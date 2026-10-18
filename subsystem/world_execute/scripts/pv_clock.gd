class_name PvClock
extends RefCounted

## 播放时钟：以「音频位置 − 输出延迟」为主时钟，墙钟只在音频不可用时兜底。
##
## 三段校正策略逐字照抄 `pv_audio.lock()`：
##   |差| ≤ 0.15 s → 不动（墙钟自己走）；
##   |差| >  0.6 s → 真跳，直接对到音频位置；
##   其余      → 每帧最多纠 0.12 s，因此永远看不出跳变。
##
## 无音频（headless 自测 / 没装音频设备）时 `player == null`，退化为纯墙钟，行为与参考实现
## `--no-audio` 一致。

const TOLERANCE := 0.15
const MAX_STEP := 0.12
const BIG_JUMP := 0.6

var player: AudioStreamPlayer       ## 可为 null
var latency := 0.0                  ## 额外校准偏移；设备延迟已由 AudioServer 算掉
var t := 0.0
var playing := false
var volume_pct := 80                ## 0..100
var muted := false


## `player` 可以是 null（纯墙钟）。`start` 为起始秒数。
func _init(p: AudioStreamPlayer = null, start := 0.0) -> void:
	player = p
	t = start
	_apply_volume()


## 推进一帧并返回当前时间（秒）。
func step(delta: float) -> float:
	if not playing:
		return t
	t = minf(PV.END, t + delta)
	var target := _audio_target()
	if target >= 0.0:
		var d := target - t
		if absf(d) > TOLERANCE:
			if absf(d) > BIG_JUMP:
				t = clampf(target, 0.0, PV.END)
			else:
				t = clampf(t + clampf(d, -MAX_STEP, MAX_STEP), 0.0, PV.END)
	if t >= PV.END:
		playing = false
		if player != null:
			player.stop()
	return t


## 音频正在播到的时间；不可用时返回 -1（调用方保持自己的墙钟）。
func _audio_target() -> float:
	if player == null or not player.playing:
		return -1.0
	var pos := player.get_playback_position() \
		+ AudioServer.get_time_since_last_mix() \
		- AudioServer.get_output_latency() - latency
	return -1.0 if pos < 0.0 else pos


# ---------------------------------------------------------------- 控制

func play() -> void:
	playing = true
	if player != null and not player.playing:
		player.play(t)


func pause() -> void:
	playing = false
	if player != null:
		player.stop()


func toggle() -> void:
	if playing:
		pause()
	else:
		play()


## 跳到 x 秒（下/上一个 1 s、±5 s、home/end 都用它）。
func seek_to(x: float) -> float:
	t = clampf(x, 0.0, PV.END)
	if playing and player != null:
		player.play(t)
	return t


func set_muted(v: bool) -> void:
	muted = v
	_apply_volume()


func toggle_muted() -> void:
	set_muted(not muted)


func add_volume(delta_pct: int) -> void:
	volume_pct = clampi(volume_pct + delta_pct, 0, 100)
	_apply_volume()


func _apply_volume() -> void:
	if player == null:
		return
	if muted or volume_pct <= 0:
		player.volume_db = -80.0
	elif volume_pct >= 100:
		player.volume_db = 0.0
	else:
		player.volume_db = linear_to_db(volume_pct / 100.0)
