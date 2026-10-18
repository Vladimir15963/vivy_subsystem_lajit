extends Control

## 通用 shader 效果预览 —— 主控制器。
##
## 交互跑：`godot --path "L:\项目\测试" shader_preview_test/shader_preview.tscn`
##
## 它只做三件事：
##   1. 把 `shaders/` 里的 .gdshader 列出来，选一个挂到预览用的 TextureRect 上；
##   2. 按 uniform 列表自动生成参数面板（见 shader_param_panel.gd），改一下就实时生效；
##   3. 每帧喂 `time`，并把 `src_tex` / `texel_size` 按当前源图绑定好。
##
## 约定：shader 里可以随便声明 uniform，但下面三个名字是**保留**的，由预览器自动绑定，
## 不会出现在参数面板里：
##   `src_tex`(sampler2D) 源图 · `texel_size`(vec2) 1/源图尺寸 · `time`(float) 秒
##
## 因为 UI 全部代码构建，这个子系统天然可以单独拷走：只依赖 shaders/ 与 scripts/。

const Library := preload("res://subsystem/shader_preview/scripts/shader_library.gd")
const Sources := preload("res://subsystem/shader_preview/scripts/preview_sources.gd")
const ParamPanel := preload("res://subsystem/shader_preview/scripts/shader_param_panel.gd")

const PRESET_DIR := "user://shader_preview_test/presets"
const SHOT_DIR := "user://shader_preview_test/shots"
const CHECKER_CELL := 8
const CHECKER_SIZE := 16
const SIDE_WIDTH := 392

signal effect_changed(path: String)
signal source_changed(index: int)

# ------------------------------------------------------------------ 内部状态

var _effects: Array = []
var _sources: Array = []
var _effect_index := -1
var _source_index := -1
var _time := 0.0
var _playing := true
var _time_scale := 1.0
var _fps := 0.0
var _fps_timer := 0.0

var _material: ShaderMaterial

# ------------------------------------------------------------------ 界面节点

var _effect_option: OptionButton
var _source_option: OptionButton
var _note_label: Label
var _status_label: Label
var _playing_check: CheckBox
var _time_scale_slider: HSlider
var _time_scale_label: Label
var _filter_edit: LineEdit
var _preset_name_edit: LineEdit
var _preset_option: OptionButton
var _preset_status: Label
var _backdrop: TextureRect
var _preview_rect: TextureRect
var _param_panel: VBoxContainer
var _file_dialog: FileDialog


# ------------------------------------------------------------------ 生命周期

func _ready() -> void:
	_build_ui()

	_effects = Library.list_effects()
	_sources = Sources.build_all()
	_reload_effect_options()
	_reload_source_options()
	_refresh_presets()

	if _sources.is_empty():
		_set_status("没有可用源图")
	else:
		set_source_index(0)

	if _effects.is_empty():
		_set_status("shaders/ 里没有 .gdshader")
	else:
		set_effect_index(0)


func _process(delta: float) -> void:
	tick(delta)
	_fps_timer += delta
	if _fps_timer >= 0.25:
		_fps_timer = 0.0
		_fps = Engine.get_frames_per_second()
		_update_status()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_SPACE:
			set_playing(not _playing)
			_sync_time_ui()
		KEY_R:
			_on_reset_pressed()
		KEY_S:
			_on_random_pressed()
		KEY_BRACKETLEFT:
			_cycle_effect(-1)
		KEY_BRACKETRIGHT:
			_cycle_effect(1)
		KEY_F12:
			save_preview_snapshot()


# ------------------------------------------------------------------ 公有 API

func effects() -> Array:
	return _effects


func sources() -> Array:
	return _sources


func current_effect_index() -> int:
	return _effect_index


func current_source_index() -> int:
	return _source_index


func current_effect() -> Dictionary:
	if _effect_index < 0 or _effect_index >= _effects.size():
		return {}
	return _effects[_effect_index]


