extends Node

## SceneLoader headless 自测入口。
## 真正的测试节点会被挂到 /root 下，这样测试过程中反复切场景不会把它一起释放掉。
##
## 运行方式（headless）：
##   godot --headless --path <项目> res://subsystem/scene_loader/tests/scene_loader_smoke_test.tscn
## 退出码：0 = 全部通过，1 = 有失败，2 = 超时。

func _ready() -> void:
	var runner := SmokeRunner.new()
	runner.name = "SceneLoaderSmokeRunner"
	# 当前场景的 _ready 里 root 正在装配子节点，必须延迟挂载
	get_tree().root.add_child.call_deferred(runner)


class SmokeRunner extends Node:
	const MENU := "res://subsystem/scene_loader/demo/demo_menu.tscn"
	const LEVEL_A := "res://subsystem/scene_loader/demo/level_a.tscn"
	const LEVEL_B := "res://subsystem/scene_loader/demo/level_b.tscn"
	const BOOT := "res://subsystem/scene_loader/demo/boot.tscn"
	const LOADING := "res://subsystem/scene_loader/transitions/loading_screen.tscn"
	const FADE := "res://subsystem/scene_loader/transitions/fade_transition.tscn"

	var _failures := PackedStringArray()
	var _checks := 0


	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		_run()


	func _run() -> void:
		print("=== SceneLoader 自测开始 ===")
		_start_watchdog()
		await get_tree().process_frame

		_test_registry()
		_test_scene_files_loadable()
		_test_preload()
		await _test_transition_switch()
		await _test_seamless_switch()
		_test_release()
		await _test_boot_to()

		_check(not SceneLoader.is_busy(), "全部结束后 is_busy() == false")
		_finish()


	# ------------------------------------------------------------ 各测试项
	func _test_registry() -> void:
		_check(SceneLoader.has_transition("loading"), "注册了内置转场 loading")
		_check(SceneLoader.has_transition("fade"), "注册了内置转场 fade")
		_check(SceneLoader.default_transition is PackedScene, "default_transition 是 PackedScene")
		_check(SceneLoader.get_transition("loading") is PackedScene, "get_transition('loading') 有值")
		SceneLoader.register_transition("my_fade", FADE)
		_check(SceneLoader.has_transition("my_fade"), "可以注册自定义转场 id")


	func _test_scene_files_loadable() -> void:
		for path in [MENU, LEVEL_A, LEVEL_B, BOOT, LOADING, FADE]:
			_check(ResourceLoader.exists(path), "场景文件存在：%s" % path)
			var packed := ResourceLoader.load(path) as PackedScene
			_check(packed != null, "可加载为 PackedScene：%s" % path)
			if packed == null or path == BOOT:
				continue   # boot 的 _ready 会主动切场景，这里只验证资源可加载
			var instance := packed.instantiate()
			_check(instance != null, "可实例化：%s" % path)
			if instance != null:
				add_child(instance)
				instance.queue_free()


	func _test_preload() -> void:
		var err := SceneLoader.preload_scene(LEVEL_B)
		_check(err == OK, "preload_scene(关卡B) 返回 OK（实际 %d）" % err)

		var ok := await _wait_until(func() -> bool: return SceneLoader.is_preloaded(LEVEL_B), 15.0)
		_check(ok, "关卡B 预加载在超时前完成")
		_check(is_equal_approx(SceneLoader.get_preload_progress(LEVEL_B), 1.0), "预加载进度到 1.0")
		_check(not SceneLoader.is_preloading(LEVEL_B), "完成后 is_preloading == false")
		_check(SceneLoader.get_cached_scene(LEVEL_B) is PackedScene, "缓存里有 PackedScene")

		var again := SceneLoader.preload_scene(LEVEL_B)
		_check(again == OK, "重复预加载同一场景返回 OK（幂等）")

		var bad := SceneLoader.preload_scene("res://不存在的场景.tscn")
		_check(bad != OK, "预加载不存在的场景会报错（实际 %d）" % bad)


	func _test_transition_switch() -> void:
		var t0 := Time.get_ticks_msec()
		await SceneLoader.goto_scene(LEVEL_A, {
			"transition": "loading",
			"title": "自测：载入关卡A",
			"min_time": 0.3,
			"params": {"from": "smoke", "index": 1},
		})
		var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
		var current := get_tree().current_scene
		_check(current != null and current.scene_file_path == LEVEL_A,
			"转场切换后 current_scene 是关卡A（实际 %s）" % _scene_path())
		_check(elapsed >= 0.3, "min_time 生效（实际 %.3f 秒）" % elapsed)
		_check(SceneLoader.get_current_scene_path() == LEVEL_A, "get_current_scene_path 同步正确")

		var params := _current_scene_params()
		_check(params.get("from", "") == "smoke" and params.get("index", 0) == 1,
			"新场景通过 on_scene_entered 收到 params：%s" % JSON.stringify(params))


	func _test_seamless_switch() -> void:
		_check(SceneLoader.is_preloaded(LEVEL_B), "无缝切换前关卡B已在预加载缓存里")

		var t0 := Time.get_ticks_msec()
		await SceneLoader.goto_scene(LEVEL_B, {
			"seamless": true,
			"min_time": 0.0,
			"params": {"from": "seamless"},
		})
		var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
		var current := get_tree().current_scene
		_check(current != null and current.scene_file_path == LEVEL_B,
			"无缝切换后 current_scene 是关卡B（实际 %s）" % _scene_path())
		_check(elapsed < 0.5, "无缝切换几乎瞬时（实际 %.3f 秒）" % elapsed)
		var params := _current_scene_params()
		_check(params.get("from", "") == "seamless", "无缝切换同样能传 params：%s" % JSON.stringify(params))


	func _test_release() -> void:
		SceneLoader.release_preload(LEVEL_B)
		_check(not SceneLoader.is_preloaded(LEVEL_B), "release_preload 后缓存被清掉")
		_check(is_equal_approx(SceneLoader.get_preload_progress(LEVEL_B), 0.0), "释放后进度归零")


	func _test_boot_to() -> void:
		var got_boot_signal := [false]
		SceneLoader.boot_finished.connect(func(_p: String) -> void: got_boot_signal[0] = true, CONNECT_ONE_SHOT)
		await SceneLoader.boot_to(MENU, {"min_time": 0.3, "title": "自测：启动读条"})
		var current := get_tree().current_scene
		_check(current != null and current.scene_file_path == MENU,
			"启动读条后 current_scene 是主菜单（实际 %s）" % _scene_path())
		_check(got_boot_signal[0], "boot_finished 信号已发出")


	# ------------------------------------------------------------ 工具
	func _scene_path() -> String:
		var current := get_tree().current_scene
		return current.scene_file_path if current != null else "null"


	func _current_scene_params() -> Dictionary:
		var current := get_tree().current_scene
		if current != null and current.has_method("get_scene_params"):
			return current.call("get_scene_params")
		return {}


	func _check(condition: bool, message: String) -> void:
		_checks += 1
		if condition:
			print("  [PASS] ", message)
		else:
			print("  [FAIL] ", message)
			_failures.append(message)


	func _wait_until(predicate: Callable, timeout: float) -> bool:
		var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
		while Time.get_ticks_msec() < deadline:
			if bool(predicate.call()):
				return true
			await get_tree().process_frame
		return bool(predicate.call())


	func _start_watchdog() -> void:
		var timer := Timer.new()
		timer.wait_time = 60.0
		timer.one_shot = true
		timer.process_mode = Node.PROCESS_MODE_ALWAYS
		timer.timeout.connect(func() -> void:
			print("  [FAIL] 自测超时（60 秒）")
			get_tree().quit(2))
		add_child(timer)
		timer.start()


	func _finish() -> void:
		print("=== SceneLoader 自测结束：%d 项检查，%d 项失败 ===" % [_checks, _failures.size()])
		for f in _failures:
			print("  失败：", f)
		get_tree().quit(0 if _failures.is_empty() else 1)
