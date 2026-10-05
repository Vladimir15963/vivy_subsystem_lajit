extends Node

var VW := VivdWindowsNode
var windows_n=0

func _ready() -> void:
	## 开启调试浮层
	VW.set_dev(true)
	print("test_bink_start")
	generate_windows()


func generate_windows() -> void:
	VW.add_window("test", "default", {
		"title": "test",
		"position": Vector2i(100, 100),
		"size": Vector2i(500, 500),
	})

	VW.add_window("image_window", "image", {
		"title": "图片窗口",
		"image": "res://assets/DSniang1.png",
		"position": Vector2i(500, 500),
		"size": Vector2i(324, 324),
	})


func _on_test_1_button_up() -> void:
	windows_n+=1
	VW.add_window("tip"+str(windows_n), "default", {
		"title": "tip"+str(windows_n),
		"position": Vector2i(100, 100),
		"size": Vector2i(500, 500),
	})
	pass # Replace with function body.


func _on_test_2_button_up() -> void:
	 # 4. 操作它们
	VW.move_window("tip"+str(windows_n), Vector2i(200, 200), 0.5)  
	VW.fade_window_in("tip"+str(windows_n), 0.3)
	VW.bring_window_to_front("tip"+str(windows_n))

	VW.remove_window("tip"+str(windows_n))
	windows_n-=1

func _on_button_button_up() -> void:
	VivdWindowsNode.add_window("movie", "video", {
    "video": "res://system_test_1/VID20250306230957.mp4",
    "position": Vector2i(300, 200),
    "size": Vector2i(960, 540),
    "autoplay": true, "loop": false, "volume_db": -6.0,
})
	VivdWindowsNode.call_window_method("movie", "seek_ms", [12000])