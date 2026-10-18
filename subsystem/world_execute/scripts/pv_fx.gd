class_name PvFx
extends RefCounted

## FX 层：揭示（cut）/ 残影（trail）/ 抖动（shake）三件后处理。
##
## 暗角与扫描线在 `PvScreen.refresh_dim()` 里，此处只管「每帧压在新画面上的那层动作」。
## 逐函数对照 `tui_live.py` L211-657（fx_clear / beat_level / _cut_kind / _run_score / _word_runs /
## _carry_plan / _carry_target / _retain_rects / fx_cut / _cut_tables / _cut_seed / _fx_front /
## _fx_carry / fx_reveal / fx_trail / fx_shake / fx_apply），调度见 tools/ref/layout.md §4.7。
##
## 调用顺序（主场景照此接线）：
## ```
## s.begin_frame(t)
## PvFx.stage_cut(s, t, ent)     # 必须在面板绘制之前：吃的是「上一帧还在屏上的画面」
## PvPanels.draw(s, d, t, ent)   # 画出新画面（同时登记 CLEAR / NOGHOST）
## PvFx.apply(s, t, ent)         # 压旧格 / 撒毛刺 / 移行
## s.end_frame()                 # 收帧快照
## ```
##
## 与 Python 的差别只在「缓冲表示」：参考实现是每行一个 `(ch, fg, bg)` 元组表，本类是扁平数组，
## 所以三处整块搬运（cut 的 `cur` / `old` / `new` 快照）改成 `_snapshot()` + `_apply_snapshot()`。
## 相位/形状/阈值全部照抄，只有随机数换成 GDScript 的 RNG，因此同一次 cut 的**形状一致而具体
## 落点不同**（Python 侧是 Mersenne Twister + numpy，无法逐格复现）。

# ---------------------------------------------------------------- 静态状态
## 对应 Python 模块级 `_CUT[0] / _LAST_SHOT[0] / PREV_CLEAR`：跨帧存活的状态。
static var _cut: Dictionary = {}          # 进行中的揭示；空字典 = 无
static var _last_shot := -1                # 上一帧的镜头号（-1 = 还没有过）
static var _prev_clear: Array = []         # 上一帧的 CLEAR（一帧延迟，$layout §4.7）
static var _tables: Dictionary = {}        # `_cut_tables` 的备忘（对应 lru_cache 256）

## 1B 整窗位移的单边上限（px）。参考实现没有窗口抖动，这个量级按 §3 冲突 1 的「±2~6 px」取中。
const WIN_SHAKE_PX := 4


## `fx_clear`：清揭示与镜头记忆，并抹掉残影表。
static func reset(s: PvScreen = null) -> void:
	_cut = {}
	_last_shot = -1
	_prev_clear = []
	if s != null:
		s.ghost.clear()
		s.ghost_prev.fill(0)


## 只取消进行中的 cut（转场接管那一帧时用；不动镜头记忆与残影）。
static func cancel_cut() -> void:
	_cut = {}


## 记下当前镜头号但不排 cut（滑动转场已经承担了这次切换）。
static func mark_shot(idx: int) -> void:
	_last_shot = idx


# ---------------------------------------------------------------- 调度

## `draw()` 里「镜头号变了才排 cut」那一段（L3248-3254）。
static func stage_cut(s: PvScreen, t: float, ent: Dictionary) -> void:
	var idx := int(ent.get("index", -1)) if not ent.is_empty() else -1
	if idx == _last_shot:
		return
	if _last_shot != -1:
		fx_cut(s, t, ent)
	else:
		_cut = {}
	_last_shot = idx


## `fx_apply`（L647-657）：CLEAR 先落后一帧，再依次 reveal → trail → shake。
static func apply(s: PvScreen, t: float, ent: Dictionary) -> void:
	_prev_clear = s.clear_rects.duplicate(true)
	if not bool(PV.FX["on"]):
		return
	if bool(PV.FX["reveal"]):
		fx_reveal(s, t)
	if bool(PV.FX["trail"]):
		fx_trail(s)
	if bool(PV.FX["shake"]):
		fx_shake(s, t, ent)


