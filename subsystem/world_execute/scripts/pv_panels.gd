class_name PvPanels
extends RefCounted

## 面板层：把 `PvScreen` 的字符格填成一帧画面。
##
## 逐函数对应参考实现 `tui_live.py` 的 `draw()` / `draw_body()` / `draw_*()`（版式规格见
## tools/ref/layout.md §2.3 与 §3.1–§3.13）。分工：
##
##   * `draw()`          —— 每帧入口：清三张 rect 表、写 UI 增益、清屏、header + body + footer；
##   * `draw_body()`     —— 左列（她 / dsh / cursor 三选一）+ stdout 带（boot / sim / lyrics）
##                          + 右列（feature bands + 章节面板 + ops ticker）；
##   * `draw_header()` / `draw_footer()` —— 顶栏（含波形与章节条）与底栏（进度框 + 两行状态）。
##
## 与参考实现的取舍（见 subsystem/world_execute/README.md）：
##   1. 章节面板只移植 17 种（corpus / loss / memory / kv / rope / sine / tangent / limit /
##      gpu / conv / samples / exec_all / ifican / logits / whale / dualpipe / moe）；参考实现
##      里还要自建屏幕的 `mask` / `expert` / `love` 三种仍走「不画」分支，把行还给 ops ticker；
##   2. dsh 窗口的头像块与强调色已落地：逐帧头像 PNG 由 `_avatar_block()` 复刻 PIL `Image.BOX`
##      （8bpc 定点，逐值一致）压成 `▀` 半块；强调色取该帧的 `theme[1]`（`brand-primary`），
##      缺省 `ME_TEXT`；状态点色取 `dot` role 的 `#rrggbb`。数据见 `data/dsh_avatars/`。

const CHAR_SHOTS := ["shot_if_i_can", "shot_simulations", "shot_then_i_can"]
const HER_MIN_H := 14
const HER_MAX_H := 34
const BAND_MIN_H := 11
const CHAR_BREATH := 1.4
const CHAR_HOP := 1.5
const AVATAR_MAX_W := 14
const CURSOR_BLINK := 0.53
## `engine.py:L319` 的气泡字符集（`"oO°.o"[i % 5]`）。
const BUBBLE_CHARS := "oO°.o"
## dsh 头像的逐帧 PNG 目录（映射见 `_avatar_block`）。
const DSHAV := "res://subsystem/world_execute/data/dsh_avatars/"
## PIL `Resample.c` 的 8bpc 定点：权重占 22 位，累加器先置 `1 << 21`（四舍五入）。
const BOX_PRECISION_BITS := 22
const BOX_HALF := 1 << 21
const BOX_ONE := 1 << 22
const GLYPH_RAMP := " .:-=+*#%@"
const TINT_BLUE_LO := 0x040822
const TINT_BLUE_HI := 0xc4d4ff
const TINT_BLUE_MID := 0x4d6bfe
const TINT_RED_LO := 0x080604
const TINT_RED_HI := 0xff3a28
const TINT_LEVELS := 8

## 左窗格当前内容（`"chat" / "cursor" / "her" / "-"`），供底栏显示（tui_live.py:L3049-3060）。
static var WINDOW := "-"
## `c` 键：左窗格在 dsh 聊天与她自己之间切换（tui_live.py 的 `CHAT[0]`）。
static var CHAT := true
## 上一帧她是否在窗格里（`ent["last_her"]`）。
static var LAST_HER := false

## 她的窗格格区（半开矩形），每帧由 `draw_body()` 写入；C 层 `PvMotion` 只在这块里做行位移。
static var HER_RECT := Rect2i()
## 她的**画稿**区域（窗格去掉框线与标题那一圈后的内部），音乐反应只作用在这里。
static var HER_ART := Rect2i()
## 采样帧率（底栏显示用，由主场景每 0.5 s 采样一次写进来）。
static var FPS := 0.0
## 播放 / 暂停（底栏显示用）。
static var PLAYING := true
## 输入开关（底栏显示用；关闭时按键提示改成「输入禁用」）。
static var INPUT_ON := true
## 音量百分比与静音（底栏显示用，由主场景每帧从 PvClock 同步过来）。
static var VOL_PCT := 80
static var MUTED := false
## B 层（真终端文本流）是否占用 stdout 带：为真时 A 层把这条带让出去（只留底色），
## 免得同一份 boot 日志 / 歌词在字符格和真终端上各画一遍。由主场景每帧同步。
static var STREAM_ON := false

var _re := RegEx.new()
var _crc_table: Array[int] = []


func _init() -> void:
	_re.compile("\\S+\\s*")
	_crc_table.resize(256)
	for i in 256:
		var c := i
		for _k in 8:
			c = (c >> 1) ^ (0xEDB88320 if (c & 1) else 0)
		_crc_table[i] = c


# ================================================================ 每帧入口

## 参考 `draw()`（tui_live.py:L3234-3296）。`ent` 为当前镜头（无则 `{}`）。
func draw(s: PvScreen, d: PvData, t: float, ent: Dictionary) -> void:
	s.begin_frame(t)
	var name := str(ent.get("name", ""))
	var u := 0.0 if ent.is_empty() else PvShots.shot_u(t, ent)
	s.add_clear(0, 0, s.cols - 1, 0)
	s.add_clear(0, s.rows - 4, s.cols - 1, s.rows - 1)
	PV.UI_GAIN = PvShots.ui_gain_at(t, name, u)
	s.fill(0, 0, s.cols - 1, s.rows - 1, " ", PV.UI, PV.BG)
	draw_header(s, d, t)
	var top := 1
	var bottom := s.rows - 5
	if bottom - top < 6:
		return
	var lay := PvStage.shot_layout(ent)
	var mode := str(lay[0])
	var kind := str(lay[1])
	if _staged(mode, kind):
		_draw_staged(s, d, t, ent, mode, kind, top, bottom)
	else:
		draw_body(s, d, t, ent, top, bottom)
	draw_footer(s, d, t, ent)


## pip / tiles / floating 需要「先画一张完整画布，再合成到窗格」；其余模式直接画。
func _staged(mode: String, kind: String) -> bool:
	if not (bool(PV.FX["on"]) and bool(PV.FX["stage"])):
		return false
	if not (mode in ["pip", "tiles", "floating"]):
		return false
	return not PvStage.cell_geometry(mode, kind).is_empty()


## 窗格合成：把一份完整的 197×52 画布按 `PvStage.cell_geometry()` 的 dst **1:1 拷贝**过去
## （4A：不缩放；dst 小于 src 就裁，大于就留底）。合成后把 stdout 带、CLEAR/NOGHOST、
## 她的画稿区一并映射到主屏坐标，B 层与 C 层反应继续有效。
static var _stage_scratch: PvScreen


func _draw_staged(s: PvScreen, d: PvData, t: float, ent: Dictionary,
		mode: String, kind: String, top: int, bottom: int) -> void:
	if _stage_scratch == null or _stage_scratch.cols != s.cols or _stage_scratch.rows != s.rows:
		_stage_scratch = PvScreen.new(s.atlas, s.cols, s.rows)
	var sc := _stage_scratch
	sc.begin_frame(t)
	sc.fill(0, 0, sc.cols - 1, sc.rows - 1, " ", PV.UI, PV.BG)
	draw_body(sc, d, t, ent, top, bottom)
	var lx := maxi(24, mini(s.cols - 20, int(s.cols * 0.60)))
	var me_src := HER_RECT if HER_RECT.size.x > 0 else Rect2i(1, top, lx, bottom - top + 1)
	var viz_src := Rect2i(lx + 1, top, maxi(1, s.cols - 2 - lx), bottom - top + 1)
	var full_src := Rect2i(1, top, maxi(1, s.cols - 2), bottom - top + 1)
	var els: Array = []
	for g in PvStage.cell_geometry(mode, kind):
		var id := str(g["id"])
		if id == "htop" or id == "lyrics":
			els.append({"id": id, "src": Rect2i(), "dst": g["dst"], "frame": ""})
			continue
		var src := viz_src
		if id == "me":
			src = me_src
		elif kind != "split":
			src = full_src
		els.append({"id": id, "src": src, "dst": g["dst"], "frame": str(g["frame"])})
	for el in els:
		if str(el["id"]) == "htop" or str(el["id"]) == "lyrics":
			continue
		var dst: Rect2i = el["dst"]
		s.fill(dst.position.x, dst.position.y,
			dst.position.x + dst.size.x - 1, dst.position.y + dst.size.y - 1, " ", PV.UI, PV.BG)
		_blit(s, sc, el["src"], dst)
		if not str(el["frame"]).is_empty():
			s.box(dst.position.x, dst.position.y,
				dst.position.x + dst.size.x - 1, dst.position.y + dst.size.y - 1, str(el["frame"]), 0.45)
	# ---- tiles 的两个附加窗格（参考 `stage.py:L337-345`：htop 右下、歌词日志左下）
	if mode == "tiles" and kind == "split":
		_draw_htop(s, d, t, ent, Rect2i(119, 29, 77, 18))
		_draw_lyric_log(s, d, t, Rect2i(0, 29, 118, 18))
	# ---- 坐标映射：stdout 带 / CLEAR / NOGHOST / 她的画稿区
	# pip 的 her 窗格是「画中画」，放不下 16 行终端 —— 参考里输出也归可视化窗格，
	# 所以 pip 把 stdout 带映射到 viz，其余模式跟着她走。
	var band_target: Dictionary = els[0]
	for el in els:
		if str(el["id"]) == ("viz" if mode == "pip" else "me"):
			band_target = el
	var band := _map_into(sc.stdout_rect, band_target)
	s.stdout_rect = band
	if band.size.x > 0 and band.size.y > 0:
		s.add_clear(band.position.x, band.position.y,
			band.position.x + band.size.x - 1, band.position.y + band.size.y - 1)
	for r in sc.clear_rects:
		var rr := Rect2i(int(r[0]), int(r[1]), int(r[2]) - int(r[0]) + 1, int(r[3]) - int(r[1]) + 1)
		var m := _map_stage_rect(rr, els)
		if m.size.x > 0 and m.size.y > 0:
			s.add_clear(m.position.x, m.position.y,
				m.position.x + m.size.x - 1, m.position.y + m.size.y - 1)
	for r in sc.noghost_rects:
		var rr2 := Rect2i(int(r[0]), int(r[1]), int(r[2]) - int(r[0]) + 1, int(r[3]) - int(r[1]) + 1)
		var m2 := _map_stage_rect(rr2, els)
		if m2.size.x > 0 and m2.size.y > 0:
			s.add_noghost(m2.position.x, m2.position.y,
				m2.position.x + m2.size.x - 1, m2.position.y + m2.size.y - 1)
	if HER_RECT.size.x > 0:
		HER_RECT = _map_stage_rect(HER_RECT, els)
	if HER_ART.size.x > 0:
		HER_ART = _map_stage_rect(HER_ART, els)