func current_effect_path() -> String:
	return String(current_effect().get("path", ""))


func shader() -> Shader:
	return _material.shader if _material != null else null


## 注意：名字不叫 `material()`，因为 CanvasItem 本来就有 `material` 属性，
## 同名方法在静态类型检查里会被当成属性取值。
func shader_material() -> ShaderMaterial:
	return _material


func preview_rect() -> TextureRect:
	return _preview_rect


func param_panel() -> VBoxContainer:
	return _param_panel


func preview_texture() -> Texture2D:
	return _preview_rect.texture if _preview_rect != null else null


func is_playing() -> bool:
	return _playing


func set_playing(value: bool) -> void:
	_playing = value
	if _playing_check != null:
		_playing_check.set_pressed_no_signal(value)


func time_value() -> float:
	return _time


func time_scale() -> float:
	return _time_scale


func set_time_scale(value: float) -> void:
	_time_scale = maxf(value, 0.0)
	if _time_scale_slider != null:
		_time_scale_slider.set_value_no_signal(_time_scale)
	_sync_time_ui()


func set_texture_filter_nearest(nearest: bool) -> void:
	if _preview_rect == null:
		return
	_preview_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if nearest \
		else CanvasItem.TEXTURE_FILTER_LINEAR


## 推进动画时间；返回是否真的走了时间（暂停/0 时长时为 false）。
func tick(delta: float) -> bool:
	var advanced := false
	if _playing and delta > 0.0:
		_time += delta * _time_scale
		advanced = true
	if _material != null:
		_material.set_shader_parameter("time", _time)
	return advanced


func set_effect_index(index: int) -> bool:
	if index < 0 or index >= _effects.size():
		return false
	var path := String(_effects[index]["path"])
	var sh: Shader = null
	if ResourceLoader.exists(path):
		sh = load(path)
	if sh == null:
		_set_status("shader 加载失败：%s" % path)
		return false

	_effect_index = index
	_time = 0.0

	var mat := ShaderMaterial.new()
	mat.shader = sh
	_material = mat
	_preview_rect.material = mat

	if _param_panel != null:
		_param_panel.build(sh)
	_write_all_params()
	_apply_reserved()
	_sync_effect_ui()
	_update_status()
	effect_changed.emit(path)
	return true


func set_source_index(index: int) -> bool:
	if index < 0 or index >= _sources.size():
		return false
	_source_index = index
	_preview_rect.texture = _sources[index]["texture"]
	_apply_reserved()
	_sync_source_ui()
	_update_status()
	source_changed.emit(index)
	return true


## 追加一张源图并选中它；返回索引（失败 -1）。
func add_source(label: String, tex: Texture2D) -> int:
	if tex == null:
		return -1
	_sources.append(Sources.entry(label, tex))
	_source_index = _sources.size() - 1
	_reload_source_options()
	set_source_index(_source_index)
	return _source_index


func load_image_file(path: String) -> int:
	var img := Image.new()
	if img.load(path) != OK:
		_set_status("读不了图片：%s" % path)
		return -1
	return add_source(path.get_file(), ImageTexture.create_from_image(img))


## 抓预览区当前的画面（需要真实窗口 —— headless 下没有可读的 framebuffer）。
func capture_preview_image() -> Image:
	var vp := get_viewport()
	if vp == null:
		return null
	var full := vp.get_texture().get_image()
	if full == null or full.is_empty():
		return null

	var vp_size := vp.get_visible_rect().size
	var sx := float(full.get_width()) / maxf(vp_size.x, 1.0)
	var sy := float(full.get_height()) / maxf(vp_size.y, 1.0)
	var rect := _preview_rect.get_global_rect()
	var region := Rect2i(
		int(rect.position.x * sx), int(rect.position.y * sy),
		int(rect.size.x * sx), int(rect.size.y * sy)
	)
	region = region.intersection(Rect2i(Vector2i.ZERO, full.get_size()))
	if region.size.x <= 0 or region.size.y <= 0:
		return full
	return full.get_region(region)


