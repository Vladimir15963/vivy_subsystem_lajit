class_name PvShots
extends RefCounted

## 镜头表 / 章节 / 节拍 / UI 增益 —— 从 data/*.json 静态懒加载的派生逻辑。
##
## 与参考实现对应：`film_panels.chapter/chapter_start/ui_gain_at/shot_wants_figure/portrait_shots/
## kv_inset/dsh_gone_pair/dsh_spans`，以及 `tui_live.Data.chapter`。这些都是「由镜头表推出来的
## 小逻辑」，与重数据（波形/特征/歌词）分开，所以单独一个静态类，不需要实例。

const DATA := "res://subsystem/world_execute/data/"

static var _loaded := false
static var _chapters: Array = []          # [[t, label]]
static var _shots: Array = []             # [{index,name,start,end,chapter,alert,ops,her}]
static var _meta: Dictionary = {}
static var _gain: PackedFloat32Array = PackedFloat32Array()
static var _gain_hz := 10.0
static var _portraits: Dictionary = {}
static var _figures: Array = []           # [[a, b]]
static var _dsh_spans: Array = []         # [[a, b]]


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_chapters = _json("chapters.json", [])
	_shots = _json("shots.json", [])
	_meta = _json("shots_meta.json", {})
	var g: Variant = _json("gain.json", {})
	if typeof(g) == TYPE_DICTIONARY:
		_gain_hz = float(g.get("hz", 10))
		_gain = PackedFloat32Array(g.get("values", []))
	_portraits = _json("portrait_shots.json", {})
	_figures = _json("figure_spans.json", [])
	_dsh_spans = _json("dsh_spans.json", [])


static func _json(name: String, fallback: Variant) -> Variant:
	var raw := FileAccess.get_file_as_string(DATA + name)
	if raw.is_empty():
		push_error("world_execute: 读取 data/%s 失败" % name)
		return fallback
	var v: Variant = JSON.parse_string(raw)
	return fallback if v == null else v


# ---------------------------------------------------------------- 元数据

static func meta() -> Dictionary:
	_ensure()
	return _meta


static func fps() -> float:
	return float(meta().get("fps", 24))


## 片尾硬切（207.0833）与全片终点（211.0）。
static func hard_cut() -> float:
	return float(meta().get("hard_cut", 207.0833))


static func shots() -> Array:
	_ensure()
	return _shots


static func chapters() -> Array:
	_ensure()
	return _chapters


# ---------------------------------------------------------------- 章节（§1.4）

static func chapter_at(t: float) -> String:
	_ensure()
	var label := ""
	for row in _chapters:
		if float(row[0]) <= t:
			label = str(row[1])
	return label


## `film_panels.chapter_start("EXECUTION")`：标签（含 "07 / EXECUTION" 这种全名）的起始秒。
static func chapter_start(tag: String, default := 0.0) -> float:
	_ensure()
	for row in _chapters:
		var label := str(row[1])
		if label == tag or label.ends_with("/ " + tag) or label.contains(tag):
			return float(row[0])
	return default


# ---------------------------------------------------------------- 镜头

## t 落在哪个镜头里；越界时贴到首/尾。
static func shot_index_at(t: float) -> int:
	_ensure()
	if _shots.is_empty():
		return -1
	var n := _shots.size()
	if t <= float(_shots[0]["start"]):
		return 0
	if t >= float(_shots[n - 1]["end"]):
		return n - 1
	var lo := 0
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi) / 2
		if float(_shots[mid]["end"]) <= t:
			lo = mid + 1
		else:
			hi = mid
	return lo


## 当前镜头字典；无镜头表时返回 {}。
static func shot_at(t: float) -> Dictionary:
	_ensure()
	var i := shot_index_at(t)
	return {} if i < 0 else _shots[i]


## 该镜头的「本地进度」u ∈ [0,1]（供单镜头内部动画用，例如 kv_inset）。
static func shot_u(t: float, ent: Dictionary) -> float:
	if ent.is_empty():
		return 0.0
	var a := float(ent["start"])
	var b := float(ent["end"])
	return clampf((t - a) / max(1e-6, b - a), 0.0, 1.0)


# ---------------------------------------------------------------- UI 增益

static func gain_at(t: float) -> float:
	_ensure()
	if _gain.is_empty():
		return 1.0
	var i := clampi(int(t * _gain_hz), 0, _gain.size() - 1)
	return _gain[i]


## 本帧的 UI 增益，含电影的三处逐镜头覆盖（film_panels.py:202-210，逐字照抄）：
##   shot_red_if_i_can / shot_red_then_i_can 整个镜头钉在 1.0；
##   shot_have_you_back 在 u<0.75 且 sin(t*40)>0.3 时闪回 1.0。
static func ui_gain_at(t: float, name: String, u: float) -> float:
	if name == "shot_red_if_i_can" or name == "shot_red_then_i_can":
		return 1.0
	if name == "shot_have_you_back" and sin(t * 40.0) > 0.3 and u < 0.75:
		return 1.0
	return gain_at(t)


# ---------------------------------------------------------------- 立绘判定（§1.5）

static func portrait_shots() -> Dictionary:
	_ensure()
	return _portraits


static func figure_spans() -> Array:
	_ensure()
	return _figures


## 这个镜头是否「大部分时间」落在她该出现的时间段里（超过 40 % 才算）。
static func shot_wants_figure(start: float, end: float) -> bool:
	_ensure()
	var inside := 0.0
	for sp in _figures:
		inside += max(0.0, min(end, float(sp[1])) - max(start, float(sp[0])))
	return inside >= 0.40 * max(1e-6, end - start)


## `film_panels.kv_inset`：她的框每拍少一堵墙，0-3。
static func kv_inset(u: float) -> int:
	return min(3, int(u * 4.0))


# ---------------------------------------------------------------- dsh 聊天窗

static func dsh_spans() -> Array:
	_ensure()
	return _dsh_spans


static func dsh_inside(t: float) -> bool:
	for sp in dsh_spans():
		if float(sp[0]) <= t and t < float(sp[1]):
			return true
	return false


## `dsh_her.py` 的 GONE / BACK：115.42 / 121.77。
static func dsh_gone_pair() -> Array:
	return [115.42, 121.77]


static func dsh_gone(t: float) -> bool:
	var p := dsh_gone_pair()
	return float(p[0]) <= t and t < float(p[1])
