extends Node

## 通用 shader 效果预览 —— 无头测试。
##
## 运行方式：
##   godot --headless --path "L:\项目\测试" shader_preview_test/tests/shader_preview_test.tscn
##
## 覆盖：效果清单扫描、登记 shader 的保留 uniform、可调参数的 hint 合法性、
##       默认值解析（含错误表达式回落）、参数面板控件生成、参数读写往返、
##       效果切换、源图切换、动画时间推进、状态导出/导入、预设落盘读写、
##       以及默认值解析器的单元用例。
##
## 约定：所有「参数个数 / 值」都从 shader 与面板动态读取，不写死数字，
## 这样新增 shader 或改默认值都不会误报；最后用完整性哨兵确认用例跑全了。
##
## 注：`_preview` 故意不写静态类型 —— 预览器是动态加载的场景，
## 静态类型下 `_preview.material()` 之类会被解析成 CanvasItem 的属性。

const PreviewScene := preload("res://subsystem/shader_preview/shader_preview.tscn")
const Library := preload("res://subsystem/shader_preview/scripts/shader_library.gd")
const ParamPanel := preload("res://subsystem/shader_preview/scripts/shader_param_panel.gd")
const Sources := preload("res://subsystem/shader_preview/scripts/preview_sources.gd")

const PRESET_NAME := "smoke_预设A"
const PRESET_DIR := "user://shader_preview_test/presets"
const RESERVED := ["src_tex", "texel_size", "time"]
const PLAN := 14

var _passed := 0
var _failed := 0
var _ran := 0
var _preview


func _ready() -> void:
	print("=== 通用 shader 效果预览 · 无头测试 ===")

	_preview = PreviewScene.instantiate()
	add_child(_preview)

	_test_ui_built()
	_test_effect_catalog()
	_test_uniform_sanity()
	_test_default_values()
	_test_panel_controls()
	_test_param_roundtrip()
	_test_effect_switch()
	_test_source_switch()
	_test_animation()
	_test_state_roundtrip()
	_test_preset_io()
	_test_default_parser()
	_test_procedural_sources()
	_test_live_control_wiring()
	_test_sentinel()

	print("\n=== 结果：%d 通过 / %d 失败（用例组 %d/%d）===" % [_passed, _failed, _ran, PLAN])
	get_tree().quit(0 if _failed == 0 else 1)


# --------------------------------------------------------------------- 用例

## 1) 代码建 UI 成功：关键节点都在，预览节点挂上了 ShaderMaterial。
func _test_ui_built() -> void:
	_ran += 1
	_check("主布局 Layout 存在", _preview.get_node_or_null("Layout") != null)
	_check("左右分栏 Body 存在", _preview.get_node_or_null("Layout/Body") is HSplitContainer)
	_check("预览节点存在", _preview.preview_rect() != null)
	_check("参数面板存在", _preview.param_panel() != null)
	_check("预览挂的是 ShaderMaterial", _preview.preview_rect().material is ShaderMaterial)


## 2) 效果清单：目录里的 shader 全部能加载；登记效果还要声明三个保留 uniform。
func _test_effect_catalog() -> void:
	_ran += 1
	var files: Array = Library.scan_files()
	_check("shaders/ 至少 10 个 .gdshader", files.size() >= 10, "实际 %d" % files.size())

	var effects: Array = _preview.effects()
	_check("界面效果数 = 目录 shader 数", effects.size() == files.size(),
		"界面 %d / 目录 %d" % [effects.size(), files.size()])

	var bad_load := PackedStringArray()
	var missing_reserved := PackedStringArray()
	for e in effects:
		var path := String(e["path"])
		var sh: Shader = load(path) if ResourceLoader.exists(path) else null
		if sh == null:
			bad_load.append(path)
			continue
		# 预览契约（三个保留 uniform）只对登记在 ENTRIES 里的效果强制；
		# shader_capture 抓来的「自定义」shader 原样收录，只要求能加载。
		if not _is_registered(String(e["file"])):
			continue
		var names := _uniform_names(sh)
		for r in RESERVED:
			if not names.has(String(r)):
				missing_reserved.append("%s 缺 %s" % [path.get_file(), r])
	_check("每个 shader 都能 load", bad_load.is_empty(), ", ".join(bad_load))
	_check("每个登记效果都有 src_tex/texel_size/time", missing_reserved.is_empty(),
		", ".join(missing_reserved))


