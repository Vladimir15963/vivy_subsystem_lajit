## FakeTerminal —— 基于 godot_xterm 的 Terminal 节点实现的「伪终端」。
##
## 特点：不依赖 PTY、不启动任何子进程，全部输出由 GDScript 直接写入，
## 因此编码 100% 可控（直接把 String 按 UTF-8 写进去），中文不会乱码。
##
## 用法：
## [codeblock]
## $FakeTerminal.println("你好，世界")
## $FakeTerminal.println_colored("警告", Color("#e5c07b"))
## await $FakeTerminal.type_line("正在连接……", 0.03)
## $FakeTerminal.register_command("help", _cmd_help, "显示帮助")
## [/codeblock]
class_name FakeTerminal
extends Terminal

## 提交了一行输入（无论命令是否存在）
signal input_line(line: String)
## 提交的命令：command 为空表示空行
signal command_entered(line: String, command: String, args: PackedStringArray)
## 提交了未注册的命令
signal unknown_command(command: String)

# ---------------------------------------------------------------------------
# ANSI 转义
# ---------------------------------------------------------------------------

const ESC := "\u001b"
const CSI := ESC + "["
const RESET := CSI + "0m"
const BOLD := CSI + "1m"
const DIM := CSI + "2m"
const ITALIC := CSI + "3m"
const UNDERLINE := CSI + "4m"
const BLINK := CSI + "5m"
const INVERSE := CSI + "7m"
const CLEAR_LINE := CSI + "2K"
const CLEAR_SCREEN := CSI + "2J"
const CURSOR_HOME := CSI + "H"
const CRLF := "\r\n"

## 标准 16 色，对应 Terminal 的 ansi_N_color 主题色。
## （不能叫 Color，会和内置类型重名）
enum Ansi {
	BLACK, RED, GREEN, YELLOW, BLUE, MAGENTA, CYAN, WHITE,
	GRAY, BRIGHT_RED, BRIGHT_GREEN, BRIGHT_YELLOW,
	BRIGHT_BLUE, BRIGHT_MAGENTA, BRIGHT_CYAN, BRIGHT_WHITE,
}

# ---------------------------------------------------------------------------
# 导出配置
# ---------------------------------------------------------------------------

@export_group("外观")
## 字号
@export var font_size: int = 16
## 是否使用内置配色（关掉就用主题/编辑器里的配色）
@export var use_builtin_theme: bool = true
## 背景色
@export var background_color: Color = Color("#10141c")
## 前景色
@export var foreground_color: Color = Color("#d7dce5")

@export_group("字体")
## 主字体（负责 ASCII 等宽字形）。留空 = 用插件自带的 JetBrains Mono。
@export var primary_font: Font = null
## 中/日/韩文回退字体名，按顺序找系统里装了的那个。
## 注意：光靠 allow_system_fallback 在 Godot 里是拿不到中文的（实测 has_char(中)=false），
## 必须显式挂 fallback，所以这里给了候选列表。
@export var cjk_font_names: PackedStringArray = PackedStringArray([
	"Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "SimSun",
	"Noto Sans SC", "Noto Sans CJK SC", "Source Han Sans SC",
	"Sarasa Mono SC", "Sarasa Gothic SC", "PingFang SC",
	"Hiragino Sans GB", "WenQuanYi Micro Hei", "DengXian",
])
## 额外回退字体。要发布给玩家时，把你的中文字体资源拖到这里最可靠，
## 这样就不依赖玩家电脑上装了什么字体。
@export var extra_fallbacks: Array[Font] = []

@export_group("行为")
## 提示符（可以带 ANSI 颜色）
@export var prompt: String = "[color=green]user@game[/color]:[color=blue]~[/color]$ "
## 启动时打印的横幅
@export_multiline var banner: String = ""
## 回滚缓冲行数（注意：不能直接叫 max_scrollback，会和 Terminal 原生属性重名）
@export var scrollback_lines: int = 2000
## 是否回显玩家输入的字符（伪终端必须自己回显，因为没有 shell 帮你回显）
@export var local_echo: bool = true
## 是否允许输入
@export var input_enabled: bool = true
## 自动滚动到底部
@export var auto_scroll: bool = true
## 命令行历史条数
@export var max_history: int = 200
## Tab 补全
@export var tab_completion: bool = true

