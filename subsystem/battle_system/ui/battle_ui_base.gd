class_name BattleUIBase
extends Control

## 战斗界面基类。
##
## 把一整套战斗界面骨架收在这里，子类只需要声明「谁打谁」，或者重写几个钩子：
##   状态栏 / 回合驱动 / 角色行（HP·MP·血条）/ 技能栏 / 目标选择 /
##   进入·暂停·继续·结束·返回探索 / txt 存档按钮 / 战斗日志
##
## 基类场景：res://subsystem/battle_system/ui/battle_ui_base.tscn
##
## 用法一（推荐，继承场景）：
##   在编辑器里对 battle_ui_base.tscn 右键 → New Inherited Scene，
##   把根节点脚本换成你的子类，在检查器里改 party_ids / enemy_ids 即可。
##
## 用法二（纯脚本）：
##   extends BattleUIBase 并重写 build_party() / build_enemies()。
##
## 注意：基类用「唯一名」取节点（%StatusLabel 等），所以子类在继承场景里
## 调整布局、增删无关节点都不会把引用弄断。

## 目标被玩家改变时发出（点击角色行，或回合开始时自动选定的默认目标）
signal target_changed(character: BattleCharacter)

const ROW_SCENE := preload("res://subsystem/battle_system/ui/character_row.tscn")

@export_group("数据")
## 角色 / 技能 txt 所在目录
@export var data_dir: String = "res://subsystem/battle_system/data"
## 「保存到 txt」写入的目录
@export var save_dir: String = "user://battle_system_test"

@export_group("编队")
## 我方角色 ID（对应 characters.txt 里的段名）
@export var party_ids: PackedStringArray = PackedStringArray(["hero", "priest"])
## 敌方角色 ID
@export var enemy_ids: PackedStringArray = PackedStringArray(["slime", "goblin"])

@export_group("表现")
## 敌方回合的“思考”基准延时（秒）
@export_range(0.0, 10.0, 0.05, "or_greater") var enemy_think_time: float = 0.5
## 在基准延时上下随机浮动的比例：0 = 固定延时，0.4 = ±40%。
## 每次 AI 行动前都会重新摇一次，所以每回合节奏不会完全一致。
@export_range(0.0, 1.0, 0.05) var enemy_think_jitter: float = 0.6

# --- 界面节点：全部用唯一名引用，子类换布局也不断 ---
@onready var status_label: Label = %StatusLabel
@onready var turn_label: Label = %TurnLabel
@onready var party_panel: VBoxContainer = %PartyPanel
@onready var enemy_panel: VBoxContainer = %EnemyPanel
@onready var skill_bar: HBoxContainer = %SkillBar
@onready var enter_button: Button = %EnterButton
@onready var pause_button: Button = %PauseButton
@onready var resume_button: Button = %ResumeButton
@onready var end_button: Button = %EndButton
@onready var leave_button: Button = %LeaveButton
@onready var save_button: Button = %SaveButton
@onready var load_saved_button: Button = %LoadSavedButton
@onready var reload_source_button: Button = %ReloadSourceButton
@onready var log_view: RichTextLabel = %LogView

@export_group("Game 实例")
## false（默认）= 自己 new 一个本地实例，测试场景互不干扰。
## true = 接入全局单例，真实项目用这个。
@export var use_global_game: bool = false
## 全局实例的节点路径。真实项目若把 autoload 取了别的名字，改这里即可。
@export var global_game_path: String = "/root/Game"

## 游戏进程状态机（Progress Status 在它身上）
var game: GameState
## 已从 txt 加载的角色 / 技能表
var characters: Dictionary = {}
var skills: Dictionary = {}
## 当前行动者；敌方回合时是敌方角色，等待推进时是 null
var actor: BattleCharacter = null
## 玩家当前选中的目标
var selected_target: BattleCharacter = null

