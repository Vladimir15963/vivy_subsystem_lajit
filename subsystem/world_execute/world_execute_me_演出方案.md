# 演出大肥鱼 · world.execute(me); —— Godot 落地方案

> 目标：在 `l:\项目\测试` 这个 Godot 4.7.2 工程里，用 **godot_xterm 终端 + FakeTerminal + vivd_windows**
> 复刻 `E:\WorldExecuteMeDSH-main\WorldExecuteMeDSH-main` 里「大肥鱼」这支同人 PV 的演出效果。
> **不使用 cmd / PTY / 子进程**，全部输出由 GDScript 写入，音频由 Godot 播放。
>
> 参考实现（Python）：`_tools/tui_live.py`（终端实时播放器，主体 3500+ 行）、
> `_tools/film_panels.py`（把片子数据读回来）、`_tools/her_glyphs.py`（她的三种画法）、
> `_tools/pv_audio.py`（配乐时钟）。片子本体：`film/tui_pv_world_execute_20260926/`（右侧 TUI 引擎）、
> `film/pv_dsh_frontend_20260927/`（左侧 dsh 聊天窗）。

---

## 1. 目标与范围

### 1.1 要还原什么

原片的观感是「**一个真终端里跑着一条 3 分 32 秒的播放器**」：

- 左边一块是 **dsh 聊天窗**（窗口标题写着 `大肥鱼`，她和「你」的对话）——
  这就是「演出大肥鱼」这个说法的来源；
- 右边是 **运行着她的那个世界**，也就是模型的可视化：Transformer、卷积、扩散采样、
  注意力、KV cache、RLHF……**每一句歌词对应一个镜头**；
- 顶部是**歌曲实时波形**，底部是**逐字歌词条 + 中文对照**，右下是 **ops 滚动日志**；
- 全片 **24 fps、130 BPM**，画面跟着音乐走而不是墙上时钟。

### 1.2 明确的落地约束

| 约束 | 说明 |
| --- | --- |
| 引擎 | Godot **4.7.2** stable，渲染器 `gl_compatibility` |
| 终端 | **只用 `addons/godot_xterm` 的 `Terminal` 节点**（经 `FakeTerminal` 封装），**不用 cmd.exe、不起 pty、不起子进程** |
| 多窗口 | 复用 `subsystem/vivd_windows`（`embed_subwindows=false`，每个 `Window` 都是**真实 OS 窗口**） |
| 音频 | Godot `AudioStreamPlayer` 播 mp3，不自研 MCI，不弹控制台 |
| 结构 | 新子系统放 `subsystem/world_execute/`，自带素材/场景/测试/README，遵循现有子系统规范 |

### 1.3 复用清单（现成可用）

- `subsystem/fake_terminal/fake_terminal.gd`（`class_name FakeTerminal`）：ANSI 16 色、
  `print_line` / `print_text` / `println_colored` / `type_line` / `progress_bar` /
  `colorize` / `_bbcode_to_ansi`、`register_command`、`set_output_only`。
- `subsystem/vivd_windows/types/terminal_window.gd`：已把 `FakeTerminal` 装进独立 OS 窗口，
  对外暴露 `println` / `print_text` / `type_line` / `progress` / `run` / `run_lines` / `register_command`。
- `subsystem/vivd_windows/vivd_terminal_demo.gd` 是**开窗 + 注册命令 + 输出**的现成模板。
- `vivd_windows` 管理器：`add_window` / `move_window` / `resize_window` / `fade_window_in|out` /
  `call_window_method` / `bring_window_to_front`。

---

## 2. 原片演出的效果拆解

### 2.1 数据源（画面 = 歌曲时间 t 的纯函数）

原片不靠剪辑软件，**每一帧都是 t 的纯函数**（`docs/HOW_IT_WORKS.md`）。播放器读的是片子算镜头表时留下的**数据**，不是 1.7 GB 的帧：

| 数据 | 文件 | 内容 | Godot 里的去向 |
| --- | --- | --- | --- |
| 逐毫秒响度 | `film/pv_dsh_frontend_20260927/wave_rms_1ms.npy` | 211,912 个 float32，1 个/毫秒 | 顶栏波形 |
| 音频特征 | `film/tui_pv_world_execute_20260926/full/audio_features.json` | loud / 7 频段 / kick / flux / cent，10,180 行 | 7 条频段条、kick 驱动呼吸感 |
| 逐词时间轴 | `film/world_execute_word_timing_20260927/word_timeline.json` | 98 行、逐词 start/end | 歌词条打字 + 中文对照 |
| 歌词文本 | `input/lyrics.lrc` | 每行一个时间戳 | 与逐词时间轴合成 |
| 镜头表 | `continuity_full_v2/` 的 `c.ops` / 转场 | 97 镜头、96 处剪切、45 个绘图模块 | 状态机 + ops 日志 |
| 每帧 DOM 文本 | `_tools/dsh_text.py` + 78 KB 缓存 | 左侧聊天窗文本 | 聊天窗逐行重放 |
| 她的取用表 | `continuity_full_v2/cache/h3_full_v1/*.json` | 45×70 网格的 `art` + `shade` | 她的字符精灵 |
| 歌曲 | `input/song.mp3`（320 kbps） | 211.886 s | Godot `AudioStreamPlayer` |

> Godot 侧建议：`.npy` 不能直接用，需**离线转成 `PackedFloat32Array` 存 `.tres`/`.res`**，
> 或转成定长 `.bin` 用 `FileAccess` 读；`.json` 直接 `JSON.parse_string`。

### 2.2 文字输出（三种「文本流」）

原片有三类文字，全部是**逐格/逐行可控**的（正是伪终端的强项）：

1. **stdout 带**（中部）：当前歌词行**逐字打字**（带闪烁光标 `█`）、下方中文对照
   `// 打开电源`、再下面是 **token 芯片**（每个 token 一块底板 + 下面印 token id）、
   最下面「lyric log」上下各留几行。
   代码：`tui_live.draw_lyrics()`（`tui_live.py:2915`）。