## 3) 参数声明合法性：滑块能建出来、枚举有候选、每个参数都写了默认值。
func _test_uniform_sanity() -> void:
	_ran += 1
	var no_default := PackedStringArray()
	var bad_range := PackedStringArray()
	var bad_enum := PackedStringArray()
	var too_few := PackedStringArray()

	for e in _preview.effects():
		var file := String(e["file"])
		if not _is_registered(file):
			continue
		var sh: Shader = load(String(e["path"]))
		var decls: Dictionary = ParamPanel.parse_declarations(sh.code)
		var editable := 0
		for u in sh.get_shader_uniform_list():
			var d: Dictionary = u
			var uniform_name := String(d["name"])
			if RESERVED.has(uniform_name) or int(d["type"]) == TYPE_OBJECT:
				continue
			editable += 1
			if not decls.has(uniform_name):
				no_default.append("%s.%s" % [file, uniform_name])
				continue
			if int(d["hint"]) == PROPERTY_HINT_ENUM:
				if String(d["hint_string"]).split(",").size() < 2:
					bad_enum.append("%s.%s" % [file, uniform_name])
			elif int(d["type"]) == TYPE_FLOAT or int(d["type"]) == TYPE_INT:
				var hint_string := String(d["hint_string"])
				if not hint_string.is_empty():
					var rng: Dictionary = ParamPanel.parse_range(hint_string)
					if rng.is_empty() or float(rng["step"]) <= 0.0:
						bad_range.append("%s.%s(%s)" % [file, uniform_name, hint_string])
		if editable < 2:
			too_few.append("%s=%d" % [file, editable])

	_check("每个可调参数都写了 = 默认值", no_default.is_empty(), ", ".join(no_default))
	_check("hint_range 的 min<max 且 step>0", bad_range.is_empty(), ", ".join(bad_range))
	_check("hint_enum 至少两个候选", bad_enum.is_empty(), ", ".join(bad_enum))
	_check("每个登记效果至少 2 个可调参数", too_few.is_empty(), ", ".join(too_few))


## 4) 默认值解析：类型对得上，数值落在 hint_range 内。
func _test_default_values() -> void:
	_ran += 1
	var type_mismatch := PackedStringArray()
	var out_of_range := PackedStringArray()

	for e in _preview.effects():
		var file := String(e["file"])
		if not _is_registered(file):
			continue
		var sh: Shader = load(String(e["path"]))
		var defaults: Dictionary = ParamPanel.parse_uniform_defaults(sh)
		for u in sh.get_shader_uniform_list():
			var d: Dictionary = u
			var uniform_name := String(d["name"])
			var type := int(d["type"])
			if RESERVED.has(uniform_name) or type == TYPE_OBJECT or not defaults.has(uniform_name):
				continue
			var v: Variant = defaults[uniform_name]
			if typeof(v) != type:
				type_mismatch.append("%s.%s: %d≠%d" % [file, uniform_name, typeof(v), type])
			var rng: Dictionary = ParamPanel.parse_range(String(d["hint_string"]))
			if not rng.is_empty() and (type == TYPE_FLOAT or type == TYPE_INT):
				var f := float(v)
				if f < float(rng["min"]) - 0.0001 or f > float(rng["max"]) + 0.0001:
					out_of_range.append("%s.%s=%s 不在 %s" % [file, uniform_name, str(f), str(rng)])

	_check("默认值的 Variant 类型与 uniform 类型一致", type_mismatch.is_empty(),
		", ".join(type_mismatch))
	_check("默认值落在声明的 hint_range 内", out_of_range.is_empty(),
		", ".join(out_of_range))


