extends VBoxContainer

## 通用 shader 效果预览 —— 参数面板。
##
## 按 `Shader.get_shader_uniform_list()` 自动生成控件，不认任何具体 shader：
##
## | shader 里的写法 | 生成的控件 |
## | --- | --- |
## | `uniform float x : hint_range(0,1,0.01)` | 滑块 + 数字框 |
## | `uniform int x : hint_range(2,32,1)` | 滑块 + 整数框 |
## | `uniform int x : hint_enum("甲","乙")` | 下拉框 |
## | `uniform bool x` | 勾选框 |
## | `uniform vec3/vec4 x : source_color` | 颜色选择器 |
## | `uniform vec2/3/4 x` | 分量数字框 |
## | `uniform sampler2D x` | 跳过（预览器自动绑 `src_tex`） |
##
## 默认值从哪来：Godot 没有 API 能读到 shader 里写的 `= 默认值`——
## `get_shader_uniform_list(true)` 返回的字典里没有默认值字段，
## `RenderingServer.shader_get_parameter_default()` 一律返回 null，
## `ShaderMaterial.get_shader_parameter()` 在没手动设过时也返回 null。
## 所以这里直接解析 shader 源码里 `uniform ... = <表达式>;` 的表达式，交给 `Expression` 求值
## （`vec2/vec3/vec4` 会翻译成 `Vector2/Vector3/Color`，`PI` 会被替换成数值）。
## 解析失败就按类型退化成零值，绝不报错。

signal param_changed(uniform_name: String, value: Variant)

const RESERVED := ["src_tex", "texel_size", "time"]
const LABEL_WIDTH := 152
const SPIN_WIDTH := 78
const VEC_SPIN_WIDTH := 62

var _shader: Shader
var _rows: Dictionary = {}
var _filter := ""


# ------------------------------------------------------------------ 公有 API

## 按 shader 重建面板；shader 为 null 时清空。
func build(shader: Shader) -> void:
    _clear()
    _shader = shader
    if shader == null:
        return

    var defaults: Dictionary = parse_uniform_defaults(shader)
    for u in shader.get_shader_uniform_list():
        var d: Dictionary = u
        var uniform_name := String(d.get("name", ""))
        var type := int(d.get("type", TYPE_NIL))
        if RESERVED.has(uniform_name) or type == TYPE_NIL or type == TYPE_OBJECT:
            continue
        var hint := int(d.get("hint", PROPERTY_HINT_NONE))
        var hint_string := String(d.get("hint_string", ""))
        var fallback: Variant = defaults.get(uniform_name, variant_zero(type))
        _add_row(uniform_name, type, hint, hint_string, fallback)

    _apply_filter()


## 面板当前的全部参数值（直接读控件，永远跟界面一致）。
func get_values() -> Dictionary:
    var out := {}
    for uniform_name in _rows:
        out[uniform_name] = read_value(String(uniform_name))
    return out


## 写回参数值；notify=true 时逐个发 param_changed。
## 写控件时用 *_no_signal，避免回环。
func apply_values(values: Dictionary, notify: bool = false) -> void:
    for uniform_name in _rows:
        var key := String(uniform_name)
        if not values.has(key):
            continue
        write_value(key, values[key])
        if notify:
            param_changed.emit(key, read_value(key))


## 参数名（含被过滤隐藏的），顺序与 shader 声明一致。
func param_names() -> Array:
    return _rows.keys()


## 可调参数个数（不含保留 uniform 与被跳过类型）。
func param_count() -> int:
    return _rows.size()


## 当前可见（未被过滤隐藏）的行数。
func visible_count() -> int:
    var n := 0
    for uniform_name in _rows:
        if (_rows[uniform_name]["root"] as Control).visible:
            n += 1
    return n


func has_param(uniform_name: String) -> bool:
    return _rows.has(uniform_name)


func get_row(uniform_name: String) -> Dictionary:
    return _rows.get(uniform_name, {})


## 按参数名子串过滤（大小写不敏感）；空串显示全部。
func set_filter(text: String) -> void:
    _filter = text.strip_edges().to_lower()
    _apply_filter()


