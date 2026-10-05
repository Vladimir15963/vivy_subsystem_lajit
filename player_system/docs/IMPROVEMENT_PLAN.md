# 玩家子系统改进方案

> 对象：`res://player_system/`（自 `jump!` 剥离出的玩家实例子系统）
> 基线：剥离后的代码与源项目**逐字节一致**，但已有 11 个编号被处置 ——
> §1.4（D17 缩放补偿）、§1.5（D18 空中阻力）、§1.6（D1 眨眼贴图，纯数据）、
> §1.7（D2 只加注释）、§1.8（D5 只加注释）、§1.9（D7/D9/D11/D12/D13/D14 六项重构）。
> 其中 **D2/D5 只加注释、未改一行可执行代码**；§1.9 是最大的一次行为改动（死亡表现整体移出玩家）。
> 下文其余每条诊断仍能与源项目一一对应。
> 其中缩放补偿在 `scale = (1,1)` 时行为等同改造前。因此下文其余每条诊断都能与源项目一一对应。
> 本文只列**已核实**的问题：带「实测」的证据来自 `tests/player_smoke_test.gd`（136 条断言全绿）
> 或专门的对照实验；未核实的猜想会被明确标注为「待验证」。

---

## 0. 目标与原则

**目标**：让玩家子系统在保持手感的前提下，成为可参数化、可注入输入、可被外部事件驱动、
表现与逻辑解耦、且可被自动化回归的模块。

**原则**

1. **手感优先于整洁**：任何影响运动曲线的改动都必须有数值/录像 A/B 依据，不能"顺手改"。
2. **先测量再修改**：每个阶段开始前，用冒烟测试固化当前数值（速度、跳跃高度、落地时间）。
3. **保持 uid 与资源路径语义**：便于回灌到 `jump!`，避免牵动关卡与主菜单的引用。
4. **一次只动一层**：逻辑层（`player.gd`）、表现层（烟雾/环境）、资源层（眼睛图集）分开改。

---

## 1. 现状诊断

### 1.1 已实测确认的缺陷

| 编号 | 位置 | 现象与证据 |
| --- | --- | --- |
| **D1** | ✅ **已修复**（见 §1.6） | `scenes/eyes.tscn` `Animation_aqb7g` 末帧 + `scripts/eye.gd:88` | `chiler` 的贴图轨道是**离散**轨道（`update=1`，值会一直保持到下一个键），末帧值被写成 `null`。逐帧采样实测：**每次眨眼有连续 3 帧（≈50 ms）整只眼睛没有贴图**。源码用 `play("chiler")` 后**紧跟** `play_backwards("chiler")` 反向播回来，只掩盖了「动画结束后永久不可见」，掩盖不了中途这 3 帧。 |
| **D5** | ✅ **已修复问题 2；问题 1 按决定保留**（见 §1.8 / §1.10） | `scripts/player.gd:20,44-49` | `decode_vector()` 在 `_ready()` 里把 `max_speed` ×1.5、`jump_velocity` ×1.5。**实测**：声明 `124.5 / -340.0`，运行时 `186.75 / -510.0`；调参时看到的数字与生效数字不一致。**连带风险**：这是乘法，重复调用 `_ready()` 会叠乘（实测第 2 次 `280.13 / -765.0`，第 3 次 `420.19 / -1147.5`），而文件开头恰好写着"死亡后可调用 `_ready()` 重新初始化"。 |
| **D3** | `scripts/player.gd:88-91` | 空中水平移动把 `ground_friction(0.7)` 当作目标速度的系数（应为 1.0），并且 `desired_velocity + velocity.x` 里的 `velocity.x` 是上一帧 `move_and_slide()` 之后的值（应与 `current_velocity.x` 一致），构成自反馈。**实测**：地面 40 物理帧即可把速度顶到 `max_speed=435`；空中同样的输入只能到目标速度的 ~70%。 |
| **D4** | ✅ **已修复**（见 §1.5） | `scripts/player.gd:17,89` | `air_resistance` 名义上是"空中水平阻力系数"，实际执行 `current_velocity.x *= air_resistance` —— 1.1（后被调到 1.4）意味着**每帧加速**，与命名和注释完全相反。`decode_vector()` 里同一变量的倍率行还被注释掉了，说明作者本人也在此处摇摆过。 |
| **D4b** | ✅ **已修复**（见 §1.10） | `scripts/player.gd:18,87,91` | `ground_friction` 声明为 `0.7`（后被调到 `0.237`），但地面摩擦实际写的是字面量 `current_velocity.x *= 0.83  #ground_friction`；而 `ground_friction` 只在**空中**公式里被用到，且是当作**目标速度的系数** → 空中按住方向键的平衡速度只有 `0.237/0.763 × max_speed` ≈ 58（`max_speed` = 186.8），**按住方向反而减速**。空中误用已随 D4 一并清除；地面那处字面量仍是硬编码，`ground_friction` 目前**完全不生效**。 |
| **D6** | `scripts/player.gd:60-80` | 跳跃缓冲 `jump_buffer_timer` 只在「本帧未按跳 且 不在地面」时递减；`is_on_floor()` 的翻转发生在 `move_and_slide()` 之后，因此**落地帧读到的仍是上一帧的 `is_on_floor()`**。**实测**：落地后需再等 1 个物理帧 `jump_count` 才归零（冒烟测试中已加注释说明）。这意味着"落地即缓冲跳"的时序依赖帧边界，脆弱。 |
| **D8** | `scripts/eye.gd:53-54` | `lerp_position()` 在 `body` 为空时 `else: _ready()` —— 用重新执行 `_ready()` 当兜底。若 `body` 始终为空，每次调用都会重跑 `_ready()`（静默、无报错、也不修复），每秒 60 次无效初始化。 |

### 1.2 结构与架构问题（已读代码确认，非猜测）

