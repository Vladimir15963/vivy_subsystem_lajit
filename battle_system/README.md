# 回合制战斗系统 · 测试项

一个极其简单的回合制战斗系统示例，覆盖四项要求：

1. **进入战斗函数** —— `Game.enter_battle()` 把选中 Game 的 Progress Status 切换成战斗状态
2. **打断战斗** —— 暂停 / 继续 / 结束战斗
3. **基本战斗功能** —— 使用技能攻击、治疗，可选择技能与目标
4. **txt 读写** —— 角色数值与技能全部通过 txt 加载和保存

界面部分抽成了一个**可复用的战斗 UI 基类** `BattleUIBase`，见第五节。

---

## 目录结构

```
battle_system/
├── data/                      # 人读可改的 txt 数据
│   ├── characters.txt         # 角色数值表
│   └── skills.txt             # 技能表
├── scripts/                   # 纯逻辑，不依赖界面
│   ├── game.gd                # Game 类：Progress Status 状态机 + 进入/打断战斗
│   ├── battle_system.gd       # BattleSystem：回合流转、行动结算、目标解析、暂停/结束
│   ├── character.gd           # BattleCharacter：hp/mp、攻防速、技能
│   ├── skill.gd               # Skill：攻击/治疗、目标类型、威力、消耗
│   └── battle_data.gd         # txt 解析与序列化（加载 / 保存）
├── ui/                        # 界面层
│   ├── battle_ui_base.tscn/.gd  # ★ 战斗界面基类（可继承）
│   └── character_row.tscn/.gd   # 单个角色行（名字 / HP·MP / 血条 / 可点击选目标）
├── battle_test.tscn/.gd         # 基础示例：继承基类场景，只改编队（本地 Game）
├── battle_variant_hard.tscn/.gd # 变体示例：继承同一基类，重写钩子强化敌人
├── battle_global.tscn/.gd       # 全局单例示例：use_global_game = true，接入 /root/Game
└── tests/
    ├── battle_logic_test.tscn/.gd  # 逻辑测试，80 条断言
    └── battle_ui_test.tscn/.gd     # 界面冒烟测试，53 条断言
```

---

## 一、Progress Status 状态机

`Game`（`scripts/game.gd`）持有 `progress_status`，共四个状态：

| 状态 | 含义 |
| --- | --- |
| `EXPLORE` | 探索中（非战斗） |
| `BATTLE` | 战斗中 |
| `BATTLE_PAUSED` | 战斗被暂停 |
| `BATTLE_ENDED` | 战斗已结束，等待返回探索 |

### 进入战斗

```gdscript
var game := Game.new()
add_child(game)

# 进入战斗函数：Progress Status 变成 BATTLE
game.enter_battle([hero, priest], [slime, goblin])
print(game.progress_status == Game.ProgressStatus.BATTLE)  # true
```

`enter_battle()` 会新建 `BattleSystem`、切换状态、启动战斗，并返回战斗实例。
已经在战斗中时不会重复进入（只打印一条警告并返回当前战斗）。

### 打断战斗

```gdscript
game.pause_battle()    # BATTLE        -> BATTLE_PAUSED
game.resume_battle()   # BATTLE_PAUSED -> BATTLE
game.end_battle()      # 任意战斗中状态 -> BATTLE_ENDED（立即结算）
game.leave_battle()    # BATTLE_ENDED  -> EXPLORE
```

- **暂停**期间 `use_skill()` 返回 `ok = false`，`next_actor()` 返回 `null`，任何行动都会被拒绝。
- **暂停中也能直接结束战斗**，不需要先继续。
- 只有 `BATTLE_ENDED` 状态才能 `leave_battle()` 回到探索。

状态变化会发出 `progress_status_changed(previous, current)` 信号。

---

## 二、战斗玩法

### 回合流转

按 `speed` 从高到低排序生成行动队列，每人行动一次为一轮；队列空了就开新回合。
由调用方驱动，方便随时暂停：

```gdscript
var actor := battle.next_actor()          # 取出下一个行动者（暂停/结束时返回 null）
battle.use_skill(actor, skill, target)    # 行动
```

### 使用技能

伤害公式：`max(1, 技能威力 + 攻击力 - 目标防御力)`
治疗公式：`技能威力 + 攻击力 / 2`（不超过生命上限）

```gdscript
var result := battle.use_skill(hero, hero.first_attack_skill(), slime)
# result = { ok, reason, results: [{target, type: "damage"/"heal", amount}] }
```

### 目标解析规则（重点）