func filter_text() -> String:
    return _filter


## 回到 shader 源码里写的默认值。
func reset_to_defaults(notify: bool = true) -> void:
    if _shader == null:
        return
    apply_values(parse_uniform_defaults(_shader), notify)


## 在每个参数的 hint_range 范围内随机取值；颜色随机、分量在 [-1,1]。
func randomize_values(notify: bool = true, rng: RandomNumberGenerator = null) -> void:
    var r := rng
    if r == null:
        r = RandomNumberGenerator.new()
        r.randomize()
    var values := {}
    for uniform_name in _rows:
        values[uniform_name] = _random_value(String(uniform_name), r)
    apply_values(values, notify)


# --------------------------------------------------------------- 行 / 控件

func _clear() -> void:
    for c in get_children():
        remove_child(c)
        c.free()
    _rows.clear()
    _shader = null


func _add_row(uniform_name: String, type: int, hint: int, hint_string: String, value: Variant) -> void:
    var row := HBoxContainer.new()
    row.name = "Row_" + uniform_name
    row.add_theme_constant_override("separation", 8)
    add_child(row)

    var label := Label.new()
    label.text = uniform_name
    label.tooltip_text = "%s\n(shader uniform: %s)" % [_type_label(type, hint, hint_string), uniform_name]
    label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
    label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    row.add_child(label)

    var rec := {"root": row, "type": type, "hint": hint, "kind": "none"}

    # 下拉框
    if hint == PROPERTY_HINT_ENUM and not hint_string.is_empty():
        var ob := OptionButton.new()
        ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        var items := _enum_items(hint_string)
        for i in items.size():
            ob.add_item(String(items[i]["label"]), int(items[i]["value"]))
        var idx := ob.get_item_index(int(value))
        ob.selected = max(idx, 0)
        # 用信号带过来的下标，而不是回读 ob.selected：
        # 这样既对真实点击成立，程序化 emit 也能正确联动。
        ob.item_selected.connect(func(i: int) -> void:
            param_changed.emit(uniform_name, ob.get_item_id(i))
        )
        row.add_child(ob)
        rec["kind"] = "enum"
        rec["enum"] = ob
        _rows[uniform_name] = rec
        return

    # 勾选框
    if type == TYPE_BOOL:
        var cb := CheckBox.new()
        cb.button_pressed = bool(value)
        cb.toggled.connect(func(pressed: bool) -> void:
            param_changed.emit(uniform_name, pressed)
        )
        row.add_child(cb)
        rec["kind"] = "bool"
        rec["check"] = cb
        _rows[uniform_name] = rec
        return

    # 颜色
    if type == TYPE_COLOR:
        var cpb := ColorPickerButton.new()
        cpb.color = value if value is Color else Color.WHITE
        cpb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        cpb.color_changed.connect(func(c: Color) -> void:
            param_changed.emit(uniform_name, c)
        )
        row.add_child(cpb)
        rec["kind"] = "color"
        rec["color"] = cpb
        _rows[uniform_name] = rec
        return

    # 向量：每个分量一个数字框
    if type == TYPE_VECTOR2 or type == TYPE_VECTOR3 or type == TYPE_VECTOR4:
        var comps := _vector_as_array(value, type)
        var spins: Array = []
        var box := HBoxContainer.new()
        box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        box.add_theme_constant_override("separation", 4)
        row.add_child(box)
        for i in comps.size():
            var sb := SpinBox.new()
            sb.min_value = -16.0
            sb.max_value = 16.0
            sb.step = 0.001
            sb.allow_greater = true
            sb.allow_lesser = true
            sb.custom_minimum_size = Vector2(VEC_SPIN_WIDTH, 0)
            sb.value = float(comps[i])
            sb.value_changed.connect(func(_v: float) -> void:
                param_changed.emit(uniform_name, read_value(uniform_name))
            )
            box.add_child(sb)
            spins.append(sb)
        rec["kind"] = "vec%d" % comps.size()
        rec["spins"] = spins
        _rows[uniform_name] = rec
        return

    # 数值：有 range 就滑块 + 数字框，没有就纯数字框
    var is_int := type == TYPE_INT
    var rng := parse_range(hint_string)
    var spin := SpinBox.new()
    spin.custom_minimum_size = Vector2(SPIN_WIDTH, 0)
    if is_int:
        spin.step = 1.0
    if rng.is_empty():
        spin.min_value = -9999.0
        spin.max_value = 9999.0
        spin.value = float(value)
        spin.value_changed.connect(func(_v: float) -> void:
            param_changed.emit(uniform_name, read_value(uniform_name))
        )
        row.add_child(spin)
        rec["kind"] = "int" if is_int else "float"
        rec["spin"] = spin
        _rows[uniform_name] = rec
        return

    var slider := HSlider.new()
    slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    slider.min_value = rng["min"]
    slider.max_value = rng["max"]
    slider.step = rng["step"]
    slider.value = clampf(float(value), rng["min"], rng["max"])
    spin.min_value = rng["min"]
    spin.max_value = rng["max"]
    spin.step = rng["step"]
    spin.value = slider.value
    # 滑块 <-> 数字框双向同步（都用 no_signal 写对方），对外发信号上带的值
    slider.value_changed.connect(func(v: float) -> void:
        spin.set_value_no_signal(v)
        param_changed.emit(uniform_name, _scalar_value(v, is_int))
    )
    spin.value_changed.connect(func(v: float) -> void:
        slider.set_value_no_signal(v)
        param_changed.emit(uniform_name, _scalar_value(v, is_int))
    )
    row.add_child(slider)
    row.add_child(spin)
    rec["kind"] = "range_int" if is_int else "range_float"
    rec["slider"] = slider
    rec["spin"] = spin
    _rows[uniform_name] = rec


