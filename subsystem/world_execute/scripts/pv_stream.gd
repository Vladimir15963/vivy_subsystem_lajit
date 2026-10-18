class_name PvStream
extends RefCounted

## B 层：文本流层。
##
## 把工程内现成的 `FakeTerminal`（godot_xterm 的 `Terminal` 子类，只输出模式）当成「真终端」，
## 用同一个时钟 `t` 把四路数据流逐行灌进去（与 A 层字符格画面并排）：
##
##   * boot 日志（`data/boot_log.json` 的 `[[t, tag, text]]`）—— 到点即打印，带 `[OK ]/[WARN]` 牌；
##   * 歌词（`data/words.json` 的行）—— 到点开打，打字机逐字推进，打完补一行中文对照；
##   * ops（当前镜头的 `ops` 列表）—— 按半拍滚动，中心步变化时才落一行；
##   * dsh 聊天（`data/dsh.json` 的逐帧 DOM）—— 新出现的行落一行（按 `role+text` 去重）。
##
## 打字机用 `\r` + `CLEAR_LINE` 覆写当前行，所以中途擦除不会污染历史（思路同参考实现
## `Screen.render_diff` 的差量重绘，只是这里交给真终端自己滚屏）。
##
## 时钟回退、或前跳超过 `BIG_JUMP` 秒 → `seek()`：清屏 + 静默把 t 之前的整段快速重放一遍
## （静默模式下每行一次打满，不走打字机）。所以 `h`/方向键跳转之后终端内容始终与 t 一致。
##
## 自测友好：`term` 可为 null —— 此时不碰真终端，只把**打完的整行**记进 `log: Array[String]`
## （纯文本），于是整套时序能在 headless 下断言（t7 定下的规矩：逻辑与渲染分开）。

## 打字机速度（字符 / 秒）。歌词行均约 25 字符、行间隔约 2.2 s，28 够用。
const TYPE_CPS := 28.0
## 前跳超过这么多秒就当作「跳转」，重置重放（而不是刷一屏历史）。
const BIG_JUMP := 1.0
## 回退超过这么多秒才重置（容忍时钟抖动的噪声；PvClock 本身每帧最多纠 0.12 s）。
const REWIND_EPS := 0.35
## `dsh_at()` 的帧率（`data/dsh.json` 的 `hz`）。仅用来判断「帧号变了才取数据」。
const DSH_HZ := 12.0

## 只把真正的对话行打进终端。dsh 的逐帧 DOM 里还混着头像/状态/胶囊等片段
## （`name` / `state` / `dot` / `pill` / `meta` / `sub` / `card`），这些不是聊天内容，跳过。
const CHAT_ROLES := ["ai", "model", "composer", "user"]

const CURSOR := "█"
const LYRIC_PREFIX := "~ "
const CN_PREFIX := "  // "
const OPS_PREFIX := "$ "

## 真终端；为 null 时只往 `log` 里记纯文本（headless 自测）。
var term: FakeTerminal = null
## 已输出的整行（纯文本，无色）。即使 `term != null` 也会同步记录，方便游戏侧读回。
var log: Array[String] = []
## `b` 键的开关。关掉时 `step()` 直接返回（面板保持现状）。
var enabled := true

var _boot_i := 0
var _chap := ""
var _shot_i := -1
var _ops_text := "\u0000"
var _lyr_idx := -1
var _lyr_shown := 0
var _chat_frame := -1
var _chat_seen: Dictionary = {}
var _last_t := -1.0


func _init(p_term: FakeTerminal = null, p_enabled := true) -> void:
	term = p_term
	enabled = p_enabled
	if term != null:
		term.set_output_only(true)


# ================================================================ 对外接口

## 每帧推进。`ent` 为当前镜头（无则 `{}`）。
func step(t: float, d: PvData, ent: Dictionary) -> void:
	if not enabled:
		return
	if _last_t >= 0.0 and (t < _last_t - REWIND_EPS or t - _last_t > BIG_JUMP):
		seek(t, d, ent)
		return
	_advance(t, d, ent, false)
	_last_t = t


## 清屏（若有终端）并把状态归零；`_last_t` 置 -1。
func reset() -> void:
	_boot_i = 0
	_chap = ""
	_shot_i = -1
	_ops_text = "\u0000"
	_lyr_idx = -1
	_lyr_shown = 0
	_chat_frame = -1
	_chat_seen.clear()
	_last_t = -1.0
	log.clear()
	if term != null:
		term.clear_screen()


## 跳到 t 并静默重放（清屏 → 一次把 t 之前的整段铺出来）。
func seek(t: float, d: PvData, ent: Dictionary) -> void:
	reset()
	_advance(t, d, ent, true)
	_last_t = t


# ================================================================ 四路数据流

## `silent` = 静默重放：歌词不打字机一次打满，章节条把 t 之前的整串补齐。
func _advance(t: float, d: PvData, ent: Dictionary, silent: bool) -> void:
	_emit_chapter(t, silent)
	_emit_boot(t, d)
	_emit_lyrics(t, d, silent)
	_emit_ops(t, ent)
	_emit_chat(t, d)


## 章节条：标签变了才打。静默重放时把 t 之前的所有章节条按序补齐。
func _emit_chapter(t: float, silent: bool) -> void:
	if silent:
		for row in PvShots.chapters():
			var label := str(row[1])
			if float(row[0]) <= t and label != _chap:
				_chap = label
				_write_line("== %s ==" % label, PV.mix(PV.ANOM, 0.75))
		return
	var c := PvShots.chapter_at(t)
	if c == _chap:
		return
	_chap = c
	_write_line("== %s ==" % c, PV.mix(PV.ANOM, 0.75))


