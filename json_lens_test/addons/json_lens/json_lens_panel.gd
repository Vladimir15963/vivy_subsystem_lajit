@tool
extends MarginContainer

## JSON Lens —— 编辑器主屏面板
##
## 布局：
##   [打开 / 重载 / 保存 / 撤销 / 压缩 / 层级 / 视图 / 搜索 / 字号]
##   [卡片视图（按格式渲染）或 结构视图（原始 JSON 树）  ⇅ 可拖拽分隔]
##   [详情：路径 + 类型/值编辑器 + 完整值]
##   [状态栏：文件 / 张数或节点数 / 耗时 / 可见行 / 未保存标记]

const Model := preload("res://addons/json_lens/json_lens_model.gd")
const Worker := preload("res://addons/json_lens/json_lens_worker.gd")
const RowsView := preload("res://addons/json_lens/json_lens_rows.gd")
const CardsView := preload("res://addons/json_lens/json_lens_cards.gd")
const Schema := preload("res://addons/json_lens/json_lens_schema.gd")

const CONFIG_PATH := "user://json_lens.cfg"
const FONT_SIZES := [11, 12, 13, 14, 16, 18, 20, 24]
const DEPTHS := [1, 2, 3, 4, 1048576]
const EDIT_KINDS := [Model.K_STRING, Model.K_NUMBER, Model.K_BOOL, Model.K_NULL]
const EDIT_LABELS := ["字符串", "数字", "布尔", "null"]
const COMPRESS_LABELS := ["不压缩", "行内合并", "行内 + 重复收缩"]
const SCAN_PER_FRAME := 24000
const MAX_HITS := 50000
const MAX_UNDO := 300

var model = null
var loader = null
var current_path := ""
var query := ""
var default_depth := 2
var font_size := 13
var dirty := false
var compress := RowsView.COMPRESS_GROUP

var _profile := {}
var _cards_mode := false
var _syncing := false
var _sel_id := -1

var _undo: Array = []
var _pending_open := ""
var _syncing_editor := false

# 主线程分帧搜索状态
var _scan_active := false
var _scan_pos := 0
var _scan_hits := PackedInt32Array()
var _scan_lower := ""
var _scan_truncated := false
var _scan_t0 := 0

var _rows = null
var _cards = null
var _scroll: ScrollContainer
var _cards_scroll: ScrollContainer
var _split: VSplitContainer
var _edit_query: LineEdit
var _lbl_hits: Label
var _lbl_file: Label
var _lbl_status: Label
var _lbl_meta: Label
var _edit_detail: TextEdit
var _edit_row: HBoxContainer
var _type_opt: OptionButton
var _val_edit: LineEdit
var _depth_opt: OptionButton
var _font_opt: OptionButton
var _compress_opt: OptionButton
var _view_opt: OptionButton
var _btn_save: Button
var _btn_undo: Button
var _btn_delete: Button
var _search_timer: Timer
var _dialog: FileDialog
var _confirm: ConfirmationDialog
var _loading := false


func _ready() -> void:
	loader = Worker.new()
	_build_ui()
	_apply_theme()
	set_process(true)
	var last := _load_last_path()
	if last != "" and FileAccess.file_exists(last):
		open_path(last)
	else:
		_lbl_status.text = "点击「打开 JSON」或把 .json 文件拖到这里"


# ------------------------------------------------------------------ UI

