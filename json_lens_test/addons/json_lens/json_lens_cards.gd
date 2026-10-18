@tool
extends Control

## JSON Lens —— 卡片视图（按文件格式渲染）
##
## 专为「条目集合 → 条目 → [kind, text] 事件列表」这种 JSON 设计（见 json_lens_schema.gd）。
## 目标：把它当成对话转录来读，而不是当成嵌套数组来读。
##
## 三件事让它好读：
## 1. **命名行**：条目第 0/1/2 位会被标成 `#id`、头像、颜色数，不再是裸数组
## 2. **碎片合并**：`["ai","我"], ["ai","在"], ["ai","。"]` 这类被切碎的连续同 kind 片段
##    拼成一句显示（span 记在行上，选中时仍能精确到第一个片段去编辑）
## 3. **软换行**：长文本按可用宽度自动折行（最多 MAX_VIS_LINES 个视觉行），不再截断成一行
##
## 虚拟化：行高可变，用 row_top 前缀和 + 二分查找定位可见行，只画屏幕内那几行。

signal selection_changed(node_id: int)
signal edit_requested(node_id: int)

const Model := preload("res://addons/json_lens/json_lens_model.gd")

const LEFT_PAD := 8.0
const INDENT := 22.0
const ARROW_W := 16.0
const KIND_W := 58.0
const MAX_VIS_LINES := 8
const SHORT_FRAG := 6
const MAX_SPAN := 240
const BREAK_FLAGS := 3  # MANDATORY | WORD_BOUND（中文按字断行）

const K_OBJECT := 0
const K_ARRAY := 1
const K_STRING := 2

# 行数据
var row_entry := PackedInt32Array()
var row_first := PackedInt32Array()   # 事件首节点 id；-1 = 卡片头
var row_span := PackedInt32Array()
var row_kind := PackedStringArray()
var row_text := PackedStringArray()
var row_lines := PackedInt32Array()
var row_top := PackedInt32Array()

var model = null
var profile := {}
var entries := -1
var events_index := 3

var expanded := {}
var summaries := {}

var selected := -1
var selected_row := -1
var hovered_row := -1

var font: Font
var font_size := 13
var row_h := 18
var line_h := 18

var scroll: ScrollContainer

var c_bg_alt := Color(1, 1, 1, 0.025)
var c_sel := Color(0.24, 0.42, 0.68, 0.55)
var c_hover := Color(1, 1, 1, 0.05)
var c_head := Color("#e0e0e0")
var c_head_id := Color("#7ab0d8")
var c_dim := Color("#8a8a8a")
var c_guide := Color(1, 1, 1, 0.08)
var c_focus := Color(0.35, 0.6, 0.95, 0.7)
var c_hl := Color(1.0, 0.82, 0.2, 0.30)

var query := ""
var _kind_colors := {}
var _content_h := 1
var _last_view_w := -1.0


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 必须带 SIZE_EXPAND：ScrollContainer 只在子控件有 EXPAND 时才把它铺满视口，
	# 否则宽度 = custom_minimum_size（=0）—— 控件宽度 0 就完全收不到鼠标事件，
	# 表现就是「点行毫无反应、不高亮、详情栏一直是未选中」。
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	set_process(false)
	_build_kind_colors()


func configure(scroll_container: ScrollContainer) -> void:
	scroll = scroll_container
	var vb := scroll.get_v_scroll_bar()
	vb.value_changed.connect(_on_scrolled)
	var hb := scroll.get_h_scroll_bar()
	hb.value_changed.connect(_on_scrolled)
	resized.connect(_on_resized)


