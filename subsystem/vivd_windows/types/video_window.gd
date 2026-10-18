extends "res://subsystem/vivd_windows/vivd_window.gd"
## 视频播放窗口 —— 在独立的真实 OS 窗口里播放视频。
##
## [b]双后端，按文件后缀自动选[/b]，也可以用 [code]backend[/code] 显式指定：
##
## * [code]builtin[/code] —— Godot 内置的 [VideoStreamPlayer]（Theora 解码器）。
##   [b]零依赖、零额外体积[/b]，任何渲染器都能跑，但只认 [code].ogv[/code]。
## * [code]vlc[/code] —— [url=https://github.com/xiSage/godot-vlc]godot-vlc[/url]
##   插件自带的 LibVLC。mp4 / mkv / mov / webm / avi … 几乎万能，走纯软件解码，
##   一样不挑渲染器；代价是插件本身约 [b]202 MB[/b]（只算 Windows 运行时）。
##
## [code]auto[/code]（默认）的规则很简单：[code].ogv[/code] 走 builtin，其余后缀走 vlc；
## 插件不在时自动退回 builtin，并给出一条明确的报错。
##
## [b]为什么不干脆统一用 [VideoStreamPlayer]？[/b]
## 因为 Godot 内置解码器只支持 Theora。[code].mp4[/code] 想内置播放就得先转码，
## 而 H.264 转 Theora 同画质体积要大 2–4 倍，等于拿素材体积换插件体积。
##
## [b]用法[/b]
## [codeblock]
## VivdWindowsNode.add_window("movie", "video", {
##     "video": "res://system_test_1/VID20250306230957.mp4",
##     "autoplay": true,
##     "loop": false,
##     "volume_db": -6.0,
##     "position": Vector2i(300, 200),
##     "size": Vector2i(540, 960),
## })
## VivdWindowsNode.call_window_method("movie", "seek_ms", [12000])
## [/codeblock]
##
## [b]两个实现上的坑（都踩过，别再踩）[/b]
##
## 1. [b]不能直接写 [code]VLCMediaPlayer[/code] 这个类名。[/b] GDScript 是在工程导入期
##    解析的，那一刻 GDExtension 还没注册任何类，写类名会变成解析错误 —— 而且是那种
##    会把整个脚本从导出工程里一并干掉的错误。所以这里一律用
##    [method ClassDB.class_exists] / [method ClassDB.instantiate] + [method Object.call]
##    动态访问。副作用是好的：没装插件时这套代码照样解析得了、跑得起来。
## 2. [b]不能指望 [code]load("res://x.mp4")[/code]。[/b] 插件的自定义
##    [ResourceFormatLoader] 只在编辑器扫描过工程之后才注册，非编辑器运行拿不到，
##    [code]load()[/code] 会返回 null 并刷一条 ERROR。所以先问
##    [method ResourceLoader.get_recognized_extensions_for_type] loader 在不在，
##    不在就退到 [code]VLCInstance.load_media_file()[/code] + 真实文件路径。

## 播放/暂停状态变化。
signal video_state_changed(playing: bool)
## 自然播放结束（[member loop] 打开时不会触发）。
signal video_finished()

const PLAYER_NAME := "Player"

## godot-vlc 注册的类名 / 单例名。用字符串而不是类名，理由见文件头注释第 1 条。
const VLC_PLAYER_CLASS := "VLCMediaPlayer"
const VLC_MEDIA_CLASS := "VLCMedia"
const VLC_SINGLETON := &"VLCInstance"

## 内置 VideoStreamPlayer 认识的容器后缀。其它后缀一律交给 VLC。
const BUILTIN_EXTS: PackedStringArray = ["ogv"]

## libvlc 的 state 枚举（对应 [code]VLCMediaPlayer.STATE_*[/code]）。
## 这里写死数值，省得为了读常量再去碰 GDExtension 的类名。
const VLC_STATE_PLAYING := 3
const VLC_STATE_PAUSED := 4

## VLC 后端的 stretch_mode 取值，与 [enum TextureRect.StretchMode] 一致。
const STRETCH_FILL := 0
const STRETCH_KEEP_ASPECT_CENTERED := 5

## 后端选择："auto" / "builtin" / "vlc"。
var backend := "auto"
## 本次实际生效的后端（[method open] 之后有效）。
var active_backend := ""
## 当前视频路径。
var video_path := ""
## 播完是否重播。VLC 没有原生 loop，靠 [code]stopped[/code] 信号重播实现。
var loop := false

var _builtin: VideoStreamPlayer = null
var _vlc: Node = null
var _vlc_media: Resource = null

## 区分"用户主动 stop"和"自然播完" —— 两者都会触发 VLC 的 [code]stopped[/code] 信号。
var _user_stop := false