func _build_ui() -> void:
	add_theme_constant_override("margin_left", 2)
	add_theme_constant_override("margin_right", 2)
	add_theme_constant_override("margin_top", 2)
	add_theme_constant_override("margin_bottom", 2)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 3)
	add_child(root)

	# ---------------- 工具栏
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	root.add_child(bar)

	var btn_open := Button.new()
	btn_open.text = "打开 JSON…"
	btn_open.tooltip_text = "选择要阅读 / 编辑的 JSON 文件"
	btn_open.pressed.connect(_on_open_pressed)
	bar.add_child(btn_open)

	var btn_reload := Button.new()
	btn_reload.text = "↻"
	btn_reload.tooltip_text = "重新读取当前文件（会丢弃未保存的修改）"
	btn_reload.pressed.connect(_on_reload_pressed)
	bar.add_child(btn_reload)

	_btn_save = Button.new()
	_btn_save.text = "保存"
	_btn_save.tooltip_text = "把修改写回文件（Ctrl+S）"
	_btn_save.pressed.connect(_on_save_pressed)
	bar.add_child(_btn_save)

	_btn_undo = Button.new()
	_btn_undo.text = "撤销"
	_btn_undo.tooltip_text = "撤销上一次修改（Ctrl+Z）"
	_btn_undo.pressed.connect(_on_undo_pressed)
	bar.add_child(_btn_undo)

	bar.add_child(VSeparator.new())
	bar.add_child(_make_label("压缩"))
	_compress_opt = OptionButton.new()
	for i in COMPRESS_LABELS.size():
		_compress_opt.add_item(COMPRESS_LABELS[i], i)
	_compress_opt.select(compress)
	_compress_opt.tooltip_text = "结构视图的压缩方式：行内合并把小的纯标量子树摊在一行；\n重复收缩再把连续同构的一段收成一行"
	_compress_opt.item_selected.connect(_on_compress_selected)
	bar.add_child(_compress_opt)

	_depth_opt = OptionButton.new()
	_depth_opt.add_item("只看根", 0)
	_depth_opt.add_item("展开 2 层", 1)
	_depth_opt.add_item("展开 3 层", 2)
	_depth_opt.add_item("展开 4 层", 3)
	_depth_opt.add_item("全部展开", 4)
	_depth_opt.select(1)
	_depth_opt.tooltip_text = "默认展开深度；卡片视图下等于「全部展开 / 全部折叠」"
	_depth_opt.item_selected.connect(_on_depth_selected)
	bar.add_child(_depth_opt)

	bar.add_child(VSeparator.new())
	_view_opt = OptionButton.new()
	_view_opt.add_item("卡片视图", 0)
	_view_opt.add_item("结构视图", 1)
	_view_opt.select(0)
	_view_opt.visible = false
	_view_opt.tooltip_text = "卡片视图 = 按这个文件的格式渲染；结构视图 = 原始 JSON 树"
	_view_opt.item_selected.connect(_on_view_selected)
	bar.add_child(_view_opt)

	bar.add_child(VSeparator.new())
	_edit_query = LineEdit.new()
	_edit_query.placeholder_text = "搜索键 / 值…（回车跳到下一个）"
	_edit_query.clear_button_enabled = true
	_edit_query.custom_minimum_size = Vector2(200, 0)
	_edit_query.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_query.text_changed.connect(_on_query_changed)
	_edit_query.text_submitted.connect(_on_query_submitted)
	bar.add_child(_edit_query)

	var btn_prev := Button.new()
	btn_prev.text = "◀"
	btn_prev.tooltip_text = "上一个匹配"
	btn_prev.pressed.connect(func(): _step_hit(-1))
	bar.add_child(btn_prev)

	var btn_next := Button.new()
	btn_next.text = "▶"
	btn_next.tooltip_text = "下一个匹配"
	btn_next.pressed.connect(func(): _step_hit(1))
	bar.add_child(btn_next)

	_lbl_hits = _make_label("")
	_lbl_hits.custom_minimum_size = Vector2(80, 0)
	bar.add_child(_lbl_hits)

	bar.add_child(VSeparator.new())
	_font_opt = OptionButton.new()
	for i in FONT_SIZES.size():
		_font_opt.add_item(str(FONT_SIZES[i]), i)
	_font_opt.select(2)
	_font_opt.tooltip_text = "字号"
	_font_opt.item_selected.connect(_on_font_selected)
	bar.add_child(_font_opt)

	# ---------------- 两个视图 + 详情
	_split = VSplitContainer.new()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.add_theme_constant_override("separation", 4)
	root.add_child(_split)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.custom_minimum_size = Vector2(0, 200)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_split.add_child(_scroll)

	_rows = RowsView.new()
	_rows.name = "Rows"
	_scroll.add_child(_rows)
	_rows.configure(_scroll)
	_rows.selection_changed.connect(_on_selection_changed)
	_rows.row_activated.connect(_on_row_activated)
	_rows.edit_requested.connect(_on_edit_requested)

	_cards_scroll = ScrollContainer.new()
	_cards_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_cards_scroll.custom_minimum_size = Vector2(0, 200)
	_cards_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_cards_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_cards_scroll.visible = false
	_split.add_child(_cards_scroll)

	_cards = CardsView.new()
	_cards.name = "Cards"
	_cards_scroll.add_child(_cards)
	_cards.configure(_cards_scroll)
	_cards.selection_changed.connect(_on_cards_selection)
	_cards.edit_requested.connect(_on_edit_requested)

	var detail := VBoxContainer.new()
	detail.custom_minimum_size = Vector2(0, 150)
	detail.add_theme_constant_override("separation", 2)
	_split.add_child(detail)

	var dbar := HBoxContainer.new()
	dbar.add_theme_constant_override("separation", 4)
	detail.add_child(dbar)

	_lbl_meta = _make_label("未选中节点")
	_lbl_meta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_meta.clip_text = true
	dbar.add_child(_lbl_meta)

	var btn_copy_path := Button.new()
	btn_copy_path.text = "复制路径"
	btn_copy_path.pressed.connect(_copy_path)
	dbar.add_child(btn_copy_path)

	var btn_copy_json := Button.new()
	btn_copy_json.text = "复制 JSON"
	btn_copy_json.pressed.connect(_copy_json)
	dbar.add_child(btn_copy_json)

	_edit_row = HBoxContainer.new()
	_edit_row.add_theme_constant_override("separation", 4)
	detail.add_child(_edit_row)

	_type_opt = OptionButton.new()
	for i in EDIT_LABELS.size():
		_type_opt.add_item(EDIT_LABELS[i], i)
	_type_opt.custom_minimum_size = Vector2(84, 0)
	_type_opt.item_selected.connect(_on_type_selected)
	_edit_row.add_child(_type_opt)

	_val_edit = LineEdit.new()
	_val_edit.placeholder_text = "选中一个标量节点后可在这里修改"
	_val_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_val_edit.text_submitted.connect(func(_t): _apply_edit())
	_edit_row.add_child(_val_edit)

	var btn_apply := Button.new()
	btn_apply.text = "应用"
	btn_apply.pressed.connect(_apply_edit)
	_edit_row.add_child(btn_apply)

	_btn_delete = Button.new()
	_btn_delete.text = "删除"
	_btn_delete.tooltip_text = "把这个节点从父节点里删掉（可撤销）"
	_btn_delete.pressed.connect(_delete_selected)
	_edit_row.add_child(_btn_delete)

	_edit_detail = TextEdit.new()
	_edit_detail.editable = false
	_edit_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_edit_detail.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_edit_detail.scroll_fit_content_height = false
	detail.add_child(_edit_detail)

	# ---------------- 状态栏
	var status := HBoxContainer.new()
	status.add_theme_constant_override("separation", 8)
	root.add_child(status)

	_lbl_file = _make_label("未打开文件")
	_lbl_file.clip_text = true
	_lbl_file.custom_minimum_size = Vector2(200, 0)
	status.add_child(_lbl_file)

	_lbl_status = _make_label("")
	_lbl_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_status.clip_text = true
	status.add_child(_lbl_status)

	# ---------------- 对话框
	if Engine.is_editor_hint():
		_dialog = EditorFileDialog.new()
	else:
		_dialog = FileDialog.new()
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.title = "选择 JSON 文件"
	_dialog.add_filter("*.json, *.jsonl, *.txt, *.cfg, *.tres", "JSON / 文本文件")
	_dialog.file_selected.connect(open_path)
	add_child(_dialog)

	_confirm = ConfirmationDialog.new()
	_confirm.title = "有未保存的修改"
	_confirm.dialog_text = "当前文件还有未保存的修改，确定要丢弃并继续吗？"
	_confirm.ok_button_text = "丢弃并继续"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(_on_discard_confirmed)
	add_child(_confirm)

	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.28
	_search_timer.timeout.connect(_run_search)
	add_child(_search_timer)