var _rows: Dictionary = {}
var _skill_owner: BattleCharacter = null
var _skill_buttons: Array = []
## 技能栏是否已经建过一次。初始时 _skill_owner 也是 null，
## 只靠 owner != _skill_owner 判断会漏掉“首次进入且没在战斗”的情况。
var _skills_built: bool = false
var _enemy_timer: Timer
## 专门给“思考延时”用的随机源，避免污染全局 RNG；测试里也可以固定 seed。
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_enemy_timer = Timer.new()
	_enemy_timer.one_shot = true
	_enemy_timer.wait_time = maxf(enemy_think_time, 0.001)
	_enemy_timer.timeout.connect(_on_enemy_timer_timeout)
	add_child(_enemy_timer)

	# 取 Game 实例；取不到时界面会被停用，这里直接返回
	if not _resolve_game():
		return

	game.progress_status_changed.connect(_on_progress_status_changed)
	game.battle_exited.connect(_on_battle_exited)

	if not load_from(data_dir):
		log_message("[color=red]数据加载失败：%s[/color]" % data_dir)
	else:
		log_message("已从 %s 加载：角色 %d 个，技能 %d 个。"
			% [data_dir, characters.size(), skills.size()])

	on_battle_ui_ready()
	refresh()


## 取 Game 实例。
##   use_global_game = true  -> 接入全局单例（真实项目）
##   use_global_game = false -> 本地 new 一个（测试环境，多个测试场景互不干扰）
## 全局实例取不到时不退出进程，而是记日志 + 停用界面，方便定位「忘了挂 autoload」。
func _resolve_game() -> bool:
	if use_global_game:
		game = get_node_or_null(global_game_path)
		if game == null:
			status_label.text = "Progress Status: —"
			turn_label.text = "Game 节点不存在：%s" % global_game_path
			log_message("[color=red]Game 节点不存在（%s），界面已停用。[/color]" % global_game_path)
			_disable_all_buttons()
			return false
		log_message("已接入全局 Game：%s" % global_game_path)
		return true

	# 测试环境：本地建一个，避免多个测试场景抢同一个全局状态
	game = GameState.new()
	game.name = "Game"
	add_child(game)
	return true


func _disable_all_buttons() -> void:
	for button in [enter_button, pause_button, resume_button, end_button,
			leave_button, save_button, load_saved_button, reload_source_button]:
		button.disabled = true


## 没有可用 Game 实例时的统一保护。
func _guard_game() -> bool:
	if game == null:
		log_message("[color=red]没有可用的 Game 实例，操作已忽略。[/color]")
		return false
	return true


# ================================================================
#  子类钩子（按需重写）
# ================================================================

## 界面就绪（按钮已接线、txt 已加载）后调用，适合放子类自己的初始化与提示。
func on_battle_ui_ready() -> void:
	pass


## 构建我方队伍。默认按 party_ids 实例化，可重写做特殊编队。
func build_party() -> Array:
	return instantiate_side(party_ids)


## 构建敌方队伍。默认按 enemy_ids 实例化，可重写做强化敌人等。
func build_enemies() -> Array:
	return instantiate_side(enemy_ids)


## 每次界面刷新后调用，适合追加自定义显示。
func on_refresh() -> void:
	pass


## 一场战斗结算时调用（胜利 / 失败 / 中途结束都会触发）。
func on_battle_finished(result: String, reason: String) -> void:
	pass


# ================================================================
#  给子类用的公开工具
# ================================================================

## 往战斗日志追加一行（支持 BBCode）。
func log_message(text: String) -> void:
	log_view.append_text(text + "\n")



## 取当前战斗实例；没在战斗中返回 null。
func current_battle() -> BattleSystem:
	return game.battle if game != null else null


func is_player_turn() -> bool:
	return actor != null and not is_enemy(actor) and game != null and game.can_act()


## 某个角色是否属于敌方。
func is_enemy(character: BattleCharacter) -> bool:
	var battle := current_battle()
	return battle != null and character != null and battle.enemies.has(character)


## 按 ID 列表从已加载数据实例化一份角色副本。
func instantiate_side(ids: PackedStringArray) -> Array:
	var out: Array = []
	for id in ids:
		var character := BattleData.instantiate_character(id, characters)
		if character != null:
			out.append(character)
	return out


