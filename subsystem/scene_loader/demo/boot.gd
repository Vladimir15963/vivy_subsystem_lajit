extends Control

## 启动引导场景（项目主场景）。
## 它自己什么都不做，只是把“第一个真正的游戏场景”交给 SceneLoader 读条加载进来，
## 这样玩家进游戏看到的第一眼就是读条界面，而不是黑屏或半成品场景。

const FIRST_SCENE := "res://subsystem/scene_loader/demo/demo_menu.tscn"

## 也可以在这里顺手预加载后面一定会用到的场景
const ALSO_PRELOAD: Array[String] = [
	"res://subsystem/scene_loader/demo/level_a.tscn",
]


func _ready() -> void:
	for path in ALSO_PRELOAD:
		SceneLoader.preload_scene(path)
	SceneLoader.boot_to(FIRST_SCENE)