`target` 传 `null` 是允许的，`BattleSystem.resolve_targets()` 会自动挑一个合法目标；
传了不合法目标（已倒下、或**站错阵营**）也会自动换掉：

| 技能目标类型 | 目标合法 | 目标为空 | 目标已倒下 | 目标站错阵营 |
| --- | --- | --- | --- | --- |
| `enemy` | 打它 | 第一个活着的敌人 | 第一个活着的敌人 | 第一个活着的敌人 |
| `ally` | 治疗它 | **伤势最重的友方** | 伤势最重的友方 | 伤势最重的友方 |
| `all_allies` / `all_enemies` | 忽略 `target`，作用到全体 |||

也就是说：**选中敌人再点治疗，不会给敌人加血**；选中队友再点攻击，也不会误伤队友。
交互界面在被自动修正时会在日志里提示「目标自动调整为：XXX」。

### 敌方 AI

`choose_ai_action(actor)` 是一个简单策略：自己血量低于 50% 且有治疗技能就治疗，否则攻击。

---

## 三、txt 数据格式

INI 风格，`#` 开头是注释，`[ID]` 开一个段，段内是 `key=value`。

**data/skills.txt**

```ini
[heal]
name=治疗术
type=heal          ; attack | heal
target=ally        ; enemy | ally | all_allies | all_enemies
power=26
mp_cost=5
description=恢复单个我方角色的生命。
```

**data/characters.txt**

```ini
[hero]
name=勇者
max_hp=120
max_mp=20
attack=18
defense=6
speed=12
skills=slash,heavy_slash,heal   ; 技能ID列表，需存在于 skills.txt
```

### 加载与保存

```gdscript
var skills := BattleData.load_skills("res://battle_system/data/skills.txt")
var characters := BattleData.load_characters("res://battle_system/data/characters.txt", skills)

var all := BattleData.load_all("res://battle_system/data")   # 一次性加载一个目录
BattleData.save_all(characters, skills)                            # 默认写 user://battle_system_test/
var hero := BattleData.instantiate_character("hero", characters)   # 取副本用于战斗
```

