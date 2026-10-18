@tool
extends RefCounted

## JSON Lens —— 格式识别（schema sniffing）
##
## 有些 JSON 是「UI 快照 / 对话转录」这类**位置化数组**：
##
##   { "n0": 120, "changes": [
##       [120, "avatars/a1.png", ["", "", ""], [["ai", "我在。"], ["meta", "用时 0.4秒"]]],
##       …
##   ]}
##
## 直接用通用结构视图读，满屏都是 `["ai", "我"]` 这种数组，人脑还得自己拼句子。
## 这里识别出「条目集合 → 条目 → [kind, text] 事件列表」的形状，
## 交给 json_lens_cards.gd 渲染成可读的卡片流。
##
## 识别用的是形状（结构、类型），不写死具体字段名，所以同形态的其它文件也能吃到。

const Model := preload("res://addons/json_lens/json_lens_model.gd")

const MIN_ENTRIES := 8
const PROBE := 48


## 返回 {} 表示不匹配；否则返回 profile 字典。
static func detect(m) -> Dictionary:
	if m == null or m.total < 16 or m.root < 0:
		return {}
	if m.kinds[m.root] != Model.K_OBJECT:
		return {}

	# 1) 根里最大的那个数组，当作「条目集合」
	var entries := -1
	var best := 0
	var c: int = m.first_child[m.root]
	while c >= 0:
		if m.kinds[c] == Model.K_ARRAY and m.counts[c] > best:
			entries = c
			best = m.counts[c]
		c = m.next_sibling[c]
	if entries < 0 or best < MIN_ENTRIES:
		return {}

	# 2) 抽第一个非空条目，找出「事件列表」在第几位
	var e: int = m.first_child[entries]
	var probes := 0
	var events_index := -1
	while e >= 0 and probes < PROBE and events_index < 0:
		if m.kinds[e] == Model.K_ARRAY:
			events_index = _find_event_index(m, e)
		e = m.next_sibling[e]
		probes += 1
	if events_index < 0:
		return {}

	# 3) 抽查：大部分条目在同一个位置都是「事件列表」（允许空数组）或是短的标量
	var cur: int = m.first_child[entries]
	var checked := 0
	var matched := 0
	while cur >= 0 and checked < PROBE:
		checked += 1
		if m.kinds[cur] != Model.K_ARRAY:
			matched += 0
		else:
			var slot := child_at(m, cur, events_index)
			if slot >= 0 and _is_event_list(m, slot):
				matched += 1
		cur = m.next_sibling[cur]
	if checked == 0 or float(matched) / float(checked) < 0.5:
		return {}

	return {
		"entries": entries,
		"events_index": events_index,
		"count": best,
		"name": "事件卡片 · %d 张" % best,
	}


## 在条目内部找「事件列表」：一个数组，元素都是 [字符串, 字符串] 这种二元组（空数组也算）。
static func _find_event_index(m, entry: int) -> int:
	var c: int = m.first_child[entry]
	var idx := 0
	while c >= 0:
		if m.kinds[c] == Model.K_ARRAY and _is_event_list(m, c):
			return idx
		c = m.next_sibling[c]
		idx += 1
	return -1


static func _is_event_list(m, arr: int) -> bool:
	if m.kinds[arr] != Model.K_ARRAY:
		return false
	var n: int = m.counts[arr]
	if n == 0:
		return true
	# 至少得有一个非空事件，否则分不清是事件列表还是空壳
	var seen := 0
	var c: int = m.first_child[arr]
	while c >= 0:
		if m.kinds[c] != Model.K_ARRAY or m.counts[c] < 2:
			return false
		var k: int = m.first_child[c]
		if m.kinds[k] != Model.K_STRING:
			return false
		seen += 1
		c = m.next_sibling[c]
	return seen > 0


## 取第 index 个子节点（没有则 -1）
static func child_at(m, parent: int, index: int) -> int:
	var c: int = m.first_child[parent]
	var i := 0
	while c >= 0:
		if i == index:
			return c
		i += 1
		c = m.next_sibling[c]
	return -1