| 编号 | 位置 | 问题 |
| --- | --- | --- |
| **D2** | ✅ **已处置**（见 §1.7：只写注释，不改行为） | `eye.gd:52` | `position = position.lerp(target_pos, speed)`，`speed = 3.4 * delta`（≈0.057/帧）。这是**帧率相关的收敛速度**：144Hz 下每帧 0.024，同样 0.5s 内眼睛只走完约一半距离。高刷屏与移动端手感不一致。 |
| **D7** | ✅ **已实施**（见 §1.9） | `player.gd:132-135` | `direction_change()` 每帧调用 `set_knip()` + `set_expression()`；`set_expression` 每帧重写同一个 `AtlasTexture.region`。另外 `eyes.set_expression(eyes.expression.blink)` 通过**实例**取枚举成员，可读性与静态检查都差。 |
| **D9** | ✅ **已实施**（见 §1.9） | `player.gd:6,41,113-118` | 玩家场景内嵌 `WorldEnvironment`，`deal("god")` 直接改它的 `Environment`（`glow_enabled/glow_bloom/glow_hdr_*`）。`Environment` 是场景内子资源，**同场景两个玩家实例会互相影响**；且本项目渲染器是 `gl_compatibility`，glow 不产生 bloom —— 表现层与环境层强耦合，收益为零。 |
| **D10** | `player.gd:57,66,98` | 输入直接轮询全局 `Input`：`_physics_process` 里 `Input.get_axis`，`_process` 里 `Input.get_axis`，跳跃 `Input.is_action_just_pressed`。无法脚本化、无法 AI 接管、无法录制回放，也无法在无头测试里驱动除了 `Input.action_press` 之外的方式。 |
| **D11** | ✅ **已实施**（见 §1.9） | `player.gd:110-128` | `deal(anim_name: String)` 用字符串 `match` 分派，无返回值、无信号；`_on_button_button_up()` 把 UI Button 的信号**直接连到玩家脚本**。死亡后没有任何完成事件，外部只能靠 `levels/level_1.gd:56-61` 把 `player.position` tween 到硬编码 `Vector2(258,95)` 来"复位"。 |
| **D12** | ✅ **已实施**（见 §1.9） | `player.gd:11-35` | 除 `eyes_mode` 外**没有一个 `@export`**。所有手感参数必须改代码，策划/美术无法在检查器试值。 |
| **D13** | ✅ **已实施**（见 §1.9） | `player.gd:29,32,136-141` | `dirrction_dev` 拼写错误；`player_direction` 的语义只靠注释维系；"向左时 x 取反"只在 `direction != player_direction and direction != 0` 时执行，与 `dirrction_dev` 初值 `(0.68, -0.636)` 的约定是隐式的。 |
| **D14** | ✅ **已实施**（见 §1.9） | `player.tscn` `SpriteFrames_xub4p` | 28 帧 1440×1080 烟雾（≈2.2MB）内嵌在玩家场景里，从不死亡也会参与加载/导入。素材总量 2.50MB 中 87% 是这个多数对局不会用到的表现资源。 |
| **D15** | `player.png` 20×13 + `eyes.tscn` `margin=(10.7,8.2)` | 眼睛可动范围**从贴图尺寸推导**：`max_offset = (b_size - margin)/2 = (4.65, 2.4)px`。归一化偏移 0.68 只对应 3.2px 位移，观感上"眼睛几乎不动"，且非整数像素会破坏像素完美。 |
| **D16** | 两个脚本 | 无 `class_name`、无类型签名、无自定义信号。外部（含源项目 `test/player/test_scen.gd:9`）只能靠硬路径 `$player/player/eyes` 访问。 |

### 1.3 已核实**正常**的点（改造时不要改坏）

- 二段跳确实被禁止（`max_jumps=1` 时空中按跳无效，`jump_count` 保持 1）。
- 落地后 `jump_count` 归零、`coyote_timer` 重置。
- `max_speed` 钳制生效（实测 435.0 顶格）。
- 眼睛偏移 `[-1,1]` 钳制生效；左右移动时 `deviation.x` 正确翻转（+0.680 ↔ -0.680）。
- 表情区域映射正确（default/blink_left/blink_right/blink/die）。
- `deal("steve")` / `deal("god")` 都置位 `is_deal` 并冻结物理（`_physics_process` 提前返回）。
- `glow_enabled` 属性正确置位（兼容渲染器下无视觉，但状态是对的）。
- 28 帧烟雾 `SpriteFrames`、`chiler` 眨眼动画库、3 个音频都解析成功。

### 1.4 ✅ 已实施：玩家缩放对运动的影响（D17）

> `scale = (1,1)` 时行为与改造前完全一致，不破坏保真基线。

| | |
| --- | --- |
| **问题** | `CharacterBody2D.velocity` 的单位是「全局像素/秒」，与节点 `scale` 无关。把玩家放大 N 倍，跑动速度、跳跃高度、滞空时间全部不变，导致「跳不起自己那么高」、机动性随体型劣化。 |
| **方案** | 新增 `@export var scale_affects_motion := true` 与 `@export var motion_scale := Vector2.ONE`；`refresh_motion_scale()` 按 `s = scale.abs() * motion_scale` 重算 `max_speed *= s.x`、`jump_velocity *= s.y`、`gravity *= s.y`；基准值在 `decode_vector()` 中记录，避免来回缩放的误差累积；每个物理帧开头调用一次（带早退），支持动画/技能驱动的运行时缩放。 |
| **实测** | `scale` 1 → 2：`max_speed` 186.8→373.5、`jump_velocity` -510→-1020、`gravity` 1078→2156；跳跃高度 116.4→232.9 px（×2.00）；滞空 55→55 帧；「跳跃高度 ÷ 体型」116.4→116.4 不变。 |
| **验收** | 冒烟测试第 [8] 组，含：基准值（**动态读取**，不写死）、三项参数线性放大、跳跃高度线性 / 滞空不变 / 相对体型高度不变、缩回完全还原、`scale_affects_motion=false` 时缩放无效、`motion_scale` 可脱离 scale 单独调参、负缩放取模不反转移动方向。 |
| **注意** | 若用 `scale` 做挤压拉伸（squash & stretch）等纯视觉动画，必须关掉 `scale_affects_motion`，改用 `motion_scale`，否则每一下挤压都会抖动移动速度。 |
| **遗留** | `scale` 变化时不会同步重算 `current_velocity`：变大时速度保持（随后由钳制和加速度自然收敛），变小时会在下一帧被 `clamp` 削到新的 `max_speed`。当前行为可接受，若将来做「一次性缩小」类道具需再评估。 |

### 1.5 ✅ 已实施：空中阻力重构（D18，同时解决 D4 与 D4b 的空中部分）

