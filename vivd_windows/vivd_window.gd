class_name VivdWindow
extends Window
## vivd 窗口基类 —— 所有窗口类型都继承它。
##
## 继承后自动获得这些能力，不用再在每个窗口脚本里复制粘贴：
##
## * [b]setup()/teardown() 生命周期[/b]：取代原来把裸数组塞进 [code]_start(args)[/code] 的做法。
## * [b]fade_in()/fade_out()[/b]：真正的淡入淡出（原来只是 print 的空壳）。
## * [b]代码生成的 dev 浮层[/b]：不再要求每个场景都摆好 [code]dev/Control/devinfo[/code] 节点，
##   所以照模板新建的窗口不会再每帧刷 "Node not found" 报错。
## * [b]关闭按钮联动[/b]：点窗口的 X 会发 [signal vivd_close_requested]，管理器据此注销，
##   不会留下关不掉的幽灵窗口。
##
## [b]子类只需要：[/b]
## [codeblock]
## extends "res://vivd_windows/vivd_window.gd"
##
## func setup(config: Dictionary) -> void:
##     $Content/Label.text = str(config.get("text", ""))
## [/codeblock]
##
## [b]为什么子类用路径式 extends 而不是 [code]extends VivdWindow[/code]？[/b]
## 全局类名要等编辑器扫描过、把 VivdWindow 写进 .godot/global_script_class_cache.cfg
## 之后才解析得到。路径式 extends 不依赖那个缓存，headless / CI / 刚克隆下来都能直接跑。
## 基类这里仍然保留 class_name，编辑器里照样能把 VivdWindow 当类型用。
##
## [b]注意[/b]：Window 不是 CanvasItem，[b]没有 modulate[/b]。所以淡入淡出是作用在
## 窗口的[b]直接子内容节点[/b]上的。想要真正的"透明穿透"效果，需要把
## [member Window.transparent] 设成 true（工程已开 per_pixel_transparency）。

## 用户点了窗口关闭按钮。管理器接这个信号来注销窗口。
signal vivd_close_requested(window_name: String)

## setup() 执行完毕。
signal vivd_ready(window_name: String)

## dev 浮层默认监视的属性。
##
## 用[b]属性名[/b]而不是"场景里必须有个叫 position 的节点"，所以对任何窗口类型都成立，
## 也不依赖场景结构 —— 这正是原来那版每帧报错的根因。
const DEV_WATCH_DEFAULT: PackedStringArray = ["position", "size", "visible", "title"]

## dev 浮层刷新间隔（秒）。用 Timer 而不是 _process，这样子类可以随意重写 _process 而不影响浮层。
const DEV_REFRESH_INTERVAL := 0.1

## 这个窗口要监视哪些属性，子类可以覆盖。
var dev_watch: PackedStringArray = DEV_WATCH_DEFAULT

var _setup_done := false
var _dev_enabled := false
var _dev_panel: Control = null
var _dev_timer: Timer = null
var _dev_labels: Dictionary[String, Label] = {}
var _dev_text_cache: Dictionary[String, String] = {}
var _fade_tween: Tween = null
## 淡出淡出时记住每个内容节点原本的 alpha，避免反复淡入淡出把透明度叠乘坏掉。
var _fade_base_alpha: Dictionary = {}


func _ready() -> void:
	_ensure_base_ready()


## ── 生命周期钩子（子类重写）────────────────────────────────────

## 子类重写这个来做初始化。config 就是 add_window() 收到的那本字典。
func setup(_config: Dictionary) -> void:
	pass


## 子类可选重写。窗口被移除前调用，用来断开连接、保存状态等。
func teardown() -> void:
	pass


## ── 供管理器调用（子类一般不用管）────────────────────────────

## 由管理器在 add_child 之后调用。
func vivd_setup(config: Dictionary) -> void:
	_ensure_base_ready()
	if _setup_done:
		return
	_setup_done = true
	apply_window_flags(config)
	setup(config)
	vivd_ready.emit(name)


## 由管理器调用：切换调试浮层。
func vivd_set_dev(enabled: bool) -> void:
	_ensure_base_ready()
	# 子类可能在 _init() 或 setup() 里改过 dev_watch。setup() 是在 _ready() 之后调的，
	# 那时浮层已经按默认列表建好了，所以这里对不上就重建一次。
	if not _dev_watch_matches():
		_teardown_dev_overlay()
		_build_dev_overlay()
	_dev_enabled = enabled
	if _dev_panel != null:
		_dev_panel.visible = enabled
	if _dev_timer != null:
		if enabled:
			_dev_text_cache.clear()
			_refresh_dev_labels()
			_dev_timer.start()
		else:
			_dev_timer.stop()


func is_dev() -> bool:
	return _dev_enabled


## ── 通用能力 ────────────────────────────────────────────────