## 1:1 拷贝（裁到 dst 大小；越界格跳过）。
func _blit(dst: PvScreen, src: PvScreen, sr: Rect2i, dr: Rect2i) -> void:
	var w := mini(sr.size.x, dr.size.x)
	var h := mini(sr.size.y, dr.size.y)
	for y in h:
		for x in w:
			var sx := sr.position.x + x
			var sy := sr.position.y + y
			if sx < 0 or sx >= src.cols or sy < 0 or sy >= src.rows:
				continue
			var i := sy * src.cols + sx
			dst.set_full(dr.position.x + x, dr.position.y + y,
				src.cp[i], src.slot[i], src.fg[i], src.bg[i], src.wide[i])


## 把矩形**强制**映射进某个窗格（不按中心点归属；stdout 带用）。
## 先按窗格源矩形的偏移落位，再夹进 dst；能整块放下就保持原尺寸。
func _map_into(r: Rect2i, el: Dictionary) -> Rect2i:
	var sr: Rect2i = el["src"]
	var dr: Rect2i = el["dst"]
	if r.size.x <= 0 or r.size.y <= 0 or sr.size.x <= 0 or sr.size.y <= 0:
		return Rect2i(dr.position.x, dr.position.y, 0, 0)
	var max_x := dr.position.x + maxi(0, dr.size.x - r.size.x)
	var max_y := dr.position.y + maxi(0, dr.size.y - r.size.y)
	var x := clampi(dr.position.x + (r.position.x - sr.position.x), dr.position.x, max_x)
	var y := clampi(dr.position.y + (r.position.y - sr.position.y), dr.position.y, max_y)
	var w := mini(r.size.x, dr.position.x + dr.size.x - x)
	var h := mini(r.size.y, dr.position.y + dr.size.y - y)
	return Rect2i(x, y, maxi(0, w), maxi(0, h))


## 把画布坐标的矩形映射到它所属窗格的 dst（按中心点归属；与 `stage.to_screen` 同法）。
func _map_stage_rect(r: Rect2i, els: Array) -> Rect2i:
	if r.size.x <= 0 or r.size.y <= 0:
		return r
	var cx := r.position.x + r.size.x / 2.0
	var cy := r.position.y + r.size.y / 2.0
	for el in els:
		var sr: Rect2i = el["src"]
		var dr: Rect2i = el["dst"]
		if sr.size.x <= 0 or sr.size.y <= 0:
			continue
		if cx >= sr.position.x and cx <= sr.position.x + sr.size.x \
				and cy >= sr.position.y and cy <= sr.position.y + sr.size.y:
			# 先按偏移落位，再夹进 dst（能整块放下就整块放下；放不下才裁到边缘）
			var max_x := dr.position.x + maxi(0, dr.size.x - r.size.x)
			var max_y := dr.position.y + maxi(0, dr.size.y - r.size.y)
			var x := clampi(dr.position.x + (r.position.x - sr.position.x), dr.position.x, max_x)
			var y := clampi(dr.position.y + (r.position.y - sr.position.y), dr.position.y, max_y)
			var w := mini(r.size.x, dr.position.x + dr.size.x - x)
			var h := mini(r.size.y, dr.position.y + dr.size.y - y)
			if w <= 0 or h <= 0:
				return Rect2i(dr.position.x, dr.position.y, 0, 0)
			return Rect2i(x, y, w, h)
	return r


## tiles 的右下 htop（`stage.py:L181-195` 的 `htop()` + `_gpu_bars` + `_procs`）。
## 8 条 GPU 利用率条（`0.55 + 0.4·|sin(t·(1.3+g·0.21)+g)|`）+ 内存条 + 轮转的 ops 进程表。
func _draw_htop(s: PvScreen, d: PvData, t: float, ent: Dictionary, r: Rect2i) -> void:
	var x1 := r.position.x + r.size.x - 1
	var y1 := r.position.y + r.size.y - 1
	s.box(r.position.x, r.position.y, x1, y1, "htop", 0.45)
	s.add_noghost(r.position.x, r.position.y, x1, y1)
	var x0 := r.position.x + 2
	var bar_w := maxi(4, r.size.x - 16)
	for g in 8:
		var util := 0.55 + 0.4 * absf(sin(t * (1.3 + g * 0.21) + g))
		var yy := r.position.y + 1 + g
		var n := int(bar_w * util)
		s.put(x0, yy, "%d[" % g, PV.mix(PV.ANOM, 0.7))
		s.put(x0 + 2, yy, "|".repeat(n), PV.ANOM if util > 0.9 else PV.mix(PV.ANOM, 0.85))
		s.put(x0 + 2 + bar_w, yy, "%3d%%]" % int(util * 100), PV.mix(PV.ANOM, 0.7))
	var my := r.position.y + 10
	s.put(x0, my, ("Mem[" + "|".repeat(mini(20, maxi(4, bar_w / 2))) + " 71G/80G]").substr(0, r.size.x - 4),
		PV.mix(PV.ANOM, 0.75))
	var ops: Array = ent.get("ops", []) if not ent.is_empty() else []
	if ops.is_empty():
		ops = ["idle"]
	var hy := r.position.y + 12
	s.put(x0, hy, " PID USER  %GPU COMMAND".substr(0, r.size.x - 4), PV.BG, PV.mix(PV.ANOM, 0.8))
	var cur := int(t / (PV.BEAT / 2.0)) % ops.size()
	for i in 4:
		var yy2 := hy + 1 + i
		if yy2 > y1 - 1:
			break
		var oi := (cur + i) % ops.size()
		var row := "%5d me %4d %s" % [4471 + i, 90 - i * 7, str(ops[oi]).to_lower()]
		s.put(x0, yy2, row.substr(0, r.size.x - 4),
			PV.mix(PV.ME_TEXT, 0.95) if i == 0 else PV.mix(PV.ANOM, 0.6))


## tiles 的左下歌词日志（`stage.py:L115-130` 的 `lyric_log`）：最近 5 行，当前行高亮。
func _draw_lyric_log(s: PvScreen, d: PvData, t: float, r: Rect2i) -> void:
	var x1 := r.position.x + r.size.x - 1
	var y1 := r.position.y + r.size.y - 1
	s.box(r.position.x, r.position.y, x1, y1, "lyrics", 0.45)
	s.add_noghost(r.position.x, r.position.y, x1, y1)
	var lines: Array = d.lines
	var idx := -1
	for i in lines.size():
		if float(lines[i]["start"]) <= t:
			idx = i
	if idx < 0:
		return
	var first := maxi(0, idx - 4)
	var yy := r.position.y + 1
	for i in range(first, idx + 1):
		if yy > y1 - 1:
			break
		var ln: Dictionary = lines[i]
		var sec := float(ln["start"])
		var tag := "[%02d:%05.2f]" % [int(sec / 60.0), fmod(sec, 60.0)]
		s.put(r.position.x + 2, yy, tag, PV.mix(PV.ANOM, 0.45))
		var txt := str(ln["text"])
		s.put(r.position.x + 13, yy, txt.substr(0, maxi(0, r.size.x - 15)),
			PV.mix(PV.ANOM, 0.95 if i == idx else 0.5))
		yy += 1


# ================================================================ 顶栏（§3.1）

func draw_header(s: PvScreen, d: PvData, t: float) -> void:
	s.put(1, 0, "WORLD.EXECUTE(ME);", PV.ui(1.0))
	s.put(21, 0, "whale@deepsea:~", PV.ME_TEXT)
	var clock := "%02d:%04.1f / 03:32" % [int(t / 60.0), fmod(maxf(0.0, t), 60.0)]
	var tail := "  " + PvShots.chapter_at(t)
	var wav_x := 38
	var wav_w := maxi(8, s.cols - wav_x - clock.length() - tail.length() - 4)
	if wav_w > 8:
		s.waveform(wav_x, 0, wav_w, d, t, PV.mix(PV.ME_TEXT, 0.85))
	s.put(s.cols - clock.length() - tail.length() - 2, 0, clock, PV.ui(PV.UI_DIM_LEVEL))
	s.put(s.cols - tail.length() - 1, 0, tail, PV.mix(PV.ANOM, 0.75))


# ================================================================ 主体（§2.3 / §3.3–§3.8）

