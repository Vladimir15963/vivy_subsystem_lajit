class_name PvHer
extends RefCounted

## 「她」的三条渲染路径（h3 / half / glyph）—— 纯数学与查表，静态函数。
##
## 逐函数对应参考实现：
##   * `_tools/her_glyphs.py`：`CROPS` / `CELL_ASPECT` / `crop_aspect` / `pick_crop` / `fit` /
##     `cropped` / `glyph_lines` / `halfblock` / `tint_ramp` / `_frame_cells` / `_h3_ink` / `h3_cells`
##   * `continuity_full_v2/h3_full.py`：`PLAN` / `source` / `join` / `frame_at`
##   * `full/dancer.py`：`_ramp`（256 级）/ `_text_at` / `_flow_table` / `flow_offset` / `CPS`
##   * `_tools/tui_live.py`：`_flip_order` / `_morph_mask` / `_glitch` / `MORPH_*`
##
## 数据由 `tools/build_data.py` 烘出来（见 README「数据管线产出的表」）：
##   `her_sprite/{expr}.png`（R=G=B=原亮度、A=原 alpha，最长边 512）+ `her_sprite.json`（缩放后
##   尺寸 / 四张 crop 矩形 / cheerful 量的裁剪宽高比）；
##   `h3_takes.bin`（16 take 的 art+shade，只存墨迹框 34×39，zlib）+ `h3_takes.json`；
##   `h3_ramp.json`（256 级蓝/红）、`h3_flow.bin` + `h3_flow.json`、`h3_text.json`、`her_morph.json`。
##
## 已知偏差（详见 README「已知取舍」）：立绘源图降到 512 后二次重采样；Godot 的
## `INTERPOLATE_LANCZOS` 与 PIL 的 `Image.LANCZOS` 核不同；`roundi`（四舍五入到远离零）与
## Python `round`（银行家舍入）在恰好 .5 处可能差 1。Sobel 已按 PIL `ImageFilter.Kernel` 的实际
## 语义实现（行翻转、列不翻转、边界取原值、`floor(sum/4+0.5)+128`，实测与 PIL 逐格一致）。

const DATA := "res://subsystem/world_execute/data/"

const CELL_ASPECT := 2.1
const GLYPH_RAMP := " .:-=+*#%@"
const CROPS := ["full", "upper", "face", "bust"]
## 切换动画（tui_live.py:L1307-1309）。
const MORPH_DUR := 0.30
const MORPH_GONE := 0.42
const MORPH_EDGE := 0.12
const H3_FPS := 24.0
const H3_PERIOD := 16.0 * 60.0 / 130.0     # h3_full.loop 段的周期
const H3_END := 211.9
## 墨迹框上界常量（`h3_takes.json` 里也存了；这里做兜底默认）。
const INK_DEFAULT := [10, 43, 17, 55]
const KX := [-1, 0, 1, -2, 0, 2, -1, 0, 1]
const KY := [-1, -2, -1, 0, 0, 0, 1, 2, 1]

static var _loaded := false
static var _sprite_ok := false
static var _h3_ok := false
static var _sprites: Dictionary = {}       # expr -> {orig:[w,h], size:[w,h], crops:{crop:[x,y,w,h]}}
static var _aspects: Dictionary = {}       # crop -> float
static var _images: Dictionary = {}        # expr -> Image
static var _ramp: Dictionary = {}          # "blue"/"red" -> PackedInt32Array(256)，h3 路径
static var _ramp8: Dictionary = {}         # "blue"/"red" -> PackedInt32Array(8)，half 路径
static var _takes: Dictionary = {}         # name -> [frames, offset]
static var _charset := ""
static var _blob := PackedByteArray()
static var _plan: Array = []
static var _ink := INK_DEFAULT
static var _h3_rows := 34
static var _h3_cols := 39
static var _flow := PackedFloat32Array()
static var _text: Array = []
static var _order := PackedFloat32Array()
static var _cells_cache: Dictionary = {}
static var _crop_cache: Dictionary = {}


# ================================================================ 加载

static func _json(name: String, fallback: Variant) -> Variant:
	var raw := FileAccess.get_file_as_string(DATA + name)
	if raw.is_empty():
		return fallback
	var v: Variant = JSON.parse_string(raw)
	return fallback if v == null else v


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_load_sprites()
	_load_h3()
	_load_misc()


