extends "res://vivd_windows/vivd_window.gd"
## 多行文本阅读窗口 —— 在独立窗口里显示、滚动阅读多行文本。
##
## 正文用 [RichTextLabel]，[b]默认按 BBCode 解析[/b]，所以
## [code][b][i][color=…][center][img]…[/code] 这些标签直接能用
## （对齐也走 BBCode 的 [code][center][/code]，[RichTextLabel] 本身没有对齐属性）。
##
## [b]用法[/b]
## [codeblock]
## VivdWindowsNode.add_window("reader", "text", {
##     "title": "序章",
##     "text": "第一行\n第二行\n\n空行也会保留。",
##     "position": Vector2i(400, 120),
##     "size": Vector2i(640, 360),
##     "font_size": 20,
## })
##
## VivdWindowsNode.call_window_method("reader", "append_line", ["后面又想起一件事……"])
## VivdWindowsNode.call_window_method("reader", "scroll_to_bottom")
## [/codeblock]
##
## [b]逐字显示（打字机）[/b]：把 [code]speed[/code] 设成正数即可，单位是[b]字/秒[/b]；
## [code]speed[/code] 为 0（默认）就是一次性全部显示。
## 显示过程中调 [method reveal_all] 可以立刻补全 —— 这是「点击继续」的标准做法：
## [codeblock]
## VivdWindowsNode.call_window_method("reader", "reveal_all")
## [/codeblock]
## 补全时会发 [signal reveal_finished]；[code]speed[/code] 为 0 时，每次
## [method set_text] / [method append] 之后也会立刻发一次，语义统一成
## 「正文已经全部可见」。
##
## [b]这个窗口没有翻页[/b]，长文本靠滚动阅读（滚轮、滚动条都能用）。
## 真需要翻页的话：拿 [method get_label] 得到 [RichTextLabel]，
## 结合 [code]get_content_height()[/code] / [method get_scroll_ratio] 自己切。
##
## [b]注意[/b]：窗口的淡入淡出作用在直接子节点 [code]Background[/code] 上，
## 所以改背景请用 [code]bg_color[/code] 或直接改那个节点的颜色，别删它。

## 正文内容变了（[method set_text] / [method append] / [method clear_text] 之后）。
signal text_changed()
## 正文已经全部可见（逐字显示播完，或本来就是一次性显示）。
signal reveal_finished()
## 阅读进度到达底部。从「未到底」变成「到底」时触发一次。
signal reached_bottom()

## 正文原文（BBCode 形式，即没有被逐字显示截断的完整内容）。
var text_content := ""
## 是否按 BBCode 解析正文。
var bbcode := true
## 逐字显示速度，单位「字/秒」。0 = 一次性全部显示。
var reveal_speed := 0.0
## 追加内容时是否自动滚到底部。
var auto_scroll := false

@onready var _background: ColorRect = get_node_or_null("Background")
@onready var _margin: MarginContainer = get_node_or_null("Background/Margin")
@onready var _body: RichTextLabel = get_node_or_null("Background/Margin/Body")

var _reveal_tween: Tween = null
var _revealing := false
var _scroll_hooked := false
var _was_at_bottom := true


# ─────────────────────────────────────────────────────────────────────────────
#  vivd 生命周期
# ─────────────────────────────────────────────────────────────────────────────

func setup(config: Dictionary) -> void:
	if _body == null:
		push_warning("[text_window] 场景里找不到 Background/Margin/Body，无法显示文字")
		return

	bbcode = bool(config.get("bbcode", true))
	_body.bbcode_enabled = bbcode

	_apply_style(config)
	_hook_scroll()

	set_auto_scroll(bool(config.get("auto_scroll", false)))
	reveal_speed = maxf(float(config.get("speed", 0.0)), 0.0)

	var content := str(config.get("text", ""))
	if not content.is_empty():
		set_text(content)


func teardown() -> void:
	_kill_reveal()


# ─────────────────────────────────────────────────────────────────────────────
#  内容
# ─────────────────────────────────────────────────────────────────────────────

## 整体替换正文。[param value] 是 BBCode 字符串（[member bbcode] 为 false 时按纯文本处理）。
func set_text(value: String) -> void:
	text_content = value
	_rebuild()


## 在末尾追加一段（不自动换行，要换行用 [method append_line] 或自己带 [code]\n[/code]）。
func append(value: String) -> void:
	if _body == null:
		return
	text_content += value
	if bbcode:
		_body.append_text(value)
	else:
		_body.add_text(value)
	_after_content_change()


## 在末尾追加一行（正文非空时自动补一个换行）。
func append_line(value: String) -> void:
	append(("\n" if not text_content.is_empty() else "") + value)


## 清空正文。
func clear_text() -> void:
	text_content = ""
	_rebuild()


## 当前正文原文。
func get_text() -> String:
	return text_content


## 正文渲染出来的行数（需要已经排过版，通常下一帧才准）。
func get_line_count() -> int:
	return _body.get_line_count() if _body != null else 0


## 拿到内部的 [RichTextLabel]，做上面没包过的高级操作
## （[code]get_content_height()[/code]、[code]get_parsed_text()[/code]、加 meta 链接等）。
func get_label() -> RichTextLabel:
	return _body


# ─────────────────────────────────────────────────────────────────────────────
#  逐字显示
# ─────────────────────────────────────────────────────────────────────────────

