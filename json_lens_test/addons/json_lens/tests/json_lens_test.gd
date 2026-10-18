extends SceneTree

## JSON Lens 无头自测：功能 + 性能 + 虚拟化行数校验
## 运行：godot --headless --path <project> --script addons/json_lens/tests/json_lens_test.gd

const Model := preload("res://addons/json_lens/json_lens_model.gd")
const Worker := preload("res://addons/json_lens/json_lens_worker.gd")
const RowsView := preload("res://addons/json_lens/json_lens_rows.gd")
const CardsView := preload("res://addons/json_lens/json_lens_cards.gd")
const Schema := preload("res://addons/json_lens/json_lens_schema.gd")

const RECORDS := 50000

var _fails := 0


func _initialize() -> void:
	print("========== JSON Lens 自测 ==========")
	_test_small()
	_test_big_model()
	_test_rows_virtualization()
	_test_worker_async()
	_test_compression()
	_test_editing()
	_test_cards()
	_test_no_size_drift()
	_test_toggle_by_click()
	print("========== %s（失败 %d 项）==========" % ["全部通过" if _fails == 0 else "有失败", _fails])
	quit(0 if _fails == 0 else 1)


func _check(cond: bool, label: String, extra := "") -> void:
	if cond:
		print("  [ok] %s %s" % [label, extra])
	else:
		_fails += 1
		print("  [FAIL] %s %s" % [label, extra])


# ---------------------------------------------------------------- 小样本

func _test_small() -> void:
	print("\n-- 基础语义 --")
	var src := '{"a":1,"b":[true,null,"x\\ny"],"c":{"d":2.5,"e":{}},"f":[]}'
	var m = Model.new()
	var ok: bool = m.build(src)
	_check(ok, "解析成功", "错误=%s" % m.error)

	# 数一数独立算出来的节点数：根a b b0 b1 b2 c c.d c.e f = 10
	_check(m.total == 10, "节点数", "total=%d 期望 10" % m.total)

	var root_kind: int = m.kinds[m.root]
	_check(root_kind == Model.K_OBJECT, "根是对象")

	var a: int = m.first_child[m.root]
	_check(m.keys[a] == "a", "第一个键是 a", "实际=%s" % m.keys[a])
	_check(m.texts[a] == "1", "整数不显示成 1.0", "实际=%s" % m.texts[a])
	_check(m.depths[a] == 1, "深度=1")
	_check(m.path_of(a) == "$.a", "路径", "实际=%s" % m.path_of(a))

	var b: int = m.next_sibling[a]
	_check(m.keys[b] == "b" and m.counts[b] == 3, "b 是 3 元素数组")
	var b2: int = m.next_sibling[m.next_sibling[m.first_child[b]]]
	_check(m.index_in_parent[b2] == 2, "数组下标")
	_check(m.path_of(b2) == "$.b[2]", "数组路径", "实际=%s" % m.path_of(b2))
	_check(m.texts[b2] == "x\ny", "字符串保留换行")
	_check(m.key_label(b2) == "2", "数组元素的键标签")

	var c: int = m.next_sibling[b]
	var cc: int = m.first_child[c]
	_check(m.path_of(cc) == "$.c.d", "嵌套路径", "实际=%s" % m.path_of(cc))
	_check(m.texts[cc] == "2.5", "浮点文本", "实际=%s" % m.texts[cc])

	# 子树序列化
	var js: String = m.to_json(c)
	_check(js.contains('"d": 2.5'), "子树序列化含 d", js.replace("\n", " "))
	_check(js.contains('"e": {}'), "空对象序列化", js.replace("\n", " "))

	# 坏 JSON
	var bad = Model.new()
	_check(not bad.build("{oops"), "坏 JSON 被拒绝")
	_check(bad.error != "", "坏 JSON 有错误信息", bad.error)


# ---------------------------------------------------------------- 大样本