func apply_palette(dark: bool) -> void:
	if dark:
		c_bg_alt = Color(1, 1, 1, 0.022)
		c_sel = Color(0.24, 0.42, 0.68, 0.55)
		c_hover = Color(1, 1, 1, 0.05)
		c_head = Color("#e4e4e4")
		c_head_id = Color("#7ab0d8")
		c_dim = Color("#8a8a8a")
		c_guide = Color(1, 1, 1, 0.08)
		c_focus = Color(0.35, 0.6, 0.95, 0.7)
		c_hl = Color(1.0, 0.82, 0.2, 0.28)
	else:
		c_bg_alt = Color(0, 0, 0, 0.025)
		c_sel = Color(0.66, 0.82, 1.0, 0.75)
		c_hover = Color(0, 0, 0, 0.05)
		c_head = Color("#1f1f1f")
		c_head_id = Color("#0451a5")
		c_dim = Color("#7a7a7a")
		c_guide = Color(0, 0, 0, 0.1)
		c_focus = Color(0.15, 0.45, 0.85, 0.8)
		c_hl = Color(1.0, 0.85, 0.2, 0.55)
	_build_kind_colors()
	queue_redraw()


func _build_kind_colors() -> void:
	var dark := c_head.get_luminance() > 0.4
	_kind_colors = {
		"user": Color("#6fb3f2") if dark else Color("#0b5fa5"),
		"ai": Color("#ededed") if dark else Color("#1a1a1a"),
		"card": Color("#d7ba7d") if dark else Color("#8a6d1d"),
		"sub": Color("#b9b9b9") if dark else Color("#555555"),
		"meta": Color("#8f8f8f") if dark else Color("#777777"),
		"pill": Color("#9d9d9d") if dark else Color("#777777"),
		"model": Color("#b48ead") if dark else Color("#7a4d6d"),
		"composer": Color("#8f8f8f") if dark else Color("#777777"),
		"err": Color("#e06c75") if dark else Color("#b00020"),
		"code": Color("#98c379") if dark else Color("#116329"),
		"dot": Color("#8f8f8f") if dark else Color("#777777"),
		"name": Color("#e5c07b") if dark else Color("#8a6d1d"),
		"state": Color("#8f8f8f") if dark else Color("#777777"),
	}


func kind_color(kind: String) -> Color:
	if _kind_colors.has(kind):
		return _kind_colors[kind]
	return c_head


# ------------------------------------------------------------------ 度量

func refresh_metrics() -> void:
	if font == null:
		font = ThemeDB.fallback_font
	if font == null:
		row_h = 18
		line_h = 18
		return
	var h := font.get_height(font_size)
	line_h = int(ceil(h)) if h > 0.0 else 18
	row_h = line_h + 4
	rebuild()


func _text_width() -> float:
	var w := _view_w() - (LEFT_PAD + INDENT + ARROW_W + KIND_W + 12.0)
	return maxf(80.0, w)


func _measure_lines(text: String) -> int:
	if text.is_empty() or font == null:
		return 1
	var sz := font.get_multiline_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, _text_width(), font_size, MAX_VIS_LINES, BREAK_FLAGS)
	if line_h <= 0:
		return 1
	return clampi(int(ceil(sz.y / float(line_h))), 1, MAX_VIS_LINES)


# ------------------------------------------------------------------ 数据

func set_source(m, prof: Dictionary) -> void:
	model = m
	profile = prof
	entries = int(prof.get("entries", -1))
	events_index = int(prof.get("events_index", 3))
	expanded.clear()
	summaries.clear()
	selected = -1
	selected_row = -1
	hovered_row = -1
	rebuild()


func rebuild() -> void:
	row_entry = PackedInt32Array()
	row_first = PackedInt32Array()
	row_span = PackedInt32Array()
	row_kind = PackedStringArray()
	row_text = PackedStringArray()
	row_lines = PackedInt32Array()
	row_top = PackedInt32Array()
	if model == null or entries < 0 or font == null:
		_content_h = 1
		custom_minimum_size = Vector2(100, 1)
		queue_redraw()
		return

	var e: int = model.first_child[entries]
	while e >= 0:
		_add_entry(e)
		e = model.next_sibling[e]

	_recompute_tops()
	# 宽度交给 ScrollContainer（横向滚动禁用时子控件会被铺成视口宽）；
	# 自己撑宽会让内容比视口宽出「垂直滚动条」那么多，每行右边被裁掉。
	custom_minimum_size = Vector2(0.0, maxf(float(_content_h), 1.0))
	if selected >= 0:
		selected_row = _find_row_for(selected)
	queue_redraw()