| | |
| --- | --- |
| **问题** | 原空中水平模型有两处反向错误：① `current_velocity.x *= air_resistance`，系数 1.1（后被手动调到 1.4）实际是**每帧加速**，与"阻力"之名相反；② `lerp(vx, ground_friction*(desired+velocity.x), acceleration*0.7)` 把 `ground_friction` 当成**目标速度的系数**，空中按住方向键的平衡速度只有约 58，而 `max_speed` 是 186.8 —— **按住方向反而减速**。此外该式还混入 `0.7·vx` 这个方向随速度而非朝向变化的阻力项。 |
| **方案** | 删除 `air_resistance`，改为显式参数：`air_drag`（每秒沿朝向轴衰减比例，默认 0.35）、`air_control`（空中操控力，默认 0.35 = 原 `acceleration*0.7`）、`in_place_epsilon`（原地起跳判定阈值）。空中分支拆成两件互不干扰的事：<br>① `_apply_air_drag(delta)` —— 沿 `facing = player_direction` 轴，方向恒为 `-facing`；只对 `along = vx × facing > 0` 的分量生效，否则直接返回（不把玩家推向后方、不让静止玩家飘起来）；衰减用 `pow(1.0 - air_drag, delta)`，帧率无关。<br>② `lerp(vx, desired_velocity, air_control)` —— 仅当有水平输入时把速度拉向输入目标（不再乘 `ground_friction`）。<br>③ `_refresh_air_drag_suppression()` 在 `move_and_slide()` 之后检测"刚离地那一帧"：该帧水平输入 ≤ `in_place_epsilon` → 判定原地起跳，`air_drag_suppressed = true`，整段滞空跳过阻力；落地复位。 |
| **实测** | 40 帧（0.667 s）后：起跳瞬间按住方向 186.8 → 140.1（保留 **75%**，理论 0.65^0.667 = 0.752）；起跳瞬间无输入 106.8 → **106.8（保留 100%）**；朝向右侧向右移动 100 → 80.6（削减）；朝向右侧向左移动 -100 → -100.0（**不介入**）；静止 0 → 0.00（**不飘**）；朝向左侧向左移动 -100 → -80.6（方向同步翻转）；`air_drag=0` 时 100 → 100.0。 |
| **验收** | 冒烟测试第 [9] 组共 12 条断言，覆盖上述全部场景。 |
| **遗留** | ① `air_drag = 0.35/秒` 是选定的默认值（原实现等效为 +2.6%/帧的加速，更早的 1.1 版本为 −1.55%/帧），需按手感确认。② **`ground_friction` 目前完全不生效**：地面分支仍是硬编码字面量 `*= 0.83`，接上它会变成 0.237/帧（差别很大），故未擅自修改。③ 朝向与速度相反时（例如空中转身）阻力不介入，这是"只削减朝向前方动量"的直接推论，如需"总能刹住"需另加规则。 |

### 1.6 ✅ 已实施：眨眼时眼睛消失（D1）

| | |
| --- | --- |
| **问题** | `chiler` 的眼部贴图轨道是**离散**轨道（`update = 1`，值一直保持到下一个键），末帧值是 `null`。逐帧采样一次完整眨眼：睁眼(f00–f02) → **NULL(f03–f05)** → 闭眼(f06–f07) → 半闭(f08–f11) → 睁眼(f12+)，即**每次眨眼有连续 3 帧（≈50 ms）整只眼睛没有贴图**。`play("chiler")` + `play_backwards("chiler")` 只掩盖了"动画结束后永久不可见"，掩盖不了中途这 3 帧。 |
| **方案** | 采用最小修复：`scenes/eyes.tscn` → `Animation_aqb7g` → `tracks/0`（`TextureRect:texture`）末帧值 `null` → `SubResource("AtlasTexture_c6fh2")`。因为动画是反向播放的，这个键实际对应"眨眼开始前的保持帧"。 |
| **实测** | `null` 帧数 **3 → 0**；序列变为 睁眼（保持）→ 闭眼 → 半闭 → 睁眼；`TextureRect.position` 仍回到 `0`；结束后 `TextureRect.texture` 仍等于脚本缓存的图集（`set_expression` 继续生效）。 |
| **验收** | 冒烟测试第 [7] 组新增 4 条断言，逐帧扫描一次完整眨眼：全程不为 `null`、确实切换了 ≥3 种图集区域（防止"什么都不做"蒙混过关）、结束后贴图与脚本缓存一致、结束后表情仍可切换。 |
| **未做（可选后续）** | `eye.gd:88` 的**反向播放**保留未改，因为改成正向播放必须同时给位置轨道补 `t=0.158 → (0,0)` 的键（否则眨眼后眼睛永久低 1.26 px），且会改变已调好的观感。作者的键间距是 `0=睁 / 0.073=半闭 / 0.099=闭 / 0.147=末帧`，闭眼那段最长（48 ms），本意应是"闭眼停一下"，反向播出来变成"睁眼停得最久"。 |

### 1.7 ✅ 已处置：眼睛插值速度与帧率相关（D2）—— 只写注释，不改行为

| | |
| --- | --- |
| **问题** | `lerp_position()` 的 `speed` 是**每帧**插值比例而非"每秒速度"，但两个调用点传的都是 `3.4 * delta`（`player.gd → direction_change()` 直接传；`player.gd → aim_mouse()` 经 `aiming_move()` 传）。60fps 下每帧 ≈0.057，144Hz 下 ≈0.024 —— 同样 0.5 s 眼睛只走完约一半距离。 |
| **处置** | **按当前优先级决定不改行为**，把问题完整写进 `eye.gd` 的函数注释（含两个调用点、帧率对照、将来要改时的具体写法与坑）。同时把 `eye.gd` 登记进 `tools/extract_player_system.py` 的 `LOCALLY_MODIFIED`，避免重跑剥离脚本时注释被冲掉。 |
| **为什么不算"已修复"** | 改法（`1 - pow(1-alpha, delta*60)`）本身是低风险的，但它会改变 60fps 之外的既有观感，属于手感改动，原 P0-2 的验收要求是"60Hz 与 144Hz 下 0.5s 位移差 < 5%"，需要高低帧对照验证。没有该验证前不擅动。 |
| **验证"只有注释"** | 源可执行行数 66 / 现可执行行数 66，**可执行代码差异 0 行**；新增 22 行全部为注释，删除 0 行。 |
| **将来要改** | `static func _smooth(alpha_60, delta) -> float: return 1.0 - pow(1.0 - alpha_60, delta * 60.0)`；两个坑：① 调用点已乘过 `delta`，要去掉否则二次缩放；② `lerp_position` 需要能拿到 `delta`（新增参数或由调用方传"基准比例 + delta"）。 |

### 1.8 ✅ 已处置：`decode_vector()` 的隐藏 ×1.5 倍率（D5）—— 只写注释，不改行为

