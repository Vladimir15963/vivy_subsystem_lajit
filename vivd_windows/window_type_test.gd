extends Control
## vivd_windows 全类型窗口测试场景。
##
## 覆盖全部 6 种已注册类型：default / image / file_examin / video / text / terminal。
## 每种类型可以单独「开」「关」，还能「调方法」验证 call_window_method 的参数展开。
##
## [b]注意[/b]：vivd 窗口是真实 OS 窗口（工程里 embed_subwindows=false），
## 所以点「开」之后窗口会出现在主画面[b]外面[/b] —— 留意任务栏。
## 多个窗口会按层叠错开摆放，避免完全重叠。
##
## 运行：打开本场景按 F6，或
## [code]godot --path . res://vivd_windows/window_type_test.tscn[/code]

const C_ACCENT := "#61afef"
const C_OK := "#98c379"
const C_WARN := "#e5c07b"
const C_ERR := "#e06c75"
const C_DIM := "#5c6370"

## 日志最多保留多少行（防止长时间运行把内存吃满）
const MAX_LOG_LINES := 200

## 层叠摆放的起点和步进
const CASCADE_ORIGIN := Vector2i(70, 60)
const CASCADE_STEP := Vector2i(46, 42)

## 6 种类型的测试规格。
## "probe" 是「调方法」按钮要调的类型专属方法（null 表示该类型没有可调的）。
const TYPE_SPECS: Array[Dictionary] = [
	{
		"type": "default",
		"label": "default 通用窗口",
		"desc": "基类能力：淡入淡出 / 移动 / dev 浮层",
		"size": Vector2i(400, 200),
		"config": {},
		"probe": {"method": "ping", "args": ["hello", "world"], "why": "验证参数展开"},
	},
	{
		"type": "image",
		"label": "image 图片窗口",
		"desc": "TextureRect 显示图片（assets/test.webp）",
		"size": Vector2i(340, 340),
		"config": {"image": "res://assets/test.webp"},
		"probe": {"method": "fit_to_window", "args": [], "why": "填充模式"},
	},
	{
		"type": "file_examin",
		"label": "file_examin 拖放窗口",
		"desc": "把文件拖进窗口（headless/自检下收不到）",
		"size": Vector2i(420, 190),
		"config": {},
		"probe": null,
	},
	{
		"type": "video",
		"label": "video 视频窗口",
		"desc": "内置 Theora 后端（.ogv），不依赖 VLC 插件",
		"size": Vector2i(360, 300),
		"config": {
			"video": "res://vivd_windows/sample/sample_5s.ogv",
			"autoplay": true,
			"loop": true,
		},
		"probe": {"method": "toggle_pause", "args": [], "why": "暂停 / 继续"},
	},
	{
		"type": "text",
		"label": "text 文本窗口",
		"desc": "RichTextLabel + BBCode，逐字显示",
		"size": Vector2i(500, 320),
		"config": {
			"text": "[center][b]全类型窗口测试[/b][/center]\n\n"
				+ "这一段是 [color=#e5c07b]BBCode[/color] 渲染的。\n"
				+ "点「调方法」会往这里追加一行。",
			"font_size": 18,
		},
		"probe": {"method": "append_line", "args": ["追加的一行中文 —— 对齐正常"], "why": "追加内容"},
	},
	{
		"type": "terminal",
		"label": "terminal 终端窗口",
		"desc": "伪终端（无 PTY），可输入命令",
		"size": Vector2i(700, 420),
		"config": {
			"font_size": 15,
			"banner": "全类型窗口测试 · 终端就绪",
		},
		"probe": {"method": "println", "args": ["[color=cyan]来自测试面板的输出[/color]"], "why": "往终端打印"},
	},
]

@onready var _type_rows: VBoxContainer = $Margin/VBox/TypeRows
@onready var _actions: HFlowContainer = $Margin/VBox/Actions
@onready var _status: RichTextLabel = $Margin/VBox/Status
@onready var _log: RichTextLabel = $Margin/VBox/Log

