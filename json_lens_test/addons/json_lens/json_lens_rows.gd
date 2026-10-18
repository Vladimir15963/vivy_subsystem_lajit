@tool
extends Control

## JSON Lens —— 虚拟化行渲染器（带压缩显示）
##
## 只有「一屏」的工作量：控件高度 = 可见行数 × 行高（可能是几千万像素，
## ScrollContainer 负责滚动条），_draw() 只画当前滚动位置命中的那 40 来行。
## 所以 100 万行和 100 行的绘制开销完全一样。
##
## 在此之上做两层压缩，都是「让一屏装下更多信息」：
##
## 1. 行内合并（INLINE）：一个子树如果全是标量且不超字符预算，
##    就把它整段摊在同一行上显示 ——  `0: { id: 0, name: "x", ok: true }`
##    它仍然占 1 行，但你不必再展开就能读到内容。
##
## 2. 重复收缩（GROUP）：数组里连续一段「同构」的元素（形状签名相同）
##    收成一行 ——  `[0..799] ×800  { id, name, level, … }`
##    点箭头可以就地展开成逐行。
##
## 行数据用三个平行数组表示：rows（首节点 id）/ row_start（组起始下标）/ row_len（组长度）。

signal selection_changed(node_id: int)
signal row_activated(node_id: int)
signal edit_requested(node_id: int)

const K_OBJECT := 0
const K_ARRAY := 1
const K_STRING := 2
const K_NUMBER := 3
const K_BOOL := 4
const K_NULL := 5

const LEFT_PAD := 8.0
const INDENT := 14.0
const ARROW_W := 13.0
const MAX_GUIDES := 16
const MAX_TEXT := 400
const MAX_CONTENT_W := 24000.0

const COMPRESS_OFF := 0
const COMPRESS_INLINE := 1
const COMPRESS_GROUP := 2

const INLINE_BUDGET := 130
const GROUP_MIN := 3
const MAX_INLINE_DEPTH := 40
const MAX_EXPAND_BUDGET := 60000

var model = null
var rows := PackedInt32Array()
var row_start := PackedInt32Array()
var row_len := PackedInt32Array()

var expanded := PackedByteArray()
var auto_depth := 2
var explicit := false

var compress := COMPRESS_GROUP
var _expanded_members := {}
var _expanded_inline := {}

var selected := -1
var selected_row := -1
var hovered_row := -1

var search_mode := false
var query := ""

var font: Font
var font_size := 13
var row_h := 18

var scroll: ScrollContainer

var c_key := Color("#9cdcfe")
var c_str := Color("#ce9178")
var c_num := Color("#b5cea8")
var c_bool := Color("#569cd6")
var c_null := Color("#808080")
var c_punct := Color("#c8c8c8")
var c_dim := Color("#7a7a7a")
var c_idx := Color("#9a9a9a")
var c_guide := Color(1, 1, 1, 0.06)
var c_sel := Color(0.24, 0.42, 0.68, 0.55)
var c_hover := Color(1, 1, 1, 0.05)
var c_hl := Color(1.0, 0.82, 0.2, 0.30)
var c_focus := Color(0.35, 0.6, 0.95, 0.7)
var c_badge := Color("#d7ba7d")

var _content_w := 100.0
var _width_pending := false
var _path_cache := {}


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 带 SIZE_EXPAND：内容比视口窄时也铺满视口，否则控件右侧一条空白区收不到点击
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	set_process(false)


func configure(scroll_container: ScrollContainer) -> void:
	scroll = scroll_container
	var vb := scroll.get_v_scroll_bar()
	vb.value_changed.connect(_on_scrolled)
	var hb := scroll.get_h_scroll_bar()
	hb.value_changed.connect(_on_scrolled)
	refresh_metrics()


func refresh_metrics() -> void:
	if font == null:
		font = ThemeDB.fallback_font
	if font == null:
		row_h = 18
		return
	var h := font.get_height(font_size)
	row_h = int(ceil(h + 4.0)) if h > 0.0 else 18
	_content_w = 100.0
	rebuild()


