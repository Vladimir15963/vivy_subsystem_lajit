class_name PvWhale
extends RefCounted

## C 层落鲸：雪 / 接触尘 / 歌词碎屑（`shot_whale_fall`）。
##
## 参数全部来自离线烘表（`tools/build_data.py: build_whale_fall()`）：
##   `whale_shed.bin`    230 × 10 f32（b, x0, y0, v, amp, w, ph, drift, lv, sz）
##   `whale_contact.bin` 100 × 6 f32（b, x0, side, up, lv, sz）
##   `whale_words.json`  171 条歌词 / 色块碎屑
##   `whale_fall.json`   T0 / TC / T1、她的落点格、落地线常数
##
## 位置公式逐字照抄 `continuity_full_v2/s_eval.py`：
##   `shed_pos` L625-637、`contact_pos` L639-644、`word_state` L646-663、
##   `converge` L665-674；落地线 `scenes_eval.floor_y(x) = 559 + 4·sin(0.07x)`。
##
## 参考在 1280×720 像素画布上画 2~3 px 的方块；这里把它们映射进给定格区，
## 用 `·` / `.` 与字符文本表示。运行时**不摇 RNG**（决策 §7 Q8）。

const SHED := "res://subsystem/world_execute/data/whale_shed.bin"
const CONTACT := "res://subsystem/world_execute/data/whale_contact.bin"
const WORDS := "res://subsystem/world_execute/data/whale_words.json"
const META := "res://subsystem/world_execute/data/whale_fall.json"

## 参考电影画布的核心内容矩形（FULL）：映射进格区时以它为基准。
const FILM := Rect2i(24, 56, 1140, 548)

static var _shed := PackedFloat32Array()
static var _contact := PackedFloat32Array()
static var _words: Array = []
static var _meta: Dictionary = {}
static var _loaded := false


static func load_tables() -> void:
	if _loaded:
		return
	_loaded = true
	var a := FileAccess.get_file_as_bytes(SHED)
	var b := FileAccess.get_file_as_bytes(CONTACT)
	if not a.is_empty():
		_shed = a.to_float32_array()
	if not b.is_empty():
		_contact = b.to_float32_array()
	var w: Variant = JSON.parse_string(FileAccess.get_file_as_string(WORDS))
	if typeof(w) == TYPE_DICTIONARY:
		_words = w.get("words", [])
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(META))
	if typeof(m) == TYPE_DICTIONARY:
		_meta = m
	if _meta.is_empty():
		push_warning("world_execute: 缺少 whale_fall.json，落鲸粒子不绘制")


static func time_range() -> Vector2:
	load_tables()
	return Vector2(float(_meta.get("t0", 0.0)), float(_meta.get("t1", 0.0)))


static func shot_time() -> float:
	load_tables()
	return float(_meta.get("tc", 0.0))


## 落地线（`scenes_eval.py:L605-607`）：屏幕 y。
static func floor_y(x: float) -> float:
	return 559.0 + 4.0 * sin(x * 0.07)


## 雪粒位置（`s_eval.py:L625-637`）。
static func shed_pos(q: PackedFloat32Array, t: float) -> Vector3:
	var age := t - q[0]
	var x := q[1] + q[4] * sin(q[5] * age + q[6]) + q[7] * age
	var y := q[2] + q[3] * age
	var lv := q[8] * (1.0 - 0.35 * clampf(age / 6.0, 0.0, 1.0))
	var fy := floor_y(x) - 2.0
	if y >= fy:
		var ta := (fy - q[2]) / maxf(1e-6, q[3])
		x = q[1] + q[4] * sin(q[5] * ta + q[6]) + q[7] * ta
		y = floor_y(x) - 2.0
		lv *= 0.8
	return Vector3(x, y, lv)


## 接触尘（`s_eval.py:L639-644`）：落地后向两侧散开再落下。
static func contact_pos(q: PackedFloat32Array, t: float) -> Vector3:
	var age := t - q[0]
	var e := _ease_out(age / 1.4)
	var x := q[1] + q[2] * e
	var y := floor_y(x) - 2.0 - q[3] * sin(PI * clampf(age / 1.4, 0.0, 1.0))
	return Vector3(x, y, q[4] * (1.0 - 0.3 * clampf(age / 4.0, 0.0, 1.0)))


## `converge`（`s_eval.py:L665-674`）：TC 之后被吸进落点格；返回 `Vector3(x, y, g)`，
## 已被吸完时返回 `Vector3(-1, -1, -1)`（调用方跳过）。
static func converge(x: float, y: float, d: float, t: float) -> Vector3:
	var tc := shot_time()
	if t < tc:
		return Vector3(x, y, 1.0)
	var w := pow(clampf((t - tc - d) / 0.75, 0.0, 1.0), 3.0)
	if w >= 1.0:
		return Vector3(-1, -1, -1)
	var p: Array = _meta.get("cell", [590.0, 559.0])
	var px := float(p[0])
	var py := float(p[1])
	var mx := (x + px) / 2.0
	var my := (y + py) / 2.0
	var dx := px - x
	var dy := py - y
	var cx := mx + dy * 0.18
	var cy := my - dx * 0.18
	var a := (1.0 - w) * (1.0 - w)
	var b := 2.0 * (1.0 - w) * w
	var c := w * w
	return Vector3(a * x + b * cx + c * px, a * y + b * cy + c * py, 1.0 + 0.4 * w)