## 从 config 里读取一批通用窗口开关。vivd_setup() 会自动调用，子类不用管。
func apply_window_flags(config: Dictionary) -> void:
	if config.has("always_on_top"):
		always_on_top = bool(config["always_on_top"])
	if config.has("unresizable"):
		unresizable = bool(config["unresizable"])
	if config.has("borderless"):
		borderless = bool(config["borderless"])
	if config.has("transparent"):
		transparent = bool(config["transparent"])
	if config.has("wrap_controls"):
		wrap_controls = bool(config["wrap_controls"])
	if config.has("exclusive"):
		exclusive = bool(config["exclusive"])


## 淡入。返回 Tween，想等它结束就 [code]await win.fade_in().finished[/code]。
func fade_in(duration := 0.2) -> Tween:
	_kill_fade()
	show()
	var tween := _make_fade_tween()
	tween.tween_method(_apply_content_alpha, 0.0, 1.0, maxf(duration, 0.0))
	return tween


## 淡出。hide_after 为 true 时动画结束后隐藏窗口。
func fade_out(duration := 0.2, hide_after := true) -> Tween:
	_kill_fade()
	var tween := _make_fade_tween()
	tween.tween_method(_apply_content_alpha, _current_content_alpha(), 0.0, maxf(duration, 0.0))
	if hide_after:
		tween.tween_callback(hide)
	return tween


## 立刻把内容透明度恢复到 1，并停止进行中的淡入淡出。
func fade_stop() -> void:
	_kill_fade()
	_apply_content_alpha(1.0)
	_fade_base_alpha.clear()


## 把窗口提到最前并获得焦点。
func bring_to_front() -> void:
	if not visible:
		show()
	# 4.7 起 move_to_foreground() 已弃用，grab_focus() 就会把窗口提到前台
	grab_focus()


## 屏幕坐标下的窗口中心点。
func get_center() -> Vector2i:
	@warning_ignore("integer_division")
	var half := size / 2
	return position + half


## 直接子节点里可以用作淡入淡出的内容节点。
func get_content_items() -> Array[CanvasItem]:
	var items: Array[CanvasItem] = []
	for child in get_children():
		if child is CanvasItem:
			items.append(child)
	return items


## ── 内部实现 ────────────────────────────────────────────────

func _ensure_base_ready() -> void:
	if not close_requested.is_connected(_on_close_requested):
		close_requested.connect(_on_close_requested)
	if _dev_panel == null:
		_build_dev_overlay()


## dev_watch 和当前浮层上已经建好的标签是否一致。
func _dev_watch_matches() -> bool:
	if _dev_labels.size() != dev_watch.size():
		return false
	for property in dev_watch:
		if not _dev_labels.has(property):
			return false
	return true


## 拆掉 dev 浮层（重建前调用）。这里用 free() 而不是 queue_free()，
## 否则旧节点要等到下一帧才消失，新节点会因为重名被 Godot 改名。
func _teardown_dev_overlay() -> void:
	if _dev_timer != null:
		_dev_timer.stop()
		if _dev_timer.get_parent() == self:
			remove_child(_dev_timer)
		_dev_timer.free()
		_dev_timer = null
	if _dev_panel != null:
		if _dev_panel.get_parent() == self:
			remove_child(_dev_panel)
		_dev_panel.free()
		_dev_panel = null
	_dev_labels.clear()
	_dev_text_cache.clear()


func _make_fade_tween() -> Tween:
	_fade_tween = create_tween()
	_fade_tween.bind_node(self)
	return _fade_tween


func _kill_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null


## 把 [0,1] 的 alpha 作用到所有内容节点上，基准值取第一次淡入淡出前的实际值。
func _apply_content_alpha(alpha: float) -> void:
	for item in get_content_items():
		if not _fade_base_alpha.has(item):
			_fade_base_alpha[item] = item.modulate.a
		var color: Color = item.modulate
		color.a = float(_fade_base_alpha[item]) * alpha
		item.modulate = color


func _current_content_alpha() -> float:
	var items := get_content_items()
	if items.is_empty():
		return 1.0
	return items[0].modulate.a


func _build_dev_overlay() -> void:
	_dev_panel = Control.new()
	_dev_panel.name = "VivdDevOverlay"
	_dev_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dev_panel.visible = false
	_dev_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_dev_panel)

	var box := VBoxContainer.new()
	box.name = "Info"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.position = Vector2(6, 4)
	_dev_panel.add_child(box)

	for property in dev_watch:
		var label := Label.new()
		label.name = property
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_color_override("font_color", Color(0.25, 1.0, 0.35))
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		label.add_theme_constant_override("outline_size", 4)
		box.add_child(label)
		_dev_labels[property] = label

	_dev_timer = Timer.new()
	_dev_timer.name = "VivdDevRefresh"
	_dev_timer.wait_time = DEV_REFRESH_INTERVAL
	_dev_timer.autostart = false
	_dev_timer.timeout.connect(_refresh_dev_labels)
	add_child(_dev_timer)


func _refresh_dev_labels() -> void:
	for property in _dev_labels:
		var text := "%s: %s" % [property, str(get(property))]
		if _dev_text_cache.get(property, "") == text:
			continue
		_dev_text_cache[property] = text
		_dev_labels[property].text = text


func _on_close_requested() -> void:
	vivd_close_requested.emit(name)