func _add_entry(entry: int) -> void:
	row_entry.append(entry)
	row_first.append(-1)
	row_span.append(0)
	row_kind.append("")
	row_text.append(_summary(entry))
	row_lines.append(1)

	if not expanded.has(entry):
		return
	var evs: int = _child_at(entry, events_index)
	if evs < 0 or model.kinds[evs] != K_ARRAY:
		return
	var ev: int = model.first_child[evs]
	while ev >= 0:
		var kind := ""
		var text := ""
		var span := 0
		var last := ev
		var cur := ev
		while cur >= 0 and span < MAX_SPAN:
			var k := _event_kind(cur)
			var t := _event_text(cur)
			if span == 0:
				kind = k
				text = t
				span = 1
			else:
				# 只在「同 kind 且都是被切碎的短片段」时继续合并
				if k != kind or t.length() > SHORT_FRAG or text.length() > SHORT_FRAG * 4:
					break
				text += t
				span += 1
			last = cur
			cur = model.next_sibling[cur]
		row_entry.append(entry)
		row_first.append(ev)
		row_span.append(span)
		row_kind.append(kind)
		row_text.append(text)
		row_lines.append(_measure_lines(text))
		ev = model.next_sibling[last]


func _recompute_tops() -> void:
	var n := row_entry.size()
	row_top.resize(n)
	var y := 0
	for i in n:
		row_top[i] = y
		y += row_lines[i] * row_h
	_content_h = maxi(y, 1)


func _event_kind(ev: int) -> String:
	var k: int = model.first_child[ev]
	if k < 0 or model.kinds[k] != K_STRING:
		return "?"
	return model.texts[k]


func _event_text_node(ev: int) -> int:
	var k: int = model.first_child[ev]
	if k < 0:
		return -1
	var t: int = model.next_sibling[k]
	if t < 0:
		return -1
	return t


func _event_text(ev: int) -> String:
	var tn := _event_text_node(ev)
	if tn < 0:
		return ""
	return model.texts[tn]


func _child_at(parent: int, index: int) -> int:
	var c: int = model.first_child[parent]
	var i := 0
	while c >= 0:
		if i == index:
			return c
		i += 1
		c = model.next_sibling[c]
	return -1


## 卡片头摘要：该条目所有事件文本拼起来取前面一截（缓存，避免每次 rebuild 都重算）
func _summary(entry: int) -> String:
	if summaries.has(entry):
		return summaries[entry]
	var evs: int = _child_at(entry, events_index)
	var acc := ""
	if evs >= 0 and model.kinds[evs] == K_ARRAY:
		var ev: int = model.first_child[evs]
		var n := 0
		while ev >= 0 and acc.length() < 90 and n < 40:
			var t := _event_text(ev)
			if not t.is_empty():
				if acc != "":
					acc += " "
				acc += t
			ev = model.next_sibling[ev]
			n += 1
	acc = acc.replace("\n", " ").replace("\r", " ")
	if acc.length() > 90:
		acc = acc.substr(0, 90) + "…"
	summaries[entry] = acc
	return acc


## 卡片头的字段串：#id 头像 [颜色数] · N 条事件
func _head_text(entry: int) -> String:
	var parts := PackedStringArray()
	var c: int = model.first_child[entry]
	var i := 0
	while c >= 0 and i < 3:
		var k: int = model.kinds[c]
		if k == K_ARRAY:
			parts.append("[%d]" % model.counts[c])
		elif k == K_STRING:
			if model.texts[c] != "":
				parts.append(model.texts[c])
		else:
			parts.append(model.texts[c])
		c = model.next_sibling[c]
		i += 1
	var evs: int = _child_at(entry, events_index)
	var n: int = model.counts[evs] if evs >= 0 else 0
	parts.append("%d 条" % n)
	return "  ".join(parts)


# ------------------------------------------------------------------ 绘制