var _volume_db := 0.0
var _expand := true
var _bus := &""
var _speed := 1.0
var _audio_track := 0


# ─────────────────────────────────────────────────────────────────────────────
#  能力探测（静态，不碰类名）
# ─────────────────────────────────────────────────────────────────────────────

## 当前工程有没有可用的 godot-vlc 插件。
static func is_vlc_available() -> bool:
	return (ClassDB.class_exists(VLC_PLAYER_CLASS)
			and ClassDB.class_exists(VLC_MEDIA_CLASS)
			and Engine.has_singleton(VLC_SINGLETON))


## 给定路径，[param want] 为 [code]"auto"[/code] 时会选哪个后端。
## 纯逻辑，不依赖插件是否真的装好 —— 方便单测。
static func resolve_backend(path: String, want := "auto") -> String:
	var w := want.to_lower()
	if w == "builtin" or w == "vlc":
		return w
	if not is_vlc_available():
		return "builtin"
	if BUILTIN_EXTS.has(path.get_extension().to_lower()):
		return "builtin"
	return "vlc"


# ─────────────────────────────────────────────────────────────────────────────
#  vivd 生命周期
# ─────────────────────────────────────────────────────────────────────────────

func setup(config: Dictionary) -> void:
	backend = str(config.get("backend", "auto")).to_lower()
	loop = bool(config.get("loop", false))
	_volume_db = float(config.get("volume_db", 0.0))
	# 默认铺满窗口；传 false 则等比缩放居中（不裁切）
	_expand = bool(config.get("expand", true))
	_bus = StringName(str(config.get("bus", "")))
	_speed = float(config.get("speed_scale", 1.0))
	if config.has("audio_track"):
		_audio_track = int(config["audio_track"])

	var path := str(config.get("video", ""))
	if not path.is_empty():
		open(path, bool(config.get("autoplay", true)))


## 窗口被移除后，VLC 播放器还要多活多久（秒）再回收。理由见 [method teardown]。
const VLC_DRAIN_SECONDS := 0.5


func teardown() -> void:
	if _vlc != null:
		_user_stop = true
		# 先让音频线程停下来，再把它摘出去延后回收
		if _vlc.has_method("set_pause"):
			_vlc.call("set_pause", true)
		if _vlc.has_method("stop_async"):
			_vlc.call("stop_async")
		_retire(_vlc)
		_vlc = null
		_vlc_media = null
		return
	if _builtin != null:
		_builtin.stop()