## 把预览区存成 PNG（res:// 与 user:// 都行，目录会自动建）。
func save_preview_png(path: String) -> bool:
	var img := capture_preview_image()
	if img == null:
		_set_status("截图失败：当前没有可读画面（headless 下拿不到 framebuffer）")
		return false
	var dir := path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(dir)
	if img.save_png(path) != OK:
		_set_status("截图保存失败：%s" % path)
		return false
	_set_status("截图已保存：%s" % path)
	return true


## 界面上「截图」按钮的落点：user:// 下按 效果_时间戳 命名。
func save_preview_snapshot() -> bool:
	var shot_name := "%s_%s.png" % [
		current_effect_path().get_file().get_basename(),
		Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_"),
	]
	return save_preview_png(SHOT_DIR + "/" + shot_name)


# ------------------------------------------------------------------ 状态导出

func export_state() -> Dictionary:
	var params := {}
	if _param_panel != null:
		var values: Dictionary = _param_panel.get_values()
		for key in values:
			params[key] = encode_value(values[key])
	return {
		"effect": current_effect_path(),
		"source": current_source_name(),
		"time": _time,
		"time_scale": _time_scale,
		"playing": _playing,
		"params": params,
	}


func import_state(state: Dictionary) -> bool:
	var index := _effect_index_of(String(state.get("effect", "")))
	if index < 0:
		return false
	if not set_effect_index(index):
		return false

	var source_index := _source_index_of(String(state.get("source", "")))
	if source_index >= 0:
		set_source_index(source_index)

	if _param_panel != null and state.has("params"):
		var raw: Dictionary = state["params"]
		var decoded := {}
		for key in raw:
			decoded[key] = decode_value(raw[key])
		_param_panel.apply_values(decoded, true)

	_time = float(state.get("time", 0.0))
	set_time_scale(float(state.get("time_scale", 1.0)))
	set_playing(bool(state.get("playing", true)))
	_apply_reserved()
	_update_status()
	return true


func current_source_name() -> String:
	if _source_index < 0 or _source_index >= _sources.size():
		return ""
	return String(_sources[_source_index]["name"])


## 把当前参数导成可以贴回代码的文本。
func params_as_text() -> String:
	var lines := PackedStringArray()
	lines.append("# %s  ·  %s" % [String(current_effect().get("name", "-")), current_effect_path()])
	if _param_panel != null:
		var values: Dictionary = _param_panel.get_values()
		for key in values:
			lines.append("shader_material.set_shader_parameter(\"%s\", %s)" % [key, format_value(values[key])])
	return "\n".join(lines)


static func format_value(v: Variant) -> String:
	match typeof(v):
		TYPE_COLOR:
			var c: Color = v
			return "Color(%s, %s, %s, %s)" % [_num(c.r), _num(c.g), _num(c.b), _num(c.a)]
		TYPE_VECTOR2:
			var v2: Vector2 = v
			return "Vector2(%s, %s)" % [_num(v2.x), _num(v2.y)]
		TYPE_VECTOR3:
			var v3: Vector3 = v
			return "Vector3(%s, %s, %s)" % [_num(v3.x), _num(v3.y), _num(v3.z)]
		TYPE_VECTOR4:
			var v4: Vector4 = v
			return "Vector4(%s, %s, %s, %s)" % [_num(v4.x), _num(v4.y), _num(v4.z), _num(v4.w)]
		TYPE_BOOL:
			return "true" if bool(v) else "false"
		TYPE_INT:
			return str(int(v))
	return _num(float(v))


static func _num(x: float) -> String:
	return "%.4f" % x