# ---------------------------------------------------------------------------
# 内部状态
# ---------------------------------------------------------------------------

var _line: String = ""            ## 当前输入行
var _cursor: int = 0             ## 光标在 _line 中的下标
var _history: Array[String] = []
var _history_index: int = 0
var _busy: bool = false          ## 命令执行中，屏蔽输入
var _commands: Dictionary = {}   ## name -> { callable, help, usage }
var _fallback_handler: Callable = Callable()
var _ready_done: bool = false


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP

	if use_builtin_theme:
		_apply_theme()

	self.max_scrollback = scrollback_lines
	self.bell_muted = true

	if not data_sent.is_connected(_on_data_sent):
		data_sent.connect(_on_data_sent)

	# 用 gui_input 信号来实现「点一下聚焦」。
	# 不能重写 _gui_input 虚函数——Terminal 用 C++ 实现按键处理并发出 data_sent，
	# 一旦重写就必须调 super，而 GDExtension 不暴露该虚函数给 super。
	if not gui_input.is_connected(_on_own_gui_input):
		gui_input.connect(_on_own_gui_input)

	_ready_done = true

	if banner != "":
		print_line(banner)
	write(_prompt_ansi())

	# 主动抢焦点，省得玩家还要点一下。
	# 注意不能直接写 grab_focus.call_deferred()：如果这一帧窗口就被删掉/换场景，
	# 延迟调用会在节点已经离树之后执行，报 grab_focus 的 "!is_inside_tree()" 错误。
	focus_soon()


func _on_own_gui_input(event: InputEvent) -> void:
	# 点一下就聚焦
	if event is InputEventMouseButton and event.pressed:
		grab_focus()


## 下一帧抢焦点（会先确认自己还在树上）。
## 外部想在 setup() 里补一次聚焦时用这个，别直接 grab_focus.call_deferred()。
func focus_soon() -> void:
	_focus_when_ready.call_deferred()


func _focus_when_ready() -> void:
	if is_inside_tree():
		grab_focus()


# ---------------------------------------------------------------------------
# 主题
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	add_theme_color_override("background_color", background_color)
	add_theme_color_override("foreground_color", foreground_color)

	# 一套偏冷色的配色，和深色背景搭
	var palette: Array[Color] = [
		Color("#2a2f3a"), # 0  black
		Color("#e06c75"), # 1  red
		Color("#98c379"), # 2  green
		Color("#e5c07b"), # 3  yellow
		Color("#61afef"), # 4  blue
		Color("#c678dd"), # 5  magenta
		Color("#56b6c2"), # 6  cyan
		Color("#abb2bf"), # 7  white
		Color("#5c6370"), # 8  bright black (gray)
		Color("#ff7b86"), # 9  bright red
		Color("#b5e890"), # 10 bright green
		Color("#ffd68a"), # 11 bright yellow
		Color("#82c9ff"), # 12 bright blue
		Color("#e094ff"), # 13 bright magenta
		Color("#6fd8e6"), # 14 bright cyan
		Color("#ffffff"), # 15 bright white
	]
	for i in palette.size():
		add_theme_color_override("ansi_%d_color" % i, palette[i])

	# 字体：ASCII 用等宽的 JetBrains Mono，中文靠显式 fallback 找系统字体。
	var font := _build_font()
	if font:
		add_theme_font_override("normal_font", font)
		add_theme_font_override("bold_font", font)
		add_theme_font_override("italics_font", font)
		add_theme_font_override("bold_italics_font", font)

	add_theme_font_size_override("normal_font_size", font_size)
	add_theme_font_size_override("bold_font_size", font_size)
	add_theme_font_size_override("italics_font_size", font_size)
	add_theme_font_size_override("bold_italics_font_size", font_size)