func apply_palette(dark: bool) -> void:
	if dark:
		c_key = Color("#9cdcfe")
		c_str = Color("#ce9178")
		c_num = Color("#b5cea8")
		c_bool = Color("#569cd6")
		c_null = Color("#808080")
		c_punct = Color("#c8c8c8")
		c_dim = Color("#7a7a7a")
		c_idx = Color("#9a9a9a")
		c_guide = Color(1, 1, 1, 0.07)
		c_sel = Color(0.24, 0.42, 0.68, 0.55)
		c_hover = Color(1, 1, 1, 0.05)
		c_hl = Color(1.0, 0.82, 0.2, 0.28)
		c_focus = Color(0.35, 0.6, 0.95, 0.7)
		c_badge = Color("#d7ba7d")
	else:
		c_key = Color("#0451a5")
		c_str = Color("#a31515")
		c_num = Color("#098658")
		c_bool = Color("#0000c0")
		c_null = Color("#7a7a7a")
		c_punct = Color("#333333")
		c_dim = Color("#8a8a8a")
		c_idx = Color("#6a6a6a")
		c_guide = Color(0, 0, 0, 0.09)
		c_sel = Color(0.66, 0.82, 1.0, 0.75)
		c_hover = Color(0, 0, 0, 0.05)
		c_hl = Color(1.0, 0.85, 0.2, 0.55)
		c_focus = Color(0.15, 0.45, 0.85, 0.8)
		c_badge = Color("#8a6d1d")
	queue_redraw()


# ------------------------------------------------------------------ 数据

func set_model(m) -> void:
	model = m
	rows = PackedInt32Array()
	row_start = PackedInt32Array()
	row_len = PackedInt32Array()
	expanded = PackedByteArray()
	explicit = false
	auto_depth = 2
	selected = -1
	selected_row = -1
	hovered_row = -1
	search_mode = false
	query = ""
	_expanded_members.clear()
	_expanded_inline.clear()
	_content_w = 100.0
	_path_cache.clear()
	rebuild()


func set_search(model_ref, hits: PackedInt32Array, q: String) -> void:
	model = model_ref
	search_mode = true
	query = q
	rows = hits
	row_start = PackedInt32Array()
	row_len = PackedInt32Array()
	row_start.resize(hits.size())
	row_len.resize(hits.size())
	for i in hits.size():
		row_start[i] = -1
		row_len[i] = 1
	selected_row = -1
	_path_cache.clear()
	_content_w = 100.0
	rebuild()


func show_tree() -> void:
	if not search_mode:
		return
	search_mode = false
	rebuild()


func set_compress(mode: int) -> void:
	compress = mode
	rebuild()


func is_expanded(id: int) -> bool:
	if explicit:
		return expanded[id] == 1
	return model.depths[id] < auto_depth


func set_expanded(id: int, value: bool) -> void:
	_materialize_expansion()
	expanded[id] = 1 if value else 0


func _materialize_expansion() -> void:
	if explicit:
		return
	var n: int = model.total
	expanded = PackedByteArray()
	expanded.resize(n)
	var d: int = auto_depth
	for i in n:
		expanded[i] = 1 if (model.depths[i] < d and model.counts[i] > 0) else 0
	explicit = true


func expand_to_depth(d: int) -> void:
	if model == null:
		return
	explicit = false
	expanded = PackedByteArray()
	_expanded_inline.clear()
	auto_depth = d
	rebuild()


func collapse_all() -> void:
	expand_to_depth(1)


func expand_all() -> void:
	expand_to_depth(1 << 20)


## 这棵子树当前是否「压成一行显示」（用户没有单独把它展开）
## 根节点永远不合并：否则一份小 JSON 会整份变成一行，反而没法导航。
func is_inline_merged(id: int) -> bool:
	if compress == COMPRESS_OFF:
		return false
	if id == model.root:
		return false
	if _expanded_inline.has(id):
		return false
	return model.is_flat(id, INLINE_BUDGET)


## 能不能往下走一层（决定这一行后面要不要继续出行）
func _can_descend(id: int) -> bool:
	if not model.is_container(id) or model.counts[id] == 0:
		return false
	if is_inline_merged(id):
		return false
	return is_expanded(id)


