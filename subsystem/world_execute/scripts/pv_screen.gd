class_name PvScreen
extends RefCounted

## 字符格屏幕：`197 × 52` 个格子，每格 `(字符, 前景色, 背景色)`。
##
## 逐字段对照 `tui_live.Screen`（`tui_live.py:872-1065`，版式规范见 tools/ref/layout.md §4）：
##
##   * 每格存 `cp/slot/fg/bg/wide`；`slot` 是图集槽位，双宽字的右半格存 `slot+1`，
##     所以「双宽字占两格」这件事在渲染端是不存在的（图集烘焙时已切成左右两半）。
##   * `dim` 是**静态**亮度场（暗角 + 三行一暗的扫描线），只在 init/resize 时重算；
##     `put` 会按它压暗前景色，但落在 `CLEAR` 里的格子不吃暗角。
##   * `fg/bg` 都是 `0xRRGGBB` 整数，与 Python 的 RGB 三元组一一对应。
##   * 输出没有「差分渲染」这一步（那是终端带宽的顾虑）：每帧直接把三张格子纹理交给 shader。
##     所以本类**不含** `render_diff`，取而代之的是 `to_data()`。
##
## 三张输出纹理的字节，在 `_set_cell()` 里就地写入，因此每帧的 `to_data()` 没有额外开销。

const BLANK_CP := 32                    # ' '

var cols := 0
var rows := 0
var atlas: PvAtlas

var cp := PackedInt32Array()            # 字符码点（双宽右半为 0）
var slot := PackedInt32Array()          # 图集槽位
var fg := PackedInt32Array()            # 前景 0xRRGGBB（已吃暗角）
var bg := PackedInt32Array()
var wide := PackedByteArray()           # 1 = 双宽字的右半格
var dim := PackedFloat32Array()         # 静态暗角 + 扫描线，每格一个乘数

var prev_cp := PackedInt32Array()       # 上一帧的字符（`fx_trail` / `fx_cut` 用）
var prev_slot := PackedInt32Array()     # 上一帧的槽位（cut 的「旧画面」快照要连槽位一起还原）
var prev_fg := PackedInt32Array()
var prev_wide := PackedByteArray()

## 残影表：i = y*cols+x → [cp, fg, level]；`ghost_prev` 记录上一帧哪些格被残影占用。
var ghost := {}
var ghost_prev := PackedByteArray()
var ghost_cp := PackedInt32Array()
var ghost_fg := PackedInt32Array()
var ghost_lv := PackedFloat32Array()

## 三张 rect 表（§附录 2）：CLEAR = 可读区（不吃暗角、不参与 cut）；NOGHOST = 不许留残影。
var clear_rects: Array = []
var prev_clear_rects: Array = []
var noghost_rects: Array = []

## 面板层每帧写进来的「stdout 带」格区（含首含尾）：`x` / `y` 是左上格，`size` 是格数。
## B 层真终端用它把自己贴在同一条带上（见 world_execute.gd 的 `_sync_stream_rect()`）。
var stdout_rect := Rect2i()

var _span_n := -1
var _span_cache := {}

var _idx_bytes := PackedByteArray()
var _fg_bytes := PackedByteArray()
var _bg_bytes := PackedByteArray()


func _init(p_atlas: PvAtlas, p_cols: int, p_rows: int) -> void:
	atlas = p_atlas
	build(p_cols, p_rows)