## 组装字体：主字体 + 中文回退。
## 实测结论（Godot 4.7）：FontFile.allow_system_fallback=true 并不会真的给你中文，
## 必须把中文字体挂到 FontVariation.fallbacks 上才生效。
func _build_font() -> Font:
	var base: Font = primary_font
	if base == null:
		base = load("res://addons/godot_xterm/themes/fonts/regular.tres")
	if base == null:
		return null

	var fallbacks: Array[Font] = []
	for f in extra_fallbacks:
		if f != null:
			fallbacks.append(f)

	# 系统字体兜底（玩家机器上一般都有其中一个）
	if cjk_font_names.size() > 0:
		var sysf := SystemFont.new()
		sysf.font_names = cjk_font_names
		sysf.allow_system_fallback = true
		fallbacks.append(sysf)

	if fallbacks.is_empty():
		return base

	var fv := FontVariation.new()
	fv.base_font = base
	fv.fallbacks = fallbacks
	return fv


## 当前字体能不能显示某个字（调试用：想知道中文会不会变方块就问它）
func can_render(text: String) -> bool:
	var font := get_theme_font("normal_font")
	if font == null:
		return false
	for i in text.length():
		if not font.has_char(text.unicode_at(i)):
			return false
	return true


# ---------------------------------------------------------------------------
# 运行时改外观
# ---------------------------------------------------------------------------
# 注意：_ready() 之后直接改 font_size / background_color 这些导出属性
# 不会自动刷新主题覆盖（覆盖是 _ready 里一次性设好的），所以要走下面这几个方法。

## 改字号并立即生效
func set_font_size(value: int) -> void:
	font_size = value
	add_theme_font_size_override("normal_font_size", value)
	add_theme_font_size_override("bold_font_size", value)
	add_theme_font_size_override("italics_font_size", value)
	add_theme_font_size_override("bold_italics_font_size", value)


## 改背景色并立即生效
func set_background_color(color: Color) -> void:
	background_color = color
	add_theme_color_override("background_color", color)


## 改前景色并立即生效
func set_foreground_color(color: Color) -> void:
	foreground_color = color
	add_theme_color_override("foreground_color", color)


## 按行输出一整段多行文本
func print_block(text: String) -> void:
	for line in text.split("\n"):
		print_line(line)


## 当前是否有命令正在执行（执行期间会屏蔽输入）
func is_busy() -> bool:
	return _busy


# ---------------------------------------------------------------------------
# 输出 API
# ---------------------------------------------------------------------------

## 输出一行
func print_line(text: String = "") -> void:
	write(_bbcode_to_ansi(text) + CRLF)
	_scroll_to_bottom()


## 输出但不换行
func print_text(text: String) -> void:
	write(_bbcode_to_ansi(text))
	_scroll_to_bottom()


## 带颜色输出一行
func println_colored(text: String, color: Color) -> void:
	print_line(colorize(text, color))


func print_error(text: String) -> void:
	print_line(colorize("[错误] ", Color.RED) + text)


func print_warn(text: String) -> void:
	print_line(colorize("[警告] ", Color.YELLOW) + text)


func print_success(text: String) -> void:
	print_line(colorize("[完成] ", Color.GREEN) + text)


func print_info(text: String) -> void:
	print_line(colorize("[信息] ", Color.CYAN) + text)


## 逐字打印一行（打字机效果）。可以 await。
func type_line(text: String, char_delay: float = 0.03, newline: bool = true) -> void:
	var plain := strip_ansi(text)
	for i in plain.length():
		write(_escape_for_terminal(plain[i]))
		if char_delay > 0.0:
			await get_tree().create_timer(char_delay).timeout
			if not is_inside_tree():
				return
	if newline:
		write(CRLF)
	_scroll_to_bottom()


## 只清屏，不重画提示符
func clear_screen() -> void:
	write(CLEAR_SCREEN + CURSOR_HOME)


## 清屏并重画提示符
func clear_all() -> void:
	clear_screen()
	write(_prompt_ansi())


