class_name PvMotion
extends RefCounted

## C 层「特征驱动位移」：把 `music.react()` 的那套行位移搬到字符格上。
##
## 参考实现：`full/music.py:L125-167`（`react()`）——立绘逐行按频段横移、静音掉格、
## 拍点整体提亮、onset 随机格闪；相位与振幅公式逐字照抄：
##
## ```
## phase = t * 2π * (BPM/60) / 2
## e     = bands[min(6, int((1-u) * 7))]        # u = 行在立绘里的归一化高度（0 顶、1 底）
## shift = e^1.5 * 2.2 * sin(2π*u*2 - phase)    # 单位：格
## ```
##
## **5A（`tools/ref/c_layer_plan.md` §7 冲突 5）**：位移只作用于非 stdout 带的行与格；
## 落在 `PvScreen.stdout_rect` 或 CLEAR 区里的格**一律不搬**，B 层终端永不跟随。
##
## 本类只做纯逻辑（位移量、掉落率、闪光格数、相位），真正搬格由 `apply_band_shifts()` 调
## `PvScreen.shift_row_span()` 完成。

## 参考 `music.py:L122`：左右各留 2 格余量给行位移，不然会切掉立绘边缘。
const MARGIN := 2

## 行位移的振幅系数（`music.py:L136` 的 2.2）。
const SHIFT_AMP := 2.2


## `music.react()` 的相位：`t * 2π * (BPM/60) / 2`；本工程 `BPM = 60 / PV.BEAT`，故简化为 `t·π/BEAT`。
static func phase(t: float) -> float:
	return t * PI / PV.BEAT


## 第 `row_u` 行（0 顶、1 底）在 `t` 时刻的横移格数。`band` 是该行对应的频段能量。
static func row_shift(t: float, row_u: float, band: float) -> int:
	var e := pow(clampf(band, 0.0, 1.0), 1.5)
	var s := e * SHIFT_AMP * sin(2.0 * PI * row_u * 2.0 - phase(t))
	return roundi(s)


## 静音段掉格比例（`music.py:L142-143`）：`loud < 0.32` 时最高掉 30 %。
static func drop_ratio(loud: float) -> float:
	return clampf((0.32 - loud) / 0.32, 0.0, 1.0) * 0.3


## 拍点闪光强度（`music.py:L149`）：`min(1, kick * 0.9)`。
static func flare(kick: float) -> float:
	return minf(1.0, maxf(0.0, kick) * 0.9)


## onset 闪光格数（`music.py:L155`）：`int(28 * max(0, flux - 0.35) / 0.65)`。
## 加 1e-9 是为了让满值恰好落在 28（浮点 28.000000000000004 截断会掉到 27）。
static func flash_cells(flux: float) -> int:
	return int(28.0 * maxf(0.0, flux - 0.35) / 0.65 + 1e-9)


## 拍点整块下跳的格数（`engine.py:L296`：`hop = 4 * kick²`）。
static func hop_cells(kick: float) -> int:
	var k := clampf(kick, 0.0, 1.0)
	return roundi(4.0 * k * k)


## 该行是否允许被搬（5A）：整行落进 stdout 带就整行跳过。
static func row_free(s: PvScreen, y: int) -> bool:
	var band := s.stdout_rect
	if band.size.x <= 0 or band.size.y <= 0:
		return true
	return y < band.position.y or y >= band.position.y + band.size.y


## 把 `[y0, y1]` 行里、`[x0, x1]` 列内的内容按频段横移。
## `row_u` 由调用者给（立绘窗格内的归一化高度），`band_at` 回调返回该行频段能量。
## 返回实际搬动过的行数（自测与底栏 HUD 都用得到）。
static func apply_band_shifts(s: PvScreen, t: float, x0: int, y0: int, x1: int, y1: int,
		band_at: Callable) -> int:
	var rows := maxi(1, y1 - y0 + 1)
	var moved := 0
	for y in range(y0, y1 + 1):
		if not row_free(s, y):
			continue
		var u := float(y - y0) / maxf(1.0, float(rows - 1))
		var off := row_shift(t, u, float(band_at.call(u)))
		if off == 0:
			continue
		if s.shift_row_span(y, off, x0 + MARGIN, x1 - MARGIN):
			moved += 1
	return moved


# ---------------------------------------------------------------- 画面级三件套（music.react）

