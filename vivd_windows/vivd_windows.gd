extends Node
## vivd 多窗口管理器 —— 在 project.godot 里注册为 autoload，名字是 [b]VivdWindowsNode[/b]。
##
## 负责按"窗口类型"动态创建/销毁窗口，并提供移动、缩放、淡入淡出、方法调用等能力，
## 给剧本开发提供多窗口演出的基础设施。
##
## [b]最小用法[/b]
## [codeblock]
## VivdWindowsNode.set_dev(true)
## VivdWindowsNode.add_window("tip", "default", {
##     "title": "提示",
##     "position": Vector2i(500, 500),
##     "size": Vector2i(400, 240),
## })
## VivdWindowsNode.move_window("tip", Vector2i(100, 100), 0.5)
## VivdWindowsNode.remove_window("tip")
## [/codeblock]
##
## [b]关于返回值和错误[/b]：所有 API 都返回真实结果（Window / bool / Variant），
## 失败时 push_warning/push_error 说明原因，不再只是 print 一行了事。
##
## [b]设计前提[/b]：工程的 [code]display/window/subwindows/embed_subwindows=false[/code]，
## 也就是每个窗口都是[b]真实的操作系统窗口[/b]，不是嵌在游戏画面里的。
## 注意 headless 运行时 Godot 会强制改成内嵌，所以命令行自检看到的窗口行为和正式运行不同。

## 窗口创建成功。window 是实例本身。
signal window_added(window_name: String, window: Window)
## 窗口被移除（含用户点 X 关闭）。
signal window_removed(window_name: String, window: Window)
## 新注册了一个窗口类型。
signal window_type_registered(type_name: String)
## 注销了一个窗口类型。
signal window_type_unregistered(type_name: String)

## move_window / resize_window 不传 duration 时用的默认动画时长。
const DEFAULT_ANIMATION_DURATION := 0.5

## 窗口类型表：键是类型名，值是窗口场景。可在检查器里编辑，也可运行时注册。
@export var window_types: Dictionary[String, PackedScene] = {}

## 是否开启调试浮层。打开后每个窗口左上角会显示 position/size/title 等实时信息。
@export var dev_mode: bool = false

## 默认动画时长（秒）。传 0 给具体方法则是立即生效。
@export var animation_duration: float = DEFAULT_ANIMATION_DURATION

## 启动时自动扫描这些目录，把里面的 *.tscn 按文件名注册成窗口类型。
## 留空则不扫描。方便"往目录里丢一个场景就能当窗口用"。
@export var auto_scan_dirs: PackedStringArray = PackedStringArray()

var _windows: Dictionary[String, Window] = {}
var _tweens: Dictionary[String, Tween] = {}


func _ready() -> void:
	for dir_path in auto_scan_dirs:
		var count := scan_window_types(dir_path)
		if count > 0:
			print("[VivdWindows] 从 %s 自动注册了 %d 个窗口类型" % [dir_path, count])


# ─────────────────────────────────────────────────────────────────────────────
#  窗口增删查
# ─────────────────────────────────────────────────────────────────────────────

## 创建一个窗口。
##
## [param window_name] 窗口的唯一标识，也是节点名。重名会被拒绝（原来的实现会静默覆盖并泄漏旧窗口）。
## [param type_name]   窗口类型名，需已在 window_types 里注册。
## [param config]      配置字典。管理器认识这几个键：[code]title[/code]、[code]position[/code]、
##                     [code]size[/code]；其余键（含通用开关 always_on_top 等）会原样传给窗口的 setup()。
##
## 返回创建出来的 Window；失败返回 null。
func add_window(window_name: String, type_name: String, config: Dictionary = {}) -> Window:
	if window_name.strip_edges().is_empty():
		push_error("[VivdWindows] 窗口名不能为空")
		return null
	if _windows.has(window_name):
		push_error("[VivdWindows] 窗口已存在：%s（先 remove_window 或换个名字）" % window_name)
		return null
	if not window_types.has(type_name):
		push_error("[VivdWindows] 未注册的窗口类型：%s（已注册：%s）"
				% [type_name, ", ".join(list_window_types())])
		return null

	var scene: PackedScene = window_types[type_name]
	var window: Window = scene.instantiate()
	if window == null:
		push_error("[VivdWindows] 场景实例化失败：%s" % type_name)
		return null

	window.name = window_name
	# 位置/尺寸必须在入树之前设好，否则窗口会先在场景默认位置露一帧，再被动画拖走（原来的滑动闪烁）
	if config.has("title"):
		window.title = str(config["title"])
	if config.has("position"):
		window.position = Vector2i(config["position"])
	if config.has("size"):
		window.size = Vector2i(config["size"])

	_windows[window_name] = window
	add_child(window)

	if window.has_signal("vivd_close_requested"):
		window.vivd_close_requested.connect(_on_window_close_requested)
	if window.has_method("vivd_setup"):
		window.vivd_setup(config)
	if window.has_method("vivd_set_dev"):
		window.vivd_set_dev(dev_mode)

	window_added.emit(window_name, window)
	return window


