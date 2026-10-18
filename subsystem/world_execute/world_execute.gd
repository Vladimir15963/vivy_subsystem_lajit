extends Node2D

## 主场景：固定窗口的 `world.execute(me)` 终端 PV 播放器（A 层字符格画面 + FX 后处理）。
##
## 每帧接线顺序（见 pv_fx.gd 文件头；顺序错会破坏 cut「吃旧画面」的语义）：
##
## ```
## screen.begin_frame(t)         # 清 rect 表、写 PV.NOW
## PvFx.stage_cut(screen, t, ent)  # 镜头号变了才排 cut，吃的是上一帧还在屏上的画面
## PvPanels.draw(screen, d, t, ent)   # 画新画面（内部又会 begin_frame，空表所以无害）
##                                #   顺带把 stdout 带格区写进 screen.stdout_rect
## _sync_stream_rect()            # B 层真终端贴到这条带上
## PvFx.apply(screen, t, ent)      # CLEAR 落后一帧，再 reveal → trail → shake
## screen.end_frame()             # 收帧快照（供下一帧 trail / cut 比对）
## ```
##
## B 层（文本流 / FakeTerminal 打字回显）在 pv_stream.gd 里，接线点见 TB 标记。
## B 层启用时 A 层把 stdout 带让出去（`PvPanels.STREAM_ON`），避免同一份 boot / 歌词画两遍。
##
## 窗口固定：197×52 格 × 9×18 px = 1773×936，居中于当前显示器，`CONTENT_SCALE_MODE_DISABLED`
## 保证一格 = 一像素（不做窄窗降级，见 README「已知取舍」）。

const COLS := 197
const ROWS := 52
const AUDIO_PATH := "res://subsystem/world_execute/data/song.mp3"

# ---------------------------------------------------------------- 对外信号
## 从暂停恢复播放（`空格`），或片尾 seek 回片头后重新播放。
signal playback_started()
## 用户暂停。
signal playback_paused()
## 到达片尾（只发一次；seek 回片头后重新武装）。
signal playback_finished()
## 任意 seek 之后的当前时间（秒）。
signal seeked(t: float)
## 镜头切换（第一个镜头也会发一次）。
signal shot_changed(index: int, name: String)
## 章节切换（含片头第一个章节）。
signal chapter_changed(label: String)
## 输入开关变化。关闭后主场景不再响应任何按键（窗口关闭按钮仍可用）。
signal input_enabled_changed(enabled: bool)

## 输入开关：可在检查器里关掉；关闭时 `_input` 直接返回，底栏提示「输入禁用」。
@export var input_enabled := true:
	set = set_input_enabled

## 一次 ±10 %：参考实现 `audio.set_volume(volume ± 100)`，而底栏按 `volume//10` 显示百分数。
const VOLUME_STEP := 10
const FPS_WINDOW := 0.5

## B 层（文本流层）的终端面板：先按「stdout 带」的典型位置摆在格 (1,32)-(118,47)，
## 之后每帧由 `_sync_stream_rect()` 跟随 `PvPanels` 报出的真实 band 格区（boot 阶段就是 32，
## 进入 sim.start 后整体下移 3 行）。字体先渲小的（11 px），底半透明。
const STREAM_SCENE_PATH := "res://subsystem/fake_terminal/fake_terminal.tscn"
const STREAM_GRID := Rect2i(1, 32, 118, 16)   # x, y, w, h（单位：格）
const STREAM_FONT_SIZE := 11
const STREAM_BG := Color(0.0157, 0.0275, 0.0588, 0.55)

var atlas: PvAtlas
var screen: PvScreen
var data: PvData
var panels: PvPanels
var clock: PvClock
var display: PvDisplay
var stream: PvStream             ## B 层；headless 下为 null
var windows: PvWindows           ## C 层附加 OS 窗口（阶段 3，新设计）