func _test_big_model() -> void:
	print("\n-- 超长 JSON（%d 条记录）--" % RECORDS)
	var doc := _make_doc(RECORDS)
	var t := int(Time.get_ticks_msec())
	var src := JSON.stringify(doc)
	var stringify_ms := int(Time.get_ticks_msec()) - t
	print("  生成文本 %.1f MB / 用时 %d ms" % [float(src.length()) / 1048576.0, stringify_ms])

	var expect := _count_nodes(doc)

	var m = Model.new()
	t = int(Time.get_ticks_msec())
	var ok: bool = m.build(src)
	var build_ms := int(Time.get_ticks_msec()) - t
	_check(ok, "大文件解析成功", m.error)
	_check(m.total == expect, "节点数与递归计数一致", "%d vs %d" % [m.total, expect])
	print("  扁平化：%s 个节点 / %d ms（%.2f 万节点每秒）" % [
		_fmt(m.total), build_ms, float(m.total) / maxf(1.0, float(build_ms)) * 10.0
	])
	_check(build_ms < 30000, "解析在 30 秒内完成", "%d ms" % build_ms)

	# 纯解析耗时（用于判断瓶颈在引擎还是我们的扁平化）
	t = int(Time.get_ticks_msec())
	var parsed = JSON.parse_string(src)
	var parse_ms := int(Time.get_ticks_msec()) - t
	print("  纯 JSON.parse：%d ms（%.1f MB）" % [parse_ms, float(src.length()) / 1048576.0])
	parsed = null

	# 按 key 找节点（构造函数里的键序会被 JSON.stringify 排序，不能硬编码 id）
	t = int(Time.get_ticks_msec())
	var items2: int = _child_by_key(m, m.root, "items")
	_check(items2 > 0, "能找到 items 节点")
	_check(m.path_of(items2) == "$.items", "items 路径", m.path_of(items2))
	_check(m.counts[items2] == RECORDS, "items 元素数", str(m.counts[items2]))
	var last_elem: int = m.first_child[items2]
	while m.next_sibling[last_elem] >= 0:
		last_elem = m.next_sibling[last_elem]
	_check(m.path_of(last_elem) == "$.items[%d]" % (RECORDS - 1),
			"最后一个元素的路径", m.path_of(last_elem))
	_check(m.counts[last_elem] == 6, "记录有 6 个字段", str(m.counts[last_elem]))

	# 序列化一个中等子树，必须有字符上限保护
	var items: int = _child_by_key(m, m.root, "items")
	t = int(Time.get_ticks_msec())
	var js: String = m.to_json(items, 20000)
	var ser_ms := int(Time.get_ticks_msec()) - t
	_check(js.length() <= 20200, "序列化被字符上限截断", "%d 字符 / %d ms" % [js.length(), ser_ms])
	_check(ser_ms < 2000, "截断序列化够快", "%d ms" % ser_ms)


# ---------------------------------------------------------------- 虚拟化

func _test_rows_virtualization() -> void:
	print("\n-- 虚拟化行构建 --")
	var doc := _make_doc(RECORDS)
	var src := JSON.stringify(doc)
	var m = Model.new()
	m.build(src)

	var rv = RowsView.new()
	root.add_child(rv)
	rv.font = ThemeDB.fallback_font
	rv.font_size = 13
	rv.refresh_metrics()
	rv.set_compress(RowsView.COMPRESS_OFF)
	rv.set_model(m)

	var at_depth_2: int = rv.rows.size()
	_check(at_depth_2 == 4 + RECORDS, "展开 2 层 = 根 + 3 个顶层键 + %d 条记录" % RECORDS,
			"实际 %d" % at_depth_2)

	var t := int(Time.get_ticks_msec())
	rv.expand_to_depth(1)
	var depth1_ms := int(Time.get_ticks_msec()) - t
	_check(rv.rows.size() == 4, "只看根 = 4 行", "实际 %d" % rv.rows.size())

	t = int(Time.get_ticks_msec())
	rv.expand_all()
	var all_ms := int(Time.get_ticks_msec()) - t
	_check(rv.rows.size() == m.total, "全部展开 = 全部节点", "%d vs %d" % [rv.rows.size(), m.total])
	print("  构建可见行：只展开 1 层 %d ms，全部展开 %s 行 %d ms" % [depth1_ms, _fmt(rv.rows.size()), all_ms])
	_check(all_ms < 15000, "百万级可见行构建在 15 秒内", "%d ms" % all_ms)

	# 折叠回 2 层：O(1)
	t = int(Time.get_ticks_msec())
	rv.expand_to_depth(2)
	var back_ms := int(Time.get_ticks_msec()) - t
	_check(rv.rows.size() == 4 + RECORDS, "折回 2 层行数正确")

	# 单节点折叠（走显式展开表）
	var items: int = _child_by_key(m, m.root, "items")
	rv.set_expanded(items, false)
	rv.rebuild()
	_check(rv.rows.size() == 4, "折叠 items 后只剩 4 行（根 + 3 个顶层键）", "实际 %d" % rv.rows.size())
	_check(rv.is_expanded(m.root), "折叠 items 不影响根展开")

	# 选中 / 定位
	rv.select_node(items)
	_check(rv.get_selected() == items, "选中节点")

	root.remove_child(rv)
	rv.queue_free()


