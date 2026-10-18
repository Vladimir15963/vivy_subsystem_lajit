extends Control
## Web3Forms API 测试面板
##
## 在 Godot 里打开 web3forms_test.tscn，按 F6 直接运行。
## 到 https://web3forms.com 免费领一个 Access Key 填进去，点「发送测试」就能收到邮件。

const Web3Forms := preload("res://subsystem/web3forms/web3forms_client.gd")

var _client
var _access_key: LineEdit
var _form_id: LineEdit
var _subject: LineEdit
var _email: LineEdit
var _message: TextEdit
var _status: Label
var _log: RichTextLabel
var _send_button: Button


func _ready() -> void:
	_build_ui()

	_client = Web3Forms.new()
	_client.name = "Web3FormsClient"
	_client.debug_log = true
	_client.submit_succeeded.connect(_on_response)
	_client.submit_failed.connect(_on_response)
	_client.submit_redirected.connect(_on_response)
	add_child(_client)

	_write_log("填好 Access Key 后点「发送测试」，结果会显示在这里。")


# ─────────────────────────────────────────────────────────────────────────────
#  交互
# ─────────────────────────────────────────────────────────────────────────────

func _on_send_pressed() -> void:
	_client.access_key = _access_key.text.strip_edges()
	_client.form_id = _form_id.text.strip_edges()
	_client.subject = _subject.text.strip_edges()
	_client.email = _email.text.strip_edges()

	_send_button.disabled = true
	_send_button.text = "发送中…"
	_status.text = "请求已发出，等待响应…"
	_status.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	_write_log("[color=#8ab4f8]→ POST %s[/color]" % _client.build_url())

	if _client.submit({"message": _message.text}) != OK:
		_set_idle()


func _on_response(result: Dictionary) -> void:
	_set_idle()

	var code: int = result["code"]
	var is_redirect := code >= 300 and code < 400
	var is_success: bool = result["success"] and str(result["error"]).is_empty()

	var color := "#e06c75"                                  # 失败
	if is_redirect:
		color = "#e5c07b"                                   # 303 重定向
	elif is_success:
		color = "#98c379"                                   # 成功

	var summary := Web3Forms.describe(result)
	_status.text = summary
	_status.add_theme_color_override("font_color", Color(color))
	_write_log("[color=%s]%s[/color]" % [color, summary])

	var raw := str(result["raw"])
	if not raw.is_empty():
		_write_log("[color=#888888]  原始响应：%s[/color]" % raw)

	var data: Dictionary = result["data"]
	if not data.is_empty():
		_write_log("[color=#888888]  提交的数据：%s[/color]" % JSON.stringify(data))


func _set_idle() -> void:
	_send_button.disabled = false
	_send_button.text = "发送测试"


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
	title.text = "Web3Forms API 测试"
	title.add_theme_font_size_override("font_size", 20)
	column.add_child(title)

	var hint := Label.new()
	hint.text = "POST https://api.web3forms.com/submit　·　Access Key 免费领取：https://web3forms.com"
	hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	column.add_child(hint)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	column.add_child(grid)

	_access_key = _add_row(grid, "Access Key", "粘贴 Access Key（必填，除非填下面的 Form ID）")
	_form_id = _add_row(grid, "Form ID", "可选：填了就走 POST /submit/{FORM_ID}，不用 access_key")
	_subject = _add_row(grid, "邮件主题", "来自 Godot 的测试")
	_email = _add_row(grid, "你的邮箱", "可选，会作为邮件的 Reply-To")
	# 预填你提供的 Access Key（官方说明：这是公开 key，可以安全地放在客户端代码里）
	_access_key.text = "ea79ee6e-5a95-4a31-93b2-520532d9d78f"
	_subject.text = "来自 Godot 的测试"

	var message_label := Label.new()
	message_label.text = "邮件内容"
	column.add_child(message_label)

	_message = TextEdit.new()
	_message.text = "你好，这是一条来自 Godot 的 Web3Forms 测试消息。"
	_message.custom_minimum_size = Vector2(0, 90)
	column.add_child(_message)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)

	_send_button = Button.new()
	_send_button.text = "发送测试"
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