func rebuild() -> void:
	# 内容宽度必须按「当前可见行」重新量。若只增不减，反复折叠/展开会让内容宽度
	# 一路涨到 MAX_CONTENT_W，表现为右边多出一大片空白的横向滚动区。
	# 基准取「视口宽」而不是 0：这样内容不宽于视口时不会挂着一条横向滚动条，
	# 也不会每次展开/折叠都让滚动条闪一下；真有更宽的行时会在绘制里被量出来。
	_content_w = maxf(_view_w(), 100.0)
	if search_mode:
		if selected >= 0:
			selected_row = rows.find(selected)
		_apply_size()
		queue_redraw()
		return
	rows = PackedInt32Array()
	row_start = PackedInt32Array()
	row_len = PackedInt32Array()
	if model != null and model.total > 0 and model.root >= 0:
		_walk_visible()
	if selected >= 0:
		selected_row = rows.find(selected)
	_apply_size()
	queue_redraw()


func _emit(id: int, start: int, length: int) -> void:
	rows.append(id)
	row_start.append(start)
	row_len.append(length)


func _walk_visible() -> void:
	_emit(model.root, -1, 1)
	if not _can_descend(model.root):
		return
	# 帧：[下一个待处理子节点, 父节点 id, 该子节点在父中的下标, 组结束下标(-1=不在组内)]
	var stack: Array = [[model.first_child[model.root], model.root, 0, -1]]
	while not stack.is_empty():
		var f: Array = stack[stack.size() - 1]
		var cid: int = f[0]
		if cid < 0:
			stack.pop_back()
			continue
		var pid: int = f[1]
		var index: int = f[2]
		var limit: int = f[3]
		if limit >= 0 and index > limit:
			stack.pop_back()
			continue
		f[0] = model.next_sibling[cid]
		f[2] = index + 1

		# —— 重复收缩：向后扫同构的一段（组内成员用 limit 标记，不再二次分组）
		var run := 1
		var last := cid
		# 注意：这里不能因为「组已展开」就跳过分组，否则组头会消失、成员变成散行，
		# 就再也点不回收起了。展开状态只决定要不要在组头后面接成员行。
		if compress == COMPRESS_GROUP and limit < 0 and model.kinds[pid] == K_ARRAY:
			var sc: int = model.next_sibling[cid]
			while sc >= 0 and _same_shape(cid, sc):
				run += 1
				last = sc
				sc = model.next_sibling[sc]
		if run >= GROUP_MIN:
			# 组头行永远保留：展开时成员行接在它下面，这样随时能点组头再收回去
			_emit(cid, index, run)
			if _expanded_members.has(cid):
				stack.push_back([cid, pid, index, index + run - 1])
			f[0] = model.next_sibling[last]
			f[2] = index + run
			continue

		_emit(cid, -1, 1)
		if _can_descend(cid):
			stack.push_back([model.first_child[cid], cid, 0, -1])


## 两个相邻元素算不算「同构」：容器比形状签名，标量要求类型和值都相同。
func _same_shape(a: int, b: int) -> bool:
	var ka: int = model.kinds[a]
	if ka == K_OBJECT or ka == K_ARRAY:
		return model.kinds[b] == ka and model.sig[a] == model.sig[b]
	return model.kinds[b] == ka and model.texts[a] == model.texts[b]


func _apply_size() -> void:
	var h := float(rows.size() * row_h)
	if h < 1.0:
		h = 1.0
	custom_minimum_size = Vector2(maxf(_content_w, 100.0), h)


func _apply_content_width() -> void:
	_width_pending = false
	if model == null:
		return
	var w := minf(_content_w, MAX_CONTENT_W)
	if absf(custom_minimum_size.x - maxf(w, 100.0)) > 0.5:
		custom_minimum_size = Vector2(maxf(w, 100.0), custom_minimum_size.y)


func _on_scrolled(_v: float) -> void:
	queue_redraw()


# ------------------------------------------------------------------ 绘制