| | |
| --- | --- |
| **问题 1** | `max_speed` / `jump_velocity` 的**声明值**（源文件与检查器里看到的数）会被 `_ready()` 里的 `decode_vector()` 再 ×1.5：声明 `124.5 / -340.0` → 运行时 `186.75 / -510.0`（`gravity` 不参与，仍是 `980 × 1.1 = 1078.0`）。照着 124.5 调出来的手感其实是 186.75 的手感。 |
| **问题 2（连带发现，更要紧）** | 这是**乘法**，而文件开头写着"玩家死亡后请重新实例化或是调用 `_ready()` 进行初始化"。实测重复调用 `_ready()`：<br>首次 `186.75 / -510.00` → 再次 `280.13 / -765.00` → 第三次 `420.19 / -1147.50`（累计 ×3.375）。<br>每"重新初始化"一次玩家就**永久快 1.5 倍**，无报错、无日志。 |
| **处置** | 不改代码，把上述两点写进 `player.gd` 的 `decode_vector()` 函数注释；并在**文件头部那句误导性注释**下加了警告（建议走"重新实例化"而非重复 `_ready()`），在两处变量声明旁标注了"基准值，运行时 ×1.5"。 |
| **为什么不算"已修复"** | 把 1.5 折进声明值（写 186.75 / -510 并删掉乘法）功能等价、风险低，但会让"一直在调的那两个数字"含义突变（现在填基准值，改后要填实际值），属于要同步调整调参习惯的改动。按当前优先级只标注。 |
| **验证"只有注释"** | `godot_validate_script` 通过；`decode_vector()` 的可执行体（`var c = 1.5 / max_speed *= c / jump_velocity *= c / _base_* = …`）逐行未变；两处 `var` 声明的代码部分仍是 `= 124.5` / `= -340.0`；89/89 冒烟断言全绿。 |
| **将来要改（含彻底消除问题 2）** | 删掉 `decode_vector()` 的乘法，把 `max_speed / jump_velocity` 直接写成运行时值（`186.75 / -510.0`）并在检查器里调（两者现在已是 `@export`，见 D12）；同时让 `decode_vector()` **幂等**（例如仅在 `_base_* == 0` 时初始化），这样重复调用也不再叠乘。注意不变量：`_base_* == 未叠加玩家缩放的运行时值`（`refresh_motion_scale()` 依赖它）。 |

### 1.9 ✅ 已实施：D7 / D9 / D11 / D12 / D13 / D14 六项批量重构

> 这一批是「把死亡表现移出玩家 + 清掉遗留耦合 + 补齐可调参数」的合并改造。
> 冒烟测试从 89 条扩到 **130 条**，并新增了**中断哨兵**（见下）。

| 编号 | 问题 | 处置 | 验证 |
| --- | --- | --- | --- |
| **D7** | `direction_change()` 每帧调 `set_knip()` + `set_expression()`，`set_expression` 每帧重写同一个 `AtlasTexture.region`；并且用 `eyes.expression.blink` 通过**实例**取枚举 | `eye.gd`：新增 `enum Face` + `current_expression`，`set_expression()` 改成**幂等**（同表情直接 return），`set_knip()` 与表情**职责拆分**（只管眨不眨）；表情→区域的映射收敛到 `_region_for()`。`player.gd`：`direction_change()` 拆成 `_update_facing()` + `_update_eyes()`，枚举改用 `preload` 常量 `Eye.Face.BLINK`（不用 `class_name`：全局类名依赖编辑器生成的 `.godot/global_script_class_cache.cfg`，无头运行解析不到） | 幂等用**行为**直接验证：人为把 region 改坏 → 同表情再调一次 → region 必须原样保留；换表情时确实重写。另加 `set_knip` 不动表情的两条断言 |
| **D9** | 玩家内嵌 `WorldEnvironment`，`deal("god")` 改它的 `Environment`；同场景多实例会互相影响，且 `gl_compatibility` 下 glow 无效果 | `player.tscn` 删掉 `WorldEnvironment` 与 `Environment_qrs7h`；`player.gd` 删掉 `environment` 引用与全部 glow 代码 | 断言语义：玩家子树里**没有任何** `WorldEnvironment`（递归查找），且死亡不动任何 Environment |
| **D11** | `deal(anim_name:String)` 字符串 match；`_on_button_button_up()` 把 UI 按钮**直接连到玩家脚本**（`jump!` 的 `playertest.tscn:315` 真的连了它）；死亡后无完成事件、无复位 API，关卡只能 tween 到硬编码 `Vector2(258,95)` | 换成信号化 API：`enum DeathKind {HURT, ASCEND}` + `signal died(kind)` / `signal respawned` + `die(kind)` / `respawn()` / `respawn_at(at)`；`die()` 幂等；`freeze_on_death` 可关。**删掉 `deal()` 与 `_on_button_button_up()`**，UI 改由关卡接信号 | `died` 恰好 emit 一次、重复 `die()` 不重复广播、`respawn_*` 逐项清状态、`freeze_on_death=false` 时不冻结。另断言旧方法已不存在 |
| **D12** | 除 `eyes_mode` 外没有任何 `@export` | 按 `@export_group` 分组导出 **15 个**手感参数（`max_speed` / `jump_velocity` / `gravity` / `acceleration` / `ground_friction` / `max_jumps` / `coyote_time` / `jump_buffer_time` / `eye_offset` / `eye_follow_speed` / `eye_aim_speed` / `air_drag` / `air_control` / `in_place_epsilon` / `eyes_mode`）；顺手把两处魔数（`3.4`、`2.34`）提成参数。**运行行为逐位不变**（默认值即原值），且按你的决定**保留了 `decode_vector()` 的 ×1.5** | 反射遍历 `get_property_list()` 断言 15 个参数都带 `PROPERTY_USAGE_EDITOR`；130 条断言（含缩放/阻力/跳跃高度数值）全部不变 |
| **D13** | `dirrction_dev` 拼写错误；`player_direction` 语义靠注释；"向左时 x 取反"是隐式约定 | `dirrction_dev` → `eye_offset`；`player_direction` → `facing`（1 右 / -1 左）；取反不再就地改值，改成 `_eye_target_offset()` 里显式 `absf(eye_offset.x) * facing` | 断言旧名不存在、新名存在；"眼睛偏移随朝向翻转"原有断言继续通过 |
| **D14** | 28 帧 1440×1080 烟雾（≈2.2MB）内嵌在玩家场景 | `player.tscn` 删掉 `smoke` 节点与 `SpriteFrames_xub4p`（连带删掉只服务于它的 `AudioStreamPlayer`）。**素材文件保留在 `assets/fx/`、`assets/audio/`**，供特效层或将来使用 | 断言：玩家场景无 `AnimatedSprite2D`、加载玩家场景后 `mist_01.png` 与受伤音效**不在资源缓存**里、素材文件本身仍存在 |

**顺带修掉的测试可信度缺陷（重要）**：这一批改造中测试曾在 `_death_animation.add_animation(...)`（Godot 3 的 API）处抛运行时错误，
但 harness 仍然打印「118/118 通过」并返回退出码 0 —— 因为脚本错误让协程中断、`_run()` 提前返回，
而 `_report()` 照常汇总了「已跑过的」断言。现在加了**完整性哨兵**：

```gdscript
var _completed := false          # 只有 _run() 跑到最后才置位
func _report() -> void:
    if not _completed:           # 中途被截断 → 直接判失败
        _failures += 1; _checks += 1
        printerr("  [FAIL] 测试被中途中断，没有跑完全部用例 —— 本次结果不可信")
```

已实测验证：故意不置位时输出 `130/131 通过，1 失败` 且**退出码 1**。

---

## 2. 目标架构

