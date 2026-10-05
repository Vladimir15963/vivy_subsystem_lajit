# 测试 —— Godot 子系统试验场

一个把若干个**待验证子系统**装进同一个 Godot 4 工程的「试验场」。每个子系统都尽量做到
**自带素材、自带场景、自带测试、边界清晰**，可以单独跑、单独改、单独回归，验证通过后再回灌到正式项目。

本文件是**总览与索引**；每个子系统的细节在各自的 `README.md` / `docs/` 里，本文只做归纳、地图与现状汇总。

---

## 1. 环境与启动

| 项 | 值 |
| --- | --- |
| 引擎 | Godot **4.7.2** stable（`L:\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe`，见 `.vscode/settings.json`） |
| 渲染器 | `gl_compatibility`（Windows 下 `d3d12` 驱动） |
| 物理 | 3D 用 `Jolt Physics`；2D 默认 |
| 主场景 | `res://scene_loader_test/demo/boot.tscn` → 读条 → 演示主菜单 |
| 窗口 | `embed_subwindows=false`（每个 `Window` 都是**真实 OS 窗口**）、`per_pixel_transparency/allowed=true` |
| 画布纹理过滤 | `default_texture_filter=0`（Nearest）—— 像素美术（`player_system`）**依赖这一条** |
| 类名解析 | 依赖 `.godot/global_script_class_cache.cfg`；刚克隆下来先 `godot --headless --import` 或用编辑器打开一次 |

### 三种跑法

```powershell
# ① 交互运行整个项目（= F5，进入 SceneLoader 演示流程）
godot --path "L:\项目\测试"

# ② 交互运行某个场景（= F6，例如战斗/沙盒/终端演示）
godot --path "L:\项目\测试" battle_system/battle_test.tscn

# ③ 无头跑测试（推荐；退出码 0 = 全绿，非 0 = 有失败）
godot --headless --path "L:\项目\测试" player_system/tests/player_smoke_test.tscn
```

> 在 DSH 里请用 `godot_run_headless` / `godot_run_project` / `godot_screenshot` 等 `godot_*` 工具，
> **不要**用 pwsh/bash 直接起 Godot（文件沙箱会拦掉 `user://` 写入，进程以 signal 11 崩溃）。

---

## 2. 全局注册表（`project.godot`）

**Autoload**

| 名字 | 来源 | 作用 |
| --- | --- | --- |
| `VivdWindowsNode` | `res://vivd_windows/vivd_windows.tscn` | 多窗口演出管理器 |
| `Game` | `uid://beqi0010skth0`（`battle_system/scripts/game.gd`，类名 `GameState`） | 进度状态机 / 战斗入口 |
| `SceneLoader` | `res://scene_loader_test/scene_loader.gd` | 读条加载 / 预加载 / 转场切场景 |
| `Dialogic` | `uid://ds2q0uclmolvu` | Dialogic 2 插件单例 |
| `McpInteractionServer` | `res://autoload/mcp_interaction_server.gd` | 交互服务器，默认监听 `127.0.0.1:9090`（DSH `godot-bridge` 用） |

**输入动作**：`move_left`(A/摇杆) / `move_right`(D/摇杆) / `jump`(空格/手柄下键) / `dialogic_default_action`(Enter/空格/X/鼠标左键)

**编辑器插件**：`addons/dialogic`、`addons/godot_xterm`

---

## 3. 目录总览

| 目录 | 规模（GDScript / 场景 行） | 一句话 |
| --- | --- | --- |
| `autoload/` | 4418 / — | `McpInteractionServer`：TCP JSON 命令服务器（4893 行），外部工具驱动游戏用 |
| `vivd_windows/` | 1895 / 214 | **多窗口演出系统**：按类型动态开关真实 OS 窗口，移动/缩放/淡入淡出/调方法 |
| `battle_system/` | 1830 / 202 | **回合制战斗系统**：状态机 + 技能结算 + txt 存档 + 可继承 UI 基类 |
| `player_system/` | 1081 / 134 | **玩家实例子系统**：从 `jump!` 剥离的移动/跳跃/眼睛/死亡，自带素材与沙盒 |
| `fake_terminal/` | 838 / 60 | **伪终端**：不依赖 PTY，纯 GDScript 写 `godot_xterm` 的 `Terminal` 节点 |
| `scene_loader_test/` | 759 / 317 | **通用场景加载器**：启动读条、后台预加载、可指定转场的切场景 |
| `web3forms_test/` | 342 / 8 | **Web3Forms 表单客户端**：一次性邮件提交接口 + 手点面板 |
| `system_test_1/` | 64 / 39 | 历史遗留：旧版 vivd_windows 演示（已被取代，见 §5） |
| `lajitest/` | 39 / 20 | 草稿：`godot_xterm` 的 PTY 直连试验（跑 `ping google.com`） |
| `dialogic/` | — / — | Dialogic 2 剧本资源（第一幕时间线 + 人物） |
| `chapter/` | — / — | 单文件剧本草稿 `test_1.ks` |
| `assets/` | — / — | 顶层公共素材（`0.png` / `DSniang1.png` / `test.webp`） |
| `script_templates/` | 14 / — | 编辑器模板：`Window/vivd_window.gd`（新建窗口类型用） |
| `_backup/` | — / — | 备份 + `.gdignore`（Godot 完全跳过，不会产生重复 uid/类名） |
| `addons/` | — / — | 第三方插件：`dialogic`、`godot-vlc`（≈593 MB，含多平台）、`godot_xterm` |

