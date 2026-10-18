extends BattleUIBase

## 基础示例场景：完整复用 BattleUIBase 的界面与流程。
##
## 全部界面逻辑都在基类里，这里只：
##   - 用 battle_test.tscn 上导出的 party_ids / enemy_ids 指定编队
##   - 在钩子里补一句开场提示
##
## 想改「谁打谁」，直接改 battle_test.tscn 根节点上的 party_ids / enemy_ids；
## 想加自己的逻辑，重写基类的钩子（on_battle_ui_ready / build_party / build_enemies /
## on_refresh / on_battle_finished）。


func on_battle_ui_ready() -> void:
	log_message("[color=#8f8]基础示例：%s  VS  %s[/color]" % [
		"、".join(party_ids),
		"、".join(enemy_ids),
	])
