extends "res://vivd_windows/vivd_window.gd"
## 文件拖放窗口类型 —— 把文件拖进窗口就能拿到路径。
##
## 用的是 Window 自带的 [signal Window.files_dropped] 信号，不需要额外配置。
## 注意：[b]headless 运行下没有真实窗口，收不到拖放事件[/b]。

@onready var _hint: Label = get_node_or_null("Hint")

## 最近一次拖入的文件。
var last_dropped: PackedStringArray = PackedStringArray()


func _ready() -> void:
	# 基类要靠这个装 dev 浮层、接窗口关闭按钮。子类重写 _ready 时必须调用 super。
	super._ready()
	files_dropped.connect(_on_files_dropped)


func setup(_config: Dictionary) -> void:
	pass


func _on_files_dropped(paths: PackedStringArray) -> void:
	last_dropped = paths
	print("[file_examin_window:%s] 收到 %d 个文件：%s" % [name, paths.size(), ", ".join(paths)])
	if _hint != null:
		_hint.text = "收到 %d 个文件：\n%s" % [paths.size(), "\n".join(paths)]
