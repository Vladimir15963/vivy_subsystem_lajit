extends Node
## vivd 窗口系统冒烟测试。
##
## 运行（工程根目录）：
## [codeblock]
## godot --headless --path . res://subsystem/vivd_windows/vivd_smoke_test.tscn
## [/codeblock]
##
## 全通过退出码 0，有失败退出码 1。
##
## [b]两点说明[/b]
## * headless 下 Godot 会把 [code]embed_subwindows[/code] 强制成 true（窗口内嵌），
##   所以这里验证的是[b]管理器逻辑[/b]，不是真实 OS 窗口的观感。
##   真实观感请在编辑器里跑 [code]system_test_1/test.tscn[/code]。
## * 输出里会夹着几条 ERROR / WARNING，那是故意触发错误路径（重名、未注册类型、不存在的方法）产生的，
##   属于预期现象。
##
## [b]关于变量类型[/b]：find_window() 返回的是 Window，而 fade_stop()/is_dev() 这些是
## VivdWindow 上的方法，直接 [code]w.fade_stop()[/code] 会因为"Window 上没有这个方法"而解析报错。
## 所以这里统一走 [method Object.call] / [method Object.get]。

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("")
	print("═══ vivd 窗口系统冒烟测试 ═══")
	print("已注册窗口类型：", ", ".join(VivdWindowsNode.list_window_types()))
	print("（下面几条 ERROR/WARNING 是故意触发的）")

	await _test_add_and_config()
	await _test_errors()
	await _test_types()
	await _test_text()
	await _test_video()
	await _test_operations()
	await _test_dev()
	await _test_remove_and_leak()
	_test_registry()

	# 让 godot-vlc 的线程彻底安静下来再退出。
	# v1.3.0 在「libvlc 线程还在回调、节点已经释放」的竞态下会直接 abort 整个进程，
	# 所以这里给 _retire() 的延后回收留出时间（见 types/video_window.gd 的注释）。
	await get_tree().create_timer(1.0).timeout

	print("")
	print("═══ 通过 %d · 失败 %d ═══" % [_passed, _failed])
	print("SMOKE_RESULT=", "PASS" if _failed == 0 else "FAIL")
	get_tree().quit(1 if _failed > 0 else 0)


# ─────────────────────────────────────────────────────────────────────────────

func _test_add_and_config() -> void:
	_section("创建与配置")
	VivdWindowsNode.clear_windows()
	await _settle()

	var w = VivdWindowsNode.add_window("t1", "default", {
		"title": "标题来了",
		"position": Vector2i(321, 123),
		"size": Vector2i(400, 300),
	})
	_check("add_window 返回实例", w != null)
	_check("窗口计数为 1", VivdWindowsNode.window_count() == 1)
	_check("title 生效", w != null and w.title == "标题来了")
	_check("position 立即生效（不再从场景默认位置滑入）", w != null and w.position == Vector2i(321, 123))
	_check("size 立即生效", w != null and w.size == Vector2i(400, 300))
	_check("find_window 能取回同一个实例", VivdWindowsNode.find_window("t1") == w)
	_check("has_window", VivdWindowsNode.has_window("t1"))
	_check("list_windows 含它", VivdWindowsNode.list_windows().has("t1"))
	_check("带上了 VivdWindow 的能力（fade_in）", w != null and w.has_method("fade_in"))
	_check("基类 _ready 跑了（close_requested 已接）", w != null and w.has_method("vivd_set_dev"))


func _test_errors() -> void:
	_section("错误处理")
	var before := VivdWindowsNode.window_count()

	var dup = VivdWindowsNode.add_window("t1", "default")
	_check("重名被拒绝并返回 null", dup == null)
	_check("重名不会顶掉旧窗口（原来会泄漏）", VivdWindowsNode.window_count() == before)

	var bad_type = VivdWindowsNode.add_window("t9", "不存在的类型")
	_check("未注册类型被拒绝", bad_type == null)

	var empty_name = VivdWindowsNode.add_window("   ", "default")
	_check("空名字被拒绝", empty_name == null)

	_check("移动不存在的窗口返回 false", VivdWindowsNode.move_window("nope", Vector2i(1, 1)) == false)
	_check("移除不存在的窗口返回 false", VivdWindowsNode.remove_window("nope") == false)
	_check("调用不存在的方法返回 null", VivdWindowsNode.call_window_method("t1", "没有这个方法") == null)