## 把 Vector/Color 转成 JSON 能存的形状（Vector 在 JSON 里会退化成字符串）。
static func encode_value(v: Variant) -> Variant:
	match typeof(v):
		TYPE_VECTOR2:
			return {"t": "vec2", "v": [v.x, v.y]}
		TYPE_VECTOR3:
			return {"t": "vec3", "v": [v.x, v.y, v.z]}
		TYPE_VECTOR4:
			return {"t": "vec4", "v": [v.x, v.y, v.z, v.w]}
		TYPE_COLOR:
			return {"t": "color", "v": [v.r, v.g, v.b, v.a]}
	return v


static func decode_value(e: Variant) -> Variant:
	if not (e is Dictionary):
		return e
	var d: Dictionary = e
	if not d.has("t") or not d.has("v"):
		return e
	var a: Array = d["v"]
	match String(d["t"]):
		"vec2":
			return Vector2(a[0], a[1])
		"vec3":
			return Vector3(a[0], a[1], a[2])
		"vec4":
			return Vector4(a[0], a[1], a[2], a[3])
		"color":
			return Color(a[0], a[1], a[2], a[3])
	return e


# ------------------------------------------------------------------ 预设

func preset_names() -> Array:
	var out := []
	var d := DirAccess.open(PRESET_DIR)
	if d == null:
		return out
	for f in d.get_files():
		if String(f).ends_with(".json"):
			out.append(String(f).get_basename())
	out.sort()
	return out


func preset_path(preset_name: String) -> String:
	return "%s/%s.json" % [PRESET_DIR, sanitize_name(preset_name)]


func save_preset(preset_name: String) -> bool:
	var safe := sanitize_name(preset_name)
	if safe.is_empty():
		_set_preset_status("预设名不能为空")
		return false
	if DirAccess.make_dir_recursive_absolute(PRESET_DIR) != OK:
		_set_preset_status("建不了目录 %s" % PRESET_DIR)
		return false
	var f := FileAccess.open(preset_path(safe), FileAccess.WRITE)
	if f == null:
		_set_preset_status("写不了预设 %s" % safe)
		return false
	f.store_string(JSON.stringify(export_state(), "\t"))
	f.close()
	_refresh_presets(safe)
	_set_preset_status("已保存 %s" % safe)
	return true


func load_preset(preset_name: String) -> bool:
	var path := preset_path(preset_name)
	if not FileAccess.file_exists(path):
		_set_preset_status("没有预设 %s" % preset_name)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		_set_preset_status("预设 %s 解析失败" % preset_name)
		return false
	var ok := import_state(parsed)
	_set_preset_status("已加载 %s" % preset_name if ok else "预设与当前效果对不上")
	_refresh_presets(preset_name)
	return ok


func delete_preset(preset_name: String) -> bool:
	var path := preset_path(preset_name)
	if not FileAccess.file_exists(path):
		return false
	var err := DirAccess.remove_absolute(path)
	_refresh_presets()
	_set_preset_status("已删除 %s" % preset_name if err == OK else "删除 %s 失败" % preset_name)
	return err == OK


static func sanitize_name(raw_name: String) -> String:
	var re := RegEx.new()
	re.compile("[\\\\/:*?\"<>|\\s]+")
	var s := re.sub(raw_name.strip_edges(), "_", true).strip_edges()
	# 开头的点也去掉，免得拼出隐藏文件或 "." / ".." 这类名字
	while s.begins_with("."):
		s = s.substr(1)
	return s.strip_edges()


# ------------------------------------------------------------------ 内部

func _write_all_params() -> void:
	if _material == null or _param_panel == null:
		return
	var values: Dictionary = _param_panel.get_values()
	for key in values:
		_material.set_shader_parameter(key, values[key])


func _apply_reserved() -> void:
	if _material == null or _preview_rect == null:
		return
	var tex := preview_texture()
	_material.set_shader_parameter("src_tex", tex)
	var tex_size := Vector2.ZERO
	if tex != null:
		tex_size = Vector2(tex.get_size())
	_material.set_shader_parameter("texel_size", Vector2(
		1.0 / maxf(tex_size.x, 1.0),
		1.0 / maxf(tex_size.y, 1.0)
	))
	_material.set_shader_parameter("time", _time)