## 5) 参数面板：控件数与类型跟 uniform 对得上，各控件形态都出现过。
func _test_panel_controls() -> void:
	_ran += 1
	var panel = _preview.param_panel()
	var count_mismatch := PackedStringArray()
	var kinds := {}

	for i in _preview.effects().size():
		_preview.set_effect_index(i)
		if not _is_registered(String(_preview.current_effect_path().get_file())):
			continue
		var sh: Shader = _preview.shader()
		var editable := 0
		for u in sh.get_shader_uniform_list():
			var d: Dictionary = u
			if RESERVED.has(String(d["name"])) or int(d["type"]) == TYPE_OBJECT:
				continue
			editable += 1
		var count: int = panel.param_count()
		if count != editable:
			count_mismatch.append("%s: %d≠%d" % [_preview.current_effect_path().get_file(), count, editable])
		for uniform_name in panel.param_names():
			var row: Dictionary = panel.get_row(String(uniform_name))
			kinds[String(row["kind"])] = true

	_check("控件数 = 可调参数数", count_mismatch.is_empty(), ", ".join(count_mismatch))
	_check("bool → 勾选框", kinds.has("bool"))
	_check("hint_enum → 下拉框", kinds.has("enum"))
	_check("hint_range float → 滑块+数字框", kinds.has("range_float"))
	_check("hint_range int → 滑块+整数框", kinds.has("range_int"))
	_check("source_color → 颜色选择器", kinds.has("color"))

	# 过滤器：过滤后可见行数变少，清空后还原
	panel.set_filter("blur")
	var filtered: int = panel.visible_count()
	panel.set_filter("")
	var total: int = panel.param_count()
	var restored: int = panel.visible_count()
	_check("过滤后可见行数 <= 全部，且能还原",
		filtered <= total and restored == total, "过滤 %d / 全部 %d" % [filtered, total])


## 6) 参数读写往返：面板取的值真的写进了 material，写回再读回不漂移。
func _test_param_roundtrip() -> void:
	_ran += 1
	var panel = _preview.param_panel()
	var mat_mismatch := PackedStringArray()
	var reapply_mismatch := PackedStringArray()

	for i in _preview.effects().size():
		_preview.set_effect_index(i)
		panel.randomize_values(true)
		var values: Dictionary = panel.get_values()
		var mat: ShaderMaterial = _preview.shader_material()
		for uniform_name in values:
			if not _values_equal(values[uniform_name], mat.get_shader_parameter(String(uniform_name))):
				mat_mismatch.append("%s.%s" % [_preview.current_effect_path().get_file(), uniform_name])
		panel.apply_values(values, true)
		var again: Dictionary = panel.get_values()
		for uniform_name in values:
			if not _values_equal(values[uniform_name], again[uniform_name]):
				reapply_mismatch.append("%s.%s" % [_preview.current_effect_path().get_file(), uniform_name])

	_check("面板值都写进了 material", mat_mismatch.is_empty(), ", ".join(mat_mismatch))
	_check("写回再读回不漂移", reapply_mismatch.is_empty(), ", ".join(reapply_mismatch))


## 7) 切换效果：材质换新、time 归零、保留 uniform 重新绑定，越界被拒。
func _test_effect_switch() -> void:
	_ran += 1
	_check("切到第 0 个效果", _preview.set_effect_index(0))
	var first: ShaderMaterial = _preview.shader_material()
	_preview.tick(1.5)
	_check("时间推进后 time != 0", float(_preview.time_value()) > 0.0)

	_check("切到第 1 个效果", _preview.set_effect_index(1))
	var second: ShaderMaterial = _preview.shader_material()
	_check("换了新的 ShaderMaterial", first != second)
	_check("材质挂的是新 shader", second.shader == _preview.shader())
	_check("切效果后 time 归零", is_zero_approx(float(_preview.time_value())))
	_check("预览节点用的是新材质", _preview.preview_rect().material == second)
	_check("越界索引被拒绝",
		not bool(_preview.set_effect_index(-1))
		and not bool(_preview.set_effect_index(_preview.effects().size())))

	var tex: Texture2D = _preview.preview_texture()
	var size := Vector2(tex.get_size())
	var ts: Vector2 = second.get_shader_parameter("texel_size")
	_check("texel_size = 1/源图尺寸",
		absf(ts.x - 1.0 / size.x) < 0.000001 and absf(ts.y - 1.0 / size.y) < 0.000001,
		"%s vs %s" % [str(ts), str(size)])
	_check("src_tex 绑定了当前源图", second.get_shader_parameter("src_tex") == tex)