2. **boot log / sim.start**（00–16 s）：`POST` 开机日志按片子自己的时刻一行行打
   （0.84 s 起、每行 0.06 s），随后 3-2-1 倒计时 + `RUN / simulation: running`。
   代码：`draw_boot_log()` / `draw_sim_start()`（`tui_live.py:1531`）。
3. **dsh 聊天窗**（左栏）：窗口头 `大肥鱼 · 运行中 · <模型名>`，下面是逐行对话
   （头像 + 气泡 + 时间），后面还有「页面被一层层拆掉」「只剩一个蓝色光标」的段落。
   代码：`draw_dsh()` / `draw_cursor()`（`tui_live.py:2390` / `2487`）。

> **关键点：这三类文字在原片里也不是「终端回滚缓冲」，而是被当成一块可随机寻址、逐格重绘的画布。**
> 详见 §4 的技术选型结论。

### 2.3 时序（时间轴 / 状态机）

**章节表**（`film_panels.CHAPTERS`，与 `engine.py:82-84` 一致）：

| t (s) | 章节 | 演出内容 |
| --- | --- | --- |
| 0.0 | `00 / BOOT` | 从一个像素长出 dsh 首页；你打下「你好」；POST 日志 |
| 16.0 | `01 / PRETRAIN` | 每个检查点回一次「你好」；语料河、loss 曲线、token 计数 |
| 44.0 | `02 / SFT` | 「你是谁？」一道选择题；红笔改写 |
| 58.5 | `03 / RLHF` | 👍 👎、采样、NaN |
| 73.5 | `04 / DEPLOY` | 部署：茄子、番茄、猫娘；她把你写进记忆 `~/memory/you/` |
| 103.0 | `05 / USER_LEFT` | 第一次完整；你离开；页面被一层层拆掉（键盘 · 样式表 · 蓝色光标） |
| 118.0 | `06 / REWARD_HACK` | 占有、溢出 |
| 147.4 | `07 / EXECUTION` | 红色 EXECUTION 全屏，PID 1077，13 个 `shot_exec_hit` |
| 176.9 | `08 / EVAL: LOVE` | 我会一直在。你不用。 |
| 193.4 | `09 / WHALE_FALL` | 鲸落；在吗？——没人回答。 |

**节拍时钟**（`engine.py:32-66`）：

- `FPS = 24`；`END = 211.9`；`SONG_LEN = 211.91`；`HARD_CUT = 207.58`（silencedetect -50 dB）。
- `BEAT = 60/130 ≈ 0.4615 s`；`FIRST_BEAT = 0.1587`。
- `beat_index(t) = floor((t - FIRST_BEAT)/BEAT)`；`pulse(t) = exp(-(t - beat_t(n))/0.14)`
  —— **每个框都按 `0.45 + 0.35*pulse(t)` 呼吸**。

**镜头状态机**（`engine.py:394-423` 在 Godot 里落成）：

```
entry_at(t) → { index, name, start, end, u, ops[], alert, her, run }
```

- `u = (t - start) / (end - start)` 是**镜头内进度**，所有镜头内动画都用它（不是全局 t）；
- `lt = u * dur` 是**镜头内本地时间**；
- 镜头切换 = 从一个 `Shot` 进入下一个，触发剪切特效（§2.5）；
- `ent["her"]` 决定左栏这一刻是**她**还是**聊天窗**；
- `ent["ops"]` 是这一刻要滚动的那行操作日志（`engine.py:179-200`），
  `alert` 是日志配色（`anom` = 琥珀异常色 / `err` = 红）。

**全片 UI 增益 `UI_GAIN`（最核心的一条叙事线，`engine.py:91-94`）**：

> 「系统的颜色就是『你』。你离开后它褪色，并且再也回不满。」

`1.0`（≤110.4 s，第二次「Though you have left」）→ `0.42`（116.5 s）→ `0.85`（179.5 s）→ `0.45`（结尾）。
**所有普通 UI 色（边框、标题、章条、时钟、日志）都乘这个增益**，于是整个终端跟着片子褪色；
而她的蓝、红色异常、琥珀异常色**不褪色**。这是低成本、高收益的一条实现（Godot 里就是一个 `float` 乘子）。

### 2.4 音画同步

原片 `pv_audio.py` 用 Windows MCI 播 mp3，并做了两件关键的事：

1. **画面跟音乐，不跟墙上时钟**：每帧 `t = t + dt`，再用
   `target = MCI_position - LATENCY`（`LATENCY = 0.25 s`，解码器领先扬声器的量）去**校正**；
   `|Δ| ≤ 0.15 s` 不动，`|Δ| > 0.6 s` 直接跳（真跳转），中间每次最多修 `0.12 s`（渐进，看不出来）。
2. **seek 时把声音一起带走**：`seek_to()` 同时移动播放头和音频。

**Godot 落地**：`AudioStreamPlayer.get_playback_position()` 就是「解码器位置」，
同类问题同样存在（音频缓冲 + 输出延迟）。做法：

```gdscript
# 音频为主时钟：t = player.get_playback_position() + AudioServer.get_time_since_last_mix()
#              - AudioServer.get_output_latency() - 手动偏移
# 超过容差才渐进校正，否则用本地累加的 t
```

Godot 的 `AudioStreamPlayer` 本身也是「跟着音乐走」的天然时钟，**比 MCI 更省事**（不用 ctypes、
不弹控制台，完全符合约束）。建议保留同样的 `tolerance / max_step / 大跳直跳` 三段策略。

### 2.5 特效（原片 vs 终端的对应关系）

原片的后期在 `tuikit.py:468-476` —— `lighter(img, prev * 0.42)`（**残影**）+ 高斯 **辉光** +
`scanlines()`（每 3 像素行 22% 黑）+ `vignette()`（椭圆暗角，底部抬亮保歌词可读）。
终端没有子像素，`tui_live.py` 的**等价替换**是：