## 歌词碎屑状态（`s_eval.py:L646-663`）：
## `{"kind":"whole","pos":Vector2,"alpha":float}` 或
## `{"kind":"specks","list":Array[Vector3],"alpha":float}`。
static func word_state(wd: Dictionary, t: float) -> Dictionary:
	var t0 := float(_meta.get("t0", 0.0))
	var a := maxf(0.0, t - t0 - float(wd.get("delay", 0.0)))
	var L := float(wd.get("whole", 0.3))
	var wx := float(wd.get("x", 0.0))
	var wy := float(wd.get("y", 0.0))
	if a < L:
		return {
			"kind": "whole",
			"pos": Vector2(wx + 2.0 * sin(a * 5.0 + wx), wy + 10.0 * a + 36.0 * a * a),
			"alpha": 1.0 - 0.7 * a / maxf(1e-6, L),
		}
	var b := a - L
	var y_l := 10.0 * L + 36.0 * L * L
	var out: Array = []
	for sp in (wd.get("specks", []) as Array):
		var ox := float(sp[0])
		var oy := float(sp[1])
		var v := float(sp[2])
		var ph := float(sp[3])
		var lv := float(sp[4])
		var x := wx + ox + 9.0 * sin(b * 1.1 + ph) + 3.0 * b
		var y := wy + oy + y_l + v * b + 14.0 * minf(b, 0.5)
		var fy := floor_y(x) - 2.0
		if y >= fy:
			y = fy
			lv *= 0.8
		out.append(Vector3(x, y, lv * (1.0 - 0.3 * clampf(b / 5.0, 0.0, 1.0))))
	return {"kind": "specks", "list": out, "alpha": 1.0}


## 绘制整段落鲸，返回落笔的格数。
##
## `area` 是格区（通常是影院模式的内容区）；参考的 1280×720 像素坐标按 `FILM` 线性映射进去。
## 5A：CLEAR 区（stdout 带）不写。
static func draw(s: PvScreen, t: float, area: Rect2i) -> int:
	load_tables()
	if _meta.is_empty() or area.size.x < 8 or area.size.y < 6:
		return 0
	var t0 := float(_meta.get("t0", 0.0))
	if t < t0 or t > float(_meta.get("t1", 0.0)) + 1.0:
		return 0
	var tc := float(_meta.get("tc", 0.0))
	var frozen := minf(t, tc)
	var n := 0

	# --- 雪
	var i := 0
	while i + 10 < _shed.size():
		var q := _shed.slice(i, i + 11)
		i += 11
		if t < q[0]:
			continue
		var p := shed_pos(q, frozen)
		n += _speck(s, area, p, t, q[9], q[10])
	# --- 接触尘
	i = 0
	while i + 6 < _contact.size():
		var q2 := _contact.slice(i, i + 7)
		i += 7
		if t < q2[0]:
			continue
		var p2 := contact_pos(q2, frozen)
		n += _speck(s, area, p2, t, q2[5], q2[6])
	# --- 歌词碎屑
	for wd in _words:
		var st := word_state(wd, t)
		if str(st["kind"]) == "whole":
			n += _draw_word(s, area, wd, st, t)
		else:
			for k in (st["list"] as Array).size():
				var v: Vector3 = st["list"][k]
				var d := float((wd.get("d", []) as Array)[mini(k, (wd.get("d", []) as Array).size() - 1)]) \
					if not (wd.get("d", []) as Array).is_empty() else 0.0
				var r := converge(v.x, v.y, d, t)
				if r.x < 0.0:
					continue
				n += _put_cell(s, area, r.x, r.y, "·", PV.mix(PV.ME_TEXT, minf(1.0, v.z * r.z)))
	return n


# ---------------------------------------------------------------- 内部

static func _speck(s: PvScreen, area: Rect2i, p: Vector3, t: float, sz: float, d: float) -> int:
	var r := converge(p.x, p.y, d, t)
	if r.x < 0.0:
		return 0
	var ch := "·" if sz >= 3.0 else "."
	return _put_cell(s, area, r.x, r.y, ch, PV.mix(PV.ME_TEXT, minf(1.0, p.z * r.z)))


static func _draw_word(s: PvScreen, area: Rect2i, wd: Dictionary, st: Dictionary, _t: float) -> int:
	var col := int(wd.get("col", PV.ME_TEXT))
	var al := float(st.get("alpha", 1.0))
	var pos: Vector2 = st["pos"]
	var n := 0
	if str(wd.get("kind", "t")) == "t":
		var text := str(wd.get("s", ""))
		var c := _cell_of(pos.x, pos.y, area)
		for k in text.length():
			n += _put_cell_at(s, c.x + k, c.y, text.substr(k, 1), PV.mix(col, al))
	else:
		var box: Array = wd.get("box", [0, 0, 0, 0])
		var a := _cell_of(float(box[0]), float(box[1]), area)
		var b := _cell_of(float(box[2]), float(box[3]), area)
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
				n += _put_cell_at(s, x, y, "█", PV.mix(col, al))
	return n


static func _cell_of(x: float, y: float, area: Rect2i) -> Vector2i:
	var nx := (x - FILM.position.x) / float(FILM.size.x)
	var ny := (y - FILM.position.y) / float(FILM.size.y)
	return Vector2i(
		area.position.x + roundi(nx * float(area.size.x - 1)),
		area.position.y + roundi(ny * float(area.size.y - 1)))


static func _put_cell(s: PvScreen, area: Rect2i, x: float, y: float, ch: String, col: int) -> int:
	var c := _cell_of(x, y, area)
	return _put_cell_at(s, c.x, c.y, ch, col)


static func _put_cell_at(s: PvScreen, x: int, y: int, ch: String, col: int) -> int:
	if x < 0 or x >= s.cols or y < 0 or y >= s.rows:
		return 0
	if s.in_clear(x, y):
		return 0
	s.set_raw(x, y, ch, col)
	return 1


static func _ease_out(u: float) -> float:
	var x := clampf(u, 0.0, 1.0)
	return 1.0 - pow(1.0 - x, 3.0)