## 8) 源图切换：每个源图都能挂上，texel_size 跟着变；追加外部纹理也生效。
func _test_source_switch() -> void:
	_ran += 1
	var sources: Array = _preview.sources()
	_check("源图 >= 8 个（程序化 + 工程素材）", sources.size() >= 8, "实际 %d" % sources.size())

	var mismatch := PackedStringArray()
	var null_tex := 0
	for i in sources.size():
		_preview.set_source_index(i)
		var tex: Texture2D = _preview.preview_texture()
		if tex == null:
			null_tex += 1
			continue
		var size := Vector2(tex.get_size())
		var mat: ShaderMaterial = _preview.shader_material()
		var ts: Vector2 = mat.get_shader_parameter("texel_size")
		if absf(ts.x - 1.0 / size.x) > 0.000001 or absf(ts.y - 1.0 / size.y) > 0.000001:
			mismatch.append(String(sources[i]["name"]))
	_check("每个源图都有纹理", null_tex == 0, "%d 个为空" % null_tex)
	_check("切源图后 texel_size 同步", mismatch.is_empty(), ", ".join(mismatch))

	# 追加一张外部纹理（对应界面上的「打开图片…」）
	var before_count: int = sources.size()
	var img := Image.create_empty(37, 11, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.4, 0.6, 1.0))
	var idx: int = _preview.add_source("测试纹理 37x11", ImageTexture.create_from_image(img))
	var mat2: ShaderMaterial = _preview.shader_material()
	var ts2: Vector2 = mat2.get_shader_parameter("texel_size")
	_check("追加源图后立即可选且尺寸生效",
		idx == before_count and absf(ts2.x - 1.0 / 37.0) < 0.000001,
		"idx=%d ts=%s" % [idx, str(ts2)])


## 9) 动画：tick 推进 time、按倍速走、暂停或 0 倍速不推进、material 与状态一致。
func _test_animation() -> void:
	_ran += 1
	_preview.set_effect_index(0)
	_preview.set_playing(true)
	_preview.set_time_scale(2.0)
	var before: float = _preview.time_value()
	var advanced: bool = _preview.tick(0.5)
	var after: float = _preview.time_value()
	_check("tick(0.5) 推进了时间", advanced and after > before, "%f → %f" % [before, after])
	_check("time 按倍速推进", is_equal_approx(after - before, 1.0), "Δ=%f" % (after - before))
	var mat: ShaderMaterial = _preview.shader_material()
	_check("material.time 与状态一致",
		is_equal_approx(float(mat.get_shader_parameter("time")), after))

	_preview.set_playing(false)
	var paused_at: float = _preview.time_value()
	var advanced2: bool = _preview.tick(0.5)
	_check("暂停后不推进", not advanced2 and is_equal_approx(float(_preview.time_value()), paused_at))

	_preview.set_playing(true)
	_preview.set_time_scale(0.0)
	var zero_at: float = _preview.time_value()
	_preview.tick(0.5)
	_check("倍速为 0 时也不推进", is_equal_approx(float(_preview.time_value()), zero_at))
	_preview.set_time_scale(1.0)


