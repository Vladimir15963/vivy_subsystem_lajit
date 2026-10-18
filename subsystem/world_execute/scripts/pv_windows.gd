class_name PvWindows
extends Node

## C 层「附加 OS 窗口」（阶段 3，**本工程的新设计**）。
##
## 参考仓库里没有真窗口：电影版的「多窗口」是 1280×720 画布上画的假窗框
## （`full/stage.py:L198-204`）。2026-10-17 的拍板（`tools/ref/c_layer_plan.md` §7 冲突 2 / Q3）是
## **允许常驻附加窗口，并尽量使用真 OS 窗口**，所以这里直接复用工程已有的
## `subsystem/vivd_windows/`（autoload `VivdWindowsNode`，`embed_subwindows=false`）。
##
## 职责边界（§7 硬规则 3）：附加窗口只承载**增强信息**，不复制主窗口的 197×52 画面：
##
##   * `pv_info`  —— 章节 / 时间 / 屏幕模式 / 她的渲染路径 / 帧率（"text" 类型）
##   * `pv_log`   —— 当前镜头的 ops 与歌词（"text" 类型）
##   * `pv_her`   —— 当前表情的立绘原图（"image" 类型）
##
## 生命周期：`W` 键开关；主场景退出时 `close_all()`；headless 下 `available` 为 false，全部空转。

const PREFIX := "pv_"
const INFO := "pv_info"
const LOG := "pv_log"
const HER := "pv_her"

const INFO_SIZE := Vector2i(380, 300)
const LOG_SIZE := Vector2i(420, 360)
const HER_SIZE := Vector2i(300, 420)
const GAP := 12

## 内容刷新间隔（秒）：文本窗口每帧重排很贵，4 Hz 足够读。
const REFRESH := 0.25

## 真实 OS 窗口可用（headless / 内嵌窗口时为 false）。
var available := false
var open := false

var _manager: Node = null
var _main: Window = null
var _acc := 0.0
var _last_expression := ""


## `cell` 目前只用来对齐信息窗的字体密度（保留参数，避免将来再改签名）。
func setup(main_window: Window, _cell: Vector2) -> void:
	_main = main_window
	if not PvDisplay.can_create_textures():
		return
	_manager = get_node_or_null("/root/VivdWindowsNode")
	if _manager == null:
		push_warning("world_execute: 未找到 VivdWindowsNode，附加窗口不可用")
		return
	if not _manager.has_method("add_window"):
		return
	available = true
	tree_exiting.connect(close_all)


## `W` 键：开/关全部附加窗口。窗口位置只在打开时算一次，之后用户可以自由拖。
func toggle() -> void:
	if not available:
		return
	if open:
		close_all()
	else:
		open_all()


func open_all() -> void:
	if not available or open:
		return
	var rects := _layout()
	_manager.call("add_window", INFO, "text", {
		"title": "world.execute(me); / info",
		"position": rects[0].position,
		"size": rects[0].size,
		"font_size": 15,
		"bg_color": Color(0.016, 0.027, 0.059, 0.96),
		"text_color": Color(0.78, 0.84, 0.92),
		"line_separation": 5,
		"scrollbar": false,
	})
	_manager.call("add_window", LOG, "text", {
		"title": "world.execute(me); / log",
		"position": rects[1].position,
		"size": rects[1].size,
		"font_size": 15,
		"bg_color": Color(0.016, 0.027, 0.059, 0.96),
		"text_color": Color(0.78, 0.84, 0.92),
		"line_separation": 5,
	})
	_manager.call("add_window", HER, "image", {
		"title": "world.execute(me); / me",
		"position": rects[2].position,
		"size": rects[2].size,
		"image": _sprite_path("cheerful"),
	})
	open = true
	_acc = REFRESH


func close_all() -> void:
	open = false
	if _manager == null:
		return
	for name in [INFO, LOG, HER]:
		if bool(_manager.call("has_window", name)):
			_manager.call("remove_window", name)


## 每帧调用；内部按 `REFRESH` 节流。`data` 可为 null（此时只画已有内容）。
func update(delta: float, t: float, ent: Dictionary, data: PvData, screen: PvScreen,
		mode: String, fps: float) -> void:
	if not available or not open:
		return
	_acc += delta
	if _acc < REFRESH:
		return
	_acc = 0.0
	_put_text(INFO, _info_text(t, ent, screen, mode, fps))
	_put_text(LOG, _log_text(t, ent, data))
	var expr := _expression_for(t)
	if expr != _last_expression:
		_last_expression = expr
		_manager.call("call_window_method", HER, "set_image", [_sprite_path(expr)])


# ---------------------------------------------------------------- 内容

