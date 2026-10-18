extends ColorRect

## 内置转场：全屏淡入淡出（黑场）。
## 用法：SceneLoader.goto_scene(path, {"transition": "fade"})
## 进场淡到黑 → 黑场中换场景 → 退场淡出，配合预加载就是“看起来无缝”的过渡。

signal in_finished
signal out_finished

var in_duration := 0.25
var out_duration := 0.3

var _tween: Tween


## 转场接口占位：淡入淡出没有进度/标题可显示
func set_title(_text: String) -> void:
	pass


func set_progress(_ratio: float) -> void:
	pass


func play_in() -> void:
	_kill_tween()
	color.a = 0.0
	_tween = create_tween()
	_tween.tween_property(self, "color:a", 1.0, in_duration)
	_tween.finished.connect(_on_tween_in_finished, CONNECT_ONE_SHOT)


func play_out() -> void:
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(self, "color:a", 0.0, out_duration)
	_tween.finished.connect(_on_tween_out_finished, CONNECT_ONE_SHOT)


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()


func _on_tween_in_finished() -> void:
	in_finished.emit()


func _on_tween_out_finished() -> void:
	out_finished.emit()