# ---------------------------------------------------------------- 后台线程

func _test_worker_async() -> void:
	print("\n-- 后台线程解析 --")
	var doc := _make_doc(2000)
	var src := JSON.stringify(doc)
	var path := "user://json_lens_test_async.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(src)
	f.close()

	var w = Worker.new()
	var started: bool = w.start_load(path)
	_check(started, "任务已派发")

	# 主线程必须立刻返回：马上检查一次忙状态就应该拿到结果前的状态
	var busy_immediately := w.is_busy()
	_check(busy_immediately, "start_load 立刻返回且仍在后台跑")

	var waited := 0
	while w.is_busy() and waited < 30000:
		OS.delay_msec(5)
		waited += 5

	_check(not w.is_busy(), "后台任务完成", "等待 %d ms" % waited)
	var res: Dictionary = w.take()
	_check(not res.is_empty(), "取到结果")
	_check(res.get("error", "x") == "", "无错误", str(res.get("error")))
	var m = res.get("model")
	_check(m != null, "拿到模型")
	if m != null:
		_check(m.total == _count_nodes(doc), "线程解析节点数一致",
				"%d vs %d" % [m.total, _count_nodes(doc)])
	print("  后台解析 %d 节点，主线程等待 %d ms" % [m.total if m != null else -1, waited])

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ---------------------------------------------------------------- 工具

func _make_doc(records: int) -> Dictionary:
	var arr := []
	for i in records:
		arr.append({
			"id": i,
			"name": "user_%d" % i,
			"tags": ["alpha", "beta", "gamma"],
			"score": 1.5 + float(i % 100) * 0.01,
			"active": (i % 2) == 0,
			"meta": {"index": i, "note": "第 %d 条记录" % i},
		})
	return {"version": 1, "generated": "json_lens", "items": arr}


# ---------------------------------------------------------------- 压缩显示