# ---------------------------------------------------------------- cut：排戏（L363-412）

## `fx_cut`：给这次硬切挑一套机制（CUT_MECH 里点名过的就按点名的来）。
static func fx_cut(s: PvScreen, t: float, ent: Dictionary) -> void:
	if not (bool(PV.FX["on"]) and bool(PV.FX["reveal"])):
		_cut = {}
		return
	var i := int(ent.get("index", 0)) if not ent.is_empty() else 0
	var mech: Array = (PV.CUT_MECH.get(i, []) as Array) if bool(PV.FX["mech"]) else []
	var heavy := (not ent.is_empty()) and PV.CUT_HEAVY.has(str(ent.get("name", "")))
	var kind := "hard"
	if not mech.is_empty():
		for m in mech:
			var ml := str(m).to_lower()
			if ml == "scan" or ml == "unfold" or ml == "morph":
				kind = ml
				break
	else:
		if i % PV.CUT_REVEAL != 0 or heavy:
			_cut = {}
			return
		kind = _cut_kind(ent)
	var cols := s.cols
	var rows := s.rows
	var rnd := RandomNumberGenerator.new()
	rnd.seed = i * 7919 + 13
	var seed_pt := _cut_seed(kind, cols, rows, rnd)
	var sx := float(seed_pt[0])
	var sy := float(seed_pt[1])
	var tables := _cut_tables(kind, cols, rows, snappedf(sx, 0.001), snappedf(sy, 0.001), i)
	# `cur` 是 cut 播放期间屏幕上的画面：起始 = 上一帧，随后一格格被新画面替换。
	var c := {
		"t0": t, "kind": kind, "seed": i, "cols": cols, "rows": rows, "sy": sy,
		"order": tables[0], "sd": tables[1], "holds": [],
		"cur": _snapshot(s), "old": {}, "done": -1.0e9, "el": -1.0e9, "carry": {},
	}
	if mech.has("RETAIN"):
		c["holds"] = _retain_rects(c["cur"], cols, rows)
	if mech.has("CARRY"):
		c["carry"] = _carry_plan(c["cur"], cols, rows, rnd, c["cur"]["wide"], int(cols * 0.62))
		if not (c["carry"] as Dictionary).is_empty():
			(c["holds"] as Array).append([0, rows - 1, 0, -1, PV.CARRY_DUR])
	if not (c["holds"] as Array).is_empty():
		c["old"] = _snapshot(s)
	if kind == "hard" and (c["carry"] as Dictionary).is_empty() and (c["holds"] as Array).is_empty():
		_cut = {}
		return
	_cut = c


## `_cut_kind`（L224-240）：三类延迟场的判定；我们的镜头表没有 `alert_own`，用 `alert`。
static func _cut_kind(ent: Dictionary) -> String:
	if ent.is_empty():
		return "radial"
	var name := str(ent.get("name", ""))
	if str(ent.get("alert", "")) == "err" \
			or _has_any(name, ["collapse", "flood", "trapped", "strange", "black", "count", "exec"]):
		return "inward"
	if _has_any(name, ["travel", "unite", "tangent", "sine", "circle", "current", "deploy",
			"dualpipe", "whale", "dimension", "infinity", "limit", "points"]):
		return "sweep"
	return "radial"


## `_run_score`（L243-252）：被搬运的东西在片子里都是「名字」——数字/变量/路径优先。
static func _run_score(text: String) -> int:
	var score := text.length()
	var has_digit := false
	var has_upper := false
	var has_punct := false
	for ch in text:
		var u := ch.unicode_at(0)
		if u >= 48 and u <= 57:
			has_digit = true
		elif u >= 65 and u <= 90:
			has_upper = true
		if "=:/.".contains(ch):
			has_punct = true
	if has_digit:
		score += 3
	if has_upper:
		score += 2
	if has_punct:
		score += 2
	return score