func _info_text(t: float, ent: Dictionary, screen: PvScreen, mode: String, fps: float) -> String:
	var shot := str(ent.get("name", "-"))
	var lines := PackedStringArray()
	lines.append("[color=#7e98ff]%s[/color]" % PvShots.chapter_at(t))
	lines.append("time    %02d:%04.1f / 03:32" % [int(t / 60.0), fmod(maxf(0.0, t), 60.0)])
	lines.append("shot    %s" % shot)
	lines.append("mode    [color=#ffcc00]%s[/color]" % mode)
	lines.append("her     %s" % PvPanels.HER_RENDER)
	lines.append("window  %d x %d cells" % [screen.cols, screen.rows])
	lines.append("fps     %.1f" % fps)
	lines.append("vol     %d%%%s" % [PvPanels.VOL_PCT, " (muted)" if PvPanels.MUTED else ""])
	lines.append("")
	lines.append("[color=#78869e]P post  V motion  K stage[/color]")
	lines.append("[color=#78869e]W windows  X fx  B stream[/color]")
	return "\n".join(lines)


func _log_text(t: float, ent: Dictionary, data: PvData) -> String:
	var lines := PackedStringArray()
	var ops: Array = ent.get("ops", []) if not ent.is_empty() else []
	if not ops.is_empty():
		var beat := PV.beat_index(t)
		var cur := posmod(beat, ops.size())
		for i in ops.size():
			var mark := ">" if i == cur else " "
			lines.append("[color=%s]%s %s[/color]" % [
				"#ffcc00" if i == cur else "#78869e", mark, str(ops[i])])
	if data != null:
		var pair: Array = data.line_at(t)
		if not pair.is_empty() and not (pair[0] as Dictionary).is_empty():
			lines.append("")
			lines.append("[color=#7e98ff]%s[/color]" % str((pair[0] as Dictionary).get("text", "")))
			var cn := data.lyric_cn_for(str((pair[0] as Dictionary).get("text", "")))
			if not cn.is_empty():
				lines.append("[color=#c8d6ea]%s[/color]" % cn)
	return "\n".join(lines)


func _put_text(name: String, body: String) -> void:
	if not bool(_manager.call("has_window", name)):
		return
	_manager.call("call_window_method", name, "set_text", [body])


## 立绘表情按章节轮换（与 A 层 glyph 路径同一个表情表；这里只挑静态图）。
func _expression_for(t: float) -> String:
	var names := ["cheerful", "starry", "shy", "serious", "confused", "frightened", "angry", "exasperated"]
	var chapter := PvShots.chapter_at(t)
	var hash := 0
	for ch in chapter:
		hash = (hash * 31 + ch.unicode_at(0)) & 0x7fffffff
	return names[hash % names.size()]


func _sprite_path(expr: String) -> String:
	return "res://subsystem/world_execute/data/her_sprite/%s.png" % expr


# ---------------------------------------------------------------- 摆放

## 三个窗口的初始位置：优先放到主窗口右侧的空位，其次左侧，最后退回「屏幕内层叠」。
## 只算一次；之后由用户/系统决定位置（§7：位置不锁定）。
func _layout() -> Array:
	var screen := 0
	var usable := Rect2i(Vector2i.ZERO, Vector2i(1920, 1080))
	if DisplayServer.get_name() != "headless":
		screen = DisplayServer.window_get_current_screen()
		usable = DisplayServer.screen_get_usable_rect(screen)
	var base := usable.position
	var base_size := usable.size
	var mpos := base
	var msize := base_size
	if _main != null:
		mpos = _main.position
		msize = _main.size
	var right_x := mpos.x + msize.x + GAP
	var left_x := mpos.x - LOG_SIZE.x - GAP
	var room_right := base.x + base_size.x - right_x
	var room_left := mpos.x - base.x
	var info := Rect2i()
	var log := Rect2i()
	var her := Rect2i()
	if room_right >= INFO_SIZE.x:
		info = Rect2i(right_x, mpos.y, INFO_SIZE.x, INFO_SIZE.y)
		log = Rect2i(right_x, mpos.y + INFO_SIZE.y + GAP, LOG_SIZE.x, LOG_SIZE.y)
		her = Rect2i(right_x + INFO_SIZE.x + GAP, mpos.y, HER_SIZE.x, HER_SIZE.y)
	elif room_left >= LOG_SIZE.x:
		info = Rect2i(left_x, mpos.y, INFO_SIZE.x, INFO_SIZE.y)
		log = Rect2i(left_x, mpos.y + INFO_SIZE.y + GAP, LOG_SIZE.x, LOG_SIZE.y)
		her = Rect2i(left_x, mpos.y + INFO_SIZE.y + LOG_SIZE.y + 2 * GAP, HER_SIZE.x, HER_SIZE.y)
	else:
		# 主窗口几乎占满屏幕：叠在屏幕内侧，用户可自行拖开。
		info = Rect2i(base.x + GAP, base.y + GAP, INFO_SIZE.x, INFO_SIZE.y)
		log = Rect2i(base.x + GAP, base.y + INFO_SIZE.y + 2 * GAP, LOG_SIZE.x, LOG_SIZE.y)
		her = Rect2i(base.x + base_size.x - HER_SIZE.x - GAP, base.y + GAP, HER_SIZE.x, HER_SIZE.y)
	return [info, log, her]