func _test_compression() -> void:
	print("\n-- 压缩显示（行内合并 / 重复收缩）--")
	var items := []
	for i in 100:
		items.append({"id": i, "name": "n_%d" % i, "ok": (i % 2) == 0})
	var m = Model.new()
	var ok: bool = m.build(JSON.stringify({"items": items, "meta": {"v": 1}}))
	_check(ok, "构造成功")

	var items_id: int = _child_by_key(m, m.root, "items")
	var first: int = m.first_child[items_id]
	var second: int = m.next_sibling[first]
	var meta_id: int = _child_by_key(m, m.root, "meta")
	_check(m.sig[first] == m.sig[second], "同构记录的形状签名相同")
	_check(m.sig[first] != m.sig[meta_id], "结构不同的签名不同")
	_check(m.flat_len[first] > 0, "纯标量记录可以压成一行", "长度 %d" % m.flat_len[first])
	_check(m.flat_len[m.root] > 130, "根节点整体太长，压不成一行", "长度 %d" % m.flat_len[m.root])
	_check(not m.is_flat(m.root, 130), "根节点超出预算不可内联")
	_check(m.is_flat(first, 130), "记录在预算内可内联")
	_check(not m.is_flat(first, 10), "超出预算就不再内联")

	var rv = RowsView.new()
	root.add_child(rv)
	rv.font = ThemeDB.fallback_font
	rv.font_size = 13
	rv.refresh_metrics()

	rv.set_compress(RowsView.COMPRESS_OFF)
	rv.set_model(m)
	rv.expand_to_depth(2)
	var rows_off: int = rv.rows.size()
	_check(rows_off == 104, "不压缩：1 根 + 2 顶键 + 100 条 + meta 的 1 个字段",
			"实际 %d" % rows_off)

	rv.set_compress(RowsView.COMPRESS_INLINE)
	rv.expand_to_depth(2)
	var rows_inline: int = rv.rows.size()
	_check(rows_inline == 103, "行内合并：meta 的内容摊到它自己那行，少 1 行",
			"实际 %d" % rows_inline)
	_check(rv.is_inline_merged(first), "记录被判定为内联合并")
	_check(rv.is_inline_merged(meta_id), "meta 被判定为内联合并")

	rv.set_compress(RowsView.COMPRESS_GROUP)
	rv.expand_to_depth(2)
	var rows_group: int = rv.rows.size()
	_check(rows_group == 4, "重复收缩：100 条同构记录收成 1 行", "实际 %d" % rows_group)

	var group_row := -1
	for i in rv.rows.size():
		if rv.row_len[i] > 1:
			group_row = i
			break
	_check(group_row >= 0, "存在组行")
	if group_row >= 0:
		_check(rv.row_len[group_row] == 100, "组行覆盖 100 条", str(rv.row_len[group_row]))
		_check(rv.row_start[group_row] == 0, "组行起始下标 0", str(rv.row_start[group_row]))
		rv.expand_group(group_row)
		# 展开后成员逐行铺开，但组头行必须保留（这样才能再点回去）
		_check(rv.rows.size() == rows_inline + 1, "展开组：逐行 + 保留组头",
				"%d（期望 %d）" % [rv.rows.size(), rows_inline + 1])
		_check(rv.row_len[group_row] == 100, "组头仍在且长度不变", str(rv.row_len[group_row]))

	# 结构不一致的元素不能被收缩（元素本身很长，所以不会被内联合并掉）
	var pad := "x".repeat(200)
	var m2 = Model.new()
	m2.build('{"a":[{"x":"%s"},{"y":"%s"},{"z":"%s"}]}' % [pad, pad, pad])
	rv.set_model(m2)
	rv.expand_to_depth(2)
	_check(rv.rows.size() == 5, "异构数组不会被收成一行（根 + a + 3 个元素）", "%d" % rv.rows.size())

	# 标量重复也要能收：40 个 null 超出内联预算，于是走重复收缩
	var nulls := ""
	for i in 40:
		nulls += "null,"
	nulls = nulls.substr(0, nulls.length() - 1)
	var m3 = Model.new()
	m3.build('{"n":[%s]}' % nulls)
	rv.set_model(m3)
	rv.expand_to_depth(3)
	_check(rv.rows.size() == 3, "重复的 null 收成一行", "%d" % rv.rows.size())

	# 根节点永远不被内联，保证顶层结构可见
	var m4 = Model.new()
	m4.build('{"a":1,"b":2}')
	rv.set_model(m4)
	rv.expand_to_depth(2)
	_check(rv.rows.size() == 3, "根节点不参与内联合并", "%d" % rv.rows.size())
	_check(not rv.is_inline_merged(m4.root), "根节点判定为不合并")

	root.remove_child(rv)
	rv.queue_free()


# ---------------------------------------------------------------- 编辑

