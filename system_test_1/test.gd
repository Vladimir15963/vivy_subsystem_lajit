extends Node

## vivd 多窗口测试：验证管理器 API 和窗口基类。
## VivdWindowsNode 在 project.godot 里注册为 autoload。

const CARD_POS := Vector2i(500, 500)
const HOME_POS := Vector2i(100, 100)


func _ready() -> void:
	## 开启调试浮层（会同时作用到已经打开的窗口）
	VivdWindowsNode.set_dev(true)

	VivdWindowsNode.add_window("test", "default", {
		"title": "测试窗口",
		"position": CARD_POS,
		"size": Vector2i(400, 260),
	})

	VivdWindowsNode.add_window("file_examin_window", "file_examin", {
		"title": "文件拖放",
		"position": Vector2i(120, 120),
		"size": Vector2i(520, 200),
	})


func _on_button_button_up() -> void:
	VivdWindowsNode.move_window("test", CARD_POS, 0.5)
	VivdWindowsNode.call_window_method("test", "ping", ["来自按钮"])


func _on_button_2_button_up() -> void:
	VivdWindowsNode.move_window("test", HOME_POS, 0.5)
