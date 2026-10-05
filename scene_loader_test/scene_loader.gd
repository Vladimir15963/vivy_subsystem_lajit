class_name SceneLoaderService
extends Node

## 通用场景加载工具（全局单例：/root/SceneLoader，autoload 注册）
##
## 三类用法，覆盖“读条加载 / 后台预加载 / 转场切换”：
##
##   1. 启动读条（进游戏时的读条加载）
##        SceneLoader.boot_to("res://xxx/main_menu.tscn")
##
##   2. 游戏进行中预加载下一个场景（后台线程，不卡帧）
##        SceneLoader.preload_scene("res://xxx/level_2.tscn")
##        SceneLoader.get_preload_progress(path)      # 0~1，可喂给自己的进度条
##        SceneLoader.is_preloaded(path)              # 预加载完成？
##
##   3. 切换场景，可指定转场场景，也可无缝（预加载完成后瞬时切换）
##        SceneLoader.goto_scene(path, {"transition": "loading"})   # 读条转场
##        SceneLoader.goto_scene(path, {"transition": "fade"})      # 淡入淡出
##        SceneLoader.goto_scene(path, {"transition": preload("res://my_transition.tscn")})
##        SceneLoader.goto_scene(path, {"seamless": true})          # 无缝，不使用任何转场
##
## 切场后会把 options.params 交给新场景：
##   新场景根节点实现 `func on_scene_entered(params: Dictionary)`，或暴露 `scene_params` 属性。
##
## 转场场景（可选接口，全部可缺省）：
##   func set_title(text: String)        # 显示标题
##   func set_progress(ratio: float)     # 0~1，喂进度
##   func play_in()                      # 进场动画
##   func play_out()                     # 退场动画
##   signal in_finished / out_finished   # 动画结束；没有信号时用 in_duration / out_duration 属性兜底
##
## 注意：本脚本的类名 SceneLoaderService 与 autoload 名 SceneLoader 必须不同，
## 否则 Godot 会报 "Class 'SceneLoader' hides an autoload singleton"。

# ------------------------------------------------------------------ 信号

## 预加载开始
signal preload_started(path: String)
## 预加载进度（0~1）
signal preload_progress(path: String, ratio: float)
## 预加载完成（packed 已进入内存缓存）
signal preload_completed(path: String, packed: PackedScene)
## 预加载失败
signal preload_failed(path: String, error: int)
## 预加载被主动取消（后台线程仍会跑完，但结果不再记录/通知）
signal preload_cancelled(path: String)

## 一次切场开始（transition_name 为空字符串表示无缝，没有转场）
signal load_started(path: String, transition_name: String)
## 切场过程中的加载进度（0~1）
signal load_progress(path: String, ratio: float)
## 切场结束（新场景已经就位）
signal load_finished(path: String)
## 启动读条结束
signal boot_finished(path: String)
## 转场进场 / 退场动画结束
signal transition_in_finished()
signal transition_out_finished()
## 当前场景发生变化（包含外部直接调用 change_scene_* 的情况）
signal scene_changed(from_path: String, to_path: String)

# ------------------------------------------------------------------ 配置

## 内置转场：读条加载界面
const LOADING_SCREEN: PackedScene = preload("res://scene_loader_test/transitions/loading_screen.tscn")
## 内置转场：淡入淡出
const FADE_TRANSITION: PackedScene = preload("res://scene_loader_test/transitions/fade_transition.tscn")

## 默认转场。可以是 PackedScene、已注册的转场 id（String），或 null（= 无缝，不显示任何转场）
var default_transition: Variant = LOADING_SCREEN
## 转场至少显示多久（秒），防止加载太快时闪一下
var min_transition_time := 0.6
## 启动读条至少显示多久（秒）
var boot_min_transition_time := 1.0
## 转场所在的 CanvasLayer 层级
var transition_layer := 128
## 是否打印调试日志
var verbose := true

# ------------------------------------------------------------------ 内部状态