func _effect_index_of(path: String) -> int:
	for i in _effects.size():
		if String(_effects[i]["path"]) == path:
			return i
	return -1


func _source_index_of(key: String) -> int:
	for i in _sources.size():
		if String(_sources[i]["name"]) == key:
			return i
	return -1


func _cycle_effect(step: int) -> void:
	if _effects.is_empty():
		return
	var n := _effects.size()
	set_effect_index(posmod(_effect_index + step, n))


func _on_effect_selected(index: int) -> void:
	set_effect_index(index)


func _on_source_selected(index: int) -> void:
	set_source_index(index)


func _on_param_changed(uniform_name: String, value: Variant) -> void:
	if _material != null:
		_material.set_shader_parameter(uniform_name, value)


func _on_filter_changed(text: String) -> void:
	if _param_panel != null:
		_param_panel.set_filter(text)


func _on_reset_pressed() -> void:
	if _param_panel != null:
		_param_panel.reset_to_defaults(true)


func _on_random_pressed() -> void:
	if _param_panel != null:
		_param_panel.randomize_values(true)


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(params_as_text())
	_set_status("参数已复制到剪贴板")


func _on_snapshot_pressed() -> void:
	save_preview_snapshot()


func _on_playing_toggled(pressed: bool) -> void:
	_playing = pressed


func _on_time_scale_changed(value: float) -> void:
	_time_scale = value
	_sync_time_ui()


func _on_backdrop_toggled(pressed: bool) -> void:
	if _backdrop != null:
		_backdrop.visible = pressed


func _on_filter_toggled(pressed: bool) -> void:
	set_texture_filter_nearest(pressed)


func _on_open_image_pressed() -> void:
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.title = "选一张图片当源图"
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.add_filter("*.png,*.jpg,*.jpeg,*.webp,*.bmp,*.tga", "图片")
		_file_dialog.size = Vector2i(760, 520)
		_file_dialog.file_selected.connect(_on_image_selected)
		add_child(_file_dialog)
	_file_dialog.popup_centered()


func _on_image_selected(path: String) -> void:
	if load_image_file(path) < 0:
		return
	_set_status("已载入 %s" % path.get_file())


func _on_preset_save_pressed() -> void:
	save_preset(_preset_name_edit.text)


func _on_preset_load_pressed() -> void:
	if _preset_option.selected < 0:
		return
	load_preset(_preset_option.get_item_text(_preset_option.selected))


func _on_preset_delete_pressed() -> void:
	if _preset_option.selected < 0:
		return
	delete_preset(_preset_option.get_item_text(_preset_option.selected))


# ------------------------------------------------------------------ 界面刷新

func _reload_effect_options() -> void:
	_effect_option.clear()
	for e in _effects:
		_effect_option.add_item(String(e["name"]))
	_sync_effect_ui()


func _reload_source_options() -> void:
	_source_option.clear()
	for s in _sources:
		_source_option.add_item(String(s["name"]))
	_sync_source_ui()


func _sync_effect_ui() -> void:
	if _effect_option != null and _effect_index >= 0:
		_effect_option.select(_effect_index)
	if _note_label != null:
		var e := current_effect()
		if e.is_empty():
			_note_label.text = ""
		else:
			_note_label.text = "%s\n%s" % [String(e.get("note", "")), String(e.get("path", "")).get_file()]


func _sync_source_ui() -> void:
	if _source_option != null and _source_index >= 0:
		_source_option.select(_source_index)


func _sync_time_ui() -> void:
	if _playing_check != null:
		_playing_check.set_pressed_no_signal(_playing)
	if _time_scale_slider != null:
		_time_scale_slider.set_value_no_signal(_time_scale)
	if _time_scale_label != null:
		_time_scale_label.text = "%.2fx" % _time_scale


