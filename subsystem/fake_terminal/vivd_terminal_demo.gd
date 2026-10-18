extends Control
## vivd 终端窗口演示。
##
## 每个 vivd 窗口都是**独立的 OS 窗口**（工程里 embed_subwindows=false），
## 所以运行后终端会另开一个窗口，不在主画面里。

const WINDOW_NAME := "term"

const C_ACCENT := Color("#61afef")
const C_OK := Color("#98c379")
const C_WARN := Color("#e5c07b")
const C_ERR := Color("#e06c75")
const C_DIM := Color("#5c6370")


func _ready() -> void:
	print("[demo] 已注册的窗口类型：", VivdWindowsNode.list_window_types())

	VivdWindowsNode.window_added.connect(_on_window_added)
	VivdWindowsNode.window_removed.connect(_on_window_removed)

	# 开窗。返回时窗口已经 setup 完毕，可以直接操作。
	var win = VivdWindowsNode.add_window(WINDOW_NAME, "terminal", {
		"title": "星港终端",
		"position": Vector2i(240, 140),
		"size": Vector2i(840, 470),
		"font_size": 16,
		"prompt": "[color=green]player@game[/color]:[color=blue]~[/color]$ ",
		"banner": "[color=cyan]══════════════════════════════[/color]\n"
			+ "[color=cyan]   星 港 终 端   v1.0[/color]\n"
			+ "[color=cyan]   伪 终 端 演 示（无 PTY）[/color]\n"
			+ "[color=cyan]══════════════════════════════[/color]",
	})
	if win == null:
		push_error("[demo] 终端窗口创建失败，看上面的 [VivdWindows] 报错")
		return

	VivdWindowsNode.fade_window_in(WINDOW_NAME, 0.25)

	# 注册自定义命令。call_window_method 会把数组里的参数展开。
	_register("status", _cmd_status, "查看系统状态", "status")
	_register("scan", _cmd_scan, "扫描附近的信号", "scan")
	_register("font", _cmd_font, "检测中文字体", "font")
	_register("close", _cmd_close, "关闭终端窗口", "close")

	await get_tree().create_timer(0.2).timeout
	await _boot()


func _boot() -> void:
	VivdWindowsNode.call_window_method(WINDOW_NAME, "println", [""])
	VivdWindowsNode.call_window_method(WINDOW_NAME, "print_info", ["输入 help 查看命令，输入 font 检查中文字体"])
	VivdWindowsNode.call_window_method(WINDOW_NAME, "println", [""])
	await _call(WINDOW_NAME, "progress", ["系统自检", 1.2])
	VivdWindowsNode.call_window_method(WINDOW_NAME, "print_success", ["自检通过，终端就绪。"])
	VivdWindowsNode.call_window_method(WINDOW_NAME, "println", [""])
	# 自动跑一条命令，演示完整输入链路（会回显 + 进历史）
	await _call(WINDOW_NAME, "run_lines", [["status"]])


# ---------------------------------------------------------------------------
# 命令实现（handler 挂在演示节点上，用管理器转发回窗口输出）
# ---------------------------------------------------------------------------

func _cmd_status(_args: PackedStringArray) -> void:
	# print_line 会解析 [b]..[/b] 这类简写，所以标题不用另外包方法
	_out("println", ["[b]系统状态[/b]"])

	var term = _term().get_terminal()
	var rows := [
		["电源", "98%", C_OK],
		["信号强度", "72%", C_WARN],
		["护盾", "已关闭", C_DIM],
		["附近节点", "4 个", C_ACCENT],
	]
	for r in rows:
		# pad_right 按显示宽度补空格（中文算 2 格），中文才对得齐
		_out("println", ["  %s%s %s" % [
			term.pad_right(r[0], 14),
			term.colorize("●", r[2]),
			r[1],
		]])


func _cmd_scan(_args: PackedStringArray) -> void:
	_out("print_info", ["开始扫描……"])
	await _call(WINDOW_NAME, "progress", ["扫描中", 1.0])
	_out("print_success", ["扫描完成，发现 3 个目标。"])


func _cmd_font(_args: PackedStringArray) -> void:
	var term = _term().get_terminal()
	if term.can_render("中文测试"):
		_out("print_success", ["中文可以正常显示"])
	else:
		_out("print_error", ["中文字体缺失，会显示成空白"])


func _cmd_close(_args: PackedStringArray) -> void:
	# 不要在这里直接删！我们此刻正处在终端自己的按键处理流程里（_gui_input →
	# data_sent → 命令分发），把持有焦点的子窗口当场拆掉，会让这一帧后续的输入
	# 继续送往已经离树的 Viewport，Godot 会报
	#   _push_shortcut_input_internal: Condition "!is_inside_tree()" is true.
	# 延迟到本帧输入处理结束之后再删。
	VivdWindowsNode.remove_window.call_deferred(WINDOW_NAME)


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

## 注册命令到终端窗口
func _register(cmd_name: String, handler: Callable, help := "", usage := "") -> void:
	VivdWindowsNode.call_window_method(WINDOW_NAME, "register_command",
		[cmd_name, handler, help, usage])


## 调窗口方法并等待协程跑完（call_window_method 不会 	
func _call(window_name: String, method: String, args: Array = []) -> void:
	var w = VivdWindowsNode.find_window(window_name)
	if w == null:
		return
	await w.callv(method, args)


func _out(method: String, args: Array) -> void:
	VivdWindowsNode.call_window_method(WINDOW_NAME, method, args)


func _term():
	var w = VivdWindowsNode.find_window(WINDOW_NAME)
	return w


func _on_window_added(window_name: String, _window: Window) -> void:
	print("[demo] 窗口已打开：", window_name)


func _on_window_removed(window_name: String, _window: Window) -> void:
	print("[demo] 窗口已关闭：", window_name)
