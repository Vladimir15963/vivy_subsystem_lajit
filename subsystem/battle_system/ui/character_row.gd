extends Button

## 战斗界面里的单个角色行：显示名字、HP/MP 数值、血条，并可作为“目标”被点击选中。
##
## 由 battle_test.gd 通过 character_row.tscn 动态实例化，数量取决于战斗数据。

signal target_chosen(character)

var character: BattleCharacter = null

@onready var _name_label: Label = $VBox/Header/NameLabel
@onready var _stat_label: Label = $VBox/Header/StatLabel
@onready var _hp_bar: ProgressBar = $VBox/HpBar
@onready var _mp_bar: ProgressBar = $VBox/MpBar

var _selected: bool = false


func _ready() -> void:
	pressed.connect(_on_pressed)


## 绑定一个战斗角色并立即刷新显示。请在 add_child() 之后调用。
func setup(target_character: BattleCharacter) -> void:
	character = target_character
	refresh()


func refresh() -> void:
	if character == null:
		return

	_name_label.text = ("▶ " if _selected else "") + character.display_name
	_stat_label.text = "HP %d/%d    MP %d/%d" % [
		character.hp, character.max_hp, character.mp, character.max_mp
	]

	_hp_bar.max_value = maxi(character.max_hp, 1)
	_hp_bar.value = character.hp
	_mp_bar.max_value = maxi(character.max_mp, 1)
	_mp_bar.value = character.mp

	# 倒下的角色整体变暗，且不能再被选为目标
	modulate = Color(1, 1, 1, 1) if character.is_alive() else Color(0.55, 0.55, 0.55, 1)
	disabled = not character.is_alive()


func set_selected(selected: bool) -> void:
	if _selected == selected:
		return
	_selected = selected
	refresh()


func _on_pressed() -> void:
	if character != null and character.is_alive():
		target_chosen.emit(character)