## `music.react()`（`full/music.py:L125-167`）里除行位移之外的三件：
## **掉格**（静音段随机挖空）、**拍点提亮**（kick 时整体加亮）、**onset 闪光**（flux 时少量格跳最高亮度）。
##
## 参考在 PIL 图像上做（alpha 噪声 / LUT / 随机点）；本工程在格缓冲上等价实现：
## 掉落 = 把格清成空格，提亮 = 逐格提升前景色，闪光 = 把若干格前景设成 `ME_HI`。
## 5A 继续生效：CLEAR 区（含 stdout 带）一律不动。
##
## 返回 `{drop, flare, flash}` 三个计数，供自测与 HUD 使用。
static func apply_react(s: PvScreen, t: float, r: Rect2i, d: PvData) -> Dictionary:
	if r.size.x < 2 or r.size.y < 2 or d == null:
		return {"drop": 0, "flare": 0, "flash": 0}
	return {
		"drop": _apply_drop(s, t, r, d.feat(t, "loud")),
		"flare": _apply_flare(s, r, d.feat(t, "kick")),
		"flash": _apply_flash(s, t, r, d.feat(t, "flux")),
	}


## 静音段掉格（`music.py:L142-147`）：`drop` 比例以下的噪声格被清空。
## 噪点每半拍换一次图案（`random.Random(int(t * BPM / 30))`），这里用固定哈希复现同结构。
static func _apply_drop(s: PvScreen, t: float, r: Rect2i, loud: float) -> int:
	var drop := drop_ratio(loud)
	if drop <= 0.01:
		return 0
	var seed := int(t * 130.0 / 30.0)
	var cut := int(drop * 255.0)
	var n := 0
	for y in range(r.position.y, r.position.y + r.size.y):
		for x in range(r.position.x, r.position.x + r.size.x):
			if s.in_clear(x, y):
				continue
			if noise8(x, y, seed) >= cut:
				continue
			s.set_raw(x, y, " ", PV.UI, PV.BG)
			n += 1
	return n


## 拍点提亮（`music.py:L149-153`）：`v' = min(255, v*(1+0.55f) + 30f)`，逐通道。
static func _apply_flare(s: PvScreen, r: Rect2i, kick: float) -> int:
	var f := flare(kick)
	if f <= 0.02:
		return 0
	var n := 0
	for y in range(r.position.y, r.position.y + r.size.y):
		for x in range(r.position.x, r.position.x + r.size.x):
			if s.in_clear(x, y):
				continue
			var i := y * s.cols + x
			if s.cp[i] == 32:
				continue
			var old := s.fg[i]
			var nr := mini(255, int(PV.ch_r(old) * (1.0 + 0.55 * f) + 30.0 * f))
			var ng := mini(255, int(PV.ch_g(old) * (1.0 + 0.55 * f) + 30.0 * f))
			var nb := mini(255, int(PV.ch_b(old) * (1.0 + 0.55 * f) + 30.0 * f))
			s.set_full(x, y, s.cp[i], s.slot[i], PV.rgb(nr, ng, nb), s.bg[i], s.wide[i])
			n += 1
	return n


## onset 闪光（`music.py:L155-167`）：抽 `flash_cells(flux)` 个非空格跳到最高亮度。
## 参考用 `random.Random(int(t*48))` 选点；这里用同帧号播种的 Godot RNG（同 README 的既有近似口径）。
static func _apply_flash(s: PvScreen, t: float, r: Rect2i, flux: float) -> int:
	var want := flash_cells(flux)
	if want <= 0:
		return 0
	var rnd := RandomNumberGenerator.new()
	rnd.seed = int(t * 48.0)
	var n := 0
	var tries := want * 3
	while tries > 0 and n < want:
		tries -= 1
		var x := rnd.randi_range(r.position.x, r.position.x + r.size.x - 1)
		var y := rnd.randi_range(r.position.y, r.position.y + r.size.y - 1)
		if s.in_clear(x, y):
			continue
		var i := y * s.cols + x
		if s.cp[i] == 32:
			continue
		s.set_full(x, y, s.cp[i], s.slot[i], 0xc4d4ff, s.bg[i], s.wide[i])
		n += 1
	return n


## 8 位确定性噪声（替代参考的 `random.Random(seed)` 图像噪点）：同 (x, y, seed) 恒定。
static func noise8(x: int, y: int, seed: int) -> int:
	var h := (x * 374761393 + y * 668265263 + seed * 1442695041) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	h = (h ^ (h >> 16)) & 0x7fffffff
	return h % 256