func _test_types() -> void:
	_section("窗口类型")

	var image = VivdWindowsNode.add_window("pic", "image", {
		"image": "res://icon.svg",
		"position": Vector2i(20, 20),
		"size": Vector2i(200, 200),
	})
	_check("image 类型创建成功", image != null)
	_check("config.image 生效", image != null and image.get("image_path") == "res://icon.svg")
	_check("图片节点存在", image != null and image.get_node_or_null("Texture") != null)

	var examin = VivdWindowsNode.add_window("examin", "file_examin", {"title": "拖放"})
	_check("file_examin 类型创建成功", examin != null)
	_check("提示节点存在", examin != null and examin.get_node_or_null("Hint") != null)
	_check("file_examin 收到了 files_dropped 信号", examin != null and examin.has_signal("files_dropped"))

	var bad_image = VivdWindowsNode.add_window("badpic", "image", {"image": "res://不存在的图.png"})
	_check("图片加载失败不崩、窗口仍创建", bad_image != null)
	_check("失败时 image_path 保持为空", bad_image != null and str(bad_image.get("image_path")).is_empty())


func _test_text() -> void:
	_section("文本阅读窗口")

	var long_text := ""
	for i in 40:
		long_text += "第 %d 行：这是一段用来撑出滚动条的文本。\n" % (i + 1)

	var w = VivdWindowsNode.add_window("reader", "text", {
		"title": "阅读",
		"text": long_text,
		"position": Vector2i(30, 30),
		"size": Vector2i(420, 240),
		"font_size": 16,
	})
	_check("text 窗口创建成功", w != null)
	_check("正文写入成功", w != null and str(w.get("text_content")) == long_text)
	_check("拿得到内部的 RichTextLabel", w != null and w.call("get_label") is RichTextLabel)
	_check("默认按 BBCode 解析", w != null and bool(w.get("bbcode")))

	await _settle()
	_check("行数 > 10（确实多行）", w != null and int(w.call("get_line_count")) > 10)
	_check("长文本撑出了滚动（在顶部时未到底）", w != null and not bool(w.call("is_at_bottom")))

	w.call("scroll_to_bottom")
	await _settle()
	_check("scroll_to_bottom 之后到底", w != null and bool(w.call("is_at_bottom")))

	w.call("scroll_to_top")
	await _settle()
	_check("scroll_to_top 之后回顶", w != null and float(w.call("get_scroll_ratio")) < 0.01)

	w.callv("append_line", ["追加的一行"])
	_check("append_line 之后正文变长",
			w != null and str(w.get("text_content")).ends_with("追加的一行"))
	_check("append_line 自动补了换行", w != null and str(w.get("text_content")).contains("\n追加的一行"))

	w.call("clear_text")
	await _settle()
	_check("clear_text 之后正文为空", w != null and str(w.get("text_content")).is_empty())

	# 逐字显示
	var r = VivdWindowsNode.add_window("reader2", "text", {
		"text": "一二三四五六七八九十",
		"speed": 5.0,
		"size": Vector2i(320, 120),
	})
	_check("逐字显示窗口创建成功", r != null)
	_check("正在逐字显示", r != null and bool(r.call("is_revealing")))
	_check("刚创建时几乎看不到字（tween 确实把 visible_ratio 压到 0）",
			r != null and float(r.call("get_label").visible_ratio) < 0.2)

	if r != null:
		await get_tree().create_timer(0.5).timeout
		var mid := float(r.call("get_label").visible_ratio)
		_check("逐字进度确实在推进（0 < ratio < 1）", mid > 0.0 and mid < 1.0)
		r.call("reveal_all")
		_check("reveal_all 之后停止逐字显示", not bool(r.call("is_revealing")))
		_check("reveal_all 之后全文可见",
				is_equal_approx(float(r.call("get_label").visible_ratio), 1.0))

	var q = VivdWindowsNode.add_window("reader3", "text", {"text": "一次显示完"})
	_check("speed=0（默认）时不是逐字状态", q != null and not bool(q.call("is_revealing")))

	var r2 = VivdWindowsNode.add_window("reader4", "text", {
		"text": "这段正在逐字显示的时候会被移除",
		"speed": 5.0,
		"size": Vector2i(320, 120),
	})
	_check("reader4 正在逐字显示", r2 != null and bool(r2.call("is_revealing")))
	_check("逐字显示途中移除窗口不崩", VivdWindowsNode.remove_window("reader4"))

	_check("移除 reader", VivdWindowsNode.remove_window("reader"))
	_check("移除 reader2", VivdWindowsNode.remove_window("reader2"))
	_check("移除 reader3", VivdWindowsNode.remove_window("reader3"))
	await _settle()