func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _apply_theme() -> void:
	var base := Color(0.85, 0.85, 0.85)
	if has_theme_color("font_color", "Label"):
		base = get_theme_color("font_color", "Label")
	var dark := base.get_luminance() > 0.5
	_rows.apply_palette(dark)
	if _cards != null:
		_cards.apply_palette(dark)
	_apply_font()


func _apply_font() -> void:
	var f: Font = SystemFont.new()
	f.font_names = PackedStringArray([
		"Cascadia Mono", "Consolas", "JetBrains Mono", "Fira Code",
		"Menlo", "DejaVu Sans Mono", "Noto Sans Mono", "Sarasa Mono SC",
		"Microsoft YaHei UI", "Courier New", "monospace",
	])
	f.allow_system_fallback = true
	if f.get_height(font_size) <= 0.0:
		f = ThemeDB.fallback_font
	_edit_detail.add_theme_font_override("font", f)
	_edit_detail.add_theme_font_size_override("font_size", font_size)
	_rows.font = f
	_rows.font_size = font_size
	_rows.refresh_metrics()
	if _cards != null:
		_cards.font = f
		_cards.font_size = font_size
		_cards.refresh_metrics()


# ------------------------------------------------------------------ 打开 / 解析

func open_path(path: String) -> void:
	if path.is_empty():
		return
	if dirty and path != current_path:
		_pending_open = path
		_confirm.popup_centered()
		return
	_do_open(path)