var _term: FakeTerminal          ## B 层的真终端节点（headless 下为 null）
var _term_rect := Rect2i()
var _fps_frames := 0
var _fps_time := 0.0
var _last_index := -2
var _last_chapter := ""
var _finished := false
## 当前镜头的屏幕模式 `[mode, kind]`（C 层 `PvStage`），底栏与黑边都用它。
var _layout: Array = ["split", "split"]
## 进行中的滑动转场：`{spec, t0, dur, a}`；空 = 没有。
var _tr: Dictionary = {}
var _prev_ent: Dictionary = {}
var _last_t := -1.0
var _tr_screen: PvScreen


func _ready() -> void:
	atlas = PvAtlas.new()
	screen = PvScreen.new(atlas, COLS, ROWS)
	data = PvData.new()
	panels = PvPanels.new()

	var audio := AudioStreamPlayer.new()
	audio.name = "Song"
	audio.stream = load(AUDIO_PATH) as AudioStream
	if audio.stream == null:
		push_warning("world_execute: 音频未导入（%s），本次运行退化为纯墙钟" % AUDIO_PATH)
	add_child(audio)
	clock = PvClock.new(audio)

	display = PvDisplay.new()
	display.name = "PvDisplay"
	add_child(display)
	display.setup(screen)
	# C 层 1B（tools/ref/c_layer_plan.md §7 冲突 1）：有真实窗口就让整窗位移接管行位移。
	PvFx.use_window_shake = PvDisplay.can_create_textures()

	_setup_stream()

	var win := get_window()
	win.title = "world.execute(me);"
	windows = PvWindows.new()
	windows.name = "PvWindows"
	add_child(windows)
	windows.setup(win, screen.atlas.cell_size_vec())
	# 调试/验收用：`-- --windows` 启动即打开附加窗口（W 键仍可随时开关）。
	if OS.get_cmdline_user_args().has("--windows"):
		windows.toggle.call_deferred()
	# 调试/验收用：`-- --half-her` 强制 half 立绘路径（会让她在所有镜头都占左窗格，
	# 便于观察音乐反应与气泡）。
	if OS.get_cmdline_user_args().has("--half-her"):
		PvPanels.HER_RENDER = "half"
	# 调试/验收用：`-- --t=194.5` 从指定秒数起播（方便逐个镜头看效果）。
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--t="):
			clock.seek_to(maxf(0.0, float(arg.substr(4))))
	# 调试/验收用：`-- --no-input` 启动即关闭按键响应（底栏显示「输入禁用」）。
	if OS.get_cmdline_user_args().has("--no-input"):
		input_enabled = false
	PvPanels.INPUT_ON = input_enabled
	clock.play()


## B 层接线：在主窗口内固定一块子区域放 `FakeTerminal`（只输出模式），把文本流灌进去。
## headless / dummy 渲染器下不建（`Terminal` 需要真实渲染环境），于是自测退化为只跑 A 层逻辑。
func _setup_stream() -> void:
	if not PvDisplay.can_create_textures():
		return
	var scene := load(STREAM_SCENE_PATH) as PackedScene
	if scene == null:
		push_warning("world_execute: B 层终端场景加载失败（%s），本次运行只有 A 层" % STREAM_SCENE_PATH)
		return
	var terminal := scene.instantiate() as FakeTerminal
	terminal.name = "StreamTerminal"
	terminal.font_size = STREAM_FONT_SIZE
	terminal.background_color = STREAM_BG
	terminal.mode = FakeTerminal.Mode.OUTPUT_ONLY
	var cell := screen.atlas.cell_size_vec()
	terminal.position = Vector2(STREAM_GRID.position) * cell
	terminal.size = Vector2(STREAM_GRID.size) * cell
	add_child(terminal)
	_term = terminal
	_term_rect = STREAM_GRID
	stream = PvStream.new(terminal)
	stream.reset()


## B 层终端逐帧贴到 A 层真正在画文本的那条带上（`screen.stdout_rect` 由 `PvPanels` 刚写好）。
## 只在带区变了才动 `Control` 属性 —— godot_xterm 的 `Terminal` 每次改尺寸都会重排内部网格。
func _sync_stream_rect() -> void:
	if _term == null:
		return
	var r := screen.stdout_rect
	if r.size.x < 4 or r.size.y < 2:
		_term.visible = false
		return
	_term.visible = true
	if r == _term_rect:
		return
	_term_rect = r
	var cell := screen.atlas.cell_size_vec()
	_term.position = Vector2(r.position) * cell
	_term.size = Vector2(r.size) * cell


