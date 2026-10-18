extends SceneTree

## 面板级集成冒烟测试：真正把 JSON Lens 面板建出来，走完
##   构建 UI → 异步加载 → 搜索 → 选中 → 编辑 → 撤销 → 保存 → 回读
## 这条完整链路。--headless 下没有真实渲染，但所有回调都会照跑。

const Model := preload("res://addons/json_lens/json_lens_model.gd")

const TEST_JSON := "user://json_lens_ui_test.json"
const REAL_JSON := "res://dsh_text.json"
const RECORDS := 3000

var panel
var stage := 0
var fails := 0
var stage_start := 0
var edit_id := -1
var base_total := 0


func _initialize() -> void:
	print("========== JSON Lens 面板冒烟测试 ==========")
	var arr := []
	for i in RECORDS:
		arr.append({
			"id": i,
			"name": "item_%d" % i,
			"tags": ["alpha", "beta"],
			"ok": i % 2 == 0,
			"note": null,
		})
	var f := FileAccess.open(TEST_JSON, FileAccess.WRITE)
	f.store_string(JSON.stringify({"meta": {"count": RECORDS}, "items": arr}))
	f.close()

	panel = load("res://addons/json_lens/json_lens_panel.gd").new()
	root.add_child(panel)
	stage_start = int(Time.get_ticks_msec())


func _process(_delta: float) -> bool:
	var now := int(Time.get_ticks_msec())
	match stage:
		0:
			if panel.is_node_ready():
				_check(panel.get_child_count() > 0, "面板 UI 构建完成",
						"子节点 %d 个" % panel.get_child_count())
				_check(panel._rows != null and panel._edit_detail != null, "关键控件都存在")
				_check(panel._btn_save != null and panel._type_opt != null, "编辑控件都存在")
				panel.open_path(ProjectSettings.globalize_path(TEST_JSON))
				stage = 1
				stage_start = now
			elif now - stage_start > 10000:
				_check(false, "面板 _ready 超时")
				return _finish()
		1:
			if panel.model != null:
				_on_loaded()
				panel._on_query_changed("item_1234")
				stage = 2
				stage_start = now
			elif now - stage_start > 20000:
				_check(false, "加载超时")
				return _finish()
		2:
			if panel._rows.search_mode:
				_on_searched()
				stage = 3
				stage_start = now
			elif now - stage_start > 10000:
				_check(false, "搜索超时")
				return _finish()
		3:
			_on_back_to_tree()
			stage = 4
			stage_start = now
		4:
			_on_edit()
			stage = 5
			stage_start = now
		5:
			# 保存是异步的（会 await 一帧，让状态栏先刷出来）
			if not panel.dirty:
				_on_saved()
				panel.open_path(ProjectSettings.globalize_path(REAL_JSON))
				stage = 6
				stage_start = now
			elif now - stage_start > 15000:
				_check(false, "保存超时")
				return _finish()
		6:
			if panel.model != null and panel.model.total > 100000:
				_on_cards_loaded()
				return _finish()
			elif now - stage_start > 30000:
				_check(false, "真实文件加载超时")
				return _finish()
	return false


func _on_loaded() -> void:
	base_total = panel.model.total
	_check(base_total > 0, "模型已回填", "%d 个节点" % base_total)
	_check(panel._rows.rows.size() > 0, "行视图有可见行", "%d 行" % panel._rows.rows.size())
	_check(panel._lbl_status.text.contains("个节点"), "状态栏显示节点数", panel._lbl_status.text)
	print("  加载后：%s" % panel._lbl_status.text)
	# 3000 条同构记录：压缩后应该只剩个位数行
	var compressed: int = panel._rows.rows.size()
	_check(compressed <= 10, "压缩后行数极少（同构记录被收成一行）", "%d 行 / %d 节点" % [compressed, base_total])
	panel._rows._select_row(0)