设计说明：txt 只保存**基础数值**；`hp` / `mp` 是战斗中的临时状态，进入战斗时由
`BattleCharacter.reset()` 重置为上限。文件缺失或读取失败时会 `push_error` 并返回空字典，
不会崩。（存储位置：`%APPDATA%\Godot\app_userdata\测试\battle_system_test\`）

> 数值可以随便改：逻辑测试的战斗用例全部使用脚本内构造的角色，不依赖 `data/*.txt` 的具体数字，
> 所以改数据（比如把史莱姆改成 9999 血）不会让测试误报失败；只有 txt 相关断言会跟文件内容比对。

---

## 四、界面基类 BattleUIBase ★

`ui/battle_ui_base.tscn` + `ui/battle_ui_base.gd` 把一整套战斗界面骨架收在一起：

> 状态栏 / 回合驱动 / 角色行（HP·MP·血条）/ 技能栏 / 目标选择 /
> 进入·暂停·继续·结束·返回探索 / txt 存档按钮 / 战斗日志

子类只需要声明「谁打谁」，或者重写几个钩子。

### 4.1 用继承场景（推荐）

1. 在编辑器里对 `ui/battle_ui_base.tscn` 右键 → **New Inherited Scene**
2. 把根节点脚本换成你的子类（`extends BattleUIBase`）
3. 在检查器里改 `party_ids` / `enemy_ids`

对应文件就三行内容，例如 `battle_test.tscn`：

```
[gd_scene load_steps=3 format=3]

[ext_resource type="PackedScene" path="res://battle_system/ui/battle_ui_base.tscn" id="1_base"]
[ext_resource type="Script" path="res://battle_system/battle_test.gd" id="2_sub"]

[node name="BattleTest" instance=ExtResource("1_base")]
script = ExtResource("2_sub")
party_ids = PackedStringArray("hero", "priest")
enemy_ids = PackedStringArray("slime", "goblin")
```

脚本也只有几行（`battle_test.gd`）：

```gdscript
extends BattleUIBase

func on_battle_ui_ready() -> void:
	log_message("基础示例：%s VS %s" % ["、".join(party_ids), "、".join(enemy_ids)])
```

### 4.2 导出配置

| 属性 | 说明 |
| --- | --- |
| `data_dir` | 角色 / 技能 txt 所在目录，默认 `res://battle_system/data` |
| `save_dir` | 「保存到 txt」写入的目录，默认 `user://battle_system_test` |
| `party_ids` | 我方角色 ID 列表（`characters.txt` 的段名） |
| `enemy_ids` | 敌方角色 ID 列表 |
| `use_global_game` | `false`（默认）= 自己 new 一个 Game；`true` = 接入全局单例 |
| `global_game_path` | 全局实例的节点路径，默认 `/root/Game` |
| `enemy_think_time` | 敌方回合的“思考”基准延时（秒），脚本默认 0.5 |
| `enemy_think_jitter` | 在基准延时上下随机浮动的比例，默认 0.6（= ±60%），0 表示固定延时 |

> 基类场景 `battle_ui_base.tscn` 里现在把 `enemy_think_time` 覆盖成了 `1.25`，
> 这就是「在检查器/场景里覆盖导出值」的实际例子；继承场景还可以再往下覆盖。

#### Game 实例来源：本地 / 全局



`GameState`（`scripts/game.gd`）同时支持两种接入方式，由 `use_global_game` 决定：

| 模式 | 取值 | 行为 | 用途 |
| --- | --- | --- | --- |
| 本地 | `false`（默认） | `GameState.new()` 建一个挂在界面自己下面 | 测试场景，多个场景互不干扰 |
| 全局 | `true` | `get_node_or_null(global_game_path)` 接入全局单例 | 真实项目，切场景不丢状态 |

全局单例在 `project.godot` 里注册：

```ini
[autoload]

Game="*res://battle_system/scripts/game.gd"
```

> **类名必须和 autoload 名不同**，否则 Godot 会报
> `Class "Game" hides an autoload singleton`。
> 所以这里是：类名 `GameState` + autoload 名 `Game` → `/root/Game` 就是那个实例。
> 你项目里若把 autoload 取了别的名字，改 `global_game_path` 即可。

取不到全局实例时的行为（**不退出进程、不崩**）：

```
Progress Status: —
Game 节点不存在：/root/Game
[日志] Game 节点不存在（/root/Game），界面已停用。
```

所有按钮被置灰，`start_battle()` 等公开接口变成 no-op 并记一行日志——
这样「忘了挂 autoload」能立刻看出来，而不是等到某处空指针崩溃。

`battle_global.tscn` 就是全局模式的完整示例（`use_global_game = true`）。

> 注意：res://battle_system/scripts/game.gd类名是 GameState(本地静态调试用的)，游戏里把这里的代码强兼到全局单例 Game


#### AI 决策等待时间

等待时间 = `enemy_think_time` ± `enemy_think_time * enemy_think_jitter`，
**每次 AI 行动前重新摇一次**，所以每回合节奏不会完全一致（看起来更像在“思考”）。

```gdscript
ui.enemy_think_time = 0.3     # 基准 0.3 秒
ui.enemy_think_jitter = 0.9   # ±90% -> 实际落在 0.03 ~ 0.57 秒
```

实测日志：

```
哥布林 正在行动…（思考 0.14 秒）
史莱姆 正在行动…（思考 0.38 秒）
哥布林 正在行动…（思考 0.05 秒）
```

几个细节：

- 想固定延时就设 `enemy_think_jitter = 0`，此时每次都等于基准值，便于做确定性测试。
- 基准为 0 时始终是 0（不会因为抖动摇出负数）；抖动比例超过 1.0 会被夹到 1.0。
- 因为延时是每次行动前现算的，**运行时改这两个属性对后续回合立即生效**
  （正在等待中的那一次不受影响）。
- 想换成别的分布，重写 `next_think_delay()` 即可，例如固定值 + 服务器时间同步。
- 抖动用的是基类自己持有的 `RandomNumberGenerator`，不会污染全局 RNG。

### 4.3 可重写的钩子

```gdscript
func on_battle_ui_ready() -> void                          # 界面就绪后
func build_party() -> Array                                # 默认按 party_ids 实例化
func build_enemies() -> Array                              # 默认按 enemy_ids 实例化
func on_refresh() -> void                                  # 每次界面刷新后
func on_battle_finished(result: String, reason: String)    # 一场战斗结算时
func next_think_delay() -> float                           # 摇一次 AI 思考等待时间
```

`battle_variant_hard.gd` 就是重写钩子的例子（单人出战 + 敌人生命攻击翻倍 + 结算提示）：

```gdscript
extends BattleUIBase

const ENEMY_HP_SCALE := 2

func build_enemies() -> Array:
	var foes := super()                      # 先按 enemy_ids 实例化
	for c in foes:
		c.max_hp *= ENEMY_HP_SCALE
		c.attack *= ENEMY_HP_SCALE
		c.reset()
	return foes

func on_battle_finished(result: String, reason: String) -> void:
	log_message(">>> 战斗结束：%s" % reason)
```

### 4.4 程序化接口

不想伪造按钮信号时，可以直接调：

```gdscript
ui.start_battle()    # 等价于点「进入战斗」
ui.pause_battle()
ui.resume_battle()
ui.end_battle()
ui.leave_battle()
ui.advance_turn()    # 推进到下一个行动者
ui.refresh()         # 手动刷新界面
ui.log_message("...")
```

以及只读状态：`ui.game` / `ui.current_battle()` / `ui.actor` / `ui.selected_target` /
`ui.characters` / `ui.skills` / `ui.is_player_turn()` / `ui.is_enemy(c)`。
信号：`target_changed(character)`。

### 4.5 两个设计点

- **节点用「唯一名」引用**：基类脚本里写 `%StatusLabel`、`%SkillBar` 等，基类场景里对应节点标了
  `unique_name_in_owner = true`。所以子类在继承场景里调整布局、增删无关节点，都不会把引用弄断。
- **按钮连线写在基类场景的 `[connection]` 里**，指向 `"."`（根节点）。子类替换根脚本后，
  因为方法是从 `BattleUIBase` 继承来的，连线照样生效——这也是 `battle_test.tscn` 不用写任何连线的原因。

---

## 五、运行方式

### 交互运行

```bash
godot --path . battle_system/battle_test.tscn          # 基础示例（本地 Game）
godot --path . battle_system/battle_variant_hard.tscn  # 困难变体
godot --path . battle_system/battle_global.tscn        # 全局单例模式
```

界面行为：

- 每个角色一行，显示 **名字、HP/MP 数值、血条与魔力条**，倒下的角色变暗且不可点。
- 点击任意角色行即可把它设为当前目标，行首出现 `▶` 标记。
- 技能按钮按**当前行动者实际拥有的技能**生成，显示名字与 MP 消耗，
  悬停可看威力 / 消耗 / 目标类型 / 说明；MP 不足或不是我方回合时置灰。
- 敌方回合会自动用 AI 行动（有 0.5 秒“思考”延迟），期间玩家按钮不可用。
- 按钮根据状态自动启用/禁用，底部日志实时打印状态变化、每次行动与目标修正。

### 无头测试

```bash
# 逻辑测试：80 条断言
godot --headless --path . battle_system/tests/battle_logic_test.tscn

# 界面冒烟测试：53 条断言
godot --headless --path . battle_system/tests/battle_ui_test.tscn
```

- **逻辑测试**：txt 加载（逐字段与文件比对）、保存往返与持久化、进入战斗切换状态、
  伤害公式、防御减伤与最低伤害、技能耗蓝与魔力不足拒绝、治疗量与上限、群体治疗、
  目标默认规则与**阵营校验**、倒下角色无法行动、暂停阻断、继续恢复、结束中断、
  全灭胜负结算、AI 决策。
- **界面冒烟测试**：基类场景能被直接实例化且 `%唯一名` 全部解析成功、继承场景的导出覆盖生效、
  三个生命周期钩子（`on_battle_ui_ready` / `build_enemies` / `on_battle_finished`）真的被调用、
  角色行与技能按钮随战斗状态生成、状态机四态下按钮可用性正确、
  **AI 等待时间的取值范围 / 波动 / 边界夹取**、
  **Game 实例来源的两种模式与取不到时的降级**。
  界面逻辑不需要渲染，headless 足以覆盖——**“钩子声明了却忘了接线”这类问题就是靠它兜住的**。

两个测试都以退出码 0 表示全部通过。

---

## 六、备注

- 基类放在 `battle_system/ui/` 下，保持测试项自包含；如果要给正式游戏复用，
  把 `ui/battle_ui_base.*` 和 `ui/character_row.*` 挪到顶层模块目录即可（记得改 `ROW_SCENE` 的 preload 路径）。
- 脚本使用 `class_name` 全局类名。Godot 的非编辑器模式依赖 `.godot/global_script_class_cache.cfg`
  来解析全局类名，该文件由编辑器扫描工程时生成（`.godot/` 已在 `.gitignore` 中）。
  用编辑器打开一次工程即可；纯净环境里直接跑无头测试前，先执行一次 `godot --headless --import`。
- 本测试项的 autoload `Game` 指向 `battle_system/scripts/game.gd`，是为了让 `/root/Game` 真实存在
  好做验证。接进正式项目时，把它指向你自己的 Game 脚本（或改 `global_game_path`）即可。
- 战斗数值平衡是随意取的，只为演示流程。
