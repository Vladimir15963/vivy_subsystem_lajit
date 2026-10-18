class_name PvData
extends RefCounted

## 重数据加载器：波形 / 音频特征 / 逐词歌词 / 中文对照 / boot 日志 / 她的字形立绘 / dsh 聊天窗。
##
## 对应参考实现 `tui_live.Data`（`tui_live.py:745-832`）。dsh 是 zlib 压缩的 `dsh.bin`
## （原始 JSON 5 MB），首次访问时懒加载解压；其余文件在 `_init()` 里一次读完。

const DATA := "res://subsystem/world_execute/data/"

var rate := 48.0                     ## 音频特征采样率（Hz）
var wave := PackedByteArray()        ## 100 Hz、u8 的 RMS（顶栏波形；0..255）
var wave_hz := 100.0                 ## 波形采样率（`wave_at` 用 ms 换算）
var loud := PackedFloat32Array()
var kick := PackedFloat32Array()
var flux := PackedFloat32Array()
var cent := PackedFloat32Array()
var bands: Array[PackedFloat32Array] = []   ## 7 条频段（与 PV.BANDS 一一对应）

var lines: Array = []                ## 逐词歌词行（见 `_load_lines`）
var lyric_cn: Dictionary = {}        ## 英文原句 → 中文对照
var boot_log: Array = []             ## [[t, tag, text]]
var cursor: Dictionary = {}
var her: Dictionary = {}             ## her_glyph.json

var _dsh: Dictionary = {}            ## 懒加载：{hz, frames}
var _dsh_hz := 12.0
var _dsh_tried := false


func _init() -> void:
	_load_wave()
	_load_features()
	_load_words()
	_load_her()


# ---------------------------------------------------------------- 读取工具

func _text(name: String) -> String:
	return FileAccess.get_file_as_string(DATA + name)


func _json(name: String, fallback: Variant) -> Variant:
	var raw := _text(name)
	if raw.is_empty():
		push_error("world_execute: 读取 data/%s 失败" % name)
		return fallback
	var v: Variant = JSON.parse_string(raw)
	return fallback if v == null else v