var _log_lines: Array[String] = []
var _status_timer: Timer
var _dev_on := false
## type -> 最近一次用过的窗口名（同名会被层叠计数器影响，所以记下来）
var _window_of_type: Dictionary[String, String] = {}


func _ready() -> void:
	_build_type_rows()
	_build_action_buttons()

	VivdWindowsNode.window_added.connect(_on_window_added)
	VivdWindowsNode.window_removed.connect(_on_window_removed)

	_status_timer = Timer.new()
	_status_timer.wait_time = 0.25
	_status_timer.autostart = true
	_status_timer.timeout.connect(_refresh_status)
	add_child(_status_timer)

	_log_line("[b]已注册类型：[/b]" + ", ".join(VivdWindowsNode.list_window_types()))
	_log_line("[color=%s]点上面的「开」逐个测试，或点「全部打开」。窗口在主画面外面。[/color]" % C_DIM)
	_refresh_status()


# ---------------------------------------------------------------------------
#  构建 UI
# ---------------------------------------------------------------------------

func _build_type_rows() -> void:
	for spec in TYPE_SPECS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

		var label := Label.new()
		label.text = spec["label"]
		label.custom_minimum_size = Vector2(170, 0)
		label.tooltip_text = spec["desc"]
		row.add_child(label)

		var desc := Label.new()
		desc.text = spec["desc"]
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		desc.add_theme_color_override("font_color", Color(C_DIM))
		desc.add_theme_font_size_override("font_size", 12)
		row.add_child(desc)

		var open_btn := Button.new()
		open_btn.text = "开"
		open_btn.tooltip_text = "打开一个 %s 窗口" % spec["type"]
		open_btn.pressed.connect(_open_type.bind(spec["type"]))
		row.add_child(open_btn)

		var close_btn := Button.new()
		close_btn.text = "关"
		close_btn.tooltip_text = "关闭该类型的窗口"
		close_btn.pressed.connect(_close_type.bind(spec["type"]))
		row.add_child(close_btn)

		var probe: Variant = spec["probe"]
		var probe_btn := Button.new()
		probe_btn.text = "调方法"
		if probe == null:
			probe_btn.disabled = true
			probe_btn.tooltip_text = "该类型没有专属方法"
		else:
			probe_btn.tooltip_text = "call_window_method(%s, %s)" % [spec["type"], probe["method"]]
			probe_btn.pressed.connect(_probe_type.bind(spec["type"]))
		row.add_child(probe_btn)

		_type_rows.add_child(row)


func _build_action_buttons() -> void:
	_add_action("全部打开", _open_all, "把 6 种类型各开一个")
	_add_action("全部关闭", _close_all, "移除所有窗口")
	_add_action("清空日志", _clear_log, "只清日志，不动窗口")
	_add_action("移动(动画)", _move_all, "move_window，0.4 秒")
	_add_action("立刻移动", _move_all_instant, "duration=0，瞬移")
	_add_action("放大", _resize_bigger, "resize_window 变宽 80px")
	_add_action("缩小", _resize_smaller, "resize_window 变窄 80px")
	_add_action("淡入", _fade_in, "内容透明度 0→1")
	_add_action("淡出", _fade_out, "内容透明度 →0 并隐藏")
	_add_action("置顶", _bring_front, "依次 grab_focus")
	_add_action("dev 浮层", _toggle_dev, "切换左上角属性浮层")
	_add_action("打印清单", _dump_windows, "在日志里输出每个窗口的位置尺寸")


func _add_action(text: String, handler: Callable, tip := "") -> void:
	var btn := Button.new()
	btn.text = text
	btn.tooltip_text = tip
	btn.pressed.connect(handler)
	_actions.add_child(btn)


# ---------------------------------------------------------------------------
#  开 / 关
# ---------------------------------------------------------------------------

## 给某个类型分配一个窗口名。同名会触发 [VivdWindows] 报错，所以用序号错开。
func _next_window_name(type_name: String) -> String:
	var i := 1
	while VivdWindowsNode.has_window("%s_%d" % [type_name, i]):
		i += 1
	return "%s_%d" % [type_name, i]