func build(p_cols: int, p_rows: int) -> void:
	cols = p_cols
	rows = p_rows
	var n := cols * rows
	cp.resize(n)
	slot.resize(n)
	fg.resize(n)
	bg.resize(n)
	wide.resize(n)
	ghost_prev.resize(n)
	ghost_cp.resize(n)
	ghost_fg.resize(n)
	ghost_lv.resize(n)
	prev_cp.resize(n)
	prev_slot.resize(n)
	prev_fg.resize(n)
	prev_wide.resize(n)
	_idx_bytes.resize(n * 4)
	_fg_bytes.resize(n * 4)
	_bg_bytes.resize(n * 4)
	ghost.clear()
	for i in n:
		cp[i] = BLANK_CP
		slot[i] = 0
		fg[i] = PV.UI
		bg[i] = PV.BG
		wide[i] = 0
		ghost_prev[i] = 0
		ghost_cp[i] = 0
		ghost_fg[i] = 0
		ghost_lv[i] = 0.0
		_write_bytes(i, 0, PV.UI, PV.BG)
	_cut_snapshot()
	refresh_dim()
	_span_n = -1
	_span_cache = {}


## `resize`：整屏重建（丢失 prev/ghost），与 Python 侧语义一致。
func resize(p_cols: int, p_rows: int) -> void:
	build(p_cols, p_rows)


# ---------------------------------------------------------------- 暗角与扫描线（§4.7）

func refresh_dim() -> void:
	var n := cols * rows
	dim.resize(n)
	for i in n:
		dim[i] = 1.0
	if not (PV.FX["on"] and PV.FX["vig"]):
		return
	var cx := (cols - 1) / 2.0
	var cy := (rows - 1) / 2.0
	var hx := maxf(1.0, cols / 2.0)
	var hy := maxf(1.0, rows / 2.0)
	var lift := maxi(2, int(rows / 8.0))
	for y in rows:
		var k := 1.0 if y < rows - lift else maxf(0.25, 1.0 - (y - (rows - lift)) / float(lift))
		var scan := PV.SCAN_DIM if y % 3 == 2 else 1.0
		var dy := (y - cy) / hy
		for x in cols:
			var dx := (x - cx) / hx
			var v := minf(1.0, maxf(0.0, (dx * dx + dy * dy) - 0.35) * 0.55)
			dim[y * cols + x] = (1.0 - v * PV.VIG_FLOOR * k) * scan


# ---------------------------------------------------------------- 帧边界

func begin_frame(t: float) -> void:
	PV.NOW = t
	clear_rects.clear()
	noghost_rects.clear()
	_span_n = -1
	_span_cache = {}


## 收帧：把当前缓冲存进 prev（供 fx_trail 比对上一帧）。
func end_frame() -> void:
	prev_cp = cp.duplicate()
	prev_slot = slot.duplicate()
	prev_fg = fg.duplicate()
	prev_wide = wide.duplicate()


## fx_cut 需要的「上一帧整屏快照」由它替换（cut 的 old 帧）。
func _cut_snapshot() -> void:
	prev_cp = cp.duplicate()
	prev_slot = slot.duplicate()
	prev_fg = fg.duplicate()
	prev_wide = wide.duplicate()


# ---------------------------------------------------------------- rect 表

func add_clear(x0: int, y0: int, x1: int, y1: int) -> void:
	clear_rects.append([x0, y0, x1, y1])
	_span_n = -1


func add_noghost(x0: int, y0: int, x1: int, y1: int) -> void:
	noghost_rects.append([x0, y0, x1, y1])


func in_clear(x: int, y: int) -> bool:
	for r in clear_rects:
		if int(r[0]) <= x and x <= int(r[2]) and int(r[1]) <= y and y <= int(r[3]):
			return true
	return false


func in_noghost(x: int, y: int) -> bool:
	for r in noghost_rects:
		if int(r[0]) <= x and x <= int(r[2]) and int(r[1]) <= y and y <= int(r[3]):
			return true
	return false


## 本行被哪些 CLEAR rect 覆盖，返回 x-span 列表（按 CLEAR 长度做备忘，§4.7）。
func _clear_spans(y: int) -> Array:
	var n := clear_rects.size()
	if n != _span_n:
		_span_n = n
		_span_cache = {}
	var sp: Variant = _span_cache.get(y)
	if sp == null:
		sp = []
		for r in clear_rects:
			if int(r[1]) <= y and y <= int(r[3]):
				sp.append([int(r[0]), int(r[2])])
		_span_cache[y] = sp
	return sp


