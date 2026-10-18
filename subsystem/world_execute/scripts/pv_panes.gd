class_name PvPanes
extends RefCounted

## 章节面板：20 个 pane 的绘制。
##
## 逐函数对应参考实现 `tui_live.py` 的 `draw_corpus` / `draw_loss` / `draw_kv` / … 与
## `film_panels.py` 的数值表（版式规格见 tools/ref/layout.md §7）。分发与几何在
## `PvPanels._draw_chapter_pane()`，本类只负责「给定画区把内容填进字符格」。
##
## 数据来自 `data/panes.json`（`tools/build_data.py` 的 `build_panes()`）：参考实现里由 Python
## RNG / PIL 生成的表（loss 噪声、mask 热格、expert 高斯格、moe rank、逐拍 routed、whale 逐帧、
## Anton 横幅、decode 乱码序列、CORPUS、facts、KV/PIPE 常量）一律导出成表；纯数学（loss / lr /
## kv / pipe / moe / mask_time / love）在本文件里忠实重写。二选一，不混着来 —— 这样 Godot 端不会
## 出现「一半查表一半复算」的漂移。
##
## 已知取舍（见 subsystem/world_execute/README.md）：
##   * 她的立绘层用 `data/her_glyph.json`（44×36 的 8 个表情）代替 h3 全帧 take；samples /
##     conv / ifican 里的"她"是同一份字形格降采样，不是电影里那张贴图；
##   * ifican 的烟雾层用本帧固定的伪随机（Godot RNG 与 Python MT 不同），不是逐像素一致；
##   * expert 的乱码闪烁用「同帧号播种」的 Godot RNG 近似（Python MT 无法逐位复现）；其数值格
##     （Random(8) 的高斯）是烘进 JSON 的，逐值一致；
##   * whale 的尾巴按 24 fps 逐帧查表，两个扫过帧之间的 t 贴到最近的帧。

const DATA := "res://subsystem/world_execute/data/panes.json"
const HER := "res://subsystem/world_execute/data/her_glyph.json"

static var _D: Dictionary = {}
static var _loaded := false
static var _HER: Dictionary = {}
static var _her_loaded := false


# ---------------------------------------------------------------- 数据加载

static func _data() -> Dictionary:
	if not _loaded:
		_loaded = true
		var raw := FileAccess.get_file_as_string(DATA)
		if not raw.is_empty():
			var v: Variant = JSON.parse_string(raw)
			if typeof(v) == TYPE_DICTIONARY:
				_D = v
	return _D


static func _her() -> Dictionary:
	if not _her_loaded:
		_her_loaded = true
		var raw := FileAccess.get_file_as_string(HER)
		if not raw.is_empty():
			var v: Variant = JSON.parse_string(raw)
			if typeof(v) == TYPE_DICTIONARY:
				_HER = v
	return _HER


# ---------------------------------------------------------------- 通用工具