## 10) 状态导出/导入：改一堆东西再导入，必须完全还原。
func _test_state_roundtrip() -> void:
	_ran += 1
	_preview.set_effect_index(5)
	var panel = _preview.param_panel()
	panel.randomize_values(true)
	_preview.set_time_scale(1.75)
	_preview.set_playing(false)
	_preview.tick(0.25)

	var state: Dictionary = _preview.export_state()
	var params_before: Dictionary = panel.get_values()
	var effect_before: String = _preview.current_effect_path()
	var source_before: String = _preview.current_source_name()

	# 弄乱
	_preview.set_effect_index(0)
	_preview.set_source_index(0)
	panel.reset_to_defaults(true)
	_preview.set_time_scale(1.0)
	_preview.set_playing(true)

	_check("导入状态成功", _preview.import_state(state))
	_check("效果还原", _preview.current_effect_path() == effect_before)
	_check("源图还原", _preview.current_source_name() == source_before)
	_check("参数还原", _dicts_equal(params_before, panel.get_values()),
		"%s vs %s" % [str(params_before), str(panel.get_values())])
	_check("倍速还原", is_equal_approx(float(_preview.time_scale()), 1.75))
	_check("播放状态还原", not bool(_preview.is_playing()))
	_check("时间还原", is_equal_approx(float(_preview.time_value()), float(state["time"])))
	_check("对不上的效果被拒绝",
		not bool(_preview.import_state({"effect": "res://subsystem/shader_preview/shaders/不存在.gdshader"})))

	# encode/decode 往返（Vector/Color 直接进 JSON 会退化成字符串，所以要先编码）
	var values: Dictionary = panel.get_values()
	var encoded := {}
	for uniform_name in values:
		encoded[uniform_name] = _preview.encode_value(values[uniform_name])
	var decoded := {}
	for uniform_name in encoded:
		decoded[uniform_name] = _preview.decode_value(encoded[uniform_name])
	_check("Vector/Color 编码解码往返一致", _dicts_equal(values, decoded))


## 11) 预设：存成 user:// 下的 JSON，读回来一致，删除生效，名字会被安全化。
func _test_preset_io() -> void:
	_ran += 1
	_preview.delete_preset(PRESET_NAME)  # 先清干净，重复跑不受影响

	_preview.set_effect_index(3)
	var panel = _preview.param_panel()
	panel.randomize_values(true)
	_preview.set_playing(false)
	var params_before: Dictionary = panel.get_values()
	var effect_before: String = _preview.current_effect_path()

	_check("保存预设", _preview.save_preset(PRESET_NAME))
	var names: Array = _preview.preset_names()
	_check("预设出现在列表里", names.has(PRESET_NAME))
	_check("预设文件真的落盘", FileAccess.file_exists(String(_preview.preset_path(PRESET_NAME))))

	# 弄乱后加载
	_preview.set_effect_index(0)
	_check("加载预设", _preview.load_preset(PRESET_NAME))
	_check("预设还原了效果", _preview.current_effect_path() == effect_before)
	_check("预设还原了参数", _dicts_equal(params_before, panel.get_values()),
		"%s vs %s" % [str(params_before), str(panel.get_values())])

	# 预设名里的路径分隔符会被清掉：结果必须仍落在预设目录内，且用不着再分层
	var safe_path: String = _preview.preset_path("../../逃跑/预设")
	var leaf := safe_path.substr(len(PRESET_DIR) + 1)
	_check("预设名被安全化（不会写出预设目录）",
		safe_path.begins_with(PRESET_DIR + "/") and not leaf.contains("/") and not leaf.contains("\\"),
		safe_path)

	_check("删除预设", _preview.delete_preset(PRESET_NAME))
	var after: Array = _preview.preset_names()
	_check("删除后不在列表里", not after.has(PRESET_NAME))