## 移除并释放窗口。返回是否真的移除了。
func remove_window(window_name: String) -> bool:
	if not _windows.has(window_name):
		push_warning("[VivdWindows] 要移除的窗口不存在：%s" % window_name)
		return false

	var window: Window = _windows[window_name]
	# 顺序很重要：先取出引用，再抹表，最后才动节点。
	# 原来的实现是 erase 之后再 windows[_name]，取到空值必报错，而且从不 queue_free，窗口永远泄漏。
	_windows.erase(window_name)
	_kill_tween(window_name)

	if is_instance_valid(window):
		if window.has_method("teardown"):
			window.teardown()
		# 如果这个子窗口正持有 OS 焦点，直接 remove_child 之后，输入事件还会被
		# 送往这个已经离树的 Viewport，触发 Godot 报
		#   _push_shortcut_input_internal: Condition "!is_inside_tree()" is true.
		# 所以先把焦点交还给主窗口，再拆节点。
		if window.has_focus() and is_inside_tree():
			get_tree().root.grab_focus()
		if window.get_parent() == self:
			remove_child(window)
		window.queue_free()

	window_removed.emit(window_name, window)
	return true


## 窗口是否存在。
func has_window(window_name: String) -> bool:
	return _windows.has(window_name)


## 取窗口实例，不存在返回 null。
##
## [b]注意名字[/b]：不能叫 [code]get_window[/code]，那会覆盖 [method Node.get_window]，
## 而本工程把这条警告当错误处理。
func find_window(window_name: String) -> Window:
	return _windows.get(window_name)


## 当前所有窗口名。
func list_windows() -> PackedStringArray:
	var names := PackedStringArray()
	for key in _windows:
		names.append(key)
	return names


## 当前窗口数量。
func window_count() -> int:
	return _windows.size()


## 移除所有窗口。
func clear_windows() -> void:
	for window_name in list_windows():
		remove_window(window_name)


# ─────────────────────────────────────────────────────────────────────────────
#  窗口操作
# ─────────────────────────────────────────────────────────────────────────────

## 移动窗口。
##
## [param duration] 小于 0（默认）用 [member animation_duration]；等于 0 立即生效；大于 0 为动画秒数。
## 同一个窗口的重复动画会自动 kill 掉上一个，不会互相打架。
func move_window(window_name: String, position: Vector2i, duration: float = -1.0) -> bool:
	var window := find_window(window_name)
	if window == null:
		push_warning("[VivdWindows] 移动失败，窗口不存在：%s" % window_name)
		return false

	var seconds := animation_duration if duration < 0.0 else duration
	if seconds <= 0.0:
		window.position = position
		return true

	var tween := _make_tween(window_name, window)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(window, "position", position, seconds)
	return true


## 调整窗口大小。duration 语义同 move_window。
func resize_window(window_name: String, size: Vector2i, duration: float = -1.0) -> bool:
	var window := find_window(window_name)
	if window == null:
		push_warning("[VivdWindows] 缩放失败，窗口不存在：%s" % window_name)
		return false

	var seconds := animation_duration if duration < 0.0 else duration
	if seconds <= 0.0:
		window.size = size
		return true

	var tween := _make_tween(window_name, window)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(window, "size", size, seconds)
	return true


## 调用窗口上的方法。
##
## [param args] 是参数数组，会[b]展开[/b]传给方法（用 callv）。
## 例：[code]call_window_method("tip", "set_text", ["你好"])[/code] → 调用 [code]set_text("你好")[/code]。
## 返回方法返回值；窗口或方法不存在时 push_warning 并返回 null。
func call_window_method(window_name: String, method: String, args: Array = []) -> Variant:
	var window := find_window(window_name)
	if window == null:
		push_warning("[VivdWindows] 调用失败，窗口不存在：%s" % window_name)
		return null
	if not window.has_method(method):
		push_warning("[VivdWindows] 窗口 %s 上没有方法 %s" % [window_name, method])
		return null
	return window.callv(method, args)


## 窗口淡入。
func fade_window_in(window_name: String, duration := 0.2) -> bool:
	var window := find_window(window_name)
	if window == null:
		push_warning("[VivdWindows] 淡入失败，窗口不存在：%s" % window_name)
		return false
	if window.has_method("fade_in"):
		window.fade_in(duration)
	return true