## boot 日志：`[[t, tag, text]]` 里时间到了的全打。
func _emit_boot(t: float, d: PvData) -> void:
	while _boot_i < d.boot_log.size() and float(d.boot_log[_boot_i][0]) <= t:
		var row: Array = d.boot_log[_boot_i]
		_boot_i += 1
		var tag := str(row[1])
		_write_line("[%s] %s" % [tag.rpad(4), str(row[2])], _tag_colour(tag))


## 歌词：一个 while 循环把「起唱时间已到」的行逐行推进，当前行由 `_type_current()` 打字。
func _emit_lyrics(t: float, d: PvData, silent: bool) -> void:
	var n := d.lines.size()
	while _lyr_idx + 1 < n and float(d.lines[_lyr_idx + 1]["start"]) <= t:
		if _lyr_idx >= 0 and not _type_current(t, d, silent):
			return                      # 当前行还没打完，本轮到此为止（打字机落后）
		_lyr_idx += 1
		_lyr_shown = 0
	if _lyr_idx >= 0:
		_type_current(t, d, silent)


## 把当前行推进到 t 应有的进度，返回「这行是否已经打完（可以进入下一行）」。
func _type_current(t: float, d: PvData, silent: bool) -> bool:
	var text := str(d.lines[_lyr_idx]["text"])
	if _lyr_shown >= text.length():
		return true
	var shown := text.length() if silent else mini(text.length(),
		int((t - float(d.lines[_lyr_idx]["start"])) * TYPE_CPS) + 1)
	if shown <= _lyr_shown:
		return false
	_lyr_shown = shown
	var done := shown >= text.length()
	_overwrite(LYRIC_PREFIX + text.substr(0, shown) + ("" if done else CURSOR),
		PV.mix(PV.ME_TEXT, 0.95), done)
	if done:
		var cn := d.lyric_cn_for(text)
		if cn != "":
			_write_line(CN_PREFIX + cn, PV.mix(PV.ME_TEXT, 0.6))
	return done


## ops：镜像 A 层 ops ticker 的中心步（`base = int(t / (BEAT/2))`，环形回绕）。
## 中心步文本或镜头号变了才落一行，免得每半拍刷一行把终端刷爆。
func _emit_ops(t: float, ent: Dictionary) -> void:
	if ent.is_empty():
		return
	var slot := int(t / (PV.BEAT / 2.0))
	var ops: Array = ent.get("ops", [])
	var text := "IDLE"
	if ops.size() > 0:
		text = str(ops[wrapi(slot, 0, ops.size())])
	var shot := int(ent.get("index", -1))
	if text == _ops_text and shot == _shot_i:
		return
	_ops_text = text
	_shot_i = shot
	_write_line(OPS_PREFIX + text, PV.RED if str(ent.get("alert", "")) == "err" else PV.mix(PV.UI, 0.8))


## dsh 聊天：只在覆盖段内、且帧号变了才取数据；行按 `role+text` 去重（DOM 是累加快照）。
func _emit_chat(t: float, d: PvData) -> void:
	if not PvShots.dsh_inside(t):
		return
	var idx := int(t * DSH_HZ)
	if idx == _chat_frame:
		return
	_chat_frame = idx
	for it in (d.dsh_at(t).get("rows", []) as Array):
		var role := str(it.get("role", ""))
		if not CHAT_ROLES.has(role):
			continue
		var text := str(it.get("text", ""))
		var key := role + "\u0000" + text
		if _chat_seen.has(key):
			continue
		_chat_seen[key] = true
		_write_line("%s> %s" % [_role_name(role), text], _role_colour(role))


# ================================================================ 输出原语

## 落一整行（终端会换行滚屏）。
func _write_line(plain: String, colour: int) -> void:
	log.append(plain)
	if term != null:
		term.print_line(_paint(plain, colour))


## 覆写当前行（`\r` + CLEAR_LINE）；`newline` 为真时收尾换行。
func _overwrite(plain: String, colour: int, newline: bool) -> void:
	if term == null:
		if newline:
			log.append(plain)
		return
	var s := "\r" + FakeTerminal.CLEAR_LINE + _paint(plain, colour)
	if newline:
		s += "\r\n"
	term.write(s)


## `colour < 0` 表示不上色。用 24 位真彩 ANSI（`Terminal` 的 ansi 主题同样吃）。
func _paint(plain: String, colour: int) -> String:
	return plain if colour < 0 else term.colorize(plain, PV.to_color(colour))


# ================================================================ 配色

func _tag_colour(tag: String) -> int:
	match tag:
		"OK":
			return PV.mix(PV.UI, 0.95)
		"WARN":
			return PV.mix(PV.ANOM, 0.95)
		"..":
			return PV.mix(PV.UI, 0.5)
		_:
			return PV.mix(PV.UI, 0.8)


func _role_colour(role: String) -> int:
	match role:
		"model":
			return PV.mix(PV.ME_TEXT, 0.95)
		"composer", "user":
			return PV.mix(PV.UI, 0.8)
		"system", "tool":
			return PV.mix(PV.ANOM, 0.8)
		_:
			return PV.mix(PV.UI, 0.7)


func _role_name(role: String) -> String:
	match role:
		"model":
			return "dsh"
		"composer", "user":
			return "you"
		_:
			return role if role != "" else "sys"
