class_name Skill
extends Resource

## 一个技能的数据定义。数值全部来自 txt，见 BattleData。

enum Kind {
	ATTACK, ## 攻击
	HEAL, ## 治疗
}

enum Target {
	ENEMY, ## 单个敌人
	ALLY, ## 单个友方
	ALL_ALLIES, ## 我方全体
	ALL_ENEMIES, ## 敌方全体
}

@export var id: StringName = &""
@export var display_name: String = ""
@export var kind: Kind = Kind.ATTACK
@export var target: Target = Target.ENEMY
@export var power: int = 0
@export var mp_cost: int = 0
@export var description: String = ""


static func kind_to_string(value: Kind) -> String:
	return "攻击" if value == Kind.ATTACK else "治疗"


static func target_to_string(value: Target) -> String:
	match value:
		Target.ENEMY:
			return "enemy"
		Target.ALLY:
			return "ally"
		Target.ALL_ALLIES:
			return "all_allies"
		Target.ALL_ENEMIES:
			return "all_enemies"
	return "enemy"


func _to_string() -> String:
	return "Skill(%s/%s/power=%d/mp=%d)" % [
		id, Skill.kind_to_string(kind), power, mp_cost
	]