## 把 VLC 播放器从窗口里摘出来、藏到场景根上，隔几帧再回收。
##
## [b]为什么不能让它跟着窗口一起 free[/b]：libvlc 的音频/解码回调跑在它自己的线程上，
## 而 Godot 释放节点是[b]先释放子节点、后释放父节点[/b]。插件内部挂着一个
## [AudioStreamPlayer] 当音频出口 —— 窗口一被 free，那个子节点就先没了，
## 可 libvlc 的线程这时还在回调。回调到已释放的对象上，godot-rust 会直接
## abort 掉整个进程（不是抛异常，是 [code]panic in a function that cannot unwind[/code]）：
## [code]AudioStreamPlayer::upcast_ref: access to instance … after it has been freed[/code]
##
## 这是 godot-vlc [b]v1.3.0[/b] 的 use-after-free，作者在 master 上给回调加了
## [code]is_instance_valid[/code] 检查，但那版还没发 release。所以这里自己躲开：
## 让播放器比窗口多活几帧，等 libvlc 的线程安静下来再回收。
func _retire(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var tree := get_tree()
	if node.get_parent() == self:
		remove_child(node)
	elif node.get_parent() != null:
		node.get_parent().remove_child(node)
	if tree == null or tree.root == null:
		node.queue_free()
		return
	if node is CanvasItem:
		(node as CanvasItem).visible = false
	tree.root.add_child(node)
	_drain_and_free(tree, node)


func _drain_and_free(tree: SceneTree, node: Node) -> void:
	await tree.create_timer(VLC_DRAIN_SECONDS).timeout
	if is_instance_valid(node):
		node.queue_free()


# ─────────────────────────────────────────────────────────────────────────────
#  播放控制
# ─────────────────────────────────────────────────────────────────────────────

## 载入视频并（可选）立刻播放。返回是否载入成功。
func open(path: String, autoplay := true) -> bool:
	var want := resolve_backend(path, backend)
	if want == "vlc" and not is_vlc_available():
		push_warning("[video_window] %s 想用 vlc 后端，但 godot-vlc 没装或没加载，"
				% path + "退回内置解码器（只认 .ogv）。")
		want = "builtin"

	active_backend = want
	if not _ensure_player():
		return false
	_apply_player_config()

	if want == "vlc":
		var media: Variant = _load_vlc_media(path)
		if media == null:
			push_error("[video_window] VLC 加载失败：%s" % path)
			return false
		_vlc_media = media
		_vlc.set("media", media)
	else:
		var stream: Variant = load(path)
		if stream == null:
			push_error("[video_window] 视频加载失败：%s" % path)
			return false
		if not (stream is VideoStream):
			push_error("[video_window] %s 不是 VideoStream（得到 %s）。内置后端只认 .ogv；"
					% [path, stream.get_class()] + "别的格式要装 godot-vlc 之类的解码插件。")
			return false
		_builtin.stream = stream

	video_path = path
	if autoplay:
		play()
	return true


func play() -> void:
	if active_backend == "vlc":
		if _vlc == null:
			return
		_user_stop = false
		_vlc.call("play")
	else:
		if _builtin == null:
			return
		# 播完（非 loop）后再 play() 要先把位置拨回开头
		if not _builtin.is_playing() and _builtin.stream_position > 0.0:
			_builtin.stream_position = 0.0
		_builtin.play()
	video_state_changed.emit(true)


func pause() -> void:
	if active_backend == "vlc":
		if _vlc != null:
			_vlc.call("set_pause", true)
	elif _builtin != null:
		_builtin.paused = true
	video_state_changed.emit(false)


func resume() -> void:
	if active_backend == "vlc":
		if _vlc != null:
			_vlc.call("set_pause", false)
	elif _builtin != null:
		_builtin.paused = false
	video_state_changed.emit(true)


func toggle_pause() -> void:
	if is_playing():
		pause()
	elif is_paused():
		resume()


## 停止播放。[param hide_window] 为 true 时顺带隐藏窗口。
func stop(hide_window := false) -> void:
	if active_backend == "vlc":
		if _vlc != null:
			_user_stop = true
			_vlc.call("stop_async")
	elif _builtin != null:
		_builtin.stop()
	video_state_changed.emit(false)
	if hide_window:
		hide()


func is_playing() -> bool:
	if active_backend == "vlc":
		# 注意：libvlc 自己的 is_playing() 在暂停时也返回 true，
		# 所以这里用 state 判断，好和 builtin 后端的语义保持一致。
		return _vlc != null and int(_vlc.call("get_state")) == VLC_STATE_PLAYING
	return _builtin != null and _builtin.is_playing()


func is_paused() -> bool:
	if active_backend == "vlc":
		return _vlc != null and int(_vlc.call("get_state")) == VLC_STATE_PAUSED
	return _builtin != null and _builtin.paused


## 当前进度（毫秒）。
func get_time_ms() -> int:
	if active_backend == "vlc":
		return int(_vlc.call("get_time")) if _vlc != null else 0
	return int(_builtin.get_stream_position() * 1000.0) if _builtin != null else 0


## 总时长（毫秒）。还没探测出来时为 0。
func get_length_ms() -> int:
	if active_backend == "vlc":
		return int(_vlc.call("get_length")) if _vlc != null else 0
	if _builtin == null:
		return 0
	var seconds := _builtin.get_stream_length()
	return int(seconds * 1000.0) if seconds > 0.0 else 0


## 跳转到指定毫秒。注意实际落点是最近的关键帧。
## [param fast] 只对 VLC 后端有意义（true = 允许非精确跳转，更快）。
func seek_ms(ms: int, fast := false) -> void:
	if active_backend == "vlc":
		if _vlc != null:
			_vlc.call("set_time", maxi(ms, 0), fast)
	elif _builtin != null:
		_builtin.stream_position = maxf(ms, 0) / 1000.0


## 按百分比跳转（0.0 ~ 1.0）。
func seek_ratio(ratio: float) -> void:
	var r := clampf(ratio, 0.0, 1.0)
	if active_backend == "vlc":
		if _vlc != null:
			_vlc.call("set_position", r, false)
	elif _builtin != null:
		_builtin.stream_position = r * _builtin.get_stream_length()


func set_volume_db(db: float) -> void:
	_volume_db = db
	if active_backend == "vlc":
		if _vlc != null:
			_vlc.call("set_volume_db", db)
	elif _builtin != null:
		_builtin.volume_db = db


func get_volume_db() -> float:
	if active_backend == "vlc":
		return float(_vlc.call("get_volume_db")) if _vlc != null else _volume_db
	return _builtin.volume_db if _builtin != null else _volume_db


## 播放速度，1.0 为原速。
func set_rate(rate: float) -> void:
	_speed = rate
	if active_backend == "vlc":
		if _vlc != null:
			_vlc.call("set_rate", rate)
	elif _builtin != null:
		_builtin.speed_scale = rate


## 当前帧纹理。
##
## [b]VLC 后端在 [code]--headless[/code] 下也可能给出有效纹理[/b]（它走软件解码，
## 不依赖 RenderingDevice），但窗口刚打开、还没解码出第一帧时会返回 null。
func get_frame_texture() -> Texture2D:
	if active_backend == "vlc":
		if _vlc == null:
			return null
		var tex: Variant = _vlc.call("get_texture")
		return tex as Texture2D
	return _builtin.get_video_texture() if _builtin != null else null


## 拿到原始播放器节点，做上面没包过的高级操作。
##
## builtin 后端返回 [VideoStreamPlayer]；vlc 后端返回 [code]VLCMediaPlayer[/code]
## （它有章节、轨道选择、字幕、AB 循环等一大堆东西，需要就直接用）。
func get_player() -> Object:
	if active_backend == "vlc":
		return _vlc
	return _builtin


# ─────────────────────────────────────────────────────────────────────────────
#  内部
# ─────────────────────────────────────────────────────────────────────────────

func _ensure_player() -> bool:
	# 换后端时把另一个节点拆掉，避免两套播放器同时存在
	if active_backend != "vlc" and _vlc != null:
		_drop(_vlc)
		_vlc = null
		_vlc_media = null
	if active_backend == "vlc" and _builtin != null:
		_drop(_builtin)
		_builtin = null

	if active_backend == "vlc":
		if _vlc != null:
			return true
		if not is_vlc_available():
			return false
		var obj: Variant = ClassDB.instantiate(VLC_PLAYER_CLASS)
		if obj == null:
			push_error("[video_window] ClassDB 无法实例化 %s" % VLC_PLAYER_CLASS)
			return false
		_vlc = obj as Node
		if _vlc == null:
			push_error("[video_window] %s 不是 Node，无法挂进窗口。" % VLC_PLAYER_CLASS)
			return false
		_vlc.set("name", PLAYER_NAME)
		_vlc.call("set_anchors_and_offsets_preset", Control.PRESET_FULL_RECT)
		# VLCMediaPlayer 自己就是个 Control，会把自己画在窗口里，
		# 不需要再套一个 TextureRect。
		add_child(_vlc)
		_vlc.connect("stopped", _on_vlc_stopped)
		return true

	if _builtin != null:
		return true
	var existing := get_node_or_null(PLAYER_NAME)
	if existing is VideoStreamPlayer:
		_builtin = existing
	else:
		_builtin = VideoStreamPlayer.new()
		_builtin.name = PLAYER_NAME
		_builtin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(_builtin)
	_builtin.finished.connect(_on_builtin_finished)
	return true


## 把设置刷到当前的播放器节点上。
func _apply_player_config() -> void:
	if active_backend == "vlc":
		if _vlc == null:
			return
		# autoplay 交给 open() 里的 play() 显式控制，免得赋了 media 就自动开播
		_vlc.set("autoplay", false)
		_vlc.set("volume_db", _volume_db)
		_vlc.set("stretch_mode", STRETCH_FILL if _expand else STRETCH_KEEP_ASPECT_CENTERED)
		if _bus != &"":
			_vlc.set("bus", _bus)
		if not is_equal_approx(_speed, 1.0):
			_vlc.call("set_rate", _speed)
		return

	if _builtin == null:
		return
	_builtin.loop = loop
	_builtin.volume_db = _volume_db
	_builtin.expand = _expand
	if _bus != &"":
		_builtin.bus = _bus
	_builtin.audio_track = _audio_track
	_builtin.speed_scale = _speed


## 加载 VLC 媒体。两条路，优先走能处理 PCK 内资源的那条。
func _load_vlc_media(path: String) -> Variant:
	# 1) 自定义 ResourceFormatLoader 在线时优先用它 —— 导出后资源被打进 PCK，
	#    只有这条路能读到；先问扩展名注册表，免得直接 load() 刷 ERROR。
	var ext := path.get_extension().to_lower()
	if ResourceLoader.get_recognized_extensions_for_type(VLC_MEDIA_CLASS).has(ext):
		var res: Variant = load(path)
		if res != null:
			return res

	# 2) 退到单例 + 真实文件路径
	var instance: Object = Engine.get_singleton(VLC_SINGLETON)
	if instance == null:
		push_error("[video_window] VLCInstance 单例不存在，godot-vlc 可能没正常加载。")
		return null
	var real_path := path
	if path.begins_with("res://") or path.begins_with("user://"):
		real_path = ProjectSettings.globalize_path(path)
	return instance.call("load_media_file", real_path)


func _drop(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node.get_parent() == self:
		remove_child(node)
	node.queue_free()


func _on_builtin_finished() -> void:
	video_state_changed.emit(false)
	video_finished.emit()


func _on_vlc_stopped() -> void:
	if _user_stop:
		_user_stop = false
		return
	if loop and _vlc != null:
		_vlc.call("play")
		return
	video_state_changed.emit(false)
	video_finished.emit()
