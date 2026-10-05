extends Node

#假设的剧本，用于测试多窗口动态演示系统

func _ready():
    ## 开启多窗口调试模式
    VivdWindowsNode.set_dev(true)
    print("test")
    VivdWindowsNode.add_window("test","test","defaultf","test")
    VivdWindowsNode.add_window("file_examin_window","文件_examin_window","file_examin","test")

    # VivdWindowsNode.move_window("test",Vector2i(100,100))

    VivdWindowsNode.move_window("test",Vector2i(500,500))


func _on_button_button_up() -> void:
    VivdWindowsNode.move_window("test",Vector2i(500,500))
    VivdWindowsNode.call_window_method("test","test","test","test")


    

func _on_button_2_button_up() -> void:
    VivdWindowsNode.move_window("test",Vector2i(100,100))