## 立刻补全到全部可见。正在播的话会中断并补发 [signal reveal_finished]。
func reveal_all() -> void:
	_kill_reveal()
	if _body != null:
		_body.visible_ratio = 1.0
	if _revealing:
		_revealing = false
		reveal_finished.emit()


## 当前是不是正在逐字显示。
func is_revealing() -> bool:
	return _revealing


## 改逐字速度。0 = 一次性显示。
func set_reveal_speed(speed: float) -> void:
	reveal_speed = maxf(speed, 0.0)


# ─────────────────────────────────────────────────────────────────────────────
#  滚动
# ─────────────────────────────────────────────────────────────────────────────

## 当前阅读进度，0.0 = 顶部，1.0 = 底部。
## 内容没有超出可视区时恒为 1.0（没得滚，视为已经看完）。
func get_scroll_ratio() -> float:
	var bar := _scroll_bar()
	if bar == null:
		return 1.0
	var span := bar.max_value - bar.page - bar.min_value
	if span <= 0.0:
		return 1.0
	return clampf((bar.value - bar.min_value) / span, 0.0, 1.0)


## 跳到指定阅读进度（0.0 ~ 1.0）。
func set_scroll_ratio(ratio: float) -> void:
	var bar := _scroll_bar()
	if bar == null:
		return
	var span := maxf(bar.max_value - bar.page - bar.min_value, 0.0)
	bar.value = bar.min_value + clampf(ratio, 0.0, 1.0) * span


func scroll_to_top() -> void:
	set_scroll_ratio(0.0)


## 滚到底。文本刚变过时滚动条范围要下一帧才刷新，所以这里会补一次。
func scroll_to_bottom() -> void:
	set_scroll_ratio(1.0)
	_reapply_bottom.call_deferred()


## 相对当前位置滚动 [param pixels]（正数向下）。
func scroll_by(pixels: float) -> void:
	var bar := _scroll_bar()
	if bar == null:
		return
	bar.value = clampf(bar.value + pixels, bar.min_value, bar.max_value)


## 是否已经读到底部。
func is_at_bottom() -> bool:
	return get_scroll_ratio() >= 0.999


## 追加内容时是否自动跟随到底部。
func set_auto_scroll(value: bool) -> void:
	auto_scroll = value
	if _body != null:
		_body.scroll_following = value


# ─────────────────────────────────────────────────────────────────────────────
#  内部
# ─────────────────────────────────────────────────────────────────────────────

func _scroll_bar() -> VScrollBar:
	return _body.get_v_scroll_bar() if _body != null else null


func _rebuild() -> void:
	if _body == null:
		return
	_body.clear()
	if bbcode:
		_body.append_text(text_content)
	else:
		_body.add_text(text_content)
	_after_content_change()


func _after_content_change() -> void:
	_start_reveal()
	text_changed.emit()


func _start_reveal() -> void:
	_kill_reveal()
	if _body == null:
		return

	var total := _body.get_total_character_count()
	if reveal_speed <= 0.0 or total <= 0:
		_body.visible_ratio = 1.0
		_revealing = false
		reveal_finished.emit()
		return

	_body.visible_ratio = 0.0
	_revealing = true
	_reveal_tween = create_tween()
	_reveal_tween.bind_node(self)
	_reveal_tween.tween_property(_body, "visible_ratio", 1.0, float(total) / reveal_speed)
	_reveal_tween.finished.connect(_on_reveal_tween_finished)


func _on_reveal_tween_finished() -> void:
	if not _revealing:
		return
	_revealing = false
	reveal_finished.emit()


func _kill_reveal() -> void:
	if _reveal_tween != null and _reveal_tween.is_valid():
		_reveal_tween.kill()
	_reveal_tween = null


func _apply_style(config: Dictionary) -> void:
	if _background != null and config.has("bg_color"):
		_background.color = Color(config["bg_color"])

	if _margin != null and config.has("padding"):
		var pad := int(config["padding"])
		_margin.add_theme_constant_override("margin_left", pad)
		_margin.add_theme_constant_override("margin_top", pad)
		_margin.add_theme_constant_override("margin_right", pad)
		_margin.add_theme_constant_override("margin_bottom", pad)

	if _body == null:
		return
	if config.has("font_size"):
		_body.add_theme_font_size_override("normal_font_size", int(config["font_size"]))
	if config.has("line_separation"):
		_body.add_theme_constant_override("line_separation", int(config["line_separation"]))
	if config.has("text_color"):
		_body.add_theme_color_override("default_color", Color(config["text_color"]))
	if config.has("selectable"):
		_body.selection_enabled = bool(config["selectable"])
	if config.has("scrollbar"):
		var bar := _scroll_bar()
		if bar != null:
			bar.visible = bool(config["scrollbar"])


func _hook_scroll() -> void:
	if _scroll_hooked:
		return
	var bar := _scroll_bar()
	if bar == null:
		return
	bar.changed.connect(_on_scroll_changed)
	_scroll_hooked = true
	_was_at_bottom = is_at_bottom()


func _on_scroll_changed() -> void:
	var now := is_at_bottom()
	if now and not _was_at_bottom:
		reached_bottom.emit()
	_was_at_bottom = now


func _reapply_bottom() -> void:
	if is_instance_valid(self) and _body != null:
		set_scroll_ratio(1.0)