func _spec_of(type_name: String) -> Dictionary:
	for spec in TYPE_SPECS:
		if spec["type"] == type_name:
			return spec
	return {}


func _open_type(type_name: String) -> void:
	var spec := _spec_of(type_name)
	if spec.is_empty():
		_log_line("[color=%s]没有这个类型的测试规格：%s[/color]" % [C_ERR, type_name])
		return

	var window_name := _next_window_name(type_name)
	var config: Dictionary = (spec["config"] as Dictionary).duplicate(true)

	# 层叠摆放，避免 6 个窗口完全重叠
	var index := _window_of_type.size() % 6
	config["title"] = spec["label"]
	config["position"] = CASCADE_ORIGIN + CASCADE_STEP * index
	config["size"] = spec["size"]

	var w = VivdWindowsNode.add_window(window_name, type_name, config)
	if w == null:
		_log_line("[color=%s]开失败：%s（看控制台的 [VivdWindows] 报错）[/color]" % [C_ERR, window_name])
		return

	_window_of_type[type_name] = window_name
	VivdWindowsNode.fade_window_in(window_name, 0.2)
	_log_line("[color=%s]开[/color] %s  →  %s  size=%s" % [
		C_OK, type_name, window_name, str(spec["size"]),
	])


func _close_type(type_name: String) -> void:
	# 关掉该类型所有实例，而不只是最近那个
	var closed := 0
	for wname in VivdWindowsNode.list_windows():
		if wname.begins_with(type_name + "_"):
			if VivdWindowsNode.remove_window(wname):
				closed += 1
	_window_of_type.erase(type_name)

	if closed == 0:
		_log_line("[color=%s]%s 没有开着的窗口[/color]" % [C_WARN, type_name])
	else:
		_log_line("[color=%s]关[/color] %s  ×%d" % [C_WARN, type_name, closed])


func _open_all() -> void:
	for spec in TYPE_SPECS:
		_open_type(spec["type"])
	_log_line("[color=%s]已请求打开全部 %d 种类型[/color]" % [C_ACCENT, TYPE_SPECS.size()])


func _close_all() -> void:
	VivdWindowsNode.clear_windows()
	_window_of_type.clear()
	_log_line("[color=%s]已清空所有窗口[/color]" % [C_WARN])


# ---------------------------------------------------------------------------
#  调方法
# ---------------------------------------------------------------------------

func _probe_type(type_name: String) -> void:
	var spec := _spec_of(type_name)
	var probe: Variant = spec.get("probe")
	if probe == null:
		_log_line("[color=%s]%s 没有专属方法[/color]" % [C_DIM, type_name])
		return

	var window_name: String = _window_of_type.get(type_name, "")
	if window_name.is_empty() or not VivdWindowsNode.has_window(window_name):
		_log_line("[color=%s]%s 还没开窗口，先点「开」[/color]" % [C_WARN, type_name])
		return

	# call_window_method 会把 args 数组展开传进去
	var result = VivdWindowsNode.call_window_method(window_name, probe["method"], probe["args"])
	_log_line("[color=%s]调方法[/color] %s.%s(%s)  →  %s  [color=%s](%s)[/color]" % [
		C_ACCENT,
		window_name,
		probe["method"],
		", ".join(probe["args"].map(func(a): return str(a))),
		str(result),
		C_DIM,
		probe["why"],
	])


# ---------------------------------------------------------------------------
#  通用操作
# ---------------------------------------------------------------------------

func _each_window(fn: Callable) -> int:
	var names := VivdWindowsNode.list_windows()
	for wname in names:
		fn.call(wname)
	return names.size()


func _move_all() -> void:
	var n := _each_window(func(wname: String) -> void:
		var w = VivdWindowsNode.find_window(wname)
		if w != null:
			VivdWindowsNode.move_window(wname, w.position + Vector2i(80, 60), 0.4)
	)
	_log_line("移动 %d 个窗口（0.4 秒动画）" % n)


func _move_all_instant() -> void:
	var n := _each_window(func(wname: String) -> void:
		var w = VivdWindowsNode.find_window(wname)
		if w != null:
			VivdWindowsNode.move_window(wname, w.position + Vector2i(-80, -60), 0.0)
	)
	_log_line("瞬移 %d 个窗口（duration=0）" % n)