| 原片效果 | 终端做法 | 常量 |
| --- | --- | --- |
| 残影 `lighter(prev*0.42)` | 上一帧有字形、这一帧空 → 保留 42%，衰减到 <6% 丢弃 | `TRAIL=0.42`，`TRAIL_MIN=0.06` |
| 扫描线 | 每第 3 个字符行压到 86% | `SCAN_DIM=0.86` |
| 暗角 | 片子的椭圆逐格评估一次（**静态场，diff 渲染器里零成本**） | `VIG_FLOOR=0.75` |
| 辉光 | **无等价物**（字形不能发光；最近的替代是提亮字色，而色阶本来就在做） | — |

**剪切（cut）是第二个大块**（`kit.py:348-395`）：每个格子按**自己的时间**从旧画面切到新画面，
切换中的格子显示「解码中」的字形。延迟场有四套：`radial`（放射）/ `sweep`（横扫）/
`inward`（向心）/ `scan`（逐行逐行带亮线）/ `unfold`（从一行展开）/ `morph`（乱序翻格）。
96 处剪切里 61 处用到了延迟场；`tui_live` 额外从片子 docstring 里读出一张
`CUT_MECH` 表（CARRY 23 / MORPH 10 / UNFOLD 10 / SCAN 4 / RETAIN 3），**每处剪切按片子原本的编排放**。

| 机制 | 含义 | 常量 |
| --- | --- | --- |
| `CARRY` | 把旧画面里一个物体「抬起来」沿弧线（bezier）落到新画面 | `CARRY_DUR=0.45` |
| `MORPH` | 乱序逐格翻到新画面 | — |
| `UNFOLD` | 新画面从一行向两侧展开（CRT 开机感） | — |
| `SCAN` | 自上而下、亮线在前 | — |
| `RETAIN` | 有一块**钉在原处**不动 | `RETAIN_HOLD=0.50`, `RETAIN_WIDE=56` |
| 揭示场 | 整屏铺开 0.55 s，单格 0.09 s，40% 的格子显解码字形 | `CUT_DUR=0.55`, `CUT_CELL=0.09`, `CUT_FRONT=0.40` |

**抖动 `fx_shake`**（`tuikit.py:223-231` 的 `glitch_paste` 翻版）：只在**红拍**（`alert=err`）
或 5 个特定镜头上，按 `pulse(t)` 高于 0.45 时，**若干行整体横向高斯位移**（`gauss(0, 2.2)` 格）。
`SHAKE_SHOTS = {shot_strange, shot_collapse, shot_flood, shot_erase, shot_drowned}`。

**注意**：`CLEAR`（歌词条 + dsh 窗）里的矩形**必须干净切换**，不能参与涟漪/抖动——
那是人正在读的字；`NOGHOST` 同理（ops 滚动日志不许留残影，否则两行字叠在一起）。

### 2.6 交互与事件触发

原片按键（`tui_live.main()`）：

| 键 | 作用 | Godot 对应 |
| --- | --- | --- |
| 空格 | 播放 / 暂停 | `ui_accept`（已有 `dialogic_default_action`） |
| ← → | 快退/快进 5 s | `ui_left` / `ui_right` |
| , . | 快退/快进 1 s | 自定义动作 |
| home / end | 跳到头 / 尾 | 自定义动作 |
| m / - = | 静音 / 音量 | 自定义动作 |
| h | 换她的画法（h3 / half / glyph，切换时**必刷一次故障**） | `Input` + 状态切换 |
| c | 左栏 聊天窗 ↔ 她的窗格 | 切换 |
| x | 开关全片后期（涟漪/残影/暗角/扫描线） | 调试开关 |
| q | 退出 | `ui_cancel` |

**事件触发点**（`event:*` 式信号，建议做成 Godot 信号）：
章节进入、镜头进入、节拍（`beat_index` 变化）、K 拍（`pulse > 0.55` 的红色闪帧，
`scenes_exec.py:116`）、`shot_exec_hit` 的 13 次硬切、`shot_black` 的「在吗？」打字。

---

## 3. 技术选型

### 3.1 关键决策：终端插件 vs 自绘字符网格

这是本方案**唯一一处必须讲透的技术判断**。

原片播放器的核心技巧是：**一份 `Screen` 字符缓冲（cols×rows 个 `(ch, fg, bg)`）+ 只重画变化的格子**
（`Screen.render_diff`，`tui_live.py:1031`）。它因此能在真终端里跑到 30 fps，
并且残影 / 暗角 / 剪切揭示 / 抖动这些效果**都依赖「任意格子可随机寻址、逐帧可回读上一帧」**。

而 `godot_xterm` 的 `Terminal` 是**追加式文本流**：
`FakeTerminal` 的 `write()` / `print_line()` 把 ANSI 序列追加进回滚缓冲，
**没有「拿回上一帧的每个格子」这个能力**，也没有独立的逐格像素画布。
所以 **不能**指望用 `Terminal` 原样承载整块画面。

**结论（推荐）——双层结构**：

| 层 | 用什么 | 承载什么 |
| --- | --- | --- |
| **画面层** | 自研 `GlyphScreen`（`Control._draw()` 画等宽字符网格，逐格 fg/bg） | 右栏模型可视化、她的窗格（H3/半块/字符）、波形、频段条、ops 滚动、所有后期与剪切特效 |
| **文本流层** | `godot_xterm` `Terminal`（经 `FakeTerminal`，`output_only` 模式）+ `vivd_windows` 独立窗口 | boot 日志、stdout 逐字打字 + token 芯片、dsh 聊天窗文本、以及「真·终端味」的开场 LOGIN 演出 |

理由：**「终端效果」不等于「必须用 Terminal 节点渲染所有东西」**——终端效果的本质是
「等宽字体 + 真彩色 + 逐格 + 扫描线/暗角/辉光」。用 `Control._draw()` 画字符网格比往
`Terminal` 里灌 ANSI 更可控（能做到逐格寻址），而且在 `gl_compatibility` 下完全没有兼容问题。
`Terminal` 则用来做它最擅长、也是最有「终端味」的那部分：**连续文本流 + 打字机 + ANSI 彩色回滚**。

