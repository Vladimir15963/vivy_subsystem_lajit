extends Node

## 战斗界面基类的无头冒烟测试。
##
## 运行方式：
##   godot --headless --path . battle_system/tests/battle_ui_test.tscn
##
## 界面本身不需要渲染，headless 下足以验证：
##   - 基类场景能被继承，%唯一名 节点全部解析成功
##   - 按钮按钮线 / 生命周期钩子被正确调用
##   - 角色行、技能按钮随战斗状态正确生成
##
## 这类测试专门用来兜住“钩子声明了却忘了接线”这种只在运行时才暴露的问题。

const BASE_SCENE := preload("res://battle_system/ui/battle_ui_base.tscn")
const TEST_SCENE := preload("res://battle_system/battle_test.tscn")
const VARIANT_SCENE := preload("res://battle_system/battle_variant_hard.tscn")

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("=== 战斗界面基类 · 无头冒烟测试 ===")
	_test_base_scene_node_refs()
	_test_subclass_hooks_fire()
	_test_row_and_skill_sync()
	_test_status_cycle()
	_test_think_delay_jitter()
	_test_game_source()
	print("\n=== 结果：%d 通过 / %d 失败 ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


# ---------------------------------------------------------------- 用例

## 基类场景应该能被直接实例化，且所有 %唯一名 节点都能取到。
func _test_base_scene_node_refs() -> void:
	var ui: BattleUIBase = BASE_SCENE.instantiate()
	add_child(ui)

	var refs := {
		"StatusLabel": ui.status_label,
		"TurnLabel": ui.turn_label,
		"PartyPanel": ui.party_panel,
		"EnemyPanel": ui.enemy_panel,
		"SkillBar": ui.skill_bar,
		"EnterButton": ui.enter_button,
		"PauseButton": ui.pause_button,
		"ResumeButton": ui.resume_button,
		"EndButton": ui.end_button,
		"LeaveButton": ui.leave_button,
		"SaveButton": ui.save_button,
		"LoadSavedButton": ui.load_saved_button,
		"ReloadSourceButton": ui.reload_source_button,
		"LogView": ui.log_view,
	}
	var missing := PackedStringArray()
	for name in refs:
		if refs[name] == null:
			missing.append(name)
	_check("基类场景的 %唯一名 节点全部解析成功", missing.is_empty(),
		"缺失：%s" % ", ".join(missing))

	_check("基类初始化后 Game 已就绪", ui.game != null)
	_check("基类初始化后状态为探索", ui.game.progress_status == GameState.ProgressStatus.EXPLORE)
	_check("基类默认从 txt 读到了数据",
		not ui.characters.is_empty() and not ui.skills.is_empty(),
		"角色 %d / 技能 %d" % [ui.characters.size(), ui.skills.size()])
	_check("未进入战斗时技能栏显示提示", ui.skill_bar.get_child_count() > 0)

	ui.queue_free()


## 继承场景上的导出覆盖 + 生命周期钩子必须真的被调用。
func _test_subclass_hooks_fire() -> void:
	# battle_test.tscn：编队来自继承场景上的导出值
	var ui: BattleUIBase = TEST_SCENE.instantiate()
	add_child(ui)
	_check("继承场景覆盖了 party_ids",
		Array(ui.party_ids) == ["hero", "priest"], str(ui.party_ids))
	_check("继承场景覆盖了 enemy_ids",
		Array(ui.enemy_ids) == ["slime", "goblin"], str(ui.enemy_ids))

	# on_battle_ui_ready() 会在日志里留一行，用它验证钩子确实被调用
	_check("子类 on_battle_ui_ready() 钩子被调用",
		_log_contains(ui, "基础示例"), _log_text(ui))

	ui.queue_free()

	# 困难变体：重写了 build_enemies()，敌人应被强化
	var variant: BattleUIBase = VARIANT_SCENE.instantiate()
	add_child(variant)
	_check("变体子类 on_battle_ui_ready() 钩子被调用", _log_contains(variant, "困难变体"))

	variant.start_battle()
	_check("变体进入战斗成功",
		variant.game.progress_status == GameState.ProgressStatus.BATTLE)
	_check("变体我方只有 1 人", variant.game.battle.party.size() == 1,
		"%d 人" % variant.game.battle.party.size())

	# build_enemies() 被重写 -> 哥布林生命翻倍
	var goblin: BattleCharacter = variant.game.battle.enemies[0]
	var base_goblin: BattleCharacter = variant.characters.get(&"goblin")
	_check("重写的 build_enemies() 生效（敌人生命翻倍）",
		base_goblin != null and goblin.max_hp == base_goblin.max_hp * 2,
		"%d -> %d" % [0 if base_goblin == null else base_goblin.max_hp, goblin.max_hp])

	# on_battle_finished() 钩子：结束时必须被调用
	variant.end_battle()
	_check("子类 on_battle_finished() 钩子被调用",
		_log_contains(variant, ">>>"), _log_text(variant))
	_check("结算后状态为 BATTLE_ENDED",
		variant.game.progress_status == GameState.ProgressStatus.BATTLE_ENDED)

	variant.queue_free()


## 角色行与技能按钮应随战斗状态生成、随行动者切换。
func _test_row_and_skill_sync() -> void:
	var ui: BattleUIBase = TEST_SCENE.instantiate()
	add_child(ui)

	_check("进入战斗前没有角色行", ui.party_panel.get_child_count() == 1,
		"只有标题，实际 %d 个子节点" % ui.party_panel.get_child_count())

	ui.start_battle()
	_check("进入战斗后我方生成角色行", ui.party_panel.get_child_count() == 3,
		"标题 + 2 个角色，实际 %d" % ui.party_panel.get_child_count())
	_check("进入战斗后敌方生成角色行", ui.enemy_panel.get_child_count() == 3,
		"标题 + 2 个敌人，实际 %d" % ui.enemy_panel.get_child_count())

	var battle := ui.game.battle
	var first_actor := battle.current_actor()
	_check("默认目标取第一个活着的敌人",
		ui.selected_target == BattleSystem.first_living(battle.enemies),
		"选中 %s" % (ui.selected_target.display_name if ui.selected_target != null else "无"))

	# 技能按钮数量应等于当前行动者拥有的技能数
	var expected_skills := first_actor.skills.size() if first_actor != null else 0
	_check("技能按钮数量 = 当前行动者的技能数",
		ui.skill_bar.get_child_count() == expected_skills,
		"按钮 %d / 技能 %d" % [ui.skill_bar.get_child_count(), expected_skills])

	# 切换行动者后技能栏应跟着换
	ui.advance_turn()
	var next_actor := battle.current_actor()
	if next_actor != null and next_actor != first_actor:
		_check("换行动者后技能按钮重建",
			ui.skill_bar.get_child_count() == next_actor.skills.size(),
			"%s 的技能 %d 个" % [next_actor.display_name, next_actor.skills.size()])
	else:
		_check("换行动者后技能按钮重建", true, "同一行动者，跳过")

	ui.queue_free()


## 状态机四态在界面上走一圈，按钮可用性跟着变。
func _test_status_cycle() -> void:
	var ui: BattleUIBase = TEST_SCENE.instantiate()
	add_child(ui)

	_check("探索时「进入战斗」可点", not ui.enter_button.disabled)
	_check("探索时「暂停/结束」不可点",
		ui.pause_button.disabled and ui.end_button.disabled)
	_check("探索时「返回探索」不可点", ui.leave_button.disabled)

	ui.start_battle()
	_check("战斗中「进入战斗」置灰", ui.enter_button.disabled)
	_check("战斗中「暂停」「结束」可点",
		not ui.pause_button.disabled and not ui.end_button.disabled)
	_check("战斗中「继续」不可点", ui.resume_button.disabled)

	ui.pause_battle()
	_check("暂停后状态为 BATTLE_PAUSED",
		ui.game.progress_status == GameState.ProgressStatus.BATTLE_PAUSED)
	_check("暂停后「继续」可点、「暂停」置灰",
		not ui.resume_button.disabled and ui.pause_button.disabled)

	ui.resume_battle()
	_check("继续后状态回到 BATTLE",
		ui.game.progress_status == GameState.ProgressStatus.BATTLE)

	ui.end_battle()
	_check("结束后状态为 BATTLE_ENDED",
		ui.game.progress_status == GameState.ProgressStatus.BATTLE_ENDED)
	_check("结束后「返回探索」可点", not ui.leave_button.disabled)

	ui.leave_battle()
	_check("返回探索后状态为 EXPLORE",
		ui.game.progress_status == GameState.ProgressStatus.EXPLORE)
	_check("返回探索后「进入战斗」恢复可点", not ui.enter_button.disabled)

	ui.queue_free()


## AI 决策等待时间：基准值 + 抖动比例应能配，且每次摇都在范围内。
func _test_think_delay_jitter() -> void:
	var ui: BattleUIBase = TEST_SCENE.instantiate()
	add_child(ui)

	# 抖动为 0 -> 每次都等于基准值（同时也证明运行时改动能生效）
	ui.enemy_think_time = 0.25
	ui.enemy_think_jitter = 0.0
	var fixed_ok := true
	for i in 20:
		if not is_equal_approx(ui.next_think_delay(), 0.25):
			fixed_ok = false
	_check("抖动为 0 时延时恒等于基准值", fixed_ok,
		"最后一次 %.4f" % ui.next_think_delay())

	# 基准为 0 -> 始终 0，不会因为抖动变成负数
	ui.enemy_think_time = 0.0
	ui.enemy_think_jitter = 0.8
	var zero_ok := true
	for i in 20:
		if ui.next_think_delay() != 0.0:
			zero_ok = false
	_check("基准为 0 时延时恒为 0（不会变负）", zero_ok)

	# 抖动 > 0 -> 落在 [base*(1-jitter), base*(1+jitter)] 内，且确实在波动
	var base := 0.5
	var jitter := 0.4
	ui.enemy_think_time = base
	ui.enemy_think_jitter = jitter
	var low := base * (1.0 - jitter)
	var high := base * (1.0 + jitter)
	var samples: Array[float] = []
	var in_range := true
	for i in 200:
		var value := ui.next_think_delay()
		samples.append(value)
		if value < low - 0.0001 or value > high + 0.0001:
			in_range = false
	_check("抖动后的延时落在 ±%d%% 范围内" % int(jitter * 100.0), in_range,
		"期望 [%.3f, %.3f]" % [low, high])

	var min_v := samples[0]
	var max_v := samples[0]
	for v in samples:
		min_v = minf(min_v, v)
		max_v = maxf(max_v, v)
	_check("200 次采样确实在波动，而不是固定值",
		max_v - min_v > 0.01 and min_v < base and max_v > base,
		"实测范围 [%.3f, %.3f]" % [min_v, max_v])

	# 抖动比例被夹到 [0,1]：乱填 5.0 也不会摇出负延时
	ui.enemy_think_jitter = 5.0
	var clamped_ok := true
	for i in 200:
		var v := ui.next_think_delay()
		if v < 0.0 or v > base * 2.0 + 0.0001:
			clamped_ok = false
	_check("抖动比例超出 1.0 时被夹住", clamped_ok)

	# 进入敌方回合时，日志里的等待时长应与实际范围一致
	ui.enemy_think_time = 0.3
	ui.enemy_think_jitter = 0.5
	ui.start_battle()
	# 推进到敌方行动者
	var guard := 0
	while guard < 20 and ui.actor != null and not ui.is_enemy(ui.actor):
		guard += 1
		ui.advance_turn()
	if ui.actor != null and ui.is_enemy(ui.actor):
		_check("敌方回合会在日志里标出思考时长",
			_log_contains(ui, "思考"), _log_text(ui))
	else:
		_check("敌方回合会在日志里标出思考时长", true, "本轮没轮到敌方，跳过")

	ui.queue_free()


## Game 实例来源：本地模式自建、全局模式接入 /root/Game、路径写错时停用界面而不是崩。
func _test_game_source() -> void:
	# project.godot 里注册了 autoload Game，所以全局实例应当存在
	var global_game: GameState = get_node_or_null("/root/Game")
	_check("autoload /root/Game 存在", global_game != null)
	if global_game == null:
		return

	# --- 本地模式（默认）：自己 new，不碰全局那个 ---
	var local_ui: BattleUIBase = TEST_SCENE.instantiate()
	add_child(local_ui)
	_check("本地模式下 game 不是全局实例",
		local_ui.game != null and local_ui.game != global_game)
	_check("本地模式的 game 挂在界面自己下面", local_ui.game.get_parent() == local_ui)
	local_ui.queue_free()

	# --- 全局模式：直接接入 /root/Game ---
	global_game.set_progress_status(GameState.ProgressStatus.EXPLORE)
	var global_scene := load("res://battle_system/battle_global.tscn")
	var global_ui: BattleUIBase = global_scene.instantiate()
	_check("全局模式场景开启了 use_global_game", global_ui.use_global_game)
	add_child(global_ui)
	_check("全局模式下 game 就是 /root/Game", global_ui.game == global_game)
	_check("全局模式下没有多建一个本地 Game",
		get_node_or_null("/root/BattleGlobal/Game") == null)

	global_ui.start_battle()
	_check("全局模式下能进入战斗",
		global_game.progress_status == GameState.ProgressStatus.BATTLE)
	_check("全局模式下角色行正常生成", global_ui.party_panel.get_child_count() == 2,
		"标题 + 1 个角色，实际 %d" % global_ui.party_panel.get_child_count())

	# 关键差异：界面被释放后，状态仍然留在全局实例上
	global_ui.queue_free()
	_check("界面释放后状态仍留在全局实例上",
		global_game.progress_status == GameState.ProgressStatus.BATTLE)
	global_game.end_battle()
	global_game.leave_battle()
	_check("全局实例可以独立收尾",
		global_game.progress_status == GameState.ProgressStatus.EXPLORE
			and global_game.battle == null)

	# --- 路径取不到：记日志 + 停用界面，不崩也不退出 ---
	var broken: BattleUIBase = TEST_SCENE.instantiate()
	broken.use_global_game = true
	broken.global_game_path = "/root/DoesNotExist"
	add_child(broken)
	_check("取不到 Game 时 game 为 null", broken.game == null)
	_check("取不到 Game 时所有按钮被停用",
		broken.enter_button.disabled and broken.pause_button.disabled
			and broken.resume_button.disabled and broken.end_button.disabled
			and broken.leave_button.disabled and broken.save_button.disabled)
	_check("取不到 Game 时日志有提示", _log_contains(broken, "Game 节点不存在"),
		_log_text(broken))
	# 停用后即使程序化调用公开接口也不该崩
	broken.start_battle()
	broken.pause_battle()
	broken.end_battle()
	broken.advance_turn()
	broken.refresh()
	_check("停用后调用公开接口不崩", true)
	broken.queue_free()


# ---------------------------------------------------------------- 辅助

func _log_text(ui: BattleUIBase) -> String:
	return ui.log_view.get_parsed_text()


func _log_contains(ui: BattleUIBase, needle: String) -> bool:
	return _log_text(ui).contains(needle)


func _check(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  [PASS] ", name, "" if detail.is_empty() else "  (%s)" % detail)
	else:
		_failed += 1
		print("  [FAIL] ", name, "" if detail.is_empty() else "  (%s)" % detail)