func _refresh_presets(select_name: String = "") -> void:
	if _preset_option == null:
		return
	_preset_option.clear()
	var names := preset_names()
	for n in names:
		_preset_option.add_item(String(n))
	if names.is_empty():
		# 空状态也要看得懂，否则那个空下拉框看着像坏了
		_preset_option.add_item("（还没有预设）")
		_preset_option.disabled = true
		return
	_preset_option.disabled = false
	var idx := names.find(select_name)
	_preset_option.select(maxi(idx, 0))


func _update_status() -> void:
	if _status_label == null:
		return
	var parts := PackedStringArray()
	parts.append(String(current_effect().get("name", "-")))
	var tex := preview_texture()
	if tex != null:
		var s := tex.get_size()
		parts.append("源图 %d×%d" % [int(s.x), int(s.y)])
	if _param_panel != null:
		parts.append("%d 个可调参数" % int(_param_panel.param_count()))
	parts.append("%.0f FPS" % _fps)
	parts.append("[空格]播放/暂停  [R]重置  [S]随机  [[] / ]] 切换效果  [F12]截图")
	_status_label.text = "  ·  ".join(parts)


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _set_preset_status(text: String) -> void:
	if _preset_status != null:
		_preset_status.text = text


# ------------------------------------------------------------------ 代码建 UI

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	custom_minimum_size = Vector2(900, 560)

	var root := VBoxContainer.new()
	root.name = "Layout"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	root.add_child(_build_top_bar())

	var body := HSplitContainer.new()
	body.name = "Body"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.split_offset = 560
	root.add_child(body)

	body.add_child(_build_stage())
	body.add_child(_build_side_panel())

	var status_panel := PanelContainer.new()
	root.add_child(status_panel)
	var status_margin := MarginContainer.new()
	status_margin.add_theme_constant_override("margin_left", 8)
	status_margin.add_theme_constant_override("margin_right", 8)
	status_margin.add_theme_constant_override("margin_top", 3)
	status_margin.add_theme_constant_override("margin_bottom", 3)
	status_panel.add_child(status_margin)
	_status_label = Label.new()
	_status_label.clip_text = true
	status_margin.add_child(_status_label)


func _build_top_bar() -> Control:
	var panel := PanelContainer.new()
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	# 第一行：选效果 / 选源图
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	box.add_child(row1)

	row1.add_child(_label("效果"))
	_effect_option = OptionButton.new()
	_effect_option.custom_minimum_size = Vector2(210, 0)
	_effect_option.item_selected.connect(_on_effect_selected)
	row1.add_child(_effect_option)

	row1.add_child(VSeparator.new())
	row1.add_child(_label("源图"))
	_source_option = OptionButton.new()
	_source_option.custom_minimum_size = Vector2(200, 0)
	_source_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_source_option.item_selected.connect(_on_source_selected)
	row1.add_child(_source_option)

	row1.add_child(_button("打开图片…", _on_open_image_pressed))
	row1.add_child(_button("重置", _on_reset_pressed))
	row1.add_child(_button("随机", _on_random_pressed))
	row1.add_child(_button("复制参数", _on_copy_pressed))
	row1.add_child(_button("截图", _on_snapshot_pressed))

	# 第二行：动画 / 显示选项
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	box.add_child(row2)

	_playing_check = CheckBox.new()
	_playing_check.text = "动画"
	_playing_check.button_pressed = _playing
	_playing_check.toggled.connect(_on_playing_toggled)
	row2.add_child(_playing_check)

	row2.add_child(_label("速度"))
	_time_scale_slider = HSlider.new()
	_time_scale_slider.min_value = 0.0
	_time_scale_slider.max_value = 4.0
	_time_scale_slider.step = 0.05
	_time_scale_slider.value = 1.0
	_time_scale_slider.custom_minimum_size = Vector2(140, 0)
	_time_scale_slider.value_changed.connect(_on_time_scale_changed)
	row2.add_child(_time_scale_slider)
	_time_scale_label = _label("1.00x")
	_time_scale_label.custom_minimum_size = Vector2(56, 0)
	row2.add_child(_time_scale_label)

	row2.add_child(VSeparator.new())
	var nearest := CheckBox.new()
	nearest.text = "最近邻过滤"
	nearest.tooltip_text = "关=线性过滤（默认）· 开=最近邻（看像素化/低分辨率观感）"
	nearest.toggled.connect(_on_filter_toggled)
	row2.add_child(nearest)

	var backdrop_check := CheckBox.new()
	backdrop_check.text = "棋盘底"
	backdrop_check.tooltip_text = "预览区背后的棋盘格，用来看 alpha 通道"
	backdrop_check.button_pressed = true
	backdrop_check.toggled.connect(_on_backdrop_toggled)
	row2.add_child(backdrop_check)

	return panel