func _test_video() -> void:
	_section("视频窗口（双后端）")
	const OGV := "res://subsystem/vivd_windows/sample/sample_5s.ogv"
	const MP4 := "res://system_test_1/VID20250306230957.mp4"

	var w_ogv = VivdWindowsNode.add_window("v_ogv", "video", {
		"video": OGV,
		"autoplay": false,
		"position": Vector2i(8, 8),
		"size": Vector2i(320, 240),
	})
	_check(".ogv 窗口创建成功", w_ogv != null)
	_check(".ogv 自动走 builtin 后端（零依赖那条路）",
			w_ogv != null and str(w_ogv.get("active_backend")) == "builtin")
	_check("builtin 挂的是 VideoStreamPlayer",
			w_ogv != null and w_ogv.get_node_or_null("Player") is VideoStreamPlayer)

	# 显式指定 backend 时应当照办，哪怕后缀和默认判断相反
	var w_force = VivdWindowsNode.add_window("v_force", "video", {
		"video": MP4,
		"backend": "builtin",
		"autoplay": false,
	})
	_check("backend=builtin 时照办（mp4 也走内置）",
			w_force != null and str(w_force.get("active_backend")) == "builtin")
	_check("内置后端放不了 .mp4：open 失败但窗口不崩",
			w_force != null and str(w_force.get("video_path")).is_empty())
	_check("失败窗口能正常移除", VivdWindowsNode.remove_window("v_force"))

	var w_mp4 = VivdWindowsNode.add_window("v_mp4", "video", {
		"video": MP4,
		"autoplay": false,
		"volume_db": -12.0,
		"position": Vector2i(12, 12),
		"size": Vector2i(270, 480),
	})
	_check(".mp4 窗口创建成功", w_mp4 != null)
	var vlc_ok: bool = w_mp4 != null and str(w_mp4.get("active_backend")) == "vlc"
	_check(".mp4 自动走 vlc 后端（需要装 godot-vlc）", vlc_ok)

	if vlc_ok:
		w_mp4.call("play")
		var started := false
		var deadline := Time.get_ticks_msec() + 20000
		while Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
			if bool(w_mp4.call("is_playing")):
				started = true
				break
		_check("VLC 进入播放状态", started)

		if started:
			_check("时长 > 0", int(w_mp4.call("get_length_ms")) > 0)
			_check("音量设置生效", is_equal_approx(float(w_mp4.call("get_volume_db")), -12.0))

			var t0: int = int(w_mp4.call("get_time_ms"))
			for _i in 60:
				await get_tree().process_frame
			_check("播放进度在推进", int(w_mp4.call("get_time_ms")) > t0)
			_check("软件解码能拿到帧纹理", w_mp4.call("get_frame_texture") != null)

			w_mp4.call("pause")
			await _settle()
			_check("pause 后 is_paused", bool(w_mp4.call("is_paused")))
			_check("pause 后 is_playing 为 false", not bool(w_mp4.call("is_playing")))

			w_mp4.call("resume")
			await _settle()
			_check("resume 后恢复播放", bool(w_mp4.call("is_playing")))

			# 注意：Object.call() 不展开数组，多参数要用 callv()
			w_mp4.callv("seek_ms", [1000])
			await _settle()

	_check("移除 playing 中的 VLC 窗口不崩", VivdWindowsNode.remove_window("v_mp4"))
	_check("移除 builtin 视频窗口", VivdWindowsNode.remove_window("v_ogv"))
	await _settle()


func _test_operations() -> void:
	_section("移动 / 缩放 / 调用 / 淡入淡出")
	var w = VivdWindowsNode.find_window("t1")

	_check("call_window_method 展开多个参数", VivdWindowsNode.call_window_method("t1", "ping", ["a", "b"]) == "pong:a+b")
	_check("单参数也对", VivdWindowsNode.call_window_method("t1", "ping", ["x"]) == "pong:x")
	_check("不传参数走默认值", VivdWindowsNode.call_window_method("t1", "ping") == "pong:")

	_check("move_window duration=0 立即生效", VivdWindowsNode.move_window("t1", Vector2i(11, 22), 0.0))
	_check("位置已改", w != null and w.position == Vector2i(11, 22))

	_check("resize_window duration=0 立即生效", VivdWindowsNode.resize_window("t1", Vector2i(333, 222), 0.0))
	_check("尺寸已改", w != null and w.size == Vector2i(333, 222))

	_check("连续两次动画移动不报错", VivdWindowsNode.move_window("t1", Vector2i(60, 60), 0.05)
			and VivdWindowsNode.move_window("t1", Vector2i(70, 70), 0.05))
	await get_tree().create_timer(0.3).timeout
	_check("动画结束后停在最后一次的目标（旧 tween 被 kill）", w != null and w.position == Vector2i(70, 70))

	_check("fade_window_in", VivdWindowsNode.fade_window_in("t1", 0.05))
	_check("fade_window_out", VivdWindowsNode.fade_window_out("t1", 0.05, false))
	w.call("fade_stop")
	var items: Variant = w.call("get_content_items")
	_check("fade_stop 后内容不透明度回到 1.0",
			items.size() > 0 and is_equal_approx(float(items[0].modulate.a), 1.0))

	_check("bring_window_to_front", VivdWindowsNode.bring_window_to_front("t1"))