```
                    ┌──────────────────────────────┐
   输入              │  PlayerInputSource（可注入）   │
   ─────────────►   │  Human / Scripted / Recorded  │
                    └──────────────┬───────────────┘
                                   │ InputFrame{axis, jump_pressed, aim_target}
                    ┌──────────────▼───────────────┐
   逻辑              │  PlayerController            │
   ─────────────►   │  · PlayerMotion（纯运动学）    │
                    │  · JumpState（土狼/缓冲/计数）  │
                    │  · PlayerState（normal/dead）  │
                    └──────┬───────────────┬───────┘
                           │ 信号           │ 视口偏移
                    ┌──────▼──────┐  ┌─────▼──────────┐
   表现              │ PixelEye    │  │ DeathFx（按需）  │
                    │ 状态机+帧率  │  │ 独立子场景/资源   │
                    │ 无关插值     │  └────────────────┘
                    └─────────────┘
```

关键边界：

- **逻辑不碰 `Input`**，只消费 `InputFrame`。
- **逻辑不发命令给表现**，只发信号（`facing_changed` / `state_changed` / `died`）。
- **表现不读逻辑内部状态**，只响应信号与显式参数。
- **环境效果（glow）属于关卡**，不属于玩家；玩家只广播 `died(kind)`。

---

## 3. 分阶段改造路线

### 阶段 1 —— P0：纯内部重构（不改手感，可随时回滚）

> 完成标准：冒烟测试 **136 条断言全绿**（无需修改断言），并用新增断言覆盖 D1/D7。
> D2 不在本阶段改动范围（已决定只加注释，见 §1.7）。

#### P0-1 ✅ 已实施：修掉 `chiler` 末帧的 `null`（D1）

实际采用的就是当初评估的**最小修复**（保留 `play_backwards`，只换末帧值）：

```diff
# scenes/eyes.tscn → Animation_aqb7g → tracks/0 (TextureRect:texture)
-"values": [SubResource("AtlasTexture_c6fh2"), SubResource("AtlasTexture_i4qtv"), SubResource("AtlasTexture_7sjra"), null]
+"values": [SubResource("AtlasTexture_c6fh2"), SubResource("AtlasTexture_i4qtv"), SubResource("AtlasTexture_7sjra"), SubResource("AtlasTexture_c6fh2")]
```

- **实测**：`null` 帧数 **3 → 0**；眨眼序列变为 睁眼（保持）→ 闭眼 → 半闭 → 睁眼；
  位置轨道仍回到 `0`；结束后 `TextureRect.texture` 仍等于脚本缓存的图集。
- **验收**：第 [7] 组新增 4 条断言，逐帧扫描一次完整眨眼（见 §1.6）。
- **未做**：`eye.gd` 未改动 —— 当初设想的 `play_blink()` 正向播放方案经评估后**放弃**，
  因为改成正向还必须给位置轨道补 `t=0.158 → (0,0)` 的键（否则眼睛永久低 1.26px），
  且会改变已调好的观感。保留为可选后续。

#### P0-2 ✅ 已处置：眼睛插值帧率相关（D2）—— 只写注释，不改行为

**决定：代码保持原样，问题写进 `eye.gd → lerp_position()` 的函数注释。**

理由：下面这个改法本身风险很低，但会改变 60fps 之外的既有观感，属于手感改动，
需要高低帧对照验证（见下方验收标准）；在没有做该验证之前按当前优先级保留原行为。
注释里已经写清问题、两个调用点、帧率对照、将来要改的具体写法与两个坑。

```gdscript
## 60fps 下的每帧收敛比例 alpha，换算成任意 delta
static func _smooth(alpha_60: float, delta: float) -> float:
    return 1.0 - pow(1.0 - alpha_60, delta * 60.0)

position = position.lerp(target_pos, _smooth(alpha_60, delta))
```

保持 `alpha_60 ≈ 0.057`（即当前 60fps 手感）作为默认值。

- **两个坑**（已写进注释）：① 调用点目前已经乘过 `delta`（`3.4 * delta`），改造时要去掉，
  否则会二次缩放；② `lerp_position()` 需要能拿到 `delta`（新增参数，或由调用点传"基准比例 + delta"）。
- **若将来要做**：新增断言 —— 让眼睛从 0 走向 `dev=1`，在 60Hz 与 144Hz 下
  0.5s 后的位移相差 < 5%；改为 `alpha_60` 后需重跑全部 89 条断言确认 60fps 下数值等价。
- **风险**：低（60fps 下数值等价），但属于观感改动。

#### P0-3 ✅ 已实施：眼睛表情状态机 + 去掉每帧写入（D7）


> ✅ **已实施** —— 实际做法、取舍与验收见 **§1.9**。下面的原始方案仅作历史记录。

```gdscript
# eye.gd
enum Expression { DEFAULT, BLINK_LEFT, BLINK_RIGHT, BLINK, DIE }
var expression: Expression = Expression.DEFAULT

func set_expression(face: Expression) -> void:
    if face == expression:
        return                 # ← 幂等，杜绝每帧重写 region
    expression = face
    _apply_region(face)
```

`player.gd` 改用 `eye.set_expression(PixelEye.Expression.BLINK)`。

- **验收**：连续 60 帧设为同一表情，`AtlasTexture.region` 的写入次数 == 1（可在测试里打桩计数）。
- **风险**：低。但注意 `AnimationPlayer` 的 method track 通过 `set_expression(3)` 传整数，
  改成 enum 后需同步 `player.tscn` 里 `Animation_88p7a` / `Animation_gdqmq` 的 method track 参数
  （当前传的是 `[4]` 与 `[3]`，换成 enum 后仍是合法 int，无需改；但建议改成常量名以免顺序漂移）。

#### P0-4 眼睛初始化兜底（D8）

```gdscript
func _ready() -> void:
    assert(body != null, "PixelEye.body 未设置：请在场景里把 body 指向宿主 Sprite2D")
    _refresh_body_size()
```

并支持运行时换 body：把 `body` 的 `@export` 加上 setter，setter 内重算 `b_size` 与 `margin`。

- **验收**：`body` 为空时给出明确报错，而不是静默每帧重跑 `_ready()`。

#### P0-5 ✅ 已实施：死亡事件化 + 复位 API（D11）


> ✅ **已实施** —— 实际做法、取舍与验收见 **§1.9**。下面的原始方案仅作历史记录。

```gdscript
signal died(kind: StringName)
signal respawned

enum DeathKind { GOD, STEVE }

func die(kind: DeathKind) -> void:  ## 旧 deal(String) 的替代，保留 deal() 作为兼容包装
    if is_dead: return
    is_dead = true
    state = State.DEAD
    _play_death_anim(kind)
    died.emit(DeathKind.keys()[kind].to_lower())

func respawn(at: Vector2) -> void:
    position = at
    velocity = Vector2.ZERO
    current_velocity = Vector2.ZERO
    jump_count = 0
    is_deal = false
    state = State.NORMAL
    deal_player.stop()
    respawned.emit()
```