## 12) 默认值解析器单元用例（含坏表达式回落）。
func _test_default_parser() -> void:
	_ran += 1
	var cases := [
		{"expr": "0.45", "type": TYPE_FLOAT, "src": "float", "want": 0.45},
		{"expr": "-1.0", "type": TYPE_FLOAT, "src": "float", "want": -1.0},
		{"expr": "PI * 0.5", "type": TYPE_FLOAT, "src": "float", "want": PI * 0.5},
		{"expr": "true", "type": TYPE_BOOL, "src": "bool", "want": true},
		{"expr": "false", "type": TYPE_BOOL, "src": "bool", "want": false},
		{"expr": "6", "type": TYPE_INT, "src": "int", "want": 6},
		{"expr": "2.0", "type": TYPE_INT, "src": "int", "want": 2},
		{"expr": "vec2(0.25, 0.75)", "type": TYPE_VECTOR2, "src": "vec2", "want": Vector2(0.25, 0.75)},
		{"expr": "vec2(0.5)", "type": TYPE_VECTOR2, "src": "vec2", "want": Vector2(0.5, 0.5)},
		{"expr": "vec3(0.2, 0.3, 0.4)", "type": TYPE_VECTOR3, "src": "vec3", "want": Vector3(0.2, 0.3, 0.4)},
		{"expr": "vec3(1.0, 0.62, 0.15)", "type": TYPE_COLOR, "src": "vec3", "want": Color(1.0, 0.62, 0.15, 1.0)},
		{"expr": "vec4(0.1, 0.2, 0.3, 0.4)", "type": TYPE_COLOR, "src": "vec4", "want": Color(0.1, 0.2, 0.3, 0.4)},
		{"expr": "vec4(0.5)", "type": TYPE_COLOR, "src": "vec4", "want": Color(0.5, 0.5, 0.5, 0.5)},
		{"expr": "vec3(0.5)", "type": TYPE_COLOR, "src": "vec3", "want": Color(0.5, 0.5, 0.5, 1.0)},
	]

	var bad := PackedStringArray()
	for c in cases:
		var got: Variant = ParamPanel.eval_default(String(c["expr"]), int(c["type"]), String(c["src"]))
		if not _values_equal(got, c["want"]):
			bad.append("%s → %s（期望 %s）" % [String(c["expr"]), str(got), str(c["want"])])
	_check("合法默认值表达式全部解析正确", bad.is_empty(), ", ".join(bad))

	var broken := ["", "   ", "vec3(", "完全不是表达式", "1.0 +", "Color("]
	var crashed := PackedStringArray()
	for expr in broken:
		var v: Variant = ParamPanel.eval_default(String(expr), TYPE_COLOR, "vec3")
		if v != null:
			crashed.append("%s → %s" % [expr, str(v)])
	_check("坏表达式一律回落 null（不崩）", crashed.is_empty(), ", ".join(crashed))

	# 声明扫描：hint 里带逗号和引号也不能把默认值切错
	var decls: Dictionary = ParamPanel.parse_declarations("""
		shader_type canvas_item;
		uniform int axis : hint_enum("水平", "垂直", "径向") = 2;
		uniform vec3 tint : source_color = vec3(0.3, 0.9, 1.0);
		uniform float no_default; // 没写默认值
		uniform sampler2D src_tex : hint_default_white;
	""")
	_check("声明扫描认得出枚举/颜色", decls.has("axis") and decls.has("tint"))
	_check("没写默认值的 uniform 不进结果", not decls.has("no_default"))
	_check("枚举默认值 2 解析成 int 2",
		ParamPanel.eval_default(String(decls["axis"]["default"]), TYPE_INT, "int") == 2)
	_check("颜色默认值解析成 Color",
		_values_equal(ParamPanel.eval_default(String(decls["tint"]["default"]), TYPE_COLOR, "vec3"),
			Color(0.3, 0.9, 1.0, 1.0)))