## 重新读取某个目录的 txt 数据（成功返回 true）。
func load_from(dir: String) -> bool:
	var loaded := BattleData.load_all(dir)
	var new_skills: Dictionary = loaded["skills"]
	var new_characters: Dictionary = loaded["characters"]
	if new_skills.is_empty() or new_characters.is_empty():
		return false
	skills = new_skills
	characters = new_characters
	return true


## 刷新整个界面（状态、回合、角色行、技能按钮、按钮可用性）。
func refresh() -> void:
	if game == null:
		return
	status_label.text = "Progress Status: %s" % GameState.status_to_string(game.progress_status)
	turn_label.text = _turn_text()
	_sync_roster()
	_sync_skills()

	var in_battle := game.is_in_battle()
	enter_button.disabled = in_battle
	pause_button.disabled = game.progress_status != GameState.ProgressStatus.BATTLE
	resume_button.disabled = game.progress_status != GameState.ProgressStatus.BATTLE_PAUSED
	end_button.disabled = not in_battle
	leave_button.disabled = not game.is_battle_over()

	on_refresh()


## 推进到下一个行动者（子类在自定义流程里可以手动调用）。
func advance_turn() -> void:
	_queue_next_turn()


## 摇一次 AI 决策前的等待时间：enemy_think_time 上下浮动 enemy_think_jitter 比例。
## jitter 为 0 时返回固定值；基准为 0 时始终返回 0（不会变负）。
func next_think_delay() -> float:
	var base := maxf(enemy_think_time, 0.0)
	var jitter := clampf(enemy_think_jitter, 0.0, 1.0)
	if base <= 0.0 or jitter <= 0.0:
		return base
	var spread := base * jitter
	return maxf(0.0, base + _rng.randf_range(-spread, spread))


# --- 程序化触发：等价于点界面上对应的按钮，方便脚本 / 测试 / 子类驱动 ---

## 按 party_ids / enemy_ids 构建双方并进入战斗。
func start_battle() -> void:
	_on_enter_pressed()


func pause_battle() -> void:
	_on_pause_pressed()


func resume_battle() -> void:
	_on_resume_pressed()


## 立即结束整场战斗。
func end_battle() -> void:
	_on_end_pressed()


## 战斗结束后回到探索状态。
func leave_battle() -> void:
	_on_leave_pressed()

#region
# ================================================================
#  按钮回调（连线写在 battle_ui_base.tscn 的 [connection] 里）
# ================================================================

func _on_enter_pressed() -> void:
	if not _guard_game():
		return
	if game.is_in_battle():
		log_message("[color=orange]已经在战斗中了。[/color]")
		return

	var party := build_party()
	var foes := build_enemies()
	if party.is_empty() or foes.is_empty():
		log_message("[color=red]队伍构建失败，请检查 txt 数据与 party_ids / enemy_ids。[/color]")
		return

	# 进入战斗函数：把选中 Game 的 Progress Status 切换成战斗状态
	var battle := game.enter_battle(party, foes)
	# 接上结算回调，让子类的 on_battle_finished() 钩子被调用
	battle.battle_finished.connect(_on_battle_finished)
	log_message("enter_battle() -> Progress Status = %s" % GameState.status_to_string(game.progress_status))
	_queue_next_turn()


func _on_pause_pressed() -> void:
	if not _guard_game():
		return
	_enemy_timer.stop()
	if game.pause_battle():
		log_message("[color=cyan]已暂停战斗（Progress Status = %s）。[/color]"
			% GameState.status_to_string(game.progress_status))
	else:
		log_message("[color=orange]当前无法暂停。[/color]")
	refresh()


func _on_resume_pressed() -> void:
	if not _guard_game():
		return
	if not game.resume_battle():
		log_message("[color=orange]当前无法继续（战斗未处于暂停状态）。[/color]")
		refresh()
		return
	log_message("[color=cyan]已继续战斗（Progress Status = %s）。[/color]"
		% GameState.status_to_string(game.progress_status))
	if actor == null:
		_queue_next_turn()
	elif is_enemy(actor):
		_start_enemy_timer(next_think_delay())
	refresh()