func _on_searched() -> void:
	var hits: int = panel._rows.rows.size()
	_check(panel._rows.search_mode, "进入搜索结果视图")
	_check(hits > 0, "搜到结果", "%d 条" % hits)
	_check(panel._lbl_hits.text.contains("结果"), "结果计数已更新", panel._lbl_hits.text)


func _on_back_to_tree() -> void:
	if panel._rows.rows.size() > 0:
		panel._on_row_activated(panel._rows.rows[0])
	_check(not panel._rows.search_mode, "点结果后回到树视图")
	_check(panel._rows.selected >= 0, "树视图里定位到了节点")
	_check(panel._rows.query != "", "查询词保留用于高亮", panel._rows.query)

	# 切到「不压缩」并展开到第 3 层，让记录里的字符串字段变成独立行
	panel._on_compress_selected(0)
	panel._rows.expand_to_depth(3)
	_check(panel._rows.rows.size() > 3000, "关闭压缩后行数恢复", "%d 行" % panel._rows.rows.size())


func _on_edit() -> void:
	# 找一个标量字符串行来改
	var found := -1
	for i in panel._rows.rows.size():
		var id: int = panel._rows.rows[i]
		if panel.model.kinds[id] == Model.K_STRING:
			found = i
			break
	_check(found >= 0, "找到一个可编辑的字符串节点")
	if found < 0:
		return
	edit_id = panel._rows.rows[found]
	panel._rows._select_row(found)
	_check(panel._edit_row.visible, "标量节点会显示编辑行")
	_check(panel._val_edit.text == panel.model.texts[edit_id], "编辑器载入原值",
			panel._val_edit.text)

	panel._val_edit.text = "EDITED_BY_TEST"
	panel._apply_edit()
	_check(panel.model.texts[edit_id] == "EDITED_BY_TEST", "改值生效")
	_check(panel.dirty, "标记为未保存")
	_check(panel._lbl_file.text.begins_with("●"), "标题出现未保存标记", panel._lbl_file.text)

	panel._on_undo_pressed()
	_check(panel.model.texts[edit_id] != "EDITED_BY_TEST", "撤销后值还原",
			panel.model.texts[edit_id])

	# 再改一次，然后触发保存
	panel._rows._select_row(panel._rows.rows.find(edit_id))
	panel._type_opt.select(0)
	panel._val_edit.text = "EDITED_BY_TEST"
	panel._apply_edit()
	_check(panel.model.texts[edit_id] == "EDITED_BY_TEST", "重新改值生效")
	panel._on_save_pressed()


func _on_saved() -> void:
	_check(panel._lbl_status.text.contains("已保存"), "状态栏报告已保存", panel._lbl_status.text)
	var text := FileAccess.get_file_as_string(TEST_JSON)
	_check(text.contains("EDITED_BY_TEST"), "落盘内容包含修改")
	var m = Model.new()
	var ok: bool = m.build(text)
	_check(ok, "落盘内容是合法 JSON", m.error)
	_check(m.total == base_total, "落盘后节点数不变", "%d vs %d" % [m.total, base_total])
	print("  保存后文件 %s 字符，%d 个节点" % [text.length(), m.total])