func _draw() -> void:
	if model == null or row_entry.is_empty() or font == null:
		return
	var top := float(scroll.scroll_vertical) if scroll != null else 0.0
	var vh := _view_h()
	var first := row_top.bsearch(int(top), true)
	if first >= row_top.size():
		first = row_top.size() - 1
	first = maxi(0, first - 1)
	for i in range(first, row_entry.size()):
		var y := float(row_top[i])
		if y > top + vh:
			break
		_draw_row(i, y)


func _draw_row(row: int, y: float) -> void:
	var h := float(row_lines[row] * row_h)
	var full := maxf(_view_w(), 10.0)
	if row_first[row] < 0 and int(y / maxf(1.0, float(row_h))) % 2 == 0:
		draw_rect(Rect2(0, y, full, h), c_bg_alt)
	if selected_row == row:
		draw_rect(Rect2(0, y, full, h), c_sel)
		if has_focus():
			draw_rect(Rect2(0, y, 2.0, h), c_focus)
	elif hovered_row == row:
		draw_rect(Rect2(0, y, full, h), c_hover)

	if row_first[row] < 0:
		_draw_head_row(row, y)
	else:
		_draw_event_row(row, y)


func _draw_head_row(row: int, y: float) -> void:
	var entry := row_entry[row]
	var base := _baseline(y, 1)
	draw_line(Vector2(0, y + float(row_h) - 1.0), Vector2(_view_w(), y + float(row_h) - 1.0), c_guide, 1.0)

	var x := LEFT_PAD
	var opened: bool = expanded.has(entry)
	_draw_arrow(Vector2(x + ARROW_W * 0.5, y + float(row_h) * 0.5), opened)
	x += ARROW_W

	# #id
	var idc: int = model.first_child[entry]
	var id_text: String = "#" + (model.texts[idc] if idc >= 0 else "?")
	x = _string(id_text, x, base, c_head_id)
	x += 10.0

	var head := _head_text(entry)
	x = _string(_clip(head, _view_w() - x - 220.0), x, base, c_dim)
	x += 10.0

	var summ := row_text[row]
	if summ != "":
		_string(_clip(summ, maxf(60.0, _view_w() - x - 12.0)), x, base, c_head)


func _draw_event_row(row: int, y: float) -> void:
	var kind := row_kind[row]
	var base := _baseline(y, 1)
	var x := LEFT_PAD + INDENT + ARROW_W

	# kind 标签
	var col := kind_color(kind)
	_string(kind, x, base, col)
	x += KIND_W

	# 文本（软换行）
	var text := row_text[row]
	if text.is_empty():
		return
	var width := maxf(80.0, _view_w() - x - 10.0)
	if query != "":
		var idx := text.findn(query)
		if idx >= 0 and idx < 200:
			# 命中高亮：先在整行底下画个色块（简化的行内高亮）
			pass
	draw_multiline_string(font, Vector2(x, base), text, HORIZONTAL_ALIGNMENT_LEFT, width,
		font_size, MAX_VIS_LINES, col, BREAK_FLAGS)


func _baseline(y: float, visual_line: int) -> float:
	var asc := float(font.get_ascent(font_size))
	return y + float((visual_line - 1) * line_h) + asc + 2.0