func _do_open(path: String) -> void:
	current_path = path
	dirty = false
	_undo.clear()
	_lbl_file.text = path.get_file()
	_lbl_file.tooltip_text = path
	_save_last_path(path)
	_remember_dir(path)
	_cancel_scan()
	_edit_query.text = ""
	query = ""
	_lbl_hits.text = ""
	_detail_clear()
	model = null
	_sel_id = -1
	_profile = {}
	_rows.set_model(null)
	_cards.set_source(null, {})
	_view_opt.visible = false
	_set_cards_mode(false)
	_loading = true
	_lbl_status.text = "读取中…"
	loader.start_load(path)


func _on_open_pressed() -> void:
	_dialog.popup_centered_ratio(0.62)


func _on_reload_pressed() -> void:
	if current_path == "":
		return
	if dirty:
		_pending_open = current_path
		_confirm.popup_centered()
		return
	_do_open(current_path)


func _on_discard_confirmed() -> void:
	if _pending_open != "":
		var p := _pending_open
		_pending_open = ""
		_do_open(p)


func _process(_delta: float) -> void:
	if loader == null:
		return
	if _scan_active:
		_step_scan()
		return
	if loader.is_busy():
		var p: int = loader.get_progress()
		_lbl_status.text = "解析中…  已构建 %s 个节点" % _fmt(p)
		return
	var res: Dictionary = loader.take()
	if res.is_empty():
		return
	_handle_result(res)


func _handle_result(res: Dictionary) -> void:
	var err: String = res["error"]
	if err != "":
		_loading = false
		_lbl_status.text = "打开失败：" + err
		push_warning("JSON Lens: " + err)
		return
	model = res["model"]
	_loading = false
	_sel_id = -1
	_cancel_scan()
	_rows.set_compress(compress)
	_rows.set_model(model)
	_rows.expand_to_depth(default_depth)

	# 格式识别：命中「条目集合 → 条目 → [kind,text] 事件」这种形态就切到卡片视图
	_profile = Schema.detect(model)
	if _profile.is_empty():
		_cards.set_source(null, {})
		_view_opt.visible = false
		_set_cards_mode(false)
		_lbl_status.text = "%s 字符 · %s 个节点 · 解析 %.2f 秒" % [
			_fmt(model.source_chars), _fmt(model.total), float(res["ms"]) / 1000.0]
	else:
		_cards.set_source(model, _profile)
		_view_opt.visible = true
		_view_opt.select(0)
		_set_cards_mode(true)
		_lbl_status.text = "%s 字符 · %s 张卡 · 解析 %.2f 秒 · %s" % [
			_fmt(model.source_chars), _fmt(int(_profile["count"])),
			float(res["ms"]) / 1000.0, _profile["name"]]
	_update_edit_buttons()


# ------------------------------------------------------------------ 视图切换

func _on_view_selected(index: int) -> void:
	_set_cards_mode(index == 0)


func _set_cards_mode(on: bool) -> void:
	_cards_mode = on and not _profile.is_empty()
	if _scroll != null:
		_scroll.visible = not _cards_mode
	if _cards_scroll != null:
		_cards_scroll.visible = _cards_mode
	if _cards == null:
		return
	if _cards_mode:
		_cards.set_selected(_sel_id)
	elif _sel_id >= 0 and _rows.model != null:
		_rows.select_node(_sel_id)