static func _load_sprites() -> void:
	var meta: Variant = _json("her_sprite.json", {})
	if typeof(meta) != TYPE_DICTIONARY:
		return
	_sprites = meta.get("sprites", {})
	_aspects = meta.get("aspects", {})
	if _sprites.is_empty() or _aspects.is_empty():
		return
	for expr in _sprites.keys():
		var raw := FileAccess.get_file_as_bytes(DATA + "her_sprite/%s.png" % expr)
		if raw.is_empty():
			push_error("world_execute: 读取 data/her_sprite/%s.png 失败" % expr)
			return
		var img := Image.new()
		if img.load_png_from_buffer(raw) != OK:
			push_error("world_execute: 解码 data/her_sprite/%s.png 失败" % expr)
			return
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		_images[expr] = img
	_sprite_ok = _images.size() == _sprites.size()


static func _load_h3() -> void:
	var meta: Variant = _json("h3_takes.json", {})
	if typeof(meta) != TYPE_DICTIONARY:
		return
	_takes = meta.get("takes", {})
	_charset = str(meta.get("charset", ""))
	_plan = meta.get("plan", [])
	_ink = meta.get("ink", INK_DEFAULT)
	_h3_rows = int(meta.get("rows", 34))
	_h3_cols = int(meta.get("cols", 39))
	var raw_size := int(meta.get("raw_size", 0))
	if _takes.is_empty() or _plan.is_empty() or raw_size <= 0 or _charset.is_empty():
		return
	var comp := FileAccess.get_file_as_bytes(DATA + "h3_takes.bin")
	if comp.is_empty():
		push_error("world_execute: 读取 data/h3_takes.bin 失败")
		return
	_blob = comp.decompress(raw_size, FileAccess.COMPRESSION_DEFLATE)
	_h3_ok = _blob.size() == raw_size


static func _load_misc() -> void:
	var r: Variant = _json("h3_ramp.json", {})
	if typeof(r) == TYPE_DICTIONARY:
		for t in ["blue", "red"]:
			if r.has(t):
				var rows: Array = r[t]
				var pk := PackedInt32Array()
				pk.resize(rows.size())
				for k in rows.size():
					var c: Array = rows[k]
					pk[k] = PV.rgb(int(c[0]), int(c[1]), int(c[2]))
				_ramp[t] = pk
			if r.has(t + "8"):
				var rows8: Array = r[t + "8"]
				var pk8 := PackedInt32Array()
				pk8.resize(rows8.size())
				for k in rows8.size():
					var c8: Array = rows8[k]
					pk8[k] = PV.rgb(int(c8[0]), int(c8[1]), int(c8[2]))
				_ramp8[t] = pk8
	var f := FileAccess.get_file_as_bytes(DATA + "h3_flow.bin")
	if not f.is_empty():
		_flow = f.to_float32_array()
	_text = _json("h3_text.json", [])
	var o: Variant = _json("her_morph.json", [])
	if typeof(o) == TYPE_ARRAY:
		_order = PackedFloat32Array(o)


static func sprite_available() -> bool:
	_load()
	return _sprite_ok


static func h3_available() -> bool:
	_load()
	return _h3_ok


## 启动时一次性把 h3 的懒加载代价付掉（对应 `her_glyphs.warm_h3()`）。
static func warm_h3(cols := 116, rows := 26) -> bool:
	_load()
	if not _h3_ok:
		return false
	h3_cells(0.0, cols, rows, "blue")
	return true


# ================================================================ 裁剪几何（her_glyphs.py:L62-119）

static func crop_box(expr: String, crop: String) -> Array:
	_load()
	var sp: Variant = _sprites.get(expr)
	if typeof(sp) != TYPE_DICTIONARY:
		return [0, 0, 1, 1]
	var crops: Dictionary = sp.get("crops", {})
	if not crops.has(crop):
		return [0, 0, 1, 1]
	return crops[crop]


## `crop_aspect(crop)`（her_glyphs.py:L72-77）：四个裁剪自身的宽/高，用 cheerful 量。
static func crop_aspect(crop: String) -> float:
	_load()
	return float(_aspects.get(crop, 1.0))


