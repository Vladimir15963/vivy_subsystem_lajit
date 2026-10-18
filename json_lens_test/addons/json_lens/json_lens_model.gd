@tool
extends RefCounted

## JSON Lens —— 扁平化 JSON 模型
##
## 为什么不用 Tree / TreeItem / 直接拿 Dictionary 递归显示？
## 因为超长 JSON 的节点数可能上百万，TreeItem 每个都要分配 Object，
## 会瞬间吃光内存并把编辑器卡死。
##
## 做法：
## 1. 一次「前序遍历」，把整棵 JSON 摊平进若干 Packed* 数组。
##    每节点约 25 字节 + 键值文本，没有任何 Object 分配。
## 2. 摊平后是「前序连续」布局：一个节点的全部子孙在 id 上是连续区间，
##    所以折叠 = 跳下标，行号 ↔ 节点都是 O(1)。
## 3. 额外算两份元数据，专供「压缩显示」用：
##    * flat_len[id]：这棵子树压成一行要多少字符（-1 = 含子容器，压不了）
##    * sig[id]     ：子树「形状签名」（只看类型/键名/子结构，不看标量值），
##                    用来识别「连续同构的一段」并收成一行
## 4. build() 是纯数据计算，不碰场景树，所以可以丢进后台线程
##    （见 json_lens_worker.gd）。

const K_OBJECT := 0
const K_ARRAY := 1
const K_STRING := 2
const K_NUMBER := 3
const K_BOOL := 4
const K_NULL := 5

const MAX_SER_DEPTH := 200
const MASK63 := 0x7FFFFFFFFFFFFFFF

var kinds := PackedByteArray()
var keys := PackedStringArray()
var texts := PackedStringArray()
var parents := PackedInt32Array()
var first_child := PackedInt32Array()
var next_sibling := PackedInt32Array()
var index_in_parent := PackedInt32Array()
var counts := PackedInt32Array()
var depths := PackedInt32Array()

# 压缩显示用的元数据
var flat_len := PackedInt32Array()
var sig := PackedInt64Array()

var root := -1
var total := 0
var error := ""
var build_ms := 0
var source_chars := 0

var _last_child := PackedInt32Array()
var _cap := 0


# ------------------------------------------------------------------ 类型工具

static func kind_of(v) -> int:
	if v is Dictionary:
		return K_OBJECT
	if v is Array:
		return K_ARRAY
	if v is String:
		return K_STRING
	if v is bool:
		return K_BOOL
	if v == null:
		return K_NULL
	return K_NUMBER


static func _scalar_text(v) -> String:
	if v is String:
		return v
	if v is bool:
		return "true" if v else "false"
	if v == null:
		return "null"
	if v is float:
		return _float_text(v)
	return str(v)


## Godot 的 JSON 解析器把数字一律读成 float，直接 str() 会显示成 "1.0"。
## 阅读体验上整数值应该还原成 1，这里做一次整形判断。
static func _float_text(f: float) -> String:
	if not is_finite(f):
		return "null"
	if f == floorf(f) and absf(f) < 1e15:
		return str(int(f))
	return str(f)


static func _child_count_of(v) -> int:
	if v is Dictionary or v is Array:
		return v.size()
	return 0


static func _dict_keys_of(v) -> Array:
	if v is Dictionary:
		return v.keys()
	return []


# ------------------------------------------------------------------ 构建

func _reserve(cap: int) -> void:
	_cap = cap
	kinds.resize(cap)
	keys.resize(cap)
	texts.resize(cap)
	parents.resize(cap)
	first_child.resize(cap)
	next_sibling.resize(cap)
	index_in_parent.resize(cap)
	counts.resize(cap)
	depths.resize(cap)
	_last_child.resize(cap)