func _rebuild_views() -> void:
	if _rows != null and _rows.model != null:
		_rows.rebuild()
	if _cards != null and _cards.model != null:
		_cards.rebuild()


# ------------------------------------------------------------------ 选中

func _on_selection_changed(id: int) -> void:
	_apply_selection(id, false)


func _on_cards_selection(id: int) -> void:
	_apply_selection(id, true)


func _apply_selection(id: int, from_cards: bool) -> void:
	_sel_id = id
	if not _syncing:
		_syncing = true
		if from_cards:
			if _rows != null and _rows.model != null:
				_rows.select_node(id, false)
		elif _cards != null and _cards.model != null:
			_cards.set_selected(id)
		_syncing = false
	_show_detail(id)


func _show_detail(id: int) -> void:
	if model == null or id < 0:
		_detail_clear()
		return
	var path: String = model.path_of(id)
	if model.is_container(id):
		_lbl_meta.text = "%s  ·  %s  ·  %s" % [model.type_label(id), model.count_label(id), path]
		_edit_detail.text = model.to_json(id, 200000)
		_edit_row.visible = false
	else:
		_lbl_meta.text = "%s  ·  %s" % [model.type_label(id), path]
		_edit_detail.text = model.texts[id]
		_edit_row.visible = true
		_sync_editor(id)
	_update_edit_buttons()
	_refresh_status()


func _detail_clear() -> void:
	_lbl_meta.text = "未选中节点"
	_edit_detail.text = ""
	_edit_row.visible = false
	_update_edit_buttons()


# ------------------------------------------------------------------ 编辑

func _mark_dirty() -> void:
	dirty = true
	_update_title()


func _update_title() -> void:
	var name := current_path.get_file() if current_path != "" else "未打开文件"
	_lbl_file.text = ("● " + name) if dirty else name


func _update_edit_buttons() -> void:
	var has_model: bool = model != null and _sel_id >= 0
	var scalar: bool = has_model and not model.is_container(_sel_id)
	if _btn_save != null:
		_btn_save.disabled = not dirty or current_path == ""
	if _btn_undo != null:
		_btn_undo.disabled = _undo.size() == 0
	if _btn_delete != null:
		_btn_delete.disabled = not has_model
	if _val_edit != null:
		_val_edit.editable = scalar
	if _type_opt != null:
		_type_opt.disabled = not scalar


func _sync_editor(id: int) -> void:
	_syncing_editor = true
	var k: int = model.kinds[id]
	var idx := EDIT_KINDS.find(k)
	_type_opt.select(idx if idx >= 0 else 0)
	_val_edit.text = model.texts[id] if k != Model.K_NULL else "null"
	_syncing_editor = false


func _on_type_selected(_index: int) -> void:
	if _syncing_editor:
		return
	if model == null or _sel_id < 0:
		return
	# 切类型时先按新类型校验一次，不合法就换成该类型的占位值
	var want: int = EDIT_KINDS[_type_opt.selected]
	if Model.parse_literal(_val_edit.text, want).is_empty():
		match want:
			Model.K_STRING:
				_val_edit.text = ""
			Model.K_NUMBER:
				_val_edit.text = "0"
			Model.K_BOOL:
				_val_edit.text = "true"
			_:
				_val_edit.text = "null"


func _apply_edit() -> void:
	if model == null or _sel_id < 0:
		return
	var id: int = _sel_id
	if model.is_container(id):
		return
	var want: int = EDIT_KINDS[_type_opt.selected]
	var res: Array = Model.parse_literal(_val_edit.text, want)
	if res.is_empty():
		_lbl_status.text = "值不合法：%s 需要输入%s" % [_val_edit.text, EDIT_LABELS[_type_opt.selected]]
		return
	_undo.append(model.set_scalar(id, res[0], res[1]))
	if _undo.size() > MAX_UNDO:
		_undo.pop_front()
	_mark_dirty()
	_rebuild_views()
	_apply_selection(id, false)
	_lbl_status.text = "已修改 %s" % model.path_of(id)
	_update_edit_buttons()


func _delete_selected() -> void:
	if model == null or _sel_id < 0:
		return
	var id: int = _sel_id
	var info: Dictionary = model.unlink(id)
	if info.is_empty():
		_lbl_status.text = "根节点不能删除"
		return
	_undo.append(info)
	if _undo.size() > MAX_UNDO:
		_undo.pop_front()
	_mark_dirty()
	var p: int = info["parent"]
	_rebuild_views()
	_apply_selection(p, false)
	_lbl_status.text = "已删除一个节点（可撤销）"
	_update_edit_buttons()


