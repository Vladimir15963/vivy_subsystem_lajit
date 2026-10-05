extends Node

## 回合制战斗系统的无头逻辑测试。
##
## 运行方式：
##   godot --headless --path . battle_system/tests/battle_logic_test.tscn
##
## 覆盖：txt 加载/保存、进入战斗切换 Progress Status、攻击、治疗、目标默认规则、
##       暂停/继续/结束等打断流程、胜负结算、AI 决策。
##
## 说明：战斗逻辑用例全部使用脚本内构造的角色，不依赖 data/*.txt 的具体数值，
## 这样随手改数据文件也不会让逻辑测试误报；txt 相关的断言则与文件内容比对。

const DATA_DIR := "res://battle_system/data"
const SAVE_DIR := "user://battle_system_test_logic"

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("=== 回合制战斗系统 · 无头逻辑测试 ===")
	_test_txt_loading()
	_test_txt_saving_roundtrip()
	_test_enter_battle_sets_progress_status()
	_test_attack_reduces_hp()
	_test_heal_restores_hp()
	_test_target_defaults()
	_test_pause_blocks_actions()
	_test_resume_restores_battle()
	_test_end_battle_interrupts()
	_test_full_battle_reaches_victory()
	_test_ai_decisions()

	print("\n=== 结果：%d 通过 / %d 失败 ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


# ---------------------------------------------------------------- txt 数据

## 断言 txt 加载结果与文件里写的值一致（而不是写死 120/18 这类数字）。
func _test_txt_loading() -> void:
	var skill_sections := BattleData.parse_txt(
		FileAccess.get_file_as_string(DATA_DIR + "/skills.txt")
	)
	var char_sections := BattleData.parse_txt(
		FileAccess.get_file_as_string(DATA_DIR + "/characters.txt")
	)
	var skills := BattleData.load_skills(DATA_DIR + "/skills.txt")
	var characters := BattleData.load_characters(DATA_DIR + "/characters.txt", skills)

	_check("技能 txt 可加载", skills.size() == skill_sections.size(),
		"读到 %d 个 / 文件 %d 段" % [skills.size(), skill_sections.size()])
	_check("角色 txt 可加载", characters.size() == char_sections.size(),
		"读到 %d 个 / 文件 %d 段" % [characters.size(), char_sections.size()])
	_check("txt 里至少有一个角色和一个技能",
		not characters.is_empty() and not skills.is_empty())

	# 逐字段与文件内容比对
	var mismatched := PackedStringArray()
	for id in char_sections:
		var raw: Dictionary = char_sections[id]
		var c: BattleCharacter = characters.get(StringName(id))
		if c == null:
			mismatched.append("%s:未解析" % id)
			continue
		if c.max_hp != int(raw.get("max_hp", "1")):
			mismatched.append("%s:max_hp" % id)
		if c.attack != int(raw.get("attack", "1")):
			mismatched.append("%s:attack" % id)
		if c.defense != int(raw.get("defense", "0")):
			mismatched.append("%s:defense" % id)
		if c.speed != int(raw.get("speed", "1")):
			mismatched.append("%s:speed" % id)
		if c.display_name != String(raw.get("name", id)):
			mismatched.append("%s:name" % id)
	_check("角色每个字段都与 txt 一致", mismatched.is_empty(), "不一致：%s" % ", ".join(mismatched))

	# 技能 ID 关联
	var link_errors := PackedStringArray()
	for id in char_sections:
		var c: BattleCharacter = characters.get(StringName(id))
		var expect := 0
		for raw_id in String(char_sections[id].get("skills", "")).split(",", false):
			if skills.has(StringName(raw_id.strip_edges())):
				expect += 1
		if c == null or c.skills.size() != expect:
			link_errors.append("%s" % id)
	_check("角色技能按 ID 正确关联", link_errors.is_empty(), "异常：%s" % ", ".join(link_errors))
	_check("治疗技能解析出 heal 类型",
		_has_kind(skills, Skill.Kind.HEAL) and _has_kind(skills, Skill.Kind.ATTACK))

	var missing := BattleData.load_skills("res://battle_system/data/not_exist.txt")
	_check("缺失文件安全返回空", missing.is_empty())


func _has_kind(skills: Dictionary, kind: Skill.Kind) -> bool:
	for id in skills:
		if skills[id].kind == kind:
			return true
	return false


## 保存 -> 重新读回，确认往返不丢数据；并验证改动确实落盘。
func _test_txt_saving_roundtrip() -> void:
	var skills := BattleData.load_skills(DATA_DIR + "/skills.txt")
	var characters := BattleData.load_characters(DATA_DIR + "/characters.txt", skills)
	var first_id := String(characters.keys()[0])

	var err := BattleData.save_all(characters, skills, SAVE_DIR)
	_check("保存到 txt 成功", err == OK, "错误码 %d" % err)

	var raw := FileAccess.get_file_as_string(SAVE_DIR + "/characters.txt")
	_check("保存出来的 txt 含所有角色段", raw.contains("[%s]" % first_id))

	var reloaded := BattleData.load_all(SAVE_DIR)
	_check("保存后可重新读回", reloaded["characters"].size() == characters.size())
	var link_ok := true
	for id in characters:
		var before: BattleCharacter = characters[id]
		var after: BattleCharacter = reloaded["characters"].get(id)
		if after == null or after.max_hp != before.max_hp or after.attack != before.attack \
				or after.defense != before.defense or after.speed != before.speed \
				or after.skills.size() != before.skills.size():
			link_ok = false
	_check("角色数值与技能关联在往返后保留", link_ok)

	# 修改数值 -> 保存 -> 重新加载，确认写盘生效
	var victim: BattleCharacter = reloaded["characters"][first_id]
	var new_attack := victim.attack + 42
	victim.attack = new_attack
	victim.display_name = "改写测试"
	BattleData.save_characters(reloaded["characters"], SAVE_DIR + "/characters.txt")
	var again := BattleData.load_characters(SAVE_DIR + "/characters.txt", reloaded["skills"])
	var victim2: BattleCharacter = again.get(first_id)
	_check("修改后的数值被持久化",
		victim2 != null and victim2.attack == new_attack and victim2.display_name == "改写测试",
		"attack=%d" % (0 if victim2 == null else victim2.attack))

	DirAccess.remove_absolute(SAVE_DIR + "/characters.txt")
	DirAccess.remove_absolute(SAVE_DIR + "/skills.txt")


# ---------------------------------------------------------------- 状态机

func _test_enter_battle_sets_progress_status() -> void:
	var game := GameState.new()
	add_child(game)
	_check("初始状态为探索", game.progress_status == GameState.ProgressStatus.EXPLORE)
	_check("初始不在战斗中", not game.is_in_battle())

	var party := [_hero()]
	var foes := [_slime()]
	var battle := game.enter_battle(party, foes)
	_check("enter_battle 让 Progress Status 变成战斗状态",
		game.progress_status == GameState.ProgressStatus.BATTLE,
		"当前 %s" % GameState.status_to_string(game.progress_status))
	_check("enter_battle 返回战斗实例", battle != null and game.battle == battle)
	_check("战斗已初始化双方", battle.party.size() == 1 and battle.enemies.size() == 1)
	_check("重复 enter_battle 不会覆盖", game.enter_battle([], []) == battle and battle.party.size() == 1)
	game.queue_free()


# ---------------------------------------------------------------- 战斗行动

func _test_attack_reduces_hp() -> void:
	# 用高血量木桩当靶子，避免中途打死目标导致后续断言失去意义
	var game := _new_battle_game([_hero()], [_dummy()])
	var battle := game.battle
	var hero: BattleCharacter = battle.party[0]
	var dummy: BattleCharacter = battle.enemies[0]
	var slash: Skill = hero.skill_by_id(&"slash")
	var before := dummy.hp
	var expected := maxi(1, slash.power + hero.attack - dummy.defense)

	var result := battle.use_skill(hero, slash, dummy)
	_check("攻击行动成功", result["ok"] == true, str(result.get("reason", "")))
	_check("攻击让目标掉血", dummy.hp < before, "%d -> %d" % [before, dummy.hp])
	_check("伤害按 攻击+威力-防御 计算", result["results"][0]["amount"] == expected,
		"实际 %d / 期望 %d" % [result["results"][0]["amount"], expected])
	_check("无消耗技能不扣魔力", hero.mp == hero.max_mp, "mp=%d" % hero.mp)

	var heavy: Skill = hero.skill_by_id(&"heavy")
	battle.use_skill(hero, heavy, dummy)
	_check("技能消耗魔力", hero.mp == hero.max_mp - heavy.mp_cost,
		"mp=%d / 期望 %d" % [hero.mp, hero.max_mp - heavy.mp_cost])
	_check("战斗仍在进行（木桩没被打死）", not battle.finished)

	# 魔力不足时必须被拒绝，且理由要是魔力而不是别的
	hero.mp = 0
	var hp_before_denied := dummy.hp
	var denied := battle.use_skill(hero, heavy, dummy)
	_check("魔力不足时无法使用技能",
		denied["ok"] == false and String(denied["reason"]).contains("魔力"),
		str(denied["reason"]))
	_check("被拒绝时没有扣血", dummy.hp == hp_before_denied,
		"%d -> %d" % [hp_before_denied, dummy.hp])

	# 防御力参与减伤计算
	var armored := _new_battle_game([_hero()], [_dummy(40)])
	var armored_dummy: BattleCharacter = armored.battle.enemies[0]
	var armored_before := armored_dummy.hp
	armored.battle.use_skill(armored.battle.party[0], slash, armored_dummy)
	var armored_damage := armored_before - armored_dummy.hp
	_check("防御力参与减伤",
		armored_damage == maxi(1, slash.power + hero.attack - armored_dummy.defense)
			and armored_damage < expected,
		"高防目标受到 %d / 无防目标受到 %d" % [armored_damage, expected])

	game.queue_free()
	armored.queue_free()


func _test_heal_restores_hp() -> void:
	var game := _new_battle_game([_hero()], [_slime()])
	var battle := game.battle
	var hero: BattleCharacter = battle.party[0]

	hero.take_damage(40)
	var wounded := hero.hp
	_check("我方受伤", wounded < hero.max_hp, "hp=%d/%d" % [wounded, hero.max_hp])

	var heal_result := battle.use_skill(hero, hero.first_heal_skill(), hero)
	_check("治疗行动成功", heal_result["ok"] == true, str(heal_result.get("reason", "")))
	_check("治疗后生命增加", hero.hp > wounded, "%d -> %d" % [wounded, hero.hp])
	_check("治疗不会超过上限", hero.hp <= hero.max_hp, "hp=%d/%d" % [hero.hp, hero.max_hp])
	_check("治疗也消耗魔力", hero.mp == hero.max_mp - hero.first_heal_skill().mp_cost)

	# 治疗量恰好等于 技能威力 + 攻击力/2
	var game2 := _new_battle_game([_hero()], [_dummy()])
	var battle2 := game2.battle
	var hero2: BattleCharacter = battle2.party[0]
	var heal_skill: Skill = hero2.first_heal_skill()
	hero2.take_damage(60)
	var hp_before := hero2.hp
	var expected_heal: int = heal_skill.power + hero2.attack / 2
	battle2.use_skill(hero2, heal_skill, hero2)
	_check("治疗量 = 威力 + 攻击力/2",
		hero2.hp == hp_before + expected_heal,
		"%d -> %d / 期望 +%d" % [hp_before, hero2.hp, expected_heal])

	# 治疗不会超过生命上限
	var cap_game := _new_battle_game([_hero()], [_dummy()])
	var cap_hero: BattleCharacter = cap_game.battle.party[0]
	cap_hero.take_damage(3)
	cap_game.battle.use_skill(cap_hero, cap_hero.first_heal_skill(), cap_hero)
	_check("治疗不会超过生命上限", cap_hero.hp == cap_hero.max_hp,
		"hp=%d/%d" % [cap_hero.hp, cap_hero.max_hp])

	# 群体治疗作用到我方全体
	var game3 := _new_battle_game([_hero(), _priest()], [_dummy()])
	var battle3 := game3.battle
	var priest: BattleCharacter = battle3.party[1]
	for c in battle3.party:
		c.take_damage(30)
	var group_result := battle3.use_skill(priest, priest.skill_by_id(&"group_heal"), null)
	_check("群体治疗行动成功", group_result["ok"] == true, str(group_result.get("reason", "")))
	_check("群体治疗覆盖我方全体", group_result["results"].size() == 2,
		"命中 %d 个目标" % group_result["results"].size())

	# 倒下的角色不能行动
	hero.take_damage(9999)
	var dead_result := battle.use_skill(hero, hero.first_attack_skill(), battle.enemies[0])
	_check("倒下的角色无法行动", dead_result["ok"] == false, str(dead_result["reason"]))

	game.queue_free()
	game2.queue_free()
	cap_game.queue_free()
	game3.queue_free()


## 目标默认规则：交互界面点技能时传的是 null，必须能自动选出合法目标。
func _test_target_defaults() -> void:
	# 攻击类：不指定目标 -> 打第一个活着的敌人
	var game := _new_battle_game([_hero(), _priest()], [_slime(), _goblin()])
	var battle := game.battle
	var hero: BattleCharacter = battle.party[0]

	var attack_result := battle.use_skill(hero, hero.first_attack_skill(), null)
	_check("攻击未指定目标时自动选敌人", attack_result["ok"] == true, str(attack_result.get("reason", "")))
	_check("自动选中的是敌方单位",
		attack_result["results"][0]["target"] == battle.enemies[0])

	# 显式指定一个已倒下的敌人 -> 自动改用还活着的敌人
	battle.enemies[0].take_damage(9999)
	var fallback := battle.use_skill(hero, hero.first_attack_skill(), battle.enemies[0])
	_check("指定已倒下的敌人时自动改用活着的敌人",
		fallback["ok"] == true and fallback["results"][0]["target"] == battle.enemies[1],
		str(fallback.get("reason", "")))
	game.queue_free()

	# 治疗类：不指定目标 -> 选伤势最重的友方
	var heal_game := _new_battle_game([_hero(), _priest()], [_dummy()])
	var heal_battle := heal_game.battle
	var healer: BattleCharacter = heal_battle.party[1]
	heal_battle.party[0].take_damage(10)
	heal_battle.party[1].take_damage(60)
	var heal_result := heal_battle.use_skill(healer, healer.skill_by_id(&"heal"), null)
	_check("单体治疗未指定目标时自动选友方", heal_result["ok"] == true, str(heal_result.get("reason", "")))
	_check("自动选中伤势最重的友方",
		heal_result["results"][0]["target"] == heal_battle.party[1],
		"选中 %s" % heal_result["results"][0]["target"].display_name)

	# 显式指定一个已倒下的友方 -> 自动改用还活着的友方
	heal_battle.party[0].take_damage(9999)
	var retarget := heal_battle.use_skill(healer, healer.skill_by_id(&"heal"), heal_battle.party[0])
	_check("指定已倒下的友方时自动改用活着的友方",
		retarget["ok"] == true and retarget["results"][0]["target"] == heal_battle.party[1],
		str(retarget.get("reason", "")))

	# 阵营校验：治疗指向敌人时必须改成治疗友方，绝不能给敌人加血
	var enemy_hp_before: int = heal_battle.enemies[0].hp
	var misdirected := heal_battle.use_skill(healer, healer.skill_by_id(&"heal"), heal_battle.enemies[0])
	var misdirected_target: BattleCharacter = null
	if misdirected["ok"] and misdirected["results"].size() > 0:
		misdirected_target = misdirected["results"][0]["target"]
	_check("治疗指向敌人时改为治疗友方",
		misdirected_target != null and heal_battle.party.has(misdirected_target),
		"实际目标 %s" % (misdirected_target.display_name if misdirected_target != null else "无"))
	_check("治疗没有给敌人加血", heal_battle.enemies[0].hp == enemy_hp_before,
		"%d -> %d" % [enemy_hp_before, heal_battle.enemies[0].hp])
	heal_game.queue_free()

	# 阵营校验：攻击指向队友时必须改成攻击敌人
	var friendly_fire := _new_battle_game([_hero(), _priest()], [_dummy()])
	var ff_battle := friendly_fire.battle
	var ally_hp_before: int = ff_battle.party[1].hp
	var ff_result := ff_battle.use_skill(ff_battle.party[0], ff_battle.party[0].first_attack_skill(),
		ff_battle.party[1])
	_check("攻击指向队友时改为攻击敌人",
		ff_result["ok"] == true and ff_result["results"][0]["target"] == ff_battle.enemies[0],
		str(ff_result.get("reason", "")))
	_check("没有误伤队友", ff_battle.party[1].hp == ally_hp_before,
		"%d -> %d" % [ally_hp_before, ff_battle.party[1].hp])
	friendly_fire.queue_free()


# ---------------------------------------------------------------- 打断战斗

func _test_pause_blocks_actions() -> void:
	var game := _new_battle_game([_hero()], [_slime()])
	var battle := game.battle

	_check("暂停返回成功", game.pause_battle())
	_check("暂停后 Progress Status = BATTLE_PAUSED",
		game.progress_status == GameState.ProgressStatus.BATTLE_PAUSED,
		GameState.status_to_string(game.progress_status))
	_check("can_act 在暂停时为 false", not game.can_act())

	var blocked := battle.use_skill(battle.party[0], battle.party[0].first_attack_skill(), battle.enemies[0])
	_check("暂停期间行动被拒绝", blocked["ok"] == false, str(blocked["reason"]))
	_check("暂停期间拿不到行动者", battle.next_actor() == null)
	_check("重复暂停返回失败", not game.pause_battle())
	game.queue_free()


func _test_resume_restores_battle() -> void:
	var game := _new_battle_game([_hero()], [_slime()])
	game.pause_battle()
	_check("继续返回成功", game.resume_battle())
	_check("继续后 Progress Status = BATTLE",
		game.progress_status == GameState.ProgressStatus.BATTLE)
	_check("继续后可以行动", game.can_act())
	_check("未暂停时继续返回失败", not game.resume_battle())
	_check("继续后能取到行动者", game.battle.next_actor() != null)
	game.queue_free()


func _test_end_battle_interrupts() -> void:
	var game := _new_battle_game([_hero(), _priest()], [_slime(), _slime()])
	var battle := game.battle

	var survived := battle.enemies[0].hp
	_check("结束战斗返回成功", game.end_battle("测试中断"))
	_check("结束战斗直接结算", battle.finished and battle.result == BattleSystem.RESULT_ENDED)
	_check("Progress Status = BATTLE_ENDED",
		game.progress_status == GameState.ProgressStatus.BATTLE_ENDED,
		GameState.status_to_string(game.progress_status))
	_check("结束后不再能行动", not game.can_act())
	_check("结束后 use_skill 被拒绝",
		battle.use_skill(battle.party[0], battle.party[0].first_attack_skill(), battle.enemies[0])["ok"] == false)
	_check("结束后敌人血量未被改动", battle.enemies[0].hp == survived)

	var game2 := _new_battle_game([_hero()], [_slime()])
	game2.pause_battle()
	_check("暂停中也能结束战斗", game2.end_battle("暂停中中断"))
	_check("暂停中结束后状态 = BATTLE_ENDED", game2.progress_status == GameState.ProgressStatus.BATTLE_ENDED)

	_check("离开战斗回到探索", game.leave_battle())
	_check("离开后 Progress Status = EXPLORE",
		game.progress_status == GameState.ProgressStatus.EXPLORE)
	_check("离开后 battle 引用被释放", game.battle == null)

	var game3 := _new_battle_game([_hero()], [_slime()])
	_check("进行中的战斗无法返回探索", not game3.leave_battle())
	_check("进行中战斗状态仍为 BATTLE", game3.progress_status == GameState.ProgressStatus.BATTLE)

	game.queue_free()
	game2.queue_free()
	game3.queue_free()


func _test_full_battle_reaches_victory() -> void:
	# 用脚本内构造的角色保证结果确定：我方明显更强
	var game := _new_battle_game([_hero()], [_slime()])
	var battle := game.battle
	var guard := 0

	while not battle.finished and guard < 500:
		guard += 1
		var actor := battle.next_actor()
		if actor == null:
			break
		var plan: Dictionary = battle.choose_ai_action(actor)
		battle.use_skill(actor, plan["skill"], plan["target"])

	_check("自动战斗能打完", battle.finished, "循环 %d 次" % guard)
	_check("结果是胜利", battle.result == BattleSystem.RESULT_VICTORY, battle.result)
	_check("敌方全灭", BattleSystem.living(battle.enemies).is_empty())
	_check("胜利后 Progress Status = BATTLE_ENDED",
		game.progress_status == GameState.ProgressStatus.BATTLE_ENDED)
	_check("战斗日志非空", not battle.log_text().is_empty())

	# 弱势方应当失败，而不是卡死
	var weak := _new_battle_game([_weakling()], [_hero()])
	var weak_battle := weak.battle
	var weak_guard := 0
	while not weak_battle.finished and weak_guard < 500:
		weak_guard += 1
		var a := weak_battle.next_actor()
		if a == null:
			break
		var p: Dictionary = weak_battle.choose_ai_action(a)
		weak_battle.use_skill(a, p["skill"], p["target"])
	_check("弱势方会被打败", weak_battle.finished and weak_battle.result == BattleSystem.RESULT_DEFEAT,
		weak_battle.result)

	game.queue_free()
	weak.queue_free()


func _test_ai_decisions() -> void:
	var game := _new_battle_game([_hero()], [_slime(), _goblin()])
	var battle := game.battle
	var goblin: BattleCharacter = battle.enemies[1]

	var plan: Dictionary = battle.choose_ai_action(goblin)
	_check("AI 满血时选择攻击", plan["skill"] != null and plan["skill"].kind == Skill.Kind.ATTACK)
	_check("AI 攻击目标是敌方单位", plan["target"] != null and battle.party.has(plan["target"]))

	# 残血且有治疗技能时会自愈
	var healer := _new_battle_game([_hero()], [_priest()])
	var healer_battle := healer.battle
	var priest: BattleCharacter = healer_battle.enemies[0]
	priest.take_damage(priest.max_hp - 1)
	var heal_plan: Dictionary = healer_battle.choose_ai_action(priest)
	_check("AI 残血且有治疗技能时选择治疗",
		heal_plan["skill"] != null and heal_plan["skill"].kind == Skill.Kind.HEAL,
		str(heal_plan["skill"]))

	game.queue_free()
	healer.queue_free()


# ---------------------------------------------------------------- 测试用构造

## 以下角色都由脚本构造，与 data/*.txt 的实际数值解耦，保证断言确定。

func _make_skill(id: StringName, kind: Skill.Kind, power: int, mp_cost: int,
		target: Skill.Target = Skill.Target.ENEMY) -> Skill:
	var s := Skill.new()
	s.id = id
	s.display_name = String(id)
	s.kind = kind
	s.power = power
	s.mp_cost = mp_cost
	s.target = target
	s.description = "测试技能"
	return s


func _make_character(id: String, hp: int, mp: int, atk: int, defense: int, speed: int,
		skill_list: Array) -> BattleCharacter:
	var c := BattleCharacter.new()
	c.id = StringName(id)
	c.display_name = id
	c.max_hp = hp
	c.max_mp = mp
	c.attack = atk
	c.defense = defense
	c.speed = speed
	var typed: Array[Skill] = []
	for s in skill_list:
		typed.append(s)
	c.skills = typed
	c.reset()
	return c


func _hero() -> BattleCharacter:
	return _make_character("勇者", 120, 20, 18, 6, 12, [
		_make_skill(&"slash", Skill.Kind.ATTACK, 14, 0),
		_make_skill(&"heavy", Skill.Kind.ATTACK, 26, 6),
		_make_skill(&"heal", Skill.Kind.HEAL, 26, 5, Skill.Target.ALLY),
	])


func _priest() -> BattleCharacter:
	return _make_character("祭司", 80, 40, 6, 4, 9, [
		_make_skill(&"slash", Skill.Kind.ATTACK, 14, 0),
		_make_skill(&"heal", Skill.Kind.HEAL, 26, 5, Skill.Target.ALLY),
		_make_skill(&"group_heal", Skill.Kind.HEAL, 14, 12, Skill.Target.ALL_ALLIES),
	])


func _slime() -> BattleCharacter:
	return _make_character("史莱姆", 40, 10, 10, 2, 7, [
		_make_skill(&"slash", Skill.Kind.ATTACK, 14, 0),
	])


func _goblin() -> BattleCharacter:
	return _make_character("哥布林", 60, 12, 14, 5, 11, [
		_make_skill(&"slash", Skill.Kind.ATTACK, 14, 0),
	])


func _weakling() -> BattleCharacter:
	return _make_character("弱鸡", 20, 0, 1, 0, 1, [
		_make_skill(&"poke", Skill.Kind.ATTACK, 1, 0),
	])


## 高血量木桩：用来观察伤害/治疗数值，不会在测试途中被打死。
func _dummy(defense: int = 0) -> BattleCharacter:
	return _make_character("木桩", 9999, 9999, 0, defense, 0, [])


func _new_battle_game(party: Array, enemies: Array) -> GameState:
	var game := GameState.new()
	add_child(game)
	game.enter_battle(party, enemies)
	return game


func _check(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  [PASS] ", name, "" if detail.is_empty() else "  (%s)" % detail)
	else:
		_failed += 1
		print("  [FAIL] ", name, "" if detail.is_empty() else "  (%s)" % detail)
