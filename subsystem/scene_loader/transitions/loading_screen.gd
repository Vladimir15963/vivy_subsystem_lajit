extends Control

## 默认转场：读条加载界面。
## 由 SceneLoader 实例化并调用：
##   set_title(text) / set_progress(0~1) / set_min_display_time(sec) / play_in() / play_out()
## 动画结束时发 in_finished / out_finished。

signal in_finished
signal out_finished

## 进场 / 退场时长。SceneLoader 在没有对应信号时会用它兜底。
var in_duration := 0.18
var out_duration := 0.25

@onready var _title_label: Label = $Center/VBox/TitleLabel
@onready var _progress_bar: ProgressBar = $Center/VBox/ProgressBar
@onready var _percent_label: Label = $Center/VBox/PercentLabel

var _target_ratio := 0.0     ## SceneLoader 喂进来的真实加载进度
var _shown_ratio := 0.0      ## 界面上实际显示的进度（只前进）
var _min_display_time := 1.0 ## 至少显示多久，由 SceneLoader 告知
var _elapsed := 0.0
var _tween: Tween


## 可选接口：SceneLoader 会告知本次转场的最短显示时长
func set_min_display_time(seconds: float) -> void:
	_min_display_time = maxf(seconds, 0.0)


func set_title(text: String) -> void:
	_title_label.text = text


func set_progress(ratio: float) -> void:
	_target_ratio = clampf(ratio, 0.0, 1.0)


func _process(delta: float) -> void:
	_elapsed += delta
	# 真实加载可能瞬间完成（小场景），此时按最短显示时长匀速把读条走完，
	# 避免“读条一闪而过”；真实加载慢的时候则完全跟随真实进度。
	var sweep := _elapsed / maxf(_min_display_time * 0.9, 0.01)
	var desired := sweep if _target_ratio >= 1.0 else maxf(_target_ratio, minf(sweep, 0.95))
	_shown_ratio = maxf(_shown_ratio, clampf(desired, 0.0, 1.0))
	_progress_bar.value = _shown_ratio * 100.0
	_percent_label.text = "%d%%" % roundi(_shown_ratio * 100.0)


func play_in() -> void:
	_kill_tween()
	modulate.a = 0.0
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, in_duration)
	_tween.finished.connect(_on_tween_in_finished, CONNECT_ONE_SHOT)


func play_out() -> void:
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, out_duration)
	_tween.finished.connect(_on_tween_out_finished, CONNECT_ONE_SHOT)


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()


func _on_tween_in_finished() -> void:
	in_finished.emit()


func _on_tween_out_finished() -> void:
	out_finished.emit()
