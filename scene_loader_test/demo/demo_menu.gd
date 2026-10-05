extends Control

## 演示：主菜单。
## 四个按钮分别演示 读条转场 / 后台预加载 / 无缝切换 / 淡入淡出转场。

const LEVEL_A := "res://scene_loader_test/demo/level_a.tscn"
const LEVEL_B := "res://scene_loader_test/demo/level_b.tscn"

@onready var _status_label: Label = %StatusLabel
@onready var _preload_bar: ProgressBar = %PreloadBar
@onready var _preload_button: Button = %PreloadButton
@onready var _seamless_button: Button = %SeamlessButton


func _ready() -> void:
	%LoadAButton.pressed.connect(_load_a)
	_preload_button.pressed.connect(_preload_b)
	_seamless_button.pressed.connect(_seamless_b)
	%FadeBButton.pressed.connect(_fade_b)

	# 监听全局预加载进度（切场景后本节点会被释放，连接会自动断开）
	SceneLoader.preload_progress.connect(_on_preload_progress)
	SceneLoader.preload_completed.connect(_on_preload_completed)
	SceneLoader.preload_failed.connect(_on_preload_failed)

	_status_label.text = "就绪。SceneLoader 是 autoload 全局单例，任何场景里都能直接用。"
	_refresh()


## 进入场景时先按当前缓存状态刷新一次（可能上一轮已经预加载过了）
func _refresh() -> void:
	if SceneLoader.is_preloaded(LEVEL_B):
		_preload_bar.value = 100.0
		_status_label.text = "关卡 B 已在预加载缓存里 √ —— 点【③ 无缝切换】可瞬时进入。"
	elif SceneLoader.is_preloading(LEVEL_B):
		_preload_bar.value = SceneLoader.get_preload_progress(LEVEL_B) * 100.0
		_status_label.text = "后台预加载关卡 B… %d%%" % roundi(_preload_bar.value)
	else:
		_preload_bar.value = 0.0


# ---------------------------------------------------------------- 演示 1：读条转场
func _load_a() -> void:
	SceneLoader.goto_scene(LEVEL_A, {
		"transition": "loading",
		"title": "载入关卡 A",
		"min_time": 1.0,
		"params": {"from": "主菜单"},
	})


# ---------------------------------------------------------------- 演示 2：后台预加载
func _preload_b() -> void:
	var err := SceneLoader.preload_scene(LEVEL_B)
	if err != OK:
		_status_label.text = "预加载请求失败：%d" % err
		return
	if SceneLoader.is_preloaded(LEVEL_B):
		_refresh()
	else:
		_status_label.text = "正在后台预加载关卡 B…（此时主菜单照常可以点击、播放动画）"


# ---------------------------------------------------------------- 演示 3：无缝切换
func _seamless_b() -> void:
	if not SceneLoader.is_preloaded(LEVEL_B):
		_status_label.text = "关卡 B 还没预加载完，请先点【② 后台预加载】。"
		return
	SceneLoader.goto_scene(LEVEL_B, {
		"seamless": true,
		"params": {"from": "主菜单", "mode": "无缝切换"},
	})


# ---------------------------------------------------------------- 演示 4：淡入淡出转场
func _fade_b() -> void:
	SceneLoader.goto_scene(LEVEL_B, {
		"transition": "fade",
		"min_time": 0.5,
		"params": {"from": "主菜单", "mode": "淡入淡出"},
	})


# ---------------------------------------------------------------- 预加载回调
func _on_preload_progress(path: String, ratio: float) -> void:
	if path != LEVEL_B:
		return
	_preload_bar.value = ratio * 100.0
	_status_label.text = "后台预加载关卡 B… %d%%" % roundi(ratio * 100.0)


func _on_preload_completed(path: String, _packed: PackedScene) -> void:
	if path != LEVEL_B:
		return
	_preload_bar.value = 100.0
	_status_label.text = "关卡 B 预加载完成 √ —— 现在点【③ 无缝切换】可以瞬时进入。"


func _on_preload_failed(path: String, error: int) -> void:
	if path != LEVEL_B:
		return
	_status_label.text = "关卡 B 预加载失败：%d" % error