## `pick_crop(cols,rows)`（her_glyphs.py:L80-88）。
static func pick_crop(cols: int, rows: int) -> String:
	_load()
	var box := cols / maxf(1.0, rows * CELL_ASPECT)
	var best := ""
	var best_d := INF
	for c in CROPS:
		var d := absf(log(crop_aspect(c) / box))
		if d < best_d:
			best_d = d
			best = c
	return best


## `fit(cols,rows,crop)`（her_glyphs.py:L91-102）→ `[w, h]`。
static func fit(cols: int, rows: int, crop: String) -> Array:
	var a := crop_aspect(crop)
	var uc := roundi(rows * CELL_ASPECT * a)
	var ur := rows
	if uc > cols:
		uc = cols
		ur = maxi(3, roundi(cols / (CELL_ASPECT * a)))
	return [maxi(4, mini(cols, uc)), maxi(3, mini(rows, ur))]


static func _sprite_image(expr: String) -> Image:
	_load()
	return _images.get(expr, null)


## `_crop_box(sprite(expr),crop)` 的裁剪结果（不足时返回 1×1）。
static func _crop_box_image(expr: String, crop: String) -> Image:
	var im := _sprite_image(expr)
	if im == null:
		var e := Image.new()
		e.create(1, 1, false, Image.FORMAT_RGBA8)
		return e
	var b := crop_box(expr, crop)
	return im.get_region(Rect2i(int(b[0]), int(b[1]), int(b[2]), int(b[3])))


## `cropped(expr,crop,target_aspect)`（her_glyphs.py:L105-119）：裁完后按目标宽高比居中裁一次。
static func _cropped(expr: String, crop: String, target_aspect: float) -> Image:
	var key := "%s|%s|%.4f" % [expr, crop, target_aspect]
	var hit: Variant = _crop_cache.get(key)
	if hit != null:
		return hit
	var im := _crop_box_image(expr, crop)
	if target_aspect > 0.0:
		var w := im.get_width()
		var h := im.get_height()
		if w / float(h) > target_aspect:
			var nw := maxi(1, roundi(h * target_aspect))
			var x := (w - nw) / 2
			im = im.get_region(Rect2i(x, 0, nw, h))
		else:
			var nh := maxi(1, roundi(w / target_aspect))
			var y := int((h - nh) * 0.25)
			im = im.get_region(Rect2i(0, y, w, nh))
	_crop_cache[key] = im
	return im


static func _resize(im: Image, w: int, h: int) -> Image:
	var out := im.duplicate()
	if out.get_width() != w or out.get_height() != h:
		out.resize(w, h, Image.INTERPOLATE_LANCZOS)
	if out.get_format() != Image.FORMAT_RGBA8:
		out.convert(Image.FORMAT_RGBA8)
	return out


# ================================================================ glyph 路径（her_glyphs.py:L122-150）

## Sobel（`ImageFilter.Kernel((3,3),K,scale=4,offset=128)` 的实测语义）：
##   * 边界一圈取原值（PIL 只改内圈，外圈原样拷贝）；
##   * 索引：行翻转、列不翻转 → 输入下标 `(r + 1 - j, c + i - 1)`；
##   * `clamp(floor(sum/4 + 0.5) + 128, 0, 255)`（实测 0 处不一致）。
static func _sobel(L: PackedByteArray, cols: int, rows: int, c: int, r: int, K: Array) -> int:
	if c <= 0 or r <= 0 or c >= cols - 1 or r >= rows - 1:
		return L[r * cols + c]
	var s := 0
	for j in 3:
		var rr := r + 1 - j
		for i in 3:
			s += int(L[rr * cols + c + i - 1]) * int(K[j * 3 + i])
	return clampi(int(floor(s / 4.0 + 0.5)) + 128, 0, 255)