## 跑一个假的「进度条」
func progress_bar(prefix: String, seconds: float = 1.5, width: int = 30,
		fill_color: Color = Color("#98c379")) -> void:
	var steps := width
	var delay := seconds / float(max(steps, 1))
	for i in range(steps + 1):
		var filled := i
		var empty := width - i
		var pct := int(round(100.0 * float(i) / float(width)))
		var bar := colorize("█".repeat(filled), fill_color) + colorize("░".repeat(empty), Color("#4a5160"))
		write("\r" + CLEAR_LINE + prefix + " [" + bar + "] " + "%3d%%" % pct)
		if delay > 0.0:
			await get_tree().create_timer(delay).timeout
			if not is_inside_tree():
				return
	write(CRLF)


## 重设提示符并立即显示
func set_prompt(new_prompt: String) -> void:
	prompt = new_prompt
	write("\r" + CLEAR_LINE + _prompt_ansi())


func _scroll_to_bottom() -> void:
	if auto_scroll:
		# Terminal 自身会在写入时跟随光标，这里只是显式表达意图，
		# 便于以后接 ScrollContainer 时替换实现。
		pass


# ---------------------------------------------------------------------------
# 颜色工具
# ---------------------------------------------------------------------------

## 用 256 色索引上色（0-15 对应主题 ansi_N_color）
func colorize(text: String, color: Color) -> String:
	var r := int(clamp(color.r, 0.0, 1.0) * 255.0)
	var g := int(clamp(color.g, 0.0, 1.0) * 255.0)
	var b := int(clamp(color.b, 0.0, 1.0) * 255.0)
	return CSI + "38;2;%d;%d;%dm" % [r, g, b] + text + RESET


## 用标准 16 色上色（0-15，对应主题 ansi_N_color）
func colorize_index(text: String, color_index: int) -> String:
	return CSI + "38;5;%dm" % color_index + text + RESET


func bold(text: String) -> String:
	return BOLD + text + CSI + "22m"


func underline(text: String) -> String:
	return UNDERLINE + text + CSI + "24m"


func dim(text: String) -> String:
	return DIM + text + CSI + "22m"


## [color=..] 解析用的正则。静态缓存，只编译一次。
static var _bbcode_re: RegEx = null


static func _bbcode_regex() -> RegEx:
	if _bbcode_re == null:
		_bbcode_re = RegEx.new()
		var err := _bbcode_re.compile("\\[color=([#a-zA-Z0-9_]+)\\](.*?)\\[/color\\]")
		if err != OK:
			push_error("FakeTerminal: [color=..] 正则编译失败，err=%d" % err)
	return _bbcode_re


## 支持类似 BBCode 的简写：[color=red]文本[/color] 和 [b]粗体[/b]
## 这样在编辑器里配置 banner / prompt 时可读性好一些。
func _bbcode_to_ansi(text: String) -> String:
	if not text.contains("["):
		return text
	var out := text
	var named := {
		"black": Color("#2a2f3a"), "red": Color("#e06c75"), "green": Color("#98c379"),
		"yellow": Color("#e5c07b"), "blue": Color("#61afef"), "magenta": Color("#c678dd"),
		"cyan": Color("#56b6c2"), "white": Color("#abb2bf"), "gray": Color("#5c6370"),
		"grey": Color("#5c6370"), "orange": Color("#d19a66"), "pink": Color("#e094ff"),
	}
	var re := _bbcode_regex()
	for m in re.search_all(out):
		var key: String = m.get_string(1).to_lower()
		var col: Color = named.get(key, Color.from_string(m.get_string(1), Color.WHITE))
		out = out.replace(m.get_string(0), colorize(m.get_string(2), col))
	out = out.replace("[b]", BOLD).replace("[/b]", CSI + "22m")
	out = out.replace("[u]", UNDERLINE).replace("[/u]", CSI + "24m")
	out = out.replace("[i]", ITALIC).replace("[/i]", CSI + "23m")
	return out


## 去掉字符串里的 ANSI 转义序列。
## 手写扫描而不是用 RegEx，原因有两个：
##   1) RegEx 每次调用都要 compile()，而这个是「每敲一个键」都会走的热路径；
##   2) 用 "\\u001b" 这种写法 PCRE 不认，compile 会失败并刷 "Condition !is_valid()" 报错。
func strip_ansi(text: String) -> String:
	if not text.contains(ESC):
		return text
	var out := ""
	var i := 0
	var n := text.length()
	while i < n:
		if text.unicode_at(i) == 0x1b and i + 1 < n and text[i + 1] == "[":
			i += 2
			# CSI 序列的收尾字节落在 0x40-0x7e
			while i < n:
				var c := text.unicode_at(i)
				i += 1
				if c >= 0x40 and c <= 0x7e:
					break
			continue
		out += text[i]
		i += 1
	return out


