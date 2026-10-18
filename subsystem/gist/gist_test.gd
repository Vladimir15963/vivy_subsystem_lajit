extends Control
## Gist POST 请求测试面板
##
## 在 Godot 里打开 gist_test.tscn，按 F6 直接运行。
## 参考 F:\项目\测试\control.gd：默认走 POST，默认预填代理 127.0.0.1:7890。

const GistClient := preload("res://subsystem/gist/gist_client.gd")

const METHOD_NAMES := ["GET", "POST"]
const METHOD_VALUES := [HTTPClient.METHOD_GET, HTTPClient.METHOD_POST]

var _client
var _url: LineEdit
var _method: OptionButton
var _proxy_host: LineEdit
var _proxy_port: LineEdit
var _body: TextEdit
var _status: Label
var _state: Label
var _log: RichTextLabel
var _send_button: Button


func _ready() -> void:
	_build_ui()

	_client = GistClient.new()
	_client.name = "GistClient"
	_client.debug_log = true
	_client.request_succeeded.connect(_on_response)
	_client.request_failed.connect(_on_response)
	_client.request_timed_out.connect(_on_response)
	add_child(_client)

	_write_log("点「发送请求」后，结果与内容会显示在这里。")


# ─────────────────────────────────────────────────────────────────────────────
#  交互
# ─────────────────────────────────────────────────────────────────────────────

func _on_send_pressed() -> void:
	_client.proxy_host = _proxy_host.text.strip_edges()
	_client.proxy_port = int(_proxy_port.text.strip_edges()) if not _proxy_port.text.strip_edges().is_empty() else 0

	var method_index := maxi(_method.selected, 0)
	var method_value: int = METHOD_VALUES[method_index]

	_send_button.disabled = true
	_send_button.text = "请求中…"
	_status.text = "请求已发出，等待响应…"
	_status.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	_write_log("[color=#8ab4f8]→ %s %s[/color]" % [METHOD_NAMES[method_index], _url.text.strip_edges()])

	if _client.request_gist(_body.text, method_value, _url.text) != OK:
		_set_idle()


func _on_response(result: Dictionary) -> void:
	_set_idle()

	var code: int = result["code"]
	var is_success: bool = result["success"]
	var is_timeout: bool = result.get("timed_out", false)

	var color := "#e06c75"                                  # 失败 / 异常响应
	if is_success:
		color = "#98c379"                                   # 成功
	elif is_timeout:
		color = "#e5c07b"                                   # 超时

	var summary := GistClient.describe(result)
	_status.text = summary
	_status.add_theme_color_override("font_color", Color(color))
	_write_log("[color=%s]%s[/color]" % [color, summary])

	_update_state()

	var content := str(result.get("content", ""))
	if not content.is_empty():
		_write_log("[color=#888888]  Gist 内容：[/color]")
		_write_log(content)

	var error := str(result.get("error", ""))
	if not error.is_empty():
		_write_log("[color=#e06c75]  %s[/color]" % error)


func _update_state() -> void:
	_state.text = "连接：%s　网络：%s　请求：%s" % [
		_client.get_connection_status_text(),
		_client.get_network_status(),
		_client.get_request_status_text(),
	]


func _set_idle() -> void:
	_send_button.disabled = false
	_send_button.text = "发送请求"


func _write_log(line: String) -> void:
	_log.append_text(line + "\n")


# ─────────────────────────────────────────────────────────────────────────────
#  界面
# ─────────────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var title := Label.new()
	title.text = "Gist POST 请求测试"
	title.add_theme_font_size_override("font_size", 20)
	column.add_child(title)

	var hint := Label.new()
	hint.text = "参考 control.gd：gist.githubusercontent 的 raw 地址只支持 GET，POST 会拿到 405，正好用来验证「异常响应」。"
	hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	column.add_child(hint)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	column.add_child(grid)

	_url = _add_row(grid, "请求地址", "留空则用 GistClient.DEFAULT_ENDPOINT")
	_url.text = GistClient.DEFAULT_ENDPOINT
	_proxy_host = _add_row(grid, "代理地址", "留空表示直连")
	_proxy_host.text = "127.0.0.1"
	_proxy_port = _add_row(grid, "代理端口", "留空表示不使用代理")
	_proxy_port.text = "7890"

	var method_label := Label.new()
	method_label.text = "请求方法"
	grid.add_child(method_label)

	_method = OptionButton.new()
	for name_index in METHOD_NAMES.size():
		_method.add_item(METHOD_NAMES[name_index], name_index)
	_method.selected = 1   # 默认 POST
	_method.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_method)

	var body_label := Label.new()
	body_label.text = "POST 请求体（GET 时忽略）"
	column.add_child(body_label)

	_body = TextEdit.new()
	_body.text = JSON.stringify({"name": "Godette"})
	_body.custom_minimum_size = Vector2(0, 80)
	column.add_child(_body)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)

	_send_button = Button.new()
	_send_button.text = "发送请求"
	_send_button.pressed.connect(_on_send_pressed)
	buttons.add_child(_send_button)

	var clear_button := Button.new()
	clear_button.text = "清空日志"
	clear_button.pressed.connect(func() -> void: _log.text = "")
	buttons.add_child(clear_button)

	_status = Label.new()
	_status.text = "等待发送"
	_status.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	column.add_child(_status)

	_state = Label.new()
	_state.text = "连接：未连接　网络：未探测　请求：空闲"
	_state.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	column.add_child(_state)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 200)
	column.add_child(_log)


func _add_row(grid: GridContainer, label_text: String, placeholder: String) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)

	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(edit)
	return edit
