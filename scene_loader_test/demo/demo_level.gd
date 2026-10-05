extends Control

## 演示：通用关卡场景。关卡 A / 关卡 B 共用这份脚本，只是导出参数不同。
## 同时演示 SceneLoader 把转场参数交给新场景：on_scene_entered(params)。

const MENU := "res://scene_loader_test/demo/demo_menu.tscn"

@export var level_title := "关卡"
@export var next_scene := ""
@export var next_label := "下一关"
@export var accent := Color(0.16, 0.35, 0.6, 1.0)

@onready var _backdrop: ColorRect = $Backdrop
@onready var _title_label: Label = %TitleLabel
@onready var _info_label: Label = %InfoLabel
@onready var _preload_bar: ProgressBar = %PreloadBar
@onready var _next_button: Button = %NextButton
@onready var _preload_button: Button = %PreloadButton
@onready var _seamless_button: Button = %SeamlessButton

var _scene_params: Dictionary = {}


## SceneLoader 约定的注入点：切场完成后自动调用
func on_scene_entered(params: Dictionary) -> void:
	_scene_params = params
	if is_node_ready():
		_refresh()


## 自测用：读回收到的转场参数
func get_scene_params() -> Dictionary:
	return _scene_params


func _ready() -> void:
	_backdrop.color = accent
	_title_label.text = level_title
	_next_button.text = "① 读条加载 → %s" % next_label
	_preload_button.text = "② 后台预加载 %s" % next_label
	_seamless_button.text = "③ 无缝切换 → %s" % next_label

	_next_button.pressed.connect(_load_next)
	_preload_button.pressed.connect(_preload_next)
	_seamless_button.pressed.connect(_seamless_next)
	%FadeNextButton.pressed.connect(_fade_next)
	%BackButton.pressed.connect(_back_to_menu)

	SceneLoader.preload_progress.connect(_on_preload_progress)
	SceneLoader.preload_completed.connect(_on_preload_completed)
	_refresh()


# ---------------------------------------------------------------- 按钮
func _load_next() -> void:
	SceneLoader.goto_scene(next_scene, {
		"transition": "loading",
		"title": "载入 %s" % next_label,
		"min_time": 1.0,
		"params": {"from": level_title, "mode": "读条加载"},
	})


func _preload_next() -> void:
	SceneLoader.preload_scene(next_scene)
	_refresh()


func _seamless_next() -> void:
	SceneLoader.goto_scene(next_scene, {
		"seamless": true,
		"params": {"from": level_title, "mode": "无缝切换"},
	})


func _fade_next() -> void:
	SceneLoader.goto_scene(next_scene, {
		"transition": "fade",
		"min_time": 0.5,
		"params": {"from": level_title, "mode": "淡入淡出"},
	})


func _back_to_menu() -> void:
	SceneLoader.goto_scene(MENU, {
		"transition": "loading",
		"title": "返回主菜单",
		"min_time": 0.8,
	})


# ---------------------------------------------------------------- 刷新信息
func _refresh() -> void:
	if not is_node_ready():
		return

	var lines := PackedStringArray()
	lines.append("当前场景：%s" % level_title)

	if next_scene != "":
		if SceneLoader.is_preloaded(next_scene):
			lines.append("%s：已预加载 √（点【③ 无缝切换】瞬时进入）" % next_label)
			_preload_bar.value = 100.0
		elif SceneLoader.is_preloading(next_scene):
			var ratio := SceneLoader.get_preload_progress(next_scene)
			lines.append("%s：后台预加载中… %d%%" % [next_label, roundi(ratio * 100.0)])
			_preload_bar.value = ratio * 100.0
		else:
			lines.append("%s：未预加载" % next_label)
			_preload_bar.value = 0.0

	if not _scene_params.is_empty():
		lines.append("转场参数：%s" % JSON.stringify(_scene_params))

	_info_label.text = "\n".join(lines)


func _on_preload_progress(path: String, ratio: float) -> void:
	if path != next_scene:
		return
	_preload_bar.value = ratio * 100.0
	_refresh()


func _on_preload_completed(path: String, _packed: PackedScene) -> void:
	if path != next_scene:
		return
	_refresh()