## 把不够「终端安全」的字符转义掉（\n 之类）
func _escape_for_terminal(ch: String) -> String:
	if ch == "\n":
		return CRLF
	if ch == "\r":
		return "\r"
	return ch


# ---------------------------------------------------------------------------
# 命令注册
# ---------------------------------------------------------------------------

## 注册一条命令。
## handler 会收到 args: PackedStringArray（不含命令名本身）。
## （参数名不用 name，避免遮蔽 Node.name）
func register_command(cmd_name: String, handler: Callable, help: String = "",
		usage: String = "") -> void:
	_commands[cmd_name.to_lower()] = {
		"callable": handler, "help": help, "usage": usage,
	}


func unregister_command(cmd_name: String) -> void:
	_commands.erase(cmd_name.to_lower())


## 未注册命令的兜底处理（收到 command 和 args）
func set_fallback_handler(handler: Callable) -> void:
	_fallback_handler = handler


func get_command_names() -> PackedStringArray:
	var names := PackedStringArray()
	for k in _commands.keys():
		names.append(k)
	names.sort()
	return names


func get_command_help(cmd_name: String) -> Dictionary:
	return _commands.get(cmd_name.to_lower(), {})


# ---------------------------------------------------------------------------
# 输入处理
# ---------------------------------------------------------------------------

func _on_data_sent(data: PackedByteArray) -> void:
	if not input_enabled or _busy:
		return
	# data 是终端根据按键生成的原始字节，这里按 UTF-8 解码，中文输入才正常。
	_handle_input(data.get_string_from_utf8())


func _handle_input(text: String) -> void:
	var i := 0
	var n := text.length()
	while i < n:
		var code := text.unicode_at(i)

		if code == 0x1b:                      # ESC 序列
			i = _handle_escape(text, i)
			continue

		if code == 0x0d or code == 0x0a:      # Enter
			_submit_line()
			return                            # 交给异步流程，本次输入到此为止

		if code == 0x7f or code == 0x08:      # Backspace
			_backspace()
			i += 1
			continue

		if code == 0x03:                      # Ctrl+C
			_interrupt()
			i += 1
			continue

		if code == 0x0c:                      # Ctrl+L
			clear_all()
			_redraw_line()
			i += 1
			continue

		if code == 0x15:                      # Ctrl+U 清空整行
			_line = ""
			_cursor = 0
			_redraw_line()
			i += 1
			continue

		if code == 0x09:                      # Tab
			if tab_completion:
				_tab_complete()
			i += 1
			continue

		if code < 0x20:                       # 其他控制字符忽略
			i += 1
			continue

		_insert_char(text[i])
		i += 1


func _handle_escape(text: String, i: int) -> int:
	var n := text.length()
	if i + 1 >= n:
		return i + 1

	if text[i + 1] != "[":
		# ESC + 字符（Alt+某键），忽略 ESC
		return i + 1

	var j := i + 2
	var params := ""
	while j < n:
		var c := text[j]
		if (c >= "0" and c <= "9") or c == ";":
			params += c
			j += 1
		else:
			break
	if j >= n:
		return n

	var final := text[j]
	match final:
		"A": _history_prev()
		"B": _history_next()
		"C": _move_cursor(1)
		"D": _move_cursor(-1)
		"H": _set_cursor(0)
		"F": _set_cursor(_line.length())
		"~":
			match params:
				"1", "7": _set_cursor(0)
				"4", "8": _set_cursor(_line.length())
				"3": _delete_forward()
				_: pass
		_: pass
	return j + 1