func _process(delta: float) -> void:
	var t := clock.step(delta)
	if not _finished and t >= PV.END - 0.001:
		_finished = true
		playback_finished.emit()
	_sync_state()
	var ent := PvShots.shot_at(t)
	_emit_timeline(t, ent)
	_layout = PvStage.shot_layout(ent)
	_update_transition(t, ent)
	screen.begin_frame(t)
	if _tr.is_empty():
		PvFx.stage_cut(screen, t, ent)
	else:
		# 转场接管这一帧的揭示；cut 的延迟场必须清掉，否则两层会打架。
		PvFx.cancel_cut()
	# TB：B 层（终端面板的文本流）在这里
	if stream != null:
		stream.step(t, data, ent)
	panels.draw(screen, data, t, ent)
	_render_transition(t)
	_apply_points(t, ent)
	_apply_whale(t, ent)
	_apply_motion(t)
	_apply_stage(t)
	_sync_stream_rect()
	PvFx.apply(screen, t, ent)
	screen.end_frame()
	_apply_window_shake(t, ent)
	display.update_textures()
	display.update_post(PvPost.params_at(t, ent, data))
	windows.update(delta, t, ent, data, screen, str(_layout[0]), PvPanels.FPS)
	_sample_fps(delta)
	_last_t = t


## 镜头切换时排一次转场（`direction.py` 的 CHOREO；默认 glide 11 帧）。
## 用户 seek 导致的跳变不播转场（时长会很长、看起来像卡住）。
func _update_transition(t: float, ent: Dictionary) -> void:
	if _prev_ent.is_empty():
		_prev_ent = ent
		return
	if int(ent.get("index", -1)) == int(_prev_ent.get("index", -1)):
		return
	if _last_t >= 0.0 and absf(t - _last_t) > 0.5:
		_tr = {}
		_prev_ent = ent
		return
	var spec := PvStage.transition_spec(
		str(_prev_ent.get("name", "")), str(ent.get("name", "")))
	if not spec.is_empty():
		_tr = {
			"spec": spec, "t0": t,
			"dur": float(spec.get("frames", 11)) / 24.0,
			"a": _prev_ent,
		}
		# 转场替代这次切换：把镜头记忆推到新镜头，避免转场结束后再补一次 cut。
		PvFx.mark_shot(int(ent.get("index", -1)))
	_prev_ent = ent


## 把上一镜头的画面按转场进度覆盖到当前帧。
func _render_transition(t: float) -> void:
	if _tr.is_empty():
		return
	var dur := float(_tr.get("dur", 0.0))
	var el := t - float(_tr.get("t0", t))
	if dur <= 0.0 or el < 0.0 or el >= dur:
		_tr = {}
		return
	if _tr_screen == null:
		_tr_screen = PvScreen.new(atlas, COLS, ROWS)
	# panels.draw(A) 会改写 PvPanels 的静态坐标，先存 B 的，画完再恢复。
	var band := screen.stdout_rect
	var hr := PvPanels.HER_RECT
	var ha := PvPanels.HER_ART
	_tr_screen.begin_frame(t)
	_tr_screen.fill(0, 0, COLS - 1, ROWS - 1, " ", PV.UI, PV.BG)
	panels.draw(_tr_screen, data, t, _tr["a"])
	PvStage.apply_transition(screen, _tr_screen, el / dur, _tr["spec"])
	screen.stdout_rect = band
	PvPanels.HER_RECT = hr
	PvPanels.HER_ART = ha


## C 层点云（`PvParticles`）：只画在 `shot_points` 的空白主体区，固定表驱动，不摇 RNG。
func _apply_points(t: float, ent: Dictionary) -> void:
	if not (bool(PV.FX["on"]) and bool(PV.FX["points"])):
		return
	if ent.is_empty() or str(ent.get("name", "")) != "shot_points":
		return
	var lx := maxi(24, mini(screen.cols - 20, int(screen.cols * 0.60)))
	var area := Rect2i(lx + 1, 2, screen.cols - 2 - (lx + 1), screen.rows - 5 - 2)
	PvParticles.draw_points(screen, t, PvShots.shot_u(t, ent), area)