# ---------------------------------------------------------------- 写入（唯一入口）

## `Screen.put`：逐字符写入，(x, y) 为格坐标、原点左上；越界行直接返回、越界列逐字符跳过。
func put(x: int, y: int, text: String, fg_c: int = PV.UI, bg_c: int = PV.BG) -> void:
	if y < 0 or y >= rows:
		return
	var base := y * cols
	var spans := _clear_spans(y)
	for ch in text:
		var w := atlas.width_of(ch)
		if x >= 0 and x < cols:
			var i := base + x
			var k := dim[i]
			if k < 0.999 and not spans.is_empty():
				for sp in spans:
					if x >= int(sp[0]) and x <= int(sp[1]):
						k = 1.0
						break
			var f2 := fg_c
			if k < 0.999:
				f2 = PV.rgb(int(PV.ch_r(fg_c) * k), int(PV.ch_g(fg_c) * k), int(PV.ch_b(fg_c) * k))
			var s := atlas.slot_of(ch)
			_set_cell(i, ch.unicode_at(0), s, f2, bg_c, 0)
			if w == 2 and x + 1 < cols:
				_set_cell(i + 1, 0, s + 1, f2, bg_c, 1)
		x += 2 if w == 2 else 1


## `Screen.fill`：闭区间逐格写；不写 wide 标记、不吃暗角。
func fill(x0: int, y0: int, x1: int, y1: int, ch := " ", fg_c: int = PV.UI, bg_c: int = PV.BG) -> void:
	var s := atlas.slot_of(ch)
	var c := ch.unicode_at(0)
	for y in range(maxi(0, y0), mini(rows, y1 + 1)):
		var base := y * cols
		for x in range(maxi(0, x0), mini(cols, x1 + 1)):
			_set_cell(base + x, c, s, fg_c, bg_c, 0)


## `Screen.box`：框线 + 四角内缩一格的亮刻度 + 标题铭牌；`level` 是调用者给的基准值。
func box(x0: int, y0: int, x1: int, y1: int, title := "", level := 0.6,
		colour: Variant = null, spinner := true) -> void:
	if x1 - x0 < 3 or y1 - y0 < 2:
		return
	var lv := PV.beat_level(level)
	var col := PV.ui(1.0) if colour == null else int(colour)
	var f := PV.mix(col, lv)
	var tick := PV.mix(col, minf(1.0, lv + 0.4))
	for x in range(x0 + 1, x1):
		put(x, y0, "─", f)
		put(x, y1, "─", f)
	for y in range(y0 + 1, y1):
		put(x0, y, "│", f)
		put(x1, y, "│", f)
	put(x0, y0, "┌", tick)
	put(x1, y0, "┐", tick)
	put(x0, y1, "└", tick)
	put(x1, y1, "┘", tick)
	for x in [x0 + 1, x1 - 1]:
		put(x, y0, "─", tick)
		put(x, y1, "─", tick)
	for y in [y0 + 1, y1 - 1]:
		put(x0, y, "│", tick)
		put(x1, y, "│", tick)
	if not title.is_empty():
		var spin := PV.SPIN[int(PV.NOW * 8.0) % 4] if spinner else ""
		var label := " %s %s " % [spin, title]
		put(x0 + 2, y0, label.substr(0, maxi(0, x1 - x0 - 3)),
			PV.mix(col, minf(1.0, lv + 0.35)), PV.BG)


## `Screen.hbar`：条形亮度，八分之一块精度（`█` + `▁▂▃▄▅▆▇`）。
func hbar(x: int, y: int, width: int, v: float, colour: int, bg_c: int = PV.BG) -> void:
	v = clampf(v, 0.0, 1.0)
	var eighths := int(round(v * width * 8.0))
	var full := int(eighths / 8.0)
	var rest := eighths % 8
	for i in width:
		var ch := ""
		if i < full:
			ch = "█"
		elif i == full and rest > 0:
			ch = PV.RAMP.substr(rest, 1)
		if not ch.is_empty():
			put(x + i, y, ch, colour, bg_c)