func _draw() -> void:
	if model == null or rows.is_empty() or font == null:
		return
	var vh := _view_h()
	var top := float(scroll.scroll_vertical) if scroll != null else 0.0
	var first := int(top / float(row_h))
	if first < 0:
		first = 0
	if first >= rows.size():
		return
	var span := int(ceil(vh / float(row_h))) + 2
	var last := mini(rows.size(), first + span)
	var sx := float(scroll.scroll_horizontal) if scroll != null else 0.0
	var vw := _view_w()
	for i in range(first, last):
		var y := float(i * row_h)
		if search_mode:
			_draw_search_row(i, y, sx, vw)
		elif row_len[i] > 1:
			_draw_group_row(i, y, sx, vw)
		else:
			_draw_row(i, y, sx, vw)


func _view_h() -> float:
	if scroll != null:
		return scroll.size.y
	return size.y


func _view_w() -> float:
	# 注意要扣掉垂直滚动条的宽度：scroll.size.x 是「外框宽」，
	# 直接拿它当可用宽会让内容恒比视口宽十几像素，横向滚动条一直挂着。
	if scroll != null:
		var vb := scroll.get_v_scroll_bar()
		var extra := vb.size.x if vb.visible else 0.0
		return maxf(20.0, scroll.size.x - extra)
	return size.x


func _draw_backdrop(row: int, y: float, h: float, _vw: float) -> void:
	var full := maxf(size.x, _view_w())
	if selected_row == row:
		draw_rect(Rect2(0.0, y, full, h), c_sel)
		if has_focus():
			draw_rect(Rect2(0.0, y, 2.0, h), c_focus)
	elif hovered_row == row:
		draw_rect(Rect2(0.0, y, full, h), c_hover)


func _draw_row(row: int, y: float, sx: float, vw: float) -> void:
	var h := float(row_h)
	_draw_backdrop(row, y, h, vw)
	var id := rows[row]

	var d: int = model.depths[id]
	for lv in mini(d, MAX_GUIDES):
		var gx := LEFT_PAD + float(lv) * INDENT + 4.0
		draw_line(Vector2(gx, y), Vector2(gx, y + h), c_guide, 1.0)

	var x := LEFT_PAD + float(d) * INDENT
	var k: int = model.kinds[id]
	var is_c := (k == K_OBJECT or k == K_ARRAY)
	var merged := is_c and is_inline_merged(id)
	var opened := false
	if is_c and model.counts[id] > 0:
		opened = not merged and is_expanded(id)
		_draw_arrow(Vector2(x + ARROW_W * 0.5, y + h * 0.5), opened)
	x += ARROW_W

	var limit := sx + vw + 240.0

	var p: int = model.parents[id]
	if p >= 0:
		if model.kinds[p] == K_ARRAY:
			x = _text(str(model.index_in_parent[id]), x, y, h, c_idx, limit, false)
		else:
			x = _text('"' + model.keys[id] + '"', x, y, h, c_key, limit, true)
		x = _text(": ", x, y, h, c_punct, limit, false)

	if merged:
		_draw_inline(id, x, y, h, limit, 0)
	else:
		_draw_value(id, k, is_c, opened, x, y, h, limit)


## 把一整棵（全标量的）子树上摊在一行里画出来。
func _draw_inline(id: int, x: float, y: float, h: float, limit: float, depth: int) -> float:
	if depth > MAX_INLINE_DEPTH:
		return _text("…", x, y, h, c_dim, limit, false)
	var k: int = model.kinds[id]
	if k == K_OBJECT or k == K_ARRAY:
		var object := k == K_OBJECT
		x = _text("{" if object else "[", x, y, h, c_punct, limit, false)
		var c: int = model.first_child[id]
		var first := true
		while c >= 0:
			if x > limit:
				break
			if not first:
				x = _text(", ", x, y, h, c_dim, limit, false)
			first = false
			if object:
				x = _text('"' + model.keys[c] + '"', x, y, h, c_key, limit, true)
				x = _text(": ", x, y, h, c_punct, limit, false)
			x = _draw_inline(c, x, y, h, limit, depth + 1)
			c = model.next_sibling[c]
		return _text("}" if object else "]", x, y, h, c_punct, limit, false)
	if k == K_STRING:
		return _text('"' + _short(model.texts[id]) + '"', x, y, h, c_str, limit, true)
	if k == K_NUMBER:
		return _text(_short(model.texts[id]), x, y, h, c_num, limit, true)
	if k == K_BOOL:
		return _text(model.texts[id], x, y, h, c_bool, limit, false)
	return _text("null", x, y, h, c_null, limit, false)