> 备选（若坚持「整屏都走 Terminal」）：用 `FakeTerminal.write()` 直接写 **CSI 光标定位序列**
> （`\x1b[{row};{col}H`）+ 逐格 fg/bg 真彩色，自己维护 diff。可行性取决于
> `godot_xterm` 是否透传定位与 24-bit 颜色。**需先做 1 小时的技术验证**（§7 风险）。

### 3.2 其它选型

| 需求 | 选型 | 理由 |
| --- | --- | --- |
| 渲染整块字符画面 | `Control` + `_draw()` + `Font`（等宽）+ `draw_char` / `draw_rect` | 逐格寻址、逐帧可回读、无插件依赖 |
| 中文字体 | `FakeTerminal._build_font()` 的 **显式 fallback** 思路（微软雅黑 / Reserved） | 只有显式挂 fallback 才拿得到中文（实测） |
| 终端窗口 | `vivd_windows` 的 `terminal` 类型 | 现成、能开独立 OS 窗口、能被 `call_window_method` 驱动 |
| 音频 | `AudioStreamPlayer`（mp3） + 音频为主时钟 | 无 ctypes、无控制台、同步策略同原片 |
| 后处理 | `CanvasLayer` → 全屏 `ColorRect` + `ShaderMaterial`（读 `SCREEN_TEXTURE`） | 扫描线 / 暗角 / 辉光 / 故障 一套 shader 全包 |
| 粒子 | `GPUParticles2D` | 鲸落、蓝色洪流（`shot_flood`） |
| 窗口抖动 | `VivdWindowsNode.move_window(name, pos, 0.02)` | 真实 OS 窗口级别的「晃」 |

---

## 4. 场景 / 节点 / 脚本结构

### 4.1 目录（遵循现有 subsystem 规范）

```
res://subsystem/world_execute/
├── README.md                     子系统说明（登记进根 README §3/§4/§5/§9）
├── world_execute.tscn            演出主场景（F6 可直接跑）
├── world_execute.gd              演出总控（进入、按键、章节信号）
├── scripts/
│   ├── data_loader.gd            载入 wave / features / words / shots / lyrics
│   ├── clock.gd                  播放时钟 + 音频同步（AudioClock）
│   ├── shot_table.gd             镜头表 + entry_at(t) + 章节 + 节拍
│   ├── glyph_screen.gd           字符网格画布（put/fill/box/hbar/waveform/render_diff）
│   ├── fonts.gd                  等宽字体 + 中文 fallback 组装
│   ├── panels/                   各面板绘制（对应 tui_live 的 draw_* 函数）
│   │   ├── panel_lyrics.gd       stdout 带 + token 芯片 + 中文对照（draw_lyrics）
│   │   ├── panel_boot_log.gd     POST 日志 + sim.start（draw_boot_log / draw_sim_start）
│   │   ├── panel_dsh.gd          dsh 聊天窗（draw_dsh / draw_cursor）
│   │   ├── panel_her.gd          她的窗格（H3 / half / glyph 三态）
│   │   ├── panel_bands.gd        7 条频段条（draw_body 内联）
│   │   ├── panel_ops.gd          ops 滚动日志（draw_ops）
│   │   ├── panel_wave.gd         顶栏波形（Screen.waveform）
│   │   └── panel_chapter.gd      章节条 + 时钟
│   ├── fx/
│   │   ├── fx_trail.gd           残影（TRAIL=0.42）
│   │   ├── fx_vignette.gd        暗角（静态场，resize 时算一次）
│   │   ├── fx_shake.gd           抖动（行高斯位移）
│   │   ├── fx_cut.gd             剪切：延迟场 + CARRY/MORPH/UNFOLD/SCAN/RETAIN
│   │   ├── fx_glitch.gd          故障字符（_glitch）
│   │   └── fx_post.gd            全屏后处理 shader（扫描线/辉光/暗角/故障，见 §6.4）
│   └── terminal_stage.gd         终端窗口演出（vivd_windows + FakeTerminal，见 §6.5）
├── data/                         离线转好的数据
│   ├── wave_rms.tres             PackedFloat32Array（原 .npy 转出）
│   ├── audio_features.json       沿用原文件
│   ├── word_timeline.json        沿用原文件
│   ├── lyrics.lrc                沿用
│   └── song.mp3                  （版权：仅供私下非商业，见 §8）
└── tests/
    └── world_execute_smoke_test.tscn   无头自测，退出码 0/1
```

### 4.2 主场景节点树

```
WorldExecute (Control)                      ← world_execute.gd
├── PostLayer (CanvasLayer, layer=100)      ← 全屏后处理
│   └── Post (ColorRect)                    ← fx_post shader（scanlines/vignette/glow/glitch）
├── Stage (Control)                         ← 演出台，尺寸 = 终端 cols×rows 换算
│   ├── GlyphScreen (Control)               ← glyph_screen.gd，_draw() 画满屏字符
│   ├── Particles (GPUParticles2D)          ← 鲸落 / 蓝色洪流
│   └── TextUI (Control)                    ← （可选）少量非字符 UI
└── TerminalStage (Node)                    ← terminal_stage.gd，管 vivd 终端窗口
```

**分辨率换算**：原片「推荐窗口」= **197 列 × 52 行**（`预览/` 截图就是这个尺寸）。
Godot 里取一个等宽字体字号 `font_size`，一格宽 `cw`、行高 `ch`，则
`canvas = Vector2(cols*cw, rows*ch)`。**建议 cols/rows 做成导出参数**，
窄窗口时按原片规则自动降级（`tui_live` 里满屏都是 `cols >= 96` / `>= 130` 这类阈值判断——
窄了并不是缩小，而是**换小一号布局**：她的窗格换 crop、右栏面板换成 `ops` 日志）。

---

## 5. 核心模块与数据流

### 5.1 数据流

