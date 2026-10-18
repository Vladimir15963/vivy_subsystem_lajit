extends SceneTree

## 真实 GUI 派发链路测试
##
## 前两个测试文件都是直接调 `_gui_input()`，绕过了 Godot 的控件拾取（has_point）、
## 坐标变换和裁剪 —— 所以「控件宽度为 0 收不到事件」这类问题它们抓不到。
## 这里用 `Viewport.push_input()` 走完整链路：
##   建窗口 → 建面板 → 打开真实文件 → 在窗口坐标上点行 → 检查是否真的选中。

const REAL_JSON := "res://dsh_text.json"
const WINDOW := Vector2i(1280, 900)

var panel
var stage := 0
var t0 := 0
var fails := 0


func _initialize() -> void:
	print("========== 真实派发链路测试 ==========")
	root.size = WINDOW
	panel = load("res://addons/json_lens/json_lens_panel.gd").new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)
	t0 = int(Time.get_ticks_msec())


func _process(_delta: float) -> bool:
	var now := int(Time.get_ticks_msec())
	match stage:
		0:
			if panel.is_node_ready():
				panel._do_open(ProjectSettings.globalize_path(REAL_JSON))
				stage = 1
				t0 = now
			elif now - t0 > 10000:
				_check(false, "面板 _ready 超时")
				return _finish()
		1:
			if panel.model != null and panel._cards.row_entry.size() > 0:
				stage = 2
				t0 = now
			elif now - t0 > 30000:
				_check(false, "加载超时")
				return _finish()
		2:
			if panel._cards.size.x > 100.0:
				_cards_click()
				stage = 3
				t0 = now
			elif now - t0 > 5000:
				_check(false, "卡片视图宽度仍为 0（收不到点击）", str(panel._cards.size))
				return _finish()
		3:
			if panel._rows.size.x > 100.0 and not panel._cards_mode:
				_rows_click()
				return _finish()
			elif now - t0 > 5000:
				_check(false, "结构视图布局超时", str(panel._rows.size))
				return _finish()
	return false


func _cards_click() -> void:
	var cv = panel._cards
	print("  卡片视图 size=%s  滚动区 size=%s" % [str(cv.size), str(panel._cards_scroll.size)])
	_check(cv.size.x > 100.0, "卡片视图宽度正常（不是 0）", "%.0f" % cv.size.x)
	_check(cv.size.x <= panel._cards_scroll.size.x + 1.0, "卡片视图没有超宽",
			"%.0f vs %.0f" % [cv.size.x, panel._cards_scroll.size.x])

	# 在窗口坐标上点第 3 行（卡片头）
	var row := 2
	var local := Vector2(300.0, float(cv.row_top[row]) + float(cv.row_h) * 0.5)
	var global: Vector2 = cv.get_global_position() + local
	_push_click(global)
	print("  点卡片第 %d 行：_sel_id=%d selected_row=%d" % [row, panel._sel_id, cv.selected_row])
	_check(panel._sel_id >= 0, "卡片视图能收到点击并选中", str(panel._sel_id))
	_check(cv.selected_row >= 0, "卡片视图记录了选中行", str(cv.selected_row))
	_check(panel._lbl_meta.text != "未选中节点", "详情栏有内容", panel._lbl_meta.text)

	# 切到结构视图，继续测它
	panel._on_view_selected(1)
	stage = 3
	t0 = int(Time.get_ticks_msec())


func _rows_click() -> void:
	var rv = panel._rows
	print("  结构视图 size=%s  滚动区 size=%s" % [str(rv.size), str(panel._scroll.size)])
	_check(not panel._cards_mode, "已切到结构视图")
	_check(rv.size.x > 100.0, "结构视图宽度正常", "%.0f" % rv.size.x)

	# 重点：点在**最右侧**（以前内容窄时控件不铺满，右侧这一片点不到）
	var row := 1
	var usable: float = rv.size.x - 20.0
	var local := Vector2(usable, float(row * rv.row_h) + float(rv.row_h) * 0.5)
	var global: Vector2 = rv.get_global_position() + local
	var before: int = panel._sel_id
	_push_click(global)
	print("  点结构视图第 %d 行右侧 x=%.0f：_sel_id %d → %d" % [row, usable, before, panel._sel_id])
	_check(panel._sel_id != before or rv.selected_row == row,
			"结构视图最右侧也能点中", str(panel._sel_id))
	_check(rv.selected_row == row, "选中的正是那一行", "%d vs %d" % [rv.selected_row, row])


func _push_click(global: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = global
	ev.global_position = global
	root.push_input(ev)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = global
	up.global_position = global
	root.push_input(up)


func _finish() -> bool:
	print("========== %s（失败 %d 项）==========" % ["全部通过" if fails == 0 else "有失败", fails])
	if is_instance_valid(panel):
		panel.free()
	quit(0 if fails == 0 else 1)
	return true


func _check(cond: bool, label: String, extra := "") -> void:
	if cond:
		print("  [ok] %s %s" % [label, extra])
	else:
		fails += 1
		print("  [FAIL] %s %s" % [label, extra])