## `glyph_lines(expr,crop,cols,rows)`（her_glyphs.py:L122-150）→ `[lines: Array[String], bright: PackedByteArray]`。
static func glyph_lines(expr: String, crop: String, cols: int, rows: int) -> Array:
	var aspect := cols / maxf(1.0, rows * CELL_ASPECT)
	var small := _resize(_cropped(expr, crop, aspect), cols, rows)
	var n := cols * rows
	var d := small.get_data()
	var L := PackedByteArray()
	var A := PackedByteArray()
	L.resize(n)
	A.resize(n)
	for i in n:
		L[i] = d[i * 4]
		A[i] = d[i * 4 + 3]
	var bright := PackedByteArray()
	bright.resize(n)
	var lines: Array[String] = []
	for r in rows:
		var row := ""
		for c in cols:
			var i := r * cols + c
			if A[i] < 110:
				row += " "
				continue
			var v := L[i] / 255.0
			var ex := (_sobel(L, cols, rows, c, r, KX) - 128) / 32.0
			var ey := (_sobel(L, cols, rows, c, r, KY) - 128) / 32.0
			if sqrt(ex * ex + ey * ey) > 1.1:
				var ang := fposmod(rad_to_deg(atan2(ey, ex)) + 180.0, 180.0)
				if ang < 22.5 or ang >= 157.5:
					row += "|"
				elif ang < 67.5:
					row += "\\"
				elif ang < 112.5:
					row += "-"
				else:
					row += "/"
				bright[i] = 255
			else:
				row += GLYPH_RAMP.substr(mini(GLYPH_RAMP.length() - 1,
					1 + int(v * (GLYPH_RAMP.length() - 1))), 1)
				bright[i] = int(255 * (0.35 + 0.65 * v))
		lines.append(row)
	return [lines, bright]


# ================================================================ half 路径（her_glyphs.py:L179-204）

## `halfblock(expr,crop,cols,rows,levels=8)`（her_glyphs.py:L179-204）。
## 返回 `[block, aw, ah]`：`block` 是**扁平** `PackedInt32Array`，下标 `(r*aw+c)*2` = 上采样级、
## `+1` = 下采样级，`-1` 表示该采样透明（对应 Python 的 `None`）。
static func halfblock(expr: String, crop: String, cols: int, rows: int, levels := 8) -> Array:
	var a := crop_aspect(crop)
	var ur := roundi(minf(cols / a, rows * 2.0))
	ur -= ur % 2
	var uc := maxi(2, mini(cols, roundi(ur * a)))
	var small := _resize(_crop_box_image(expr, crop), uc, ur)
	var d := small.get_data()
	var block := PackedInt32Array()
	block.resize(uc * (ur / 2) * 2)
	for r in (ur / 2):
		for c in uc:
			block[(r * uc + c) * 2] = _level(d, uc, c, 2 * r, levels)
			block[(r * uc + c) * 2 + 1] = _level(d, uc, c, 2 * r + 1, levels)
	return [block, uc, ur / 2]


## `halfblock_lum` 的单点（her_glyphs.py:L197-201）：alpha ≤ 100 透明，亮度从 16 % 起步。
static func _level(d: PackedByteArray, cols: int, c: int, r: int, levels: int) -> int:
	var i := (r * cols + c) * 4
	if d[i + 3] <= 100:
		return -1
	return roundi((0.16 + (1.0 - 0.16) * d[i] / 255.0) * (levels - 1))


# ================================================================ 色阶（dancer._ramp / her_glyphs.tint_ramp）

## `dancer._ramp(tint)` 的 256 级查表（读 h3_ramp.json）。
static func tint_ramp(tint: String) -> PackedInt32Array:
	_load()
	var r: Variant = _ramp.get(tint)
	return r if r != null else PackedInt32Array()


## `her_glyphs.tint_ramp(tint,8)`：half 路径用的 8 级表（烘在 h3_ramp.json 的 blue8/red8）。
## 注意红的常量与上面的 256 级表不同（her_glyphs 自己那对），所以不能从 256 级采样推出来。
static func tint_ramp8(tint: String) -> PackedInt32Array:
	_load()
	var r: Variant = _ramp8.get(tint)
	return r if r != null else PackedInt32Array()


# ================================================================ h3 路径

static func h3_plan() -> Array:
	_load()
	return _plan


## `h3_full.source(t)`（h3_full.py:L95-113）→ `[name, i]`。
static func h3_source(t: float) -> Array:
	_load()
	t = clampf(t, 0.0, 211.999)
	var seg: Array = _plan[_seg_index(t)]
	var start := float(seg[0])
	var end := float(seg[1])
	var name := str(seg[2])
	var a := float(seg[3])
	var b := float(seg[4])
	var u := 0.0
	if str(seg[5]) == "loop":
		u = fposmod(t - start, H3_PERIOD) / H3_PERIOD
	else:
		u = (t - start) / (end - start)
	var sec := a + (b - a) * u
	var knots := _knots(name)
	if not knots.is_empty() and absf(start - float(knots[0][0])) < 0.001:
		for k in knots.size() - 1:
			var x := float(knots[k][0])
			var v := float(knots[k][1])
			var y := float(knots[k + 1][0])
			var w := float(knots[k + 1][1])
			if t < y:
				sec = v + (w - v) * (t - x) / (y - x)
				break
	var i := clampi(roundi(sec * H3_FPS), 0, int(_takes[name][0]) - 1)
	return [name, i]