## `_word_runs`（L255-294）：`buf[y0..y1]` 里「词」的横向游程，越长越像名字的排前面。
static func _word_runs(snap: Dictionary, cols: int, rows: int, y0: int, y1: int,
		wide: PackedByteArray, rects: Array, x_max: int = -1) -> Array:
	var out: Array = []
	var cps: PackedInt32Array = snap["cp"]
	var box_chars := "─│┌┐└┘├┤┬┴┼╭╮╰╯"
	for y in range(y0, mini(rows, y1 + 1)):
		var base := y * cols
		var blocked: Array = []
		for r in rects:
			if int(r[1]) <= y and y <= int(r[3]):
				blocked.append([int(r[0]), int(r[2])])
		if x_max >= 0:
			blocked.append([x_max, cols - 1])
		var boxes := 0
		for x in cols:
			if box_chars.contains(char(cps[base + x])):
				boxes += 1
		if boxes > 6:
			continue                      # 这是框线行或标题行，不是画面正文
		var busy := 0
		for x in cols:
			if _is_alnum(cps[base + x]) and not _in_spans(x, blocked):
				busy += 1
		if busy < 12:
			continue
		var x := 0
		while x < cols:
			if wide[base + x] == 1 or _in_spans(x, blocked) or not _is_run_char(cps[base + x]):
				x += 1
				continue
			var x1 := x
			while x1 < cols and wide[base + x1] == 0 and not _in_spans(x1, blocked) \
					and _is_run_char(cps[base + x1]):
				x1 += 1
			if x1 - x >= 3 and x1 - x < PV.CARRY_CELLS + 1:
				var text := ""
				for k in range(x, x1):
					text += char(cps[base + k])
				out.append([_run_score(text) + mini(8, busy / 8), y, x, x1 - 1])
			x = x1 + 1
	out.sort_custom(func(a: Array, b: Array) -> bool:
		if int(a[0]) != int(b[0]):
			return int(a[0]) > int(b[0])
		if int(a[1]) != int(b[1]):
			return int(a[1]) < int(b[1])
		return int(a[2]) < int(b[2]))
	return out


## `_carry_plan`（L297-310）：从旧画面上拎起一个「名字」。
static func _carry_plan(snap: Dictionary, cols: int, rows: int, rnd: RandomNumberGenerator,
		wide: PackedByteArray, x_max: int) -> Dictionary:
	var runs := _word_runs(snap, cols, rows, 1, rows - 6, wide, _prev_clear, x_max)
	if runs.is_empty():
		return {}
	var r: Array = runs[0]
	var y := int(r[1])
	var x0 := int(r[2])
	var x1 := int(r[3])
	var cps: PackedInt32Array = snap["cp"]
	var fgs: PackedInt32Array = snap["fg"]
	var cells: Array = []
	for x in range(x0, x1 + 1):
		cells.append([x, y, cps[y * cols + x], fgs[y * cols + x]])
	var bends := [-0.22, -0.12, 0.12, 0.22]
	return {
		"cells": cells, "src": [(x0 + x1) / 2.0, float(y)], "dst": null, "span": null,
		"bend": bends[rnd.randi_range(0, 3)],
	}


## `_carry_target`（L313-328）：落在新画面里最像名字的那一段上，否则落到画面中部。
static func _carry_target(new: Dictionary, carry: Dictionary, cols: int, rows: int,
		wide: PackedByteArray, x_max: int, clear_rects: Array) -> void:
	var runs := _word_runs(new, cols, rows, 1, rows - 6, wide, clear_rects, x_max)
	var src: Array = carry["src"]
	var sx := float(src[0])
	var sy := float(src[1])
	var best: Variant = null
	var best_d := 0.0
	for k in mini(6, runs.size()):
		var rr: Array = runs[k]
		var y := int(rr[1])
		var x0 := int(rr[2])
		var x1 := int(rr[3])
		var cx := (x0 + x1) / 2.0
		var d := absf(cx - sx) * 0.6 + absf(float(y) - sy)
		if d > best_d and absf(cx - sx) + absf(float(y) - sy) >= 12.0:
			best = [y, x0, x1]
			best_d = d
	if best == null:
		carry["dst"] = [sx if (sx > 1.0 and sx < cols - 2) else cols / 2.0, float(rows) * 0.42]
		return
	var by := int(best[0])
	var bx0 := int(best[1])
	var bx1 := int(best[2])
	carry["dst"] = [(bx0 + bx1) / 2.0, float(by)]
	carry["span"] = [by, bx0, bx1]