func _on_cards_loaded() -> void:
	print("  真实文件：%d 节点 · %s" % [panel.model.total, panel._lbl_status.text])
	_check(not panel._profile.is_empty(), "识别出卡片格式", str(panel._profile.get("name", "")))
	_check(panel._cards_mode, "自动切到卡片视图")
	_check(panel._view_opt.visible, "视图切换器出现")
	var count: int = int(panel._profile.get("count", 0))
	_check(panel._cards.row_entry.size() == count, "卡片行数 = 卡片数",
			"%d vs %d" % [panel._cards.row_entry.size(), count])

	# 两个视图来回切
	panel._on_view_selected(1)
	_check(not panel._cards_mode, "切到结构视图")
	_check(panel._scroll.visible, "结构视图滚动区可见")
	panel._on_view_selected(0)
	_check(panel._cards_mode, "切回卡片视图")

	# 展开一张有事件的卡，并选中它的事件行（应当在详情栏出现可编辑的值）
	var target := -1
	for i in mini(50, panel._cards.row_entry.size()):
		var ent: int = panel._cards.row_entry[i]
		var evs: int = panel._cards._child_at(ent, int(panel._profile["events_index"]))
		if evs >= 0 and panel.model.counts[evs] > 0:
			target = i
			break
	_check(target >= 0, "找到有事件的卡片")
	if target < 0:
		return
	panel._cards.toggle_entry(panel._cards.row_entry[target])
	_check(panel._cards.row_entry.size() > count, "展开后有事件行",
			"%d 行" % panel._cards.row_entry.size())
	panel._cards._pick_row(target + 1)
	_check(panel._sel_id >= 0, "卡片里选中事件后 _sel_id 有效")
	_check(panel._edit_row.visible, "事件文本是标量 → 显示编辑行")
	_check(panel._val_edit.text != "", "编辑器载入了事件文本", panel._val_edit.text.substr(0, 40))
	print("  选中事件：%s" % panel._lbl_meta.text)

	# ---- 点击选中（模拟真实鼠标事件）----
	var other := -1
	for i in mini(60, panel._cards.row_entry.size()):
		var ent: int = panel._cards.row_entry[i]
		if panel._cards.expanded.has(ent):
			continue
		var evs2: int = panel._cards._child_at(ent, int(panel._profile["events_index"]))
		if evs2 >= 0 and panel.model.counts[evs2] > 0:
			other = i
			break
	_check(other >= 0, "找到一张未展开且有事件的卡")
	if other < 0:
		return
	var ent_id: int = panel._cards.row_entry[other]
	var before_rows: int = panel._cards.row_entry.size()
	_click_cards_row(panel._cards, other, 200.0)
	_check(panel._sel_id == ent_id, "点卡片头选中整张卡", str(panel._sel_id))
	_check(panel._cards.row_entry.size() > before_rows, "未展开的卡被顺手展开",
			"%d → %d" % [before_rows, panel._cards.row_entry.size()])

	var erow: int = other + 1
	if erow < panel._cards.row_entry.size() and panel._cards.row_first[erow] >= 0:
		var ev: int = panel._cards.row_first[erow]
		var text_node: int = panel._cards._event_text_node(ev)
		_click_cards_row(panel._cards, erow, 300.0)
		_check(panel._sel_id == text_node, "点事件文本选中文本节点",
				"%d vs %d" % [panel._sel_id, text_node])
		_check(panel._edit_row.visible and panel._val_edit.editable, "详情栏变成可编辑",
				panel._lbl_meta.text)
		var kx: float = panel._cards.LEFT_PAD + panel._cards.INDENT + panel._cards.ARROW_W + 6.0
		_click_cards_row(panel._cards, erow, kx)
		_check(panel._sel_id == panel.model.first_child[ev], "点 kind 标签选中 kind 节点",
				"%d vs %d" % [panel._sel_id, panel.model.first_child[ev]])


func _click_cards_row(cv, row: int, x: float) -> void:
	if row < 0 or row >= cv.row_top.size():
		return
	var y: float = float(cv.row_top[row]) + float(cv.row_h) * 0.5
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = Vector2(x, y)
	cv._gui_input(ev)


func _finish() -> bool:
	print("========== %s（失败 %d 项）==========" % ["全部通过" if fails == 0 else "有失败", fails])
	if is_instance_valid(panel):
		panel.free()
		print("  面板已释放")
	quit(0 if fails == 0 else 1)
	return true


func _check(cond: bool, label: String, extra := "") -> void:
	if cond:
		print("  [ok] %s %s" % [label, extra])
	else:
		fails += 1
		print("  [FAIL] %s %s" % [label, extra])