static func _seg_index(t: float) -> int:
	for k in _plan.size():
		var p: Array = _plan[k]
		if float(p[0]) <= t and t < float(p[1]):
			return k
	return _plan.size() - 1


## `h3_full.join(t)`（h3_full.py:L115-123）→ `[]` 或 `[[name,i], u]`。
static func _join(t: float) -> Array:
	var t2 := clampf(t, 0.0, 211.999)
	var seg: Array = _plan[_seg_index(t2)]
	var boundary := float(seg[0])
	if str(seg[5]) == "loop":
		boundary += int((t2 - boundary) / H3_PERIOD) * H3_PERIOD
	var age := t2 - boundary
	if boundary > 0.0 and age < 4.0 / H3_FPS:
		return [h3_source(boundary - 1.0 / H3_FPS), minf(1.0, (age * H3_FPS + 1.0) / 4.0)]
	return []


static func _knots(name: String) -> Array:
	match name:
		"turn":
			return [[33.292, 0.7], [33.75, 1.2], [34.333, 2.0], [34.8, 2.7], [35.125, 3.7],
				[36.333, 4.9], [36.851, 5.125]]
		"reach":
			return [[110.416, 0.0], [111.844, 1.3], [112.25, 2.9], [112.85, 3.5], [114.0, 4.5],
				[115.543, 5.125]]
		"downbeat":
			return [[164.125, 0.9], [164.8, 1.25], [165.458, 2.4], [166.6, 3.6], [166.792, 3.8]]
		"release":
			return [[188.167, 0.15], [189.364, 0.9], [189.7, 2.6], [190.4, 3.7], [191.433, 4.55],
				[193.543, 5.125]]
	return []


## 一个 take 的一帧的墨迹框内容（art + shade），只解 34×39。
static func _decode_frame(name: String, i: int) -> Array:
	var base := int(_takes[name][1]) + i * 2 * _h3_rows * _h3_cols
	var art: Array[String] = []
	var shade: Array[PackedByteArray] = []
	var p := base
	for r in _h3_rows:
		var row := ""
		for c in _h3_cols:
			row += _charset.substr(_blob[p], 1)
			p += 1
		art.append(row)
	for r in _h3_rows:
		var srow := PackedByteArray()
		srow.resize(_h3_cols)
		for c in _h3_cols:
			srow[c] = _blob[p]
			p += 1
		shade.append(srow)
	return [art, shade]


## `h3_full.frame_at(t)`（h3_full.py:L135-147）：接缝处按 `cut = round(45*u)` 逐行拼 4 帧。
## 我们只存墨迹框（行 10..43），所以按**绝对行号**判定：`br + ink[0] < cut` 取新帧。
static func _frame_at(t: float) -> Array:
	var s := h3_source(t)
	var fr := _decode_frame(str(s[0]), int(s[1]))
	var j := _join(t)
	if j.is_empty():
		return fr
	var old: Array = j[0]
	var before := _decode_frame(str(old[0]), int(old[1]))
	var cut := roundi(45.0 * float(j[1]))
	var r0 := int(_ink[0])
	var art: Array[String] = []
	var shade: Array[PackedByteArray] = []
	for br in _h3_rows:
		if br + r0 < cut:
			art.append(fr[0][br])
			shade.append(fr[1][br])
		else:
			art.append(before[0][br])
			shade.append(before[1][br])
	return [art, shade]


## `_tools/tui_live._text_at`（dancer.py:L75-81）用的 `LYRICS` 行表。
static func text_at(t: float) -> String:
	_load()
	if _text.is_empty():
		return "world.execute(me);"
	var i := -1
	for k in _text.size():
		var a := float(_text[k][0])
		var b := float(_text[k][1])
		if a <= t and t < b:
			i = k
			break
	if i < 0:
		i = 0
		for k in _text.size():
			if float(_text[k][0]) <= t:
				i = k
	var parts := PackedStringArray()
	for k in range(i, mini(i + 4, _text.size())):
		var s := str(_text[k][2])
		if not s.strip_edges().is_empty():
			parts.append(s)
	var txt := " / ".join(parts)
	if txt.is_empty():
		txt = "world.execute(me);"
	return txt.replace(" ", "·") + "·//·"


