class_name PvAtlas
extends RefCounted

## 字形图集（`data/glyphs.png` + `glyphs.json`）。
##
## 图集契约（由 tools/build_atlas.py 产出，两边必须逐值一致）：
##   CELL_W=9, CELL_H=18, ATLAS_COLS=32，槽位数 1129；baseline=12。
##   字符 → [slot, width]，width ∈ {0,1,2}；双宽字占两个**连续**槽（左半 = slot，右半 = slot+1），
##   所以渲染端不需要知道「双宽」这件事：只要把右半格也写成 slot+1 即可。
##   槽 0 = 全空白。
##
## 缺字（不在图集里，通常是面板新增了硬编码文案却忘了跑 builder）按 width=1、slot=0 处理，
## 即渲染为空白而不是豆腐块；`missing()` 可以把它们列出来自查。

const PNG_PATH := "res://subsystem/world_execute/data/glyphs.png"
const JSON_PATH := "res://subsystem/world_execute/data/glyphs.json"

var texture: Texture2D
var cell_w := 9
var cell_h := 18
var atlas_cols := 32
var atlas_rows := 36
var slot_count := 1129
var baseline := 12

## char(String, 单字符) → [slot:int, width:int]
var chars: Dictionary = {}
var missing_chars: Array[String] = []


func _init() -> void:
	texture = load(PNG_PATH)
	if texture == null:
		push_error("world_execute: 缺少字形图集 %s，请先跑 tools/build_atlas.py" % PNG_PATH)
		return
	var raw := FileAccess.get_file_as_string(JSON_PATH)
	var data: Variant = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("world_execute: %s 解析失败" % JSON_PATH)
		return
	cell_w = int(data.get("cell_w", cell_w))
	cell_h = int(data.get("cell_h", cell_h))
	atlas_cols = int(data.get("atlas_cols", atlas_cols))
	atlas_rows = int(data.get("atlas_rows", atlas_rows))
	slot_count = int(data.get("slot_count", slot_count))
	baseline = int(data.get("baseline", baseline))
	chars = data.get("chars", {})


func has_char(ch: String) -> bool:
	return chars.has(ch)


## 该字符在图集里的槽位；缺字返回 0（空白）。
func slot_of(ch: String) -> int:
	var e: Variant = chars.get(ch)
	return int(e[0]) if e != null else 0


## 该字符占几格：0=零宽、1=单宽、2=双宽；缺字按 1（空白占位）处理。
func width_of(ch: String) -> int:
	var e: Variant = chars.get(ch)
	return int(e[1]) if e != null else 1


## 自查：文本里哪些字不在图集（面板硬编码文案与 UI_LITERALS 失同步时会用到）。
func scan_missing(text: String) -> void:
	for ch in text:
		if not chars.has(ch) and not missing_chars.has(ch):
			missing_chars.append(ch)


func atlas_size() -> Vector2:
	return Vector2(atlas_cols * cell_w, atlas_rows * cell_h)


## 一个格子的像素尺寸，供显示层建 shader uniform。
func cell_size_vec() -> Vector2:
	return Vector2(cell_w, cell_h)