## 13) 程序化源图生成器：形状/alpha/颜色分布要对。
## 这一组是被真事逼出来的 —— `make_ring` 的圆环公式写反过，整圈恒为透明，
## 但「纹理存在 + 尺寸正确」这类断言完全抓不到。
@warning_ignore("integer_division")
func _test_procedural_sources() -> void:
	_ran += 1
	var size := 256

	var checker := Sources.make_checker(size).get_image()
	var checker_colors := _distinct_colors(checker)
	_check("棋盘格恰好两种颜色且不透明",
		checker_colors.size() == 2 and checker.get_pixel(0, 0).a == 1.0,
		str(checker_colors.size()))

	var gradient := Sources.make_gradient(size).get_image()
	_check("渐变颜色数 > 200（是连续的，不是色带）",
		_distinct_colors(gradient).size() > 200, str(_distinct_colors(gradient).size()))

	var uv := Sources.make_uv(size).get_image()
	var c00 := uv.get_pixel(0, 0)
	var c11 := uv.get_pixel(size - 1, size - 1)
	_check("UV 图 = (u, v, 0.5)",
		absf(c00.r) < 0.01 and absf(c00.g) < 0.01 and absf(c00.b - 0.5) < 0.01
		and absf(c11.r - 1.0) < 0.01 and absf(c11.g - 1.0) < 0.01,
		"%s / %s" % [str(c00), str(c11)])

	var wheel := Sources.make_color_wheel(size).get_image()
	_check("色轮：中心不透明、角上透明",
		wheel.get_pixel(size / 2, size / 2).a > 0.9 and wheel.get_pixel(2, 2).a < 0.1)

	var blob := Sources.make_blob(size).get_image()
	_check("圆形蒙版：正中心不透明、角上透明、边缘有半透明过渡",
		blob.get_pixel(size / 2, size / 2).a > 0.9
		and blob.get_pixel(2, 2).a < 0.1
		and _has_partial_alpha(blob))

	var ring := Sources.make_ring(size).get_image()
	# 半径 71.68(内) ~ 97.28(外)：环带中点必须实心；内孔 45° 方向必须透明
	var band := ring.get_pixel(size / 2, size / 2 - 84)
	var hole := ring.get_pixel(size / 2 + 25, size / 2 + 25)
	_check("圆环：环带实心（这一条抓过回归）", band.a > 0.9, "alpha=%f" % band.a)
	_check("圆环：内孔透明（十字以外的地方）", hole.a < 0.1, "alpha=%f" % hole.a)

	var noise := Sources.make_noise(size).get_image()
	_check("噪点图颜色数 > 100 且不透明",
		_distinct_colors(noise).size() > 100 and noise.get_pixel(5, 5).a == 1.0)

	var steps := Sources.make_grayscale_steps(size).get_image()
	var levels := {}
	for x in size:
		levels[steps.get_pixel(x, 4)] = true
	_check("灰阶卡至少 8 级", levels.size() >= 8, "%d 级" % levels.size())

	_check("全部程序化源图都是 256x256",
		checker.get_size() == Vector2i(size, size) and ring.get_size() == Vector2i(size, size))