var _transitions: Dictionary = {}   ## id -> PackedScene（值可以是 null，表示“无缝”）
var _cache: Dictionary = {}         ## 已预加载完成的 path -> PackedScene
var _pending: Dictionary = {}       ## 正在线程加载的 path -> 剩余“宽限帧数”
var _progress: Dictionary = {}      ## path -> 0~1
var _layer: CanvasLayer
var _transition: Node = null
var _current_path := ""
var _busy := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_layer = CanvasLayer.new()
	_layer.name = "SceneLoaderTransitionLayer"
	_layer.layer = transition_layer
	add_child(_layer)

	register_transition("loading", LOADING_SCREEN)
	register_transition("fade", FADE_TRANSITION)
	register_transition("none", null)
	register_transition("seamless", null)

	call_deferred("_track_current_scene")
	_log("SceneLoader 就绪，默认转场 = %s" % _transition_name(default_transition))


func _process(_delta: float) -> void:
	_track_current_scene()
	_poll_preloads()


# ================================================================== 转场注册

## 注册一个具名转场，之后可以用 goto_scene(path, {"transition": id}) 指定。
## scene 可以是 PackedScene、场景路径（String），或 null（表示无缝）。
func register_transition(id: String, scene: Variant) -> void:
	if id.is_empty():
		push_warning("SceneLoader: 转场 id 不能为空。")
		return
	_transitions[id] = _resolve_transition(scene)


## 是否注册过该转场
func has_transition(id: String) -> bool:
	return _transitions.has(id)


## 取出转场场景（没有则返回 null）
func get_transition(id: String) -> PackedScene:
	return _transitions.get(id, null)


# ================================================================== 预加载

## 后台线程预加载一个场景。可以反复调用，重复调用会被忽略。
## 返回 Error，OK 表示请求已受理（不代表已加载完）。
func preload_scene(path: String) -> int:
	if path.is_empty():
		return ERR_INVALID_PARAMETER
	if _cache.has(path):
		# 已经在缓存里：补发一次完成通知，让“刚连接上去的监听方”也能拿到状态
		var cached: PackedScene = _cache[path]
		preload_completed.emit(path, cached)
		return OK
	if _pending.has(path):
		return OK
	if not ResourceLoader.exists(path):
		push_error("SceneLoader: 场景不存在：%s" % path)
		return ERR_FILE_NOT_FOUND
	return _begin_request(path)


## 批量预加载
func preload_scenes(paths: Array) -> void:
	for p in paths:
		preload_scene(String(p))


## 是否已经预加载完成
func is_preloaded(path: String) -> bool:
	return _cache.has(path)


## 是否正在预加载
func is_preloading(path: String) -> bool:
	return _pending.has(path)


## 预加载进度（0~1）
func get_preload_progress(path: String) -> float:
	if _cache.has(path):
		return 1.0
	return float(_progress.get(path, 0.0))


## 取消跟踪一个预加载（Godot 没有真正的取消接口，线程仍会跑完，只是结果不再记录）
func cancel_preload(path: String) -> void:
	if not _pending.has(path):
		return
	_pending.erase(path)
	_progress.erase(path)
	preload_cancelled.emit(path)
	_log("取消预加载：%s" % path)


## 丢弃一个已完成的预加载缓存（下次进入会重新加载）
func release_preload(path: String) -> void:
	_cache.erase(path)
	_progress.erase(path)
	_log("释放预加载缓存：%s" % path)


## 清空所有预加载缓存
func clear_cache() -> void:
	_cache.clear()
	_progress.clear()


## 取出已预加载的场景；没有预加载则返回 null
func get_cached_scene(path: String) -> PackedScene:
	return _cache.get(path, null)


# ================================================================== 启动读条

## 进游戏时的读条加载：立刻显示转场（默认读条界面），加载完成后自动切到目标场景。
func boot_to(path: String, options: Dictionary = {}) -> void:
	var opts: Dictionary = options.duplicate()
	opts.erase("seamless")   # 启动读条不允许无缝
	if not opts.has("transition"):
		opts["transition"] = default_transition
	if not opts.has("min_time"):
		opts["min_time"] = boot_min_transition_time
	if not opts.has("title"):
		opts["title"] = "正在进入游戏"
	_log("启动读条 → %s" % path)
	await goto_scene(path, opts)
	boot_finished.emit(path)


# ================================================================== 切场

