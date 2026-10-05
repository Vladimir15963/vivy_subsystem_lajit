class_name BattleCharacter
extends Resource

## 战斗角色：基础数值来自 txt（BattleData），hp / mp 是战斗中的临时状态。

@export var id: StringName = &""
@export var display_name: String = ""
@export var max_hp: int = 1
@export var max_mp: int = 0
@export var attack: int = 1
@export var defense: int = 0
@export var speed: int = 1
@export var skills: Array[Skill] = []

var hp: int = 1
var mp: int = 0


## 把生命 / 魔力恢复到上限，进入战斗时调用。
func reset() -> void:
	hp = max_hp
	mp = max_mp


func is_alive() -> bool:
	return hp > 0


## 受到伤害，返回实际扣除的生命值。
func take_damage(amount: int) -> int:
	var real := clampi(amount, 0, hp)
	hp -= real
	return real


## 恢复生命，返回实际恢复的生命值（不会超过上限）。
func heal(amount: int) -> int:
	var real := clampi(amount, 0, max_hp - hp)
	hp += real
	return real


func skill_by_id(skill_id: StringName) -> Skill:
	for s in skills:
		if s != null and s.id == skill_id:
			return s
	return null


func first_skill_of_kind(kind: Skill.Kind) -> Skill:
	for s in skills:
		if s != null and s.kind == kind:
			return s
	return null


func first_attack_skill() -> Skill:
	return first_skill_of_kind(Skill.Kind.ATTACK)


func first_heal_skill() -> Skill:
	return first_skill_of_kind(Skill.Kind.HEAL)


func hp_ratio() -> float:
	return 0.0 if max_hp <= 0 else float(hp) / float(max_hp)


func describe() -> String:
	return "%s HP %d/%d MP %d/%d" % [display_name, hp, max_hp, mp, max_mp]


func _to_string() -> String:
	return "BattleCharacter(%s %s)" % [id, describe()]
