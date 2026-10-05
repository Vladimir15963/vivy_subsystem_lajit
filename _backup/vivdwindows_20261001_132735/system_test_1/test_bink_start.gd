extends Node
var VW := VivdWindowsNode

func _ready():
    ## 开启多窗口调试模式
    VW.set_dev(true)
    print("test_bink_start")
    grenrate_windows()


func grenrate_windows():
    VW.add_window("test","test","defaultf","test")
    VW.resize_window("test",Vector2i(500,500))

    VW.move_window("test",Vector2i(100,100))
    
    VW.add_window("image_window","图片窗口","image","res://icon.svg",Vector2i(555,555))
    VW.resize_window("image_window",Vector2i(324,324))
    VW.move_window("image_window",Vector2i(500,500))
    