func _on_undo_pressed() -> void:
	if _undo.is_empty() or model == null:
		return
	var info: Dictionary = _undo.pop_back()
	var target: int = int(info["id"])
	model.undo(info)
	_mark_dirty()
	_rebuild_views()
	_apply_selection(target, false)
	_lbl_status.text = "已撤销"
	_update_edit_buttons()


func _on_edit_requested(id: int) -> void:
	if model == null or model.is_container(id):
		return
	_sel_id = id
	_val_edit.grab_focus()
	_val_edit.select_all()


func _on_save_pressed() -> void:
	if model == null:
		return
	if current_path == "":
		_lbl_status.text = "没有可保存的路径"
		return
	_lbl_status.text = "保存中…"
	await get_tree().process_frame
	var text: String = model.to_json(model.root, -1)
	var f := FileAccess.open(current_path, FileAccess.WRITE)
	if f == null:
		_lbl_status.text = "保存失败：%s" % error_string(FileAccess.get_open_error())
		return
	f.store_string(text)
	f.close()
	dirty = false
	_undo.clear()
	_update_title()
	_update_edit_buttons()
	_lbl_status.text = "已保存 %s（%s 字符）" % [current_path.get_file(), _fmt(text.length())]


# ------------------------------------------------------------------ 搜索
#
# 搜索刻意放在主线程「分帧扫描」而不是丢进 WorkerThreadPool：
# 实测（见 tests/thread_probe.gd）在 Godot 4.7 上，让工作线程去读一个
# GDScript 脚本对象（RefCounted）的成员，即使只是只读，也会在退出时崩坏。
# 分帧扫描既避开了这个坑，又天然可取消、可显示进度，UI 依然不卡。

func _on_query_changed(text: String) -> void:
	query = text.strip_edges()
	if query.is_empty():
		if _search_timer != null:
			_search_timer.stop()
		_cancel_scan()
		_lbl_hits.text = ""
		_rows.query = ""
		_rows.show_tree()
		_cards.set_query("")
		return
	_search_timer.start()


func _run_search() -> void:
	if model == null or query == "":
		return
	_rows.query = query
	_cards.set_query(query)
	_scan_active = true
	_scan_pos = 0
	_scan_hits = PackedInt32Array()
	_scan_truncated = false
	_scan_lower = query.to_lower()
	_scan_t0 = int(Time.get_ticks_msec())
	_lbl_hits.text = "搜索中…"


func _cancel_scan() -> void:
	_scan_active = false
	_scan_pos = 0
	_scan_hits = PackedInt32Array()


## 每帧只扫一小段，保证编辑器始终有响应。
func _step_scan() -> void:
	if not _scan_active or model == null:
		return
	var total: int = model.total
	var end := mini(total, _scan_pos + SCAN_PER_FRAME)
	var q := _scan_lower
	var hits := _scan_hits
	for i in range(_scan_pos, end):
		var hit := false
		if model.kinds[i] != Model.K_OBJECT:
			var key: String = model.keys[i]
			if key != "" and key.findn(q) >= 0:
				hit = true
		if not hit:
			var txt: String = model.texts[i]
			if txt != "" and txt.findn(q) >= 0:
				hit = true
		if hit:
			hits.append(i)
			if hits.size() >= MAX_HITS:
				_scan_truncated = true
				end = total
				break
	_scan_hits = hits
	_scan_pos = end
	if _scan_pos >= total:
		_finish_scan()
	else:
		_lbl_status.text = "搜索中…  已扫描 %s / %s 个节点" % [_fmt(_scan_pos), _fmt(total)]


func _finish_scan() -> void:
	_scan_active = false
	var hits := _scan_hits
	if query == "":
		return
	_rows.set_compress(compress)
	_rows.set_search(model, hits, query)
	_cards.set_query(query)
	var ms := int(Time.get_ticks_msec()) - _scan_t0
	if hits.is_empty():
		_lbl_hits.text = "0 结果"
	elif _scan_truncated:
		_lbl_hits.text = "前 %s 结果" % _fmt(hits.size())
	else:
		_lbl_hits.text = "%s 结果" % _fmt(hits.size())
	_lbl_status.text = "搜索「%s」：%s 个匹配 · %.2f 秒" % [query, _fmt(hits.size()), float(ms) / 1000.0]