func _test_editing() -> void:
	print("\n-- 编辑 / 撤销 / 保存 --")
	var m = Model.new()
	m.build('{"a":1,"b":"x","c":{"d":true,"e":null},"f":[1,2,3]}')
	var a: int = _child_by_key(m, m.root, "a")
	var b: int = _child_by_key(m, m.root, "b")

	var u1: Dictionary = m.set_scalar(a, Model.K_NUMBER, "42")
	_check(m.texts[a] == "42", "改值生效")
	_check(m.to_json(m.root).contains('"a": 42'), "序列化反映修改")
	m.undo(u1)
	_check(m.texts[a] == "1", "撤销改值")

	var u2: Dictionary = m.set_scalar(b, Model.K_BOOL, "true")
	_check(m.kinds[b] == Model.K_BOOL and m.texts[b] == "true", "改类型生效")
	_check(m.to_json(m.root).contains('"b": true'), "序列化反映类型变化")
	m.undo(u2)
	_check(m.kinds[b] == Model.K_STRING and m.texts[b] == "x", "撤销改类型")

	var u3: Dictionary = m.set_key(a, "alpha")
	_check(m.keys[a] == "alpha", "改键名生效")
	_check(m.to_json(m.root).contains('"alpha": 1'), "序列化反映键名")
	m.undo(u3)
	_check(m.keys[a] == "a", "撤销改键名")

	var before := m.to_json(m.root)
	var u4: Dictionary = m.unlink(b)
	_check(not u4.is_empty(), "删除返回撤销信息")
	_check(not m.to_json(m.root).contains('"b"'), "删除后序列化里没有它")
	_check(m.counts[m.root] == 3, "父节点子数减一", str(m.counts[m.root]))
	m.undo(u4)
	_check(m.to_json(m.root) == before, "撤销删除后完全还原")
	_check(m.counts[m.root] == 4, "父节点子数还原", str(m.counts[m.root]))

	_check(Model.parse_literal("abc", Model.K_NUMBER).is_empty(), "数字校验拒绝 abc")
	_check(Model.parse_literal("12.5", Model.K_NUMBER)[1] == "12.5", "数字校验接受 12.5")
	_check(Model.parse_literal("true", Model.K_BOOL).size() == 2, "布尔校验接受 true")
	_check(Model.parse_literal("True", Model.K_BOOL).is_empty(), "布尔校验拒绝 True")

	# 保存 -> 落盘 -> 重新解析（round trip）
	var text: String = m.to_json(m.root, -1)
	var m2 = Model.new()
	_check(m2.build(text), "保存出来的文本能被重新解析", m2.error)
	_check(m2.total == m.total, "往返后节点数一致", "%d vs %d" % [m2.total, m.total])

	var path := "user://json_lens_edit_roundtrip.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	var m3 = Model.new()
	m3.build(FileAccess.get_file_as_string(path))
	_check(m3.total == m.total, "落盘后再读回节点数一致", "%d" % m3.total)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ---------------------------------------------------------------- 格式识别 / 卡片视图