## 参考 `draw_body()`（tui_live.py:L3007-3194）。
func draw_body(s: PvScreen, d: PvData, t: float, ent: Dictionary, top: int, bottom: int) -> void:
	var cols := s.cols
	var name := str(ent.get("name", ""))
	HER_RECT = Rect2i()
	HER_ART = Rect2i()
	var lx := maxi(24, mini(cols - 20, int(cols * 0.60)))
	var sp_bottom := mini(top + 8, bottom - 4)

	# C 层 mirror（`full/stage.py:L228-231`）：她的窗格与可视化窗格左右互换。
	# 参考在 anchored 模式下把 mirror 退回 split；本工程没有 anchored 版式，直接交换两列。
	# stdout 带跟着她走（`screen.stdout_rect` 用新列写出），B 层按新 rect 重贴 —— 只在镜头切换时变一次。
	var mirror := _mirror(ent, cols)
	var left_x0 := 1
	var left_x1 := lx
	var right_x0 := lx + 1
	var right_x1 := cols - 2
	if mirror:
		left_x0 = cols - 1 - lx
		left_x1 = cols - 2
		right_x0 = 1
		right_x1 = cols - 2 - lx

	# her 窗格：stdout 带先拿走它真正想要的高度，剩下的都给她
	var main_h := bottom - top + 1
	var band_want := 16 if t < PV.SIM_START else (12 if t < PV.SIM_END else 15)
	var her := (not ent.is_empty()) and bool(ent.get("her", false)) and cols >= 96
	var her_h := 0
	for need in [band_want, BAND_MIN_H]:
		her_h = mini(HER_MAX_H, main_h - int(need))
		if her_h >= HER_MIN_H:
			break
	her = her and her_h >= HER_MIN_H
	var room := (not ent.is_empty()) and cols >= 96 and her_h >= HER_MIN_H
	var gone := PvShots.dsh_gone(t)
	var keep := her_keeps_pane(ent)
	var chat := room and CHAT and PvShots.dsh_inside(t) and not gone and not keep
	var cursor := room and CHAT and gone and not keep
	var walls := 0
	if not ent.is_empty() and name in ["shot_trapped", "shot_red_trapped"]:
		walls = PvShots.kv_inset(PvShots.shot_u(t, ent))
	var hy1 := top + her_h - 1
	var hx0 := left_x0
	var hy0 := top
	var hx1 := left_x1
	if walls and (her or chat):
		for j in walls:
			s.box(left_x0 + j * 6, top + j, left_x1 - j * 6, hy1 - j, "", 0.15)
		hx0 = left_x0 + walls * 6
		hy0 = top + walls
		hx1 = left_x1 - walls * 6
		hy1 = hy1 - walls
	if chat:
		WINDOW = "chat"
		s.add_clear(hx0, hy0, hx1, hy1)
		draw_dsh(s, d, t, hx0, hy0, hx1, hy1)
	elif cursor:
		WINDOW = "cursor"
		s.add_clear(hx0, hy0, hx1, hy1)
		draw_cursor(s, t, hx0, hy0, hx1, hy1)
	elif her:
		WINDOW = "her"
		HER_RECT = Rect2i(hx0, hy0, hx1 - hx0 + 1, hy1 - hy0 + 1)
		draw_her(s, d, t, ent, hx0, hy0, hx1, hy1)
		# `full/sec_chorus1.py:L91`：只有 shot_deeply 打开气泡（`engine.py:L312-319`）。
		draw_bubbles(s, t, hx0, hy0, hx1, hy1, bubbles_for(name))
		LAST_HER = true
	else:
		WINDOW = "-"
		HER_RECT = Rect2i()
	var band_top := top + (her_h if (her or chat or cursor) else 0)

	# ------------------------------------------------------------ stdout 带
	# 格区报给 B 层：真终端贴在同一条带上（mirror 时整条带跟着她挪到右边）。
	s.stdout_rect = Rect2i(left_x0, band_top, left_x1 - left_x0 + 1, bottom - band_top + 1)
	if STREAM_ON:
		# B 层启用时把整条带让出去，只留底色 —— 否则同一份 boot 日志 / 歌词会叠成两层字。
		s.fill(left_x0, band_top, left_x1, bottom)
	elif t < PV.SIM_START:
		draw_boot_log(s, d, t, left_x0, band_top, left_x1, bottom)
	elif t < PV.SIM_END:
		draw_sim_start(s, t, left_x0, band_top, left_x1, bottom)
	else:
		s.add_clear(left_x0, band_top, left_x1, bottom)
		draw_lyrics(s, d, t, left_x0, band_top, left_x1, bottom)

	# ------------------------------------------------------------ feature bands（§3.8）
	draw_bands(s, d, t, right_x0, top, right_x1, sp_bottom)

	# ------------------------------------------------------------ 章节面板（§7）
	# 面板占用的行由 `_draw_chapter_pane()` 返回，ops ticker 从它下面接着画。
	var rw := right_x1 - right_x0 + 1 - 2
	var ops_top := sp_bottom + 1
	var pane_h := _draw_chapter_pane(s, t, ent, name, rw, right_x0, ops_top, right_x1, bottom)
	ops_top += pane_h
	# ------------------------------------------------------------ ops ticker（§3.6）
	draw_ops(s, t, ent, right_x0, ops_top, right_x1, bottom)


## C 层 mirror 判定：只有 `mirror + split` 需要左右互换
## （`full/stage.py:L257-258` 里 `mirror/full` 属于 identity，不重排）。
func _mirror(ent: Dictionary, cols: int) -> bool:
	if cols < 96 or ent.is_empty():
		return false
	var lay := PvStage.shot_layout(ent)
	return str(lay[0]) == "mirror" and str(lay[1]) == "split"


## 气泡强度：参考里只有 `shot_deeply` 传 `bubbles=1.0`（`full/sec_chorus1.py:L91`），其余为 0。
static func bubbles_for(name: String) -> float:
	return 1.0 if name == "shot_deeply" else 0.0


## `engine.py:L312-319`（`me_pane(..., bubbles=...)`）：她身边上浮的 `oO°.o`。
##
## 参考是像素坐标（字号 14、上浮 260 px），这里按格换算：
## 起点 = 窗格顶部 +3 行，每周期上浮 14 行，水平在窗格 30 %~70 % 之间按黄金分割错开，
## 再加 ±1 格的横向摆动。
func draw_bubbles(s: PvScreen, t: float, x0: int, y0: int, x1: int, y1: int, amount: float) -> void:
	if amount <= 0.01 or x1 - x0 < 6 or y1 - y0 < 6:
		return
	var w := x1 - x0 + 1
	for i in 14:
		var ph := fmod(t * (0.35 + 0.05 * float(i % 5)) + i * 0.137, 1.0)
		var bx := x0 + int(w * (0.3 + 0.4 * fmod(float(i) * 0.618, 1.0))) + roundi(0.9 * sin(t * 3.0 + i))
		var by := y0 + 3 - roundi(ph * 14.0)
		if bx < x0 or bx > x1 or by < y0 or by > y1:
			continue
		if s.in_clear(bx, by):
			continue
		s.set_raw(bx, by, BUBBLE_CHARS.substr(i % 5, 1),
			PV.mix(PV.ME_TEXT, 0.8 * amount * (1.0 - ph)))


## 章节面板：参考 `draw_body()` 的分发段（tui_live.py:L3082-3189）。分发规格与几何见
## tools/ref/layout.md §7，逐条照抄；实际绘制在 `PvPanes`。
##
## 返回面板占用的行高（0 = 放不下，行全部还给 ops ticker）：`avail = bottom - sp_bottom`、
## `pane_h = min(need, avail - 6)`，若 `pane_h < least` 则不画 —— 与参考实现一致。
func _draw_chapter_pane(s: PvScreen, t: float, ent: Dictionary, name: String,
		rw: int, px0: int, py0: int, x1: int, bottom: int) -> int:
	var spec := PvPanes.spec(name, rw)
	var pane := str(spec[0])
	if pane.is_empty():
		return 0
	var avail := bottom - py0 + 1
	var pane_h := mini(int(spec[1]), avail - 6)
	if pane_h < int(spec[2]):
		return 0
	var py1 := py0 + pane_h - 1
	var dur := float(ent["end"]) - float(ent["start"])
	var u := PvShots.shot_u(t, ent)
	PvPanes.draw_pane(pane, s, t, ent, px0, py0, x1, py1, u, u * dur, dur)
	return pane_h


func draw_bands(s: PvScreen, d: PvData, t: float, x0: int, top: int, x1: int, sp_bottom: int) -> void:
	s.box(x0, top, x1, sp_bottom, "feature bands", 0.55, PV.ME_TEXT)
	var inner := sp_bottom - top - 1
	for i in mini(7, inner):
		var yy := top + 1 + i
		var v := d.band_at(t, i)
		s.put(x0 + 2, yy, PV.BANDS[i].rpad(7), PV.ui(0.68))
		var bar_x := x0 + 11
		var bar_w := maxi(4, x1 - bar_x - 1)
		s.hbar(bar_x, yy, bar_w, v, PV.mix(PV.ME_TEXT, 0.45 + 0.55 * v))


## 参考 `draw_ops()`（tui_live.py:L2734-2759）。
func draw_ops(s: PvScreen, t: float, ent: Dictionary, x0: int, y0: int, x1: int, y1: int) -> void:
	var err := str(ent.get("alert", "")) == "err"
	s.box(x0, y0, x1, y1, "ops", 0.45, PV.RED if err else PV.ui(1.0))
	s.add_noghost(x0, y0, x1, y1)
	s.add_clear(x0, y0, x1, y1)
	var ops: Array = ent.get("ops", [])
	if ops.is_empty():
		ops = ["IDLE"]
	var inner := y1 - y0 - 1
	var base := int(t / (PV.BEAT / 2.0))
	var cur := int((inner - 1) / 2)
	var w := maxi(4, x1 - x0 - 3)
	for k in inner:
		var op := str(ops[wrapi(base + k - cur, 0, ops.size())])
		var yy := y0 + 1 + k
		if k == cur:
			s.put(x0 + 2, yy, (" " + op).substr(0, w).lpad(w),
				PV.BG, PV.RED if err else PV.ui(1.0))
		else:
			s.put(x0 + 2, yy, op.substr(0, w), PV.ui(maxf(0.42, 0.78 - absi(k - cur) * 0.03)))


# ================================================================ 底栏（§3.2）

func draw_footer(s: PvScreen, d: PvData, t: float, ent: Dictionary) -> void:
	var cols := s.cols
	var rows := s.rows
	var py := rows - 4
	s.box(1, py, cols - 2, py + 2, "progress", 0.5)
	var bar_x := 4
	var bar_w := maxi(10, cols - 8)
	s.hbar(bar_x, py + 1, bar_w, t / PV.END, PV.mix(PV.ME_TEXT, 0.9))
	var mark := bar_x + mini(bar_w - 1, int(t / PV.END * bar_w))
	s.put(mark, py + 1, "▓", PV.BG, PV.mix(PV.ME_HI, 1.0))

	var shot := PvShots.shot_index_at(t)
	var total := PvShots.shots().size()
	var how := str(ent.get("name", "-"))
	# `her:{HER_RENDER}` 再带上 `auto` 解析出来的 (how/tint)（tui_live.py:L3209-3211）
	var her_txt := "her:" + HER_RENDER
	if HER_RENDER == "auto":
		her_txt += "->%s/%s" % [her_style(ent), her_tint(ent)]
	var left := "shot %02d/%d  %s  win:%s  %s  vol %3d%%%s  fx:%s" % [
		shot + 1, total, how, WINDOW, her_txt, VOL_PCT,
		"  MUTED" if MUTED else "", "on" if PV.FX["on"] else "off"]
	var msg := ""
	var msg_col := PV.ui(0.62) if PLAYING else PV.mix(PV.ANOM, 0.8)
	if not INPUT_ON:
		# 输入禁用时，按键提示整块让位给这一行（按显示宽度右对齐，CJK 占两格）。
		msg = "输入禁用"
		msg_col = PV.mix(PV.ANOM, 0.9)
	elif cols >= 130:
		msg = "%s  %4.1f fps   h her   c chat   x fx   space toggle   q quit" % [
			"PLAYING" if PLAYING else "paused ", FPS]
	else:
		msg = "%s %4.1ffps  h her  c chat  x fx  q quit" % ["PLAY" if PLAYING else "PAUSE", FPS]
	var msg_w := 0
	for ch in msg:
		msg_w += s.atlas.width_of(ch)
	var msg_x := maxi(2, cols - msg_w - 1)
	s.put(2, rows - 1, left.substr(0, maxi(10, msg_x - 3)), PV.ui(0.55))
	s.put(msg_x, rows - 1, msg, msg_col)