## `dancer.flow_offset(t)`（dancer.py:L99-101）。
static func flow_offset(t: float) -> int:
	_load()
	if _flow.is_empty():
		return 0
	return int(_flow[clampi(int(t * H3_FPS), 0, _flow.size() - 1)])


## `_frame_cells(t,tint)`（her_glyphs.py:L267-301）落在墨迹框里的部分。
## 单元格编码：`null` = 空；否则 `[ch: String, fg: int, bg: int]`，`bg = -1` 表示无底色。
static func frame_cells(t: float, tint: String) -> Array:
	_load()
	var key := "%.5f|%s" % [t, tint]
	var hit: Variant = _cells_cache.get(key)
	if hit != null:
		return hit
	var fr := _frame_at(t)
	var ramp := tint_ramp(tint)
	var text := text_at(t)
	var n := text.length()
	var off := flow_offset(t)
	var k := 0
	var cells: Array = []
	for r in _h3_rows:
		var arow: String = fr[0][r]
		var srow: PackedByteArray = fr[1][r]
		var line: Array = []
		for c in _h3_cols:
			var ch := arow.substr(c, 1)
			if ch == " ":
				line.append(null)
				continue
			var sb := srow[c]
			var lv := sb if sb < 10 else 4
			var gl := 0
			if ch == ":":
				ch = text.substr((k + off) % n, 1)
				k += 1
				gl = int(60 + lv * 26) if ch != "·" else int(40 + lv * 10)
			else:
				gl = mini(255, int(110 + lv * 21))
			line.append([ch, ramp[gl], ramp[lv * 15] if lv >= 5 else -1])
		cells.append(line)
	if _cells_cache.size() > 256:
		_cells_cache.clear()
	_cells_cache[key] = cells
	return cells


## `h3_cells(t,cols,rows,tint)`（her_glyphs.py:L336-340）→ `[cells, aw, ah, ox, oy]`。
static func h3_cells(t: float, cols: int, rows: int, tint := "blue") -> Array:
	_load()
	if cols < 4 or rows < 3:
		return [[], 0, 0, 0, 0]
	var tt := roundf(clampf(t, 0.0, H3_END) * H3_FPS) / H3_FPS
	var grid := frame_cells(tt, tint)
	var kh := mini(_h3_rows, rows)
	var kw := mini(_h3_cols, cols)
	var x0 := maxi(0, (_h3_cols - kw) / 2)
	var cells: Array = []
	for r in kh:
		cells.append(grid[r].slice(x0, x0 + kw))
	return [cells, kw, kh, maxi(0, (cols - kw) / 2), maxi(0, rows - kh)]


# ================================================================ 切换（tui_live.py:L1315-1336）

## `_flip_order(n)`（tui_live.py:L1315-1319，读 her_morph.json）。
static func flip_order(n: int) -> PackedFloat32Array:
	_load()
	var out := PackedFloat32Array()
	out.resize(n)
	for k in n:
		out[k] = _order[k % maxi(1, _order.size())]
	return out


## `_morph_mask(u,order,k,t)`（tui_live.py:L1322-1332）→ `[draw, glitch]`。`u < 0` 表示「不在切换中」。
static func morph_mask(u: float, order: PackedFloat32Array, k: int, _t: float) -> Array:
	if u < 0.0:
		return [true, false]
	var th := order[k % maxi(1, order.size())]
	if u < MORPH_GONE:
		return [false, th < (1.0 - u / MORPH_GONE) * 0.30]
	var v := (u - MORPH_GONE) / (1.0 - MORPH_GONE)
	if th > v:
		return [false, false]
	return [true, absf(th - v) < MORPH_EDGE]


## `_glitch(t,k)`（tui_live.py:L1335-1336）：`SCRAMBLE[(k*31 + int(t*97)) % len]`。
static func glitch_char(t: float, k: int) -> String:
	var s := PV.SCRAMBLE
	return s.substr((k * 31 + int(t * 97.0)) % s.length(), 1)