func _insert_char(ch: String) -> void:
	if _cursor >= _line.length():
		_line += ch
		_cursor = _line.length()
		if local_echo:
			write(_escape_for_terminal(ch))
	else:
		_line = _line.substr(0, _cursor) + ch + _line.substr(_cursor)
		_cursor += 1
		_redraw_line()


func _backspace() -> void:
	if _cursor <= 0:
		return
	_line = _line.substr(0, _cursor - 1) + _line.substr(_cursor)
	_cursor -= 1
	if local_echo:
		_redraw_line()


func _delete_forward() -> void:
	if _cursor >= _line.length():
		return
	_line = _line.substr(0, _cursor) + _line.substr(_cursor + 1)
	if local_echo:
		_redraw_line()


func _move_cursor(delta: int) -> void:
	_set_cursor(_cursor + delta)


func _set_cursor(pos: int) -> void:
	_cursor = clampi(pos, 0, _line.length())
	if local_echo:
		_redraw_line()


func _redraw_line() -> void:
	# 重画整行，再把光标挪回去。
	write("\r" + CLEAR_LINE + _prompt_ansi() + _line)
	var col := _display_width(_visible_prompt()) + _display_width(_line.substr(0, _cursor))
	write(CSI + "%dG" % (col + 1))


func _interrupt() -> void:
	write("^C" + CRLF)
	_line = ""
	_cursor = 0
	write(_prompt_ansi())


func _tab_complete() -> void:
	if _line.contains(" "):
		return
	var prefix := _line.to_lower()
	var matches: Array[String] = []
	for cmd_name in get_command_names():
		if cmd_name.begins_with(prefix):
			matches.append(cmd_name)
	if matches.size() == 1:
		_line = matches[0] + " "
		_cursor = _line.length()
		_redraw_line()
	elif matches.size() > 1:
		write(CRLF)
		write("  ".join(matches))
		write(CRLF)
		write(_prompt_ansi() + _line)
		write(CSI + "%dG" % (_display_width(_visible_prompt()) + _display_width(_line) + 1))


func _history_prev() -> void:
	if _history.is_empty():
		return
	_history_index = maxi(0, _history_index - 1)
	_line = _history[_history_index]
	_cursor = _line.length()
	_redraw_line()


func _history_next() -> void:
	if _history.is_empty():
		return
	if _history_index < _history.size() - 1:
		_history_index += 1
		_line = _history[_history_index]
	else:
		_history_index = _history.size()
		_line = ""
	_cursor = _line.length()
	_redraw_line()


func _submit_line() -> void:
	var line := _line
	write(CRLF)
	_line = ""
	_cursor = 0

	if line.strip_edges() != "":
		_history.append(line)
		while _history.size() > max_history:
			_history.pop_front()
	_history_index = _history.size()

	var parts := _split_line(line)
	var cmd: String = parts[0] if parts.size() > 0 else ""
	var args := parts.slice(1) if parts.size() > 1 else PackedStringArray()

	input_line.emit(line)
	command_entered.emit(line, cmd, args)

	_busy = true
	await _dispatch(cmd, args)
	_busy = false
	write(_prompt_ansi())


func _dispatch(cmd: String, args: PackedStringArray) -> void:
	if cmd == "":
		return
	var key := cmd.to_lower()
	if _commands.has(key):
		var entry: Dictionary = _commands[key]
		var cb: Callable = entry["callable"]
		# await 对普通函数也成立：不是协程就立刻返回值，所以同步/异步处理器都能写。
		await cb.call(args)
		return

	if _fallback_handler.is_valid():
		await _fallback_handler.call(cmd, args)
		return

	unknown_command.emit(cmd)
	print_error("未知命令：%s（输入 help 查看可用命令）" % cmd)