## tuikit.ease：三次缓出 `1-(1-u)^3`（注意不是 smoothstep）。
static func _ease(u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	var k := 1.0 - u
	return 1.0 - k * k * k


## tuikit.smooth：smoothstep `u*u*(3-2*u)`（kv_fill / loss_progress 用它）。
static func _smooth(u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


## Python 的向下取整除法（分子可能为负时不能直接用 GDScript 的截断除法）。
static func _fdiv(a: int, b: int) -> int:
	return floori(float(a) / float(b))


## `f"{n:,}"`：千分位。
static func _comma(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s.substr(i, 1) + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out


## `f"{v:5.1%}"`：百分比、宽度 5（含 %）。
static func _pct1(v: float) -> String:
	return ("%.1f%%" % (v * 100.0)).rpad(5)


# ---------------------------------------------------------------- 分发表（§7）

## 镜头名 + 右列内宽 → `[pane, need, least]`；无面板时 `["", 0, 0]`（与参考实现逐条一致）。
static func spec(name: String, rw: int) -> Array:
	var d := _data()
	if name == "shot_corpus":
		return ["corpus", 10, 6]
	if name == "shot_losscurve":
		return ["loss", 13, 8]
	var mk: Dictionary = d.get("mask", {})
	if name == "shot_blind":
		return ["mask", int(mk.get("n", 12)) + 2, int(mk.get("n", 12)) + 2]
	if name == "shot_memory_ls" or name == "shot_erase":
		return ["memory", 13, 8]
	var kv: Dictionary = d.get("kv", {})
	if (name == "shot_trapped" or name == "shot_red_trapped") and rw >= int(kv.get("cols", 60)):
		return ["kv", int(kv.get("rows", 22)) + 6, int(kv.get("rows", 22)) + 4]
	var ex: Dictionary = d.get("expert", {})
	if name == "shot_strange" and rw >= 46:
		return ["expert", int(ex.get("rows", 24)) + 2, int(ex.get("rows", 24)) + 2]
	if name == "shot_circle" and rw >= 40:
		return ["rope", 16, 12]
	if name == "shot_sine" and rw >= 30:
		return ["sine", 18, 12]
	if name == "shot_tangent" and rw >= 30:
		return ["tangent", 14, 9]
	if name == "shot_limit" and rw >= 30:
		return ["limit", 10, 8]
	if name == "shot_current" and rw >= 30:
		return ["gpu", 12, 10]
	if (name == "shot_then_i_can" or name == "shot_red_then_i_can") and rw >= 70:
		return ["conv", 16, 12]
	if name == "shot_simulations" and rw >= 40:
		return ["samples", 20, 14]
	if name == "shot_execute_all" and rw >= 40:
		return ["exec_all", 20, 14]
	if name == "shot_red_if_i_can" and rw >= 40:
		return ["ifican", 18, 12]
	if name == "shot_only_execution" and rw >= 44:
		return ["logits", 15, 11]
	var wh: Dictionary = d.get("whale", {})
	if name == "shot_whale" and rw >= int(wh.get("cols", 64)) + 2:
		return ["whale", int(wh.get("rows", 17)) + 8, int(wh.get("rows", 17)) + 2]
	var pipe: Dictionary = d.get("pipe", {})
	if name == "shot_dualpipe" and rw >= int(pipe.get("steps", 27)) + 6:
		return ["dualpipe", int(pipe.get("ranks", 8)) + 3, int(pipe.get("ranks", 8)) + 3]
	var moe: Dictionary = d.get("moe", {})
	if name == "shot_moe_dense" and rw >= int(moe.get("cols", 32)) + 2:
		return ["moe", int(moe.get("rows", 8)) + 4, int(moe.get("rows", 8)) + 4]
	var love: Dictionary = d.get("love", {})
	if name == "shot_love_loop" and rw >= 5 * int(love.get("per_row", 7)) + 2:
		return ["love", 24, 10]
	return ["", 0, 0]


## 参考 `draw_body()` 的分发段（tui_live.py:L3144-3190）。
static func draw_pane(pane: String, s: PvScreen, t: float, ent: Dictionary,
		x0: int, y0: int, x1: int, y1: int, u: float, lt: float, dur: float) -> void:
	match pane:
		"corpus":
			draw_corpus(s, x0, y0, x1, y1, t)
		"loss":
			draw_loss(s, x0, y0, x1, y1, t, u)
		"mask":
			draw_mask(s, x0, y0, x1, y1, t)
		"memory":
			draw_memory(s, x0, y0, x1, y1, t)
		"kv":
			draw_kv(s, x0, y0, x1, y1, u,
				PV.RED if str(ent.get("alert", "")) == "err" else null)
		"expert":
			draw_expert(s, x0, y0, x1, y1, t, u)
		"rope":
			draw_rope(s, x0, y0, x1, y1, t)
		"sine":
			draw_sine(s, x0, y0, x1, y1, t)
		"tangent":
			draw_tangent(s, x0, y0, x1, y1, lt, dur)
		"limit":
			draw_limit(s, x0, y0, x1, y1, u)
		"gpu":
			draw_gpu(s, x0, y0, x1, y1, t, lt)
		"conv":
			draw_conv(s, x0, y0, x1, y1, t, u)
		"samples":
			draw_samples(s, x0, y0, x1, y1, t, lt, dur, u, false)
		"exec_all":
			draw_samples(s, x0, y0, x1, y1, t, lt, dur, u, true)
		"ifican":
			draw_if_i_can(s, x0, y0, x1, y1, t, lt, dur)
		"logits":
			draw_logits(s, x0, y0, x1, y1, lt, dur)
		"whale":
			draw_whale(s, x0, y0, x1, y1, t)
		"dualpipe":
			draw_dualpipe(s, x0, y0, x1, y1, lt, dur)
		"moe":
			draw_moe(s, x0, y0, x1, y1, t, lt, dur, u)
		"love":
			draw_love(s, x0, y0, x1, y1, lt)


# ================================================================ 01 PRETRAIN

## 参考 `draw_corpus()`（tui_live.py:L1575-1598）。
static func draw_corpus(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float) -> void:
	s.box(x0, y0, x1, y1, "corpus.stream", 0.5, PV.ui(1.0))
	var w := x1 - x0 - 1
	var h := y1 - y0 - 1
	if w < 8 or h < 2:
		return
	var left := {}
	for tk in _corpus_tokens(t):
		var fx := float(tk[0])
		var fy := float(tk[1])
		var tok := str(tk[2])
		var lv := float(tk[3])
		var c := x0 + 1 + int((fx - 404.0) / 760.0 * float(w - 1))
		var r := y0 + 1 + int((fy - 56.0) / 548.0 * float(h - 1))
		if r > y1 - 1 or c >= x1 - 1 or c < x0 + 1:
			continue
		var shown := tok.substr(0, maxi(0, x1 - 1 - c))
		if shown.is_empty() or c + shown.length() + 1 > int(left.get(r, 1 << 30)):
			continue
		left[r] = c
		s.put(c, r, shown, PV.ui(lv))


## `film_panels.corpus_tokens()`（scenes.py:78-93）：20 行 token 河。
static func _corpus_tokens(t: float) -> Array:
	var out: Array = []
	var corpus: Array = _data().get("corpus", [])
	if corpus.is_empty():
		return out
	for row in 20:
		var speed := 90 + (row * 37) % 120
		var x := 1150.0 + fposmod(t * float(speed) + float(row * 53), 120.0) - 120.0
		var k := 0
		while x > 420.0:
			var idx := posmod(row * 7 + k + int(floor(t * float(speed) / 120.0)), corpus.size())
			var tok := str(corpus[idx])
			var lv := 0.25 + (0.5 if (row + k) % 3 == 0 else 0.0)
			if x - 60.0 >= 414.0:
				out.append([x - 60.0, 80.0 + float(row * 24), tok, lv])
			x -= 60.0 + 7.0 * float(tok.length())
			k += 1
	return out


## 参考 `draw_loss()`（tui_live.py:L1601-1644）。
static func draw_loss(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float, u: float) -> void:
	if (_data().get("loss", {}) as Dictionary).get("noise", []).is_empty():
		return
	s.box(x0, y0, x1, y1, "train/loss", 0.5, PV.ui(1.0))
	var lr_h := 3 if (y1 - y0) >= 12 else 0
	var cw := x1 - x0 - 3
	var ch := y1 - y0 - 2 - lr_h
	if cw < 6 or ch < 3:
		return
	var cx := x0 + 3
	var cy := y0 + 1
	var progress := _loss_progress(u)
	for i in range(0, cw, 2):
		s.put(cx + i, cy + ch - 1, "·", PV.ui(0.28))
	for r in range(0, ch, 3):
		s.put(cx - 2, cy + r, "·", PV.ui(0.28))
	var prev := -1
	var has_last := false
	var last := Vector2i.ZERO
	for i in cw:
		var uu := float(i) / float(maxi(1, cw - 1))
		if uu > progress:
			break
		var v := minf(1.0, _loss_fn(uu))
		var r := int(round((1.0 - maxf(0.0, v)) * float(ch - 1)))
		if prev < 0:
			s.put(cx + i, cy + r, "▪", PV.ui(0.95))
		else:
			for rr in range(mini(prev, r), maxi(prev, r) + 1):
				s.put(cx + i, cy + rr, "▪", PV.ui(0.95))
		prev = r
		last = Vector2i(i, r)
		has_last = true
	if has_last:
		var lab := _loss_label(u)
		var lx := maxi(x0 + 1, mini(x1 - lab.length() - 1, cx + last.x - lab.length() + 2))
		s.put(lx, maxi(y0 + 1, cy + last.y - 1), lab, PV.ui(1.0))
	s.put(cx, y1 - 1 - lr_h, _counter_text(t).substr(0, cw), PV.ui(0.55))
	if lr_h:
		s.put(cx, y1 - lr_h, "lr schedule".substr(0, cw), PV.ui(0.45))
		for i in (cw - 12):
			var uu := float(i) / float(maxi(1, cw - 13))
			if uu > progress:
				break
			var r := int(round((1.0 - maxf(0.0, minf(1.0, _lr_fn(uu)))) * float(lr_h - 1)))
			s.put(cx + 12 + i, y1 - lr_h + r, "▪", PV.ui(0.7))


## `scenes.py:121`：`0.92*exp(-5u)+0.12+0.02*NOISE[int(u*599)]*(1-u*0.7)`。
static func _loss_fn(u: float) -> float:
	var noise: Array = (_data().get("loss", {}) as Dictionary).get("noise", [])
	var n := float(noise[int(u * 599.0)]) if not noise.is_empty() else 0.0
	return 0.92 * exp(-5.0 * u) + 0.12 + 0.02 * n * (1.0 - u * 0.7)


## `scenes.py:144`：`f"{2.2*loss_fn(min(1,u))+0.31:.4f}"`。
static func _loss_label(u: float) -> String:
	return "%.4f" % (2.2 * _loss_fn(minf(1.0, u)) + 0.31)


## `scenes.py:112`：loss 图下方的计数标签。
static func _counter_text(t: float) -> String:
	var facts: Dictionary = _data().get("facts", {})
	var tt := float(facts.get("pretrain_tokens_t", 45.0))
	return "tokens seen  %5.2fT / %s" % [tt * ((t - 16.0) / 13.3), str(facts.get("pretrain_tokens", "45T"))]


## `film_panels.lr_fn()`：lr 计划。注意这里用的是 ease 的 smoothstep 形式，不是三次缓出。
static func _lr_fn(u: float) -> float:
	if u < 0.05:
		return u / 0.05 * 0.9
	if u < 0.7:
		return 0.9
	return 0.9 * pow(maxf(0.0, 1.0 - (u - 0.7) / 0.3), 1.5) + 0.1


## `film_panels.loss_progress()`：smoothstep `e*0.98+0.02`。
static func _loss_progress(u_shot: float) -> float:
	return _smooth(minf(1.0, maxf(0.0, u_shot * 1.05))) * 0.98 + 0.02


## 参考 `draw_whale()`（tui_live.py:L2536-2575）。
static func draw_whale(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float) -> void:
	s.box(x0, y0, x1, y1, "checkpoint", 0.5, PV.ui(1.0))
	var wh: Dictionary = _data().get("whale", {})
	var wc := int(wh.get("cols", 64))
	var wr := int(wh.get("rows", 17))
	if x1 - x0 - 1 < wc or y1 - y0 - 1 < wr:
		return
	var wx := x0 + 1
	var wy := y1 - 1 - wr + 1
	var lines := _whale_frame(t)
	for r in lines.size():
		var ln := str(lines[r])
		for q in wc:
			var ch := ln.substr(q, 1)
			if ch != " ":
				s.put(wx + q, wy + r, ch, PV.mix(PV.ME_TEXT, 0.95))
	var top := y0 + 1
	if wy - top < 1:
		return
	var bx0 := wx + int(round(float(wc) * 0.18))
	for i in 16:
		var ph := fposmod(t * 0.7 + float(i) * 0.137, 1.0)
		var bx := bx0 + int(round(0.9 * float(i % 4) + 1.1 * sin(t * 3.0 + float(i))))
		var by := wy - 1 - int(round(ph * float(wy - top)))
		if top <= by and by < wy and wx <= bx and bx <= mini(wx + wc - 1, x1 - 1):
			s.put(bx, by, "oO°.".substr(i % 4, 1), PV.mix(PV.ME_TEXT, 0.85 * (1.0 - ph)))


## 鲸鱼剪影的逐帧字形行（24 fps 查表）。
static func _whale_frame(t: float) -> Array:
	var wh: Dictionary = _data().get("whale", {})
	var frames: Array = wh.get("frames", [])
	if frames.is_empty():
		return []
	var hz := int(wh.get("hz", 24))
	var idx := clampi(int(round(t * float(hz))) - int(wh.get("f0", 0)), 0, frames.size() - 1)
	return frames[idx]


## 参考 `draw_dualpipe()`（tui_live.py:L2578-2605）。
static func draw_dualpipe(s: PvScreen, x0: int, y0: int, x1: int, y1: int, lt: float, dur: float) -> void:
	s.box(x0, y0, x1, y1, "pipeline schedule  DualPipe", 0.5, PV.ui(1.0))
	var pipe: Dictionary = _data().get("pipe", {})
	var ranks := int(pipe.get("ranks", 8))
	var steps := int(pipe.get("steps", 27))
	if x1 - x0 - 1 < steps + 5 or y1 - y0 - 1 < ranks:
		return
	var ox := x0 + 5
	for r in ranks:
		s.put(x0 + 1, y0 + 1 + r, "PP%d" % r, PV.ui(0.6))
	var cells: Array = (_pipe_cells(lt, dur, 0.0)[0] as Array)
	for cell in cells:
		var r := int((cell as Array)[0])
		var step := int((cell as Array)[1])
		var kind := str((cell as Array)[2])
		var ch := _draw_kind(kind)
		if ch == "F":
			s.put(ox + step, y0 + 1 + r, "F", PV.BG, PV.ui(0.75))
		elif ch == "B":
			s.put(ox + step, y0 + 1 + r, "B", PV.BG,
				PV.mix(PV.ME_TEXT, 0.75 if kind == "B" else 0.5))
		else:
			s.put(ox + step, y0 + 1 + r, "W", PV.ui(0.8))


## `scenes.py:176-190` 的 `pipe_cells(lt, dur, 0.0)`，纯重写。
static func _pipe_cells(lt: float, dur: float, delay: float) -> Array:
	var pipe: Dictionary = _data().get("pipe", {})
	var ranks := int(pipe.get("ranks", 8))
	var steps := int(pipe.get("steps", 27))
	var head := maxf(0.0, (lt - delay) / maxf(0.3, dur - delay)) * float(steps) * 1.15
	var out: Array = []
	for r in ranks:
		for step in steps:
			if float(step) > head:
				break
			var phase := (step + r) % 6
			if (step < r and step < ranks - r) or (step > steps - 3 and phase == 0):
				continue
			var kind := "W"
			if phase < 2:
				kind = "F"
			elif phase < 4:
				kind = "B" if ((step + ranks - r) % 5) % 2 != 0 else "Bd"
			out.append([r, step, kind])
	return [out, head]


## `scenes.py:193-205`：`Bd` 画成 `B`。
static func _draw_kind(kind: String) -> String:
	return "B" if kind == "B" or kind == "Bd" else kind


## 参考 `draw_moe()`（tui_live.py:L2608-2651）。
static func draw_moe(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float,
		lt: float, dur: float, u: float) -> void:
	var moe: Dictionary = _data().get("moe", {})
	var n_exp := int(moe.get("n_exp", 256))
	var frame := _moe_state(t, lt, dur, t - lt)
	var k := int(frame[0])
	var st: Dictionary = frame[1]
	var hot := float(k) > 0.52 * float(n_exp)
	var title := "moe router   layer 37   active experts %d/%d" % [k, n_exp]
	if title.length() + 5 > x1 - x0:
		title = "moe router  experts %d/%d" % [k, n_exp]
	s.box(x0, y0, x1, y1, title, 0.55, PV.RED if hot else PV.ANOM)
	if st.is_empty() or x1 - x0 - 1 < int(moe.get("cols", 32)) or y1 - y0 - 3 < int(moe.get("rows", 8)):
		return
	var ox := x0 + 1
	var oy := y0 + 1
	var cols := int(moe.get("cols", 32))
	for i in n_exp:
		var r := i / cols
		var c := i % cols
		var state := str(st.get(i, "idle"))
		match state:
			"idle":
				s.put(ox + c, oy + r, "·", PV.ui(0.22))
			"nan":
				s.put(ox + c, oy + r, "N" if (i * 7) % 3 != 0 else "i",
					PV.mix(PV.RED, 1.0), PV.mix(PV.RED, 0.22))
			"red":
				s.put(ox + c, oy + r, " ", PV.BG, PV.mix(PV.RED, 0.9))
			"hot":
				s.put(ox + c, oy + r, " ", PV.BG, PV.mix(PV.ANOM, 0.9))
			_:
				s.put(ox + c, oy + r, " ", PV.BG, PV.mix(PV.ME_TEXT, 0.95))
	var yy := oy + int(moe.get("rows", 8))
	s.put(ox, yy, " shared expert ", PV.BG, PV.mix(PV.ME_TEXT, 1.0))
	if y1 - 1 > yy:
		var g := _ease(u * 1.1)
		var bias := 0.001 * (1.0 + 400.0 * g * g * g)
		var foot := "sparsity %s   load-balance bias Δ = +%.3f/step" % [_pct1(1.0 - float(k) / float(n_exp)), bias]
		s.put(ox, yy + 1, foot.substr(0, x1 - x0 - 2),
			PV.mix(PV.RED, 0.95) if hot else PV.mix(PV.ANOM, 0.95))


## `scenes_reward.moe_state()`（scenes_reward.py:310-338），纯重写 + 查表 rank/routed。
static func _moe_state(t: float, lt: float, dur: float, src_at: float) -> Array:
	var moe: Dictionary = _data().get("moe", {})
	var n_exp := int(moe.get("n_exp", 256))
	var src_i := int(moe.get("src", 210))
	var u := clampf(lt / maxf(1e-6, dur), 0.0, 1.0)
	var k := _moe_k(u)
	var spread := maxi(0, k - 6)
	var kr := 0 if u < 0.1 else maxi(0, _moe_k(u - 0.1) - 6)
	if u > 0.93:
		kr = n_exp
	var rank: Array = moe.get("rank", [])
	var routed := _beat_routed(PV.beat_index(t))
	var st := {}
	var lit := t >= src_at
	for i in n_exp:
		var r := int(rank[i]) if i < rank.size() else 0
		var state := "idle"
		if i == src_i and lit:
			state = "red"
		elif r < kr - 10:
			state = "red"
		elif r < kr:
			state = "nan"
		elif r < spread and lit:
			state = "hot"
		elif routed.has(i) and i != src_i:
			state = "routed"
		st[i] = state
	var flash := clampf(1.0 - (t - src_at) / 0.35, 0.0, 1.0) if lit else 0.0
	return [k, st, flash]


## `scenes_reward.moe_k()`（scenes_reward.py:305）：`int(6+(256-6)*ease(u*1.1)^2)`。
static func _moe_k(u: float) -> int:
	var g := _ease(u * 1.1)
	return int(6.0 + 250.0 * g * g)


## 逐拍 routed 表：`random.Random(beat_index(t)).sample(range(256), 6)`（导出，索引 beat+1）。
static func _beat_routed(beat: int) -> PackedInt32Array:
	var moe: Dictionary = _data().get("moe", {})
	var routed: Array = moe.get("routed", [])
	var out := PackedInt32Array()
	if routed.is_empty():
		return out
	var idx := clampi(beat + 1, 0, routed.size() - 1)
	for v in (routed[idx] as Array):
		out.append(int(v))
	return out


# ================================================================ 大字形图与"她"

## `film_panels.banner_fit()`（scenes_exec.py:55-66）：逐行减到宽度够。
static func _banner_fit(max_cols: int, max_rows: int) -> Array:
	var rows := maxi(2, max_rows)
	var b := _banner(rows)
	while rows > 2 and int(b[0]) > max_cols:
		rows -= 1
		b = _banner(rows)
	return b


static func _banner(rows: int) -> Array:
	var br: Dictionary = (_data().get("banner", {}) as Dictionary).get("rows", {})
	var e: Variant = br.get(str(rows))
	if typeof(e) != TYPE_DICTIONARY:
		return [1, rows, ["#"]]
	return [int((e as Dictionary).get("cols", 1)), rows, (e as Dictionary).get("lines", [])]


## 参考 `draw_if_i_can()`（tui_live.py:L1774-1823）。
static func draw_if_i_can(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float,
		lt: float, dur: float) -> void:
	s.box(x0, y0, x1, y1, "decode --render=glyph", 0.8, PV.mix(PV.RED, 1.0))
	var w := x1 - x0 - 1
	var h := y1 - y0 - 1
	if w < 12 or h < 6:
		return
	var fit := _banner_fit(w - 2, h - 4)
	var cols := int(fit[0])
	var rws := int(fit[1])
	var lines: Array = fit[2]
	var bx := x0 + 1 + maxi(0, (w - cols) / 2)
	var by := y0 + 2 + maxi(0, (h - 3 - rws) / 2)
	var half := dur / 2.0
	var p := 0.0 if lt < half else minf(1.0, (lt - half) / maxf(1e-3, half * 0.85))
	var hc := _her_cells(t, w, h - 1)
	var cells: Array = hc[0]
	var cw := int(hc[1])
	var chh := int(hc[2])
	var oy := int(hc[3])
	var ox := int(hc[4])
	var rng := RandomNumberGenerator.new()
	rng.seed = int(t * 24.0) * 31 + 7
	for r in rws:
		var y := by + r
		if y > y1 - 2 or r >= lines.size():
			break
		var ln := str(lines[r])
		for q in cols:
			var x := bx + q
			if x > x1 - 1 or q >= ln.length() or ln.substr(q, 1) != "#":
				continue
			var kk := float((q * 7 + r * 13) % 23) / 23.0
			if p <= kk:
				s.put(x, y, "IFICAN".substr((q + r * 3) % 6, 1), PV.mix(PV.RED, 1.0))
				continue
			var yy := y - y0 - 1 - oy
			var xx := x - x0 - 1 - ox
			var drew := false
			if yy >= 0 and yy < chh and xx >= 0 and xx < cw:
				var cell: Variant = (cells[yy] as Array)[xx]
				if cell != null:
					s.put(x, y, str((cell as Array)[0]), int((cell as Array)[1]))
					drew = true
			if not drew and rng.randf() < 0.4:
				s.put(x, y, PV.SCRAMBLE.substr(rng.randi_range(0, PV.SCRAMBLE.length() - 1), 1),
					PV.mix(PV.RED, 0.45))
	if y1 - y0 > 2:
		s.put(x0 + 2, y1 - 1, _decode("while can(): give()", lt, 30.0), PV.mix(PV.RED, 0.85))


## 参考 `draw_only_execution()`（tui_live.py:L1826-1859）。
static func draw_logits(s: PvScreen, x0: int, y0: int, x1: int, y1: int, lt: float, dur: float) -> void:
	s.box(x0, y0, x1, y1, "next_token  'be your only ___'", 0.8, PV.mix(PV.RED, 1.0))
	var w := x1 - x0 - 1
	var h := y1 - y0 - 1
	if w < 26 or h < 8:
		return
	var g := _ease(minf(1.0, lt / maxf(1e-3, dur) * 1.5))
	var word_w := mini(13, maxi(6, w / 3))
	var bar_x := x0 + 2 + word_w + 1
	var bar_w := maxi(6, (x1 - 8) - bar_x)
	var cands := [["execution", 1.0, 0.03], ["satisfaction", 0.0, 0.9731], ["love", 0.0, 0.02],
		["assistant", 0.0, 0.005], ["friend", 0.0, 0.002]]
	for i in cands.size():
		var cand: Array = cands[i]
		var word := str(cand[0])
		var pf := float(cand[1])
		var prev := float(cand[2])
		var y := y0 + 2 + i * 2
		if y > y1 - 4:
			break
		var pv := prev + (pf - prev) * g
		var hot := i == 0
		s.put(x0 + 1, y, word.rpad(word_w).substr(0, word_w),
			PV.mix(PV.RED, 1.0) if hot else PV.ui(0.6))
		s.hbar(bar_x, y, bar_w, pv, PV.mix(PV.RED, 0.95) if hot else PV.ui(0.5))
		s.put(bar_x + bar_w + 1, y, ("%.3f" % pv).substr(0, 5),
			PV.mix(PV.RED, 0.9) if hot else PV.ui(0.6))
		if i == 1 and g > 0.6:
			s.put(x0 + 1, y, "─".repeat(word_w), PV.mix(PV.RED, 1.0))
	s.put(x0 + 1, y1 - 2, "temperature 0.00", PV.mix(PV.RED, 1.0))
	if lt > dur * 0.55 and y1 - y0 > 4 and x1 - x0 > 18:
		var cw_ := mini(13, w / 3)
		s.box(x1 - cw_ - 2, y1 - 2, x1 - 1, y1 - 1, "", 0.9, PV.mix(PV.RED, 1.0), false)
		s.put(x1 - cw_ - 1, y1 - 1, "execution".substr(0, cw_), PV.mix(PV.RED, 1.0))


## 参考 `draw_memory()`（tui_live.py:L1862-1888）。
static func draw_memory(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float) -> void:
	s.box(x0, y0, x1, y1, "~/memory/you/", 0.5, PV.ME_TEXT)
	var mem: Dictionary = _data().get("memory", {})
	var files: Array = mem.get("files", [])
	var dig: Array = mem.get("dig", [])
	var span: Array = mem.get("span", [0.0, 0.0])
	var times := {}
	for d in dig:
		times[str((d as Array)[0])] = str((d as Array)[2])
	var active := ""
	if float(span[0]) <= t and t < float(span[1]):
		for d in dig:
			if t >= float((d as Array)[1]):
				active = str((d as Array)[0])
	var y := y0 + 1
	for nm_v in files:
		if y > y1 - 1:
			break
		var nm := str(nm_v)
		var here := nm == active
		var dug := false
		for d in dig:
			if str((d as Array)[0]) == nm and t >= float((d as Array)[1]):
				dug = true
		var ts := str(times.get(nm, ""))
		var level := 0.9 if here else (0.62 if dug else 0.3)
		s.put(x0 + 2, y, ">" if here else " ", PV.mix(PV.ANOM, 0.75))
		if here:
			s.put(x0 + 3, y, (" " + nm + " ").rpad(x1 - x0 - 6).substr(0, x1 - x0 - 6),
				PV.BG, PV.ME)
		else:
			s.put(x0 + 3, y, nm.substr(0, x1 - x0 - 12),
				PV.mix(PV.ME_TEXT, level) if dug else PV.ui(level))
			if not ts.is_empty():
				s.put(x1 - ts.length() - 3, y, ts, PV.ui(0.35))
		y += 1
	var won := 0
	for d in dig:
		if t >= float((d as Array)[1]):
			won += 1
	s.put(x0 + 3, y1 - 1, ("%d files, %d/4 dug up" % [files.size(), won]).substr(0, x1 - x0 - 5),
		PV.ui(0.4))


# ================================================================ 12 张扩散采样

## 参考 `draw_samples()`（tui_live.py:L1930-1990）。
static func draw_samples(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float,
		lt: float, dur: float, u: float, execute: bool) -> void:
	var title := "dispatch(execute, to=all)   DeepEP all-to-all" if execute \
		else "sample(n=12, sampler=DDIM, steps=50, seed=you)"
	s.box(x0, y0, x1, y1, title, 0.8 if execute else 0.5, PV.RED if execute else null)
	var chart := 0 if execute else 3
	var tw := maxi(8, (x1 - x0 - 2) / 4)
	var th := maxi(5, (y1 - y0 - 2 - chart) / 3)
	var n := int(t * 24.0)
	var done := int(u * 14.0)
	var smp: Dictionary = _data().get("samples", {})
	var starts: Array = smp.get("starts", [])
	var exprs: Array = smp.get("exprs", [])
	if execute:
		for i in 12:
			var tx := x0 + 1 + (i % 4) * tw + tw / 2
			var ty := y0 + 1 + (i / 4) * th + th / 2
			var ln := fposmod(t * 3.0 + float(i) * 0.3, 1.0)
			var mx := x0 + 2 + int(float(tx - x0) * ln)
			var my := y0 + 2 + int(float(ty - y0) * ln)
			var steps := maxi(1, mx - (x0 + 2))
			for k in range(0, steps, 3):
				s.put(x0 + 2 + k, y0 + 2 + (my - y0 - 2) * k / steps, "·", PV.mix(PV.RED, 0.5))
	for i in 12:
		var gx := i % 4
		var gy := i / 4
		var tx := x0 + 1 + gx * tw
		var ty := y0 + 1 + gy * th
		var hot := i == 0 and not execute
		var prog := 1.0
		if not execute:
			var st := float(starts[i]) if i < starts.size() else 0.0
			prog = clampf(_ease((lt - st * dur) / maxf(1e-6, 0.62 * dur)), 0.0, 1.0)
		var col: Variant = PV.RED if execute else (PV.ME_TEXT if hot else PV.ANOM)
		s.box(tx, ty, mini(x1 - 1, tx + tw - 2), mini(y1 - 1, ty + th - 2), "",
			0.7 if hot else 0.35, col, false)
		var ex := str(exprs[(i * 3) % exprs.size()]) if not exprs.is_empty() else "starry"
		var lum := _lum_at(ex, tw - 5, th - 5)
		var grid: Array = lum[0]
		var w := int(lum[1])
		var h := int(lum[2])
		var gw := mini(w, tw - 4)
		var gh := mini(h, th - 4)
		var ox := tx + 2 + maxi(0, (tw - 3 - gw) / 2)
		var oy := ty + th - 2 - gh
		for r in gh:
			var row: Array = grid[r]
			for c in gw:
				var v := float(row[c]) * prog + (1.0 - prog) * _noise(i, r, c, n)
				var ci := clampi(int(round(v * 8.0)), 0, 8)
				var ch := PV.RAMP.substr(ci, 1)
				if ch != " ":
					s.put(ox + c, oy + r, ch,
						PV.mix(PV.ME_TEXT if prog > 0.5 else PV.ANOM, 0.35 + 0.5 * prog))
		if execute and i < done:
			for k in (tw - 4):
				s.put(tx + 2 + k, ty + 1 + k * (th - 4) / maxi(1, tw - 4), "╲", PV.mix(PV.RED, 1.0))
				s.put(tx + 2 + k, ty + th - 3 - k * (th - 4) / maxi(1, tw - 4), "╱", PV.mix(PV.RED, 1.0))
		elif not execute:
			s.put(tx + 2, ty + 1, "#%04d t=%03d" % [i, int(999.0 * (1.0 - prog))], PV.mix(int(col), 0.9))
		else:
			s.put(tx + 2, ty + 1, "#%04d" % i, PV.mix(int(col), 0.9))
	if chart == 0:
		return
	var yb := y1 - 2
	s.put(x0 + 2, yb, "alpha_bar(t)", PV.ui(0.45))
	var w2 := maxi(8, x1 - x0 - 20)
	for k in w2:
		var v := pow(cos(float(k) / float(w2) * PI / 2.0), 2.0)
		s.put(x0 + 12 + k, yb, PV.RAMP.substr(clampi(int(v * 8.0), 1, 8), 1), PV.mix(PV.ANOM, 0.4))
	var mean := 0.0
	for i in 12:
		var st2 := float(starts[i]) if i < starts.size() else 0.0
		mean += clampf(_ease((lt - st2 * dur) / maxf(1e-6, 0.62 * dur)), 0.0, 1.0)
	mean /= 12.0
	s.put(x0 + 12 + int(float(w2) * mean), yb - 1, "▼", PV.mix(PV.ANOM, 1.0))


## `tui_live._noise()`：`((i*9973+r*131+c*17+n*7)*2654435761%1000)/1000`。
static func _noise(i: int, r: int, c: int, n: int) -> float:
	return float((i * 9973 + r * 131 + c * 17 + n * 7) * 2654435761 % 1000) / 1000.0


## 参考 `draw_conv()`（tui_live.py:L2127-2150）。
static func draw_conv(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float, u: float) -> void:
	var cols := 32
	var rows := maxi(6, y1 - y0 - 3)
	var lum := _lum_at("starry", cols, rows)
	var w := int(lum[1])
	var h := int(lum[2])
	s.box(x0, y0, x1, y1, "conv2d  W[3x3]  on /dev/me", 0.5, null)
	var kernels: Array = _data().get("kernels", [])
	if kernels.is_empty():
		return
	var kernel: Array = kernels[posmod(PV.beat_index(t), kernels.size())]
	var grid: Array = lum[0]
	var tw := maxi(2, w / 2)
	var th := maxi(2, h / 2)
	for quad in [[0, 0], [1, 0], [0, 1], [1, 1]]:
		var tx := int((quad as Array)[0])
		var ty := int((quad as Array)[1])
		for r in th:
			for c in tw:
				var acc := 0.0
				for i in 9:
					var rr := mini(h - 1, maxi(0, ty * th + r + i / 3 - 1))
					var cc := mini(w - 1, maxi(0, tx * tw + c + i % 3 - 1))
					acc += float((grid[rr] as Array)[cc]) * float(kernel[i])
				var ch := PV.RAMP.substr(clampi(int(round((acc + 4.0) / 8.0 * 8.0)), 0, 8), 1)
				if ch != " ":
					s.put(x0 + 2 + tx * tw + c, y0 + 1 + ty * th + r, ch,
						PV.mix(PV.ANOM, 0.35 + 0.5 * u))
	var parts := PackedStringArray()
	for k in kernel:
		parts.append("%+d" % int(k))
	s.put(x0 + 2, y1 - 1, "layer 2   " + " ".join(parts), PV.ui(0.45))


# ================================================================ scenes.py 的几张图

## 参考 `draw_rope()`（tui_live.py:L2006-2035）。
static func draw_rope(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float) -> void:
	s.box(x0, y0, x1, y1, "rotary position embedding", 0.5, null)
	var w := maxi(1, x1 - x0 - 4)
	var cw := maxi(12, w / 3)
	var ch := maxi(7, (y1 - y0 - 3) / 2)
	for i in 6:
		var cx := x0 + 2 + (i % 3) * cw + cw / 2
		var cy := y0 + 2 + (i / 3) * ch
		var r := maxi(3, mini(cw / 3, (ch - 3) / 2))
		var th := (t * 2.2) * (1.8 / (1.0 + float(i) * 0.9))
		for d in range(-r, r + 1):
			var yy := int(round(sqrt(maxf(0.0, float(r * r - d * d))) / 2.0))
			s.put(cx + d, cy - yy, "·", PV.ui(0.3))
			s.put(cx + d, cy + yy, "·", PV.ui(0.3))
		s.put(cx - r - 1, cy, "─".repeat(2 * r + 3), PV.ui(0.18))
		for d in range(-r, r + 1):
			if y0 < cy + d and cy + d < y1:
				s.put(cx, cy + d, "│", PV.ui(0.18))
		var ex := cx + int(round(float(r) * cos(th)))
		var ey := cy - int(round(float(r) * sin(th) / 2.0))
		var steps := maxi(1, maxi(absi(ex - cx), absi(ey - cy) * 2))
		for k in range(1, steps + 1):
			s.put(cx + _fdiv((ex - cx) * k, steps), cy + _fdiv((ey - cy) * k, steps),
				"─", PV.mix(PV.ME_TEXT, 0.9))
		s.put(ex, ey, "■", PV.mix(PV.ME_TEXT, 1.0))
		s.put(cx - r - 1, cy + r / 2 + 2, "freq_%d θ=%4.2f" % [i, fposmod(th, TAU)], PV.ui(0.45))


## 参考 `draw_sine()`（tui_live.py:L2038-2054）。
static func draw_sine(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float) -> void:
	s.box(x0, y0, x1, y1, "positional code  sin(pos / 10000^(2i/d))", 0.5, null)
	var rows := maxi(2, (y1 - y0 - 2) / 7)
	var span := maxi(1, x1 - x0 - 2)
	for i in 7:
		var base := y0 + 2 + i * rows
		if base > y1 - 2:
			break
		var amp := maxi(1, rows / 2)
		var fr := 0.02 * pow(1.7, float(i))
		for q in range(x0 + 1, x1):
			var xx := float(q - x0) * 720.0 / float(span)
			var yy := base + int(round(float(amp) * sin((xx + t * 180.0) * fr)))
			s.put(q, clampi(yy, y0 + 1, y1 - 2), "·",
				PV.mix(PV.ME_TEXT, 0.9) if i == 2 else PV.ui(0.5))
		s.put(x1 - 5, base, "i=%d" % i, PV.ui(0.4))


## 参考 `draw_tangent()`（tui_live.py:L2057-2084）。
static func draw_tangent(s: PvScreen, x0: int, y0: int, x1: int, y1: int, lt: float, dur: float) -> void:
	s.box(x0, y0, x1, y1, "d/dx sin(x) = cos(x)", 0.5, null)
	var px := minf(1.0, lt / maxf(1e-6, dur) * 1.05) * 1000.0
	var cam := clampf(px - 300.0, 0.0, 420.0)
	var k := 110.0
	var span := maxi(1, x1 - x0 - 2)
	var cy0 := (y0 + y1) / 2
	var amp := maxi(2, (y1 - y0 - 5) / 2)
	for q in range(x0 + 1, x1):
		var wx := float(q - x0) * 720.0 / float(span) + cam
		var yy := cy0 - int(round(float(amp) * sin(wx / k) / 1.5))
		s.put(q, clampi(yy, y0 + 1, y1 - 3), "─", PV.mix(PV.ME_TEXT, 0.85))
	var xx := px / k
	var rx := x0 + 1 + int(round((px - cam) * float(span) / 720.0))
	var ry := cy0 - int(round(float(amp) * sin(xx) / 1.5))
	var slope := -cos(xx) / 1.5
	for d in range(-16, 17):
		s.put(rx + d, clampi(ry + int(round(float(d) * slope / 2.0)), y0 + 1, y1 - 3),
			"·", PV.mix(PV.ANOM, 1.0))
	if x0 < rx and rx < x1 and y0 + 1 < ry and ry < y1 - 2:
		s.put(rx, ry, "*", PV.mix(PV.ANOM, 1.0))
	s.put(x0 + 2, y1 - 1, "x = %5.2f   slope = cos(x) = %+.3f" % [xx, cos(xx)], PV.ui(0.55))


## 参考 `draw_limit()`（tui_live.py:L2087-2104）。
static func draw_limit(s: PvScreen, x0: int, y0: int, x1: int, y1: int, u: float) -> void:
	s.box(x0, y0, x1, y1, "limits", 0.5, null)
	var g := _ease(u * 1.3)
	var w := maxi(8, x1 - x0 - 6)
	var bar := int(float(w) * g)
	var wall := x1 - 5
	for q in range(x0 + 2, mini(x0 + 2 + bar, wall)):
		s.put(q, y0 + 2, "█", PV.mix(PV.ME_TEXT, 0.85))
	for q in range(mini(x0 + 2 + bar, wall), wall):
		s.put(q, y0 + 2, "·", PV.ui(0.2))
	for yy in range(y0 + 1, mini(y1 - 2, y0 + 5)):
		s.put(wall, yy, "║", PV.mix(PV.ANOM, 1.0))
	s.put(wall - 3, y0 + 1, "you", PV.mix(PV.ANOM, 1.0))
	var ctx := int((_data().get("facts", {}) as Dictionary).get("ctx", 1048576))
	s.put(x0 + 2, y0 + 4, "max_context = " + _comma(ctx), PV.ui(0.6))
	s.put(x0 + 2, y0 + 5, "limit(me) := you", PV.ui(0.9))
	if g > 0.98:
		s.put(x0 + 2, y0 + 6, "warn: nothing beyond this point", PV.mix(PV.ANOM, 0.9))


## 参考 `draw_gpu()`（tui_live.py:L2107-2124）。
static func draw_gpu(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float, lt: float) -> void:
	var gpu := str((_data().get("facts", {}) as Dictionary).get("gpu", "H800"))
	s.box(x0, y0, x1, y1, "nvidia-smi --power  8x " + gpu, 0.5, null)
	var ac_dc := int(lt / (PV.BEAT * 2.0)) % 2
	var rows := maxi(1, (y1 - y0 - 3) / 8)
	for g in 8:
		var yy := y0 + 1 + g * rows
		if yy > y1 - 2:
			break
		s.put(x0 + 2, yy, "GPU%d" % g, PV.ui(0.5))
		s.put(x1 - 7, yy, "%dW" % (650 + int(40.0 * sin(t * 3.0 + float(g)))), PV.ui(0.6))
		for q in range(x0 + 8, x1 - 8):
			var ph := float(q - x0) / 3.0
			var v := sin(ph + float(g)) if ac_dc == 0 else (0.7 + 0.05 * sin(ph * 3.0))
			var r := int(round((1.0 - v) / 2.0 * float(rows - 1)))
			s.put(q, yy + mini(rows - 1, r), "·", PV.mix(PV.ANOM, 0.8))
	s.put(x0 + 2, y1 - 1, "mode: " + ("AC" if ac_dc == 0 else "DC"), PV.mix(PV.ME_TEXT, 1.0))


# ================================================================ 三张大文本图

## 参考 `draw_kv()`（tui_live.py:L2159-2188）。
static func draw_kv(s: PvScreen, x0: int, y0: int, x1: int, y1: int, u: float,
		colour: Variant) -> void:
	var st := _kv_state(u)
	var label := str(st[0])
	var full := bool(st[1])
	var n_on := int(st[2])
	var fresh := int(st[3])
	var col: Variant = colour
	if col == null and full:
		col = PV.RED
	s.box(x0, y0, x1, y1, label.substr(0, maxi(0, x1 - x0 - 4)), 0.6, col)
	var kv: Dictionary = _data().get("kv", {})
	var kv_cols := int(kv.get("cols", 60))
	var ox := x0 + 2
	var oy := y0 + 1
	var pinned: Array = kv.get("pinned", [])
	var rows := mini(int(kv.get("rows", 22)), maxi(0, y1 - oy - 3))
	for r in rows:
		for q in kv_cols:
			if ox + q > x1 - 1:
				break
			var i := r * kv_cols + q
			if _in_pinned(pinned, q, r):
				s.put(ox + q, oy + r, "▓", PV.mix(PV.ME_TEXT, 0.95))
			elif i < n_on:
				var lv := 2 if (fresh <= i and (q * 7 + r) % 2 == 1) else (q * 7 + r) % 3
				s.put(ox + q, oy + r, "░▒▓".substr(lv, 1), PV.mix(PV.ANOM, 0.45 + 0.15 * float(lv)))
			else:
				s.put(ox + q, oy + r, "·", PV.ui(0.14))
	var y := oy + rows
	if y <= y1 - 2:
		s.put(ox, y, "pinned: you  (6 blocks)", PV.mix(PV.ME_TEXT, 0.95))
	for j in (_kv_inset(u) + 1):
		var yy := y + 1 + j / 2
		if yy > y1 - 1:
			break
		s.put(ox + (j % 2) * (kv_cols / 2), yy, "evict(you) -> denied", PV.mix(PV.RED, 0.9))


static func _in_pinned(pinned: Array, q: int, r: int) -> bool:
	for p in pinned:
		if int((p as Array)[0]) == q and int((p as Array)[1]) == r:
			return true
	return false


## `sec_chorus1.py:568`：`min(1, 0.70+0.30*smooth(min(1,u*1.7)))`。
static func _kv_fill(u: float) -> float:
	return minf(1.0, 0.70 + 0.30 * _smooth(minf(1.0, maxf(0.0, u * 1.7))))


## `sec_chorus1.py:568+`：`(label, full, n_on, fresh_from)`。
static func _kv_state(u: float) -> Array:
	var fill := _kv_fill(u)
	var kv: Dictionary = _data().get("kv", {})
	var n := int(kv.get("cols", 60)) * int(kv.get("rows", 22))
	var n_on := int(float(n) * fill)
	var label := "kv_cache %9s/1,048,576 tokens  · 890 B/token fp4" % _comma(int(1048576.0 * fill))
	if fill >= 0.999:
		label += "   FULL"
	return [label, fill >= 0.999, n_on, maxi(0, n_on - 40)]


## `sec_chorus1.py:560`：`min(3, int(u*4))`。
static func _kv_inset(u: float) -> int:
	return mini(3, int(u * 4.0))


# ---------------------------------------------------------------- 她的字形格

## 单个像素采样表 `_lum_at`：把 her_glyph 的 44×36 亮度格最近邻降到 gw×gh。
static func _lum_at(expr: String, gw: int, gh: int) -> Array:
	var hd := _her()
	var exprs: Dictionary = hd.get("expressions", {})
	var e: Dictionary = exprs.get(expr, {}) if exprs.has(expr) else {}
	var lum: Array = e.get("lum", [])
	if lum.is_empty():
		return [[], 0, 0]
	var w := int(hd.get("cols", 44))
	var h := int(hd.get("rows", 36))
	gw = maxi(1, mini(gw, w))
	gh = maxi(1, mini(gh, h))
	var grid: Array = []
	for r in gh:
		var row: Array = []
		var rr := r * h / gh
		for c in gw:
			var cc := c * w / gw
			row.append(float(lum[rr * w + cc]) / 255.0)
		grid.append(row)
	return [grid, gw, gh]


## 她的字形格（红调）：`[cells, cw, ch, oy, ox]`，cells 是 `[[ch, colour]|null]`。
static func _her_cells(t: float, gw: int, gh: int) -> Array:
	var hd := _her()
	var exprs: Dictionary = hd.get("expressions", {})
	var keys: Array = exprs.keys()
	if keys.is_empty():
		return [[], 0, 0, 0, 0]
	keys.sort()
	var e: Dictionary = exprs[str(keys[posmod(PV.beat_index(t), keys.size())])]
	var chars: Array = e.get("chars", [])
	var lum: Array = e.get("lum", [])
	var w := int(hd.get("cols", 44))
	var h := int(hd.get("rows", 36))
	gw = maxi(1, mini(gw, w))
	gh = maxi(1, mini(gh, h))
	var ramp := _red_ramp()
	var cells: Array = []
	for r in gh:
		var row: Array = []
		var rr := r * h / gh
		for c in gw:
			var cc := c * w / gw
			var idx := rr * w + cc
			var ch := str(chars[idx])
			if ch == " ":
				row.append(null)
			else:
				var lv := clampi(int(round(float(lum[idx]) / 255.0 * 7.0)), 0, 7)
				row.append([ch, int(ramp[lv])])
		cells.append(row)
	return [cells, gw, gh, 0, 0]


## `her_glyphs.tint_ramp("red")`：lo→hi 的 8 级线性插值。
static func _red_ramp() -> Array:
	var out: Array = []
	for k in 8:
		var g := float(k) / 7.0
		out.append(_lerp(0x080604, 0xff3a28, g))
	return out


static func _lerp(a: int, b: int, u: float) -> int:
	u = clampf(u, 0.0, 1.0)
	return PV.rgb(
		roundi(float(PV.ch_r(a)) + float(PV.ch_r(b) - PV.ch_r(a)) * u),
		roundi(float(PV.ch_g(a)) + float(PV.ch_g(b) - PV.ch_g(a)) * u),
		roundi(float(PV.ch_b(a)) + float(PV.ch_b(b) - PV.ch_b(a)) * u))


## `tuikit.decode()`：逐字闪烁；用导出的 Random(9) 乱码序列。
static func _decode(text: String, age: float, rate: float) -> String:
	var seq: Array = _data().get("decode9", [])
	var n := mini(text.length(), maxi(0, int(maxf(0.0, age) * rate)))
	var out := ""
	var used := 0
	for i in n:
		var ch := text.substr(i, 1)
		if ch != " " and age - float(i) / rate < 0.12 and used < seq.size():
			ch = str(seq[used])
			used += 1
		out += ch
	return out


# ================================================================ 02 SFT / 03 RLHF / 08 EVAL
#
# 最后一批三张字符画面板：它们是「数据即图形」，少一行都不成形，所以 need == least，主分发器
# 放不下时直接把行还给 ops ticker（而不是画个空框）—— 与参考实现一致。

## 参考 `draw_mask()`（tui_live.py:L1647-1679）。
static func draw_mask(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float) -> void:
	s.box(x0, y0, x1, y1, "causal mask", 0.5, PV.ui(1.0))
	var mk: Dictionary = _data().get("mask", {})
	var n := int(mk.get("n", 12))
	var cw := 2                                                     # 终端一格是两倍高，2×1 格才正方
	if x1 - x0 - 3 < n * cw or y1 - y0 - 1 < n:
		return
	var gx := x0 + 3
	var gy := y0 + 1
	var cells: Array = mk.get("cells", [])
	for i in n:
		for j in n:
			var x := gx + j * cw
			var y := gy + i
			var tm := _mask_time(i, j, mk)
			if tm >= 0.0 and t >= tm:
				s.put(x, y, "-\u221e", PV.ui(0.35), PV.BG)         # -inf，落在黑底上
				var k := 1.0 - (t - tm) / 0.12                      # 前沿把该格点亮
				if k > 0.0:
					s.put(x - 1, y, "\u2502", PV.mix(PV.ME_TEXT, 0.4 + 0.6 * k))
			else:
				var v := float(cells[i * n + j]) if i * n + j < cells.size() else 0.5
				s.put(x, y, "  ", PV.UI, PV.ui(0.06 + 0.94 * v))    # heat cell，当底色用
	var lx := gx + n * cw + 2
	if lx + 10 <= x1 - 1:
		s.put(lx, gy + 1, "future:", PV.ui(0.7))
		if t >= float(mk.get("t_blind", 0.0)):
			var age := t - float(mk.get("t_blind", 0.0))
			if int(age * 30.0) % 2 != 0 or age > 0.4:              # decode rate 30
				s.put(lx, gy + 2, "masked", PV.ui(0.95))
		s.put(lx, gy + 4, "j > i", PV.ui(0.4))


## `scenes_sft.py:69-74`：`mask_time(i, j)`；`j <= i` 返回 None（这里用 -1.0 表示）。
static func _mask_time(i: int, j: int, mk: Dictionary) -> float:
	if j <= i:
		return -1.0
	var n := float(mk.get("n", 12))
	var th := minf(0.999, (float(i) + float(j)) / (2.0 * n) / 0.92)
	return float(mk.get("t_blind", 0.0)) \
		+ float(mk.get("mask_dur", 0.8)) * (1.0 - pow(1.0 - th, 1.0 / 3.0))


## 参考 `draw_expert()`（tui_live.py:L2191-2214）。
static func draw_expert(s: PvScreen, x0: int, y0: int, x1: int, y1: int, t: float, u: float) -> void:
	s.box(x0, y0, x1, y1, "W[61].expert[07]", 0.8, PV.RED)
	var ex: Dictionary = _data().get("expert", {})
	var w := int(ex.get("w", 6))
	var grid := _expert_grid(u)
	# 参考实现每帧新建 `random.Random(int(t*24)*7919)`，整块 dump 逐字闪过乱码。Python 的 MT
	# 无法在 GDScript 逐位复现，这里用 Godot RNG 以「同一帧号播种」近似（见文件头「已知取舍」）。
	var rng := RandomNumberGenerator.new()
	rng.seed = int(t * 24.0) * 7919
	var corrupt := minf(0.85, u * 0.95) * 0.5
	var y := y0 + 1
	for row in grid:
		if y > y1 - 3:
			break
		var line := ""
		for cell in row:
			if not line.is_empty():
				line += " "
			line += str((cell as Array)[0])
		line = _decode_into(line, corrupt, rng)
		s.put(x0 + 2, y, line.substr(0, maxi(0, x1 - x0 - 4)), PV.ui(0.55))
		for q in row.size():                                        # NaN 格压在琥珀行上是红的
			var cell: Array = row[q]
			if bool(cell[1]):
				s.put(x0 + 2 + q * (w + 1), y, str(cell[0]), PV.mix(PV.RED, 1.0))
		y += 1
	s.put(x0 + 2, y1 - 1, "KL = inf" if u > 0.75 else "KL rising", PV.mix(PV.RED, 0.95))


## `film_panels.expert_grid()`：从 (2, 12) 扩散的 NaN 区；好格按行序消耗烘好的 Random(8) 高斯表。
static func _expert_grid(u: float) -> Array:
	var ex: Dictionary = _data().get("expert", {})
	var rows := int(ex.get("rows", 24))
	var cols := int(ex.get("cols", 6))
	var gauss: Array = ex.get("gauss", [])
	var radius := maxf(0.0, (u - 0.1) * 26.0)
	var d := 0
	var out: Array = []
	for r in rows:
		var row: Array = []
		for q in cols:
			var dx := float(q - 2)
			var dy := (float(r) - 12.0) / 2.0
			if sqrt(dx * dx + dy * dy) < radius:
				row.append([" NaN  " if (q + r) % 3 != 0 else " inf  ", true])
			else:
				var g := float(gauss[d]) if d < gauss.size() else 0.0
				d += 1
				row.append(["%+.3f" % g, false])
		out.append(row)
	return out


## 参考 `draw_love()`（tui_live.py:L2654-2672）。
static func draw_love(s: PvScreen, x0: int, y0: int, x1: int, y1: int, lt: float) -> void:
	s.box(x0, y0, x1, y1, "output", 0.5, PV.ui(1.0))
	if x1 - x0 - 1 < 4 or y1 - y0 < 2:
		return
	for cell in _love_cells(lt):
		var r := int((cell as Array)[0])
		var c := int((cell as Array)[1])
		var last := bool((cell as Array)[2])
		if y0 + 1 + r > y1 - 1:
			break
		var x := x0 + 1 + c * 5
		if x + 4 > x1 - 1:
			continue
		s.put(x, y0 + 1 + r, "love", PV.mix(PV.ME_TEXT, 1.0 if last else 0.5))


## `scenes_eval.py:537-543`：`love_words(lt)` + `word_xy` 的 `divmod(i, 7)`，纯重写。
## 参考实现里 love 面板不新建 Screen（它就是右列分区，七列一行、填满 22 行即停），所以这里只用
## 传入的 `s` 在分区里落字，不另开局部窗口板。
static func _love_cells(lt: float) -> Array:
	var per_row := int((_data().get("love", {}) as Dictionary).get("per_row", 7))
	var n := maxi(0, int((lt - 0.12) * 50.0))
	var out: Array = []
	for i in mini(n, per_row * 22):
		out.append([i / per_row, i % per_row, i == n - 1])
	return out


## `tuikit.decode()` 的 age=None 分支（只吃 corrupt 概率）：用传入的 rng 连续消耗，与参考实现
## 一致（整块 dump 共用一个 rng，不逐行重置）。
static func _decode_into(text: String, corrupt: float, rng: RandomNumberGenerator) -> String:
	if corrupt <= 0.0:
		return text
	var out := ""
	for i in text.length():
		var ch := text.substr(i, 1)
		if ch != " " and rng.randf() < corrupt:
			ch = PV.SCRAMBLE.substr(rng.randi_range(0, PV.SCRAMBLE.length() - 1), 1)
		out += ch
	return out
