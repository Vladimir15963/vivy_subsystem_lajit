extends BattleUIBase

## 变体示例：演示子类如何重写基类钩子。
##
## 与 battle_test.tscn 共用同一套界面（继承同一个基类场景），只改两件事：
##   1. battle_variant_hard.tscn 上导出的编队不同（单人 VS 两只强化敌人）
##   2. 这里重写 build_enemies() 把敌人整体强化，并接上 on_battle_finished()

const ENEMY_HP_SCALE := 2
const ENEMY_ATK_SCALE := 2


func on_battle_ui_ready() -> void:
	log_message("[color=#f88]困难变体：我方只有 1 人，敌人生命 x%d、攻击 x%d[/color]"
		% [ENEMY_HP_SCALE, ENEMY_ATK_SCALE])


## 重写敌人构建：先按 ID 实例化，再整体强化。
func build_enemies() -> Array:
	var foes := super()
	for character in foes:
		character.max_hp *= ENEMY_HP_SCALE
		character.attack *= ENEMY_ATK_SCALE
		character.reset()
	return foes


## 重写结算回调：把结果显著地写进日志。
func on_battle_finished(result: String, reason: String) -> void:
	match result:
		BattleSystem.RESULT_VICTORY:
			log_message("[color=#8f8]>>> 通关！%s[/color]" % reason)
		BattleSystem.RESULT_DEFEAT:
			log_message("[color=#f88]>>> 全灭……%s[/color]" % reason)
		_:
			log_message("[color=orange]>>> 战斗被中断：%s[/color]" % reason)