---

## 4. 各子系统

### 4.1 `scene_loader_test/` —— SceneLoader

不依赖任何插件的通用场景加载工具，autoload 名 `SceneLoader`（脚本类名 `SceneLoaderService`，避免与 autoload 撞名）。

- **启动读条**：`SceneLoader.boot_to(path)` —— 立刻显示读条界面，加载完自动进入。项目主场景 `boot.tscn` 就是干这个的。
- **后台预加载**：`preload_scene(path)` 走线程加载，`preload_progress` 信号直接喂进度条；重复调用幂等。
- **切场景**：`goto_scene(path, options)` —— `transition` 可选内置 `loading` / `fade` / 自定义 / `null`（无缝），`min_time` 是「转场最短显示时间」而不是加载时间。
- **数据传递**：`options.params` → 新场景的 `on_scene_entered(params)` 或 `scene_params` 属性。

细节见 [scene_loader_test/README.md](scene_loader_test/README.md)，截图在 `scene_loader_test/_shots/`。

### 4.2 `vivd_windows/` —— 多窗口演出系统

核心心智模型：`types/*.tscn` 是**模板**，`add_window()` 造**实例**，之后所有操作按名字找实例。

- 内置 6 种窗口类型：`default` / `image` / `file_examin`（文件拖放）/ `text`（正文阅读、可选逐字显示）/ `video`（双后端）/ `terminal`（接 `fake_terminal`）。
- **视频双后端**：`.ogv` 走 Godot 内置 Theora（0 MB），其余走 `godot-vlc` 的 LibVLC（Windows 运行时 +202 MB），插件缺失自动退回内置且报错清晰。选型实测见 [vivd_windows/VIDEO.md](vivd_windows/VIDEO.md)。
- 基类白送：`setup/teardown` 生命周期、淡入淡出、置顶、dev 调试浮层、关闭按钮自动注销。
- 已知限制：`Window` 不是 `CanvasItem`，**没有 `modulate`**（淡入淡出作用在内容子节点上）；headless 下 Godot 强制 `embed_subwindows=true`，因此无头测试验证的是管理器逻辑而非真实 OS 窗口观感。

文档：[README.md](vivd_windows/README.md)（概览+迁移表）、[USAGE.md](vivd_windows/USAGE.md)（1028 行使用手册）、[FEATURES_PLAN.md](vivd_windows/FEATURES_PLAN.md)（13 项规划）、[VIDEO.md](vivd_windows/VIDEO.md)。

### 4.3 `player_system/` —— 玩家实例

从正式项目 `jump!`（「梦与日记」）**逐字节剥离**出来的玩家实例子系统，自带素材/场景/沙盒/测试，目标是「玩家只管我一举一动，不负责怎么演」。

- **运动**：移动、跳跃（土狼时间 / 跳跃缓冲 / 禁二段跳）、眼睛（偏移插值、瞄准、眨眼、表情）、死亡与复位。
- **本次剥离做的功能改动**（其余问题按「只加注释」处置，详见 `docs/IMPROVEMENT_PLAN.md`）：
  - **缩放补偿**：`scale` 放大 N 倍时同步放大 `max_speed` / `jump_velocity` / `gravity`，让「跳几个自己那么高」不变；纯视觉挤压请关 `scale_affects_motion`。
  - **空中阻力重构**：删除反向的 `air_resistance`，改为沿**朝向反方向**衰减的 `air_drag`，并加了「原地起跳整段滞空忽略阻力」的例外。
  - **眨眼贴图修复**（纯数据，改 `eyes.tscn` 一个末帧值）：原来每次眨眼有连续 3 帧整只眼睛没有贴图，现为 0 帧。
  - **死亡表现移出玩家**：`player.tscn` 从 475 行瘦到 28 行，`deal(String)` → `die(DeathKind)` + `died` 信号，`DeathAnimation` 是空的扩展点（放同名动画就自动播，不用改代码）。