func read_value(uniform_name: String) -> Variant:
    if not _rows.has(uniform_name):
        return null
    var r: Dictionary = _rows[uniform_name]
    match String(r["kind"]):
        "bool":
            return bool((r["check"] as CheckBox).button_pressed)
        "enum":
            var ob: OptionButton = r["enum"]
            if ob.selected < 0:
                return 0
            return ob.get_item_id(ob.selected)
        "color":
            return (r["color"] as ColorPickerButton).color
        "float", "range_float":
            return float((r["spin"] as SpinBox).value)
        "int", "range_int":
            return int(round((r["spin"] as SpinBox).value))
        "vec2", "vec3", "vec4":
            var spins: Array = r["spins"]
            var v := []
            for s in spins:
                v.append(float((s as SpinBox).value))
            match v.size():
                2:
                    return Vector2(v[0], v[1])
                3:
                    return Vector3(v[0], v[1], v[2])
                4:
                    return Vector4(v[0], v[1], v[2], v[3])
    return null


func write_value(uniform_name: String, value: Variant) -> void:
    if not _rows.has(uniform_name):
        return
    var r: Dictionary = _rows[uniform_name]
    match String(r["kind"]):
        "bool":
            (r["check"] as CheckBox).set_pressed_no_signal(bool(value))
        "enum":
            var ob: OptionButton = r["enum"]
            var idx := ob.get_item_index(int(value))
            ob.selected = max(idx, 0)
        "color":
            (r["color"] as ColorPickerButton).color = value if value is Color else Color.WHITE
        "float", "range_float":
            (r["spin"] as SpinBox).set_value_no_signal(float(value))
            if r.has("slider"):
                (r["slider"] as HSlider).set_value_no_signal(float(value))
        "int", "range_int":
            (r["spin"] as SpinBox).set_value_no_signal(roundf(float(value)))
            if r.has("slider"):
                (r["slider"] as HSlider).set_value_no_signal(roundf(float(value)))
        "vec2", "vec3", "vec4":
            var comps := _vector_as_array(value, int(r["type"]))
            var spins: Array = r["spins"]
            for i in mini(comps.size(), spins.size()):
                (spins[i] as SpinBox).set_value_no_signal(float(comps[i]))


func _apply_filter() -> void:
    for uniform_name in _rows:
        var row: Control = _rows[uniform_name]["root"]
        row.visible = _filter.is_empty() or String(uniform_name).to_lower().contains(_filter)