## `_retain_rects`（L331-360）：把画面最密的一段「钉」在原地。返回 `[y0,y1,x0,x1,hold]`。
static func _retain_rects(snap: Dictionary, cols: int, rows: int) -> Array:
	var cps: PackedInt32Array = snap["cp"]
	var bands: Array = []
	for y in range(2, rows - 6):
		var ink := 0
		for x in cols:
			if cps[y * cols + x] != 32 and cps[y * cols + x] != 0:
				ink += 1
			if cps[(y + 1) * cols + x] != 32 and cps[(y + 1) * cols + x] != 0:
				ink += 1
		bands.append([ink, y])
	bands.sort_custom(func(a: Array, b: Array) -> bool:
		if int(a[0]) != int(b[0]):
			return int(a[0]) > int(b[0])
		return int(a[1]) < int(b[1]))
	var tried := 0
	for band in bands:
		if tried >= 8:
			break
		tried += 1
		var y0 := int(band[1])
		var y1 := mini(rows - 5, y0 + 1)
		var cols_on: Array = []
		for x in cols:
			var blocked := false
			for r in _prev_clear:
				if int(r[0]) <= x and x <= int(r[2]) and int(r[1]) <= y0 and y0 <= int(r[3]):
					blocked = true
					break
			if blocked:
				continue
			if (cps[y0 * cols + x] != 32 and cps[y0 * cols + x] != 0) \
					or (cps[y1 * cols + x] != 32 and cps[y1 * cols + x] != 0):
				cols_on.append(x)
		if cols_on.size() < 8:
			continue
		var run: Array = [cols_on[0]]
		var best: Array = [cols_on[0]]
		for k in range(1, cols_on.size()):
			var x := int(cols_on[k])
			if x - int(run[run.size() - 1]) <= 2:
				run.append(x)
			else:
				run = [x]
			if run.size() > best.size():
				best = run
		if best.size() < 6:
			continue
		var x0 := int(best[0])
		var x1 := int(best[best.size() - 1])
		if x1 - x0 > PV.RETAIN_WIDE:            # 保持「一块」而不是整行，以自身的墨迹居中
			var cx := (x0 + x1) / 2
			x0 = cx - PV.RETAIN_WIDE / 2
			x1 = cx + PV.RETAIN_WIDE / 2
		return [[y0, y1, maxi(1, x0 - 1), mini(cols - 2, x1 + 1), PV.RETAIN_HOLD]]
	return []


# ---------------------------------------------------------------- 延迟场（L415-467）