**删掉 `_on_button_button_up()`**（UI 耦合），由关卡用自己的按钮连接 `player.die(...)`。
`levels/level_1.gd` 的硬编码 `Vector2(258,95)` 改为监听 `died` 后调用 `player.respawn(spawn_point)`。

- **验收**：`died` 在 `deal("steve")` 后恰好 emit 一次；`respawn()` 后 `is_deal == false`、
  可再次受重力与输入影响、`deal_player.stop()` 已停止。
- **风险**：中（回灌 `jump!` 时需同步改 `level_1.gd`）。建议保留 `deal()` 与 `is_deal` 作为兼容层一个版本。

#### P0-6 ✅ 已实施：参数 `@export` 化（D12，共 15 个参数）

> ✅ **已实施** —— 见 **§1.9**。注意：按你的决定，`decode_vector()` 的 ×1.5 **刻意保留**，
> 所以检查器里调的是「基准值」，运行时仍会被 ×1.5（D5 见 §1.8）。

> **D5 已按"只写注释"处置**（见 §1.8）：本节的 `@export` 化与"删掉 `decode_vector()`"仍未实施，
> 但 D5 这个子问题已经标注清楚，不再作为待办跟踪。

```gdscript
@export_group("Movement")
@export var max_speed: float = 186.75         # 直接写运行时真实值（当前声明值是 124.5，会被 ×1.5）
@export var acceleration: float = 0.5
@export var ground_friction: float = 0.83
@export_group("Jump")
@export var jump_velocity: float = -510.0
@export var max_jumps: int = 1
@export_range(0.0, 0.5) var coyote_time: float = 0.07
@export_range(0.0, 0.5) var jump_buffer_time: float = 0.1
@export_group("Eyes")
@export var eyes_mode: EyesMode = EyesMode.MOVE
@export var eye_offset: Vector2 = Vector2(0.68, -0.636)   # 原 dirrction_dev
```

**删除 `decode_vector()`**：把 ×1.5 的乘积直接写进默认值（见上面的 186.75 / -510.0），
这样检查器显示值 == 运行时值 == 可调值。同时让初始化变**幂等**，消除重复 `_ready()` 叠乘的坑（§1.8 问题 2）。

- **验收**：在检查器里改 `jump_velocity`，跳跃高度按 `v²/2g` 线性变化；
  连续调用 `_ready()` 三次后 `max_speed` 不再变化（当前实测会 ×3.375）。

#### P0-7 重命名与类型化（D13 / D16）—— D13 ✅ 已实施，D16 待做

> ✅ D13（`dirrction_dev`→`eye_offset`、`player_direction`→`facing`、取反显式化）已实施，见 **§1.9**。
> ⚠ D16（`class_name` / 类型签名）**未做**：`class_name` 依赖编辑器生成的全局类缓存，
> 在无编辑器的无头运行里解析不到，因此改用 `preload` 常量 + 类型化成员变量（见 `player.gd`）。

- `dirrction_dev` → `eye_offset`；新增 `facing: int` 替代 `player_direction`，并把取反收敛到 `_update_facing(dir)`。
- `player.gd` → `class_name PlayerController`；`eye.gd` → `class_name PixelEye`。
- 外部改用 `@export var player: PlayerController` 注入，删除 `$player/player/eyes` 硬路径（源项目 `test_scen.gd` 同步改）。

- **验收**：`player_system/tests/player_smoke_test.gd` 里不再出现 `get_node("player/eyes")` 之类硬路径。

---

### 阶段 2 —— P1：手感对齐（需要数值/录像 A/B）

> 前置条件：阶段 1 已完成，且已用脚本采集**基线运动曲线**（每 1/60s 的 `position/velocity`，
> 输入序列为"右移 1s → 松 → 左移 1s → 跳 → 空中右移"）。
> 每个改动都要把新曲线与基线做 diff，**人工确认差异是"修正"而不是"手感变了"**。

#### P1-1 重写空中/地面水平运动（D3/D4）

```gdscript
func _apply_horizontal(input_dir: float, delta: float) -> void:
    var target := input_dir * max_speed
    if is_on_floor():
        current_velocity.x = _approach(current_velocity.x, target, acceleration, delta)
        if is_zero_approx(input_dir):
            current_velocity.x *= ground_friction          # 0.83/帧 → 也改成帧率无关
    else:
        current_velocity.x = _approach(current_velocity.x, target, air_control, delta)  # air_control ≈ 0.35
    current_velocity.x = clampf(current_velocity.x, -max_speed, max_speed)

## 帧率无关的指数逼近
static func _approach(current: float, target: float, alpha_60: float, delta: float) -> float:
    return lerpf(current, target, 1.0 - pow(1.0 - alpha_60, delta * 60.0))
```

同时**删除 `current_velocity.x *= air_resistance`**（D4），把 `air_resistance` 改名为 `air_drag`
（默认 1.0，即不生效）或直接移除。

- **验收**：
  1. 地面从静止到达 `0.9 * max_speed` 的时间与基线一致（±1 帧）；
  2. 空中"转向到反向 90% 速度"的时间成为**显式可调参数**，不再是 `0.7` 的副产物；
  3. 全程 `|velocity.x| <= max_speed`；
  4. 松手后 `|velocity.x|` 单调递减（新增断言）。
- **风险**：中高 —— 这正是"手感"的核心。务必保留基线曲线，允许回退到旧公式仅作为开关
  （`@export var legacy_air_motion := false`）。

#### P1-2 跳跃状态机（D6）

```gdscript
class JumpState:
    var grounded := false
    var coyote_left := 0.0
    var buffer_left := 0.0
    var used := 0

# 关键：grounded 的更新放到 move_and_slide() 之后
func _physics_process(delta: float) -> void:
    ...
    move_and_slide()
    _jump_state.grounded = is_on_floor()   # ← 消除"同帧读旧值"
```

`_process` 里只做表现（眼睛），`_physics_process` 里只做运动学。

- **验收**：新增断言覆盖
  1. 落地帧之后 1 帧内 `jump_count == 0`（不再需要测试里那句"多等一帧"的注释）；
  2. 离地 0.07s 内按跳仍可起跳（土狼时间）；
  3. 落地前 0.1s 内按跳，落地后立即起跳（缓冲）；
  4. 缓冲一旦被消耗即清零，不得触发第二次起跳；
  5. 连续 3 次"贴地按跳"的起跳间隔方差 < 1 帧。
- **风险**：中。

---

### 阶段 3 —— P2：能力扩展（按需求排期）

#### P2-1 输入源抽象（D10）

```gdscript
class_name PlayerInputSource extends RefCounted
func poll(_delta: float) -> InputFrame:
    return InputFrame.new()

class_name HumanInputSource extends PlayerInputSource   # 现有 Input.* 行为的等价搬迁
class_name ScriptedInputSource extends PlayerInputSource # 供测试/过场/AI
class_name RecordedInputSource extends PlayerInputSource # 录制回放
```