## 切换场景。
## options:
##   transition : PackedScene | String(id 或场景路径) | null   —— 默认 default_transition；null/"none" = 无缝
##   seamless   : bool                                        —— true 时强制不使用转场（等价 transition = null）
##   params     : Dictionary                                  —— 交给新场景（on_scene_entered / scene_params）
##   title      : String                                      —— 转场标题
##   min_time   : float                                       —— 转场最少显示时间，默认 min_transition_time
func goto_scene(path: String, options: Dictionary = {}) -> void:
	if _busy:
		push_warning("SceneLoader: 正在切换场景，忽略对 %s 的请求。" % path)
		return
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("SceneLoader: 场景不存在：%s" % path)
		return

	var seamless := bool(options.get("seamless", false))
	var transition_src: Variant = null if seamless else options.get("transition", default_transition)
	var transition_packed := _resolve_transition(transition_src)
	var params: Dictionary = options.get("params", {})
	var min_time := float(options.get("min_time", min_transition_time))
	var title := String(options.get("title", path.get_file().get_basename()))

	_busy = true
	# 先发起线程加载，让“加载”和“转场动画”并行，避免白白多等一个动画时长
	if not _cache.has(path) and not _pending.has(path):
		_begin_request(path)

	load_started.emit(path, _transition_name(transition_src))
	_log("切场 → %s（转场 = %s）" % [path, _transition_name(transition_src)])

	var node: Node = null
	var started_at := Time.get_ticks_msec()
	if transition_packed != null:
		node = _spawn_transition(transition_packed, title, min_time)
		await _play_transition(node, true)

	var packed := await _wait_for_scene(path, func(ratio: float) -> void: _feed_transition(node, path, ratio))
	if packed == null:
		push_error("SceneLoader: 场景加载失败：%s" % path)
		_free_transition(node)
		_busy = false
		return

	# 保证转场有一个可见的最短时长
	if transition_packed != null and min_time > 0.0:
		var elapsed := float(Time.get_ticks_msec() - started_at) / 1000.0
		if elapsed < min_time:
			await get_tree().create_timer(min_time - elapsed).timeout

	await _swap_scene(packed, path, params)

	if node != null:
		await _play_transition(node, false)
		_free_transition(node)

	load_finished.emit(path)
	_log("切场完成：%s" % path)
	_busy = false


## 当前正在切场？
func is_busy() -> bool:
	return _busy


## 当前场景的资源路径（跟随 SceneTree.current_scene 自动同步）
func get_current_scene_path() -> String:
	return _current_path


# ================================================================== 内部实现

func _log(msg: String) -> void:
	if verbose:
		print("[SceneLoader] ", msg)


func _transition_name(src: Variant) -> String:
	if src == null:
		return ""
	if src is PackedScene:
		return (src as PackedScene).resource_path.get_file().get_basename()
	return String(src)


func _resolve_transition(src: Variant) -> PackedScene:
	if src == null:
		return null
	if src is PackedScene:
		return src
	var key := String(src)
	if key.is_empty() or key == "none" or key == "seamless":
		return null
	if _transitions.has(key):
		return _transitions[key]
	if ResourceLoader.exists(key, "PackedScene"):
		return load(key) as PackedScene
	push_warning("SceneLoader: 未知转场 %s，本次退化为无缝切换。" % key)
	return null


func _begin_request(path: String) -> int:
	var err := ResourceLoader.load_threaded_request(path, "PackedScene", true)
	if err != OK:
		return err
	# 线程刚启动的头两帧状态不可靠（可能返回 INVALID_RESOURCE），先宽限两帧
	_pending[path] = 2
	_progress[path] = 0.0
	preload_started.emit(path)
	_log("开始加载：%s" % path)
	return OK


## 每帧轮询所有预加载请求，是进度信号与缓存写入的唯一出口
func _poll_preloads() -> void:
	if _pending.is_empty():
		return
	for path in _pending.keys():
		var grace: int = _pending[path]
		if grace > 0:
			_pending[path] = grace - 1
			continue

		var progress: Array = []
		var status := ResourceLoader.load_threaded_get_status(path, progress)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			var ratio := float(progress[0]) if progress.size() > 0 else 0.0
			_progress[path] = ratio
			preload_progress.emit(path, ratio)
		elif status == ResourceLoader.THREAD_LOAD_LOADED:
			_pending.erase(path)
			var packed := ResourceLoader.load_threaded_get(path) as PackedScene
			if packed == null:
				_progress.erase(path)
				preload_failed.emit(path, ERR_FILE_CORRUPT)
				push_error("SceneLoader: 加载结果不是 PackedScene：%s" % path)
			else:
				_cache[path] = packed
				_progress[path] = 1.0
				preload_completed.emit(path, packed)
				_log("加载完成：%s" % path)
		elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_pending.erase(path)
			_progress.erase(path)
			preload_failed.emit(path, ERR_CANT_OPEN)
			push_error("SceneLoader: 加载失败：%s" % path)