## 窗口淡出并隐藏。
func fade_window_out(window_name: String, duration := 0.2, hide_after := true) -> bool:
	var window := find_window(window_name)
	if window == null:
		push_warning("[VivdWindows] 淡出失败，窗口不存在：%s" % window_name)
		return false
	if window.has_method("fade_out"):
		window.fade_out(duration, hide_after)
	return true


## 把窗口提到最前。
func bring_window_to_front(window_name: String) -> bool:
	var window := find_window(window_name)
	if window == null:
		push_warning("[VivdWindows] 前置失败，窗口不存在：%s" % window_name)
		return false
	if window.has_method("bring_to_front"):
		window.bring_to_front()
	return true


# ─────────────────────────────────────────────────────────────────────────────
#  调试模式
# ─────────────────────────────────────────────────────────────────────────────

## 开关调试浮层。会[b]同时作用到已经打开的窗口[/b]（原来只影响之后新建的窗口）。
func set_dev(enabled: bool) -> void:
	dev_mode = enabled
	for window in _windows.values():
		if is_instance_valid(window) and window.has_method("vivd_set_dev"):
			window.vivd_set_dev(enabled)


func is_dev() -> bool:
	return dev_mode


# ─────────────────────────────────────────────────────────────────────────────
#  窗口类型注册
# ─────────────────────────────────────────────────────────────────────────────

## 注册一个窗口类型。返回是否成功（重复注册会覆盖并返回 false）。
func register_window_type(type_name: String, scene: PackedScene) -> bool:
	if type_name.strip_edges().is_empty():
		push_error("[VivdWindows] 窗口类型名不能为空")
		return false
	if scene == null:
		push_error("[VivdWindows] 窗口类型 %s 的场景为空" % type_name)
		return false

	var is_new := not window_types.has(type_name)
	window_types[type_name] = scene
	if is_new:
		window_type_registered.emit(type_name)
	return is_new


## 注销一个窗口类型。已经打开的窗口不受影响。
func unregister_window_type(type_name: String) -> bool:
	if not window_types.has(type_name):
		return false
	window_types.erase(type_name)
	window_type_unregistered.emit(type_name)
	return true


## 取窗口类型的场景，不存在返回 null。
func get_window_type(type_name: String) -> PackedScene:
	return window_types.get(type_name)


## 是否已注册该窗口类型。
func has_window_type(type_name: String) -> bool:
	return window_types.has(type_name)


## 所有已注册的窗口类型名。
func list_window_types() -> PackedStringArray:
	var names := PackedStringArray()
	for key in window_types:
		names.append(key)
	return names


## 扫描目录，把里面的 *.tscn 按文件名注册成窗口类型。
##
## 会自动跳过根节点不是 Window 的场景。返回注册成功的数量。
func scan_window_types(dir_path: String) -> int:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("[VivdWindows] 目录打不开：%s" % dir_path)
		return 0

	var count := 0
	for file_name in dir.get_files():
		if not file_name.ends_with(".tscn"):
			continue
		var scene := load(dir_path.path_join(file_name)) as PackedScene
		if scene == null:
			# 场景加载失败（比如它依赖的插件没装）就跳过，不影响其它类型
			continue
		if not _scene_root_is_window(scene):
			continue
		if register_window_type(file_name.get_basename(), scene):
			count += 1
	return count


## 判断场景的根节点是不是 [Window]。
##
## [b]不要用 [method SceneState.get_node_type][/b]：继承场景（[code]instance=[/code] 指向另一个
## 场景）的根节点是那个场景的实例，该接口会返回[b]空字符串[/b]，
## 于是所有继承来的窗口类型都会被误判掉。实例化是最可靠的判断，
## 而且不入树就不会触发 [method Node._ready]，没有副作用。
static func _scene_root_is_window(scene: PackedScene) -> bool:
	var probe := scene.instantiate()
	if probe == null:
		return false
	var is_window := probe is Window
	probe.free()
	return is_window


# ─────────────────────────────────────────────────────────────────────────────
#  内部实现
# ─────────────────────────────────────────────────────────────────────────────

func _make_tween(window_name: String, window: Window) -> Tween:
	_kill_tween(window_name)
	var tween := create_tween()
	# 绑到窗口上：窗口被移除时动画自动停，不会对着已释放的节点报错
	tween.bind_node(window)
	_tweens[window_name] = tween
	return tween


func _kill_tween(window_name: String) -> void:
	var tween: Tween = _tweens.get(window_name)
	if tween != null and tween.is_valid():
		tween.kill()
	_tweens.erase(window_name)


func _on_window_close_requested(window_name: String) -> void:
	# 用户点了窗口的 X：直接销毁，不留幽灵条目
	remove_window(window_name)
