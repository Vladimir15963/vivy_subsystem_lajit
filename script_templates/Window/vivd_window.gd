extends "res://subsystem/vivd_windows/vivd_window.gd"
## 新建 vivd 窗口类型的模板。
##
## 步骤：
##   1. 新建场景，根节点类型选 Window
##   2. 给根节点挂上这个脚本
##   3. 在 res://subsystem/vivd_windows/vivd_windows.tscn 的检查器里，
##      往 window_types 加一条「类型名 → 这个场景」；
##      或者把它放进 auto_scan_dirs 指向的目录里自动注册
##
## 之后就能用 VivdWindowsNode.add_window("窗口名", "类型名", {...}) 打开它了。
##
## 提示：dev 浮层、fade_in/fade_out、关闭按钮注销都由 VivdWindow 提供，这里不用重复写。
## 如果重写了 _ready()，记得第一行调用 super._ready()。


## config 就是 add_window() 收到的那本字典（title/position/size 已被管理器消费）。
func setup(config: Dictionary) -> void:
	pass


## 可选：窗口被移除前调用，用来断开连接、保存状态。
func teardown() -> void:
	pass