## `Screen.waveform`：顶栏心电图，数据是歌曲真实的 1 ms RMS。
func waveform(x: int, y: int, width: int, data: PvData, t: float, colour: int) -> void:
	var i0 := int((t - PV.SPAN) * 1000.0)
	for i in width:
		var ms := i0 + int(i * PV.SPAN * 1000.0 / maxf(1.0, float(width)))
		var v := data.wave_at(ms)
		var idx := clampi(roundi(v * 8.0), 1, 8)
		put(x + i, y, PV.RAMP.substr(idx, 1), colour)


# ---------------------------------------------------------------- 内部与输出

func _set_cell(i: int, c: int, s: int, f: int, b: int, w: int) -> void:
	cp[i] = c
	slot[i] = s
	fg[i] = f
	bg[i] = b
	wide[i] = w
	_write_bytes(i, s, f, b)


func _write_bytes(i: int, s: int, f: int, b: int) -> void:
	var o := i * 4
	_idx_bytes[o] = s & 0xff
	_idx_bytes[o + 1] = (s >> 8) & 0xff
	_idx_bytes[o + 2] = 0
	_idx_bytes[o + 3] = 255
	_fg_bytes[o] = (f >> 16) & 0xff
	_fg_bytes[o + 1] = (f >> 8) & 0xff
	_fg_bytes[o + 2] = f & 0xff
	_fg_bytes[o + 3] = 255
	_bg_bytes[o] = (b >> 16) & 0xff
	_bg_bytes[o + 1] = (b >> 8) & 0xff
	_bg_bytes[o + 2] = b & 0xff
	_bg_bytes[o + 3] = 255


## 交给显示层的三张 RGBA8 格子纹理原始字节（尺寸 = cols × rows）。
func to_data() -> Dictionary:
	return {"idx": _idx_bytes, "fg": _fg_bytes, "bg": _bg_bytes}


# ---------------------------------------------------------------- FX 原语（§4.7，fx 层专用）
##
## Python 侧 FX 直接写 `s.buf[y][x] = (ch, fg, bg)`：不查 CLEAR、不吃暗角。本类的 `put()`
## 两样都做（那是界面文案要的），所以 FX 需要下面这组旁路接口。

## 原样写格（不吃暗角、不查 CLEAR）：槽位由字符现查图集；双宽字连右半格一起写。
func set_raw(x: int, y: int, ch: String, fg_c: int = PV.UI, bg_c: int = PV.BG) -> void:
	if y < 0 or y >= rows or x < 0 or x >= cols:
		return
	var base := y * cols
	var s := atlas.slot_of(ch)
	var c := ch.unicode_at(0)
	_set_cell(base + x, c, s, fg_c, bg_c, 0)
	if atlas.width_of(ch) == 2 and x + 1 < cols:
		_set_cell(base + x + 1, 0, s + 1, fg_c, bg_c, 1)


## 逐字段原样还原一格（cut 的 holds / CLEAR 直通要把「旧格」连槽位、wide 标记一起搬回来）。
func set_full(x: int, y: int, c: int, s: int, f: int, b: int, w: int) -> void:
	if y < 0 or y >= rows or x < 0 or x >= cols:
		return
	_set_cell(y * cols + x, c, s, f, b, w)