func _bytes(name: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(DATA + name)


# ---------------------------------------------------------------- 波形（§3.9）

func _load_wave() -> void:
	wave = _bytes("wave_rms.bin")
	var meta: Variant = _json("wave_rms.json", {})
	if typeof(meta) == TYPE_DICTIONARY:
		wave_hz = float(meta.get("sample_rate", 100))


## 第 ms 毫秒的 RMS（0..1）；越界返回 0（`Screen.waveform` 的行为）。
## 数据是 100 Hz 的 u8，所以先按毫秒换算成桶下标。
func wave_at(ms: int) -> float:
	if ms < 0:
		return 0.0
	var i := int(ms * wave_hz / 1000.0)
	if i < 0 or i >= wave.size():
		return 0.0
	return wave[i] / 255.0


# ---------------------------------------------------------------- 音频特征（§3.8）

func _load_features() -> void:
	var f: Variant = _json("features.json", {})
	if typeof(f) != TYPE_DICTIONARY:
		return
	rate = float(f.get("rate", 48.0))
	loud = _floats(f.get("loud"))
	kick = _floats(f.get("kick"))
	flux = _floats(f.get("flux"))
	cent = _floats(f.get("cent"))
	bands.clear()
	for b in (f.get("bands", []) as Array):
		bands.append(_floats(b))


func _floats(v: Variant) -> PackedFloat32Array:
	return PackedFloat32Array(v) if typeof(v) == TYPE_ARRAY else PackedFloat32Array()


func _curve(name: String) -> PackedFloat32Array:
	match name:
		"loud": return loud
		"kick": return kick
		"flux": return flux
		"cent": return cent
		_: return PackedFloat32Array()


## `Data.feat(t, "kick"|"loud"|"flux"|"cent")`。
func feat(t: float, name: String) -> float:
	var arr := _curve(name)
	if arr.is_empty():
		return 0.0
	return arr[clampi(int(t * rate), 0, arr.size() - 1)]


## `Data.band(t, i)`：第 i 条频段（0..6）。
func band_at(t: float, i: int) -> float:
	if i < 0 or i >= bands.size():
		return 0.0
	var row := bands[i]
	if row.is_empty():
		return 0.0
	return row[clampi(int(t * rate), 0, row.size() - 1)]


# ---------------------------------------------------------------- 逐词歌词（§3.3）

## 逐字推进用的数学与 `tui_live.Data._load_lines` / `typed` 逐字一致：
## 词内 onset + td*j/n 均分；词尾到下一个词起点用 onset+td；td 取 `min(0.25, dur)`（含 "-" 的词
## 用整 dur），下限 0.06。带 "-" 的词会把字符拉长（"lo-o-ove"）。
func _load_words() -> void:
	var raw: Variant = _json("words.json", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return
	for ln in (raw.get("lines", []) as Array):
		var text := str(ln.get("text", ""))
		var words: Array = []
		var pos := 0
		for w in (ln.get("words", []) as Array):
			var shown := str(w.get("text", ""))
			if shown.is_empty():
				continue
			var i := text.find(shown, pos)
			if i < 0:
				continue
			pos = i + shown.length()
			var dur := maxf(0.0, float(w["end"]) - float(w["start"]))
			var td := dur if shown.contains("-") else minf(0.25, dur)
			words.append(PackedFloat32Array([float(i), float(i + shown.length()),
				float(w["start"]), maxf(0.06, td)]))
		if text.is_empty() or words.is_empty():
			continue
		var last_w: PackedFloat32Array = words[words.size() - 1]
		var end := float(ln.get("display_end")) if ln.get("display_end") != null else float(last_w[2])
		lines.append({
			"text": text, "start": float(words[0][2]), "end": end,
			"words": words, "when": PackedFloat32Array(),
		})
	for k in lines.size():
		var ln: Dictionary = lines[k]
		var nxt: float = float(lines[k + 1]["start"]) if k + 1 < lines.size() else PV.END
		if nxt - float(ln["end"]) > 2.0:
			ln["show_until"] = float(ln["end"]) + PV.BEAT
			ln["fade_until"] = float(ln["end"]) + 2.0 * PV.BEAT
		else:
			ln["show_until"] = nxt
			ln["fade_until"] = nxt
	lyric_cn = _json("lyrics_cn.json", {})


## 当前歌词行与其淡出系数：`[line, alpha]`；没有时 `[{}, 0.0]`。
func line_at(t: float) -> Array:
	for ln in lines:
		if float(ln["start"]) <= t and t < float(ln["fade_until"]):
			var a := 1.0
			var su := float(ln["show_until"])
			var fu := float(ln["fade_until"])
			if t >= su:
				a = 1.0 - (t - su) / maxf(1e-6, fu - su)
			return [ln, a]
	return [{}, 0.0]


## `[已输出字符数, 每个字符的到达时刻]`。`when` 每行只算一次（纯函数，结果可缓存）。
func typed(ln: Dictionary, t: float) -> Array:
	if ln.is_empty():
		return [0, PackedFloat32Array()]
	var text := str(ln["text"])
	var when: PackedFloat32Array = ln["when"]
	if when.size() != text.length():
		when = PackedFloat32Array()
		when.resize(text.length())
		when.fill(INF)
		var words: Array = ln["words"]
		for k in words.size():
			var w: PackedFloat32Array = words[k]
			var i0 := int(w[0])
			var i1 := int(w[1])
			var onset := w[2]
			var td := w[3]
			var n := i1 - i0
			for j in n:
				when[i0 + j] = onset + td * j / n
			var nxt := int(words[k + 1][0]) if k + 1 < words.size() else text.length()
			for j in range(i1, nxt):
				when[j] = onset + td
		ln["when"] = when
	var n_out := 0
	while n_out < text.length() and when[n_out] <= t:
		n_out += 1
	return [n_out, when]


func lyric_cn_for(text: String) -> String:
	return str(lyric_cn.get(text, ""))


# ---------------------------------------------------------------- boot 日志（§3.4）

func _load_her() -> void:
	boot_log = _json("boot_log.json", [])
	cursor = _json("cursor.json", {})
	her = _json("her_glyph.json", {})


## t 之前已经打印的 boot 行：`[[t, tag, text]]`。
func boot_printed(t: float) -> Array:
	var out: Array = []
	for row in boot_log:
		if float(row[0]) <= t:
			out.append(row)
	return out


# ---------------------------------------------------------------- 她的字形立绘（glyph 路径）

## 表情名 → {chars:[44*36], lum:[...], edge:[...]}。
func expression(name: String) -> Dictionary:
	var exprs: Dictionary = her.get("expressions", {})
	var e: Variant = exprs.get(name)
	return e if typeof(e) == TYPE_DICTIONARY else {}


func expression_names() -> Array:
	var exprs: Dictionary = her.get("expressions", {})
	return exprs.keys()


# ---------------------------------------------------------------- dsh 聊天窗（懒加载）

func _load_dsh() -> void:
	if _dsh_tried:
		return
	_dsh_tried = true
	var meta: Variant = _json("dsh_meta.json", {})
	var raw_size := int(meta.get("raw_size", 0)) if typeof(meta) == TYPE_DICTIONARY else 0
	var packed := _bytes("dsh.bin")
	if packed.is_empty() or raw_size <= 0:
		push_error("world_execute: dsh.bin / dsh_meta.json 缺失或不完整")
		return
	var raw := packed.decompress(raw_size, FileAccess.COMPRESSION_DEFLATE)
	if raw.is_empty():
		push_error("world_execute: dsh.bin 解压失败")
		return
	var d: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(d) != TYPE_DICTIONARY:
		push_error("world_execute: dsh.bin 解析失败")
		return
	_dsh = d
	_dsh_hz = float((meta as Dictionary).get("hz", d.get("hz", 12)))


## t 时刻的聊天窗帧：`{t, avatar, theme:[bg, brand, border], rows:[{role, text}]}`；越界贴边，
## 无数据返回 {}。`theme[1]`（`brand-primary`）是窗口的强调色，`rows` 里的 `dot` 是状态点色。
func dsh_at(t: float) -> Dictionary:
	_load_dsh()
	var frames: Array = _dsh.get("frames", [])
	if frames.is_empty():
		return {}
	var i := clampi(int(t * _dsh_hz), 0, frames.size() - 1)
	return frames[i]