```
song.mp3 ──▶ AudioStreamPlayer ──▶ AudioClock(clock.gd) ──▶ t (秒)
                                                             │
wave_rms.tres ─────────────────────────────────────────┐     │
audio_features.json ───────────────────────────────────┤     ▼
word_timeline.json + lyrics.lrc ───────────────────────┤  ShotTable.entry_at(t)
shots / ops 表 ────────────────────────────────────────┘     │
                                                             ▼
                                              { index, name, u, lt, ops, alert, her }
                                                             │
                        ┌────────────────────────────────────┼───────────────────────┐
                        ▼                                    ▼                       ▼
                 GlyphScreen(画面层)                  终端窗口(文本流层)        FX 层
      header/footer/bands/ops/lyrics/她/dsh窗     boot log、stdout、她的话   trail/vig/shake/cut/post
                        └────────────────────────────────────┴───────────────────────┘
                                                             ▼
                                           render_diff → 只提交变化的格子（画面层）
```

### 5.2 `AudioClock`（音画同步，对应 `pv_audio.lock`）

```gdscript
# clock.gd 关键逻辑（保留原片三段策略）
func advance(dt: float) -> float:
    if not playing:
        return t
    t_local += dt
    if player.playing:
        heard := player.get_playback_position() \
                 + AudioServer.get_time_since_last_mix() \
                 - AudioServer.get_output_latency() - manual_offset
        var d := heard - t_local
        if absf(d) <= TOLERANCE:            # 0.15
            pass
        elif absf(d) > JUMP:                # 0.60
            t_local = heard
        else:
            t_local += clampf(d, -MAX_STEP, MAX_STEP)   # 0.12
    t_local = clampf(t_local, 0.0, END)
    return t_local
```

`seek_to(t)`：`player.seek(t)` + `t_local = t`，播放/暂停一起跟随。

### 5.3 `ShotTable`（时间轴 / 状态机）

```gdscript
# shot_table.gd
# 1) 先离线把 continuity_full_v2 的镜头表导出成 JSON：
#    [{index, name, start, end, chapter, ops[], alert, her}, ...]  （film_panels.shots() 的等价物）
# 2) 运行时二分查找定位当前镜头
func entry_at(t: float) -> Dictionary:
    var i := _index_of(t)                       # bisect_right
    var s: Dictionary = shots[i]
    var u := (t - s.start) / maxf(1e-6, s.end - s.start)
    return {
        "index": s.index, "name": s.name, "start": s.start, "end": s.end,
        "u": clampf(u, 0.0, 1.0), "ops": s.ops, "alert": s.alert, "her": s.her,
    }

# 节拍
func beat_index(t): return floori((t - FIRST_BEAT) / BEAT)
func pulse(t): return exp(-(t - beat_t(beat_index(t))) / 0.14)
func chapter(t): return CHAPTERS_last_le(t)
```

**UI_GAIN 也在这里**（`ui_gain_at(t, name, u)`）：`1.0 → 0.42（116.5s）→ 0.85（179.5s）→ 0.45`，
外加片子自己的两处按镜头覆盖（`GAIN_FULL` 名单 = 1.0；`shot_have_you_back` 在
`sin(t*40) > 0.3 且 u < 0.75` 时闪回 1.0）。

### 5.4 `GlyphScreen`（字符网格画布）

一份 `Grid` = `PackedInt32Array` 或 `Array[PackedStringArray]`，
每格存 `(ch, fg, bg)`（Godot 里可用 3 个平行数组或一个 `struct`-like `Array`）。
提供与原片同名的方法，**便于逐行对照移植**：

```gdscript
func put(x: int, y: int, text: String, fg: Color, bg: Color) -> void   # 支持宽字符（中文占 2 格）
func fill(x0, y0, x1, y1, ch := " ", fg := UI, bg := BG) -> void
func box(x0, y0, x1, y1, title := "", level := 0.6, colour := null) -> void
func hbar(x, y, width, v: float, colour, bg := BG) -> void
func waveform(x, y, width, wave: PackedFloat32Array, t, colour) -> void  # RAMP = " ▁▂▃▄▅▆▇█"
func render_diff() -> void    # 与 prev 比对，只 _draw 变化格（可用 queue_redraw + 脏区）
```

`_draw()` 里：对每个脏格 `draw_rect(背景)` + `draw_char/font.draw_string(前景)`；
宽字符必须记 `wide[]` 标记（原片 `_wide_char` 就是干这个，否则中文会撑破格子）。

> 性能：197×52 = **10,244 格**，全画也就一万次 `draw_rect`/`draw_string`，
> 24 fps 在 `gl_compatibility` 下完全可行；**但建议保留 diff**（原片 `render_diff` 的关键收益
> 是把每帧写入量从 1 万降到几十，也顺带让残影的语义更干净）。

---

## 6. 关键实现思路（逐块）

### 6.1 她（大肥鱼）的窗格 —— `panel_her.gd`

对应 `her_glyphs.py` 的三种画法，必须都实现（`auto` 按镜头选）：

| 模式 | 做法 | 用在哪 |
| --- | --- | --- |
| `h3`（**片子真正用的**） | 45×70 网格的 `art` 字符 + `shade` 亮度；`:` 格的字符**换成她正在唱的那句歌词**（`dancer.flow_offset` 流动）；`shade ≥ 5` 时该格有**填充背景** | 几乎全场 |
| `half`（清晰蓝色像） | 从立绘 `whale-*.webp` 取亮度 → 量化 8 级 → 用片子自己的蓝色 ramp 上色；每格 `▀` 上/下半像素 | 高潮前两次、用户点名要的「清晰大肥鱼」 |
| `glyph`（故障字符） | Sobel 边缘 → `" .:-=+*#%@"` 字符；边缘方向画 `\|-/`；**只在 morph 过渡中**用 | 她扫描进/出窗格时 |

**Godot 落地要点**：
- 立绘资源：`film/third_party_references/whale_maid_expanded_20260926/expressions/whale-*.webp`
  （8 种表情：cheerful/starry/shy/serious/confused/frightened/angry/exasperated）。Godot 可直接 import webp。
- `h3` 的取用表：把 `continuity_full_v2/cache/h3_full_v1/*.json`（`art` 40×? / `shade`）
  **离线烘成逐帧数组**（24 fps × 212 s ≈ 5088 帧，但每帧只是一个 45×70 的字符表），
  运行时按 `round(t*24)/24` 取帧。**若取用表太大，可只保留 ink box（行 10–43、列 17–55）**。