## 整行循环移位：`new[x] = old[(x - off) mod cols]`，对应 Python `row[-off:] + row[:-off]`。
## 用 `slice()` 先取临时副本，否则就地覆盖会读到已改过的格子。
func shift_row(y: int, off: int) -> void:
	if y < 0 or y >= rows or off == 0 or absi(off) >= cols:
		return
	var base := y * cols
	var rcp := cp.slice(base, base + cols)
	var rsl := slot.slice(base, base + cols)
	var rfg := fg.slice(base, base + cols)
	var rbg := bg.slice(base, base + cols)
	var rwd := wide.slice(base, base + cols)
	for x in cols:
		var k := wrapi(x - off, 0, cols)
		_set_cell(base + x, rcp[k], rsl[k], rfg[k], rbg[k], rwd[k])


## 在 `[x0, x1]` 这一段内做循环移位（C 层 `PvMotion` 的行位移用；整行版是 `shift_row()`）。
##
## 5A（`tools/ref/c_layer_plan.md` §7 冲突 5）：落在 CLEAR 区里的目标格**不写**，于是位移永远
## 不会把内容搬进 stdout 带或其它可读区，B 层终端不需要跟随。返回是否真的搬动过。
func shift_row_span(y: int, off: int, x0: int, x1: int) -> bool:
	if y < 0 or y >= rows:
		return false
	var a := clampi(x0, 0, cols - 1)
	var b := clampi(x1, 0, cols - 1)
	var w := b - a + 1
	if w < 2 or off == 0 or absi(off) % w == 0:
		return false
	var base := y * cols
	var rcp := cp.slice(base + a, base + b + 1)
	var rsl := slot.slice(base + a, base + b + 1)
	var rfg := fg.slice(base + a, base + b + 1)
	var rbg := bg.slice(base + a, base + b + 1)
	var rwd := wide.slice(base + a, base + b + 1)
	var moved := false
	for i in w:
		var x := a + i
		if in_clear(x, y):
			continue
		var k := wrapi(i - off, 0, w)
		_set_cell(base + x, rcp[k], rsl[k], rfg[k], rbg[k], rwd[k])
		moved = moved or (i != k)
	return moved


## 残影标记位要跟着格子一起走，否则 ghost 会长在自己的尾巴上（参考实现 L640-644）。
func shift_ghost_row(y: int, off: int) -> void:
	if y < 0 or y >= rows or off == 0 or absi(off) >= cols:
		return
	var base := y * cols
	var m := ghost_prev.slice(base, base + cols)
	for x in cols:
		ghost_prev[base + x] = m[wrapi(x - off, 0, cols)]


## 摘掉双宽右半格的标记（carry 飞过时用）：槽位归空白槽，避免留下左半的残像。
func drop_wide(x: int, y: int) -> void:
	if x < 0 or x >= cols or y < 0 or y >= rows:
		return
	var i := y * cols + x
	_set_cell(i, 0, 0, fg[i], bg[i], 0)


## 整行是否被任一 rect 的 y 区间覆盖（`fx_trail` 的 NOGHOST 行级判定）。
func row_covered(y: int, rects: Array) -> bool:
	for r in rects:
		if int(r[1]) <= y and y <= int(r[3]):
			return true
	return false


## 该列是否落在任一 rect 的 x 区间内（`fx_trail` 的 NOGHOST 列级判定，参考实现只比 x）。
func col_covered(x: int, rects: Array) -> bool:
	for r in rects:
		if int(r[0]) <= x and x <= int(r[2]):
			return true
	return false


## 本行与上一帧是否完全相同；`fx_trail` 只比对变化过的行（底色由 FX 统一写 BG，故不比对）。
func row_same(y: int) -> bool:
	var base := y * cols
	for x in cols:
		var i := base + x
		if cp[i] != prev_cp[i] or fg[i] != prev_fg[i] or wide[i] != prev_wide[i]:
			return false
	return true


## 纯文本 dump（剥色），`--dump` 用。
func text_dump() -> String:
	var out := PackedStringArray()
	for y in rows:
		var line := ""
		var base := y * cols
		for x in cols:
			if wide[base + x] == 1:
				continue
			line += char(cp[base + x]) if cp[base + x] > 0 else " "
		out.append(line.rstrip(" "))
	return "\n".join(out)