## `_cut_tables`（L415-453）：一套延迟场的 `(每行的切换顺序, 每行排序后的延迟)`。
## numpy 段全部手写；结果按 `lru_cache` 的语义备忘（同一形状+尺寸+种子只算一次）。
static func _cut_tables(kind: String, cols: int, rows: int, sx: float, sy: float,
		seed: int) -> Array:
	if kind == "hard" or kind == "retain":
		return [null, null]
	var key := "%s|%d|%d|%.3f|%.3f|%d" % [kind, cols, rows, sx, sy, seed]
	if _tables.has(key):
		return _tables[key]
	var n := cols * rows
	var d := PackedFloat32Array()
	d.resize(n)
	if kind == "scan":
		for y in rows:
			var v := (y + 0.5) / float(rows) * PV.CUT_DUR
			for x in cols:
				d[y * cols + x] = v
	elif kind == "unfold":
		var y0 := clampi(int(roundf(sy / 2.0)), 0, rows - 1)
		var far_max := 1.0
		for y in rows:
			far_max = maxf(far_max, absf(float(y) - float(y0)))
		for y in rows:
			var v := absf(float(y) - float(y0)) / far_max * PV.CUT_DUR
			for x in cols:
				d[y * cols + x] = v
	elif kind == "morph":
		var rng := RandomNumberGenerator.new()
		rng.seed = seed * 7919 + 5
		for i in n:
			d[i] = rng.randf() * PV.CUT_DUR
	else:
		var lo := INF
		var hi := -INF
		for y in rows:
			for x in cols:
				var v := sqrt(pow(float(x) - sx, 2.0) + pow(float(y) * 2.0 - sy, 2.0))
				d[y * cols + x] = v
				lo = minf(lo, v)
				hi = maxf(hi, v)
		var span := maxf(1e-6, hi - lo)
		for i in n:
			var u := (d[i] - lo) / span
			if kind == "inward":
				u = 1.0 - u
			d[i] = u * PV.CUT_DUR
	var order: Array = []
	var sd: Array = []
	for y in rows:
		var pairs: Array = []
		for x in cols:
			pairs.append([d[y * cols + x], x])
		pairs.sort_custom(func(a: Array, b: Array) -> bool:
			if float(a[0]) == float(b[0]):
				return int(a[1]) < int(b[1])
			return float(a[0]) < float(b[0]))
		var orow: Array = []
		var srow := PackedFloat32Array()
		srow.resize(cols)
		for x in cols:
			orow.append(int(pairs[x][1]))
			srow[x] = float(pairs[x][0])
		order.append(orow)
		sd.append(srow)
	var result := [order, sd]
	_tables[key] = result
	return result


## `_cut_seed`（L456-467）：延迟场从哪儿开始（片子自己的种子是镜头主体，不是画面正中）。
static func _cut_seed(kind: String, cols: int, rows: int, rnd: RandomNumberGenerator) -> Array:
	var cx := (cols - 1) / 2.0
	var cy := (rows - 1) / 2.0
	var picks := [-0.5, -0.2, 0.0, 0.2, 0.5]
	if kind == "sweep":
		if rnd.randf() < 0.75:
			return [(-1.0 * cols if rnd.randf() < 0.5 else 2.0 * cols), cy]
		return [cx, (-1.0 * rows if rnd.randf() < 0.5 else 2.0 * rows)]
	if kind == "inward":
		return [cx, cy]                    # inward 是往中间收
	return [cx + picks[rnd.randi_range(0, 4)] * cols, cy + picks[rnd.randi_range(0, 4)] * rows]


# ---------------------------------------------------------------- cut：播放（L477-584）

## `_fx_front`（L477-495）：扫过的那道亮线——scan 自顶向下，unfold 从一行向两边张开。
static func _fx_front(s: PvScreen, c: Dictionary, el: float) -> void:
	var rows := int(c["rows"])
	var cols := int(c["cols"])
	var u := clampf(el / PV.CUT_DUR, 0.0, 1.0)
	var ys: Array = []
	if str(c["kind"]) == "scan":
		ys.append(mini(rows - 1, int(u * rows)))
	else:
		var sy := float(c["sy"])
		var span := maxf(1.0, maxf(sy / 2.0, float(rows - 1) - sy / 2.0))
		ys.append(int(roundf(sy / 2.0 - u * span)))
		ys.append(int(roundf(sy / 2.0 + u * span)))
	var fg := PV.mix(PV.ME_TEXT, 0.95)
	for yv in ys:
		var y := int(yv)
		if y < 0 or y >= rows:
			continue
		var base := y * cols
		for x in cols:
			if s.cp[base + x] != 32 and s.wide[base + x] == 0 and not s.in_clear(x, y):
				s.set_raw(x, y, "─", fg, PV.BG)