## C 层落鲸（`PvWhale`）：雪 / 接触尘 / 歌词碎屑，固定表驱动，5A 不写 stdout 带。
func _apply_whale(t: float, ent: Dictionary) -> void:
	if not (bool(PV.FX["on"]) and bool(PV.FX["whale"])):
		return
	if ent.is_empty() or str(ent.get("name", "")) != "shot_whale_fall":
		return
	var area := Rect2i(4, 4, 175, 40)
	if str(_layout[0]) == "cinema":
		area = Rect2i(4, 10, 175, 34)
	PvWhale.draw(screen, t, area)


## C 层特征驱动（`PvMotion` / `music.react`）：只作用在她的**画稿区**，且 5A 绕开 stdout 带。
## 顺序照参考 `music.py:L125-167`：逐行横移 → 掉格 → 拍点提亮 → onset 闪光。
func _apply_motion(t: float) -> void:
	if not (bool(PV.FX["on"]) and bool(PV.FX["motion"])):
		return
	var r := PvPanels.HER_ART
	if r.size.x < 8 or r.size.y < 4:
		return
	var x1 := r.position.x + r.size.x - 1
	var y1 := r.position.y + r.size.y - 1
	PvMotion.apply_band_shifts(screen, t, r.position.x, r.position.y, x1, y1,
		func(u: float) -> float:
			return data.band_at(t, clampi(int((1.0 - u) * 7.0), 0, 6)))
	PvMotion.apply_react(screen, t, r, data)


## C 层屏幕模式里能在格上直接落地的部分：影院/满出血的黑边条 + 该模式的字幕位。
## `fullbleed`/`cinema` 按 §7 冲突 4 的拍板**不缩放**，靠黑边条把顶/底让出来。
func _apply_stage(t: float) -> void:
	if not (bool(PV.FX["on"]) and bool(PV.FX["stage"])):
		return
	var mode := str(_layout[0])
	for r in PvStage.bar_rects(mode, screen.stdout_rect):
		var rect: Rect2i = r
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		screen.fill(rect.position.x, rect.position.y,
			rect.position.x + rect.size.x - 1, rect.position.y + rect.size.y - 1,
			" ", PV.UI, PV.BG)
	if mode == "cinema" or mode == "fullbleed":
		var bar_row := 4 if mode == "cinema" else 0
		# 参考 `stage.py:L328`：`" ".join(chapter.replace(" ", ""))` —— 章节名逐字加空格。
		var title := ""
		for ch in PvShots.chapter_at(t).replace(" ", ""):
			title += ch + " "
		var x := maxi(1, (screen.cols - title.length()) / 2)
		screen.put(x, bar_row, title, PV.mix(PV.ANOM, 0.85))
		var clock_text := "%02d:%04.1f" % [int(t / 60.0), fmod(maxf(0.0, t), 60.0)]
		screen.put(screen.cols - clock_text.length() - 2, bar_row, clock_text, PV.ui(0.55))


## 1B 整窗抖动（`PvFx.window_offset()` 的纯逻辑 + `PvDisplay` 的位置贴附）。
## 无抖动帧把「当前窗口位置」记成基准，因此用户手动拖窗不会被抢回居中。
func _apply_window_shake(t: float, ent: Dictionary) -> void:
	if not PvFx.use_window_shake:
		return
	var off := PvFx.window_offset(t, ent)
	if off == Vector2i.ZERO:
		display.sync_rest_position()
	display.apply_window_offset(off)


func _input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	# 输入禁用时不响应、也不吃事件（留给上层/其它 UI）。
	if not input_enabled:
		return
	_handle_key(k.keycode)
	get_viewport().set_input_as_handled()


