class_name BattleData
extends RefCounted

## 角色数值与技能的 txt 加载 / 保存。
##
## txt 格式（INI 风格，便于手改）：
##   # 注释
##   [段ID]
##   key=value
##
## 段 ID 就是技能 / 角色的 id，段内的 key 与 Skill / BattleCharacter 的字段一一对应。

const DEFAULT_DATA_DIR := "res://battle_system/data"
const DEFAULT_SAVE_DIR := "user://battle_system_test"


# ---------------------------------------------------------------- 解析 / 序列化

## 把 txt 文本解析成 {段ID: {key: value}}。
static func parse_txt(text: String) -> Dictionary:
	var sections: Dictionary = {}
	var current := ""
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			current = line.substr(1, line.length() - 2).strip_edges()
			if not current.is_empty():
				sections[current] = {}
			continue
		if current.is_empty():
			continue
		var eq := line.find("=")
		if eq <= 0:
			continue
		sections[current][line.substr(0, eq).strip_edges()] = line.substr(eq + 1).strip_edges()
	return sections


## 把 {段ID: {key: value}} 序列化回 txt 文本。
static func sections_to_txt(sections: Dictionary, header: String = "") -> String:
	var out := ""
	if not header.is_empty():
		for line in header.split("\n"):
			out += "# " + line + "\n"
		out += "\n"
	for section_id in sections:
		out += "[%s]\n" % section_id
		var fields: Dictionary = sections[section_id]
		for key in fields:
			out += "%s=%s\n" % [key, fields[key]]
		out += "\n"
	return out


# ---------------------------------------------------------------- 技能

## 从 txt 读取技能表，返回 {StringName(id): Skill}。
static func load_skills(path: String = DEFAULT_DATA_DIR + "/skills.txt") -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("BattleData: 技能文件不存在 -> " + path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("BattleData: 技能文件为空或读取失败 -> " + path)
		return {}
	var skills: Dictionary = {}
	var sections := parse_txt(text)
	for section_id in sections:
		var skill := _skill_from_fields(StringName(section_id), sections[section_id])
		skills[skill.id] = skill
	return skills


## 把技能表写回 txt。
static func save_skills(skills: Dictionary, path: String = DEFAULT_SAVE_DIR + "/skills.txt") -> Error:
	var sections: Dictionary = {}
	for skill_id in skills:
		var skill: Skill = skills[skill_id]
		if skill == null:
			continue
		sections[String(skill.id)] = {
			"name": skill.display_name,
			"type": "heal" if skill.kind == Skill.Kind.HEAL else "attack",
			"target": Skill.target_to_string(skill.target),
			"power": str(skill.power),
			"mp_cost": str(skill.mp_cost),
			"description": skill.description,
		}
	return _write_file(path, sections_to_txt(sections, "技能表（由 BattleData 自动生成）"))


static func _skill_from_fields(id: StringName, fields: Dictionary) -> Skill:
	var skill := Skill.new()
	skill.id = id
	skill.display_name = String(fields.get("name", String(id)))
	skill.kind = (
		Skill.Kind.HEAL
		if String(fields.get("type", "attack")).to_lower() == "heal"
		else Skill.Kind.ATTACK
	)
	match String(fields.get("target", "enemy")).to_lower():
		"ally":
			skill.target = Skill.Target.ALLY
		"all_allies":
			skill.target = Skill.Target.ALL_ALLIES
		"all_enemies":
			skill.target = Skill.Target.ALL_ENEMIES
		_:
			skill.target = Skill.Target.ENEMY
	skill.power = int(fields.get("power", "0"))
	skill.mp_cost = int(fields.get("mp_cost", "0"))
	skill.description = String(fields.get("description", ""))
	return skill


# ---------------------------------------------------------------- 角色

## 从 txt 读取角色表，返回 {StringName(id): BattleCharacter}。
## skills 参数是 load_skills() 的结果，用于把技能 ID 解析成 Skill 对象。
static func load_characters(
	path: String = DEFAULT_DATA_DIR + "/characters.txt",
	skills: Dictionary = {}
) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("BattleData: 角色文件不存在 -> " + path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("BattleData: 角色文件为空或读取失败 -> " + path)
		return {}
	var characters: Dictionary = {}
	var sections := parse_txt(text)
	for section_id in sections:
		var fields: Dictionary = sections[section_id]
		var character := BattleCharacter.new()
		character.id = StringName(section_id)
		character.display_name = String(fields.get("name", section_id))
		character.max_hp = int(fields.get("max_hp", "1"))
		character.max_mp = int(fields.get("max_mp", "0"))
		character.attack = int(fields.get("attack", "1"))
		character.defense = int(fields.get("defense", "0"))
		character.speed = int(fields.get("speed", "1"))
		var list: Array[Skill] = []
		for raw_id in String(fields.get("skills", "")).split(",", false):
			var skill_id := StringName(raw_id.strip_edges())
			var skill: Skill = skills.get(skill_id)
			if skill == null:
				push_warning("BattleData: 角色 %s 引用了不存在的技能 %s" % [section_id, skill_id])
				continue
			list.append(skill)
		character.skills = list
		character.reset()
		characters[character.id] = character
	return characters


## 把角色表写回 txt。
static func save_characters(
	characters: Dictionary,
	path: String = DEFAULT_SAVE_DIR + "/characters.txt"
) -> Error:
	var sections: Dictionary = {}
	for character_id in characters:
		var c: BattleCharacter = characters[character_id]
		if c == null:
			continue
		var skill_ids := PackedStringArray()
		for s in c.skills:
			if s != null:
				skill_ids.append(String(s.id))
		sections[String(c.id)] = {
			"name": c.display_name,
			"max_hp": str(c.max_hp),
			"max_mp": str(c.max_mp),
			"attack": str(c.attack),
			"defense": str(c.defense),
			"speed": str(c.speed),
			"skills": ",".join(skill_ids),
		}
	return _write_file(path, sections_to_txt(sections, "角色数值表（由 BattleData 自动生成）"))


# ---------------------------------------------------------------- 组合操作

## 同时保存角色与技能到 dir 目录。
static func save_all(characters: Dictionary, skills: Dictionary, dir: String = DEFAULT_SAVE_DIR) -> Error:
	var err := save_skills(skills, dir + "/skills.txt")
	if err != OK:
		return err
	return save_characters(characters, dir + "/characters.txt")


## 从 dir 目录同时读取角色与技能；目录不存在时返回空字典。
static func load_all(dir: String = DEFAULT_DATA_DIR) -> Dictionary:
	var skills := load_skills(dir + "/skills.txt")
	var characters := load_characters(dir + "/characters.txt", skills)
	return {"skills": skills, "characters": characters}


## 按 id 取一份角色副本（深拷贝，避免影响原始数据表）。
static func instantiate_character(id: String, characters: Dictionary) -> BattleCharacter:
	var source: BattleCharacter = characters.get(StringName(id))
	if source == null:
		push_error("BattleData: 找不到角色 " + id)
		return null
	var copy: BattleCharacter = source.duplicate(true)
	copy.reset()
	return copy


# ---------------------------------------------------------------- 内部

static func _write_file(path: String, content: String) -> Error:
	var dir := path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var err := FileAccess.get_open_error()
		push_error("BattleData: 无法写入 %s（错误码 %d）" % [path, err])
		return err
	file.store_string(content)
	file.close()
	return OK