## 按空格切分，支持用引号包住带空格的参数
func _split_line(line: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	var in_quote := false
	for i in line.length():
		var ch := line[i]
		if ch == "\"":
			in_quote = not in_quote
			continue
		if ch == " " and not in_quote:
			if cur != "":
				out.append(cur)
				cur = ""
			continue
		cur += ch
	if cur != "":
		out.append(cur)
	return out


# ---------------------------------------------------------------------------
# 光标定位用的显示宽度（中文按 2 格算）
# ---------------------------------------------------------------------------

## 提示符的实际输出（把 [color=..] 之类转成 ANSI 再写出去）
func _prompt_ansi() -> String:
	return _bbcode_to_ansi(prompt)


## 重新显示提示符（清屏或打完横幅之后调用）
func show_prompt() -> void:
	write(_prompt_ansi())


func _visible_prompt() -> String:
	return strip_ansi(_prompt_ansi())


## 按「显示宽度」右侧补空格（中文算 2 格，rpad() 是按字符数算的，对不齐）
func pad_right(text: String, width: int) -> String:
	var w := _display_width(strip_ansi(text))
	if w >= width:
		return text
	return text + " ".repeat(width - w)


## 按「显示宽度」左侧补空格
func pad_left(text: String, width: int) -> String:
	var w := _display_width(strip_ansi(text))
	if w >= width:
		return text
	return " ".repeat(width - w) + text


func _display_width(s: String) -> int:
	var w := 0
	for i in s.length():
		w += _char_width(s.unicode_at(i))
	return w


## 近似的 wcwidth：CJK / 全角字符算 2 格
func _char_width(cp: int) -> int:
	if cp == 0:
		return 0
	if cp < 0x20 or (cp >= 0x7f and cp < 0xa0):
		return 0
	if (cp >= 0x1100 and cp <= 0x115f) \
			or (cp >= 0x2e80 and cp <= 0xa4cf) \
			or (cp >= 0xac00 and cp <= 0xd7a3) \
			or (cp >= 0xf900 and cp <= 0xfaff) \
			or (cp >= 0xfe30 and cp <= 0xfe6f) \
			or (cp >= 0xff00 and cp <= 0xff60) \
			or (cp >= 0xffe0 and cp <= 0xffe6) \
			or (cp >= 0x20000 and cp <= 0x3fffd):
		return 2
	return 1


# ---------------------------------------------------------------------------
# 内置命令
# ---------------------------------------------------------------------------

## 注册默认命令（help / clear / echo / colors）
## 想完全自己控制就别调，或者注册完再 unregister_command。
func register_default_commands() -> void:
	register_command("help", _cmd_help, "显示所有可用命令", "help [命令]")
	register_command("clear", _cmd_clear, "清屏", "clear")
	register_command("echo", _cmd_echo, "原样回显", "echo <文本>")
	register_command("colors", _cmd_colors, "演示配色", "colors")


func _cmd_help(args: PackedStringArray) -> void:
	if args.size() > 0:
		var info := get_command_help(args[0])
		if info.is_empty():
			print_error("没有这个命令：%s" % args[0])
			return
		print_line(bold(args[0].to_lower()))
		print_line("  说明：" + str(info.get("help", "")))
		var usage: String = str(info.get("usage", ""))
		if usage != "":
			print_line("  用法：" + usage)
		return

	print_line(bold("可用命令："))
	for cmd_name in get_command_names():
		var info := get_command_help(cmd_name)
		print_line("  %s  %s" % [
			colorize(cmd_name.rpad(12), Color("#61afef")),
			str(info.get("help", "")),
		])


func _cmd_clear(_args: PackedStringArray) -> void:
	clear_screen()


func _cmd_echo(args: PackedStringArray) -> void:
	print_line(" ".join(args))


func _cmd_colors(_args: PackedStringArray) -> void:
	var names := ["黑", "红", "绿", "黄", "蓝", "紫", "青", "白",
		"灰", "亮红", "亮绿", "亮黄", "亮蓝", "亮紫", "亮青", "亮白"]
	var palette: Array[Color] = [
		Color("#2a2f3a"), Color("#e06c75"), Color("#98c379"), Color("#e5c07b"),
		Color("#61afef"), Color("#c678dd"), Color("#56b6c2"), Color("#abb2bf"),
		Color("#5c6370"), Color("#ff7b86"), Color("#b5e890"), Color("#ffd68a"),
		Color("#82c9ff"), Color("#e094ff"), Color("#6fd8e6"), Color("#ffffff"),
	]
	for i in palette.size():
		print_text(colorize(" %s " % names[i], palette[i]))
	print_line()