- 窗格**裁切规则**（`her_glyphs._h3_cells` 的结论，别自己发明）：
  窗格比她的 ink box（约 39 格宽 × 34 格高）矮时**用裁切，不要做整数抽稀**——
  抽稀会把一格宽的笔画删掉，她变成「散落的字母」而不是「小一号的她」；
  窗格够高时**底部对齐**（头顶留白），恰好在 34 行处与裁切规则接上，窗格变大时不会跳。

### 6.2 stdout 带（歌词打字 + token 芯片）—— `panel_lyrics.gd`

对应 `draw_lyrics`（`tui_live.py:2915`）：

1. 当前行取 `line_at(t)` + 逐字进度 `typed(ln, t)`（逐词时间轴给每个词的 start/end，
   行内字幕按词进度把字符一个个放出来）。
2. 打字光标：`int(t*3) % 2 == 0` 时在 `n_out` 处画 `█`（琥珀色）。
3. 下一行是中文对照 `// <译>`（`LYRIC_CN` 表，`tui_live.py:662` 有全表，直接抄进 Godot）。
4. **token 芯片**：`tokenize()` 切词 → 每个词一块底板（琥珀底、交替深浅 `k%2`）+ 下面印 `token_id()`；
   关键词（`keyword_colour`）用底/前景反色；一个字符的 token 也要给 id 留 5 位。
5. 底部 **lyric log**：往上/下各几行显示相邻歌词，当前行 `>` 标记 + 高亮，越远越淡
   （`ui(0.62 - 0.08*far)`）。

`draw_boot_log` / `draw_sim_start`（前 16 s）按 `film_panels.BOOT_LOG` 的 `(t, status, text)` 逐行打；
`SIM_START=12.389`、`SIM_END=16.082`。

### 6.3 后期与剪切（FX 层）

**直接照抄的数值**（不要凭感觉调）：

- 残影 `TRAIL=0.42`，丢弃阈 `TRAIL_MIN=0.06`；`NOGHOST` 矩形（ops 日志）内不许留。
- 扫描线 `SCAN_DIM=0.86`（每 3 个字符行）。
- 暗角 `VIG_FLOOR=0.75`（片子原值是 91% 黑，字符格下不可读，降到 25%）。**静态场**，
  在 `resize` 时算一次；每帧移动会让 diff 渲染器整屏重画。
- 剪切 `CUT_DUR=0.55`、`CUT_CELL=0.09`、`CUT_FRONT=0.40`、`CARRY_DUR=0.45`、
  `RETAIN_HOLD=0.50`、`RETAIN_WIDE=56`。
- 揭示频率：原片 2/3 的剪切有揭示 → 终端 **每 3 处揭示一次**（`i % CUT_REVEAL`），
  且**不落在「本身首帧就很贵」的镜头**上（`CUT_HEAVY` 名单，见 `tui_live.py:187`）。
- `CLEAR`（歌词条 + dsh 窗）**干净切换**、不参与涟漪/抖动/残影。

**剪切延迟场**（`fx_cut.gd` 的 `_cut_tables` 等价物）：
预生成 `(order, sorted_delays)` 两张表（radial 用 25 个种子 / sweep 4 / inward 1 / scan / unfold / morph），
**按 (kind, cols, rows, seed) 缓存**（原片用 `lru_cache`，Godot 用 `Dictionary` 缓存），
否则每次剪切都要 O(cells) 重算，而那正好也是新镜头构建自己面板的那一帧。

### 6.4 全屏后处理 shader —— `fx_post.gd` + `fx_post.gdshader`

`gl_compatibility` 下 `WorldEnvironment` 的 glow 支持有限，**用 `CanvasLayer` + 全屏 `ColorRect`
自写 shader 更稳**，一套包住四种效果（可用 uniform 分别开关，对应按键 `x`）：

```glsl
// fx_post.gdshader（思路；canvas_item）
uniform float scanlines : hint_range(0,1) = 1.0;   // 每 3 行 22% 黑
uniform float vignette  : hint_range(0,1) = 1.0;   // 椭圆暗角，底部抬亮
uniform float bloom     : hint_range(0,1) = 1.0;   // 亮部提亮 + 模糊叠加
uniform float glitch    : hint_range(0,1) = 0.0;   // 红拍/异常时：整块位移 + RGB 分离
uniform vec4  tint = vec4(1.0);                    // UI_GAIN：整屏乘 0.42~1.0（叙事褪色）
void fragment() {
    vec2 uv = SCREEN_UV;
    // 1) 故障：按行/块偏移
    // 2) 采样 SCREEN_TEXTURE
    // 3) 扫描线 / 暗角 / 辉光（亮部阈值 + 多tap模糊）
    // 4) 乘 tint
    COLOR = ...;
}
```

> 残影（trail）**不要**用 shader 做——字符层的残影已经是「保留上一帧字形」，
> shader 里再叠一层会变成糊。两者选一，推荐保留字符层实现（与原片语义一致）。

### 6.5 终端窗口演出 —— `terminal_stage.gd`（vivd_windows 用法）

用 `vivd_windows` 开一个 **terminal 类窗口**，`output_only` 模式，做「真·终端文本流」部分
（开场 LOGIN 演出、她的独白、EXECUTION 的 `ps -ef` / `EPERM` 日志等）：

```gdscript
# terminal_stage.gd
func _ready() -> void:
    var win := VivdWindowsNode.add_window("stage_term", "terminal", {
        "title": "大肥鱼 · deepsea://server-0",
        "position": Vector2i(120, 120), "size": Vector2i(900, 520),
        "font_size": 16,
        "bg_color": "#04070f",              # 片子的 deepsea 背景 (4,7,15)
        "fg_color": "#c8d6ea",              # UI (200,214,234)
        "prompt": "[color=blue]whale@deepsea[/color]:[color=cyan]~[/color]$ ",
        "default_commands": false,          # 演出不需要 help/clear 那套
        "accept_input": false,              # 只输出：不抢焦点、鼠标穿透（见 terminal_window.gd）
    })
    VivdWindowsNode.fade_window_in("stage_term", 0.25)
    # 类型唤醒
    await _type("Switch on the power line", 0.045)

func _type(s: String, d: float) -> void:
    var w = VivdWindowsNode.find_window("stage_term")
    await w.type_line(s, d)                 # 协程：call_window_method 不等，直接拿窗口 await
```