func _test_dev() -> void:
	_section("调试浮层")
	VivdWindowsNode.set_dev(true)

	var w = VivdWindowsNode.find_window("t1")
	_check("set_dev 作用到已存在的窗口（原来只影响之后新建的）", w != null and w.call("is_dev") == true)

	var overlay = w.get_node_or_null("VivdDevOverlay")
	_check("dev 浮层由基类自动生成（不再要求场景预放 dev/Control/devinfo）", overlay != null)
	_check("dev 开启时浮层可见", overlay != null and bool(overlay.get("visible")))

	VivdWindowsNode.set_dev(false)
	_check("set_dev(false) 也作用到已存在窗口", w != null and w.call("is_dev") == false)
	_check("dev 关闭时浮层隐藏", overlay != null and not bool(overlay.get("visible")))


func _test_remove_and_leak() -> void:
	_section("移除与泄漏")
	var w = VivdWindowsNode.find_window("t1")
	var reference: Variant = weakref(w)

	_check("remove_window 返回 true", VivdWindowsNode.remove_window("t1"))
	_check("字典里已经没了", not VivdWindowsNode.has_window("t1"))
	_check("find_window 返回 null", VivdWindowsNode.find_window("t1") == null)

	await _settle()
	_check("窗口对象真的被释放（原来从不 queue_free，必然泄漏）", reference.get_ref() == null)

	VivdWindowsNode.clear_windows()
	await _settle()
	_check("clear_windows 清空所有窗口", VivdWindowsNode.window_count() == 0)


func _test_registry() -> void:
	_section("窗口类型注册")
	var scene: PackedScene = load("res://subsystem/vivd_windows/types/default.tscn")

	_check("注册新类型返回 true", VivdWindowsNode.register_window_type("tmp_type", scene) == true)
	_check("重复注册返回 false", VivdWindowsNode.register_window_type("tmp_type", scene) == false)
	_check("list_window_types 含新类型", VivdWindowsNode.list_window_types().has("tmp_type"))
	_check("get_window_type 取回同一个场景", VivdWindowsNode.get_window_type("tmp_type") == scene)
	_check("注销返回 true", VivdWindowsNode.unregister_window_type("tmp_type") == true)
	_check("注销后查不到", not VivdWindowsNode.has_window_type("tmp_type"))

	# 目录扫描必须能认【继承场景】。
	# test_fixtures/scan_probe.tscn 是 instance=types/default.tscn 的继承场景，
	# 而 SceneState.get_node_type(0) 对继承场景返回空字符串 —— 这里就是回归点。
	_check("扫描能注册继承来的窗口类型", VivdWindowsNode.scan_window_types("res://subsystem/vivd_windows/test_fixtures") == 1)
	_check("扫出来的类型名取自文件名", VivdWindowsNode.has_window_type("scan_probe"))
	_check("扫出来的确实能用", VivdWindowsNode.add_window("probe", "scan_probe", {"position": Vector2i(5, 5)}) != null)
	_check("用完能移除", VivdWindowsNode.remove_window("probe"))
	_check("清理扫出来的类型", VivdWindowsNode.unregister_window_type("scan_probe"))

	_check("扫描已注册目录不会重复注册", VivdWindowsNode.scan_window_types("res://subsystem/vivd_windows/types") == 0)


# ─────────────────────────────────────────────────────────────────────────────

func _settle(frames := 3) -> void:
	for _i in frames:
		await get_tree().process_frame


func _section(title: String) -> void:
	print("")
	print("── %s ──" % title)


func _check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		print("  [PASS] ", label)
	else:
		_failed += 1
		print("  [FAIL] ", label)