func _test_cards() -> void:
	print("\n-- 格式识别与卡片视图 --")
	var parts := PackedStringArray()
	parts.append('[1,"a.png",["","",""],[["name","大肥鱼"],["ai","我"],["ai","在"],["ai","。"],["ai","这是一整句完整的话。"],["meta","用时 0.4秒"]]]')
	parts.append('[2,"b.png",["","",""],[["user","你好"],["ai","你好。"]]]')
	for i in 10:
		parts.append('[%d,"",["","",""],[]]' % (100 + i))
	var src := '{"n0":1,"changes":[' + ",".join(parts) + ']}'
	var m = Model.new()
	_check(m.build(src), "构造成功", m.error)

	var prof: Dictionary = Schema.detect(m)
	_check(not prof.is_empty(), "识别出卡片格式")
	if prof.is_empty():
		return
	_check(int(prof["count"]) == 12, "识别出 12 张卡", str(prof["count"]))
	_check(int(prof["events_index"]) == 3, "事件列表在第 3 位", str(prof["events_index"]))

	# 普通 JSON 不应该被误判
	var plain = Model.new()
	plain.build('{"a":1,"b":[1,2,3]}')
	_check(Schema.detect(plain).is_empty(), "普通 JSON 不会被误判成卡片格式")

	var cv = CardsView.new()
	root.add_child(cv)
	cv.font = ThemeDB.fallback_font
	cv.font_size = 13
	cv.set_source(m, prof)
	cv.refresh_metrics()

	_check(cv.row_entry.size() == 12, "默认全部折叠：12 行卡片头", "%d" % cv.row_entry.size())
	_check(cv.row_text[0].contains("大肥鱼"), "卡片头摘要含正文", cv.row_text[0])
	var head: String = cv._head_text(cv.row_entry[0])
	_check(head.contains("a.png"), "卡片头含头像字段", head)
	_check(head.contains("6 条"), "卡片头含事件数", head)

	# 展开第一张卡：name 1 行 + 3 个碎 ai 片段合并 1 行 + 整句 1 行 + meta 1 行 = 4 行
	cv.toggle_entry(cv.row_entry[0])
	_check(cv.row_entry.size() == 12 + 4, "展开第一张后 16 行", "%d" % cv.row_entry.size())
	# 找回被合并的那一行
	var merged_row := -1
	for i in cv.row_entry.size():
		if cv.row_kind[i] == "ai" and cv.row_span[i] > 1:
			merged_row = i
			break
	_check(merged_row >= 0, "存在合并了多个碎片的行")
	if merged_row >= 0:
		_check(cv.row_span[merged_row] == 3, "合并了 3 个碎片", str(cv.row_span[merged_row]))
		_check(cv.row_text[merged_row] == "我在。", "合并文本正确", cv.row_text[merged_row])

	# 整句没有被合并（长度 > 阈值）
	var long_row := -1
	for i in cv.row_entry.size():
		if cv.row_text[i] == "这是一整句完整的话。":
			long_row = i
			break
	_check(long_row >= 0, "完整句子单独成行")
	if long_row >= 0:
		_check(cv.row_span[long_row] == 1, "长句 span=1", str(cv.row_span[long_row]))

	# reveal_node：从文本节点定位到卡片行
	var entry0: int = cv.row_entry[0]
	var evs: int = cv._child_at(entry0, 3)
	var ev: int = m.first_child[evs]
	var tn := -1
	while ev >= 0:
		var t: int = cv._event_text_node(ev)
		if t >= 0 and m.texts[t] == "这是一整句完整的话。":
			tn = t
			break
		ev = m.next_sibling[ev]
	_check(tn >= 0, "找到目标文本节点")
	if tn >= 0:
		cv.collapse_all()
		cv.reveal_node(tn)
		_check(cv.selected == tn, "reveal_node 选中目标")
		_check(cv.selected_row >= 0, "reveal_node 定位到行", str(cv.selected_row))

	# 反复展开/折叠：尺寸必须回到基准，宽度不能被自己撑大
	cv.collapse_all()
	var cx: float = cv.custom_minimum_size.x
	var cy: float = cv.custom_minimum_size.y
	for i in 8:
		cv.toggle_entry(entry0)
		cv.toggle_entry(entry0)
	_check(cv.custom_minimum_size.x == cx, "卡片宽度不被反复折叠撑大",
			"%.0f vs %.0f" % [cv.custom_minimum_size.x, cx])
	_check(cv.custom_minimum_size.y == cy, "卡片高度反复折叠后回到基准",
			"%.0f vs %.0f" % [cv.custom_minimum_size.y, cy])
	_check(cv.custom_minimum_size.x <= 1.0, "卡片视图不自己撑宽（交给滚动容器）",
			str(cv.custom_minimum_size.x))

	root.remove_child(cv)
	cv.queue_free()

	# 真机回归：项目里的 dsh_text.json 应该被识别，且行数远小于节点数
	if FileAccess.file_exists("res://dsh_text.json"):
		var real = Model.new()
		var t0 := int(Time.get_ticks_msec())
		var okr: bool = real.build(FileAccess.get_file_as_string("res://dsh_text.json"))
		var build_ms := int(Time.get_ticks_msec()) - t0
		_check(okr, "真实文件解析成功")
		var pr: Dictionary = Schema.detect(real)
		_check(not pr.is_empty(), "真实文件被识别为卡片格式", str(pr.get("name", "")))
		if not pr.is_empty():
			var cv2 = CardsView.new()
			root.add_child(cv2)
			cv2.font = ThemeDB.fallback_font
			cv2.font_size = 13
			cv2.apply_palette(true)
			t0 = int(Time.get_ticks_msec())
			cv2.set_source(real, pr)
			cv2.refresh_metrics()
			var cards_ms := int(Time.get_ticks_msec()) - t0
			print("  真实文件：%d 节点 / 解析 %d ms；%d 张卡 / 折叠视图 %d 行 / 构建 %d ms" % [
				real.total, build_ms, int(pr["count"]), cv2.row_entry.size(), cards_ms])
			_check(cv2.row_entry.size() == int(pr["count"]),
					"折叠时行数 = 卡片数", "%d vs %d" % [cv2.row_entry.size(), int(pr["count"])])
			_check(cv2.row_entry.size() < real.total / 10, "行数远少于节点数",
					"%d 行 vs %d 节点" % [cv2.row_entry.size(), real.total])
			# 展开一张**有事件**的卡，行数必须增加（这个文件的第一张卡事件是空的）
			var target := -1
			for i in mini(50, cv2.row_entry.size()):
				var ent: int = cv2.row_entry[i]
				var evsx: int = cv2._child_at(ent, int(pr["events_index"]))
				if evsx >= 0 and real.counts[evsx] > 0:
					target = i
					break
			_check(target >= 0, "找到有事件的卡片")
			if target >= 0:
				var before: int = cv2.row_entry.size()
				cv2.toggle_entry(cv2.row_entry[target])
				_check(cv2.row_entry.size() > before, "展开一张卡后行数增加",
						"%d → %d" % [before, cv2.row_entry.size()])
			root.remove_child(cv2)
			cv2.queue_free()


