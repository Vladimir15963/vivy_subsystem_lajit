# `world.execute(me)` 终端 PV 播放器（Godot 4 移植）

把「演出大肥鱼」的 **world.execute(me)** 终端 PV 搬进 Godot：逐帧由**镜头表**驱动，用**自研字符格画面层**画出原片的 TUI 版式，再叠一层**真终端文本流**；A+B 两层之上再补 C 层演出增强。

> **来源声明**
>
> 本子系统是对 **MisakaZentai** 的开源同人 PV 工程
> [`world-execute-me-dsh-pv`](https://github.com/MisakaZentai/world-execute-me-dsh-pv)（MIT）及其
> **终端实时版**（作者 **林原林海**，`_tools/tui_live.py` 等，MIT）的 **Godot 4 重实现**。
> 镜头表、版式与逐帧数据来自上游；GDScript 播放器、Python 离线管线与测试为独立重写。
> 本移植**未经原作者审阅或背书**，不是上游项目的一部分。
>
> **代码**按仓库根 [LICENSE](../../LICENSE)（MIT）发布；**素材另计**：
> 歌曲与歌词归 **Mili**（个人非商业，本仓库不授予再许可）；鲸鱼娘立绘/表情/头像及其派生字符网格按
> **CC BY-NC-SA 4.0**（署名 / 非商业 / 相同方式共享）。`data/` **不随仓库分发**，
> 克隆后请按 [DATA.md](DATA.md) 在本地生成。完整署名链见仓库根 [NOTICE.md](../../NOTICE.md)。

| 层 | 内容 | 实现 |
| --- | --- | --- |
| **A 层** | 字符格画面（197×52 格、24 fps、区块框线 / 波形 / 立绘 / 章节面板 / FX） | `scripts/pv_screen.gd` + `shaders/glyph_grid.gdshader` + `scripts/pv_panels.gd` + `scripts/pv_panes.gd` + `scripts/pv_fx.gd` |
| **B 层** | 文本流（打字机 / ANSI 颜色 / 假 shell 回显） | `scripts/pv_stream.gd` + 复用本工程既有的 `subsystem/fake_terminal/fake_terminal.gd`（`godot_xterm` 的 `Terminal` 子类） |
| **C 层** | 屏幕模式（9 种，含 pip/tiles/floating 窗格合成）/ 影院黑边 / mirror / 气泡 / 音乐反应 / her_glow / 全屏 post / 点云 / 落鲸雪尘 / 真 OS 窗口抖动 / 附加 OS 窗口 | `scripts/pv_stage.gd` + `pv_post.gd` + `shaders/post_fullscreen.gdshader` + `pv_motion.gd` + `pv_particles.gd` + `pv_whale.gd` + `pv_windows.gd`（复用 `subsystem/vivd_windows/`） |

C 层的**方案与拍板记录**在 [tools/ref/c_layer_plan.md](tools/ref/c_layer_plan.md)：9 种屏幕模式按 `full/stage.py` 移植，但缩放语义的模式按拍板改成**影院黑边（letterbox）+ 不缩放**（整数格不碎格）；`pip`/`tiles`/`floating` 用「完整画布 → 1:1 合成进窗格」实现。

---

## 文件

| 文件 | 行数 | 作用 |
| --- | --- | --- |
| `world_execute.tscn` / `world_execute.gd` | 447 | 主场景：装数据、挂音频时钟、按帧顺序接线 A/B/C 三层、滑动转场调度、对外信号、输入开关、按键表、`-- --windows` / `-- --half-her` / `-- --t=秒` / `-- --no-input` 验收开关 |
| `scripts/pv.gd` | 141 | 全局常量：配色、`mix/ui` 增益、节拍（BPM 130）、镜头增益、字符集（`SPIN` / `SCRAMBLE` / `RAMP`）、FX 开关（含 C 层五项） |
| `scripts/pv_atlas.gd` | 79 | 字形图集：`glyphs.png` 采样（32×36 槽位 / 1129 个字形）、ASCII 单宽与 CJK 双宽切分、缺失字符扫描 |
| `scripts/pv_data.gd` | 279 | 重数据取法：21191 个 100 Hz u8 波形采样、7 条频段、98 行逐词歌词、14 行 boot 日志、dsh 聊天逐帧（zlib 懒加载）、8 个立绘表情（44×36 字形格） |
| `scripts/pv_her.gd` | 614 | **她的三条渲染路径**（h3 / half / glyph）的纯数学与查表：`crop_box` / `crop_aspect` / `pick_crop` / `fit`、`glyph_lines`（手写 Sobel，按 PIL `ImageFilter.Kernel` 语义）、`halfblock`、`tint_ramp` / `tint_ramp8`、`h3_source` / `_join` / `frame_cells` / `h3_cells`、`text_at` / `flow_offset`、`flip_order` / `morph_mask` / `glitch_char` |
| `scripts/pv_shots.gd` | 202 | 97 个镜头表、10 个章节、`dsh` 覆盖段 / `GONE` 段、立绘段、gain 曲线、`cut` 表 |
| `scripts/pv_clock.gd` | 114 | 播放时钟：音频驱动（`song.mp3`）+ 墙钟回退、暂停/静音/音量/seek、片长 211.9 s |
| `scripts/pv_screen.gd` | 451 | 字符格缓冲：`idx/fg/bg` 三平面 + `cp/slot/wide`，矩形表（clear / noghost）、`box/hbar/waveform`、整行/段内位移、残影比对 |
| `scripts/pv_panels.gd` | 1649 | 全部版式：顶栏（波形 + 章节条）/ 底栏（含「输入禁用」提示）/ 左窗格（她 / dsh 聊天 / 光标三选一，mirror 时整列换到右侧）/ stdout 带（boot → sim.start → 歌词）/ feature bands / 章节面板分发与几何 / ops ticker / 她身边的气泡 / `her_glow` 光晕 / **pip·tiles·floating 的窗格合成** / **tiles 的 htop 与歌词日志**；`draw_her()` 逐行照抄 `tui_live.py:L1340-1507`，按 `her_style` 分发三条路径；`draw_dsh()` 照 `tui_live.py:L2390-2484`，含 `_avatar_block()`（复刻 PIL `Image.BOX` 的 8bpc 定点面积平均）与主题强调色 |
| `scripts/pv_panes.gd` | 1211 | 20 种章节面板的绘制：`corpus` / `loss` / `mask` / `memory` / `kv` / `expert` / `rope` / `sine` / `tangent` / `limit` / `gpu` / `conv` / `samples` / `exec_all` / `ifican` / `logits` / `whale` / `dualpipe` / `moe` / `love` |
| `scripts/pv_fx.gd` | 714 | FX 后处理：`dim` 增益场、`trail` 残影、`shake` 行位移（真窗口下由 1B 整窗位移接管）、`cut` 硬切揭示（含「吃上一帧旧画面」语义） |
| `scripts/pv_display.gd` | 166 | 三平面对纹理 + `glyph_grid.gdshader` 材质 + C 层 post 层 + **固定尺寸窗口**（位置不锁） |
| `scripts/pv_stage.gd` | 632 | **C 层舞台**：9 种屏幕模式、镜头→模式表（`direction.py` 原表）、格版 `geometry` / `through` / `to_screen`、`cell_geometry`（pip/tiles/floating 的 1:1 窗格矩形）、影院与满出血的黑边条、**转场**（CHOREO 原表 + 推动/径向/角度/溶解）、`glide` 插值数学（全部 5A 绕开 stdout 带） |
| `scripts/pv_post.gd` | 73 | **C 层 post 参数**：色差 / 颗粒 / 辉光 / glitch / CRT 转场（扫描线与暗角仍归 `dim` 场） |
| `scripts/pv_motion.gd` | 180 | **C 层特征反应**：`music.react` 的逐行横移 + 掉格 / 拍点提亮 / onset 闪光三件套，作用范围限定在她的画稿区 |
| `scripts/pv_particles.gd` | 119 | **C 层点云**：`shot_points` 的 1400 点固定表（`points_set.bin`），逐点复现参考的收敛与抖动 |
| `scripts/pv_whale.gd` | 255 | **C 层落鲸**：雪 230 粒 / 接触尘 100 个 / 歌词碎屑 171 条，全部读固定表；`shed_pos` / `contact_pos` / `word_state` / `converge` 逐公式移植 |
| `scripts/pv_windows.gd` | 223 | **C 层附加 OS 窗口**（新设计）：info / log / 她的立绘三个真窗口，复用 `subsystem/vivd_windows/` |
| `scripts/pv_stream.gd` | 267 | B 层文本流：打字机（28 字符/秒）、ANSI 上色、boot/章节/歌词/ops/聊天五路顺序回放、seek 静默重放 |
| `shaders/glyph_grid.gdshader` | 46 | 把三张格子纹理采样成图集里的字形 |
| `shaders/post_fullscreen.gdshader` | 90 | C 层全屏 post：色差 / 颗粒 / 辉光 / glitch / CRT 开关机 |
| `data/` | — | 导出的数据表（见下）+ `glyphs.png` 图集 + `her_sprite/` 立绘 PNG + `dsh_avatars/` dsh 头像 PNG |
| `tools/build_data.py` | 956 | 离线导出管线：只读参考仓库 → 写 `data/*.json` / `data/*.bin` / `data/her_sprite/*.png` / `data/dsh_avatars/*.png` |
| `tools/build_atlas.py` | 417 | 烘字体图集成 `data/glyphs.png` + `glyphs.json` |
| `tools/ref/layout.md` | 690 | **A/B 版式权威规格**：`tui_live.py` 的逐函数对照、常量表、章节面板 §7、按键表 |
| `tools/ref/c_layer_plan.md` | 345 | **C 层方案与决策记录**：11 项效果映射、6 条冲突与折中、三阶段、§7 拍板表 |
| `tests/world_execute_smoke_test.tscn` + `.gd` | 1814 | 无头自测（**633 项断言**） |

GDScript 合计 **9640 行**（含自测 1814 行；不含自测 7826 行），Python 管线 **1373 行**，场景 **12 行**，shader **136 行**。

---

## 运行条件

### 播放（必需）

| 项 | 要求 | 说明 |
| --- | --- | --- |
| 引擎 | **Godot 4.7.2 stable** | 工程 `config/features` 为 4.7；GDExtension 最低 4.3，但 4.6 / 4.8 未验证 |
| 渲染器 | `gl_compatibility` | 工程已固定；需要支持 OpenGL 3.3 / D3D12 的显卡，集显即可 |
| 系统 | Windows 10/11 x64（已验证）；Linux / macOS 亦有预编译 GDExtension | 重建图集时才需要 Windows 系统字体 |
| 显示 | 可用桌面 **≥ 1773×936** | 窗口尺寸锁死、一格 = 一像素；小于该尺寸会被裁切。建议 1920×1080 及以上 |
| 音频 | 任意输出设备；没有设备也能跑 | 主时钟优先跟随音频；`data/song.mp3` 缺失时退化为纯墙钟、无声 |
| 插件 | 仓库内 `addons/godot_xterm`（GDExtension，含预编译库） | B 层真终端依赖它；缺失或加载失败时只剩 A 层 |
| 磁盘 | `data/` 约 **12 MB**（其中 `song.mp3` 8 MB） | 不含上游参考包 |
| 网络 | 不需要 | 播放与无头自测全离线 |

> **克隆后不能直接播放**：`data/` 不随仓库分发（版权 + 体积），必须先按下面的「从零构建」生成一次。

### 重建数据（克隆后需要做一次）

| 项 | 要求 | 说明 |
| --- | --- | --- |
| Python | **3.12+** | 两个脚本只用标准库 + Pillow / numpy |
| Python 包 | `pillow`、`numpy` | `python -m pip install pillow numpy` |
| 上游参考包 | MisakaZentai 的开源 PV 工程 + 林原林海的终端实时版 | 目录结构见 [DATA.md §1](DATA.md)；`WE_REF` 指向它的根目录 |
| 字体 | `consola.ttf`、`msyh.ttc`、`seguisym.ttf` | Windows 自带；其它系统用 `PV_F_MONO` / `PV_F_CJK` / `PV_F_SYM` 指向替代字体 |
| 写权限 | 参考包**只读**即可 | 输出只写 `data/`（可用 `WE_OUT` 换目录） |

---

## 从零构建

下面以「仓库根」为当前目录。Windows 上若 `godot` 未加入 `PATH`，把命令里的 `godot`
换成完整路径（例如 `"L:\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe"`）。

### 1. 导入工程，生成 `.godot/` 与类缓存

```powershell
godot --headless --path "." --import
```

`.godot/` 被 `.gitignore` 排除，首次克隆必须跑这一遍；否则 headless 会报
`PvAtlas not declared` 之类的类名解析错误。

### 2. 指向上游参考包

```powershell
$env:WE_REF = "E:\WorldExecuteMeDSH-main\WorldExecuteMeDSH-main"   # 改成你的实际路径
$env:PYTHONIOENCODING = "utf-8"
```

`WE_REF` 下应能看到 `_tools/`、`film/tui_pv_world_execute_20260926/`、
`film/mmd_motion_eval_20260927/`、`film/pv_dsh_frontend_20260927/`、`input/`
（完整结构见 [DATA.md §1](DATA.md)）。

### 3. 生成数据表、立绘与头像

```powershell
python subsystem/world_execute/tools/build_data.py
```

输出目录默认是 `subsystem/world_execute/data/`（可用 `WE_OUT` 改）。脚本会打印一串
`CHECK` 行用于验收，关键几项应接近：

```text
CHECK shots              97
CHECK dsh.frames         2533
CHECK dsh.bin            62513 B (raw 5010508 B)
CHECK h3_takes           16 takes / 2188 frames / ink 34×39
CHECK points_set         1400 pts, 28000 B
CHECK whale_fall         t0=193.54 tc=203.54 shed=230 contact=100 words=171
```

### 4. 烘字形图集

```powershell
python subsystem/world_execute/tools/build_atlas.py
```

必须在第 3 步之后跑：它会扫描 `data/*.json` 收集所有要打印的字符，再按
9×18 px 的格烘出 `data/glyphs.png` + `data/glyphs.json`（32 列 × 36 行、1129 个槽位）。

```text
OK glyphs.png 114849B  288x648px
OK glyphs.json 9356B
   slots=1129 narrow=... wide=... mono_size=16 advance=9.00 baseline=12
```

若出现 `WARN ... chars had no glyph`，说明新增文案里有字体画不出的字符：
换用 `PV_F_*` 字体，或把该字符加进 `build_atlas.py` 的 `UI_LITERALS` / `FIXED_EXTRA` 后重烘。

### 5. 跑无头自测

```powershell
godot --headless --path "." res://subsystem/world_execute/tests/world_execute_smoke_test.tscn
```

期望最后一行是 `=== world_execute 自测结束：633 项检查，0 项失败 ===`，退出码 `0`。
退出码含义：`0` 全绿 / `1` 有失败 / `2` 超过 30 秒看门狗。

### 6. 启动播放器

```powershell
godot --path "." res://subsystem/world_execute/world_execute.tscn
```

也可以直接在编辑器里打开 `world_execute.tscn` 后按 F6。窗口启动时会在当前屏幕居中一次，
之后可以拖动；**尺寸不可调整**。

> 主场景根节点有一个导出项 `input_enabled`，仓库里的 `world_execute.tscn` 当前保存为
> `false`。想让键盘控制生效，在检查器里勾上它（或调用 `set_input_enabled(true)`）；
> 反之可用 `-- --no-input` 做「输入禁用」验收。

### 重建单个文件 / 自定义数据

| 想改 | 做法 |
| --- | --- |
| 只重烘图集 | 跑第 4 步即可；输入是现有的 `data/*.json` |
| 只重导某个表 | 改 `build_data.py` 对应 `build_*()` 后整体重跑（脚本幂等，产物逐字节一致） |
| 换输出目录 | `$env:WE_OUT = "D:\we_data"`，并把结果拷回 `data/`（运行时路径是 `res://...`） |
| 歌词 / dsh / 镜头 / 立绘 / 点云 / 落鲸 | 见 [DATA.md §4 自定义数据](DATA.md) |

两个 Python 工具都是**幂等**的，且对参考仓库只读（`sys.dont_write_bytecode` 在 import 前
就置位，连 `.pyc` 都不写）。

---

## 命令行参数

`world_execute.tscn` 支持以下**用户参数**（注意 `--` 是 Godot 的用户参数分隔符，不能省）：

```powershell
godot --path "." res://subsystem/world_execute/world_execute.tscn -- --windows
```

| 参数 | 作用 |
| --- | --- |
| `-- --windows` | 启动即打开 info / log / 立绘三个附加 OS 窗口（`W` 键仍可随时开关） |
| `-- --t=194.2` | 从指定秒数起播；便于逐个镜头验收（pip ≈ 9.5、tiles ≈ 17、落鲸 ≈ 194.2） |
| `-- --half-her` | 强制 `half` 立绘路径，让她在所有镜头都占左窗格，便于观察音乐反应与气泡 |
| `-- --no-input` | 启动即禁用按键响应，底栏显示「输入禁用」（窗口关闭按钮仍可用） |

可以组合，例如 `-- --windows --t=17`。

---

## 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `PvAtlas: 缺少字形图集 …/glyphs.png` | 没跑第 4 步；先 `build_atlas.py` |
| 画面全是空白 / 方块 | `glyphs.json` 与 `glyphs.png` 不配套，或字符不在图集里；重烘图集 |
| `data/xxx` 读取失败、自测红 | 第 3 步没跑完或 `WE_OUT` 指到了别处；确认文件在 `subsystem/world_execute/data/` |
| 没有声音，但画面正常走 | 缺 `data/song.mp3`（时钟会退化为墙钟），或音量被 `-` / `M` 调没了；默认音量 80 % |
| 画面只有 A 层，没有终端文本流 | headless / dummy 渲染器本来就没有 B 层；真实窗口下检查 `addons/godot_xterm` 是否加载成功 |
| headless 报 `Xxx not declared` | 类缓存过期；重跑 `godot --headless --path "." --import` |
| 窗口显示不全 / 被裁切 | 桌面可用区域小于 1773×936；换更高分辨率或放大桌面 |
| 按键没反应 | 检查主场景根节点的 `input_enabled`（当前场景保存为 `false`），或是否传了 `-- --no-input` |
| 附加窗口叠在主窗口上 | 主窗口几乎占满屏幕时，三个附加窗口按内侧层叠摆放；先拖开一次即可 |
| 自测里的表长断言失败 | 你改过/替换过 `data/`；断言写死了若干表长与首尾值，改完数据要同步更新测试 |
| `WE_REF` 路径错 | 会直接 `FileNotFoundError` 或找不到 `film/...`；用 `Test-Path $env:WE_REF` 先确认 |

---

## 按键表

照抄参考实现 `tui_live.main()`（`tools/ref/layout.md` §6），例外见「已知取舍」。

| 键 | 作用 | | 键 | 作用 |
| --- | --- | --- | --- | --- |
| `Q` / `Esc` | 退出 | | `-` / `=` | 音量 ∓10 % |
| `空格` | 播放 / 暂停 | | `,` / `.` | 后退 / 前进 1 s |
| `M` | 静音 | | `←` / `→` | 后退 / 前进 5 s |
| `X` | FX 总开关 | | `Home` / `End` | 回到片头 / 片尾 |
| `C` | 左窗格在 dsh 聊天与她之间切换 | | **`B`** | **B 层终端面板开关（本子系统新增）** |
| **`H`** | **渲染路径循环 `auto → h3 → half → glyph`** | | **`P`** | **C 层全屏 post 开关** |
| **`V`** | **C 层特征驱动位移开关** | | **`K`** | **C 层屏幕模式/黑边开关** |
| **`W`** | **C 层附加 OS 窗口（info / log / 立绘）开关** | | | |

---

## 输入开关与对外信号

**输入开关**（关闭后所有按键都不响应、也不吃事件；窗口关闭按钮仍可用）：

| 方式 | 用法 |
| --- | --- |
| 检查器 | 主场景根节点的 `input_enabled`（默认开） |
| 代码 | `world_execute.set_input_enabled(false)` |
| 命令行 | `-- --no-input` |

关闭时底栏右侧的按键提示整块替换为 **输入禁用**（amber 色，按显示宽度右对齐）。

**对外信号**（`world_execute.gd` 顶部）：

| 信号 | 参数 | 触发时机 |
| --- | --- | --- |
| `playback_started` | — | 空格从暂停恢复播放 |
| `playback_paused` | — | 空格暂停 |
| `playback_finished` | — | 到达片尾 211.9 s（只发一次；seek 回片头后重新武装） |
| `seeked` | `t: float` | 任意 seek（±1 s / ±5 s / Home / End） |
| `shot_changed` | `index: int, name: String` | 镜头切换（第一帧也发一次） |
| `chapter_changed` | `label: String` | 章节切换（含片头第一个章节） |
| `input_enabled_changed` | `enabled: bool` | 输入开关变化（同值不重复发） |

---

## 三层是怎么接起来的

**A 层**：`PvScreen` 是一块 197×52 的字符格缓冲，每帧由 `PvPanels.draw()` 填满，然后 `PvDisplay` 把 `idx/fg/bg` 三个平面传成三张 `RGBA8` 纹理，交给 `glyph_grid.gdshader` 采样字体图集。一格固定 **9×18 px**，所以整屏 = **1773×936**。

每帧顺序（顺序错会破坏 `cut`「吃旧画面」的语义）：

```
screen.begin_frame(t)                # 清 rect 表、写 PV.NOW
PvFx.stage_cut(screen, t, ent)        # 镜头号变了才排 cut，吃的是上一帧还在屏上的画面
PvStream.step(t, data, ent)           # B 层先写文本（它要读 A 层上一帧的 stdout 带位置）
PvPanels.draw(screen, d, t, ent)      # 画新画面；同时把 stdout 带格区写进 screen.stdout_rect
PvParticles.draw_points(...)          # C 层点云（仅 shot_points），固定表驱动
PvMotion.apply_band_shifts(...)       # C 层行位移（只搬她的窗格，5A 跳过 stdout 带）
PvStage.bar_rects(...)                # C 层影院/满出血黑边（5A 裁到带外）+ 章节字幕
PvFx.apply(screen, t, ent)            # CLEAR 落后一帧，再 reveal → trail → shake
screen.end_frame()                    # 收帧快照（供下一帧 trail / cut 比对）
display.update_textures()
display.update_post(PvPost...)        # C 层全屏 post（色差/颗粒/辉光/glitch/CRT）
PvFx.window_offset(...) → 窗口位置     # C 层 1B 整窗抖动（真窗口才有）
PvWindows.update(...)                 # C 层附加 OS 窗口内容（4 Hz 节流）
```

**B 层**：`PvStream` 是纯逻辑类，`FakeTerminal` 为 `null` 时只把**打完的整行**记进 `log: Array[String]`——这样 B 层的全部行为（打字进度、去重、回退重放）都能在 headless 下断言。真终端只在本机渲染环境里创建（`PvDisplay.can_create_textures()` 为真时）。

它贴在 A 层**真正在画文本的那条带上**（`screen.stdout_rect`），逐帧跟随：boot 阶段是格 (1,32)-(118,47)，进入 sim.start 后整体下移 3 行。B 层启用时 A 层把这条带**让出去**（只留底色），所以同屏不会出现两份 boot 日志 / 两份歌词。

终端以 `Mode.OUTPUT_ONLY` 运行（`focus_mode = NONE` + 鼠标穿透），按键不会被它吃掉——`Q`/`空格`/`B` 仍然归主场景。

**C 层**（`tools/ref/c_layer_plan.md` §7 的拍板落地）：

- **屏幕模式**：`PvStage` 把 `full/direction.py` 的 97 个镜头 → 9 种模式的表整套搬过来（`shot_you_left` 与 `shot_exec_hit` 按同名序号参数化）。`cinema` / `fullbleed` 按拍板**不缩放**，改成上下黑边（9/5 行、2/5 行）+ 章节字幕；黑边先过 `avoid_band()`，**永远不盖 stdout 带**（5A）。**`mirror` 已接管实际绘制**：`mirror + split` 的镜头把她的窗格与可视化窗格整列互换，stdout 带跟着她挪到右侧（B 层按新 rect 重贴，只在镜头切换时变一次）。
- **气泡**：`shot_deeply` 打开 `oO°.o` 上浮气泡（`engine.py:L312-319`；全片只有 `sec_chorus1.py:L91` 用 `bubbles=1.0`），按格换算为「窗格顶 +3 行起、每周期上浮 14 行、黄金分割错开、±1 格横摆」。
- **窗格合成**：`pip` / `tiles` / `floating` 先在一张完整的 197×52 暂存画布上照常绘制，再按 `PvStage.cell_geometry()` 的 dst **1:1 拷贝**（4A：不缩放，裁/留底）。stdout 带、CLEAR / NOGHOST、她的画稿区随后一起映射到主屏坐标，B 层与音乐反应继续有效；pip 的 stdout 带归可视化窗格（画中画放不下 16 行终端）。`tiles` 另有 `htop`（GPU 条 + 内存 + 轮转进程表）与 `lyrics`（最近 5 行歌词日志）两个附加窗格。
- **滑动转场**：`PvStage.CHOREO` 把 `direction.py:L137-220` 的镜头对表整套搬来（默认 `glide` 11 帧、`you_left` 6 帧、显式硬切为 `{}`）。运行时在当前帧旁再渲染一遍上一镜头的画面，按进度做**整块推动 / 径向展开 / 角度扫描 / 逐格溶解**（4A 整数格近似），`crt` 交给 post shader。转场期间不排 `cut`，并把 `PvFx` 的镜头记忆推前，结束后不会补一次切入。
- **落鲸雪尘**：`whale_shed.bin` / `whale_contact.bin` / `whale_words.json` 由 `build_data.py` 离线烘好（230 雪 / 100 尘 / 171 条碎屑），`PvWhale` 逐公式复现 `shed_pos` / `contact_pos` / `word_state` / `converge`，运行时无 RNG。
- **post**：`PvDisplay` 在字形画布之上再挂一层全屏 `ColorRect`，`post_fullscreen.gdshader` 用 `hint_screen_texture` 采样下层画面，做色差 / 颗粒 / 辉光 / glitch / CRT 开关机。扫描线与暗角仍由 `PvScreen.refresh_dim()` 的 `dim` 场负责（不叠两层）。
- **特征反应**：`PvMotion` 照 `music.react()` 的相位公式逐行搬她的**画稿区**（不含框线与标题）；随后依次做**掉格**（静音段按确定性噪点挖空）、**拍点提亮**（`v' = min(255, v*(1+0.55f)+30f)`）、**onset 闪光**（少量格跳到 `#c4d4ff`）。`PvScreen.shift_row_span()` 与反应都跳过 CLEAR 区（5A）。
- **`her_glow`**：`draw_glow()` 照 `kit.her_glow()`（`kit.py:L168-180`）落成「一圈邻格 `░` + 0.3k 提亮」，用在 GONE 段那个闪烁蓝色光标的周围（`dsh_her.py:L161-172` 的原始用法）。
- **点云**：`points_set.bin`（1400 点 × 5 f32）由 `build_data.py` 离线烘好，运行时逐点复现 `scenes.points_pos()`，不摇 RNG。
- **真窗口抖动**：`PvFx.window_offset()` 与行抖动同触发条件，真实窗口存在时整窗偏移 ±4 px（A/B 两层一起动，不会错位）；headless 下仍走原来的行位移。
- **附加 OS 窗口**：`PvWindows` 用 `VivdWindowsNode` 开三个常驻真窗口（info / log / 立绘），只放增强信息，不复制主画面；`W` 开关，`-- --windows` 启动即开。

---

## 数据管线产出的表

| 文件 | 内容 |
| --- | --- |
| `wave_rms.bin` / `wave_rms.json` | **21191 个 100 Hz u8** 波形采样（每 10 ms 取 1 kHz 源的峰值；顶栏波形） |
| `features.json` | 48 Hz 特征：`loud` / `kick` / `cent` 等 10180 点 + 7 条频段 |
| `words.json` / `lyrics_cn.json` | 98 行逐词歌词（每词 `start`/`when` 打字时刻）+ 中文对照 |
| `shots.json` / `shots_meta.json` | 97 个镜头（名 / 起止 / alert / ops / 立绘开关…）、硬切时刻、增益曲线 |
| `chapters.json` | 10 个章节标签与起点 |
| `boot_log.json` | 14 行 boot 日志（`[t, tag, text]`，全部 ≤2.783 s） |
| `dsh.bin` / `dsh_meta.json` / `dsh_spans.json` | dsh 聊天窗口逐帧 DOM 快照（12 Hz，2533 帧）：`dsh.bin` 是 **zlib 压缩的 JSON**（5 010 508 B → 62 513 B），`dsh_meta.json` 存 `raw_size` / `hz` / 帧数，运行时按需解压；每帧带 `avatar`（相对路径）、`theme`（`[bg-base, brand-primary, border-l1]`，`brand-primary` 是窗口强调色）与 `rows`（含 `name` / `state` / `dot` / `pill` / `composer` 等 role） |
| `dsh_avatars/` | dsh 引用到的 **745** 张逐帧头像 PNG（120×120 RGB，~959 KB）。路径映射：`avatars/<子目录>/<名>.png` → `data/dsh_avatars/<子目录>/<名>.png`（去掉前导 `avatars/`，其余相对路径原样保留） |
| `her_glyph.json` / `her_glyph_meta.json` | 8 个立绘表情的 44×36 字形格 + 亮度（旧 glyph 网格，现为降级兜底） |
| `her_sprite/{expr}.png` × 8 + `her_sprite.json` | 立绘源图降到最长边 512 px 的 RGBA（**R=G=B=原亮度、A=原 alpha**），含缩放后尺寸 / 四张 crop 矩形 / `cheerful` 量的裁剪宽高比 |
| `h3_takes.bin` + `h3_takes.json` | 16 个 H3 take 的 `art`+`shade`，只存墨迹框 rows 10-43 × cols 17-55（34×39），zlib 压缩（396 KB / 解压 5.80 MB）；json 里是字符集 / take→`[帧数, 偏移]` / 50 段 `PLAN` / 墨迹框 |
| `h3_ramp.json` | `dancer._ramp` 的 256 级蓝/红查表（h3 路径）+ `her_glyphs.tint_ramp` 的 8 级蓝/红（half 路径；红的常量与 256 级那对**不同**） |
| `h3_flow.bin` / `h3_flow.json` | 5087 个 float32 的逐帧 lyric 流偏移 + `CPS=7.0` / `SONG_LEN` / `FPS` |
| `h3_text.json` | `engine.LYRICS` 的 `[[start,end,line]]`（98 行，来自 `.lrc`；与 `words.json` 的逐词时间线**不同**） |
| `her_morph.json` | `random.Random(7)` 的前 7722 个 `random()`（切换动画的固定次序阈值） |
| `figure_spans.json` / `portrait_shots.json` / `cursor.json` / `gain.json` / `meta.json` | 立绘段、立绘镜头、光标窗格、增益、杂项常量 |
| `panes.json` | 20 种章节面板需要的表：`corpus` 词表、`facts`、`loss.noise`（600 点）、`mask`（12 阶热格）、`memory` 文件/挖取表、`kv` 尺寸与 pinned 块、`expert`（24×6 高斯）、`pipe` 尺寸、`moe` rank/逐拍 routed、`kernels`、`samples`、`love` 每行格数、`whale` 逐帧剪影、`banner`（IFICAN 位图）、`decode9` 乱码序列 |
| `points_set.bin` / `points_set.json` | C 层点云固定表：1400 点 × 5 个 f32（`tx, ty, lv, rx, ry`），共 28000 B；由 `scenes.point_set()` 的 `random.Random(9)` 序列离线固化 |
| `whale_shed.bin` / `whale_contact.bin` | C 层落鲸固定表：230 粒雪 × 11 f32（`b,x0,y0,v,amp,w,ph,drift,lv,sz,d`）+ 100 个接触尘 × 7 f32；`random.Random(94)` 序列离线固化 |
| `whale_words.json` / `whale_fall.json` | 171 条歌词 / 色块碎屑（含 delay / whole / specks / d）+ 时间轴 `T0/TC/T1`、落点格、落地线常数 |
| `glyphs.png` / `glyphs.json` | 字体图集：32×36 槽位、1129 个字形、基线 12、双宽字已切成左右两格 |

---

## 已知取舍（都在代码注释里有对应标注）

1. **窗口尺寸固定、位置不锁**：`1773×936`（197 格 × 9 px、52 格 × 18 px）、`CONTENT_SCALE_MODE_DISABLED`、`min_size = max_size = 尺寸`、`unresizable = true`。启动居中一次；之后用户可以拖窗，C 层 1B 整窗抖动也会临时改 `Window.position`（无抖动帧把当前位置记成基准，不会把用户拖走的窗口抢回居中）。屏幕小于该尺寸时仍会被裁切，不做窄窗降级。
2. **她的三条渲染路径全部移植**：`h3` 走电影自己的逐帧 H3 字符 take（16 个 take 的 `art`+`shade`，一个电影格 = 一个终端格，`:` 格用她正在唱的歌词填）、`half` 走半块立绘（`▀`/`▄` 每格两个亮度采样）、`glyph` 走方向笔画 + 密度梯度。`her_style` 的 auto 判定链（`tui_live.py:L1236-1276`）逐条落地。**表情仍由镜头名稳定哈希挑选**，而不是参考实现里「每个镜头自带 expression」——电影那需要逐镜头的 `call`（`expr`/`kw`/`dist`），本次未导出（见第 5 条）。
3. **`H` 键已绑定**：在 `auto → h3 → half → glyph` 间循环，切到 `h3`/`auto` 时先 `warm_h3()` 预热，与参考实现一致（不 `seek` 重放）；底栏照参考实现显示 `her:{模式}`，`auto` 时再带 `->{how}/{tint}`。
4. **章节面板 20 种全部移植**：`corpus` / `loss` / `mask` / `memory` / `kv` / `expert` / `rope` / `sine` / `tangent` / `limit` / `gpu` / `conv` / `samples` / `exec_all` / `ifican` / `logits` / `whale` / `dualpipe` / `moe` / `love` 均已绘制，分发（`PvPanes.spec()`）与几何（`_draw_chapter_pane()`）逐条照抄参考实现；放不下时把行还给 ops ticker。由 Python RNG / PIL 生成的表（噪声、`mask` 热格、`expert` 高斯、rank、逐拍 routed、鲸鱼逐帧、Anton 横幅、乱码序列）一律导出成 `panes.json`，纯数学（loss / lr / kv / pipe / moe / `love_cells`）在 GDScript 里重写。
5. **`ent` 没有 `call`：`expr` / `dist` 是降级**：我们的 `shots.json` 没有电影逐镜头的 `call`，所以表情用镜头名的稳定哈希选、`dist` 恒空 → `soft = 0`、不画 softmax 段（那段代码照抄在，只是走不到）。`her_style` 的 `ent.last_her` 用 `PvPanels.LAST_HER` 静态代替（她上次被画过即为真），第 6 条用 `ent["alert"]`（`shots.json` 里没有 `alert_own`）。
6. **立绘源图与重采样偏差**：`her_sprite/{expr}.png` 把 935×1682 的原图降到最长边 512 px（PIL LANCZOS）再存，运行侧再裁 + 重采样到窗格大小 —— 比参考实现多了一次重采样；Godot 的 `INTERPOLATE_LANCZOS` 与 PIL `Image.LANCZOS` 核不同，所以 `halfblock` / `glyph_lines` 在 alpha 边界附近的个别格子可能差 1 级 / 换个字符（`h3_cells` / `frame_cells` 是纯查表，逐格与参考一致）。Sobel 已按 PIL `ImageFilter.Kernel` 的**实测**语义实现（行翻转、列不翻转、边界取原值、`floor(sum/4+0.5)+128`）。
7. **h3 只存墨迹框（rows 10-43 × cols 17-55）与 `part` 缺失**：`build_data.py` 对**每一帧**量过并集并断言整片非空 `art` 都在框内，所以只存 34×39 与存整块 45×70 等价（`:` 的 lyric 流下标只数非空格）。`part` 字段没有导出（只 `art`+`shade`）——`her` 窗格用不到它；`portrait_cells` / `tile_art` 那些走 `part` 的渲染器本子系统没有复现。
8. **take 缺失时退到旧 glyph 网格**：h3 take 读不出或立绘 PNG 不可用时，`draw_her()` 退回 `her_glyph.json` 的 44×36 字形格降采样路径（参考实现是退到 `half`）——本机数据齐，走不到。
9. **`expert` 面板的逐字乱码闪烁**：参考实现每帧用 `random.Random(int(t*24)*7919)` 播种，Python MT 无法逐位复现，这里改用同帧号播种的 Godot RNG 近似 —— 高斯数值是烘出来的表、逐值一致，只有闪烁序列不保证一致。
10. **dsh 窗口的头像块与强调色已落地**：逐帧头像 PNG（`data/dsh_avatars/`）由 `_avatar_block()` 复刻 PIL `Image.BOX` 的 8bpc 定点面积平均（横向 → 纵向两趟、权重 22 位定点、累加器预置 `1<<21`），逐格取上下像素画 `▀`；强调色取该帧 `theme[1]`（`brand-primary`），缺省 `ME_TEXT`。`data/dsh_avatars/` 只拷快照实际引用到的 745 张；`theme` 非空（`brand-primary`）的帧 482/2533，其余回退 `ME_TEXT`。
11. **`B` 键是本子系统新增**（参考实现没有）：用来对照 A / A+B 两种效果；切换时会 `seek()` 静默重放一遍，保证画面与文本流对齐。
12. **headless 下没有 B 层**：`Terminal` 需要真实渲染环境，无头运行时 `PvStream` 退化为只写 `log`，所以自测覆盖的是 A 层全部逻辑 + B 层的纯逻辑（打字进度 / 去重 / 回退重放），不覆盖真终端的绘制。
13. **顶栏 fps 与底栏状态**由主场景每帧（fps 每 0.5 s）写进 `PvPanels` 的静态变量，与参考实现的全局变量同法。
14. **`roundi` vs Python `round`**：Godot 四舍五入到远离零、Python 是银行家舍入，`sec*24` / `t*24` 恰好落在 `.5` 时可能差 1（实测数据里没有踩到）。h3 的 `_flow_table()` 长度是 **5087**（`int(211.91*24)+2`），不是任务描述里的 5089。
15. **C 层屏幕模式与转场全部落地，但都是「整数格」近似**：`cinema`/`fullbleed` 的黑边与字幕、`mirror` 的左右整列互换直接画在主缓冲上；`pip`/`tiles`/`floating` 用「完整画布 → 按 dst 1:1 拷贝」（4A：不缩放），窗格比源列小时是**裁切**、比源列大时是**留底**。滑动转场同理：电影是「窗格滑动 + 内容重组」，这里是**整块推动 / 径向 / 角度 / 溶解**，没有亚格插值；`glide` 的 `lerp_rect` / `collapse_rect` 仍保留为纯数学（给将来的真窗格插值用）。
16. **影院黑边不盖 stdout 带**：`PvStage.avoid_band()` 会把下黑边从 5 行裁到 4 行（`48..51`），这是 5A 的直接后果；B 层终端的位置与可见性全程不变。
17. **post 不含扫描线/暗角**：那两项仍在 `PvScreen.dim` 场里，避免两层叠加。`P` 键只关 C 层 post（色差/颗粒/辉光/glitch/CRT），不关 `dim`。
18. **CRT 转场只认两个镜头**：`shot_eggplant` 与 `shot_grpo`（`direction.py:L176/L207` 的 `crt` 转场），各 0.5 s；其余硬切仍走 A 层 `cut`。
19. **真窗口抖动仅在有真实窗口时生效**：headless / 内嵌窗口下 `PvFx.use_window_shake` 为 false，退回参考实现的行位移（自测覆盖的是后者 + 前者的偏移上限纯逻辑）。
20. **附加 OS 窗口是本工程的新设计**：参考仓库里没有真窗口（电影是画布上的假窗框），所以 info / log / 立绘三个窗口的内容是本工程自定的增强信息；主窗口几乎占满 1920 宽的屏幕时，三个窗口按「屏幕内侧层叠」摆放，需要用户自行拖开。headless 下 `PvWindows.available` 为 false，全部空转。
21. **落鲸雪尘已落地，采样点用立绘 PNG 替代**：参考 `WhaleFall.build()` 用 `her_layer()` 的 alpha 撒雪，但参考仓库缺 `cache/h3_full_v1/rgba/settle/030.png`（会直接抛异常）。`build_data.py` 按同一 RNG 顺序重放整段 `build()`，只把「她轮廓内的采样点」换成 `her_sprite/cheerful.png` 的 alpha（同窗格、同阈值、同摆放）——**雪量与参数一致，采样轮廓有细微差别**。歌词碎屑的字体也降级为格内逐字。
22. **pip/tiles/floating 的 B 层位置**：stdout 带随窗格映射（`_map_into`）；pip 固定映射到可视化窗格（画中画放不下 16 行终端），其余跟着她的窗格。`FakeTerminal` 在模式切换那一帧会重排一次内部网格。
23. **气泡只在「她」被画出来时出现**：左窗格在 dsh 覆盖段里显示聊天窗时不会画她的窗格，因此气泡也只在 `keep`（`her_style == "half"` 或 `CHAR_SHOTS`）的镜头可见；这与参考实现「气泡属于 `me_pane`」的从属关系一致。
24. **音乐三件套的随机性口径**：掉格用确定性哈希（`noise8(x,y,seed)`）复现「每半拍换图案」的结构，但**图案与 Python 的 MT 噪点不同**；onset 闪光用同帧号播种的 Godot RNG，落点同样不保证逐格一致。拍点跳 `hop_cells` 保留为纯函数——参考是 4 px（不足一格），格版里向上取整会抖动整块画稿，故**不施加**。
25. **反应范围是「画稿区」不是整个窗格**：`PvMotion` 只在 `PvPanels.HER_ART`（去掉框线与标题那一圈）里搬格 / 掉格 / 提亮，窗格边框与标题保持稳定；这也修掉了早期用 `HER_RECT` 时会把边框一起搬歪的问题。
26. **数据体积（P0 已落地）**：`dsh.json`（5.01 MB）改成 zlib 压缩的 `dsh.bin`（62.5 KB），首次访问时按 `dsh_meta.json` 的 `raw_size` 一次性解压；波形从 1 kHz f32（848 KB）降到 **100 Hz u8**（21 KB，每 10 ms 取峰值）。`data/` 合计 **18.20 MB → 12.42 MB（−31.8%）**。精度影响：波形柱只有 8 级、每格≈17 ms，看不出来；dsh 是**无损**压缩。剩余候选：features 量化 int8（767 KB→~112 KB）、头像去重（745 个仅 406 唯一，−~446 KB）、立绘降采样（986 KB→~550 KB）、音频转 128k OGG（8.48 MB→~3.4 MB）。

---

## 自测覆盖

`tests/world_execute_smoke_test.tscn`，**633 项断言全绿、退出码 0**：

| 组 | 覆盖 |
| --- | --- |
| 图集契约 | cell 9×18、槽位 32×36 / 1129、基线 12、纹理 288×648、空格 / ASCII 单宽 / CJK 双宽 / 零宽、盒线与块元素齐备、界面文案全部有字形 |
| 调色与增益 | `mix` 的钳制与端点、`ui` 增益 0 / 0.42 / 1.0、`to_color` |
| 节拍 | `BEAT = 60/130`、第 0 拍前的索引 -1、`pulse` 在拍点 = 1 与拍后衰减、`beat_level` 上下界 |
| 镜头表 | 97 个镜头、10 个章节起点、越界贴边、`alert`/`ops`、硬切时刻、gain 曲线、立绘段与 `kv_inset`、dsh 覆盖段与 `GONE`、`SHAKE` / `cut` 表 |
| 数据取法 | 波形 21191 个 100 Hz u8 采样与桶换算、特征点数与 7 频段、歌词行数与逐词打字、越界返回 0、中文对照、boot 打印进度、立绘 8 表情与 44×36 格、dsh 从 `dsh.bin` 解压后可查帧 |
| 她的三条渲染路径 | 8 张立绘 PNG 可加载与缩放后尺寸、crop 矩形 / `crop_aspect` / `pick_crop` / `fit` 的已知取值、`halfblock` 的维度与若干格真值、`glyph_lines` 的维度与字符集契约、`h3_cells` / `frame_cells` 的 `aw/ah/ox/oy` 与逐格 `(ch,fg,bg)`、`source`（含 knots 段）/ `join` / `flow_offset` / `text_at`、`flip_order` / `morph_mask` 四分支 / `glitch_char`、`tint_ramp` 256 级与 8 级、`her_style` 判定链逐条规则 |
| B 层文本流 | 章节条 / ops 首步落行、boot 条数与打印进度一致、打字中不落行、半拍去重、dsh 白名单角色、同帧去重、前跳与回退触发重置重放、关掉再开 `seek` 铺回 |
| 字符格缓冲 | 写格 / 双宽切分 / 行位移 / 残影比对 / rect 表 / `text_dump` |
| 面板 | 顶栏底栏要素、左窗格三态、ops ticker 滚动与 `err` 配色、feature bands、`her` 立绘（h3 take + 框标题 + 扫描线）、底栏 her 模式与路径、dsh 聊天分栏 |
| dsh 聊天窗 | `_hex` 的 `#rgb` / `#rrggbb` / 非法输入、`_avatar_block` 在 14×7 / 10×5 / 6×3 等尺寸的若干格与 PIL `Image.BOX` 逐值一致、缺图 / 空路径 → null、745 张头像引用数 == 实拷数、`theme` / `dot` 非空帧数、accent 落到框线（`#ff8fc0`）/ 缺省 `ME_TEXT`、头像区 `▀` 半块与前景/背景、窗口登记 NOGHOST |
| 章节面板 | 20 条分发规格（全部命中）、宽度门槛让行（含 `shot_strange` 的 `rw>=46`、`shot_love_loop` 的 `rw>=5*LOVE_PER_ROW+2`）、`panes.json` / `her_glyph.json` 已加载、20 个 pane 的 `pane_h` / 画区左右界（第 119/195 列）/ ops 起点行 / 标题落字、无面板时 `pane_h = 0` |
| FX | `dim` 场叠加、`trail` 残影、`shake` 行位移、`cut` 揭示与延迟帧 |
| C 层舞台 | 9 种模式、97 镜头 → 模式映射（含 `you_left` / `exec_hit` 参数化）、`identity` / `through` / `geometry` / `to_screen`、影院 9/5 黑边与 5A 裁带、`ease_io` / `lerp` / `collapse` / `glide_plan` |
| C 层 mirror | `shot_world` 判定、raw/full 与 split 不互换、stdout 带中心移到右半边且右缘贴第 195 列、split 镜头仍在 x=1 |
| C 层气泡 | `shot_deeply` 强度 1 / 其它 0、窗格内落 `oO°`、不写到窗格之上、字符集长度 5 |
| C 层位移 | 相位 = `t·π/BEAT`、逐行横移真值、掉格 30 %、闪光 28 格、拍点跳 `4·kick²`、`shift_row_span` 在 CLEAR 区不写、stdout 带整行跳过 |
| C 层三件套 | 静音掉格数量区间、满 kick 提亮 100→176、满 flux 闪光格数上限、闪光只改颜色不改字符、`noise8` 确定性 |
| C 层 her_glow | 邻格写 `░`、光晕色 = `ME_TEXT × 0.5`、已有笔画被提亮、无笔画时不出光晕 |
| C 层窗格 | pip/tiles/floating 的 `cell_geometry` 窗格数与画布边界、full 单窗格；三种模式实际绘制后 stdout 带落在目标窗格内；tiles 的 htop / lyrics 标题与内存条 |
| C 层转场 | CHOREO 表（reflow/zoom/pan/spin/crt/硬切）、`you_left` 6 帧、默认 glide 11；推动 p=0/1 端点、zoom 边角在 p=0 仍是 A |
| C 层落鲸 | 时间轴 193.54–205.54 / TC、230×11 + 100×7 表长、落地线公式、出生位置、`converge` 前后、落笔 5A 不写 stdout 带、非该镜头不画 |
| C 层 post | 静音 / 红系统的色差 · 颗粒 · glitch 真值、CRT 转场 0.5 s 与白名单 |
| C 层点集 | 1400 点 / 28000 B、`u=1` 收敛到目标、画布→格区映射端点 |
| C 层窗口 | headless 下 `available=false` 且 toggle 空转、三个附加窗口初始矩形、1B 抖动偏移上限与开关联动 |
| 对外 API | 7 个信号存在、`input_enabled` 关闭/重复设值/恢复的信号次数、`PvPanels.INPUT_ON` 同步 |
| 输入提示 | 关闭时底栏末行含「输入禁用」，恢复后含 `q quit` |