## 解析并摊平。失败时 error 非空并返回 false。
## progress: 可选 Callable(int)，会被后台线程每 4096 个节点调用一次。
##
## 性能要点：
##   * 先用源文本里 ',' / ':' 的数量估一个节点上限，一次性 resize 全部数组，
##     避免 Packed 数组在追加时反复扩容拷贝；
##   * 节点写入内联在循环里，省掉每个节点一次 GDScript 函数调用。
func build(src: String, progress := Callable()) -> bool:
	var t0 := int(Time.get_ticks_msec())
	source_chars = src.length()

	var parser := JSON.new()
	if parser.parse(src) != OK:
		error = "第 %d 行：%s" % [parser.get_error_line(), parser.get_error_message()]
		return false

	var data = parser.get_data()

	_reserve(src.count(",") + src.count(":") + 64)

	var rk := kind_of(data)
	var rtext := "" if (rk == K_OBJECT or rk == K_ARRAY) else _scalar_text(data)
	kinds[0] = rk
	keys[0] = ""
	texts[0] = rtext
	parents[0] = -1
	first_child[0] = -1
	next_sibling[0] = -1
	index_in_parent[0] = 0
	counts[0] = 0
	depths[0] = 0
	_last_child[0] = -1
	root = 0

	var n := 1
	var rcount := _child_count_of(data)
	if rcount > 0:
		var progress_on := progress.is_valid()
		var stack: Array = []
		stack.push_back([data, _dict_keys_of(data), 0, 0, rcount])
		# 缓存当前栈顶帧：绝大多数迭代都停留在同一层，省掉每节点一次栈取值。
		var frame: Array = stack[0]
		while not stack.is_empty():
			var cursor: int = frame[2]
			if cursor >= frame[4]:
				stack.pop_back()
				if not stack.is_empty():
					frame = stack[stack.size() - 1]
				continue
			frame[2] = cursor + 1

			var holder = frame[0]
			var ckey := ""
			var cval = null
			if holder is Dictionary:
				ckey = frame[1][cursor]
				cval = holder[ckey]
			else:
				cval = holder[cursor]

			# 内联类型判定 + 文本生成
			var ck := K_NUMBER
			var ctext := ""
			if cval is String:
				ck = K_STRING
				ctext = cval
			elif cval is Dictionary:
				ck = K_OBJECT
			elif cval is Array:
				ck = K_ARRAY
			elif cval is bool:
				ck = K_BOOL
				ctext = "true" if cval else "false"
			elif cval == null:
				ck = K_NULL
				ctext = "null"
			else:
				ctext = _float_text(cval)

			var pid: int = frame[3]
			if n >= _cap:
				_reserve(maxi(_cap * 2, 1024))
			var cid := n
			kinds[cid] = ck
			keys[cid] = ckey
			texts[cid] = ctext
			parents[cid] = pid
			first_child[cid] = -1
			next_sibling[cid] = -1
			index_in_parent[cid] = cursor
			counts[cid] = 0
			depths[cid] = depths[pid] + 1
			_last_child[cid] = -1
			if first_child[pid] < 0:
				first_child[pid] = cid
			else:
				next_sibling[_last_child[pid]] = cid
			_last_child[pid] = cid
			counts[pid] += 1
			n = cid + 1

			if ck == K_OBJECT or ck == K_ARRAY:
				var cn: int = cval.size()
				if cn > 0:
					var nf := [cval, _dict_keys_of(cval), 0, cid, cn]
					stack.push_back(nf)
					frame = nf

			if progress_on and (n & 4095) == 0:
				progress.call(n)

	total = n
	kinds.resize(total)
	keys.resize(total)
	texts.resize(total)
	parents.resize(total)
	first_child.resize(total)
	next_sibling.resize(total)
	index_in_parent.resize(total)
	counts.resize(total)
	depths.resize(total)
	_last_child = PackedInt32Array()
	_cap = total

	_recompute_all()
	build_ms = int(Time.get_ticks_msec()) - t0
	return true


# ------------------------------------------------------------------ 压缩元数据

## 前序布局下子节点 id 一定大于父节点，所以倒着扫一遍就能自底向上算完。
func _recompute_all() -> void:
	flat_len.resize(total)
	sig.resize(total)
	for i in range(total - 1, -1, -1):
		_recompute_one(i)


## 重算某个节点（以及所有祖先）的 flat_len / sig。
## 编辑或删掉节点后必须调用，否则压缩显示会用到过期数据。
func _recompute_from(node: int) -> void:
	var a := node
	while a >= 0:
		_recompute_one(a)
		a = parents[a]


func _recompute_one(i: int) -> void:
	var k := kinds[i]
	if k != K_OBJECT and k != K_ARRAY:
		# 标量：形状只看类型，不看值（否则同构记录永远组不起来）
		flat_len[i] = texts[i].length() + keys[i].length() + 6
		sig[i] = int(k)
		return

	var sum := 2
	var all_scalar := true
	var h: int = (int(k) * 1000003 + int(counts[i]) * 31) & MASK63
	var c := first_child[i]
	while c >= 0:
		var cl := flat_len[c]
		if cl < 0:
			all_scalar = false
		else:
			sum += cl + 2
		if k == K_OBJECT:
			h = (h * 131 + int(keys[c].hash())) & MASK63
		h = (h * 131 + sig[c]) & MASK63
		c = next_sibling[c]
	flat_len[i] = sum if all_scalar else -1
	sig[i] = h


## 这棵子树能不能压成一行（且压完不超过预算）。
func is_flat(id: int, budget: int) -> bool:
	var l := flat_len[id]
	return l >= 0 and l <= budget


# ------------------------------------------------------------------ 查询接口

func is_container(id: int) -> bool:
	var k := kinds[id]
	return k == K_OBJECT or k == K_ARRAY


func key_label(id: int) -> String:
	var p := parents[id]
	if p < 0:
		return ""
	if kinds[p] == K_ARRAY:
		return str(index_in_parent[id])
	return keys[id]


func type_label(id: int) -> String:
	match kinds[id]:
		K_OBJECT:
			return "对象"
		K_ARRAY:
			return "数组"
		K_STRING:
			return "字符串"
		K_NUMBER:
			return "数字"
		K_BOOL:
			return "布尔"
		_:
			return "null"


func count_label(id: int) -> String:
	if kinds[id] == K_OBJECT:
		return "%d 键" % counts[id]
	return "%d 项" % counts[id]