- **验收**：用 `ScriptedInputSource` 无人值守复现一条固定轨迹，
  与 `HumanInputSource` + `Input.action_press` 产生的轨迹逐帧一致（新增断言）。
- **收益**：过场动画、教学关卡、AI 敌人复用同一套运动学；回放可用于回归比对。

#### P2-2 ✅ 已实施：环境效果从玩家剥离（D9）


> ✅ **已实施** —— 实际做法、取舍与验收见 **§1.9**。下面的原始方案仅作历史记录。

- 玩家只 emit `died(kind)`；`Environment` 的 glow 由关卡/后处理管理器响应。
- 若确实需要玩家自带环境效果，则 `_ready()` 里 `environment.environment = environment.environment.duplicate()`
  避免多实例共享。
- **验收**：同场景实例化 2 个玩家，A 触发 `die(GOD)`，B 的 `environment.glow_enabled` 仍为 `false`。

#### P2-3 ✅ 已实施：死亡特效移出玩家场景（D14）

> ✅ **已实施** —— 见 **§1.9**。做法比原方案更彻底：不是「按需加载」而是**整个移出玩家场景**，
> 素材文件保留在 `assets/fx/`、`assets/audio/`，由特效层按 `died(kind)` 自行决定要不要用。

- 抽出 `death_fx/fx_steve.tscn`（28 帧 `SpriteFrames` + 音效），玩家场景只保留 `Node2D` 挂点。
- 关卡在加载时用 `ResourceLoader.load_threaded_request()` 预取，`die(STEVE)` 时实例化。
- **验收**：不触发死亡的对局中，玩家场景的 `SpriteFrames` 资源未被加载
  （可用 `ResourceLoader.has_cached()` 断言）；死亡首帧无卡顿（帧时间 < 20ms）。

#### P2-4 眼睛位移改为显式像素意图（D15）

- 引入 `@export var eye_travel: Vector2 = Vector2(4, 2)`（像素，整数），
  由它决定 `max_offset`，而不是从 `player.png` 的尺寸推导；
  `margin` 退化为"像素留白"，或直接由 `eye_travel` 与眼睛图尺寸算出。
- 偏移量取整（`floorf`）保证像素完美。
- **验收**：`eye_offset == (1, -1)` 时眼睛相对瞳孔中心的位移 == `(4, -2)` 像素，整数值。
- **风险**：低（纯视觉），但需美术确认"眼睛该动多远"。

#### P2-5 杂项清理

- `scenes/end_credits/end_credits.tscn` 里 `main_menu_scene = "res://scenes/player/player.tscn"`
  —— 把玩家场景当主菜单场景，疑似遗留错误，回灌时顺手核对。
- `levels/level_1.gd` 的玩家复位坐标 `Vector2(258,95)` 改为场景里的 `Marker2D` 出生点导出。

---

## 4. 验收与回归

### 4.1 自动化

```bash
# 子系统冒烟测试（本仓库可直接跑）
godot --headless --path "L:\项目\测试" player_system/tests/player_smoke_test.tscn
# 期望：exit 0，且输出 "136/136 通过" 起（每个阶段会递增）
```

每个阶段新增的断言建议：

| 阶段 | 新增断言 |
| --- | --- |
| ✅P0-1 | 已落地（第 [7] 组 4 条）：逐帧扫描一次眨眼，`TextureRect.texture` 全程非 null、切换 ≥3 种图集区域、结束后与脚本缓存一致、表情仍可切换 |
| ✅P0-2 | 已处置（不新增断言）：D2 只写注释、不改行为，见 §1.7；若将来改造，验收为 60Hz/144Hz 下 0.5s 位移差 < 5% |
| ✅P0-3 | 已落地（第 [7] 组 6 条）：幂等用**行为**验证——把 region 人为改坏后同表情再调一次必须原样保留；换表情时必须重写；`set_knip` 不再动表情 |
| ✅P0-5 | 已落地（第 [10] 组 19 条）：`died` 恰好一次、`die()` 幂等、`respawn_at()` 逐项清状态、`respawn()` 回出生点、`freeze_on_death` 开关、复位后可继续游玩 |
| P1-1 | 松手后 `|velocity.x|` 单调递减；全程不超 `max_speed` |
| P1-2 | 落地后 1 帧内计数归零；缓冲只生效一次；起跳间隔方差 < 1 帧 |
| ✅P2-2 | 已落地：玩家子树里没有任何 `WorldEnvironment`（递归查找），死亡不再触碰任何 Environment |
| ✅P2-3 | 已落地：玩家场景无 `AnimatedSprite2D`；加载玩家场景后 `mist_01.png` / 受伤音效都**不在资源缓存**里；素材文件仍存在 |
| ✅D17 | 已落地（第 [8] 组 14 条）：缩放线性放大三项参数、跳跃高度线性、滞空不变、相对体型高度不变、缩回还原、开关可关、负缩放不反向 |

### 4.2 人工

1. `demo/player_sandbox.tscn` 走一遍：移动、跳跃、贴墙、上坡、空中转向、两种眼睛模式、
   `F`/`G` 触发 `die(HURT/ASCEND)`（玩家不再有任何死亡表现，沙盒把信号打到屏幕上）、`R` 复位。
2. 回灌后在 `jump!` 里跑 `test/player/playertest.tscn` 与 `levels/level_1.tscn`。
3. **主菜单必测**：`main_menu/main_menu_with_animations.tscn` 里玩家实例上有 `eyes_mode = 0` 的覆盖值，
   而 `EYES_MODE { look_at = 0, move = 1 }` —— 即主菜单用的是 **look_at（望鼠标）**模式。
   任何调整枚举成员顺序的改动都会静默改变主菜单表现，属于破坏性变更。

---

## 5. 回灌到 `jump!` 的流程

1. 在 `player_system/` 内完成并跑绿冒烟测试。
2. 反向搬运（`tools/extract_player_system.py` 的 `FILES` 表反向执行即可，或手工按 README 的对照表覆盖）：
   `scripts/ → scipts/player/`、`scenes/ → scenes/player/`、`assets/ → assets/{player,steve_anim,FIX}/`。
3. **uid 未变**，因此 `levels/level_1.tscn`、`main_menu/main_menu_with_animations.tscn`、
   `test/player/playertest.tscn` 中的 `ext_resource uid="uid://q6asbxlf23qt"` 等引用无需改动。