## 等待一个场景就绪并返回它。优先吃预加载缓存；没有缓存就现场发起线程加载。
func _wait_for_scene(path: String, on_progress: Callable = Callable()) -> PackedScene:
	if _cache.has(path):
		if on_progress.is_valid():
			on_progress.call(1.0)
		return _cache[path]

	if not _pending.has(path):
		var err := _begin_request(path)
		if err != OK:
			_log("线程加载请求失败(%d)，退化为同步加载：%s" % [err, path])
			var fallback := ResourceLoader.load(path, "PackedScene") as PackedScene
			if fallback != null:
				_cache[path] = fallback
				if on_progress.is_valid():
					on_progress.call(1.0)
			return fallback

	while not _cache.has(path):
		if not _pending.has(path):
			# 线程加载失败（信号已发过），让调用方走失败分支
			return null
		if on_progress.is_valid():
			on_progress.call(float(_progress.get(path, 0.0)))
		await get_tree().process_frame

	if on_progress.is_valid():
		on_progress.call(1.0)
	return _cache[path]


func _spawn_transition(packed: PackedScene, title: String, min_time: float) -> Node:
	var node := packed.instantiate()
	_layer.add_child(node)
	_transition = node
	if node.has_method("set_title"):
		node.call("set_title", title)
	if node.has_method("set_progress"):
		node.call("set_progress", 0.0)
	# 可选接口：告诉转场“至少显示多久”，读条界面用它做最短匀速读条
	if node.has_method("set_min_display_time"):
		node.call("set_min_display_time", min_time)
	return node


func _feed_transition(node: Node, path: String, ratio: float) -> void:
	load_progress.emit(path, ratio)
	if node != null and node.has_method("set_progress"):
		node.call("set_progress", ratio)


func _play_transition(node: Node, is_in: bool) -> void:
	if node == null:
		return
	var method := "play_in" if is_in else "play_out"
	var sig := "in_finished" if is_in else "out_finished"
	var duration_prop := "in_duration" if is_in else "out_duration"

	if node.has_method(method):
		node.call(method)
	else:
		return

	if node.has_signal(sig):
		await _await_signal(node, sig)
	elif duration_prop in node:
		var duration := float(node.get(duration_prop))
		if duration > 0.0:
			await get_tree().create_timer(duration).timeout

	if is_in:
		transition_in_finished.emit()
	else:
		transition_out_finished.emit()


## 等待一个动态名字的信号（带超时，防止对端被提前释放时卡死）
func _await_signal(obj: Object, sig: StringName, timeout := 10.0) -> void:
	var fired := [false]
	obj.connect(sig, func() -> void: fired[0] = true, CONNECT_ONE_SHOT)
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not fired[0] and is_instance_valid(obj) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _free_transition(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
	if _transition == node:
		_transition = null


func _swap_scene(packed: PackedScene, path: String, params: Dictionary) -> void:
	var err := get_tree().change_scene_to_packed(packed)
	if err != OK:
		push_error("SceneLoader: change_scene_to_packed 失败(%d)：%s" % [err, path])
		return

	# change_scene_to_packed 是延迟执行的，等新场景真正成为 current_scene
	var waited := 0
	while waited < 10:
		await get_tree().process_frame
		waited += 1
		# 内层别再用 scene 这个名字：外层还要再声明一个 scene，
		# 重名会触发 CONFUSABLE_LOCAL_DECLARATION
		# "The variable is declared below in the parent block."
		var current := get_tree().current_scene
		if current != null and current.scene_file_path == path:
			break

	var scene := get_tree().current_scene
	if scene == null:
		push_error("SceneLoader: 切换后没有 current_scene：%s" % path)
		return

	_current_path = path
	if not params.is_empty():
		if scene.has_method("on_scene_entered"):
			scene.call("on_scene_entered", params)
		elif "scene_params" in scene:
			scene.set("scene_params", params)


## 跟随 SceneTree.current_scene，外部直接 change_scene_* 也能同步到
func _track_current_scene() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null:
		return   # 切场过程中的空档，忽略
	var path := scene.scene_file_path
	if path == _current_path:
		return
	var previous := _current_path
	_current_path = path
	scene_changed.emit(previous, path)