- **仍存在的已知问题**：隐藏 ×1.5 倍率保留（`max_speed` 检查器显示 124.5 → 运行时 186.75）、眼睛插值帧率相关（仅注释）、输入直接轮询全局 `Input`（无法 AI 接管）。

跑沙盒演示：`godot --path "L:\项目\测试" player_system/demo/player_sandbox.tscn`（`A/D` 移动、空格跳、`Q` 切眼睛模式、`[`/`]` 缩放、`F`/`G` 触发两种死亡）。

### 4.4 `battle_system/` —— 回合制战斗

四项要求的极简实现：进入战斗 / 打断战斗（暂停·继续·结束）/ 基本战斗（技能·目标·AI）/ txt 读写。

- **状态机**：`GameState.progress_status` = `EXPLORE → BATTLE ⇄ BATTLE_PAUSED → BATTLE_ENDED → EXPLORE`，变化走 `progress_status_changed` 信号。
- **伤害/治疗**：`max(1, 威力 + 攻击 - 防御)` / `威力 + 攻击/2`（不超上限）。
- **目标解析**（重点）：传 `null` 或传**站错阵营**的目标都会被自动修正 —— 选敌人点治疗不会给敌人加血，选队友点攻击不会误伤。
- **数据**：`data/characters.txt` + `data/skills.txt`（INI 风格），运行时可保存到 `user://battle_system_test/`。
- **UI 基类** `BattleUIBase`：用继承场景 + 改 `party_ids`/`enemy_ids` 就能开一场战斗，可重写 `build_party` / `build_enemies` / `on_refresh` / `on_battle_finished` / `next_think_delay` 钩子。样例：`battle_test`（本地 Game）、`battle_variant_hard`（重写钩子）、`battle_global`（接全局单例 `/root/Game`）。

细节见 [battle_system/README.md](battle_system/README.md)。

> 入口场景：`battle_test.tscn`（基础）、`battle_variant_hard.tscn`（变体）、`battle_global.tscn`（全局单例）。
> 该模块曾因目录重命名导致内部 `res://` 路径全部失效、5 个入口场景都无法加载，现已修复（见 §6.1）。

### 4.5 `fake_terminal/` —— 伪终端

在 `godot_xterm` 的 `Terminal` 节点上实现的「假终端」：**不依赖 PTY、不起子进程**，所有输出由 GDScript 直接以 UTF-8 写入，因此中文不会乱码、内容 100% 可控（打字的动画、进度条、彩色 ANSI、假命令都能精确编排）。

- `fake_terminal.gd`（`class_name FakeTerminal`）：ANSI 16 色、`println` / `println_colored` / `type_line`、`register_command(...)` 注册假命令、未知命令回调。
- 三个演示：`demo.tscn`（全中文 + 颜色 + 打字机 + 进度条 + 假命令）、`fake_terminal.tscn`（裸节点）、`vivd_terminal_demo.tscn`（作为 `vivd_windows` 的 `terminal` 窗口打开，**会弹一个独立 OS 窗口**）。
- 配套 `lajitest/` 是**真** PTY 那一路的草稿（`pty.fork("ping", ["google.com"])`），用于对比。

### 4.6 `web3forms_test/` —— 表单提交