func _string(t: String, x: float, base_y: float, col: Color) -> float:
	if t.is_empty():
		return x
	var w := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if x < _view_w() + 40.0:
		draw_string(font, Vector2(x, base_y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
	return x + w


func _clip(t: String, max_w: float) -> String:
	if font == null or max_w <= 10.0:
		return t
	if font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_w:
		return t
	var lo := 0
	var hi := t.length()
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if font.get_string_size(t.substr(0, mid), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_w - 12.0:
			lo = mid
		else:
			hi = mid - 1
	return t.substr(0, lo) + "…"


func _draw_arrow(c: Vector2, opened: bool) -> void:
	var pts := PackedVector2Array()
	if opened:
		pts.push_back(Vector2(c.x - 4.0, c.y - 2.0))
		pts.push_back(Vector2(c.x + 4.0, c.y - 2.0))
		pts.push_back(Vector2(c.x, c.y + 3.0))
	else:
		pts.push_back(Vector2(c.x - 2.0, c.y - 4.0))
		pts.push_back(Vector2(c.x + 3.0, c.y))
		pts.push_back(Vector2(c.x - 2.0, c.y + 4.0))
	draw_colored_polygon(pts, c_dim)


## 可用宽度 = 滚动容器宽 - 垂直滚动条宽。控件自身的 size.x 含滚动条那一条，
## 拿它当换行宽度会让每行右端被滚动条盖住。
func _view_w() -> float:
	if scroll != null:
		var vb := scroll.get_v_scroll_bar()
		var extra := vb.size.x if vb.visible else 0.0
		return maxf(20.0, scroll.size.x - extra)
	return maxf(20.0, size.x)


func _view_h() -> float:
	if scroll != null:
		return scroll.size.y
	return size.y


func _on_scrolled(_v: float) -> void:
	queue_redraw()


func _on_resized() -> void:
	# 只有「视口宽度」变了才需要重算软换行行数。展开/折叠卡片只改高度，
	# 不能触发重算，否则会和 custom_minimum_size 互相打架、来回抖。
	if model == null:
		return
	var w := size.x
	if w <= 1.0:
		return
	if absf(w - _last_view_w) < 8.0:
		return
	_last_view_w = w
	rebuild()


# ------------------------------------------------------------------ 交互

func _row_at(pos_y: float) -> int:
	if row_top.is_empty():
		return -1
	var idx := row_top.bsearch(int(pos_y), true)
	if idx >= row_top.size():
		idx = row_top.size() - 1
	if idx > 0 and pos_y < float(row_top[idx]):
		idx -= 1
	if idx < 0 or idx >= row_top.size():
		return -1
	var y0 := float(row_top[idx])
	if pos_y < y0 or pos_y > y0 + float(row_lines[idx] * row_h):
		return -1
	return idx


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse(event)
	elif event is InputEventMouseMotion:
		var row := _row_at(event.position.y)
		if row != hovered_row:
			hovered_row = row
			queue_redraw()
	elif event is InputEventKey:
		_handle_key(event)


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		if hovered_row != -1:
			hovered_row = -1
			queue_redraw()


func _handle_mouse(e: InputEventMouseButton) -> void:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return
	if is_inside_tree():
		grab_focus()
	if not e.pressed:
		return
	var row := _row_at(e.position.y)
	if row < 0:
		return
	accept_event()
	hovered_row = row
	if row_first[row] < 0:
		var entry := row_entry[row]
		if e.double_click or e.position.x < LEFT_PAD + ARROW_W + 6.0:
			toggle_entry(entry)
			return
		# 单击卡片头：选中这张卡。如果它还是折叠的，顺手展开 ——
		# 否则整屏只有卡片头可点，看着就像「选不了节点」。
		selected = entry
		if not expanded.has(entry):
			expanded[entry] = true
			rebuild()
			selected_row = _find_row_for(entry)
		else:
			selected_row = row
		selection_changed.emit(entry)
		queue_redraw()
		return

	# 事件行：kind 标签和文本各自可选（都能直接编辑）
	var ev: int = row_first[row]
	var kind_x0: float = LEFT_PAD + INDENT + ARROW_W
	var node := -1
	if e.position.x >= kind_x0 and e.position.x < kind_x0 + KIND_W:
		var kn: int = model.first_child[ev]
		if kn >= 0:
			node = kn
	if node < 0:
		node = _event_text_node(ev)
	if node >= 0:
		selected_row = row
		selected = node
		selection_changed.emit(node)
		queue_redraw()
		if e.double_click:
			edit_requested.emit(node)


func toggle_entry(entry: int) -> void:
	if expanded.has(entry):
		expanded.erase(entry)
	else:
		expanded[entry] = true
	rebuild()
	# 折叠后把选中移到卡片头那一行
	selected_row = _find_row_for(selected) if selected >= 0 else -1


func expand_all() -> void:
	summaries_mark_expanded()
	rebuild()


func summaries_mark_expanded() -> void:
	var e: int = model.first_child[entries]
	while e >= 0:
		expanded[e] = true
		e = model.next_sibling[e]


func collapse_all() -> void:
	expanded.clear()
	rebuild()


func set_query(q: String) -> void:
	query = q
	queue_redraw()


func set_selected(node_id: int) -> void:
	selected = node_id
	selected_row = _find_row_for(node_id)
	if selected_row >= 0:
		ensure_visible(selected_row)
	queue_redraw()


## 从文本节点往上找到它所属的条目
func _entry_of(node_id: int) -> int:
	var cur := node_id
	while cur >= 0:
		var p: int = model.parents[cur]
		if p == entries:
			return cur
		cur = p
	return -1


func _find_row_for(node_id: int) -> int:
	if model == null or node_id < 0 or row_entry.is_empty():
		return -1
	var entry := _entry_of(node_id)
	if entry < 0:
		return -1
	# 该条目的行是连续的，从卡片头往后扫
	var start := row_entry.bsearch(entry, true)
	if start >= row_entry.size():
		return -1
	while start > 0 and row_entry[start - 1] == entry:
		start -= 1
	while start < row_entry.size() and row_entry[start] == entry:
		if row_first[start] < 0:
			if node_id == entry:
				return start
		else:
			# 该行覆盖 [r_first, r_first+span) 这些事件，看 node 是否落在其中
			var ev := row_first[start]
			var n := row_span[start]
			var i := 0
			while ev >= 0 and i < n:
				var tn := _event_text_node(ev)
				if tn == node_id:
					return start
				ev = model.next_sibling[ev]
				i += 1
		start += 1
	return -1


## 把视图滚到某个模型节点（搜索结果跳转用）
func reveal_node(node_id: int) -> void:
	var entry := _entry_of(node_id)
	if entry < 0:
		return
	if not expanded.has(entry):
		expanded[entry] = true
		rebuild()
	set_selected(node_id)


func ensure_visible(row: int) -> void:
	if scroll == null or row < 0 or row >= row_top.size():
		return
	var y0 := float(row_top[row])
	var y1 := y0 + float(row_lines[row] * row_h)
	var top := float(scroll.scroll_vertical)
	var vh := _view_h()
	if y0 < top:
		scroll.scroll_vertical = int(y0)
	elif y1 > top + vh:
		scroll.scroll_vertical = int(maxf(0.0, y1 - vh))


func _handle_key(e: InputEventKey) -> void:
	if not e.pressed or e.echo:
		return
	var n := row_entry.size()
	match e.keycode:
		KEY_UP:
			_move(-1)
		KEY_DOWN:
			_move(1)
		KEY_PAGEUP:
			_move(-int(maxf(1.0, _view_h() / float(row_h))))
		KEY_PAGEDOWN:
			_move(int(maxf(1.0, _view_h() / float(row_h))))
		KEY_HOME:
			if n > 0:
				_pick_row(0)
		KEY_END:
			if n > 0:
				_pick_row(n - 1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if selected_row >= 0 and row_first[selected_row] < 0:
				toggle_entry(row_entry[selected_row])
		KEY_RIGHT:
			if selected_row >= 0 and row_first[selected_row] < 0:
				toggle_entry(row_entry[selected_row])
		KEY_LEFT:
			if selected_row >= 0 and row_first[selected_row] >= 0:
				var entry := row_entry[selected_row]
				if expanded.has(entry):
					expanded.erase(entry)
					rebuild()
					set_selected(entry)
		KEY_C:
			if e.ctrl_pressed or e.meta_pressed:
				if selected_row >= 0:
					DisplayServer.clipboard_set(row_text[selected_row])
			else:
				return
		_:
			return
	accept_event()


func _move(delta: int) -> void:
	if row_entry.is_empty():
		return
	var row := selected_row
	if row < 0:
		row = 0
	else:
		row = clampi(row + delta, 0, row_entry.size() - 1)
	_pick_row(row)


func _pick_row(row: int) -> void:
	selected_row = row
	if row_first[row] < 0:
		selected = row_entry[row]
	else:
		selected = _event_text_node(row_first[row])
	ensure_visible(row)
	queue_redraw()
	selection_changed.emit(selected)