## `_fx_carry`（L497-523）：被搬的东西在弧线上飞（三次贝塞尔）；它会飞过 CLEAR 区。
static func _fx_carry(s: PvScreen, c: Dictionary, el: float) -> void:
	var k: Dictionary = c["carry"]
	var dst: Variant = k.get("dst")
	if dst == null:
		return
	var u := clampf(el / PV.CARRY_DUR, 0.0, 1.0)
	if u >= 1.0:
		return
	var e := 4.0 * pow(u, 3.0) if u < 0.5 else 1.0 - pow(-2.0 * u + 2.0, 3.0) / 2.0
	var src: Array = k["src"]
	var sx := float(src[0])
	var sy := float(src[1])
	var dx := float(dst[0])
	var dy := float(dst[1])
	var vx := dx - sx
	var vy := dy - sy
	var bend := float(k["bend"]) * sin(PI * u)
	var lit := PV.mix(0xecf2ff, 0.6 + 0.4 * u)
	for cell in (k["cells"] as Array):
		var px := float(cell[0]) + vx * e - vy * bend
		var py := float(cell[1]) + vy * e + vx * bend
		var xx := int(roundf(px))
		var yy := int(roundf(py))
		if xx < 0 or xx >= s.cols or yy < 0 or yy >= s.rows or s.wide[yy * s.cols + xx] == 1:
			continue
		if xx + 1 < s.cols and s.wide[yy * s.cols + xx + 1] == 1:
			s.drop_wide(xx + 1, yy)         # 右半格还挂着旧双宽字，先摘掉
		s.set_raw(xx, yy, char(int(cell[2])), lit, PV.BG)


## `fx_reveal`（L526-584）：还没到点的格子留旧画面，正在切换的格子撒毛刺。
static func fx_reveal(s: PvScreen, t: float) -> void:
	if _cut.is_empty():
		return
	var c := _cut
	var el := t - float(c["t0"])
	c["el"] = el
	var carry: Dictionary = c["carry"]
	if el > PV.CUT_DUR + PV.CUT_CELL + 0.05 and (carry.is_empty() or el > PV.CARRY_DUR + 0.05):
		_cut = {}
		return
	var new := _snapshot(s)
	var cols := int(c["cols"])
	var rows := int(c["rows"])
	if not carry.is_empty() and carry.get("dst") == null:
		_carry_target(new, carry, cols, rows, new["wide"], int(cols * 0.62), s.clear_rects)
		var span: Variant = carry.get("span")
		var holds: Array = c["holds"]
		if span != null:                     # 落点定了：那一带先空着等它落地
			holds[holds.size() - 1] = [int(span[0]), int(span[0]), int(span[1]), int(span[2]),
				PV.CARRY_DUR]
		elif not holds.is_empty():
			holds.pop_back()
		if holds.is_empty():
			c["old"] = {}
	if c["order"] != null:
		var cur: Dictionary = c["cur"]
		var order: Array = c["order"]
		var sd: Array = c["sd"]
		var seed := int(c["seed"])
		var done := float(c["done"])
		var front := el - PV.CUT_CELL    # 比这更晚才切换的格子还在解码
		c["done"] = front
		c["el"] = el
		for y in rows:
			var srow: PackedFloat32Array = sd[y]
			var orow: Array = order[y]
			var p1 := _bisect_right(srow, el)
			var p0 := _bisect_right(srow, done)
			if p1 > p0:
				var base := y * cols
				for k in range(p0, p1):
					_copy_cell(new, base + int(orow[k]), cur, base + int(orow[k]))
				var g0 := _bisect_right(srow, front)
				for k in range(g0, p1):
					var x := int(orow[k])
					if (x * 31 + y * 17 + seed * 7) % 100 < int(PV.CUT_FRONT * 100.0) \
							and not s.in_clear(x, y):
						var kk := clampf((el - srow[k]) / PV.CUT_CELL, 0.0, 1.0)
						var gi := base + x
						var gc := _glitch(t, x + y * cols)
						cur["cp"][gi] = gc.unicode_at(0)
						cur["slot"][gi] = s.atlas.slot_of(gc)
						cur["fg"][gi] = PV.mix(PV.ME_TEXT, 0.2 + 0.6 * kk)
						cur["bg"][gi] = PV.BG
						cur["wide"][gi] = 0
		_apply_snapshot(s, cur)
		if str(c["kind"]) == "scan" or str(c["kind"]) == "unfold":
			_fx_front(s, c, el)
	var old: Dictionary = c["old"]
	if not old.is_empty():
		for h in (c["holds"] as Array):
			var y0 := int(h[0])
			var y1 := int(h[1])
			var x0 := int(h[2])
			var x1 := int(h[3])
			var until := float(h[4])
			if el < until:
				for y in range(maxi(0, y0), mini(rows, y1 + 1)):
					var base := y * cols
					for x in range(maxi(0, x0), x1 + 1):
						if x < cols:
							s.set_full(x, y, old["cp"][base + x], old["slot"][base + x],
								old["fg"][base + x], old["bg"][base + x], old["wide"][base + x])
	for r in s.clear_rects:                  # CLEAR 区切得干干净净：没有保持，也没有毛刺
		var a := int(r[0])
		var b := int(r[1])
		var e := int(r[2])
		var d := int(r[3])
		for y in range(maxi(0, b), mini(s.rows, d + 1)):
			var base := y * cols
			for x in range(maxi(0, a), mini(s.cols, e + 1)):
				s.set_full(x, y, new["cp"][base + x], new["slot"][base + x], new["fg"][base + x],
					new["bg"][base + x], new["wide"][base + x])
	if not carry.is_empty():
		_fx_carry(s, c, el)