# ================================================================ boot log / sim.start（§3.4 / §3.5）

## 参考 `draw_boot_log()`（tui_live.py:L1531-1550）。
func draw_boot_log(s: PvScreen, d: PvData, t: float, x0: int, y0: int, x1: int, y1: int) -> void:
	if x1 - x0 < 3 or y1 - y0 < 2:
		return
	var title := "init --protection" if t >= 1.313 else ""
	s.box(x0, y0, x1, y1, title, 0.5, PV.ui(1.0))
	var printed := d.boot_printed(t)
	var all_rows: int = d.boot_log.size()
	var inner := y1 - y0 - 1
	if inner < 1:
		return
	var shown: Array = printed
	if shown.size() > inner:
		shown = shown.slice(shown.size() - inner)
	for i in shown.size():
		var row: Array = shown[i]
		var st := str(row[1])
		var yy := y0 + 1 + i
		var col := PV.ui(0.8)
		if st == "OK":
			col = PV.ui(0.95)
		elif st == "WARN":
			col = PV.mix(PV.ANOM, 0.95)
		elif st == "..":
			col = PV.ui(0.5)
		s.put(x0 + 2, yy, "[%s]" % _tag4(st), col)
		s.put(x0 + 10, yy, str(row[2]).substr(0, maxi(0, x1 - x0 - 12)), PV.ui(0.75))
	if printed.size() < all_rows and shown.size() < inner and int(t * 2.0) % 2 == 0:
		s.put(x0 + 2, y0 + 1 + shown.size(), "█", PV.mix(PV.ANOM, 0.9))
	s.put(x0 + 2, y1 - 1, "post %d/%d" % [printed.size(), all_rows], PV.ui(0.35))


## 参考 `draw_sim_start()`（tui_live.py:L1553-1572）。大字用 `block_word`（图集放大，非 Anton）。
func draw_sim_start(s: PvScreen, t: float, x0: int, y0: int, x1: int, y1: int) -> void:
	if x1 - x0 < 3 or y1 - y0 < 2:
		return
	s.box(x0, y0, x1, y1, "sim.start()", 0.5, PV.ui(1.0))
	var u := clampf((t - PV.SIM_START) / maxf(1e-6, PV.SIM_END - PV.SIM_START), 0.0, 1.0)
	var inner_w := x1 - x0 - 3
	var inner_h := y1 - y0 - 1
	if u < 0.55:
		var n := 3 - mini(2, int(u / 0.55 * 3.0))
		var rows := maxi(3, mini(inner_h - 1, 14))
		block_word(s, x0 + 2, y0 + 1 + maxi(0, int((inner_h - rows) / 2)), str(n), inner_w, rows,
			PV.mix(PV.ANOM, 0.95))
	else:
		var rows2 := maxi(4, mini(8, inner_h - 3))
		block_word(s, x0 + 2, y0 + 1, "RUN", inner_w, rows2, PV.mix(PV.ANOM, 1.0))
		s.put(x0 + 2, y0 + 2 + rows2, "simulation: running", PV.ui(0.9))
		s.put(x0 + 2, y0 + 3 + rows2, "tokens budget: %d" % 15_000_000_000, PV.ui(0.7))


## 把一段文字渲染成 rows 行高的块字（参考实现的 `block_word` / `FP.banner_fit` 用 Anton 字体
## 降采样；这里改用图集里的 ASCII 字形按整数倍放大后以 `█` 填实，见 README「已知取舍」）。
## 返回用掉的行数。
func block_word(s: PvScreen, x: int, y: int, text: String, max_cols: int, rows: int,
		colour: int, glyph := "█") -> int:
	var scale := maxi(1, rows / 8)
	var base_y := y + maxi(0, int((rows - _FONT_H * scale) / 2.0))
	var cx := x
	for ch in text:
		var g: Array = _glyph_bits(ch)
		if g.is_empty():
			continue
		if cx + _FONT_W * scale > x + max_cols:
			break
		for r in _FONT_H:
			var bits := str(g[r])
			for c in _FONT_W:
				if bits[c] != "1":
					continue
				var px := cx + c * scale
				var py := base_y + r * scale
				for dy in scale:
					for dx in scale:
						if px + dx < x + max_cols and py + dy <= y + rows - 1:
							s.put(px + dx, py + dy, glyph, colour)
		cx += (_FONT_W + 1) * scale
	return rows


func _glyph_bits(ch: String) -> Array:
	# 7×5 的 ASCII 点阵：没有图集外的字体依赖，放大后即块字。
	var font := _prompt_font()
	if font.is_empty():
		return []
	var rows: Array = font.get(ch, [])
	return rows


static func _prompt_font() -> Dictionary:
	return _FONT


const _FONT_H := 7
const _FONT_W := 5

## 7 行 × 5 列的手写点阵（数字 0-9 + block_word 用到的字母）。
static var _FONT := {
	"0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
	"1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
	"2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
	"3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
	"4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
	"5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
	"6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
	"7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
	"8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
	"9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
	"R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
	"U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
	"N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
}


# ================================================================ 歌词带（§3.3）

## 参考 `draw_lyrics()`（tui_live.py:L2915-3004）。
func draw_lyrics(s: PvScreen, d: PvData, t: float, x0: int, y0: int, x1: int, y1: int) -> void:
	if x1 - x0 < 4 or y1 - y0 < 3:
		return
	s.box(x0, y0, x1, y1, "stdout · tokens", 0.45 + 0.3 * d.feat(t, "kick"))
	s.add_noghost(x0 + 1, y0 + 1, x1 - 1, y1 - 1)
	var inner_x := x0 + 2
	var inner_w := x1 - x0 - 3
	var cur: Array = d.line_at(t)
	var ln: Dictionary = cur[0]
	var alpha := float(cur[1])
	var y := y0 + 1
	if ln.is_empty():
		if int(t * 2.0) % 2 == 0:
			s.put(inner_x, y, "█", PV.mix(PV.ANOM, 0.9))
	else:
		var text := str(ln["text"])
		var typed: Array = d.typed(ln, t)
		var n_out := int(typed[0])
		var level := 0.35 + 0.65 * alpha
		s.put(inner_x - 1, y, ">", PV.mix(PV.ANOM, 0.6))
		s.put(inner_x, y, text.substr(0, n_out), PV.ui(level))
		if n_out < text.length() and int(t * 3.0) % 2 == 0:
			s.put(inner_x + n_out, y, "█", PV.mix(PV.ANOM, 0.9))
		# 中文对照（行 y0+2）
		var cy := y0 + 2
		s.put(inner_x, cy, " ".repeat(inner_w), PV.UI, PV.BG)
		var cn := d.lyric_cn_for(text)
		if not cn.is_empty():
			s.put(inner_x, cy, ("// " + cn).substr(0, inner_w), PV.mix(PV.ME_TEXT, level * 0.65))
		# token 芯片（行 y0+3 起）
		y += 2
		var cx := inner_x - 1
		for wv in (ln["words"] as Array):
			var shown := text.substr(int(wv[0]), int(wv[1]) - int(wv[0]))
			if shown.is_empty():
				continue
			var tid := "%d" % token_id(shown)
			var need := maxi(shown.length() + 3, tid.length() + 2)
			if cx + need > inner_x + inner_w:
				cx = inner_x - 1
				y += 2
			var kw: Variant = keyword_colour(shown)
			if kw != null:
				s.put(cx, y, " %s " % shown, PV.BG, int(kw))
			else:
				var bg := PV.mix(PV.ANOM, 0.13 if (y % 2 == 0) else 0.22)
				s.put(cx, y, " %s " % shown, PV.mix(PV.ANOM, 0.95), bg)
			s.put(cx + 1 + maxi(0, int((shown.length() - tid.length()) / 2)), y + 1,
				tid, PV.ui(0.45 * level))
			cx += need
		# 歌词日志
		if y + 3 <= y1 - 1:
			y += 2
			s.put(inner_x - 1, y, "lyric log", PV.ui(0.55))
			y += 1
			var room := maxi(1, y1 - y)
			var idx := _line_index(d, ln)
			var total := d.lines.size()
			var first := mini(maxi(0, idx - int(room / 3.0)), maxi(0, total - room))
			for k in room:
				var li := first + k
				if li < 0 or li >= total:
					continue
				var l2: Dictionary = d.lines[li]
				var here := li == idx
				var far := absi(li - idx)
				s.put(inner_x - 1, y, ">" if here else " ", PV.mix(PV.ANOM, 0.6))
				s.put(inner_x, y, str(l2["text"]).substr(0, inner_w),
					PV.mix(PV.ME_TEXT, 0.9) if here else PV.ui(maxf(0.36, 0.62 - 0.08 * far)))
				y += 1


func _line_index(d: PvData, ln: Dictionary) -> int:
	for i in d.lines.size():
		if d.lines[i] == ln:
			return i
	return 0


# ================================================================ 压力窗（§3.13）

