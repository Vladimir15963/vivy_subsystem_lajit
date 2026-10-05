extends Control

## 伪终端演示：全中文输出 + 颜色 + 打字机 + 进度条 + 假命令。
## 因为不经过 PTY，写进去的就是 Godot 的 UTF-8 String，不存在乱码问题。
##
## 注意：中文能不能显示，取决于字体有没有挂上中文回退，
## 详见 fake_terminal.gd 的 _build_font() / extra_fallbacks。

@onready var term = $Margin/FakeTerminal

const C_ACCENT := Color("#61afef")
const C_OK := Color("#98c379")
const C_WARN := Color("#e5c07b")
const C_ERR := Color("#e06c75")
const C_DIM := Color("#5c6370")


func _ready() -> void:
	# FakeTerminal._ready() 会先打一个提示符出来，这里清掉，
	# 等启动动画播完再重新显示。
	term.clear_screen()

	term.register_default_commands()
	term.register_command("status", _cmd_status, "查看系统状态", "status")
	term.register_command("scan", _cmd_scan, "扫描附近的信号", "scan [范围]")
	term.register_command("connect", _cmd_connect, "连接目标节点", "connect <节点名>")
	term.register_command("whoami", _cmd_whoami, "显示当前身份", "whoami")
	term.register_command("font", _cmd_font, "检测中文字体是否可用", "font")
	term.register_command("exit", _cmd_exit, "退出（其实退不掉）", "exit")
	term.set_fallback_handler(_on_unknown)

	await _boot()


func _boot() -> void:
	var line := "══════════════════════════════════"
	term.print_line(term.colorize(line, C_ACCENT))
	term.print_line(term.colorize("  星 港 终 端   v1.0", C_ACCENT))
	term.print_line(term.colorize("  伪 终 端 演 示（无 PTY）", C_DIM))
	term.print_line(term.colorize(line, C_ACCENT))
	term.print_line()

	await term.type_line("正在初始化内核……", 0.02)
	term.print_success("内核加载完成")
	await term.type_line("正在挂载本地数据卷……", 0.02)
	term.print_success("数据卷挂载完成（3 个）")
	term.print_warn("检测到 1 个信号强度异常的节点")
	term.print_info("输入 help 查看可用命令")
	term.print_line()
	await term.progress_bar("系统自检", 1.2)
	term.print_success("自检通过，终端就绪。")
	term.print_line()
	term.print_line(term.colorize("支持：", C_DIM) + "中文显示、打字机、进度条、方向键历史、Tab 补全")
	term.show_prompt()


# ---------------------------------------------------------------------------
# 命令实现
# ---------------------------------------------------------------------------

func _cmd_status(_args: PackedStringArray) -> void:
	term.print_line(term.bold("系统状态"))
	var rows := [
		["电源", "98%", C_OK],
		["信号强度", "72%", C_WARN],
		["护盾", "已关闭", C_DIM],
		["货舱", "12 / 60 格", C_ACCENT],
		["附近节点", "4 个", C_ACCENT],
	]
	for r in rows:
		# pad_right 按显示宽度补空格，中文才对齐（String.rpad 按字符数算，会歪）
		term.print_line("  %s%s %s" % [
			term.pad_right(r[0], 14),
			term.colorize("●", r[2]),
			r[1],
		])


func _cmd_scan(args: PackedStringArray) -> void:
	var range_text: String = args[0] if args.size() > 0 else "默认"
	term.print_info("开始扫描，范围：%s" % range_text)
	await term.progress_bar("扫描中", 1.0, 24)
	term.print_line()
	var found := [
		["中继站-07", "信号良好", C_OK],
		["废弃货船 K-221", "信号微弱", C_WARN],
		["未知信标", "信号异常", C_ERR],
	]
	for f in found:
		term.print_line("  %s  %s" % [
			term.colorize(term.pad_left(f[0], 18), f[2]),
			f[1],
		])
	term.print_line()
	term.print_success("扫描完成，发现 %d 个目标。" % found.size())


func _cmd_connect(args: PackedStringArray) -> void:
	if args.size() == 0:
		term.print_error("用法：connect <节点名>")
		return
	var target := args[0]
	term.print_info("正在连接 %s ……" % target)
	await term.type_line("  握手协议：OK", 0.02)
	await term.type_line("  密钥交换：OK", 0.02)
	await term.type_line("  通道加密：OK", 0.02)
	term.print_success("已连接到 %s" % target)


func _cmd_whoami(_args: PackedStringArray) -> void:
	term.print_line("玩家（你就是玩家，不是 shell）")


func _cmd_font(_args: PackedStringArray) -> void:
	# 用来快速确认中文字体到底挂上没有
	var sample := "中文测试中文字体"
	var ok: bool = term.can_render(sample)
	if ok:
		term.print_success("中文可以正常显示")
	else:
		term.print_error("中文字体缺失，会显示成空白/方块")
		term.print_info("解决：给 FakeTerminal 的 extra_fallbacks 挂一个中文字体资源")
	term.print_line("  样例：" + sample)


func _cmd_exit(_args: PackedStringArray) -> void:
	term.print_warn("这是个伪终端，没有真的进程可以退出 :)")
	term.print_line(term.colorize("（不信你可以一直按 exit）", C_DIM))


func _on_unknown(command: String, _args: PackedStringArray) -> void:
	term.print_error("未知命令：%s" % command)
	term.print_text(term.colorize("你是指 ", C_DIM))
	term.print_text(term.colorize("help", C_ACCENT))
	term.print_line(term.colorize(" 吗？", C_DIM))