4. **本次重构新增的必改外部接线点**（回灌 `jump!` 时必须同步改）：
   - `test/player/playertest.tscn:315` 的 `[connection signal="button_up" from="CanvasLayer/Button" to="player" method="_on_button_button_up"]`
     —— `_on_button_button_up()` **已被删除**，这个连接会报错；改成关卡侧接 `player.died` 并调用 `player.die(...)`。
   - 任何调用 `player.deal("steve"/"god")` 的地方 → `player.die(DeathKind.HURT / ASCEND)`。
   - 任何读 `player.is_deal` 的地方 → `player.is_dead`。
   - 任何读 `player.player_direction` / `player.dirrction_dev` 的地方 → `player.facing` / `player.eye_offset`。
   - 任何引用 `$Deal_Player` / `$smoke` / `$WorldEnvironment` / `$AudioStreamPlayer` 的地方
     —— 这些节点**已从玩家场景移除**（`Deal_Player` 改名为空的扩展点 `DeathAnimation`）。
   - `levels/level_1.gd:56-61` 里把 `player.position` tween 到硬编码 `Vector2(258,95)` 的复位写法
     → 改成 `player.respawn_at(出生点)`（或接 `died` 信号后调用）。
5. 原来的外部调用点（同样需要同步）：
   - `levels/level_1.gd:56-61` —— 改用 `died` 信号 + `respawn(spawn)`；
   - `test/player/test_scen.gd:9-10` —— 改用 `@export var player: PlayerController`；
   - 主菜单 `eyes_mode = 0` 的覆盖值 —— 枚举顺序若变，必须同步。
5. 在 `jump!` 里跑 4.2 的人工回归；对比 `JUMP!.apk` 旧包行为。
6. 提示：两个项目不要在编辑器里同时打开同名 uid 的资源，避免 uid 缓存互相污染。

---

## 6. 优先级总表

| 编号 | 标题 | 阶段 | 影响面 | 风险 | 预估 |
| --- | --- | --- | --- | --- | --- |
| **D1** | **`chiler` 末帧 `texture=null`（眨眼 3 帧消失）** | ✅ **已实施** | 表现 | 低 | 已完成 |
| **D5** | **隐藏 ×1.5（保留）/ 重复调用叠乘（已修）** | ✅ **已修复叠乘；×1.5 按决定保留** | 调参正确性 | 低 | 已完成 |
| **D2** | **眼睛插值速度帧率相关** | ✅ **已处置**（注释标注，不改） | 高刷/移动端手感 | 低 | 已完成 |
| **D7** | **表情每帧重写 + 实例取枚举** | ✅ **已实施** | 性能/可读性 | 低 | 已完成 |
| D8 | `_ready()` 当兜底 | P0 | 健壮性 | 低 | 0.5h |
| D16 | 无 `class_name`/类型 | P0 | 可维护性 | 低 | 1h |
| **D12** | **参数非 `@export`** | ✅ **已实施**（D5 仍单独保留） | 调参效率 | 低 | 已完成 |
| **D13** | **`dirrction_dev` 拼写/隐式约定** | ✅ **已实施** | 可读性 | 低 | 已完成 |
| **D11** | **死亡无事件/无复位 API** | ✅ **已实施** | 关卡集成 | 中 | 已完成 |
| D3 | 空中移动公式误用 `ground_friction` | ✅ **已随 D18 解决** | **手感** | 中高 | 已完成 |
| D4 | `air_resistance` 语义反转 | ✅ **已随 D18 解决** | **手感** | 中 | 已完成 |
| D4b | **`ground_friction` 是死参数** | ✅ **已修复**（接上，默认值取原字面量 0.83） | **手感** | 低 | 已完成 |
| D6 | 跳跃缓冲/土狼时间耦合 | P1 | **手感** | 中 | 4h |
| D10 | 输入硬编码 | P2 | 扩展性 | 中 | 4h |
| **D9** | **玩家内嵌环境效果** | ✅ **已实施** | 多实例正确性 | 中 | 已完成 |
| **D14** | **烟雾 2.2MB 常驻** | ✅ **已实施** | 加载/内存 | 低 | 已完成 |
| D15 | 眼睛位移受限贴图尺寸 | P2 | 观感 | 低 | 2h |
| **D17** | **缩放不影响运动** | ✅ **已实施** | 手感 / 体型系统 | 低 | 已完成 |
| **D18** | **空中阻力方向与原地起跳例外** | ✅ **已实施** | 手感 / 空中控制 | 中 | 已完成 |
**建议排期**：先做完整 P0（约 1 天，纯内部、零手感风险、立刻拿到可回归基线），
再用一段独立时间做 P1（必须配录像 A/B），P2 按功能需求插空。

### 1.10 ✅ 已实施：清理批次「值得修」的四项（D6 结构 / D5 幂等 / D4b 死参数 / 死节点）

> 原则：**只做结构整理，不改任何手感数值**。验收靠原有断言**逐条不变**地继续通过。

| 项 | 原状态 | 处置 | 验证 |
| --- | --- | --- | --- |
| **D6** | `_physics_process` 是 51 行 / 38 行有效代码的上帝函数，同一函数里裸调 4 次 `is_on_floor()`，帧边界语义隐式 | 拆成 `_update_vertical()`（土狼/缓冲/起跳/顶头/重力）+ `_update_horizontal()`（地面加速+摩擦 / 空中阻力+操控），主流程只留调度；`grounded` 在帧首缓存一次并写明「这是上一帧 `move_and_slide()` 之后的值」。**严格保持原执行顺序**（尤其「重力在起跳之后」） | 原有的跳跃高度 `116.4 → 232.9`、起跳速度 `-438.1`、松手衰减 `-0.84` 等断言数值**逐条不变** |
| **D5（问题 2）** | `decode_vector()` 是乘法，重复调 `_ready()` 会叠乘（第三次 ×3.375），无报错 | 重命名为 `_initialize()` 并加 `_initialized` 守卫 → 幂等；出生点也不再被覆盖。**×1.5 本身按你的决定保留**（问题 1） | 新增断言：连续两次 `_ready()` 后 `max_speed` 保持 `186.75`、`jump_velocity` 不变、`spawn_position` 不变 |
| **D4b** | `ground_friction` 能导出、能调、**完全不生效**（地面写死字面量 `0.83`） | 接上地面分支，**默认值取原字面量 0.83**（而不是那个从未生效的 0.237），因此行为不变 | 新增断言：`ground_friction=1.0` 时残余速度 186.8（不减速）、`=0.2` 时残余 0.00（迅速刹停）、默认值 == 0.83 |
| 死节点 | `eyes.tscn` 里有个从未被引用的 `Label` | 删除（`eye.gd` 里 grep 不到 `Label`） | 场景仍正常加载，眨眼/表情断言全绿 |
| 顺手 | `eye.gd` / `player_smoke_test.gd` / 两份 md 是 CRLF，其余是 LF | 全部统一为 LF（与源项目一致） | 纯字节层面，无行为影响 |

**仍未做的部分**：D6 的**帧边界语义**本身（`is_on_floor()` 由 `move_and_slide()` 更新，落地帧读到上一帧的值）
没有改 —— 消除它属于手感改动，需要跳跃状态机整体重排（P1-2）。这一批只让它从「隐式」变成「显式且有注释」。
