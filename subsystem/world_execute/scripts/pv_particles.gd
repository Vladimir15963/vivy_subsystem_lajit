class_name PvParticles
extends RefCounted

## C 层粒子：`shot_points` 的 1400 点「embedding(me)」点云。
##
## 数据来自 `data/points_set.bin`（`tools/build_data.py: build_point_set()` 离线烘焙的固定表，
## 每点 5 个 f32：`tx, ty, lv, rx, ry`）——**按决策 §7 Q8 不使用运行时 RNG**，逐点可复现。
##
## 运动公式逐字照抄 `continuity_full_v2/scenes.py:L288-297`（`points_pos()`）：
##
## ```
## g      = ease(u * 1.25)                        # ease = 1 - (1-x)^3
## jitter = (1 - g) * 6
## x      = rx + (tx - rx) * g + jitter * sin(t*5 + i)
## y      = ry + (ty - ry) * g + jitter * cos(t*4 + i)
## colour = blue(0.35 + 0.65*lv) if g > 0.3 else amb(0.4 + 0.4*lv)
## ```
##
## 参考坐标是 1280×720 的电影画布像素；本类把它线性映射进格区（`x0..x1 / y0..y1`）。

const DATA := "res://subsystem/world_execute/data/points_set.bin"
const META := "res://subsystem/world_execute/data/points_set.json"

## 参考 `scenes.py:L283-284` 的散布范围（电影画布像素）。
const FILM_X0 := 420.0
const FILM_X1 := 1140.0
const FILM_Y0 := 70.0
const FILM_Y1 := 590.0

static var _pts := PackedFloat32Array()
static var _n := 0
static var _loaded := false


## 读固定表（28 000 B = 1400 × 5 × f32）。缺文件时 `count()` 为 0，绘制静默跳过。
static func load_table() -> void:
	if _loaded:
		return
	_loaded = true
	var raw := FileAccess.get_file_as_bytes(DATA)
	if raw.is_empty():
		push_warning("world_execute: 缺少 data/points_set.bin，点云不绘制")
		return
	_pts = raw.to_float32_array()
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(META))
	var stride := 5
	if typeof(meta) == TYPE_DICTIONARY:
		stride = int(meta.get("stride", 5))
	if stride <= 0:
		stride = 5
	_n = _pts.size() / stride


static func point_count() -> int:
	load_table()
	return _n


## 第 i 个点的原始五项（`tx, ty, lv, rx, ry`）。
static func point(i: int) -> PackedFloat32Array:
	load_table()
	var o := i * 5
	return _pts.slice(o, o + 5)


## `ease()`（tuikit.py:L88-90）：1 - (1-x)³，两端钳死。
## 注意不能叫 `ease` —— Godot 有同名全局函数 `ease(x, curve)`，静态调用会解析到内置版本。
static func ease_out(u: float) -> float:
	var x := clampf(u, 0.0, 1.0)
	return 1.0 - pow(1.0 - x, 3.0)


## 第 i 个点在 `t` / 进度 `u` 时的电影画布坐标与亮度：`Vector3(x, y, lv)`。
static func pos_at(t: float, u: float, i: int) -> Vector3:
	load_table()
	if i < 0 or i >= _n:
		return Vector3.ZERO
	var o := i * 5
	var g := ease_out(u * 1.25)
	var jitter := (1.0 - g) * 6.0
	var x: float = _pts[o + 3] + (_pts[o] - _pts[o + 3]) * g + jitter * sin(t * 5.0 + i)
	var y: float = _pts[o + 4] + (_pts[o + 1] - _pts[o + 4]) * g + jitter * cos(t * 4.0 + i)
	return Vector3(x, y, _pts[o + 2])


## 电影画布坐标 → 格坐标（线性映射到给定格区）。
static func cell_of(x: float, y: float, r: Rect2i) -> Vector2i:
	var nx := (x - FILM_X0) / (FILM_X1 - FILM_X0)
	var ny := (y - FILM_Y0) / (FILM_Y1 - FILM_Y0)
	return Vector2i(
		r.position.x + roundi(nx * float(r.size.x - 1)),
		r.position.y + roundi(ny * float(r.size.y - 1)))


## 绘制点云，返回实际落笔的格数。
##
## 5A 口径：落在 CLEAR 区（含 stdout 带）的格**不画**——终端的那条带永远由 B 层独占。
static func draw_points(s: PvScreen, t: float, u: float, r: Rect2i) -> int:
	load_table()
	if _n <= 0 or r.size.x < 2 or r.size.y < 2:
		return 0
	var g := ease_out(u * 1.25)
	var drawn := 0
	for i in _n:
		var p := pos_at(t, u, i)
		var c := cell_of(p.x, p.y, r)
		if c.x < r.position.x or c.x >= r.position.x + r.size.x \
				or c.y < r.position.y or c.y >= r.position.y + r.size.y:
			continue
		if s.in_clear(c.x, c.y):
			continue
		var col: int
		if g > 0.3:
			col = PV.mix(PV.ME_TEXT, 0.35 + 0.65 * p.z)
		else:
			col = PV.mix(PV.ANOM, (0.4 + 0.4 * p.z) * PV.UI_GAIN)
		s.put(c.x, c.y, "·", col)
		drawn += 1
	return drawn
