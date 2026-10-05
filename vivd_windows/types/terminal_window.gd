extends "res://vivd_windows/vivd_window.gd"
## 终端窗口 —— 把一个 [FakeTerminal] 装进独立的 vivd 窗口。
##
## [b]它和 [code]text[/code] 窗口的区别[/b]：text 窗口是「只读阅读器」，
## 这个是「能打字的终端」——有提示符、能输入命令、有历史记录和 Tab 补全。
##
## [b]用法[/b]
## [codeblock]
## VivdWindowsNode.add_window("term", "terminal", {
##     "title": "星港终端",
##     "position": Vector2i(220, 160),
##     "size": Vector2i(820, 460),
##     "font_size": 16,
##     "banner": "星港终端 v1.0",
##     "text": "系统就绪。\n输入 help 查看命令。",
## })
##
## # 输出（call_window_method 的参数会展开）
## VivdWindowsNode.call_window_method("term", "println", ["你好"])
## VivdWindowsNode.call_window_method("term", "print_error", ["出错了"])
## VivdWindowsNode.call_window_method("term", "type_line", ["正在连接……", 0.03])
## VivdWindowsNode.call_window_method("term", "progress", ["加载中", 1.5])
##
## # 像玩家一样敲一行命令（会回显、进历史、走完整输入链路）
## VivdWindowsNode.call_window_method("term", "run", ["status"])
## VivdWindowsNode.call_window_method("term", "run_lines", [["scan", "status"]])
## [/codeblock]
##
## [b]注册命令[/b]：直接调 [method register_command]，
## 或连 [signal command_entered] 自己做分发。
##
## [b]注意[/b]：淡入淡出作用在直接子节点 [code]Background[/code] 上，别删它。

## 玩家敲了回车（无论命令是否存在）。
signal command_entered(command: String, args: PackedStringArray)
## 窗口初始化完毕，可以开始输出/注册命令了。
signal terminal_ready()
## 输入了未注册的命令。
signal unknown_command(command: String)

## 提示符，支持 [code][color=red]…[/color][/code] 写法。
var prompt := "[color=green]player@game[/color]:[color=blue]~[/color]$ "
## 字号。
var font_size := 16
## 背景色。
var bg_color := Color("#10141c")
## 前景色。
var fg_color := Color("#d7dce5")

@onready var _background: ColorRect = get_node_or_null("Background")
@onready var _margin: MarginContainer = get_node_or_null("Background/Margin")
@onready var _term = get_node_or_null("Background/Margin/FakeTerminal")


# ─────────────────────────────────────────────────────────────────────────────
#  vivd 生命周期
# ─────────────────────────────────────────────────────────────────────────────

func setup(config: Dictionary) -> void:
	if _term == null:
		push_warning("[terminal_window] 场景里找不到 Background/Margin/FakeTerminal")
		return

	dev_watch = PackedStringArray(["position", "size", "visible", "font_size"])

	_apply_style(config)

	if config.has("prompt"):
		prompt = str(config["prompt"])
		_term.prompt = prompt
	if config.has("scrollback"):
		_term.scrollback_lines = int(config["scrollback"])

	# 默认挂上 help / clear / echo / colors
	if bool(config.get("default_commands", true)):
		_term.register_default_commands()

	_term.command_entered.connect(_on_term_command_entered)
	_term.unknown_command.connect(_on_term_unknown_command)

	# 清掉 FakeTerminal._ready() 画出来的那行提示符。
	# _ready() 用的是脚本默认提示符（user@game），而配置里的 prompt 要到 setup()
	# 才生效，不清的话窗口顶部会残留一行旧提示符。
	_term.clear_screen()

	var banner := str(config.get("banner", ""))
	if not banner.is_empty():
		_term.print_block(banner)

	var content := str(config.get("text", ""))
	if not content.is_empty():
		_term.print_block(content)

	_term.show_prompt()

	if config.has("run"):
		run_lines(config["run"])

	terminal_ready.emit()


func teardown() -> void:
	if _term == null:
		return
	# 交还焦点：终端一直 grab_focus，窗口被拆掉时若还占着焦点，
	# 后续输入会被送往已经离树的 Viewport。
	if _term.has_focus():
		_term.release_focus()
	if _term.command_entered.is_connected(_on_term_command_entered):
		_term.command_entered.disconnect(_on_term_command_entered)
	if _term.unknown_command.is_connected(_on_term_unknown_command):
		_term.unknown_command.disconnect(_on_term_unknown_command)