func _random_value(uniform_name: String, rng: RandomNumberGenerator) -> Variant:
    var r: Dictionary = _rows[uniform_name]
    match String(r["kind"]):
        "bool":
            return rng.randf() < 0.5
        "enum":
            var ob: OptionButton = r["enum"]
            if ob.item_count == 0:
                return 0
            return ob.get_item_id(rng.randi_range(0, ob.item_count - 1))
        "color":
            return Color(rng.randf(), rng.randf(), rng.randf(), 1.0)
        "float", "range_float", "int", "range_int":
            var spin: SpinBox = r["spin"]
            var v := rng.randf_range(spin.min_value, spin.max_value)
            if String(r["kind"]).begins_with("range"):
                var step: float = maxf(spin.step, 0.0001)
                v = roundf(v / step) * step
            if String(r["kind"]).ends_with("int"):
                v = roundf(v)
            return v
        "vec2", "vec3", "vec4":
            var comps := _vector_as_array(read_value(uniform_name), int(r["type"]))
            var out := []
            for c in comps:
                out.append(rng.randf_range(-1.0, 1.0))
            match out.size():
                2:
                    return Vector2(out[0], out[1])
                3:
                    return Vector3(out[0], out[1], out[2])
                4:
                    return Vector4(out[0], out[1], out[2], out[3])
        _:
            pass
    return read_value(uniform_name)


# --------------------------------------------------------- 默认值解析（静态）

## 解析 shader 源码里每个 uniform 的默认值，键是参数名。
## 拿不到默认值的参数不会出现在结果里。
static func parse_uniform_defaults(shader: Shader) -> Dictionary:
    var out := {}
    if shader == null:
        return out
    var decls := parse_declarations(shader.code)
    for u in shader.get_shader_uniform_list():
        var d: Dictionary = u
        var uniform_name := String(d.get("name", ""))
        var type := int(d.get("type", TYPE_NIL))
        if uniform_name.is_empty() or type == TYPE_NIL or type == TYPE_OBJECT:
            continue
        if not decls.has(uniform_name):
            continue
        var v = eval_default(String(decls[uniform_name]["default"]), type, String(decls[uniform_name]["type"]))
        if v != null:
            out[uniform_name] = v
    return out


## 扫源码，返回 {uniform 名: {"type": glsl 类型, "default": 默认值表达式}}。
static func parse_declarations(code: String) -> Dictionary:
    var out := {}
    if code.is_empty():
        return out

    var re := RegEx.new()
    re.compile("^\\s*uniform\\s+(?<type>[A-Za-z0-9_]+)\\s+(?<name>[A-Za-z0-9_]+)\\s*(?::\\s*(?<hint>[^=;]*))?=\\s*(?<value>[^;]*);")

    for raw_line in code.split("\n"):
        var line := String(raw_line)
        var comment := line.find("//")
        if comment >= 0:
            line = line.substr(0, comment)
        if not line.contains("uniform"):
            continue
        var m := re.search(line)
        if m == null:
            continue
        out[String(m.get_string("name"))] = {
            "type": String(m.get_string("type")),
            "default": String(m.get_string("value")),
        }
    return out


## 把 GLSL 默认值表达式求值成 target_type 的 Variant；失败返回 null。
static func eval_default(expr_text: String, target_type: int, source_type: String = "") -> Variant:
    var text := expr_text.strip_edges()
    if text.is_empty():
        return null

    var src := source_type
    if src.is_empty():
        # 没有源码类型信息时，从表达式猜
        src = text.get_slice("(", 0).strip_edges()

    # 先体检一遍：Expression 碰到垃圾输入会在引擎层直接报 ERROR，
    # 而预览器是要读别人写的 shader 的，不能因为一个坏默认值刷一屏错误。
    if not looks_evaluable(text):
        return null

    # GLSL 的向量构造翻译成 Godot 的，并把参数补齐：
    # Expression 不支持 Vector2(x) / Color(x) 这种单参构造，必须展开。
    var args := _inner_args(text)
    match src:
        "vec2":
            text = _ctor("Vector2", args, 2)
        "vec3":
            text = _ctor("Color", args, 4, "1.0") if target_type == TYPE_COLOR \
                else _ctor("Vector3", args, 3)
        "vec4":
            text = _ctor("Color", args, 4) if target_type == TYPE_COLOR \
                else _ctor("Vector4", args, 4)
        "ivec2":
            text = _ctor("Vector2i", args, 2)
        "ivec3":
            text = _ctor("Vector3i", args, 3)
        "ivec4":
            text = _ctor("Vector4i", args, 4)
        _:
            pass

    text = _replace_pi(text)

    var e := Expression.new()
    if e.parse(text, []) != OK:
        return null
    var v = e.execute()
    if e.has_execute_failed() or v == null:
        return null
    return coerce_value(v, target_type)