在 Godot 里调 [Web3Forms](https://docs.web3forms.com/getting-started/api-reference) 的最小实现 + 可手点的测试面板（`web3forms_test.tscn`，F6 运行）。

- 两种接口都实现了：Access Key 方式（`access_key` 放请求体）与 Form ID 方式（`submit/{FORM_ID}`）。
- 状态码 200 / 303 / 400 / 429 / 500 都有处理；**303 不自动跳转**（`max_redirects=0`，跳转地址给到 `redirect_url`）。
- 实测过一次真实提交：HTTP 200，邮件送达；错误 key → 400、不存在的 Form ID → 500 均能正确落到 `submit_failed`。
- **未实现附件**（PRO 功能，且需要换成低层 `HTTPClient` 状态机）。

细节见 [web3forms_test/README.md](web3forms_test/README.md)。

### 4.7 `dialogic/` + `chapter/` —— 剧本

- `dialogic/`：Dialogic 2 的**第一幕**时间线（`timelines/01第一幕.dtl`，166 个事件 = 107 条台词 + 48 注释 + 5 背景 + 5 信号 + 1 结束）与 6 个人物资源。转写规则、`\` 换行的实测结论、「一行一句、每行都写角色」的取舍，以及需要游戏代码接管的 `event:*` 信号清单都在 [dialogic/README.md](dialogic/README.md)。
- `chapter/test_1.ks`：单文件剧本草稿，暂未接入任何播放器。

### 4.8 `system_test_1/` —— 历史遗留（**已被取代**）

旧版 `vivd_windows` 的演示场景（`test.tscn` / `game_start.tscn` / `test_bink_start.gd`）。
其管理器和窗口类型实现已搬到 `vivd_windows/`，旧实现整体备份在 `_backup/vivdwindows_20261001_132735/`（带 `MANIFEST.txt` 与 sha256）。

这里只剩下两个用途：**真实 OS 窗口观感的人工演示**（headless 看不出多窗口效果），以及
`res://system_test_1/VID20250306230957.mp4` —— 它被 `vivd_windows` 的视频测试当作 mp4 素材使用，**不要删**。

### 4.9 `autoload/mcp_interaction_server.gd`

4893 行的 TCP JSON 命令服务器，作为 autoload 常驻，默认监听 `127.0.0.1:9090`。
DSH 的 `godot-bridge` 通过它执行 `eval` / `screenshot` / `get_scene_tree` / 输入模拟等命令。
它使任何一次运行都会打印 `McpInteractionServer: Listening on 127.0.0.1:9090` —— 这是正常的，不是测试输出。

---

## 5. 测试矩阵（实测）

四个带断言的自动化套件，全部用 `<子目录>/tests/*.tscn` 或根级 `*_smoke_test.tscn` 作为入口，
**headless 全绿退出码 0**：

```powershell
godot --headless --path "L:\项目\测试" player_system/tests/player_smoke_test.tscn
godot --headless --path "L:\项目\测试" scene_loader_test/tests/scene_loader_smoke_test.tscn
godot --headless --path "L:\项目\测试" vivd_windows/vivd_smoke_test.tscn
godot --headless --path "L:\项目\测试" battle_system/tests/battle_logic_test.tscn   # 见下方 ⚠️
godot --headless --path "L:\项目\测试" battle_system/tests/battle_ui_test.tscn      # 见下方 ⚠️
```

| 套件 | 断言 | 实测结果 | 覆盖重点 |
| --- | --- | --- | --- |
| `player_system/tests/player_smoke_test.tscn` | **136** | ✅ **136/136 通过**（退出码 0） | 场景装配、重力落地、移动钳制、跳跃与土狼/缓冲、眼睛表情与眨眼（含 D1/D7 回归）、缩放补偿、空中阻力 12 种场景、死亡与复位、初始化幂等 |
| `scene_loader_test/tests/scene_loader_smoke_test.tscn` | **42** | ✅ **42/42 通过**（退出码 0） | 转场注册表、场景可加载可实例化、预加载进度与幂等、失败分支、转场切换（`min_time` / `params`）、无缝切换耗时、缓存释放、启动读条 |
| `vivd_windows/vivd_smoke_test.tscn` | **101** | ✅ **101/101 通过**（退出码 0，`SMOKE_RESULT=PASS`） | 创建与配置、错误路径、6 种窗口类型、视频双后端、文本窗口滚动与逐字、移动缩放、淡入淡出、dev 浮层、移除与泄漏（`weakref`）、类型注册 |
| `battle_system/tests/battle_logic_test.tscn` | **80** | ✅ **80/80 通过**（退出码 0） | 逻辑：txt 读写往返、伤害/治疗公式、目标阵营校验、暂停阻断、全灭结算、AI 决策 |
| `battle_system/tests/battle_ui_test.tscn` | **53** | ✅ **53/53 通过**（退出码 0） | 界面：基类可实例化、`%唯一名` 全解析、导出覆盖、三个生命周期钩子、AI 等待时间取值 |

合计 **412 条断言全绿**。

**非自动化**（需人工点）：

| 入口 | 说明 |
| --- | --- |
| `web3forms_test/web3forms_test.tscn` | 面板手点发请求，看服务端返回原文 |
| `fake_terminal/demo.tscn` / `vivd_terminal_demo.tscn` | 伪终端演示；后者会弹独立 OS 窗口 |
| `vivd_windows/window_type_test.tscn` | 窗口类型手工试验场 |
| `system_test_1/test.tscn` | 旧版多窗口观感演示 |
| 整个项目 F5 | `boot.tscn` → 读条 → 演示主菜单（四个按钮分别演示读条转场/预加载/无缝/淡入淡出） |

**headless 噪音（正常，不是失败）**：`vivd_smoke_test` 会输出几条故意的 `ERROR`/`WARNING`（测错误路径用），
以及满屏 `godot-vlc: audio buffer full`（headless 的假音频驱动没人消费音频，见 `VIDEO.md`）。

---

## 6. 已知问题

### 6.1 ✅ 已修复：`battle_system/` 的内部路径曾全部指向 `res://battle_system_test/`

> **状态：已修复并验证（80/80 + 53/53 全绿）。** 下面保留记录，因为这是本工程最典型的一类坑。

症状：目录名是 `battle_system/`，但目录内的场景与脚本仍写着 `res://battle_system_test/...`，
**14 个文件、46 处引用**失效，该模块的 5 个入口场景**全部无法加载**
（`Parse Error: [ext_resource] referenced non-existent resource at res://battle_system_test/...`）。

| 文件 | 曾失效的引用数 |
| --- | --- |
| `battle_system/ui/battle_ui_base.gd` | 4（`ROW_SCENE`、`data_dir`、`save_dir`、注释） |
| `battle_system/tests/battle_ui_test.gd` | 5 |
| `battle_system/tests/battle_logic_test.gd` | 4 |
| `battle_system/scripts/battle_data.gd` | 2 |
| `battle_system/battle_global.gd` / `battle_global.tscn` | 1 / 2 |
| `battle_system/battle_test.tscn` / `battle_variant_hard.tscn` | 2 / 2 |
| `battle_system/tests/*.tscn`（2 个） | 各 1 |
| `battle_system/ui/battle_ui_base.tscn` / `character_row.tscn` | 各 1 |
| `battle_system/scripts/game.gd` | 1 |
| `battle_system/README.md` | 19（文档里的路径与示例同样过时） |

根因是**一次目录重命名没有连带更新引用**（数据文件与脚本逻辑本身一直都是好的）。

**修法**：把 14 个文件里的 `battle_system_test/` 按字节替换为 `battle_system/`（共 40 处，
`res://` 资源引用、`--path` 命令行示例、文档目录树一并更新）。两个刻意的保留：

1. **`user://` 存档目录名保持 `battle_system_test` 不动**（`save_dir` / `DEFAULT_SAVE_DIR` / `SAVE_DIR`）。
   它们不是失效引用（`user://` 目录按需创建），改名反而会孤立 `%APPDATA%\Godot\app_userdata\测试\battle_system_test\`
   下已有的 `characters.txt` / `skills.txt`。所以替换特意用负向后顾排除了 `user://` 前缀。
2. 替换按**原始字节**进行，不经过文本解码 —— 这样 `game.gd` 等含中文注释的文件编码不会被改写。

同类排查建议：全工程扫一遍 `res://` 引用是否落盘存在（**别忘了把 `addons/`、`.godot/` 也纳入"存在性"检查集**，
否则会得到一堆假阳性；`.import` 里的路径还会被文件名中的空格截断，需要额外过滤）。
`project.godot` 里的 autoload `Game` 用的是 `uid://beqi0010skth0` 而非路径，所以它**一直不受影响**。

### 6.2 其它

| 位置 | 问题 |
| --- | --- |
| `player_system` | 隐藏 ×1.5 倍率保留（检查器 `124.5` → 运行时 `186.75`）；眼睛插值帧率相关（144Hz 手感与 60Hz 不一致，仅注释未改）；输入直接轮询全局 `Input`，无法脚本化/AI 接管 |
| `player_system` | 死亡表现素材（28 帧烟雾 ≈2.2 MB + 3 段音频）仍留在 `assets/`，玩家场景已不加载它们，但导入开销还在 |
| `vivd_windows` | godot-vlc **v1.3.0 有 use-after-free**（libvlc 回调线程 vs 节点释放顺序，会 `abort` 整个进程）。工程已在 `video_window.gd` 的 `teardown()` 里让播放器比窗口多活 0.5 秒规避，升级到带 `is_instance_valid` 的版本后可撤掉 |
| `vivd_windows` | `Window` 无 `modulate`，整体透明度只能作用在内容子节点；文件拖放只在真实窗口下有效（headless 收不到） |
| `web3forms_test` | 不支持附件（需改用低层 `HTTPClient`） |
| 工程级 | 部分脚本（`fake_terminal/*.gd`、`system_test_1/*.gd`）源文件是 **GBK** 编码，用 UTF-8 工具读会乱码；改这些文件前先确认编码，别把整个文件写成 UTF-8 |
| 工程级 | 没有 git 仓库（`.git` 不存在），回滚只能靠 `_backup/` |

---

## 7. 约定与经验

这些约定是这几个子系统共同踩出来的，新加模块时建议照做：

1. **autoload 名 ≠ `class_name`**。同名会被 Godot 拒绝（`Class "X" hides an autoload singleton`）。所以是 `SceneLoader`(autoload) / `SceneLoaderService`(类名)、`Game`(autoload) / `GameState`(类名)。
2. **跨子系统引用优先用 `preload` 路径而不是全局类名**。全局类名依赖编辑器生成的 `.godot/global_script_class_cache.cfg`，在刚克隆、CI、无编辑器的无头运行里可能解析不到。`player_system` 与 `vivd_windows` 都刻意用了路径式 `extends` / `const X = preload(...)`。
3. **子系统的核心脚本不 `preload` 插件、不引用工程里别的模块**，这样能被单独拷走、单独测试（`vivd_windows` 的视频窗口是这条底线的样板：只用 `ClassDB` 动态探测，插件不在就退回内置解码器，一行都不用改）。
4. **测试入口一律是 `.tscn`，退出码 0/1 表达通过/失败**，便于 CI 与 `godot_run_headless` 直接判定。
5. **数值型断言动态读取基准值**，不要在测试里写死 `435` / `-900` 之类 —— 否则调参就会误报失败（`player_system` 第 8 组起已改成这样）。
6. **测试要带完整性哨兵**：如果某段代码让协程中断、用例没跑完，必须判失败并返回退出码 1，而不是只汇总「已经跑过的那部分」。
7. **`_backup/` 里放一个 `.gdignore`**，Godot 会完全跳过该目录，不会产生重复 uid 或重复类名。

---

## 8. 备份与回滚

| 备份 | 内容 |
| --- | --- |
| `_backup/vivdwindows_20261001_132735/` | 旧版 `vivd_windows` 实现（原 `system_test_1/` 全套 + `script_templates/Window/`）的原样拷贝，含 `MANIFEST.txt`（逐文件 sha256） |
| `_backup/project_godot_before_forward_plus_20261002_003317/` | 切换渲染器之前的 `project.godot` |

`_backup/.gdignore` 使 Godot 完全跳过该目录。

---

## 9. 文档索引

| 文档 | 内容 |
| --- | --- |
| [battle_system/README.md](battle_system/README.md) | 战斗系统：状态机、目标解析规则、UI 基类与钩子、txt 格式、运行方式 |
| [player_system/README.md](player_system/README.md) | 玩家子系统：依赖边界、缩放补偿、空中阻力、眨眼修复、死亡 API、回灌清单 |
| [player_system/docs/IMPROVEMENT_PLAN.md](player_system/docs/IMPROVEMENT_PLAN.md) | 逐条问题诊断（D1–D18）与分阶段改造方案、验收标准 |
| [scene_loader_test/README.md](scene_loader_test/README.md) | SceneLoader：完整 API、options 字段、转场接口约定、设计要点 |
| [vivd_windows/README.md](vivd_windows/README.md) | 多窗口系统概览、快速开始、API 速查、旧版迁移对照 |
| [vivd_windows/USAGE.md](vivd_windows/USAGE.md) | 1028 行使用手册：心智模型、生命周期、config 全键、Cookbook、FAQ |
| [vivd_windows/VIDEO.md](vivd_windows/VIDEO.md) | 视频双后端选型、体积实测、三个候选插件的实测淘汰记录、排查表 |
| [vivd_windows/FEATURES_PLAN.md](vivd_windows/FEATURES_PLAN.md) | 13 项后续功能规划（按性价比排序） |
| [web3forms_test/README.md](web3forms_test/README.md) | 表单客户端：两种接口、返回字典字段、303 处理、实测记录 |
| [dialogic/README.md](dialogic/README.md) | 第一幕剧本的转写规则、`\` 换行实测结论、需接管的 `event:*` 信号 |