func _on_end_pressed() -> void:
	if not _guard_game():
		return
	_enemy_timer.stop()
	if game.end_battle("玩家主动结束战斗"):
		log_message("[color=cyan]已结束战斗（Progress Status = %s）。[/color]"
			% GameState.status_to_string(game.progress_status))
	else:
		log_message("[color=orange]当前没有进行中的战斗。[/color]")
	refresh()


func _on_leave_pressed() -> void:
	if not _guard_game():
		return
	if game.leave_battle():
		log_message("[color=cyan]已返回探索状态。[/color]")
	else:
		log_message("[color=orange]战斗还没结束，无法返回探索。[/color]")
	actor = null
	selected_target = null
	refresh()


func _on_save_pressed() -> void:
	var err := BattleData.save_all(characters, skills, save_dir)
	if err == OK:
		log_message("[color=green]已保存角色与技能到 %s[/color]" % save_dir)
	else:
		log_message("[color=red]保存失败，错误码 %d[/color]" % err)


func _on_load_saved_pressed() -> void:
	if load_from(save_dir):
		log_message("[color=green]已从存档 %s 读取数据。[/color]" % save_dir)
	else:
		log_message("[color=orange]存档目录还没有数据，请先点“保存到 txt”。[/color]")
	refresh()


func _on_reload_source_pressed() -> void:
	if load_from(data_dir):
		log_message("[color=green]已重新读取原始数据 %s。[/color]" % data_dir)
	else:
		log_message("[color=red]原始数据读取失败。[/color]")
	refresh()


# ================================================================
#  回合流转
# ================================================================

func _queue_next_turn() -> void:
	actor = null
	selected_target = null
	var battle := current_battle()
	if battle == null or battle.finished or battle.paused:
		refresh()
		return

	actor = battle.next_actor()
	if actor == null:
		refresh()
		return

	# 默认目标取第一个活着的敌人；治疗类技能若目标不合法，由 BattleSystem 兜底
	selected_target = BattleSystem.first_living(battle.opponents_of(actor))
	target_changed.emit(selected_target)
	refresh()

	if is_enemy(actor):
		var delay := next_think_delay()
		log_message("[color=#ffd479]%s 正在行动…（思考 %.2f 秒）[/color]"
			% [actor.display_name, delay])
		_start_enemy_timer(delay)


func _on_enemy_timer_timeout() -> void:
	var battle := current_battle()
	if battle == null or battle.finished or battle.paused or actor == null:
		return
	var plan: Dictionary = battle.choose_ai_action(actor)
	battle.use_skill(actor, plan.get("skill"), plan.get("target"))
	_after_action()


## 用指定的等待时间启动“敌方思考”计时器（0 会被夹成极小正数）。
func _start_enemy_timer(delay: float) -> void:
	_enemy_timer.wait_time = maxf(delay, 0.001)
	_enemy_timer.start()


func _after_action() -> void:
	var battle := current_battle()
	if battle == null or battle.finished:
		refresh()
		return
	_queue_next_turn()


func _on_skill_button_pressed(skill: Skill) -> void:
	if not _player_turn_ready():
		return

	var result: Dictionary = current_battle().use_skill(actor, skill, selected_target)
	if not result["ok"]:
		log_message("[color=orange]行动失败：%s[/color]" % result["reason"])
		refresh()
		return

	# 目标被自动修正时明确提示（例如选中了敌人却施放治疗）
	var used: BattleCharacter = result["results"][0]["target"]
	if used != selected_target:
		log_message("[color=#9cdcfe]目标自动调整为：%s[/color]" % used.display_name)

	_after_action()


func _on_row_target_chosen(character: BattleCharacter) -> void:
	if current_battle() == null:
		return
	selected_target = character
	log_message("已选中目标：%s" % character.display_name)
	target_changed.emit(character)
	refresh()


