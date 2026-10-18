@tool
extends EditorPlugin

## JSON Lens —— 编辑器插件入口
##
## 注册为「主屏」工具（顶部和 2D / 3D / Script 并列的那个标签页），
## 因为阅读超长 JSON 需要尽可能宽的区域，窄坞站不够用。

const PanelScript := preload("res://addons/json_lens/json_lens_panel.gd")

var _panel: Control = null
var _dock_mode := false


func _enter_tree() -> void:
	_panel = PanelScript.new()
	_panel.name = "JSON Lens"
	var host := _main_screen()
	if host != null:
		host.add_child(_panel)
		_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_panel.visible = false
	else:
		# 兜底：主屏容器不可用时退到底部坞站，至少还能用。
		_dock_mode = true
		_panel.custom_minimum_size = Vector2(0, 280)
		add_control_to_dock(DOCK_SLOT_BOTTOM, _panel)


func _exit_tree() -> void:
	if is_instance_valid(_panel):
		if _dock_mode:
			remove_control_from_docks(_panel)
		_panel.queue_free()
	_panel = null


func _has_main_screen() -> bool:
	return not _dock_mode


func _get_plugin_name() -> String:
	return "JSON Lens"


func _make_visible(visible: bool) -> void:
	if _dock_mode:
		return
	if is_instance_valid(_panel):
		_panel.visible = visible


## 暴露给外部（例如别的插件想直接打开某个 json）。
func open_path(path: String) -> void:
	if is_instance_valid(_panel) and _panel.has_method("open_path"):
		_panel.visible = true
		_panel.call("open_path", path)


func _main_screen() -> Control:
	var ei := _editor_interface()
	if ei == null:
		return null
	var screen = ei.call("get_editor_main_screen")
	if screen is Control:
		return screen
	return null


func _editor_interface() -> Object:
	if Engine.has_singleton("EditorInterface"):
		return Engine.get_singleton("EditorInterface")
	if has_method("get_editor_interface"):
		var legacy = call("get_editor_interface")
		if legacy != null:
			return legacy
	return null