func _resize_bigger() -> void:
	var n := _each_window(func(wname: String) -> void:
		var w = VivdWindowsNode.find_window(wname)
		if w != null:
			VivdWindowsNode.resize_window(wname, w.size + Vector2i(80, 0), 0.2)
	)
	_log_line("加宽 %d 个窗口" % n)


func _resize_smaller() -> void:
	var n := _each_window(func(wname: String) -> void:
		var w = VivdWindowsNode.find_window(wname)
		if w != null:
			VivdWindowsNode.resize_window(wname, Vector2i(maxi(w.size.x - 80, 240), w.size.y), 0.2)
	)
	_log_line("收窄 %d 个窗口" % n)


func _fade_in() -> void:
	var n := _each_window(func(wname: String) -> void:
		VivdWindowsNode.fade_window_in(wname, 0.25)
	)
	_log_line("淡入 %d 个窗口" % n)


func _fade_out() -> void:
	var n := _each_window(func(wname: String) -> void:
		VivdWindowsNode.fade_window_out(wname, 0.25, false)
	)
	_log_line("淡出 %d 个窗口（hide_after=false，看得见变透明）" % n)


func _bring_front() -> void:
	var n := _each_window(func(wname: String) -> void:
		VivdWindowsNode.bring_window_to_front(wname)
	)
	_log_line("置顶 %d 个窗口" % n)


func _toggle_dev() -> void:
	_dev_on = not _dev_on
	VivdWindowsNode.set_dev(_dev_on)
	_log_line("[color=%s]dev 浮层 %s[/color]" % [C_ACCENT, "开" if _dev_on else "关"])


func _dump_windows() -> void:
	var names := VivdWindowsNode.list_windows()
	if names.is_empty():
		_log_line("当前没有窗口")
		return
	_log_line("[b]窗口清单（%d）：[/b]" % names.size())
	for wname in names:
		var w = VivdWindowsNode.find_window(wname)
		if w == null:
			continue
		_log_line("  %s  pos=%s  size=%s  visible=%s  title=%s" % [
			wname, str(w.position), str(w.size), str(w.visible), w.title,
		])


func _clear_log() -> void:
	_log_lines.clear()
	_log.clear()


# ---------------------------------------------------------------------------
#  状态刷新 / 信号
# ---------------------------------------------------------------------------

func _refresh_status() -> void:
	if _status == null:
		return
	var names := VivdWindowsNode.list_windows()
	var lines: Array[String] = []
	lines.append("已注册类型 %d 种 | 当前窗口 %d 个 | dev 浮层 %s" % [
		VivdWindowsNode.list_window_types().size(),
		names.size(),
		"开" if VivdWindowsNode.is_dev() else "关",
	])
	if names.is_empty():
		lines.append("[color=%s]（没有窗口）[/color]" % C_DIM)
	else:
		for wname in names:
			var w = VivdWindowsNode.find_window(wname)
			if w == null:
				continue
			var vis_color := C_OK if w.visible else C_WARN
			lines.append("  %s  [color=%s]%s[/color]  pos=%s  size=%s" % [
				wname,
				vis_color,
				"显示" if w.visible else "隐藏",
				str(w.position),
				str(w.size),
			])
	_status.text = "\n".join(lines)


func _on_window_added(window_name: String, _window: Window) -> void:
	_log_line("[color=%s]window_added[/color] → %s" % [C_OK, window_name])


func _on_window_removed(window_name: String, _window: Window) -> void:
	_log_line("[color=%s]window_removed[/color] → %s" % [C_WARN, window_name])


# ---------------------------------------------------------------------------
#  日志
# ---------------------------------------------------------------------------

func _log_line(bbcode: String) -> void:
	if _log == null:
		return
	_log_lines.append(bbcode)
	while _log_lines.size() > MAX_LOG_LINES:
		_log_lines.pop_front()
	_log.text = "\n".join(_log_lines)
	# 让滚动条跟到最新一行
	_log.scroll_to_line(_log.get_line_count())