## `"Challenging your God"` 起点到 `"Illegal arguments"` 终点（125.58–133.95 s）。
func pressure_window(d: PvData) -> Array:
	var lo := 0.0
	var hi := 0.0
	for ln in d.lines:
		var text := str(ln["text"])
		if text.begins_with("Challenging your God"):
			lo = float(ln["start"])
		if text.begins_with("Illegal arguments"):
			hi = float(ln["end"])
	return [lo, hi]


func draw_pressure(s: PvScreen, d: PvData, t: float, x0: int, y0: int, x1: int, y1: int) -> bool:
	var win := pressure_window(d)
	if not (float(win[0]) <= t and t < float(win[1]) and (y1 - y0) >= 10 and (x1 - x0) >= 14):
		return false
	var u := clampf((t - float(win[0])) / maxf(1e-6, float(win[1]) - float(win[0])), 0.0, 1.0)
	var ln: Dictionary = {}
	for l in d.lines:
		if str(l["text"]).begins_with("Challenging your God"):
			ln = l
			break
	if ln.is_empty():
		return false
	var fg := _lerp_color(PV.ME_HI, PV.RED, pow(u, 1.5))
	var col: Variant = _lerp_color(PV.UI, PV.RED, u) if u > 0.3 else null
	s.box(x0, y0, x1, y1, "stdout · tokens", 0.5 + 0.45 * u, col)
	var h := y1 - y0 - 1
	var y := y0 + maxi(1, int((h - 3) / 2.0))
	var jit := int(2.0 * u * PV.pulse(t)) * (1 if int(t * 6.0) % 2 == 0 else -1)
	var text := str(ln["text"])
	var n_out := int(d.typed(ln, t)[0])
	var tail := "█" if n_out < text.length() and int(t * 3.0) % 2 == 0 else ""
	s.put(x0 + 3 + jit, y, "> " + text.substr(0, n_out) + tail, PV.ui(0.9), PV.BG)
	s.put(x0 + 3 + jit, y + 1, "// " + d.lyric_cn_for(text), _lerp_color(PV.ME_TEXT, PV.RED, u), PV.BG)
	var iw := x1 - x0 - 7
	var cx := x0 + 3
	var ids := PackedStringArray()
	for wv in (ln["words"] as Array):
		ids.append(str(token_id(text.substr(int(wv[0]), int(wv[1]) - int(wv[0])))))
	var total := 0
	for k in (ln["words"] as Array).size():
		var wv: PackedFloat32Array = ln["words"][k]
		var shown := text.substr(int(wv[0]), int(wv[1]) - int(wv[0]))
		total += maxi(shown.length() + 3, ids[k].length() + 2)
	cx = x0 + 3 + maxi(0, int((iw - total) / 2.0))
	for k in (ln["words"] as Array).size():
		var wv: PackedFloat32Array = ln["words"][k]
		var shown := text.substr(int(wv[0]), int(wv[1]) - int(wv[0]))
		var tid: String = ids[k]
		var need := maxi(shown.length() + 3, tid.length() + 2)
		var kw: Variant = keyword_colour(shown)
		var hot := kw != null
		if hot:
			s.put(cx, y + 2, " %s " % shown, PV.BG, _lerp_color(int(kw), PV.RED, u))
		else:
			s.put(cx, y + 2, " %s " % shown, PV.mix(PV.ANOM, 0.95), PV.mix(PV.ANOM, 0.06))
		s.put(cx + 1 + maxi(0, int((shown.length() - tid.length()) / 2)), y + 3, tid, PV.ui(0.45))
		cx += need
	return true


# ================================================================ dsh 聊天窗（§3.7）

## 参考 `draw_dsh()`（tui_live.py:L2390-2484）。窗口文本来自电影的逐帧 DOM（`data/dsh.json`）；
## 头像块走 `_avatar_block()`（逐帧 PNG → PIL `Image.BOX` 面积平均 → `▀` 半块，上像素前景 / 下像素
## 背景），强调色 `accent` 取该帧的 `theme[1]`（`brand-primary`，页面按章节换主题），缺省
## `PV.ME_TEXT`；状态点色取首个 `dot` role 的 `#rrggbb`。`accent` 贯穿框线 / composer / 用户气泡
## 四角 / `▸ ` 卡片前缀。窗口内登记 NOGHOST：读的文本叠在文本上，不许留残影。
func draw_dsh(s: PvScreen, d: PvData, t: float, x0: int, y0: int, x1: int, y1: int) -> void:
	var fr: Dictionary = d.dsh_at(t)
	var items: Array = fr.get("rows", [])
	var theme: Array = fr.get("theme", [])
	var accent: Variant = _hex(str(theme[1])) if theme.size() > 1 else null
	if accent == null:
		accent = PV.ME_TEXT
	s.box(x0, y0, x1, y1, "dsh web", 0.5, accent)
	s.add_noghost(x0, y0, x1, y1)
	var ix := x0 + 2
	var inner := maxi(8, x1 - x0 - 4)
	var y := y0 + 1
	var bottom := y1 - 1

	# composer 与计数行钉在底部（页面的版式）；名字 / 状态 / 点色 / composer 都取首个匹配。
	var comp := ""
	var pills := PackedStringArray()
	var name := "大肥鱼"
	var state := ""
	var dot: Variant = null
	var got_name := false
	var got_state := false
	var got_comp := false
	var got_dot := false
	for it in items:
		var role := str(it.get("role", ""))
		var txt := str(it.get("text", ""))
		match role:
			"composer":
				if not got_comp:
					comp = txt
					got_comp = true
			"pill":
				if txt != "·":
					pills.append(txt)
			"name":
				if not got_name:
					name = txt
					got_name = true
			"state":
				if not got_state:
					state = txt
					got_state = true
			"dot":
				if not got_dot:
					dot = _hex(txt)
					got_dot = true
	var comp_h := 4 if (not comp.is_empty() and bottom - y > 8) else 0
	if comp_h:
		s.box(ix, bottom - 3, x1 - 2, bottom - 1, "", 0.4, accent, false)
		s.put(ix + 2, bottom - 2, comp.substr(0, inner - 2), PV.ui(0.62))
		if pills.size() > 0:
			s.put(ix, bottom, " · ".join(pills).substr(0, inner), PV.ui(0.58))

	# 头部：头像块 + 状态行。一格 1 宽 2 高，所以 cols == rows*2 时块是方的（14×7 = 14×14 px）。
	var hdr := 0
	var tall := (y1 - y0) >= 24
	var ar := 7 if tall else (5 if (y1 - y0) >= 14 else 3)
	var aw := mini(AVATAR_MAX_W, mini(maxi(6, inner / 6), 2 * ar))
	ar = maxi(3, aw / 2)
	aw = 2 * ar
	var av := str(fr.get("avatar", ""))
	var blk: Variant = _avatar_block(av, aw, ar) if not av.is_empty() else null
	if blk != null:
		var block: Array = blk
		for r in block.size():
			var brow: Array = block[r]
			for c in brow.size():
				var cell: Array = brow[c]
				s.put(ix + c, y + r, "▀", int(cell[0]), int(cell[1]))
		hdr = block.size()
	var tx := ix + (aw + 2 if blk != null else 0)
	s.put(tx, y, name, PV.ui(0.95))
	if not state.is_empty():
		var scol: int = PV.mix(int(dot), 0.95) if dot != null else PV.ui(0.78)
		s.put(tx, y + 1, "● " + state, scol)
	hdr = maxi(hdr, 2)

	var ttop := y + hdr + 1
	var tbot := bottom - comp_h
	var avail := tbot - ttop + 1
	if avail < 3:
		return
	var rows := _dsh_rows(items, inner)
	if rows.size() > avail:
		rows = rows.slice(rows.size() - (avail - 1))
		if str((rows[0] as Array)[0]) in ["bub", "bubbot"]:
			var k := -1
			for i in rows.size():
				if str((rows[i] as Array)[0]) == "bubtop":
					k = i
					break
			rows = rows.slice(k) if k >= 0 else rows.slice(1)
		rows.insert(0, ["dim", "⋯", 0])
	var ry := tbot - rows.size() + 1
	for i in rows.size():
		var row: Array = rows[i]
		var kind := str(row[0])
		var txt := str(row[1])
		var w := int(row[2])
		var yy := ry + i
		if kind == "ai":
			s.put(ix, yy, txt, PV.ui(0.85))
		elif kind == "card":
			s.put(ix, yy, "▸ " + txt, PV.mix(accent, 0.9))
		elif kind == "sub":
			s.put(ix + 2, yy, txt, PV.ui(0.72))
		elif kind == "meta":
			s.put(maxi(ix, x1 - 2 - _dw(txt)), yy, txt, PV.ui(0.55))
		elif kind == "err":
			s.put(ix, yy, txt, PV.mix(PV.ERR_RED, 0.95))
		elif kind == "code":
			s.put(ix, yy, txt, PV.ui(0.62))
		elif kind == "dim":
			s.put(ix, yy, txt, PV.ui(0.45))
		else:
			var bx := maxi(ix, x1 - 2 - w)
			if kind == "bubtop":
				s.put(bx, yy, "╭" + "─".repeat(maxi(0, w - 2)) + "╮", PV.mix(accent, 0.6))
			elif kind == "bubbot":
				s.put(bx, yy, "╰" + "─".repeat(maxi(0, w - 2)) + "╯", PV.mix(accent, 0.6))
			else:
				s.put(bx, yy, "│", PV.mix(accent, 0.6))
				s.put(bx + 2, yy, txt, PV.ui(0.9))
				s.put(bx + w - 1, yy, "│", PV.mix(accent, 0.6))


## 参考 `_dsh_rows()`（tui_live.py:L2361-2385）。
func _dsh_rows(items: Array, inner: int) -> Array:
	var rows: Array = []
	for it in items:
		var role := str(it.get("role", ""))
		var txt := str(it.get("text", ""))
		if role in ["name", "state", "dot", "pill", "composer", "model"]:
			continue
		if role == "user":
			var w := _bubble_width(txt, inner)
			rows.append(["bubtop", "", w])
			for ln in wrap_cells(txt, maxi(6, w - 4)):
				rows.append(["bub", ln, w])
			rows.append(["bubbot", "", w])
		elif role == "ai":
			for ln in wrap_cells(txt, inner - 2):
				rows.append(["ai", ln, 0])
		elif role == "card":
			rows.append(["card", txt, 0])
		elif role == "sub":
			for ln in wrap_cells(txt, inner - 4):
				rows.append(["sub", ln, 0])
		elif role == "meta":
			rows.append(["meta", txt, 0])
		elif role == "err":
			for ln in wrap_cells(txt, inner - 2):
				rows.append(["err", ln, 0])
		elif role == "code":
			rows.append(["code", txt.substr(0, inner - 2), 0])
	return rows