# ---------------------------------------------------------------- 残影与抖动（L586-657）

## `fx_trail`（L586-614）：每格级别 `*=0.42`，低于 0.06 丢弃；只喂「新变空的格子」。
static func fx_trail(s: PvScreen) -> void:
	var cols := s.cols
	var rows := s.rows
	var g: Dictionary = s.ghost
	var keys := g.keys()
	for key in keys:
		var v: Array = g[key]
		var lv := float(v[2]) * PV.TRAIL
		if lv < PV.TRAIL_MIN:
			g.erase(key)
		else:
			g[key] = [v[0], v[1], lv]
	for y in rows:
		if s.row_same(y):
			continue
		var base := y * cols
		var keep := not s.row_covered(y, s.noghost_rects)
		for x in cols:
			var i := base + x
			if s.cp[i] == 32 and s.ghost_prev[i] == 0 \
					and s.prev_cp[i] != 32 and s.prev_cp[i] != 0:
				if keep or not s.col_covered(x, s.noghost_rects):
					g[i] = [s.prev_cp[i], s.prev_fg[i], PV.TRAIL]
	var gh := PackedByteArray()
	gh.resize(cols * rows)
	for key in g.keys():
		var i := int(key)
		var y := i / cols
		var x := i % cols
		if s.cp[i] == 32:
			var v: Array = g[i]
			var f := int(v[1])
			var lv := float(v[2])
			s.set_raw(x, y, char(int(v[0])),
				PV.rgb(int(PV.ch_r(f) * lv), int(PV.ch_g(f) * lv), int(PV.ch_b(f) * lv)), PV.BG)
			gh[i] = 1
	s.ghost_prev = gh


## `fx_shake`（L624-644）：只在拍点上、且系统是红的（err）才抖；整行循环移位。
##
## C 层决策（`tools/ref/c_layer_plan.md` §7 冲突 1）：真实窗口可用时由 **1B 整窗位移**接管
## （`window_offset()`），此处不再做行位移——两套叠加会「窗在跳、格又在滑」，观感反而更碎。
## headless / 内嵌窗口下 `use_window_shake` 恒为 false，这里保持参考实现的原样行为（可断言）。
static var use_window_shake := false


static func fx_shake(s: PvScreen, t: float, ent: Dictionary) -> void:
	if use_window_shake:
		return
	if ent.is_empty():
		return
	if not (str(ent.get("alert", "")) == "err" or PV.SHAKE_SHOTS.has(str(ent.get("name", "")))):
		return
	var k := PV.pulse(t)
	if k < PV.SHAKE_LEVEL:
		return
	var rnd := RandomNumberGenerator.new()
	rnd.seed = int(t * 24.0) * 977 + int(ent.get("index", 0))
	var cols := s.cols
	for y in s.rows:
		if rnd.randf() > 0.15 * k:
			continue
		var off := 0
		if rnd.randf() < k:
			off = int(rnd.randfn(0.0, 2.2))
		if off == 0 or absi(off) >= cols:
			continue
		s.shift_row(y, off)
		s.shift_ghost_row(y, off)