# ---------------------------------------------------------------- 尺寸漂移回归

func _test_no_size_drift() -> void:
	print("\n-- 反复折叠/展开不应让尺寸漂移 --")
	var pad := "x".repeat(300)
	var m = Model.new()
	m.build('{"a":{"deep":{"val":"%s"}},"b":[1,2,3]}' % pad)
	var rv = RowsView.new()
	root.add_child(rv)
	rv.font = ThemeDB.fallback_font
	rv.font_size = 13
	rv.set_compress(RowsView.COMPRESS_OFF)
	rv.set_model(m)
	rv.expand_to_depth(1)

	var a: int = _child_by_key(m, m.root, "a")
	var w0: float = rv.custom_minimum_size.x
	var h0: float = rv.custom_minimum_size.y
	rv._toggle(a)
	_check(rv.custom_minimum_size.y == h0 + float(rv.row_h), "展开一层高度正好 +1 行",
			"%.0f → %.0f" % [h0, rv.custom_minimum_size.y])
	rv._toggle(a)
	_check(rv.custom_minimum_size.y == h0, "收起后高度回到基准")

	for i in 8:
		# 模拟一次绘制里遇到超宽行（无头环境没有真实绘制，手动制造这个状态）
		rv._content_w = 9000.0
		rv._apply_content_width()
		rv._toggle(a)
		rv._toggle(a)
	_check(rv.custom_minimum_size.x == w0, "反复折叠后内容宽度不膨胀",
			"%.1f vs %.1f" % [rv.custom_minimum_size.x, w0])
	_check(rv.custom_minimum_size.y == h0, "反复折叠后高度仍回到基准",
			"%.1f vs %.1f" % [rv.custom_minimum_size.y, h0])

	root.remove_child(rv)
	rv.queue_free()


# ---------------------------------------------------------------- 点箭头折叠/展开