## 表达式体检：只放行「数字 + 四则运算 + 括号 + 已知构造名」这类东西。
static func looks_evaluable(text: String) -> bool:
    if text.count("(") != text.count(")"):
        return false
    if text.count("\"") > 0 or text.count("'") > 0:
        return false
    var allowed := "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_+-*/().,% \t"
    for i in text.length():
        if not allowed.contains(text[i]):
            return false

    var known := [
        "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "PI", "true", "false",
        "Color", "Vector2", "Vector3", "Vector4", "Vector2i", "Vector3i", "Vector4i",
    ]
    var re := RegEx.new()
    re.compile("[A-Za-z_][A-Za-z0-9_]*")
    for m in re.search_all(text):
        if not known.has(m.get_string()):
            return false
    return true


## 取出构造调用的参数；没有括号就当成单参数。
static func _inner_args(text: String) -> Array:
    var open := text.find("(")
    if open < 0:
        return [text]
    var close := text.rfind(")")
    if close < open:
        return []
    return _split_args(text.substr(open + 1, close - open - 1))


## 生成 Godot 构造调用，参数不足时补齐（不足的用第一个参数或 tail_default）。
static func _ctor(ctor: String, args: Array, count: int, tail_default: String = "") -> String:
    var values := PackedStringArray()
    for a in args:
        values.append(String(a))
    if values.is_empty():
        values.append("0.0")
    while values.size() < count:
        if values.size() == count - 1 and not tail_default.is_empty():
            values.append(tail_default)
        else:
            values.append(values[0])
    return "%s(%s)" % [ctor, ", ".join(values)]


static func _split_args(inner: String) -> Array:
    var out := []
    for part in inner.split(","):
        var s := String(part).strip_edges()
        if not s.is_empty():
            out.append(s)
    return out


static func _replace_pi(text: String) -> String:
    var re := RegEx.new()
    re.compile("\\bPI\\b")
    return re.sub(text, "3.14159265358979", true)


## 把求值结果整成 uniform 的 Variant 类型。
static func coerce_value(v: Variant, target_type: int) -> Variant:
    match target_type:
        TYPE_BOOL:
            return bool(v)
        TYPE_INT:
            return int(v)
        TYPE_FLOAT:
            return float(v)
        TYPE_VECTOR2:
            if v is Vector2:
                return v
            if v is Vector3:
                return Vector2(v.x, v.y)
            if v is Vector4:
                return Vector2(v.x, v.y)
            if v is Color:
                return Vector2(v.r, v.g)
            return Vector2(float(v), float(v))
        TYPE_VECTOR3:
            if v is Vector3:
                return v
            if v is Vector2:
                return Vector3(v.x, v.y, 0.0)
            if v is Vector4:
                return Vector3(v.x, v.y, v.z)
            if v is Color:
                return Vector3(v.r, v.g, v.b)
            return Vector3(float(v), float(v), float(v))
        TYPE_VECTOR4:
            if v is Vector4:
                return v
            if v is Color:
                return Vector4(v.r, v.g, v.b, v.a)
            if v is Vector3:
                return Vector4(v.x, v.y, v.z, 1.0)
            if v is Vector2:
                return Vector4(v.x, v.y, 0.0, 0.0)
            return Vector4(float(v), float(v), float(v), float(v))
        TYPE_COLOR:
            if v is Color:
                return v
            if v is Vector3:
                return Color(v.x, v.y, v.z, 1.0)
            if v is Vector4:
                return Color(v.x, v.y, v.z, v.w)
            if v is Vector2:
                return Color(v.x, v.y, 0.0, 1.0)
            return Color(float(v), float(v), float(v), float(v))
    return v


