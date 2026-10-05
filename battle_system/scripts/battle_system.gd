class_name BattleSystem
extends RefCounted

## 极其简单的回合制战斗系统。
##
## 用法：
##   var battle := BattleSystem.new()
##   battle.start(party, enemies)
##   var actor := battle.next_actor()          # 取出下一个行动者
##   battle.use_skill(actor, skill, target)    # 行动
##   battle.next_actor()                       # 下一位……
##
## 打断：
##   battle.pause() / battle.resume()  暂停与继续
##   battle.end_battle(reason)         立即结束整场战斗

signal battle_started(party: Array, enemies: Array)
signal round_started(round_index: int)
signal turn_started(actor: BattleCharacter)
signal action_performed(actor: BattleCharacter, skill: Skill, targets: Array, results: Array)
signal battle_paused()
signal battle_resumed()
signal battle_finished(result: String, reason: String)
signal log_message(text: String)

const RESULT_VICTORY := "victory"
const RESULT_DEFEAT := "defeat"
const RESULT_ENDED := "ended"

## 我方队伍
var party: Array[BattleCharacter] = []
## 敌方队伍
var enemies: Array[BattleCharacter] = []
var round_index: int = 0
## 被打断（暂停）时为 true，此时不允许任何行动
var paused: bool = false
var finished: bool = false
var result: String = ""
var end_reason: String = ""

var _order: Array[BattleCharacter] = []
var _current: BattleCharacter = null
var _log: Array[String] = []


# ---------------------------------------------------------------- 开始 / 结束

## 开始一场战斗：重置双方状态、清空回合、发出 battle_started。
func start(new_party: Array, new_enemies: Array) -> void:
	party.assign(new_party)
	enemies.assign(new_enemies)
	for c in party:
		c.reset()
	for c in enemies:
		c.reset()
	round_index = 0
	paused = false
	finished = false
	result = ""
	end_reason = ""
	_current = null
	_order.clear()
	_log.clear()
	_log_line("战斗开始：%s  VS  %s" % [_side_names(party), _side_names(enemies)])
	battle_started.emit(party, enemies)
	_begin_round()


## 结束整场战斗（打断）。result 为 RESULT_ENDED，仅当战斗已经结束过时返回 false。
func end_battle(reason: String = "玩家中断战斗") -> bool:
	if finished:
		return false
	paused = false
	_finish(RESULT_ENDED, reason)
	return true


## 暂停战斗（打断），暂停期间 use_skill / next_actor 都会拒绝执行。
func pause() -> bool:
	if finished or paused:
		return false
	paused = true
	_log_line("战斗暂停。")
	battle_paused.emit()
	return true


## 从暂停中恢复。
func resume() -> bool:
	if finished or not paused:
		return false
	paused = false
	_log_line("战斗继续。")
	battle_resumed.emit()
	return true


# ---------------------------------------------------------------- 回合流转

## 取出下一个可行动的角色；当前回合的敌人全灭 / 我方全灭时返回 null 并结算。
## 暂停中或战斗已结束时同样返回 null。
func next_actor() -> BattleCharacter:
	if finished or paused:
		return null
	if _check_battle_end():
		return null
	_current = _pop_next()
	if _current == null:
		_begin_round()
		if _check_battle_end():
			return null
		_current = _pop_next()
	if _current == null:
		_check_battle_end()
		return null
	turn_started.emit(_current)
	return _current


func current_actor() -> BattleCharacter:
	return _current


# ---------------------------------------------------------------- 行动

## 让 actor 对 target 使用 skill。target 为 null 时自动选第一个合法目标。
## 返回 {ok, reason, results}，results 是每个目标的效果明细。
func use_skill(
	actor: BattleCharacter, skill: Skill, target: BattleCharacter = null
) -> Dictionary:
	var out := {"ok": false, "reason": "", "results": []}
	if finished:
		out["reason"] = "战斗已经结束"
		return out
	if paused:
		out["reason"] = "战斗已暂停，无法行动"
		return out
	if actor == null or not actor.is_alive():
		out["reason"] = "行动者不存在或已倒下"
		return out
	if skill == null:
		out["reason"] = "技能不存在"
		return out
	if actor.mp < skill.mp_cost:
		out["reason"] = "魔力不足（需要 %d，剩余 %d）" % [skill.mp_cost, actor.mp]
		return out

	var targets := resolve_targets(actor, skill, target)
	if targets.is_empty():
		out["reason"] = "没有合法的目标"
		return out

	actor.mp -= skill.mp_cost
	var results: Array = []
	for t in targets:
		if skill.kind == Skill.Kind.HEAL:
			# 治疗量 = 技能威力 + 攻击力的一半（向下取整）
			@warning_ignore("integer_division")
			var heal_amount := skill.power + actor.attack / 2
			var healed := t.heal(heal_amount)
			results.append({"target": t, "type": "heal", "amount": healed})
			_log_line(
				"%s 使用「%s」，%s 恢复 %d 点生命（%d/%d）"
				% [actor.display_name, skill.display_name, t.display_name, healed, t.hp, t.max_hp]
			)
		else:
			var damage := t.take_damage(max(1, skill.power + actor.attack - t.defense))
			results.append({"target": t, "type": "damage", "amount": damage})
			var suffix := "（倒下）" if not t.is_alive() else ""
			_log_line(
				"%s 使用「%s」，%s 受到 %d 点伤害（%d/%d）%s"
				% [
					actor.display_name,
					skill.display_name,
					t.display_name,
					damage,
					t.hp,
					t.max_hp,
					suffix,
				]
			)
	out["ok"] = true
	out["results"] = results
	action_performed.emit(actor, skill, targets, results)
	_check_battle_end()
	return out