## 1B 真窗口抖动：与 `fx_shake` **同一触发条件**（`SHAKE_SHOTS` 或 `alert=="err"`，且脉冲过阈值），
## 但位移量按像素算、作用于整个 OS 窗口（A/B 两层一起动，所以不会出现格与终端错位）。
## 返回 `Vector2i` 像素偏移；不抖时返回零。
static func window_offset(t: float, ent: Dictionary) -> Vector2i:
	if not (bool(PV.FX["on"]) and bool(PV.FX["shake"])):
		return Vector2i.ZERO
	if ent.is_empty():
		return Vector2i.ZERO
	if not (str(ent.get("alert", "")) == "err" or PV.SHAKE_SHOTS.has(str(ent.get("name", "")))):
		return Vector2i.ZERO
	var k := PV.pulse(t)
	if k < PV.SHAKE_LEVEL:
		return Vector2i.ZERO
	var rnd := RandomNumberGenerator.new()
	rnd.seed = int(t * 24.0) * 977 + int(ent.get("index", 0))
	var dx := rnd.randfn(0.0, 1.6) * k
	var dy := rnd.randfn(0.0, 0.7) * k
	return Vector2i(
		clampi(roundi(dx), -WIN_SHAKE_PX, WIN_SHAKE_PX),
		clampi(roundi(dy), -WIN_SHAKE_PX, WIN_SHAKE_PX))


# ---------------------------------------------------------------- 工具

## 整屏快照（cp/slot/fg/bg/wide 各一份副本），对应 Python 的 `[r[:] for r in s.buf]`。
static func _snapshot(s: PvScreen) -> Dictionary:
	return {
		"cp": s.cp.duplicate(), "slot": s.slot.duplicate(), "fg": s.fg.duplicate(),
		"bg": s.bg.duplicate(), "wide": s.wide.duplicate(),
	}


## 把快照整份搬回屏幕（含三张纹理字节的重写——这一步绕过了 `_set_cell`）。
static func _apply_snapshot(s: PvScreen, snap: Dictionary) -> void:
	s.cp = (snap["cp"] as PackedInt32Array).duplicate()
	s.slot = (snap["slot"] as PackedInt32Array).duplicate()
	s.fg = (snap["fg"] as PackedInt32Array).duplicate()
	s.bg = (snap["bg"] as PackedInt32Array).duplicate()
	s.wide = (snap["wide"] as PackedByteArray).duplicate()
	var n := s.cols * s.rows
	for i in n:
		s._write_bytes(i, s.slot[i], s.fg[i], s.bg[i])


static func _copy_cell(src: Dictionary, si: int, dst: Dictionary, di: int) -> void:
	dst["cp"][di] = src["cp"][si]
	dst["slot"][di] = src["slot"][si]
	dst["fg"][di] = src["fg"][si]
	dst["bg"][di] = src["bg"][si]
	dst["wide"][di] = src["wide"][si]


static func _bisect_right(arr: PackedFloat32Array, value: float) -> int:
	var lo := 0
	var hi := arr.size()
	while lo < hi:
		var mid := (lo + hi) / 2
		if value < arr[mid]:
			hi = mid
		else:
			lo = mid + 1
	return lo


static func _glitch(t: float, k: int) -> String:
	return PV.SCRAMBLE.substr((k * 31 + int(t * 97)) % PV.SCRAMBLE.length(), 1)


static func _has_any(s: String, keys: Array) -> bool:
	for k in keys:
		if s.contains(str(k)):
			return true
	return false


static func _is_alnum(c: int) -> bool:
	return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


static func _is_run_char(c: int) -> bool:
	if _is_alnum(c):
		return true
	return c == 95 or c == 61 or c == 58 or c == 47 or c == 46 or c == 45 or c == 43 or c == 39


static func _in_spans(x: int, spans: Array) -> bool:
	for sp in spans:
		if int(sp[0]) <= x and x <= int(sp[1]):
			return true
	return false