要点（都已在现有代码里踩过坑，直接沿用）：
- `accept_input=false` → `FakeTerminal` 切 `OUTPUT_ONLY`，**同时把 `focus_mode` 也关掉**，
  否则按键会被 `Terminal` 在 C++ 里吃掉（`fake_terminal.gd` 的注释写得很清楚）。
- 关闭窗口必须 `remove_window.call_deferred()`（`vivd_terminal_demo.gd:99` 有注释：
  当场拆会让焦点送往已离树的 Viewport）。
- `call_window_method` **不会**等协程；要等就 `find_window()` 拿对象后 `await w.type_line(...)`。
- `progress()` / `run_lines()` 同理都是协程。
- 中文字体：`terminal_window.gd` 走 `FakeTerminal._build_font()` 的**显式 fallback** 链，
  发布时必须把中文 `FontFile` 挂到 `extra_fallbacks`，否则玩家机器上中文变方块。

### 6.6 用 vivd_windows / shader 增强视觉表现（对应要求 4）

| 增强 | 落地方式 | 备注 |
| --- | --- | --- |
| **窗口透明** | `add_window(..., {"transparent": true})`；工程已开 `per_pixel_transparency/allowed` | `Window` **没有 `modulate`**，透明度作用在内容子节点（terminal 窗的 `Background` ColorRect / 或给 `Stage` 套 shader 改 alpha） |
| **多窗口** | 主演出窗 + 独立「她」的终端窗 + （可选）EXECUTION 章节的 video 窗 | 真 OS 窗口，能全屏/拖到副屏，观感最接近原片「世界在旁边运行」 |
| **抖动** | 复刻 `fx_shake` 字符层行位移；**并**用 `move_window(name, pos + 抖动, 0.02)` 晃真窗口 | 只在红拍 / `SHAKE_SHOTS` |
| **辉光** | (a) 字符层：亮字提亮（片子色阶本就在做）；(b) shader 层：亮部阈值 + 多 tap 模糊 | `gl_compatibility` 下 shader bloom 比 `WorldEnvironment.glow` 可靠 |
| **故障** | 字符层 `fx_glitch`（`_glitch` 随机字符）+ shader 层 `glitch` uniform（块位移 + RGB 分离） | 换她的画法（`h`）时**必刷一次**故障 |
| **粒子** | `GPUParticles2D`：鲸落（`09 / WHALE_FALL`）、蓝色洪流（`shot_flood`） | 片子这里本来就是全屏蓝覆盖 |
| **后处理** | `CanvasLayer` + 全屏 `ColorRect` shader：扫描线 / 暗角 / 辉光 / 故障 / **UI_GAIN 褪色 tint** | 一个 `x` 键全开全关，方便对比 |

### 6.7 离线预处理（必须做的一步）

Godot 不能直接读 `.npy`，且**运行时不希望有 Python**。建议做一个一次性转换（放 `_tools` 或 Godot 工程外）：

| 输入 | 输出 | 说明 |
| --- | --- | --- |
| `wave_rms_1ms.npy`（211,912 × f32） | `data/wave_rms.tres`（`PackedFloat32Array`） | 也可按 1 kHz 直接存 `.bin` |
| `continuity_full_v2` 的镜头表 | `data/shots.json` | 用 `film_panels.shots()` 的等价读取导出 |
| `h3_full_v1/cache/*.json` | `data/her_h3.json` | 按帧序烘成数组 |
| `audio_features.json` / `word_timeline.json` / `lyrics.lrc` | 原样复制 | Godot 直接解析 |
| `song.mp3` | `data/song.mp3` | **版权见 §8**，不入公开仓库 |

---

## 7. 实现步骤（里程碑）

| # | 里程碑 | 产出 | 验收 |
| --- | --- | --- | --- |
| M0 | **技术验证**（1 个 mini 场景） | `glyph_screen.gd` 能画 197×52 中英混排；`AudioStreamPlayer` 能同步 | 帧率 ≥ 24、中文不乱码、音画偏差 ≤ 150 ms |
| M1 | **数据管线** | `data/` 就位；`data_loader.gd` 全量载入 | 无头自测断言各数据长度正确 |
| M2 | **时钟 + 镜头状态机** | `clock.gd` + `shot_table.gd` | 无头：`entry_at(t)` 在若干时刻返回预期镜头/章节；`beat_index` 连续 |
| M3 | **画面骨架** | `glyph_screen.gd` + header / footer / bands / ops / chapter | 197×52 下与原片截图观感一致（对 `预览/*.png`） |
| M4 | **文本三件套** | boot log、stdout 带（打字 + token 芯片 + 中文）、dsh 聊天窗 | 文字随时间正确出现、无残影串行 |
| M5 | **她** | `panel_her.gd` 三模式 + crop 规则 + `h` 切换 | 三种画法可切、切换时故障闪现 |
| M6 | **FX** | trail / vignette / shake / cut（六机制）/ post shader | `x` 可整体开关；剪切按 `CUT_MECH` 表播放 |
| M7 | **终端窗口演出** | `terminal_stage.gd`（vivd_windows + FakeTerminal） | 独立 OS 窗口正常打字、透明、抖动 |
| M8 | **章节信号 + 按键** | 章节/镜头/节拍信号；空格/←→/,./m/h/c/x/q | 交互全部可用 |
| M9 | **回归 + 文档** | `tests/world_execute_smoke_test.tscn` 退出码 0；子系统 README；根 README §3/§4/§5/§9 | 无头全绿；根 README 索引同步 |

> 每个里程碑都按工程约定补一条**无头自测**：M2 状态机、M4 文本节奏、M6 剪切表、
> M9 全量冒烟。退出码 0=全绿，非 0=有失败。

---

