extends BattleUIBase

## 全局单例模式示例。
##
## 与 battle_test 的区别只有一处：battle_global.tscn 上把 use_global_game 打开，
## 于是基类不再自己 new 一个 Game，而是接入 project.godot 里注册的 autoload：
##
##     [autoload]
##     Game="*res://battle_system/scripts/game.gd"
##
## 好处是 Progress Status / 当前战斗都挂在全局实例上，切场景不会丢；
## 代价是多个战斗界面会共享同一份状态，所以测试场景要用默认的本地模式。


func on_battle_ui_ready() -> void:
	log_message("[color=#9cf]全局单例模式：状态挂在 %s 上，切换场景不会丢。[/color]"
		% global_game_path)