## 把技能的目标解析成具体的角色列表。
## target 为空、已倒下、或站错了阵营（治疗指向敌人 / 攻击指向队友）时，都会自动换成合法目标。
func resolve_targets(
	actor: BattleCharacter, skill: Skill, target: BattleCharacter
) -> Array[BattleCharacter]:
	var out: Array[BattleCharacter] = []
	match skill.target:
		Skill.Target.ALL_ALLIES:
			out = living(allies_of(actor))
		Skill.Target.ALL_ENEMIES:
			out = living(opponents_of(actor))
		Skill.Target.ALLY:
			var ally := target
			if not _is_pickable(ally, allies_of(actor)):
				# 未指定目标时自动选择伤势最重的友方（交互界面的“治疗”按钮依赖这个默认行为）
				ally = weakest_living(allies_of(actor))
			if ally != null:
				out.append(ally)
		_:
			var enemy := target
			if not _is_pickable(enemy, opponents_of(actor)):
				enemy = first_living(opponents_of(actor))
			if enemy != null:
				out.append(enemy)
	return out


## 候选目标是否可以被选中：存在、活着、且确实属于期望的那一阵营。
static func _is_pickable(candidate: BattleCharacter, side: Array[BattleCharacter]) -> bool:
	return candidate != null and candidate.is_alive() and side.has(candidate)


## 敌方（AI）的简单决策：血量低于一半就治疗，否则攻击。
func choose_ai_action(actor: BattleCharacter) -> Dictionary:
	if actor == null:
		return {"skill": null, "target": null}
	var heal_skill := actor.first_heal_skill()
	var weakest := weakest_living(allies_of(actor))
	if (
		heal_skill != null
		and weakest != null
		and actor.mp >= heal_skill.mp_cost
		and weakest.hp_ratio() < 0.5
	):
		return {"skill": heal_skill, "target": weakest}
	return {"skill": actor.first_attack_skill(), "target": first_living(opponents_of(actor))}


# ---------------------------------------------------------------- 查询工具

## actor 的友方（包含自己）
func allies_of(actor: BattleCharacter) -> Array[BattleCharacter]:
	return party if party.has(actor) else enemies


## actor 的敌方
func opponents_of(actor: BattleCharacter) -> Array[BattleCharacter]:
	return enemies if party.has(actor) else party


func is_player_side(actor: BattleCharacter) -> bool:
	return party.has(actor)


static func living(source: Array[BattleCharacter]) -> Array[BattleCharacter]:
	var out: Array[BattleCharacter] = []
	for c in source:
		if c != null and c.is_alive():
			out.append(c)
	return out


static func first_living(source: Array[BattleCharacter]) -> BattleCharacter:
	for c in source:
		if c != null and c.is_alive():
			return c
	return null


static func weakest_living(source: Array[BattleCharacter]) -> BattleCharacter:
	var weakest: BattleCharacter = null
	for c in source:
		if c == null or not c.is_alive():
			continue
		if weakest == null or c.hp_ratio() < weakest.hp_ratio():
			weakest = c
	return weakest


func log_text() -> String:
	return "\n".join(_log)


# ---------------------------------------------------------------- 内部

func _begin_round() -> void:
	round_index += 1
	_order = _sorted_by_speed()
	_log_line("—— 第 %d 回合 ——" % round_index)
	round_started.emit(round_index)


func _sorted_by_speed() -> Array[BattleCharacter]:
	var all: Array[BattleCharacter] = []
	all.append_array(party)
	all.append_array(enemies)
	all.sort_custom(func(a, b):
		if a.speed == b.speed:
			return String(a.id) < String(b.id)
		return a.speed > b.speed
	)
	return all


func _pop_next() -> BattleCharacter:
	while not _order.is_empty():
		var c: BattleCharacter = _order.pop_front()
		if c != null and c.is_alive():
			return c
	return null


## 检查胜负；已结算返回 true。
func _check_battle_end() -> bool:
	if finished:
		return true
	if living(enemies).is_empty():
		_finish(RESULT_VICTORY, "敌方全灭")
		return true
	if living(party).is_empty():
		_finish(RESULT_DEFEAT, "我方全灭")
		return true
	return false


func _finish(battle_result: String, reason: String) -> void:
	if finished:
		return
	finished = true
	result = battle_result
	end_reason = reason
	_current = null
	_log_line("战斗结束（%s）：%s" % [battle_result, reason])
	battle_finished.emit(battle_result, reason)


func _side_names(side: Array[BattleCharacter]) -> String:
	var names := PackedStringArray()
	for c in side:
		names.append(c.display_name)
	return "、".join(names)


func _log_line(text: String) -> void:
	_log.append(text)
	if _log.size() > 300:
		_log.pop_front()
	log_message.emit(text)