## 输入开关（检查器里可直接勾；运行时也可以调）。关闭后底栏提示「输入禁用」。
func set_input_enabled(v: bool) -> void:
	if input_enabled == v:
		return
	input_enabled = v
	PvPanels.INPUT_ON = v
	input_enabled_changed.emit(v)


## 统一的 seek：发 `seeked`，并在回到片尾之前重新武装 `playback_finished`。
func _seek(x: float) -> void:
	clock.seek_to(x)
	if clock.t < PV.END - 0.001:
		_finished = false
	seeked.emit(clock.t)


## 镜头 / 章节变化时发信号（第一帧也会发一次，方便外部 UI 初始化）。
func _emit_timeline(t: float, ent: Dictionary) -> void:
	var idx := int(ent.get("index", -1))
	if idx != _last_index:
		_last_index = idx
		shot_changed.emit(idx, str(ent.get("name", "")))
	var chapter := PvShots.chapter_at(t)
	if chapter != _last_chapter:
		_last_chapter = chapter
		chapter_changed.emit(chapter)


## 按键表照抄 `tui_live.main()`（tools/ref/layout.md §6）。两处例外：
##   * `h` 在 `("auto","h3","half","glyph")` 间循环她的渲染路径（tui_live.py:L3512-3519）；切到
##     h3/auto 时先把 take 预热，与参考实现一致（不 `seek` 重放）；
##   * `b` 是本次新增（参考实现里没有）：开关 B 层终端面板，便于对照 A / A+B 两种效果。
func _handle_key(code: int) -> void:
	match code:
		KEY_Q, KEY_ESCAPE:
			get_tree().quit()
		KEY_SPACE:
			clock.toggle()
			if clock.playing:
				playback_started.emit()
			else:
				playback_paused.emit()
		KEY_M:
			clock.toggle_muted()
		KEY_H:
			var modes := PvPanels.RENDER_MODES
			var i := modes.find(PvPanels.HER_RENDER)
			PvPanels.HER_RENDER = str(modes[(i + 1) % modes.size()])
			if PvPanels.HER_RENDER in ["h3", "auto"]:
				PvHer.warm_h3()
		KEY_B:
			if stream != null:
				stream.enabled = not stream.enabled
				stream.seek(clock.t, data, PvShots.shot_at(clock.t))
		KEY_X:
			PV.FX["on"] = not bool(PV.FX["on"])
			PvFx.reset(screen)
			screen.refresh_dim()
		KEY_C:
			PvPanels.CHAT = not PvPanels.CHAT
		KEY_P:
			PV.FX["post"] = not bool(PV.FX["post"])
		KEY_V:
			PV.FX["motion"] = not bool(PV.FX["motion"])
		KEY_K:
			PV.FX["stage"] = not bool(PV.FX["stage"])
		KEY_W:
			if windows != null:
				windows.toggle()
		KEY_MINUS, KEY_UNDERSCORE:
			clock.add_volume(-VOLUME_STEP)
		KEY_EQUAL, KEY_PLUS:
			clock.add_volume(VOLUME_STEP)
		KEY_COMMA, KEY_LESS:
			_seek(clock.t - 1.0)
		KEY_PERIOD, KEY_GREATER:
			_seek(clock.t + 1.0)
		KEY_LEFT:
			_seek(clock.t - 5.0)
		KEY_RIGHT:
			_seek(clock.t + 5.0)
		KEY_HOME:
			_seek(0.0)
		KEY_END:
			_seek(PV.END)


## 底栏要显示的播放状态由 PvClock 每帧同步过来。
func _sync_state() -> void:
	PvPanels.PLAYING = clock.playing
	PvPanels.VOL_PCT = clock.volume_pct
	PvPanels.MUTED = clock.muted
	PvPanels.STREAM_ON = stream != null and stream.enabled


## 每 0.5 s 采一次帧率（`tui_live.main()` 的 fps 采样同上）。
func _sample_fps(delta: float) -> void:
	_fps_frames += 1
	_fps_time += delta
	if _fps_time >= FPS_WINDOW:
		PvPanels.FPS = _fps_frames / _fps_time
		_fps_frames = 0
		_fps_time = 0.0