func _player_turn_ready() -> bool:
	var battle := current_battle()
	if battle == null:
		log_message("[color=orange]还没有进入战斗，请先点“进入战斗”。[/color]")
		return false
	if game.progress_status == GameState.ProgressStatus.BATTLE_PAUSED:
		log_message("[color=orange]战斗已暂停，请先点“继续战斗”。[/color]")
		return false
	if battle.finished:
		log_message("[color=orange]战斗已经结束。[/color]")
		return false
	if actor == null:
		log_message("[color=orange]当前没有可以行动的玩家角色。[/color]")
		return false
	if is_enemy(actor):
		log_message("[color=orange]现在是敌方回合，请等待。[/color]")
		return false
	return true


# ================================================================
#  状态同步
# ================================================================

func _on_progress_status_changed(previous, current) -> void:
	log_message("[color=#9cdcfe]Progress Status: %s -> %s[/color]"
		% [GameState.status_to_string(previous), GameState.status_to_string(current)])


func _on_battle_exited(reason: String) -> void:
	if not reason.is_empty():
		log_message("战斗退出原因：%s" % reason)


func _on_battle_finished(result: String, reason: String) -> void:
	on_battle_finished(result, reason)


## 让角色行与当前战斗同步：复用已有行，只为新角色创建、为消失的角色回收。
func _sync_roster() -> void:
	var wanted: Array = []
	var battle := current_battle()
	if battle != null:
		wanted.append_array(battle.party)
		wanted.append_array(battle.enemies)

	for character in _rows.keys():
		if not wanted.has(character):
			_rows[character].queue_free()
			_rows.erase(character)

	for character in wanted:
		var row = _rows.get(character)
		if row == null:
			row = ROW_SCENE.instantiate()
			(enemy_panel if is_enemy(character) else party_panel).add_child(row)
			row.setup(character)
			row.target_chosen.connect(_on_row_target_chosen)
			_rows[character] = row
		else:
			row.refresh()
		row.set_selected(character == selected_target)


## 让技能按钮与当前行动者同步：行动者换了才重建按钮，否则只更新可用状态。
func _sync_skills() -> void:
	var owner: BattleCharacter = null
	var battle := current_battle()
	if battle != null and not battle.finished:
		owner = actor if actor != null else battle.current_actor()

	if not _skills_built or owner != _skill_owner:
		_skills_built = true
		_skill_owner = owner
		_skill_buttons.clear()
		for child in skill_bar.get_children():
			skill_bar.remove_child(child)
			child.queue_free()
		if owner == null:
			var hint := Label.new()
			hint.text = "（尚未进入战斗）"
			skill_bar.add_child(hint)
		else:
			for skill in owner.skills:
				if skill == null:
					continue
				var button := Button.new()
				button.text = "%s（MP %d）" % [skill.display_name, skill.mp_cost]
				button.tooltip_text = "%s\n威力 %d · 消耗 MP %d\n目标：%s\n%s" % [
					skill.display_name,
					skill.power,
					skill.mp_cost,
					Skill.target_to_string(skill.target),
					skill.description,
				]
				button.pressed.connect(_on_skill_button_pressed.bind(skill))
				skill_bar.add_child(button)
				_skill_buttons.append({"button": button, "skill": skill})

	if owner == null:
		return

	# 只有轮到我方且未暂停时才能点，MP 不够的技能置灰但保留可见
	var usable := not is_enemy(owner) and not battle.paused
	for entry in _skill_buttons:
		var skill: Skill = entry["skill"]
		entry["button"].disabled = not usable or owner.mp < skill.mp_cost


func _turn_text() -> String:
	var battle := current_battle()
	if battle == null:
		return "当前回合：—"
	if battle.finished:
		return "第 %d 回合 · 战斗结束（%s：%s）" % [
			battle.round_index, battle.result, battle.end_reason
		]
	if battle.paused:
		return "第 %d 回合 · 已暂停" % battle.round_index
	if actor == null:
		return "第 %d 回合 · 等待推进" % battle.round_index

	var target_text := "无"
	if selected_target != null:
		target_text = selected_target.display_name
	return "第 %d 回合 · 行动者：%s（%s） · 目标：%s" % [
		battle.round_index,
		actor.display_name,
		"我方" if not is_enemy(actor) else "敌方",
		target_text,
	]