func _draw_value(id: int, k: int, is_c: bool, opened: bool, x: float, y: float, h: float, limit: float) -> void:
	if is_c:
		var empty: bool = model.counts[id] == 0
		var opener := "{" if k == K_OBJECT else "["
		var closer := "}" if k == K_OBJECT else "]"
		if empty:
			_text(opener + closer, x, y, h, c_punct, limit, false)
		elif opened:
			var nx := _text(opener, x, y, h, c_punct, limit, false)
			_text(model.count_label(id), nx + 6.0, y, h, c_dim, limit, false)
		else:
			var nx2 := _text(opener + "…" + closer, x, y, h, c_punct, limit, false)
			_text(model.count_label(id), nx2 + 6.0, y, h, c_dim, limit, false)
	elif k == K_STRING:
		_text('"' + _short(model.texts[id]) + '"', x, y, h, c_str, limit, true)
	elif k == K_NUMBER:
		_text(_short(model.texts[id]), x, y, h, c_num, limit, true)
	elif k == K_BOOL:
		_text(model.texts[id], x, y, h, c_bool, limit, false)
	else:
		_text("null", x, y, h, c_null, limit, false)


## 一组同构元素收起来后的一行
func _draw_group_row(row: int, y: float, sx: float, vw: float) -> void:
	var h := float(row_h)
	_draw_backdrop(row, y, h, vw)
	var id := rows[row]
	var start := row_start[row]
	var n := row_len[row]

	var d: int = model.depths[id]
	for lv in mini(d, MAX_GUIDES):
		var gx := LEFT_PAD + float(lv) * INDENT + 4.0
		draw_line(Vector2(gx, y), Vector2(gx, y + h), c_guide, 1.0)

	var x := LEFT_PAD + float(d) * INDENT
	_draw_arrow(Vector2(x + ARROW_W * 0.5, y + h * 0.5), _expanded_members.has(id))
	x += ARROW_W
	var limit := sx + vw + 240.0

	x = _text("[%d..%d]" % [start, start + n - 1], x, y, h, c_idx, limit, false)
	x = _text("  ×%d  " % n, x, y, h, c_badge, limit, false)
	x = _text(_group_preview(id), x, y, h, c_dim, limit, false)


func _group_preview(id: int) -> String:
	var k: int = model.kinds[id]
	if k == K_OBJECT:
		var parts := PackedStringArray()
		var c: int = model.first_child[id]
		var i := 0
		while c >= 0 and i < 4:
			parts.append(model.keys[c])
			c = model.next_sibling[c]
			i += 1
		if model.counts[id] > 4:
			parts.append("…")
		return "{" + ", ".join(parts) + "}"
	if k == K_ARRAY:
		return "[" + model.count_label(id) + "]"
	return _short(model.texts[id])


func _draw_search_row(row: int, y: float, sx: float, vw: float) -> void:
	var h := float(row_h)
	_draw_backdrop(row, y, h, vw)
	var id := rows[row]

	var x := LEFT_PAD
	var limit := sx + vw + 240.0
	x = _text(_path_of(id), x, y, h, c_dim, limit, false)
	x = _text("  ", x, y, h, c_dim, limit, false)

	var p: int = model.parents[id]
	if p >= 0:
		if model.kinds[p] == K_ARRAY:
			x = _text(str(model.index_in_parent[id]), x, y, h, c_idx, limit, false)
		else:
			x = _text('"' + model.keys[id] + '"', x, y, h, c_key, limit, true)
		x = _text(": ", x, y, h, c_punct, limit, false)

	var k: int = model.kinds[id]
	if model.is_container(id) and is_inline_merged(id):
		_draw_inline(id, x, y, h, limit, 0)
	else:
		_draw_value(id, k, k == K_OBJECT or k == K_ARRAY, false, x, y, h, limit)


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