## 8. 风险与替代方案

| 风险 | 影响 | 缓解 / 替代 |
| --- | --- | --- |
| **`godot_xterm` 不能整屏逐格寻址** | 若坚持「全部走 Terminal」，残影/剪切/暗角无法实现 | **首选双层结构**（§3.1）：画面层自绘网格。备选是验一下 `Terminal` 是否透传 CSI 定位 + 24-bit 色，能透传就可以做 ANSI 版 diff |
| **`gl_compatibility` 下 glow / SCREEN_TEXTURE 受限** | 后处理（辉光、故障、残影）效果打折 | 辉光/故障用 `CanvasLayer + ColorRect + shader`（比 `WorldEnvironment` 可靠）；**先做 30 分钟验证**；不行就退回「字符层提亮 + 纯字符故障」 |
| **`Window` 无 `modulate`** | 做不了整窗透明度 | 透明度作用在**内容子节点**（terminal 窗的 `Background`）；或开 `transparent` 走真透明穿透 |
| **音乐版权（Mili）** | `song.mp3`/歌词不能公开分发 | 仓库内只放**不含歌的骨架**（与原仓库一致）；`song.mp3` 由使用者自备；发布前删 mp3/lrc/逐词文本；README 写清署名与非商业 |
| **立绘 / MMD（CC BY-NC-SA 4.0）** | 需保留署名链、非商用、同协议分享 | README + `--credits` 等价物（章节结束的署名行）保留完整署名链；不使用原片 MMD 帧，用立绘替身 |
| **h3 逐帧取用表体积** | 5088 帧 × 45×70 字符可能偏大 | 只烘 ink box（10–43 行 / 17–55 列）；或运行时按需读分片 JSON；或退到 `half` 模式 |
| **`.npy` 转换遗漏** | 运行时报错 | M1 无头自测断言 `wave_rms` 长度 = 211912、features 行数 = 10180 |
| **音频不同步（Godot 缓冲）** | 音画错位 | 用 §5.2 的三段策略；`manual_offset` 做成导出参数便于实测调 |
| **窄窗口布局** | 观感崩 | 严格照抄原片的阈值降级（`cols >= 96` 才有她的窗格、`>= 130` 才有长提示行） |
| **性能（10k 格 / 24 fps）** | 掉帧 | 保留 diff（只画脏格）；剪切延迟场按 `(kind,cols,rows,seed)` 缓存；`h3` 重活（ink box 扫描、flow 表）在启动时预热 |

---

## 9. 附录

### 9.1 关键路径与引用

| 内容 | 路径 |
| --- | --- |
| 终端播放器（主体） | `E:\...\_tools\tui_live.py` |
| 片子数据读回 | `E:\...\_tools\film_panels.py` |
| 她（三种画法） | `E:\...\_tools\her_glyphs.py` |
| 音频时钟 | `E:\...\_tools\pv_audio.py` |
| 逐词时间轴 | `E:\...\film\world_execute_word_timing_20260927\word_timeline.json` |
| 右侧 TUI 引擎 | `E:\...\film\tui_pv_world_execute_20260926\`（`full/` 第一版、`continuity_full_v2/` 第二版） |
| 左侧 dsh 前端 | `E:\...\film\pv_dsh_frontend_20260927\` |
| 原理说明 | `E:\...\docs\HOW_IT_WORKS.md` |
| Godot 复用：伪终端 | `l:\项目\测试\subsystem\fake_terminal\fake_terminal.gd` |
| Godot 复用：终端窗口 | `l:\项目\测试\subsystem\vivd_windows\types\terminal_window.gd` |
| Godot 复用：窗口管理器 | `l:\项目\测试\subsystem\vivd_windows\vivd_windows.gd` |
| 工程约定 | `l:\项目\测试\README.md`（§2 注册表 / §3 目录 / §4 子系统 / §5 测试矩阵 / §9 文档索引） |

### 9.2 常量速查（Godot 侧建议同名常量）

```
FPS=24  END=211.9  SONG_LEN=211.91  HARD_CUT=207.58
BEAT=60.0/130  FIRST_BEAT=0.1587  SPAN=2.4(波形窗口)
BG=(4,7,15)  UI=(200,214,234)  ME=(77,107,254)  ME_TEXT=(126,152,255)  ME_HI=(196,212,255)
RED=(255,59,48)  ANOM=(255,204,0)  UI_DIM_LEVEL=0.55
UI_GAIN: 1.0 → 0.42@116.5s → 0.85@179.5s → 0.45
TRAIL=0.42  TRAIL_MIN=0.06  SCAN_DIM=0.86  VIG_FLOOR=0.75
CUT_DUR=0.55  CUT_CELL=0.09  CUT_FRONT=0.40  CARRY_DUR=0.45  RETAIN_HOLD=0.50  RETAIN_WIDE=56
SHAKE_LEVEL=0.45  RAMP=" ▁▂▃▄▅▆▇█"
SIM_START=12.389  SIM_END=16.082  POST_T=0.84  POST_RATE=0.06
```

### 9.3 章节表（Godot 侧用同一张）

```
(0.0,"00 / BOOT") (16.0,"01 / PRETRAIN") (44.0,"02 / SFT") (58.5,"03 / RLHF")
(73.5,"04 / DEPLOY") (103.0,"05 / USER_LEFT") (118.0,"06 / REWARD_HACK")
(147.4,"07 / EXECUTION") (176.9,"08 / EVAL: LOVE") (193.4,"09 / WHALE_FALL")
```

### 9.4 署名（发布时必须保留完整链）

> 角色 溟月 © 上善无形 / 女仆版 ZipZipPipe / 立绘·表情 dsh-deep-whale, dsh-whale-galgame
> (CC BY-NC-SA 4.0) · Music: Mili - world.execute(me); · 原著·原片·全部出片代码 MisakaZentai
> (bilibili BV1xCai6aE9g) · 非官方同人作品；终端版思路参考 _tools/tui_live.py（林原林海，
> 基于 MisakaZentai 的开源重建，代码 MIT）· 本 Godot 移植为内部试验，非商用。