## 直接模拟鼠标点箭头，覆盖四种行：普通容器 / 内联合并 / 重复收缩组 / 卡片
func _test_toggle_by_click() -> void:
	print("\n-- 点箭头折叠↔展开（真实点击事件）--")

	# 1) 普通容器
	var p1: Array = _make_view('{"a":{"b":{"c":1}},"d":[1,2,3]}', RowsView.COMPRESS_OFF)
	var rv = p1[0]
	var m = p1[1]
	rv.expand_to_depth(2)
	var a: int = _child_by_key(m, m.root, "a")
	var n0: int = rv.rows.size()
	_click_arrow(rv, a)
	var n1: int = rv.rows.size()
	_click_arrow(rv, a)
	var n2: int = rv.rows.size()
	_check(n1 < n0, "普通容器：点箭头折叠", "%d → %d" % [n0, n1])
	_check(n2 == n0, "普通容器：再点能展开回来", "%d → %d" % [n1, n2])
	root.remove_child(rv)
	rv.queue_free()

	# 2) 行内合并的扁平节点
	var p2: Array = _make_view('{"e":{"x":1,"y":2},"f":[1,2,3]}', RowsView.COMPRESS_GROUP)
	rv = p2[0]
	m = p2[1]
	rv.expand_to_depth(2)
	var e: int = _child_by_key(m, m.root, "e")
	_check(rv.is_inline_merged(e), "行内节点初始是合并成一行")
	n0 = rv.rows.size()
	_click_arrow(rv, e)
	n1 = rv.rows.size()
	_click_arrow(rv, e)
	n2 = rv.rows.size()
	_click_arrow(rv, e)
	var n3: int = rv.rows.size()
	_check(n1 > n0, "行内节点：展开成逐行", "%d → %d" % [n0, n1])
	_check(n2 == n0, "行内节点：收回一行", "%d → %d" % [n1, n2])
	_check(n3 == n1, "行内节点：还能再展开", "%d → %d" % [n2, n3])
	root.remove_child(rv)
	rv.queue_free()

	# 3) 重复收缩组：组头必须保留，否则再也收不回去
	var items := []
	for i in 20:
		items.append({"id": i, "name": "n"})
	var p3: Array = _make_view(JSON.stringify({"items": items}), RowsView.COMPRESS_GROUP)
	rv = p3[0]
	m = p3[1]
	rv.expand_to_depth(2)
	var grow := -1
	for i in rv.rows.size():
		if rv.row_len[i] > 1:
			grow = i
			break
	_check(grow >= 0, "存在组行")
	if grow >= 0:
		var first: int = rv.rows[grow]
		n0 = rv.rows.size()
		_click_arrow(rv, first)
		n1 = rv.rows.size()
		var header_kept: bool = rv.rows.find(first) >= 0 and rv.row_len[rv.rows.find(first)] == 20
		_click_arrow(rv, first)
		n2 = rv.rows.size()
		_check(n1 > n0, "组行：点箭头展开", "%d → %d" % [n0, n1])
		_check(header_kept, "组行：展开后组头仍然在")
		_check(n2 == n0, "组行：再点组头能收回", "%d → %d" % [n1, n2])
	root.remove_child(rv)
	rv.queue_free()

	# 4) 卡片视图
	var parts := PackedStringArray()
	parts.append('[1,"a.png",["","",""],[["ai","你好。"],["meta","用时 0.4秒"]]]')
	for i in 10:
		parts.append('[%d,"",["","",""],[]]' % (100 + i))
	var cm = Model.new()
	cm.build('{"changes":[' + ",".join(parts) + ']}')
	var prof: Dictionary = Schema.detect(cm)
	var cv = CardsView.new()
	root.add_child(cv)
	cv.font = ThemeDB.fallback_font
	cv.font_size = 13
	cv.set_source(cm, prof)
	cv.size = Vector2(700, 400)
	cv.refresh_metrics()
	var c0: int = cv.row_entry.size()
	_click_card_row(cv, 0)
	var c1: int = cv.row_entry.size()
	_click_card_row(cv, 0)
	var c2: int = cv.row_entry.size()
	_click_card_row(cv, 0)
	var c3: int = cv.row_entry.size()
	_check(c1 > c0, "卡片：点箭头展开", "%d → %d" % [c0, c1])
	_check(c2 == c0, "卡片：再点收起", "%d → %d" % [c1, c2])
	_check(c3 == c1, "卡片：还能再展开", "%d → %d" % [c2, c3])
	root.remove_child(cv)
	cv.queue_free()


func _make_view(src: String, compress: int) -> Array:
	var m = Model.new()
	m.build(src)
	var rv = RowsView.new()
	root.add_child(rv)
	rv.font = ThemeDB.fallback_font
	rv.font_size = 13
	rv.set_compress(compress)
	rv.set_model(m)
	rv.size = Vector2(700, 400)
	return [rv, m]


func _click_arrow(view, node_id: int) -> void:
	var row: int = view.rows.find(node_id)
	if row < 0:
		return
	var d: int = view.model.depths[node_id]
	var x: float = view.LEFT_PAD + float(d) * view.INDENT + view.ARROW_W * 0.5
	var y: float = float(row * view.row_h) + float(view.row_h) * 0.5
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = Vector2(x, y)
	view._gui_input(ev)


func _click_card_row(cv, row: int) -> void:
	if row >= cv.row_top.size():
		return
	var y: float = float(cv.row_top[row]) + float(cv.row_h) * 0.5
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = Vector2(cv.LEFT_PAD + 4.0, y)
	cv._gui_input(ev)


func _child_by_key(m, parent: int, key: String) -> int:
	var c: int = m.first_child[parent]
	while c >= 0:
		if m.keys[c] == key:
			return c
		c = m.next_sibling[c]
	return -1


func _count_nodes(v) -> int:
	var n := 1
	if v is Dictionary:
		for k in v:
			n += _count_nodes(v[k])
	elif v is Array:
		for x in v:
			n += _count_nodes(x)
	return n


func _fmt(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out