func _build_stage() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(320, 0)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(margin)

	var stack := Control.new()
	stack.name = "PreviewStack"
	stack.clip_contents = true
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(stack)

	_backdrop = TextureRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.texture = _make_checker_texture()
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.stretch_mode = TextureRect.STRETCH_TILE
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.add_child(_backdrop)

	_preview_rect = TextureRect.new()
	_preview_rect.name = "Preview"
	_preview_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_preview_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.add_child(_preview_rect)

	return panel


func _build_side_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(SIDE_WIDTH, 0)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)

	_note_label = Label.new()
	_note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note_label.custom_minimum_size = Vector2(0, 44)
	box.add_child(_note_label)

	# 参数过滤
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 6)
	box.add_child(filter_row)
	filter_row.add_child(_label("过滤"))
	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "按参数名过滤，例如 blur / edge"
	_filter_edit.clear_button_enabled = true
	_filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter_edit.text_changed.connect(_on_filter_changed)
	filter_row.add_child(_filter_edit)

	# 参数区
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_param_panel = ParamPanel.new()
	_param_panel.name = "Params"
	_param_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_param_panel.param_changed.connect(_on_param_changed)
	scroll.add_child(_param_panel)

	# 预设
	box.add_child(HSeparator.new())
	var preset_title := HBoxContainer.new()
	preset_title.add_child(_label("预设（存到 user:// 下，JSON）"))
	box.add_child(preset_title)

	var preset_row1 := HBoxContainer.new()
	preset_row1.add_theme_constant_override("separation", 6)
	box.add_child(preset_row1)
	_preset_name_edit = LineEdit.new()
	_preset_name_edit.placeholder_text = "预设名"
	_preset_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_row1.add_child(_preset_name_edit)
	preset_row1.add_child(_button("保存", _on_preset_save_pressed))
	preset_row1.add_child(_button("删除", _on_preset_delete_pressed))

	var preset_row2 := HBoxContainer.new()
	preset_row2.add_theme_constant_override("separation", 6)
	box.add_child(preset_row2)
	_preset_option = OptionButton.new()
	_preset_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_row2.add_child(_preset_option)
	preset_row2.add_child(_button("加载", _on_preset_load_pressed))

	_preset_status = Label.new()
	_preset_status.clip_text = true
	box.add_child(_preset_status)

	return panel


@warning_ignore("integer_division")
func _make_checker_texture() -> ImageTexture:
	var img := Image.create_empty(CHECKER_SIZE, CHECKER_SIZE, false, Image.FORMAT_RGBA8)
	for y in CHECKER_SIZE:
		for x in CHECKER_SIZE:
			var on := ((x / CHECKER_CELL) + (y / CHECKER_CELL)) % 2 == 0
			img.set_pixel(x, y, Color(0.13, 0.13, 0.15) if on else Color(0.20, 0.20, 0.23))
	return ImageTexture.create_from_image(img)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	return b