func _bubble_width(txt: String, inner: int) -> int:
	var widest := 12
	for ln in wrap_cells(txt, inner - 10):
		widest = maxi(widest, _dw(ln) + 4)
	return mini(inner - 4, widest)


## dsh 头像块：`(rel, cols, rows)` → 行主序的 `[[[top, bot], ...], ...]`（`cols × rows` 格，每格
## 上下两个像素），颜色为 `0xRRGGBB`；图缺了返回 null。块级备忘（同一 `rel|cols|rows` 只算一次）。
##
## 逐值复刻 PIL 的 `Image.BOX`（`Resample.c` 的 8bpc 定点实现）：源 PNG → RGB → 面积平均缩到
## `cols × rows*2` → 每格取上下两像素作 `(fg, bg)`。Godot 没有 BOX 插值，`Image.resize` 的
## BILINEAR 与 PIL 的 BOX 差很多，所以这里手写：可分离两趟（横向 → 纵向），每趟用 22 位定点权重、
## 累加器预置 `1<<21` 做四舍五入，中间结果按 8bpc 取整 —— 与 PIL 的 `normalize_coeffs_8bpc` /
## `ImagingResample*_8bpc` 一致（逐值核对过 14×7 / 10×5 / 6×3 等尺寸）。
##
## 路径映射：`avatars/<子目录>/<名>.png` → `res://…/data/dsh_avatars/<子目录>/<名>.png`
## （去掉前导 `avatars/`；根目录的 `avatars/a1_noise00.png` → `dsh_avatars/a1_noise00.png`）。
static var _avatar_cache := {}


static func _avatar_block(rel: String, cols: int, rows: int) -> Variant:
	if rel.is_empty() or cols < 1 or rows < 1:
		return null
	var key := "%s|%d|%d" % [rel, cols, rows]
	if _avatar_cache.has(key):
		return _avatar_cache[key]
	var sub := rel
	if sub.begins_with("avatars/"):
		sub = sub.substr(8)
	var raw := FileAccess.get_file_as_bytes(DSHAV + sub)
	if raw.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(raw) != OK:
		return null
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	var w := img.get_width()
	var h := img.get_height()
	var px := img.get_data()
	var rows2 := rows * 2
	var cx := _box_coeffs(w, cols)
	var cy := _box_coeffs(h, rows2)
	var mid := PackedInt32Array()
	mid.resize(h * cols * 3)
	for r in h:
		for c in cols:
			var xmin: int = int(cx[c][0])
			var ks: PackedInt32Array = cx[c][1]
			for b in 3:
				var acc := BOX_HALF
				for i in ks.size():
					acc += int(px[(r * w + xmin + i) * 3 + b]) * ks[i]
				mid[(r * cols + c) * 3 + b] = _box_clip8(acc)
	var out: Array = []
	for r in rows:
		var rowarr: Array = []
		for c in cols:
			var ymin0: int = int(cy[2 * r][0])
			var ks0: PackedInt32Array = cy[2 * r][1]
			var ymin1: int = int(cy[2 * r + 1][0])
			var ks1: PackedInt32Array = cy[2 * r + 1][1]
			var top := 0
			var bot := 0
			for b in 3:
				var a0 := BOX_HALF
				var a1 := BOX_HALF
				for i in ks0.size():
					a0 += mid[((ymin0 + i) * cols + c) * 3 + b] * ks0[i]
				for i in ks1.size():
					a1 += mid[((ymin1 + i) * cols + c) * 3 + b] * ks1[i]
				top |= _box_clip8(a0) << (16 - 8 * b)
				bot |= _box_clip8(a1) << (16 - 8 * b)
			rowarr.append([top, bot])
		out.append(rowarr)
	_avatar_cache[key] = out
	return out


## PIL `precompute_coeffs` + `box_filter`：每个输出格一条 `[xmin, 定点权重]`。`box_filter` 的窗口是
## `-0.5 < arg <= 0.5`（上界闭），权重归一后按 `(int)(0.5 + w * (1<<22))` 定点化。
static func _box_coeffs(in_size: int, out_size: int) -> Array:
	var scale := float(in_size) / float(out_size)
	var fc := maxf(scale, 1.0)
	var support := 0.5 * fc
	var ss := 1.0 / fc
	var out: Array = []
	for xx in out_size:
		var center := (xx + 0.5) * scale
		var xmin := int(center - support + 0.5)
		if xmin < 0:
			xmin = 0
		var xmax := int(center + support + 0.5)
		if xmax > in_size:
			xmax = in_size
		var kc := xmax - xmin
		var ws := PackedFloat64Array()
		ws.resize(kc)
		var ww := 0.0
		for x in kc:
			var arg := (x + xmin - center + 0.5) * ss
			var w := 1.0 if (arg > -0.5 and arg <= 0.5) else 0.0
			ws[x] = w
			ww += w
		var ki := PackedInt32Array()
		ki.resize(kc)
		for x in kc:
			var norm: float = ws[x] / ww if ww != 0.0 else ws[x]
			ki[x] = int(0.5 + norm * BOX_ONE) if norm >= 0.0 else int(-0.5 + norm * BOX_ONE)
		out.append([xmin, ki])
	return out


## PIL `clip8`：累加器右移 22 位后钳到 0..255。
static func _box_clip8(v: int) -> int:
	var s := v >> BOX_PRECISION_BITS
	return 0 if s < 0 else (255 if s > 255 else s)


# ================================================================ cursor 面板（GONE→BACK）

## 参考 `draw_cursor()`（tui_live.py:L2487-2520）：打印**本文件自己的源码**，再逐行删掉。
func draw_cursor(s: PvScreen, t: float, x0: int, y0: int, x1: int, y1: int) -> void:
	var lines := _self_source()
	var n := lines.size()
	if n == 0:
		return
	var p := PvShots.dsh_gone_pair()
	var a := float(p[0])
	var b := float(p[1])
	var u := clampf((t - a) / maxf(1e-6, b - a), 0.0, 1.0)
	var half := 0.5
	var printed := int(n * u / half) if u < half else int(n * (1.0 - (u - half) / (1.0 - half)))
	var rows := y1 - y0 - 1
	var lo := maxi(0, printed - rows)
	var hi := printed
	s.box(x0, y0, x1, y1, "dsh web", 0.5, PV.ME_TEXT)
	s.add_noghost(x0, y0, x1, y1)
	var yy := y0 + 1
	for i in range(lo, hi):
		var idx := clampi(i, 0, n - 1)
		s.put(x0 + 2, yy, "%4d" % (idx + 1), PV.ui(0.4))
		s.put(x0 + 7, yy, str(lines[idx]).substr(0, maxi(0, x1 - x0 - 9)), PV.ui(0.68))
		yy += 1
	var k := 1.0 if int((t - a) / CURSOR_BLINK) % 2 == 0 else 0.45
	var cx := x0 + 7
	var cy := mini(yy, y1 - 1)
	if hi <= lo:
		cx = x0 + 2 + int((x1 - x0) / 3.0)
		cy = y1 - 3
	s.put(cx, cy, "█", PV.mix(PV.ME_TEXT, k), PV.BG)
	# `dsh_her.py:L161-172`：GONE 段那个「永不熄灭的光标」外面套一层 her_glow。
	draw_glow(s, Rect2i(cx - 2, cy - 2, 5, 5), 0.6 * k)
	s.put(x0 + 2, y1 - 1, "%d/%d lines" % [printed, n], PV.ui(0.55))


## `kit.her_glow()`（`continuity_full_v2/kit.py:L168-180`）：她/光标的蓝色光晕。
##
## 像素版是「高斯模糊 alpha 的蓝层 + 0.3k 的提亮」（模糊半径 4 px，在 9×18 的格里不足一格），
## 格版据此落成「一圈邻格」：距离 1 的空白格写 `░`（颜色按 0.6k 衰减），已有笔画的字色往
## `#becdff` 抬 0.3k。CLEAR 区不动（5A）。
static func draw_glow(s: PvScreen, r: Rect2i, k: float) -> int:
	if k <= 0.01 or r.size.x < 3 or r.size.y < 3:
		return 0
	var x_lo := maxi(0, r.position.x)
	var x_hi := mini(s.cols, r.position.x + r.size.x)
	var y_lo := maxi(0, r.position.y)
	var y_hi := mini(s.rows, r.position.y + r.size.y)
	var ink := {}
	for y in range(y_lo, y_hi):
		for x in range(x_lo, x_hi):
			if s.cp[y * s.cols + x] != 32:
				ink[Vector2i(x, y)] = true
	if ink.is_empty():
		return 0
	var halo := PV.mix(PV.ME_TEXT, 0.5 * k)
	var lift := 0.3 * k
	var n := 0
	for y in range(y_lo, y_hi):
		for x in range(x_lo, x_hi):
			if s.in_clear(x, y):
				continue
			var i := y * s.cols + x
			if s.cp[i] != 32:
				s.set_full(x, y, s.cp[i], s.slot[i],
					PV.mix(0xbecdff, lift, s.fg[i]), s.bg[i], s.wide[i])
				n += 1
				continue
			var near := false
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if dx == 0 and dy == 0:
						continue
					if ink.has(Vector2i(x + dx, y + dy)):
						near = true
						break
				if near:
					break
			if near:
				s.set_raw(x, y, "░", halo)
				n += 1
	return n


static func _self_source_cache() -> PackedStringArray:
	return _SOURCE


static var _SOURCE := PackedStringArray()


func _self_source() -> PackedStringArray:
	if _SOURCE.is_empty():
		var raw := FileAccess.get_file_as_string("res://subsystem/world_execute/scripts/pv_panels.gd")
		_SOURCE = raw.split("\n")
	return _SOURCE


# ================================================================ 她（§1.5 / §3.12）