## 14) 控件 → material 的实时联动：模拟用户拖滑块 / 点勾选框 / 选下拉 / 调颜色。
## 「可调参数」是这东西的全部卖点，所以这一组专门盯信号接线，
## 而且尽量用控件赋值的自然信号（不是自己 emit 自己）。
func _test_live_control_wiring() -> void:
	_ran += 1

	# 01_pixelate：block_size 是 hint_range 滑块，show_grid 是勾选框
	_preview.set_effect_index(0)
	var panel = _preview.param_panel()
	var mat: ShaderMaterial = _preview.shader_material()

	var row: Dictionary = panel.get_row("block_size")
	var slider: HSlider = row["slider"]
	var spin: SpinBox = row["spin"]
	slider.value = 33.0
	_check("拖滑块 → material 立即更新",
		is_equal_approx(float(mat.get_shader_parameter("block_size")), 33.0),
		str(mat.get_shader_parameter("block_size")))
	_check("拖滑块 → 数字框同步", is_equal_approx(spin.value, 33.0), str(spin.value))

	spin.value = 7.0
	_check("改数字框 → 滑块同步", is_equal_approx(slider.value, 7.0), str(slider.value))
	_check("改数字框 → material 立即更新",
		is_equal_approx(float(mat.get_shader_parameter("block_size")), 7.0))

	var bool_row: Dictionary = panel.get_row("show_grid")
	var check: CheckBox = bool_row["check"]
	check.button_pressed = true
	_check("点勾选框 → material 立即更新",
		bool(mat.get_shader_parameter("show_grid")), str(mat.get_shader_parameter("show_grid")))

	# 05_wave_distortion：axis 是 hint_enum（select() 按设计不发信号，真实点击发的是 item_selected）
	_preview.set_effect_index(4)
	var enum_row: Dictionary = _preview.param_panel().get_row("axis")
	var option: OptionButton = enum_row["enum"]
	option.item_selected.emit(2)
	_check("选下拉项 → material 立即更新",
		int(_preview.shader_material().get_shader_parameter("axis")) == 2,
		str(_preview.shader_material().get_shader_parameter("axis")))

	# 02_dissolve：edge_color 是 source_color
	# 注意：`ColorPickerButton.color = x` 是静默的（Godot 只让弹窗里的取色器发 color_changed），
	# 所以这里走真实用户路径 —— 弹窗取色器发信号。
	_preview.set_effect_index(1)
	var color_row: Dictionary = _preview.param_panel().get_row("edge_color")
	var picker: ColorPickerButton = color_row["color"]
	var wanted := Color(0.1, 0.2, 0.3, 1.0)
	picker.get_picker().color_changed.emit(wanted)
	var got: Variant = _preview.shader_material().get_shader_parameter("edge_color")
	_check("调颜色 → material 立即更新", _values_equal(got, wanted), str(got))
	_check("调颜色 → 面板读回一致", _values_equal(picker.color, wanted), str(picker.color))

	# 04_chromatic_aberration：radial 是 bool，radial_power 是滑块 —— 改完记得能读回
	_preview.set_effect_index(3)
	var p3 = _preview.param_panel()
	var radial_row: Dictionary = p3.get_row("radial")
	(radial_row["check"] as CheckBox).button_pressed = false
	var power_row: Dictionary = p3.get_row("radial_power")
	(power_row["slider"] as HSlider).value = 2.5
	var values: Dictionary = p3.get_values()
	_check("联动后面板读回与 material 一致",
		_values_equal(values["radial"], _preview.shader_material().get_shader_parameter("radial"))
		and _values_equal(values["radial_power"], _preview.shader_material().get_shader_parameter("radial_power")),
		"%s / %s" % [str(values["radial"]), str(values["radial_power"])])


## 15) 完整性哨兵：用例组没跑全就算失败（协程中断 / 提前 return 都能抓到）。
func _test_sentinel() -> void:
	if _ran != PLAN:
		_failed += 1
		print("  [FAIL] 完整性哨兵：计划 %d 组用例，实际只跑了 %d 组" % [PLAN, _ran])
		return
	_passed += 1
	print("  [PASS] 完整性哨兵：%d/%d 组用例全部执行" % [_ran, PLAN])


# ------------------------------------------------------------------- 小工具

## 是否是 `shader_library.gd` 的 ENTRIES 里登记的效果（只有这些保证预览契约）。
func _is_registered(file: String) -> bool:
	for e in Library.ENTRIES:
		if String(e["file"]) == file:
			return true
	return false


func _distinct_colors(img: Image) -> Array:
	var colors := {}
	for y in img.get_height():
		for x in img.get_width():
			colors[img.get_pixel(x, y)] = true
	return colors.keys()


func _has_partial_alpha(img: Image) -> bool:
	for y in range(0, img.get_height(), 3):
		for x in range(0, img.get_width(), 3):
			var a := img.get_pixel(x, y).a
			if a > 0.05 and a < 0.95:
				return true
	return false


func _uniform_names(sh: Shader) -> Array:
	var out := []
	for u in sh.get_shader_uniform_list():
		var d: Dictionary = u
		out.append(String(d["name"]))
	return out


func _values_equal(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == null and b == null
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	if typeof(a) != typeof(b):
		return false
	match typeof(a):
		TYPE_FLOAT:
			return is_equal_approx(float(a), float(b))
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR:
			return a.is_equal_approx(b)
	return a == b


func _dicts_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
		if not _values_equal(a[k], b[k]):
			return false
	return true


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  [PASS] ", label, "" if detail.is_empty() else "  (%s)" % detail)
	else:
		_failed += 1
		print("  [FAIL] ", label, "" if detail.is_empty() else "  (%s)" % detail)