# ─────────────────────────────────────────────────────────────────────────────
#  输出（都能通过 call_window_method 调）
# ─────────────────────────────────────────────────────────────────────────────

func println(text := "") -> void:
	if _term != null:
		_term.print_line(str(text))


func print_text(text: String) -> void:
	if _term != null:
		_term.print_text(text)


func print_error(text: String) -> void:
	if _term != null:
		_term.print_error(text)


func print_warn(text: String) -> void:
	if _term != null:
		_term.print_warn(text)


func print_success(text: String) -> void:
	if _term != null:
		_term.print_success(text)


func print_info(text: String) -> void:
	if _term != null:
		_term.print_info(text)


## 按行输出一整段多行文本。
func print_block(text: String) -> void:
	if _term != null:
		_term.print_block(text)


## 打字机效果。协程——call_window_method 不会等它，想等就直接拿窗口对象 await。
func type_line(text: String, delay := 0.03) -> void:
	if _term != null:
		await _term.type_line(text, delay)


## 进度条。同样是协程。
func progress(prefix := "进度", seconds := 1.5, width := 30) -> void:
	if _term != null:
		await _term.progress_bar(prefix, seconds, width)


## 清屏（保留提示符）。
func clear() -> void:
	if _term != null:
		_term.clear_all()


## 清屏并把提示符也重画。
func clear_screen() -> void:
	if _term != null:
		_term.clear_screen()


func set_prompt(value: String) -> void:
	prompt = value
	if _term != null:
		_term.set_prompt(value)


func set_font_size(value: int) -> void:
	font_size = value
	if _term != null:
		_term.set_font_size(value)


# ─────────────────────────────────────────────────────────────────────────────
#  输入 / 命令
# ─────────────────────────────────────────────────────────────────────────────

## 注册一条命令。handler 收到 args: PackedStringArray（不含命令名）。
func register_command(cmd_name: String, handler: Callable, help := "", usage := "") -> void:
	if _term != null:
		_term.register_command(cmd_name, handler, help, usage)


func unregister_command(cmd_name: String) -> void:
	if _term != null:
		_term.unregister_command(cmd_name)


## 未注册命令的兜底处理（收到 command 和 args）。
func set_fallback_handler(handler: Callable) -> void:
	if _term != null:
		_term.set_fallback_handler(handler)


func get_command_names() -> PackedStringArray:
	return _term.get_command_names() if _term != null else PackedStringArray()


## 像玩家一样敲进一整行命令并回车。
## 走的是真实输入链路（data_sent），所以会回显、会进历史、会走完整解析。
func run(line: String) -> void:
	if _term == null:
		return
	_term.data_sent.emit(line.to_utf8_buffer())
	_term.data_sent.emit("\r".to_utf8_buffer())


## 依次执行多行命令，每行都会等上一条跑完。
func run_lines(lines) -> void:
	for line in lines:
		run(str(line))
		# 命令是协程（可能有打字机动画），等它跑完再发下一条，
		# 否则 _busy 会把后续输入直接丢掉。
		while _term != null and _term.is_busy():
			await get_tree().process_frame


## 拿到内部的 FakeTerminal，做上面没包过的事。
func get_terminal():
	return _term


# ─────────────────────────────────────────────────────────────────────────────
#  内部
# ─────────────────────────────────────────────────────────────────────────────

func _apply_style(config: Dictionary) -> void:
	if config.has("bg_color"):
		bg_color = Color(config["bg_color"])
	if config.has("fg_color"):
		fg_color = Color(config["fg_color"])

	if _background != null:
		_background.color = bg_color

	if config.has("padding") and _margin != null:
		var pad := int(config["padding"])
		_margin.add_theme_constant_override("margin_left", pad)
		_margin.add_theme_constant_override("margin_top", pad)
		_margin.add_theme_constant_override("margin_right", pad)
		_margin.add_theme_constant_override("margin_bottom", pad)

	if _term == null:
		return

	_term.set_background_color(bg_color)
	_term.set_foreground_color(fg_color)

	if config.has("font_size"):
		font_size = int(config["font_size"])
		_term.set_font_size(font_size)

	# 让玩家能直接打字，不用先点一下。
	# 走 focus_soon() 而不是 grab_focus.call_deferred()：后者在窗口被当帧删掉时
	# 会在节点离树之后执行，报 grab_focus 的 "!is_inside_tree()"。
	_term.focus_soon()


func _on_term_command_entered(_line: String, command: String, args: PackedStringArray) -> void:
	command_entered.emit(command, args)


func _on_term_unknown_command(command: String) -> void:
	unknown_command.emit(command)