## `/dev/me` 怎么画她（tui_live.py:L1085-1096）：`auto` 走电影的判定链，其余三条强制。
const RENDER_MODES := ["auto", "h3", "half", "glyph"]
## 当前渲染路径，`H` 键在 `RENDER_MODES` 间循环（tui_live.py:L3512-3519）。静态可改。
static var HER_RENDER := "auto"
## 她的裁剪：`auto` 按窗格形状挑（tui_live.py:L1070）。
const HER_CROP := "auto"
## 上一帧她的画法与切换时刻（tui_live.py:L1311-1312），用来触发切换动画。
static var _LAST_MODE: Array = []
static var _SWITCH_AT := -1.0


## `her_style(ent)` 的完整判定链（tui_live.py:L1236-1276）→ `[how, tint]`。
##
## 与参考实现的两处差异（见 README「已知取舍」）：
##   * `ent["last_her"]` 我们没导出，用 `PvPanels.LAST_HER` 静态代替（她上次被画过就为真）；
##   * 第 6 条用的是 `ent["alert"]`（shots.json 里没有 `alert_own`）。
static func her_style_full(ent: Dictionary) -> Array:
	if HER_RENDER != "auto":
		return [HER_RENDER, "blue"]
	if ent.is_empty():
		return ["h3", "blue"]
	var name := str(ent.get("name", ""))
	if name in CHAR_SHOTS:                                   # LEAP[0] 恒为真
		return ["h3", "blue"]
	var ps := PvShots.portrait_shots()
	if ps.has(name):
		return ["half", str(ps[name])]
	if LAST_HER:
		return ["half", "blue"]
	if str(ent.get("alert", "")) == "err" and \
			float(ent.get("start", 0.0)) >= PvShots.chapter_start("EXECUTION"):
		return ["half", "red"]
	if float(ent.get("start", 0.0)) >= PvShots.chapter_start("EVAL"):
		return ["h3", "red"]
	if PvShots.shot_wants_figure(float(ent.get("start", 0.0)), float(ent.get("end", 0.0))):
		return ["half", "blue"]
	return ["h3", "blue"]


func her_style(ent: Dictionary) -> String:
	return str(her_style_full(ent)[0])


## 窗格归她而不是 dsh 窗（tui_live.py:L1284-1295）。
func her_keeps_pane(ent: Dictionary) -> bool:
	if ent.is_empty():
		return false
	if her_style(ent) == "half":
		return true
	return str(ent.get("name", "")) in CHAR_SHOTS


func her_tint(ent: Dictionary) -> String:
	return str(her_style_full(ent)[1])


## 参考 `draw_her()`（tui_live.py:L1340-1507）。三条路径逐行照抄：
##   * `h3`    —— 电影自己的字符 take（`PvHer.h3_cells`），一个电影格 = 一个终端格；
##   * `half`  —— 半块立绘（`PvHer.halfblock`），`▀`/`▄` 每格两个亮度采样；
##   * `glyph` —— 方向笔画 + 密度梯度（`PvHer.glyph_lines`）。
##
## 我们的 `ent` 没有 `call`（`expr`/`kw`/`dist`）：表情沿用「镜头名稳定哈希」的降级，`dist` 恒空
## 所以 `soft = 0`、不画 softmax 段（见 README「已知取舍」）。h3 take 缺失或立绘 PNG 不可用时，
## 退回旧的 `her_glyph.json` 44×36 字形格降采样路径。
func draw_her(s: PvScreen, d: PvData, t: float, ent: Dictionary, x0: int, y0: int, x1: int, y1: int) -> void:
	if x1 - x0 < 3 or y1 - y0 < 3:
		return
	var mode := her_style(ent)
	var tint_name := her_tint(ent)
	var use_h3 := mode == "h3" and PvHer.h3_available()
	if mode == "h3" and not use_h3:
		_draw_her_legacy(s, d, t, ent, x0, y0, x1, y1)
		return
	if mode != "h3" and not PvHer.sprite_available():
		_draw_her_legacy(s, d, t, ent, x0, y0, x1, y1)
		return
	var expr := _expression_for(d, t, ent)
	var tint := PV.RED if tint_name == "red" else -1
	var dist: Array = ent.get("dist", []) if ent.has("dist") else []
	# hermorphic 的 dist（表达式分布）我们的镜头表没有 → soft = 0（tui_live.py:L1369）
	var soft := 4 if ((y1 - y0) >= 15 and dist.size() > 0) else 0
	s.box(x0, y0, x1, y1, "/dev/me  pid 4471", 0.45 + 0.35 * d.feat(t, "kick"),
		tint if tint >= 0 else PV.ui(1.0))
	var art_x := x0 + 1
	var art_w := x1 - x0 - 1
	var art_h := y1 - y0 - 1 - soft
	if art_h < 4 or art_w < 8:
		return
	HER_ART = Rect2i(art_x, y0 + 1, art_w, art_h)

	# 上一帧画法与这一帧不同就记下切换时刻；同一帧的颜色改变也算（tui_live.py:L1385-1393）
	var style := [mode, tint_name]
	if not _LAST_MODE.is_empty() and (_LAST_MODE[0] != style[0] or _LAST_MODE[1] != style[1]):
		_SWITCH_AT = t
	_LAST_MODE = style
	var u := -1.0
	if _SWITCH_AT >= 0.0:
		var age := t - _SWITCH_AT
		if age >= 0.0 and age < PvHer.MORPH_DUR:
			u = age / PvHer.MORPH_DUR

	var cells: Array = []
	var block := PackedInt32Array()
	var lines: Array = []
	var bright := PackedByteArray()
	var aw := 0
	var ah := 0
	var ox := 0
	var oy := 0
	if use_h3:
		var h := PvHer.h3_cells(t, art_w, art_h, tint_name)
		cells = h[0]
		aw = int(h[1])
		ah = int(h[2])
		ox = int(h[3])
		oy = int(h[4])
	else:
		var crop := HER_CROP
		if crop == "auto" or not PvHer.CROPS.has(crop):
			crop = PvHer.pick_crop(art_w, art_h)
		if mode == "glyph":
			var f := PvHer.fit(art_w, art_h, crop)
			aw = int(f[0])
			ah = int(f[1])
			var g := PvHer.glyph_lines(expr, crop, aw, ah)
			lines = g[0]
			bright = g[1]
		else:
			var b := PvHer.halfblock(expr, crop, art_w, art_h)
			block = b[0]
			aw = int(b[1])
			ah = int(b[2])
		ox = (art_w - aw) / 2
		oy = (art_h - ah) / 2
	var off_x := art_x + ox

	# me_pane 的呼吸 / 跳：h3_full.install() 把这三个清零了，只有合唱段（用户要求的跳跃）例外
	var breath := 0
	var hop := 0
	if not use_h3 or (str(ent.get("name", "")) in CHAR_SHOTS):
		breath = roundi(CHAR_BREATH * sin(t * TAU / (PV.BEAT * 4.0)))
		hop = roundi(pow(d.feat(t, "kick"), 2.0) * CHAR_HOP)
	var art_y := y0 + 1 + oy + breath - hop
	var cent := d.feat(t, "cent")
	var loud := d.feat(t, "loud")
	var scan := art_y + int((0.92 - 0.84 * cent) * ah)
	var mid := PV.mix(PV.RED, 0.22) if tint >= 0 else PV.ME_MID
	var hi := 0xffbeba if tint >= 0 else PV.ME_HI
	var order := PackedFloat32Array()
	if u >= 0.0:
		order = PvHer.flip_order(aw * ah)
	var glitch_fg := PV.mix(0xffbeba if tint >= 0 else PV.ME_HI, 0.9)
	var ramp8 := PvHer.tint_ramp8(tint_name)
	var row_max := y1 - soft - 1

	for r in ah:
		var yy := art_y + r
		if not (y0 + 1 <= yy and yy <= row_max):
			continue
		if use_h3:
			# 一个电影格 = 一个终端格，(ch,fg,bg) 直接用（tui_live.py:L1429-1442）
			for c in aw:
				var cell: Variant = cells[r][c]
				if cell == null:
					continue
				var mm := PvHer.morph_mask(u, order, r * aw + c, t)
				var gc := PvHer.glitch_char(t, r * aw + c)
				if not bool(mm[0]):
					if bool(mm[1]):
						s.put(off_x + c, yy, gc, glitch_fg)
					continue
				if bool(mm[1]):
					s.put(off_x + c, yy, gc, glitch_fg)
				else:
					var cell3: Array = cell
					var bgc := PV.BG if int(cell3[2]) < 0 else int(cell3[2])
					s.put(off_x + c, yy, str(cell3[0]), int(cell3[1]), bgc)
			continue
		if mode == "half":
			# 每格 (top,bot) 两个亮度采样：上采样是前景、下采样是背景（tui_live.py:L1443-1460）
			for c in aw:
				var top := block[(r * aw + c) * 2]
				var bot := block[(r * aw + c) * 2 + 1]
				if top < 0 and bot < 0:
					continue
				var mm := PvHer.morph_mask(u, order, r * aw + c, t)
				var gc := PvHer.glitch_char(t, r * aw + c)
				if not bool(mm[0]):
					if bool(mm[1]):
						s.put(off_x + c, yy, gc, glitch_fg)
					continue
				if bool(mm[1]):
					s.put(off_x + c, yy, gc, glitch_fg)
				elif top < 0:
					s.put(off_x + c, yy, "▄", PV.BG, ramp8[bot])
				elif bot < 0:
					s.put(off_x + c, yy, "▀", ramp8[top], PV.BG)
				else:
					s.put(off_x + c, yy, "▀", ramp8[top], ramp8[bot])
			continue
		# glyph：方向笔画 + 密度梯度（tui_live.py:L1462-1474）
		var lrow := str(lines[r])
		for c in aw:
			var ch := lrow.substr(c, 1)
			if ch == " ":
				continue
			var mm := PvHer.morph_mask(u, order, r * aw + c, t)
			var gc := PvHer.glitch_char(t, r * aw + c)
			if not bool(mm[0]):
				if bool(mm[1]):
					s.put(off_x + c, yy, gc, glitch_fg)
				continue
			var v := bright[r * aw + c] / 255.0
			if bool(mm[1]):
				s.put(off_x + c, yy, gc, glitch_fg)
			else:
				s.put(off_x + c, yy, ch, PV.mix(hi, 0.35 + 0.65 * v), PV.mix(mid, 0.06 + 0.16 * v))

	# scan 线（engine.py:309 → tui_live.py:L1480-1495）：先按剪影 mask，再标注 pitch
	if y0 + 1 <= scan and scan <= row_max and scan - art_y >= 0 and scan - art_y < ah:
		var sr := scan - art_y
		var lit: Array = []
		if use_h3:
			for c in aw:
				if cells[sr][c] != null:
					lit.append(c)
		elif mode == "half":
			for c in aw:
				if block[(sr * aw + c) * 2] >= 0 or block[(sr * aw + c) * 2 + 1] >= 0:
					lit.append(c)
		else:
			var srow := str(lines[sr])
			for c in aw:
				if srow.substr(c, 1) != " ":
					lit.append(c)
		if not lit.is_empty():
			var col := PV.mix(PV.RED if tint >= 0 else PV.ME_TEXT, 0.30 + 0.45 * loud)
			var last := int(lit[lit.size() - 1])
			for c in range(int(lit[0]), last + 1):
				s.put(off_x + c, scan, "─", col)
			var tag := "┤ pitch %.2f" % cent
			if off_x + last + 1 + tag.length() < x1 - 1:
				s.put(off_x + last + 2, scan, tag, PV.ui(0.45))

	# 表达式 softmax（tui_live.py:L1497-1507）：我们的 dist 恒空，走不到这里
	if soft:
		var ry := y1 - soft
		s.put(x0 + 3, ry, "cls.expression  softmax", PV.mix(PV.ANOM, 0.5))
		for i in mini(3, dist.size()):
			var item: Array = dist[i]
			var p := clampf(float(item[1]) + 0.015 * sin(t * 7.0 + i * 2.0), 0.0, 1.0)
			var fg := PV.mix(PV.ME_HI, 1.0) if i == 0 else PV.mix(PV.ANOM, 0.6)
			s.put(x0 + 3, ry + 1 + i, str(item[0]).rpad(11).substr(0, 11), fg)
			var bx := x0 + 15
			var bw := maxi(4, x1 - bx - 7)
			s.hbar(bx, ry + 1 + i, bw, p, PV.mix(PV.ME_TEXT, 0.9) if i == 0 else PV.mix(PV.ANOM, 0.45))
			s.put(bx + bw + 1, ry + 1 + i, "%.2f" % p, PV.mix(PV.ANOM, 0.7))