## 例如 $.items[3].name
func path_of(id: int) -> String:
	var parts := PackedStringArray()
	var cur := id
	while cur > 0:
		var p := parents[cur]
		if p >= 0 and kinds[p] == K_ARRAY:
			parts.append("[%d]" % index_in_parent[cur])
		else:
			parts.append("." + keys[cur])
		cur = p
	var out := "$"
	for i in range(parts.size() - 1, -1, -1):
		out += parts[i]
	return out


# ------------------------------------------------------------------ 编辑

## 改一个标量节点。返回撤销信息。
func set_scalar(id: int, new_kind: int, new_text: String) -> Dictionary:
	var info := {"op": "scalar", "id": id, "kind": kinds[id], "text": texts[id]}
	kinds[id] = new_kind
	texts[id] = new_text
	_recompute_from(id)
	return info


## 重命名对象的键。返回撤销信息。
func set_key(id: int, new_key: String) -> Dictionary:
	var info := {"op": "key", "id": id, "key": keys[id]}
	keys[id] = new_key
	_recompute_from(id)
	return info


## 把节点从父节点上摘下来（数据仍留在数组里，只是不可达，因此序列化时自然被排除）。
func unlink(id: int) -> Dictionary:
	var p := parents[id]
	if p < 0:
		return {}
	var prev := -1
	var c := first_child[p]
	while c >= 0 and c != id:
		prev = c
		c = next_sibling[c]
	if c != id:
		return {}
	var info := {"op": "unlink", "id": id, "parent": p, "prev": prev, "next": next_sibling[id]}
	if prev < 0:
		first_child[p] = next_sibling[id]
	else:
		next_sibling[prev] = next_sibling[id]
	next_sibling[id] = -1
	counts[p] -= 1
	_recompute_from(p)
	return info


func undo(info: Dictionary) -> void:
	match info.get("op", ""):
		"scalar":
			kinds[info["id"]] = info["kind"]
			texts[info["id"]] = info["text"]
			_recompute_from(info["id"])
		"key":
			keys[info["id"]] = info["key"]
			_recompute_from(info["id"])
		"unlink":
			var id: int = info["id"]
			var p: int = info["parent"]
			next_sibling[id] = info["next"]
			if int(info["prev"]) < 0:
				first_child[p] = id
			else:
				next_sibling[info["prev"]] = id
			counts[p] += 1
			_recompute_from(p)


## 把「标量字面量」解析成 (kind, text)。返回 [] 表示不合法。
static func parse_literal(text: String, want_kind: int) -> Array:
	var t := text.strip_edges()
	match want_kind:
		K_STRING:
			return [K_STRING, text]
		K_NUMBER:
			if not t.is_valid_float():
				return []
			var f := t.to_float()
			return [K_NUMBER, _float_text(f)]
		K_BOOL:
			if t == "true":
				return [K_BOOL, "true"]
			if t == "false":
				return [K_BOOL, "false"]
			return []
		K_NULL:
			return [K_NULL, "null"]
		_:
			var j := JSON.new()
			if j.parse(t) != OK:
				return []
			var v = j.get_data()
			var k := kind_of(v)
			if k == K_OBJECT or k == K_ARRAY:
				return []
			return [k, _scalar_text(v)]


# ------------------------------------------------------------------ 序列化

## 序列化某个子树为格式化 JSON。
## max_chars < 0 表示不限长度（保存文件时用）。
func to_json(id: int, max_chars := 262144) -> String:
	var acc := {"parts": [], "len": 0, "limit": max_chars, "cut": false}
	_ser(id, 0, acc)
	var out := "".join(PackedStringArray(acc["parts"]))
	if acc["cut"]:
		out += "\n…（内容过大，已截断）"
	return out


func _ser(id: int, depth: int, acc: Dictionary) -> void:
	if acc["cut"]:
		return
	var k := kinds[id]
	if k == K_OBJECT or k == K_ARRAY:
		var opener := "{" if k == K_OBJECT else "["
		var closer := "}" if k == K_OBJECT else "]"
		_put(acc, opener)
		if counts[id] > 0 and depth < MAX_SER_DEPTH:
			var pad := "\n" + "  ".repeat(depth + 1)
			var c := first_child[id]
			var first := true
			while c >= 0:
				_put(acc, pad if first else "," + pad)
				first = false
				if k == K_OBJECT:
					_put(acc, JSON.stringify(keys[c]) + ": ")
				_ser(c, depth + 1, acc)
				if acc["cut"]:
					return
				c = next_sibling[c]
			_put(acc, "\n" + "  ".repeat(depth))
		_put(acc, closer)
	elif k == K_STRING:
		_put(acc, JSON.stringify(texts[id]))
	else:
		_put(acc, texts[id])


func _put(acc: Dictionary, s: String) -> void:
	var limit: int = acc["limit"]
	if limit >= 0 and acc["len"] > limit:
		acc["cut"] = true
		return
	acc["parts"].append(s)
	acc["len"] += s.length()