## 滑块的浮点值按参数类型转成对外发出去的值（int 参数取整）。
## 单独抽出来是为了不在三元表达式里混 int/float（GDScript 会警告）。
static func _scalar_value(v: float, is_int: bool) -> Variant:
    if is_int:
        return int(round(v))
    return v


static func variant_zero(type: int) -> Variant:
    match type:
        TYPE_BOOL:
            return false
        TYPE_INT:
            return 0
        TYPE_FLOAT:
            return 0.0
        TYPE_VECTOR2:
            return Vector2.ZERO
        TYPE_VECTOR3:
            return Vector3.ZERO
        TYPE_VECTOR4:
            return Vector4.ZERO
        TYPE_COLOR:
            return Color(1, 1, 1, 1)
    return null


## 数字转短字符串（去掉多余的 0），给 tooltip / 提示文本用。
## Godot 的 % 格式化不认识 %g，所以统一走这里。
static func format_number(x: float) -> String:
    var s := String.num(x, 6)
    if s.contains("."):
        s = s.rstrip("0").rstrip(".")
    if s == "" or s == "-":
        s = "0"
    return s


## 解析 `hint_range(0, 1, 0.01)` 的 hint_string；没有 range 返回 {}。
static func parse_range(hint_string: String) -> Dictionary:
    var parts := hint_string.split(",")
    if parts.size() < 2:
        return {}
    var lo := float(parts[0])
    var hi := float(parts[1])
    var step := 0.01
    if parts.size() >= 3:
        step = float(parts[2])
    if hi <= lo:
        return {}
    if step <= 0.0:
        step = (hi - lo) / 100.0
    return {"min": lo, "max": hi, "step": step}


## 解析 `hint_enum("甲","乙")` 的 hint_string，兼容 `甲:0,乙:1` 写法。
static func _enum_items(hint_string: String) -> Array:
    var out := []
    var idx := 0
    for part in hint_string.split(","):
        var s := String(part).strip_edges()
        if s.is_empty():
            continue
        var value := idx
        var label := s
        var colon := s.rfind(":")
        if colon > 0 and s.substr(colon + 1).strip_edges().is_valid_int():
            label = s.substr(0, colon).strip_edges()
            value = s.substr(colon + 1).strip_edges().to_int()
        out.append({"label": label, "value": value})
        idx += 1
    return out


static func _type_label(type: int, hint: int, hint_string: String) -> String:
    if hint == PROPERTY_HINT_ENUM:
        return "枚举（%s）" % hint_string
    var rng := parse_range(hint_string)
    if not rng.is_empty():
        # 注意：Godot 的 % 格式化不支持 %g，这里统一走 format_number
        return "范围 %s ~ %s（步长 %s）" % [
            format_number(rng["min"]), format_number(rng["max"]), format_number(rng["step"])]
    match type:
        TYPE_BOOL:
            return "开关"
        TYPE_INT:
            return "整数"
        TYPE_FLOAT:
            return "浮点数"
        TYPE_COLOR:
            return "颜色"
        TYPE_VECTOR2:
            return "二维向量"
        TYPE_VECTOR3:
            return "三维向量"
        TYPE_VECTOR4:
            return "四维向量"
    return "参数"


static func _vector_as_array(v: Variant, type: int) -> Array:
    match type:
        TYPE_VECTOR2:
            var v2: Vector2 = v if v is Vector2 else Vector2.ZERO
            return [v2.x, v2.y]
        TYPE_VECTOR3:
            var v3: Vector3 = v if v is Vector3 else Vector3.ZERO
            return [v3.x, v3.y, v3.z]
        TYPE_VECTOR4:
            var v4: Vector4 = v if v is Vector4 else Vector4.ZERO
            return [v4.x, v4.y, v4.z, v4.w]
    return []