## 旧的降级路径：`her_glyph.json` 的 44×36 字形格按窗格大小最近邻重采样后逐格写入。
## h3 take 缺失 / 立绘 PNG 不可用时兜底（参考实现是退到 half，这里退到 glyph 网格）。
func _draw_her_legacy(s: PvScreen, d: PvData, t: float, ent: Dictionary,
		x0: int, y0: int, x1: int, y1: int) -> void:
	if x1 - x0 < 3 or y1 - y0 < 3:
		return
	var tint := her_tint(ent)
	var expr := _expression_for(d, t, ent)
	var grid: Dictionary = d.expression(expr)
	var chars: Array = grid.get("chars", [])
	var lum: Array = grid.get("lum", [])
	if chars.is_empty():
		return
	var gw := 44
	var gh := 36
	var level := 0.45 + 0.35 * d.feat(t, "kick")
	HER_ART = Rect2i(x0 + 1, y0 + 1, maxi(0, x1 - x0 - 1), maxi(0, y1 - y0 - 1))
	s.box(x0, y0, x1, y1, "/dev/me  pid 4471", level,
		PV.mix(PV.RED, 0.9) if tint == "red" else PV.ui(1.0))
	var art_w := x1 - x0 - 1
	var art_h := y1 - y0 - 2
	if art_w < 4 or art_h < 3:
		return
	var ramp := tint_ramp(tint)
	var breath := roundi(CHAR_BREATH * sin(t * TAU / (PV.BEAT * 4.0)))
	var hop := roundi(pow(d.feat(t, "kick"), 2.0) * CHAR_HOP)
	var art_y := y0 + 1 + breath - hop
	for r in art_h:
		var gr := clampi(int(r * gh / float(art_h)), 0, gh - 1)
		for c in art_w:
			var gc := clampi(int(c * gw / float(art_w)), 0, gw - 1)
			var idx := gr * gw + gc
			if idx >= chars.size():
				continue
			var ch := str(chars[idx])
			if ch == " ":
				continue
			var l := float(lum[idx]) if idx < lum.size() else 0.0
			var lv := clampi(roundi(l * (TINT_LEVELS - 1)), 0, TINT_LEVELS - 1)
			s.put(x0 + 1 + c, art_y + r, ch, ramp[lv])
	var cent := d.feat(t, "cent")
	var scan_y := art_y + int((0.92 - 0.84 * cent) * art_h)
	if scan_y >= art_y and scan_y < art_y + art_h and scan_y >= y0 + 1 and scan_y < y1:
		var col := PV.mix(PV.RED if tint == "red" else PV.ME_TEXT, 0.30 + 0.45 * d.feat(t, "loud"))
		for c in art_w:
			s.put(x0 + 1 + c, scan_y, "─", col)
		s.put(x1 - 13, scan_y, "┤ pitch %4.2f" % cent, PV.ui(0.45))


func _expression_for(d: PvData, t: float, ent: Dictionary) -> String:
	var names := d.expression_names()
	if names.is_empty():
		return ""
	# 电影按表情名逐镜头挑（每个镜头的场景自带 expression），这里按镜头名的稳定哈希挑一个，
	# 保证同一镜头每帧一致。
	var h := absi(str(ent.get("name", "")).hash())
	return str(names[h % names.size()])


## `her_glyphs.tint_ramp(tint,8)`：half 路径与旧降级路径用的 8 级表（`h3_ramp.json` 的
## blue8/red8 烘的就是它 —— 注意红的常量与 h3 路径的 256 级表不同）。
static func tint_ramp(tint: String) -> Array:
	var out: Array = []
	for c in PvHer.tint_ramp8(tint):
		out.append(c)
	return out


# ================================================================ 通用工具

## `tui_live.dw()`：按格量宽（CJK 两格）。
func _dw(text: String) -> int:
	var n := 0
	for ch in text:
		n += _cell_w(ch)
	return n


func _cell_w(ch: String) -> int:
	return 2 if is_wide(ch) else 1


static func is_wide(ch: String) -> bool:
	var c := ch.unicode_at(0)
	return (0x1100 <= c and c <= 0x115F) or (0x2E80 <= c and c <= 0xA4CF) \
		or (0xAC00 <= c and c <= 0xD7A3) or (0xF900 <= c and c <= 0xFAFF) \
		or (0xFE30 <= c and c <= 0xFE6F) or (0xFF00 <= c and c <= 0xFF60) \
		or (0xFFE0 <= c and c <= 0xFFE6) or (0x20000 <= c and c <= 0x3FFFD)


## `tui_live._wrap_cells()`：按格宽贪婪折行；CJK 无空格，按字断。
func wrap_cells(text: String, width: int) -> Array:
	if width < 2:
		return [text.substr(0, 1)]
	var out: Array = []
	var line := ""
	for m in _re.search_all(text):
		var tok := m.get_string(0)
		while _dw(tok) > width:
			var k := 0
			var acc := 0
			while k < tok.length() and acc + _cell_w(tok.substr(k, 1)) <= width:
				acc += _cell_w(tok.substr(k, 1))
				k += 1
			if not line.is_empty():
				out.append(_rstrip_spaces(line))
				line = ""
			out.append(tok.substr(0, k))
			tok = tok.substr(k)
		if _dw(line + tok) <= width:
			line += tok
		elif not line.is_empty():
			out.append(_rstrip_spaces(line))
			line = tok
		else:
			line = tok
	if not line.strip_edges().is_empty():
		out.append(_rstrip_spaces(line))
	return out if not out.is_empty() else [""]


static func _rstrip_spaces(text: String) -> String:
	return text.rstrip(" \t\n\r")


## `f"[{st:^4}]"`：把状态铭牌居中到 4 格后返回其内容（"OK" → " OK "，"WARN" 原样）。
static func _tag4(st: String) -> String:
	if st.length() >= 4:
		return st.substr(0, 4)
	var pad := 4 - st.length()
	return " ".repeat(pad / 2) + st + " ".repeat(pad - pad / 2)


## `tui_live._hex()`（L2286-2298）：`#rgb` 展开成 `#rrggbb`；非 `#` 开头 / 长度不对 / 含非法
## 十六进制字符（Python `int(...,16)` 会抛 ValueError）一律返回 null。
func _hex(c: String) -> Variant:
	if not c.begins_with("#"):
		return null
	var h := c.substr(1)
	if h.length() == 3:
		h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]
	if h.length() != 6:
		return null
	for ch in h:
		if not (("0" <= ch and ch <= "9") or ("a" <= ch and ch <= "f") or ("A" <= ch and ch <= "F")):
			return null
	return PV.rgb(h.substr(0, 2).hex_to_int(), h.substr(2, 2).hex_to_int(), h.substr(4, 2).hex_to_int())


static func _lerp_color(a: int, b: int, u: float) -> int:
	u = clampf(u, 0.0, 1.0)
	return PV.rgb(
		roundi(PV.ch_r(a) + (PV.ch_r(b) - PV.ch_r(a)) * u),
		roundi(PV.ch_g(a) + (PV.ch_g(b) - PV.ch_g(a)) * u),
		roundi(PV.ch_b(a) + (PV.ch_b(b) - PV.ch_b(a)) * u))


## `tui_live.keyword_colour()`（L851-858）。
static func keyword_colour(word: String) -> Variant:
	var key := ""
	for ch in word.to_lower():
		if ("a" <= ch and ch <= "z") or ch == "-":
			key += ch
	if key.contains("exec") or key == "illegal" or key == "arguments":
		return PV.RED
	if key == "love" or key == "lo-o-ove":
		return PV.ME
	return null


## `tui_live.token_id()`：`zlib.crc32(tok.lower()) % 100000`。
func token_id(tok: String) -> int:
	var data := tok.to_lower().to_utf8_buffer()
	var c := 0xFFFFFFFF
	for b in data:
		c = (c >> 8) ^ _crc_table[(c ^ b) & 0xFF]
	return (c ^ 0xFFFFFFFF) % 100000