func _on_query_submitted(_text: String) -> void:
	_step_hit(1)


func _step_hit(delta: int) -> void:
	# 还在分帧扫描中就先跑完，避免跳到半个结果集上
	while _scan_active:
		_step_scan()
	if not _rows.search_mode:
		if query != "":
			_search_timer.stop()
			_run_search()
			while _scan_active:
				_step_scan()
		return
	var n: int = _rows.rows.size()
	if n == 0:
		return
	var cur: int = _rows.selected_row
	var nxt := 0
	if cur < 0:
		nxt = 0 if delta >= 0 else n - 1
	else:
		nxt = (cur + delta + n) % n
	var id: int = _rows.rows[nxt]
	_rows._select_row(nxt)
	_apply_selection(id, false)


func _on_row_activated(id: int) -> void:
	if model == null:
		return
	if _cards_mode:
		_cards.reveal_node(id)
	else:
		_rows.reveal_node(id)
	_sel_id = id


# ------------------------------------------------------------------ 工具栏回调

func _on_depth_selected(index: int) -> void:
	default_depth = DEPTHS[index]
	if model == null or _loading:
		return
	if _cards_mode:
		if DEPTHS[index] >= 1048576:
			_cards.expand_all()
		else:
			_cards.collapse_all()
		return
	_rows.expand_to_depth(default_depth)


func _on_compress_selected(index: int) -> void:
	compress = index
	if model != null:
		_rows.set_compress(compress)
		_rows.rebuild()


func _on_font_selected(index: int) -> void:
	font_size = FONT_SIZES[index]
	_apply_font()


func _copy_path() -> void:
	if model == null or _sel_id < 0:
		return
	DisplayServer.clipboard_set(model.path_of(_sel_id))


func _copy_json() -> void:
	if model == null or _sel_id < 0:
		return
	var id: int = _sel_id
	if model.is_container(id):
		DisplayServer.clipboard_set(model.to_json(id, 4194304))
	else:
		DisplayServer.clipboard_set(model.texts[id])


# ------------------------------------------------------------------ 杂项

func _refresh_status() -> void:
	if model == null:
		return
	if _cards_mode:
		_lbl_status.text = "%s 字符 · %s 张卡 · 可见 %s 行%s" % [
			_fmt(model.source_chars), _fmt(int(_profile.get("count", 0))),
			_fmt(_cards.row_entry.size()), "  ·  ● 未保存" if dirty else ""]
		return
	_lbl_status.text = "%s 字符 · %s 个节点 · 可见 %s 行%s" % [
		_fmt(model.source_chars), _fmt(model.total), _fmt(_rows.rows.size()),
		"  ·  ● 未保存" if dirty else ""
	]


func _fmt(n: int) -> String:
	var out := ""
	var c := 0
	var s := str(absi(n))
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


func _can_drop_data(_pos: Vector2, data) -> bool:
	if data is Dictionary and data.get("type", "") == "files":
		var files = data.get("files", PackedStringArray())
		return files is PackedStringArray and files.size() > 0
	return false


func _drop_data(_pos: Vector2, data) -> void:
	if _can_drop_data(_pos, data):
		var files: PackedStringArray = data["files"]
		for f in files:
			if f.to_lower().ends_with(".json") or f.to_lower().ends_with(".jsonl"):
				open_path(f)
				return
		if files.size() > 0:
			open_path(files[0])


## 「上次打开的文件」用普通 ConfigFile 存在 user://，
## 这样不依赖 EditorInterface / EditorSettings 的具体版本 API。
func _load_last_path() -> String:
	var cf := ConfigFile.new()
	if cf.load(CONFIG_PATH) != OK:
		return ""
	return str(cf.get_value("json_lens", "last_path", ""))


func _save_last_path(path: String) -> void:
	var cf := ConfigFile.new()
	cf.load(CONFIG_PATH)
	cf.set_value("json_lens", "last_path", path)
	cf.save(CONFIG_PATH)


func _remember_dir(path: String) -> void:
	if _dialog != null:
		_dialog.current_dir = path.get_base_dir()
