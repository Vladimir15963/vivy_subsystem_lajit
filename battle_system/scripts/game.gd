class_name GameState
extends Node

## 游戏进程状态机。核心是 progress_status（Progress Status）。
##
## 进入战斗：game.enter_battle(party, enemies) 会把 Progress Status 切到 BATTLE。
## 打断战斗：game.pause_battle() / game.resume_battle() / game.end_battle()
##
## 注意：res://battle_system/scripts/game.gd类名是 GameState(本地静态调试用的)，游戏里把这里的代码强兼到全局单例 Game，
## 于是 /root/Game 指向全局唯一的那个实例。两者名字必须不同，
## 否则 Godot 会报 "Class 'Game' hides an autoload singleton"。

## 游戏进程状态
enum ProgressStatus {
	EXPLORE, ## 探索中（非战斗）
	BATTLE, ## 战斗中
	BATTLE_PAUSED, ## 战斗被暂停
	BATTLE_ENDED, ## 战斗已结束（等待结算 / 返回探索）
}

signal progress_status_changed(previous, current)
signal battle_entered(battle: BattleSystem)
signal battle_exited(reason: String)

## 当前进程状态
var progress_status: ProgressStatus = ProgressStatus.EXPLORE
## 当前战斗实例，非战斗时为 null
var battle: BattleSystem = null


static func status_to_string(status: ProgressStatus) -> String:
	match status:
		ProgressStatus.EXPLORE:
			return "探索"
		ProgressStatus.BATTLE:
			return "战斗中"
		ProgressStatus.BATTLE_PAUSED:
			return "战斗暂停"
		ProgressStatus.BATTLE_ENDED:
			return "战斗结束"
	return "未知"


# ---------------------------------------------------------------- 进入战斗

## 进入战斗：把 Progress Status 变成 BATTLE 并启动一场新的战斗。
## 已经在战斗中时不会重复进入，直接返回当前 battle。
func enter_battle(party: Array, enemies: Array) -> BattleSystem:
	if is_in_battle():
		push_warning("Game: 已经处于战斗状态，忽略重复的 enter_battle。")
		return battle

	battle = BattleSystem.new()
	battle.battle_finished.connect(_on_battle_finished, CONNECT_ONE_SHOT)

	set_progress_status(ProgressStatus.BATTLE)
	battle.start(party, enemies)
	battle_entered.emit(battle)
	return battle


# ---------------------------------------------------------------- 打断战斗

## 暂停战斗。成功时 Progress Status 变成 BATTLE_PAUSED。
func pause_battle() -> bool:
	if progress_status != ProgressStatus.BATTLE or battle == null:
		return false
	if not battle.pause():
		return false
	set_progress_status(ProgressStatus.BATTLE_PAUSED)
	return true


## 从暂停恢复战斗。成功时 Progress Status 回到 BATTLE。
func resume_battle() -> bool:
	if progress_status != ProgressStatus.BATTLE_PAUSED or battle == null:
		return false
	if not battle.resume():
		return false
	set_progress_status(ProgressStatus.BATTLE)
	return true


## 强制结束整场战斗（中断）。Progress Status 会变成 BATTLE_ENDED。
func end_battle(reason: String = "玩家中断战斗") -> bool:
	if not is_in_battle():
		return false
	battle.end_battle(reason)
	return true


## 战斗结束后回到探索状态，并释放 battle 引用。
func leave_battle() -> bool:
	if progress_status != ProgressStatus.BATTLE_ENDED:
		return false
	var reason := battle.end_reason if battle != null else ""
	battle = null
	set_progress_status(ProgressStatus.EXPLORE)
	battle_exited.emit(reason)
	return true


# ---------------------------------------------------------------- 查询

func is_in_battle() -> bool:
	return progress_status == ProgressStatus.BATTLE or progress_status == ProgressStatus.BATTLE_PAUSED


func is_battle_over() -> bool:
	return progress_status == ProgressStatus.BATTLE_ENDED


## current 是否处于“可以行动”的状态（战斗中且未暂停）。
func can_act() -> bool:
	return progress_status == ProgressStatus.BATTLE and battle != null and not battle.finished


func set_progress_status(next: ProgressStatus) -> void:
	if next == progress_status:
		return
	var previous := progress_status
	progress_status = next
	progress_status_changed.emit(previous, next)


func _on_battle_finished(_result: String, _reason: String) -> void:
	set_progress_status(ProgressStatus.BATTLE_ENDED)
