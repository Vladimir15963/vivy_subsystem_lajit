extends "res://subsystem/vivd_windows/vivd_window.gd"
## 通用窗口类型 —— 只需要基类的通用能力，没有额外业务。
##
## 拿它来验证 add_window / move_window / resize_window / fade_in / fade_out /
## call_window_method / dev 浮层这些通路。


## 示例方法：VivdWindowsNode.call_window_method("名字", "ping", ["参数"])
## 返回值故意做成可断言的，方便冒烟测试验证「参数有没有被展开」。
func ping(value := "", extra := "") -> String:
	var text := "pong:%s" % str(value)
	if not str(extra).is_empty():
		text += "+" + str(extra)
	print("[default_window:%s] ping %s" % [name, text])
	return text