func _text(t: String, x: float, y: float, h: float, col: Color, limit: float, highlight: bool) -> float:
	if t.is_empty():
		return x
	var w := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if w > _content_w and x + w > _content_w:
		_content_w = minf(x + w, MAX_CONTENT_W)
		if not _width_pending:
			_width_pending = true
			call_deferred("_apply_content_width")
	if x < limit:
		var base_y := y + (h - float(font.get_height(font_size))) * 0.5 + float(font.get_ascent(font_size))
		if highlight and query != "":
			var idx := t.findn(query)
			if idx >= 0:
				var pre := t.substr(0, idx)
				var pw := font.get_string_size(pre, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
				var mw := font.get_string_size(t.substr(idx, query.length()), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
				draw_rect(Rect2(x + pw, y + 1.0, mw, h - 2.0), c_hl)
		draw_string(font, Vector2(x, base_y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
	return x + w


func _short(s: String) -> String:
	var t := s
	if t.length() > MAX_TEXT:
		t = t.substr(0, MAX_TEXT) + "…"
	t = t.replace("\r\n", "\\n").replace("\n", "\\n").replace("\r", "\\n").replace("\t", "\\t")
	return t


func _path_of(id: int) -> String:
	if _path_cache.has(id):
		return _path_cache[id]
	var p: String = model.path_of(id)
	if _path_cache.size() > 512:
		_path_cache.clear()
	_path_cache[id] = p
	return p


# ------------------------------------------------------------------ 交互

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse(event)
	elif event is InputEventMouseMotion:
		_handle_motion(event)
	elif event is InputEventKey:
		_handle_key(event)


func _handle_motion(e: InputEventMouseMotion) -> void:
	var row := int(e.position.y / float(row_h))
	if row < 0 or row >= rows.size():
		row = -1
	if row != hovered_row:
		hovered_row = row
		queue_redraw()


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
	var row := int(e.position.y / float(row_h))
	if row < 0 or row >= rows.size():
		return
	hovered_row = row
	accept_event()

	if search_mode:
		if row != selected_row:
			_select_row(row)
		if e.double_click:
			row_activated.emit(rows[row])
		return

	if row_len[row] > 1:
		if e.double_click or _hit_arrow(rows[row], e.position.x):
			toggle_group(row)
			return
		_select_row(row)
		return

	var id := rows[row]
	if _hit_arrow(id, e.position.x):
		_toggle(id)
		return
	if e.double_click:
		if model.is_container(id):
			_toggle(id)
		else:
			edit_requested.emit(id)
		return
	_select_row(row)


func _hit_arrow(id: int, x: float) -> bool:
	if not model.is_container(id):
		return false
	if model.counts[id] == 0:
		return false
	var ax := LEFT_PAD + float(model.depths[id]) * INDENT
	return x >= ax - 3.0 and x <= ax + ARROW_W + 3.0


func _toggle(id: int) -> void:
	if not model.is_container(id) or model.counts[id] == 0:
		return
	if _expanded_inline.has(id):
		# 从「逐行展开」收回到「压成一行」
		_expanded_inline.erase(id)
		rebuild()
		return
	if is_inline_merged(id):
		_expanded_inline[id] = true
		set_expanded(id, true)
		rebuild()
		return
	set_expanded(id, not is_expanded(id))
	rebuild()


## 组行：展开 / 收起（组头行永远在，所以两个方向都能来回切）
func toggle_group(row: int) -> void:
	if row < 0 or row >= rows.size() or row_len[row] <= 1:
		return
	var first: int = rows[row]
	var n: int = row_len[row]
	if _expanded_members.has(first):
		_collapse_run(first, n)
	else:
		_expand_run(first, n)
	rebuild()


func expand_group(row: int) -> void:
	if row < 0 or row >= rows.size() or row_len[row] <= 1:
		return
	_expand_run(rows[row], row_len[row])
	rebuild()


func _expand_run(first_id: int, length: int) -> void:
	var c := first_id
	var i := 0
	while c >= 0 and i < length:
		_expanded_members[c] = true
		c = model.next_sibling[c]
		i += 1


func _collapse_run(first_id: int, length: int) -> void:
	var c := first_id
	var i := 0
	while c >= 0 and i < length:
		_expanded_members.erase(c)
		c = model.next_sibling[c]
		i += 1


func collapse_groups() -> void:
	_expanded_members.clear()
	rebuild()


func _select_row(row: int) -> void:
	selected_row = row
	selected = rows[row]
	ensure_visible(row)
	queue_redraw()
	selection_changed.emit(selected)


func select_node(id: int, ensure: bool = true) -> void:
	selected = id
	selected_row = rows.find(id)
	if ensure and selected_row >= 0:
		ensure_visible(selected_row)
	queue_redraw()
	selection_changed.emit(id)


func get_selected() -> int:
	return selected


func row_is_group(row: int) -> bool:
	return row >= 0 and row < row_len.size() and row_len[row] > 1


func ensure_visible(row: int) -> void:
	if scroll == null or row < 0:
		return
	var y0 := float(row * row_h)
	var y1 := y0 + float(row_h)
	var top := float(scroll.scroll_vertical)
	var vh := _view_h()
	if y0 < top:
		scroll.scroll_vertical = int(y0)
	elif y1 > top + vh:
		scroll.scroll_vertical = int(y1 - vh)


## 从搜索结果跳回树视图：展开所有祖先，并把它所在的同构组也展开。
func reveal_node(id: int) -> void:
	if model == null:
		return
	search_mode = false
	var a := id
	while a >= 0:
		if model.counts[a] > 0:
			set_expanded(a, true)
			_expanded_inline[a] = true
		a = model.parents[a]
	var p: int = model.parents[id]
	if p >= 0 and model.kinds[p] == K_ARRAY:
		var c: int = model.first_child[p]
		var n := 0
		while c >= 0 and n < MAX_EXPAND_BUDGET:
			_expanded_members[c] = true
			c = model.next_sibling[c]
			n += 1
	rebuild()
	select_node(id)


func _handle_key(e: InputEventKey) -> void:
	if not e.pressed or e.echo:
		return
	var handled := true
	match e.keycode:
		KEY_UP:
			_move_selection(-1)
		KEY_DOWN:
			_move_selection(1)
		KEY_PAGEUP:
			_move_selection(-int(maxf(1.0, _view_h() / float(row_h))))
		KEY_PAGEDOWN:
			_move_selection(int(maxf(1.0, _view_h() / float(row_h))))
		KEY_HOME:
			if rows.size() > 0:
				_select_row(0)
		KEY_END:
			if rows.size() > 0:
				_select_row(rows.size() - 1)
		KEY_LEFT:
			_key_left()
		KEY_RIGHT:
			_key_right()
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if selected_row >= 0:
				if row_is_group(selected_row):
					toggle_group(selected_row)
				elif model != null and model.is_container(selected):
					_toggle(selected)
				else:
					edit_requested.emit(selected)
			else:
				handled = false
		KEY_C:
			if e.ctrl_pressed or e.meta_pressed:
				_copy_selected()
			else:
				handled = false
		_:
			handled = false
	if handled:
		accept_event()


func _move_selection(delta: int) -> void:
	if rows.is_empty():
		return
	var row := selected_row
	if row < 0:
		row = 0
	else:
		row = clampi(row + delta, 0, rows.size() - 1)
	_select_row(row)


func _key_left() -> void:
	if selected_row >= 0 and row_is_group(selected_row):
		# 组行按左键：把这一组收起来
		var first := rows[selected_row]
		_collapse_run(first, row_len[selected_row])
		rebuild()
		select_node(first, false)
		return
	if selected < 0:
		return
	if model.is_container(selected) and model.counts[selected] > 0:
		if _expanded_inline.has(selected):
			_expanded_inline.erase(selected)
			rebuild()
			return
		if not is_inline_merged(selected) and is_expanded(selected):
			_toggle(selected)
			return
	var p: int = model.parents[selected]
	if p >= 0:
		select_node(p)


func _key_right() -> void:
	if selected_row >= 0 and row_is_group(selected_row):
		expand_group(selected_row)
		return
	if selected < 0:
		return
	if model.is_container(selected) and model.counts[selected] > 0:
		if is_inline_merged(selected) or not is_expanded(selected):
			_toggle(selected)
			return
		if selected_row + 1 < rows.size():
			_select_row(selected_row + 1)


func _copy_selected() -> void:
	if selected < 0:
		return
	var text := ""
	if model.is_container(selected):
		text = model.to_json(selected, 262144)
	else:
		text = model.texts[selected]
	DisplayServer.clipboard_set(text)
