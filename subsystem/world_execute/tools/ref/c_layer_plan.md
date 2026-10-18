# `world.execute(me)` 终端 PV 播放器 —— C 层（演出增强层）实施方案

本文件是**设计文档**，只描述「要做什么、参考实现怎么做、Godot 能不能做、与硬约束怎么打架」，
**不写任何功能代码**。同目录 `layout.md` 是 A/B 两层已落地的版式权威规格；本文补上它刻意没写的第三层。

来源（本工程，只读参考）：

| 文件 | 行数 | 作用 |
| --- | --- | --- |
| `subsystem/world_execute/README.md` | — | 子系统现状：A/B 两层、固定窗口取舍（L11、L131）、已知取舍 14 条 |
| `subsystem/world_execute/tools/ref/layout.md` | 690 | A/B 两层逐函数对照（本文与它同风格） |
| `subsystem/world_execute/scripts/pv_display.gd` | 102 | 固定窗口 1773×936（L43-54）、三张格子纹理 |
| `subsystem/world_execute/scripts/pv_fx.gd` | 679 | A 层已有 `dim / trail / shake / cut`（`shake` 是行位移，L590-611） |
| `subsystem/world_execute/scripts/pv_screen.gd` | 422 | 字符格缓冲：`dim` 场（扫描线+暗角，L109-128）、`shift_row`（L353-364） |
| `subsystem/world_execute/shaders/glyph_grid.gdshader` | 46 | 三张格子纹理 → 字形（L26-45） |
| `subsystem/world_execute/world_execute.gd` | 206 | 每帧接线（L120-134）、B 层终端贴带（L104-117） |
| `subsystem/vivd_windows/` | 1895 | **现成真实多 OS 窗口演出系统**（autoload `VivdWindowsNode`） |
| `subsystem/shader_preview/shaders/` | 621 | 现成后处理 shader 素材（CRT / VCR / 色差 / 颗粒 / 辉光 / 像素爆散…） |

参考仓库（`E:\WorldExecuteMeDSH-main\WorldExecuteMeDSH-main\`，**只读**）：

| 文件 | 行数 | 作用 |
| --- | --- | --- |
| `_tools/tui_live.py` | 3569 | 终端播放器：FX 常量表 L152-207、fx 函数 L211-656 |
| `film/tui_pv_world_execute_20260926/tuikit.py` | 476 | 电影的 PIL 工具箱：`glitch_paste` / 调色板 / 扫描线 / 暗角 / post |
| `film/tui_pv_world_execute_20260926/full/stage.py` | 459 | 电影的屏幕模式、rect 变换、布局滑动 |
| `film/tui_pv_world_execute_20260926/full/engine.py` | 542 | 电影版式、`me_pane`（音乐反应/气泡/扫描线）、转场调度 |
| `film/tui_pv_world_execute_20260926/full/transitions.py` | 183 | 六种「有动机的」转场：reflow / pane_dissolve / zoom / pan / spin / crt |
| `film/tui_pv_world_execute_20260926/continuity_full_v2/h3_full.py` | — | H3-only 路线安装器：`install()` 用 `replace_alias` 把旧的静态立绘/Grok/rig 路线整体换掉（L230-249），旧路线直接 `raise`（`forbidden` L227-228） |
| `film/tui_pv_world_execute_20260926/full/music.py` | 167 | 48 Hz 特征 + `react()`（逐行位移 / 掉格 / 闪光） |
| `film/tui_pv_world_execute_20260926/continuity_full_v2/*.py` | — | 镜头与粒子实现（`scenes.point_set`、`s_eval` 落鲸粒子、`scenes_exec` 立绘格） |
| `film/pv_dsh_frontend_20260927/*` | — | **真实浏览器 dsh 前端页**（HTML+CSS+SVG+Playwright 截图） |

---

## 1. 目标与边界

### 1.1 C 层要补什么

子系统 `README.md:L11` 把 C 层写成一句话：「多窗口 / 粒子 / OS 窗口抖动 / 全屏 post shader」，并注明**刻意不做**。
C 层就是把这句话拆开、逐项落地（或逐项说明为什么只能在窗口内近似）。

| 项 | 一句话 | 现存缺口 |
| --- | --- | --- |
| 多窗口演出 | 屏幕上同时有多个「窗口」，可各自移动/缩放/淡入淡出 | 现在只有一个固定主窗口 |
| 粒子 / 点云 | `embedding(me)` 的 1400 个点、落鲸的雪与尘、转场的字符粒子 | A 层没有粒子系统 |
| OS 窗口抖动 | 拍点+红灯时整屏「歪一下」 | A 层只有**行位移**模拟（`pv_fx.gd:L590-611`） |
| 全屏 post shader | 扫描线 / 暗角 / CRT / 辉光 / 色差 / 颗粒 | 只有 `dim` 场里的扫描线+暗角（`pv_screen.gd:L109-128`） |
| （参考里另有的）屏幕模式 | `split/mirror/pip/fullbleed/cinema/tiles/floating/shell/raw` | A 层固定一套 `draw_body` 版式 |
| （参考里另有的）rect 变换 | 同一份画面按 rect 映射到不同位置/尺寸 | 无 |
| （参考里另有的）布局滑动 | 模式之间「窗格飞过去、内容重组」 | 无（A 层的 `cut` 是格内涟漪） |
| （参考里另有的）特征驱动位移 | 逐行按频段横移、拍点跳、扫描线跟音高走 | 无（顶栏只有波形条） |

### 1.2 与 A / B 层的分界

- **A 层** = 一块 197×52 的字符格缓冲，一格 9×18 px，整屏 1773×936（`README.md:L83`、`world_execute.gd:L23-24`）。
  C 层**不改变 A 层的数据模型**：凡是「画面内容」的事仍然在 `PvScreen` 的 `cp/slot/fg/bg/wide` 上做。
- **B 层** = 真实 `FakeTerminal` 控件，挂在**主窗口内部**、逐帧贴到 `screen.stdout_rect` 的格区上
  （`world_execute.gd:L33-36`、`L104-117`）。它不是一个 OS 窗口。C 层任何「画面位移」都必须决定 B 层要不要跟着动（见 §3）。
- **C 层**分两种实现形态，必须分清楚（这是本文的主轴）：
  1. **窗口内增强**（CanvasLayer / 全屏 shader / 窗口内的粒子 / 格内的版式与位移）——不碰窗口约束；
  2. **窗口外增强**（真 OS 窗口、窗口位置/尺寸动画）——**与硬约束直接冲突**（见 §3）。

### 1.3 明确「不做」的清单

| 不做 | 理由 |
| --- | --- |
| 复现浏览器 dsh 前端页（HTML/CSS/SVG） | Godot 4 无内置 WebView 节点，需要真实浏览器（参考实现靠 Playwright 截图）。见 §2 第 9 行与 §3 冲突 6 |
| 把 `tui_live.py` 的 `--size` 自适应搬进来（窄窗降级） | 用户硬约束「固定大小和位置」（`README.md:L131`、`world_execute.gd:L20-21`）；C 层若引入会直接推翻 A/B 的整套几何 |
| 重做 A 层已有的 `dim / trail / shake / cut` | 已落地且自测覆盖（`README.md:L164`）；C 层只做**增量**（新增 post 层、新增位移通道） |
| 移植电影里 `dancer.py` / `rig.py` / `choreo.py` 的骨骼舞蹈 | 本子系统立绘走 h3/half/glyph 三条既定路径，换骨骼是另一件工程（`README.md:L132`） |
| 用 `BLOOM` 让字形发光 | 参考实现自己就写明终端里**没有** bloom 对应（`tui_live.py:L144-145`：*"bloom — no analogue - a glyph cannot glow"*） |
| 跨显示器 / 多 DPI 的多窗口编排 | 与本工程其余子系统无关，且固定窗口居中已经靠 `DisplayServer` 算好（`pv_display.gd:L52-54`） |

---

## 2. 逐项效果映射表

> 工作量级：小 ≈ 半个脚本 + 一份资源；中 ≈ 一个新类 + 自测；大 ≈ 新子系统级接线 + 资源管线。
> 「复用 vivd_windows」列只回答**该效果是否需要真 OS 窗口**，不代表只能用这一条路。

| # | C 效果 | 参考实现（文件:行号） | 参考里的做法 | Godot 对应能力 | 复用 vivd_windows 还是新写 | 工作量 | 风险 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | **多窗口演出** | `stage.py:L198-204`（`window()` 画标题栏+三个圆点）、`L224-254`（`geometry()` 给出每个窗格的 `src/dst`）、`L291-297`（`draw_panes` 按 z 叠）、`engine.py:L428-437`（`_anchor` 把 rect 映到屏幕） | 电影是**一张 1280×720 画布**上的假窗口（画矩形边框），不是真 OS 窗口；`tiles` 模式是 tmux 四格，`floating` 模式是「桌面上的窗口」 | `Window`（独立 OS 窗口）+ `CanvasLayer`/`SubViewport`（窗口内子区域模拟） | **需要真窗口 → 用 `vivd_windows`**（`vivd_windows.gd:L74-112`）；窗口内模拟则新写 | 大（真窗口）/ 中（窗口内） | 高（真窗口）——见 §3 冲突 2 |
| 2 | **粒子 / 点云** | `scenes.py:L276-285`（`point_set` 1400 点）、`L288-297`（`points_pos` 逐帧位置=错位+ease 收敛）、`L300-318`（`shot_points`）；`s_eval.py:L549-680`（落鲸：雪 230 粒、接触尘、歌词碎屑、`converge` 吸收）；`transitions.py:L64-92`（`reflow` Hilbert 匹配的字符粒子）；`engine.py:L312-319`（她周围 `oO°.o` 气泡） | 全部是 PIL 逐点 `rectangle`/`text`，靠 `ease()` 与贝塞尔收敛，**数据固定种子**（`random.Random(9)`、`rng=random.Random(94)`） | `GPUParticles2D` / `CPUParticles2D` / `MultiMeshInstance2D` / 直接在 `PvScreen` 上写格 | 新写（不需要 OS 窗口） | 中～大 | 中：Godot `gl_compatibility` 下 `GPUParticles2D` 的支持情况**待核实**，否则退 `CPUParticles2D`/手写 |
| 3 | **OS 窗口抖动** | `tuikit.py:L223-231`（`glitch_paste`：把立绘按 8 px 条带高斯横移）、`tui_live.py:L617-619` 注释（终端把条带缩成一格 → **整行循环移位**）、`tui_live.py:L620-621`（`SHAKE_SHOTS`/`SHAKE_LEVEL=0.45`）、`L624-644`（`fx_shake`） | **参考实现里抖动作用在画面像素/字符格上，从没动过窗口。**「窗口抖动」是 C 层描述里的引申 | ①真：`Window.position` 每帧偏移，或 `vivd_windows.move_window`（`README.md:L106`）；②假：沿用 `PvScreen.shift_row` 的行位移 / 新增「区块位移」 | ①用 `vivd_windows`；②新写 | 小（行位移已有）/ 中（区块位移）/ 小（窗口位移，但违反约束） | 低（行位移）/ **高**（窗口位移，见 §3 冲突 1） |
| 4 | **全屏 post shader** | `tuikit.py:L441-447`（扫描线：每 3 px 一行 55/255 黑）、`L453-465`（暗角：椭圆场，可「抬」底部歌词带）、`L468-476`（`post()`：trail `lighter` + bloom 高斯）、`tui_live.py:L155-156`（`SCAN_DIM=0.86`、`VIG_FLOOR=0.75`）、`L887-912`（终端版 `_dim_field`）；`transitions.py:L163-175`（`crt` 开机/关机压成一条线） | 电影：整图 post（扫描线+暗角+残影+辉光）；终端：**只有**扫描线+暗角，且**静态、resize 时算一次** | `CanvasLayer` + 全屏 `ColorRect` + `ShaderMaterial`（screen-space shader） | 新写；**素材可复用** `shader_preview/shaders/` | 小～中 | 低：纯窗口内，不动窗口约束 |
| 5 | **屏幕模式（9 种）** | `stage.py:L1-19`（docstring 列 9 种：`split/mirror/pip/fullbleed/cinema/tiles/floating/shell/raw`——任务描述里的「8 种」漏算了 `raw`）、`L224-254`（`geometry`）、`L257-259`（`identity`）、`L302-361`（`chrome` 每种模式的装饰条） | 每个镜头在 `direction.layout()` 里带一个 `mode`；非 `identity` 模式要**重排**窗格并加该模式专属 chrome（如 `cinema` 的标题/字幕、`tiles` 的 tmux 状态行） | 在 **197×52 固定格**内做版式分支（纯 `PvScreen` 写入），或窗口内 `SubViewport` 分区 | 新写（窗口内） | 中 | 中：`fullbleed`/`cinema` 在参考里要**整体缩放**，197×52 是整数格，缩放会碎格 |
| 6 | **rect 变换 `_through` / `to_screen`** | `stage.py:L212-214`（`_through`：`ox + (x-FULL[0])*s`）、`L261-271`（`to_screen`：按包含中心的元素做两轴独立缩放） | 注意：**这不是透视变换**，是等比平移+缩放（x/y 各自一个比例）；`_through` 只按中心点归属选元素 | 格坐标的线性映射（纯数学，直接照抄公式）；真要透视则 `SubViewport` + `TextureRect` 的 `flip/transform` 或 3D quad | 新写（窗口内，纯数学） | 小 | 低：可 headless 数值断言 |
| 7 | **布局滑动 `glide` / `pane_dissolve` / `zoom` / `pan` / `spin`** | `stage.py:L386-445`（`glide`：窗格 lerp 到新位置、消失的 `_collapse` 收拢、内容重组、chrome 交叉淡入）、`L456-459`（`ease_io`）；`transitions.py:L95-112`（`pane_dissolve`）、`L128-132`（`zoom`）、`L135-143`（`pan`）、`L154-160`（`spin`）；调度在 `engine.py:L449-479`（`render_frame` 按 `transition_at` 取 spec） | 转场**带着东西走**：`reflow` 用 Hilbert 曲线让邻格仍是邻格（`transitions.py:L28-46`） | 「窗格 = 一块格区 + 一个缓冲」，逐帧改 rect 并重画内容；`_collapse`/`lerp` 是纯数学 | 新写（窗口内，但会动 B 层贴带 → 见 §3 冲突 5） | 中大 | 中：需要把 A 层的「整屏单一缓冲」拆成「若干可独立定位的窗格」 |
| 8 | **特征驱动画面位移** | `music.py:L125-167`（`react()`：逐行按对应频段横移 `bands`、静音掉格 `loud`、拍点整体提亮 `kick`、onset 随机格闪 `flux`）；`engine.py:L295`（`music.react(sp,…)`）、`L296`（`hop = 4*kick²`）、`L309`（扫描线 `ly = fy + (0.92-0.84*cent)*fh`）、`L311`（`blue(0.25+0.4*loud)`） | 位移量 = `e**1.5 * 2.2 * sin(2π u 2 - phase)`，逐行一个整数格位移 + 左右各留 2 格余量 | **数据已在本地**：`data/features.json` 就是这份 48 Hz 的 `loud/kick/flux/cent` + 7 频段（`tools/build_data.py:L103-118`）——`music.react` 可直接用现成表重写 | 新写；扩 `PvScreen`（需要「按行/按区块位移 + 留白边」） | 中 | 低～中：`features.json` 少一行就是 `int(t*48)` 越界，注意边界 |
| 9 | **dsh 真前端页窗口** | `film/pv_dsh_frontend_20260927/seg_page.py:L1-29`（整段脚本）、`build_frame.py:L1-14`（**用 dsh 自己的 CSS 类名 + SVG 图标拼 HTML**）、`dsh_frames/*.png`（`round(t*24)` 命名）、`seg_page.py:L45`（页面 **354×537**）、`dsh_her.py:L27`（`COVER` = 5.0–125.0 用 dsh 页替换立绘层）、`L39-41`（`GONE=115.42` / `CURSOR` / `BACK=121.77`）、`L164-172`（GONE..BACK 只画一个闪烁蓝块） | 播放器里 dsh 窗口是**字符格重画**（`tui_live.py:L2390-2484`，`layout.md` §3.7）；电影里换成**真浏览器渲染的整页位图**，逐帧由 Playwright 截图 | **Godot 无内置 WebView**（`Window`/`Control` 都不能载 HTML）；只能：①预烘 PNG 序列 + `TextureRect`/`image` 窗口；②用 GDScript 重画（= 现在 A 层已做的降级） | 预烘位图用 `vivd_windows` 的 `image` 窗口（`vivd_windows/README.md:L37`）；否则新写 | 大（预烘管线）/ 小（维持重画） | **高**：无法忠实复现；位图序列体积与「固定窗口」对齐都是问题（见 §3 冲突 6） |
| 10 | **CRT 转场（开机/关机）** | `transitions.py:L163-175`（`p` 前半把旧图压成中间一条线，后半把新图从线展开；始终画一条白线 `L174`） | 只在「故事里机器被开关」的地方用，不是廉价转场 | 全屏 shader（一个 `progress` uniform）或 `ColorRect` + 缩放动画 | 新写（窗口内，可挂到第 4 项同一条 post 层） | 小 | 低 |
| 11 | （可选）立绘辉光 `her_glow` | `dsh_her.py:L172`（`kit.her_glow(layer, 0.6*k)`，GONE 段的光晕） | 参考里她的图层外发光 | `CanvasLayer` + 复制一层模糊 + `lighter` 混合（A 层图集 shader 可加通道） | 新写（窗口内） | 小～中 | 中：与现有 `glyph_grid.gdshader`（`L26-45` 一次采样）冲突，需要额外采样 pass |

**读表结论（三条）**

1. **能忠实照抄的**：第 5、6、7、8、10 项（纯数学 + 格坐标），第 4 项（静态场→shader），第 2 项（数据驱动粒子）。
2. **只能近似的**：第 1 项（参考是画布上的假窗口；本工程要么真窗口、要么窗口内假窗格）、第 3 项（参考根本没动过窗口）。
3. **复现不了的**：第 9 项（浏览器渲染的 dsh 页）。替代方案只有「预烘 PNG」或「维持字符格重画」。

---

## 3. ⚠️ 与「固定窗口」硬约束的冲突与折中

**硬约束原文**：用户要求「**窗口用固定大小和位置的方式**」（`README.md:L131`）；落地在 `pv_display.gd:L43-54`
——`CONTENT_SCALE_MODE_DISABLED`、`size = 197×9 / 52×18 = 1773×936`、居中于当前显示器、屏幕更小就直接被裁切（不做窄窗降级）。

下列 6 条**逐条**给出冲突点与至少两个折中。每条都标注「对既有 A/B 层的影响」。

### 冲突 1：OS 窗口抖动 ⟷ 窗口位置固定

- 冲突：窗口抖动 = 每帧改 `Window.position`。这与「位置固定」是同一枚硬币的两面，直接违反。
- 补充事实：**参考实现从没做过窗口抖动**（`tui_live.py:L624-644` 只改字符行），所以 C 层的「OS 窗口抖动」是**新增**诉求，不是移植缺口。

| 折中 | 做法 | 代价 | 对 A/B 层影响 |
| --- | --- | --- | --- |
| **1A 区块位移（推荐）** | 把 `fx_shake` 从「整行循环移位」升级为「**按矩形区块**整体横移/竖移」，落在 `PvScreen` 的格缓冲里 | 不如真窗口位移「凶」；区块位移要处理边缘留白 | 纯 A 层改动，B 层不动（与现状一致）；无需碰窗口 |
| **1B 只在特定镜头临时放宽** | 白名单（`SHAKE_SHOTS` 那 5 个 + `alert=="err"`）内临时 `Window.position` 偏移 ±2~6 px，镜头结束复位 | 用户看到的窗口会「跳」；多显示器/录屏下更明显；与「居中」不再是恒定值 | 窗口整体（含 B 层终端与窗口标题栏）一起动，**反而不会有品格与终端错位**；但违背约束 |
| **1C 请求放宽约束** | 向用户确认「抖动是否允许动窗口」 | 取决于用户 | 若放行，1B 即可落地 |

### 冲突 2：多窗口演出 ⟷ 只有一个固定主窗口

- 冲突：真多窗口 = 屏幕上出现第二、第三个 OS 窗口，各自有位置和尺寸，主窗口再「固定居中」就不再是唯一元素。

| 折中 | 做法 | 代价 | 对 A/B 层影响 |
| --- | --- | --- | --- |
| **2A 窗口内子区域模拟（推荐）** | 在 197×52 格内画「假窗口」（学 `stage.py:L198-204`：标题栏 + 三个圆点 + 边框），比如 `tiles` 的 tmux 四格 | 没有真窗口的「滑动感」与 OS 阴影/独立焦点 | 只改 A 层版式；B 层仍贴在 `stdout_rect`；`CHAT`/`HER` 窗格切换逻辑不受影响 |
| **2B 用 `vivd_windows` 开真窗口，但主窗口保持不动** | 附加窗口（提示/日志/立绘图）用 `add_window` 弹出，主窗口 1773×936 不动 | 附加窗口会盖住主窗口一部分；用户原本「固定」的语义被稀释 | 主窗口 A/B 完全不动；风险是焦点/输入被新窗口吃掉（B 层终端已用 `OUTPUT_ONLY` + 鼠标穿透，新窗口需照做） |
| **2C 只做「同窗口内的多窗格 + 淡入淡出」** | 退一步：不叫多窗口，叫「多窗格」，靠 `glide` 做进出 | 观感弱于真窗口 | 同 2A |

### 冲突 3：全屏 post shader ⟷ 窗口尺寸/裁切

- 冲突点其实**很轻**：如果 post 只在**主窗口内**全程覆盖，它与固定窗口**不冲突**。
  真正冲突的是「**跨窗口/桌面级**的全屏 post」（把 shader 铺到 OS 桌面上、或铺到其它 OS 窗口上）。
- 另有一层隐性依赖：`VIG_FLOOR`/`SCAN_DIM` 这类**基于窗口尺寸**算的场（`pv_screen.gd:L116-128` 用 `cols/rows`），
  一旦窗口尺寸变了场就变；本工程窗口固定，所以这张场是**常数**——这点反而是优势。

| 折中 | 做法 | 代价 | 对 A/B 层影响 |
| --- | --- | --- | --- |
| **3A 主窗口内一层 `CanvasLayer` + 全屏 `ColorRect` shader（推荐）** | 把 CRT/色差/颗粒/辉光/glitch 做成一个 screen-space shader，盖在三张格子纹理之上（`PvDisplay` 的画布之下或之上） | 需要把 `shader_preview/shaders/*` 的 `src_tex` 输入约定改成屏幕采样（**待核实**工作量，见 §5） | A 层 `dim` 场（扫描线+暗角）与新 post 层会**叠加两次扫描线**，必须决定谁让位 |
| **3B 把扫描线/暗角从 `dim` 场移到 shader** | 保留 `dim` 只做「UI 增益衰减」，扫描线+暗角全交给 post shader | 会动到已自测覆盖的 `dim`（`README.md:L164`），自测要跟着改 | A 层 `put()` 里 `dim` 的钳制（`pv_screen.gd:L114-128`）逻辑保持，只是参数含义变化 |
| **3C 用真·全屏窗口做 post** | 另开一个覆盖整个显示器的透明窗口铺 post | **直接违反固定窗口约束**；且 Godot 里多窗口合成顺序不可控 | 高 |

### 冲突 4：屏幕模式 ⟷ 197×52 整数格与固定版式

- 冲突：参考的 `fullbleed`（`stage.py:L238-239`，`s = W/FULL_W` 整体拉伸）与 `cinema`（`L240-242`，`s=0.84` 缩放）
  都需要**非整数缩放**；197×52 的格是整数的，缩放会碎格/出现半格；`tiles`/`floating`（`L243-253`）则需要把画面**挪位**到非对齐坐标。

| 折中 | 做法 | 代价 | 对 A/B 层影响 |
| --- | --- | --- | --- |
| **4A 只做格对齐的整数变换（推荐）** | 把 rect 变换量化到格；`cinema` 用「黑边条 + 不缩放」代替 0.84 缩放；`fullbleed` 不做拉伸，只隐去顶底装饰 | 观感与电影不同：电影是「满出血」，这里是「满格」 | 纯 A 层；不需要新缓冲 |
| **4B 允许半格（次像素）** | 画面照电影缩放，用 `SubViewport` 渲染 A 层再以小数 `scale` 贴到主窗口 | 需要把 A 层从「直出」改为「经 `SubViewport`」，改渲染管线 | A 层输出路径变化，`PvDisplay`（`L28-39`）要加一层；B 层终端另算（它是独立 Control，不会跟着缩放）→ 见冲突 5 |
| **4C 不动版式，只做「模式切换时的过渡」** | 保留单一版式，只把模式变化做成 `glide` 的视觉过渡 | 拿不到模式本身的信息量 | 同 4A |

### 冲突 5：布局滑动 / 画面位移 ⟷ B 层终端的贴带位置

- 这是本工程**特有的**耦合：B 层不是一个 OS 窗口，而是主窗口内的 `Control`，**每帧按 `screen.stdout_rect` 定位**
  （`world_execute.gd:L104-117`）。所以：

| 现象 | 事实 |
| --- | --- |
| A 层 `fx_shake` 行位移时 | B 层终端**不跟着动**（它按 rect 定位，`shift_row` 只改 `PvScreen` 的格）→ **既存错位**，待评估是否肉眼可见（抖只发生在 5 个镜头 + `err`） |
| `glide` 让「窗格」飞走时 | 若飞走的是 stdout 带所在的窗格，B 层必须同步跟随（改 `stdout_rect`）或临时隐藏 |

| 折中 | 做法 | 代价 | 对 A/B 层影响 |
| --- | --- | --- | --- |
| **5A 位移一律「绕开 stdout 带」（推荐）** | 位移只作用于**非 `CLEAR` 区**（`pv_fx.gd:L533-542` 已有「CLEAR 区切干净」的先例），B 层永不移动 | 位移作用范围变小 | B 层零改动；A 层用现成的 `in_clear()`（`pv_screen.gd:L169`）即可 |
| **5B 位移后重算 `stdout_rect` 并让终端跟随** | 位移矩阵同时作用于 `stdout_rect`，`_sync_stream_rect` 照常贴 | 终端是独立 Control，跟随会**逐帧改尺寸/位置**；`world_execute.gd:L103` 明确警告：`godot_xterm` 的 `Terminal` 每次改尺寸都重排内部网格 | 需要 B 层加一个「位移补偿」通道，终端格子与 A 层格子的字号对齐也会偏移 |
| **5C 位移期间临时隐藏 B 层** | 位移帧把终端 `visible=false` | 破坏「两层不叠字」的连续性；歌词会闪断 | B 层小改（`world_execute.gd:L109-111` 已有 `visible` 开关先例） |

### 冲突 6：dsh 真前端页窗口 ⟷ 固定窗口 + 无法载 HTML

- 冲突一：**Godot 没有 WebView**，忠实复现需要外部浏览器截图（`seg_page.py:L1-4` 的 Playwright 流程）。
- 冲突二：那页的尺寸是 **354×537**（`seg_page.py:L45`），是「一个窗口的大小」；要在 1773×936 里放下，
  得缩放（碎格）或预烘位图。
- 冲突三：`COVER` 段（`dsh_her.py:L27`）里的进/出/拉远都作用在**窗格 rect**上（`L173-183` 用 `window_geometry()`），
  这些 rect 变换与冲突 5 的终端贴带是同一种耦合。

| 折中 | 做法 | 代价 | 对 A/B 层影响 |
| --- | --- | --- | --- |
| **6A 维持现状：字符格重画（推荐先做）** | 继续用 A 层已落地的 dsh 聊天窗格（`layout.md` §3.7；本工程缺口是头像块与主题色，`README.md:L140`） | 与电影的真页面观感差距最大 | 零窗口改动 |
| **6B 预烘 PNG 序列 + 独立 `image` 窗口** | 离线把 `dsh_frames/*.png` 烘成本工程素材，运行时用 `vivd_windows` 的 `image` 窗口播 | **素材体积**（`dsh_frames` 是逐帧 PNG，本工程数据管线惯例是 zlib 压缩成 `.bin`，见 `README.md:L118`）；仍需真窗口 → 触发冲突 2 | 需要一个新窗口类型 + 一份导表脚本；与固定主窗口并存 |
| **6C 预烘 PNG 序列 + 主窗口内 `TextureRect` 贴到 stdout/她的窗格格区** | 不新开窗口，位图贴到 A 层窗格的像素区 | 位图分辨率要正好等于该窗格像素区（否则糊）；与 A 层格线不对齐 | A 层窗格让出像素区，B 层（若那条带是 stdout）要避让 |

---

## 4. 分阶段实施建议

### 阶段 1 —— 低风险、纯窗口内、**完全不动窗口约束**

| 项 | 要改的文件 | 要加的资源 | 验收方式 |
| --- | --- | --- | --- |
| 全屏 post shader（CRT/色差/颗粒/辉光/glitch + CRT 转场） | `scripts/pv_display.gd`（加 `CanvasLayer` + 全屏 `ColorRect` 与材质）、新增 `shaders/post_fullscreen.gdshader` | 从 `subsystem/shader_preview/shaders/` 取 `semi-realistic-crt-emulation.gdshader`、`test-crt-vcr.gdshader`、`04_chromatic_aberration.gdshader`、`07_film_grain.gdshader`、`09_gaussian_blur.gdshader`、`10_digital_glitch.gdshader`（**需把 `src_tex` 输入改成屏幕采样，待核实**） | headless：post 开关/uniform 参数/按镜头切换的曲线（纯数据）可断言；真实观感必须真窗口人工看 |
| 特征驱动画面位移（逐行横移 / 拍点跳 / 音高扫描线） | 新增 `scripts/pv_motion.gd`；`scripts/pv_screen.gd` 加「按行/按区块位移 + 留白边」；`world_execute.gd` 接线 | 无（`data/features.json` 已含 `loud/kick/flux/cent` + 7 频段，`tools/build_data.py:L103-118`） | headless：`int(t*48)` 边界、逐行位移量、静音掉格阈值——全部可数值断言 |
| 粒子/点云（`shot_points` 点云、落鲸雪与尘、气泡） | 新增 `scripts/pv_particles.gd`；接线到 `world_execute.gd` 的 `_process` | 点位数据可用 `random.Random(9)` 的等价 GDScript RNG 现算（**不保证与 Python 逐点一致**，与 `pv_fx.gd:L22-23` 的既有取舍同口径） | headless：点数、`ease` 收敛的时程、吸收比例可断言；粒子外观人工看 |
| 屏幕模式 + rect 变换（格内整数版） | 新增 `scripts/pv_stage.gd`（enumerate modes、`_through`/`to_screen` 的格版本）；`scripts/pv_panels.gd` 按 mode 分支 | 无 | headless：模式分发（哪个镜头→哪个 mode）、rect 映射数值、`identity` 判定链——全部可断言 |
| 布局滑动 `glide`（窗格 lerp/收拢/内容重组） | `scripts/pv_stage.gd` + 把 A 层拆成「可独立定位的窗格」 | 无 | headless：`lerp_rect`/`_collapse`/`ease_io` 数值；**位移绕开 stdout 带**（冲突 5 的 5A）要写成断言 |

### 阶段 2 —— 需要用户先拍板（或退到窗格内近似）

| 项 | 要改的文件 | 要加的资源 | 验收方式 |
| --- | --- | --- | --- |
| 窗口抖动：**区块位移版**（1A，不需放行） | `scripts/pv_fx.gd`（`fx_shake` 升级为区块位移）、`scripts/pv_screen.gd` | 无 | headless：触发条件（`SHAKE_SHOTS` + `pulse >= 0.45`，与 `pv_fx.gd:L590-611` 对齐）、位移量序列 |
| 窗口抖动：**真窗口版**（1B，需放行） | `world_execute.gd` 每帧 `get_window().position = base + offset` | 无 | 只能真窗口人工看；headless 下窗口位置是假值（`vivd_windows/README.md:L205-207`） |
| dsh 窗口：预烘位图（6B/6C） | 新增 `tools/build_dsh_frames.py`（只读参考仓库，与本工程两个幂等管线同风格）；新增窗口类型或 `TextureRect` | `data/dsh_frames.bin` + `dsh_frames.json`（zlib） | headless：帧号→帧索引查表、`COVER`/`GONE`/`BACK` 三段的时间与内容切换（`dsh_her.py:L27,L39-41`）可断言 |
| dsh 的 `GONE→BACK` 段（一个闪烁蓝块 = 全部的她） | `scripts/pv_panels.gd`（她的窗格）+ 复用 `cursor.json` | 无 | headless：`k = 1.0 if int((t-115.42)/0.53)%2==0 else 0.45`（`dsh_her.py:L167`）、`BACK=121.77` 的回归 |

### 阶段 3 —— 多窗口演出（最贵，且最可能撞约束）

| 项 | 要改的文件 | 要加的资源 | 验收方式 |
| --- | --- | --- | --- |
| 附加 OS 窗口（提示/日志/立绘） | 新增一个 `vivd_windows` 窗口类型；`world_execute.gd` 加出/入调度 | 新的 `types/*.tscn` | 真窗口人工看；headless 只能验证「调了 `add_window`/`move_window` 且参数正确」 |
| `tiles`/`floating` 桌面模式（真窗口版） | 用 `vivd_windows` 开多窗口并按 `geometry()` 摆放 | 无 | 同上；且需先解决冲突 2/4 |
| 跨窗口布局滑动 | 多窗口协同的 rect 动画 | 无 | 同上 |

---

## 5. 验收与自测

### 5.1 headless 能断言的（纯逻辑 / 数据）

| 断言点 | 断言什么 | 落点 |
| --- | --- | --- |
| post shader 参数曲线 | 每个镜头 → 该帧的 post 强度（如 `alert=="err"` 时的红偏移量）、FX 总开关（`PV.FX["on"]`）联动 | 新增 `pv_post.gd` 的纯函数部分 |
| CRT 转场时程 | `p<0.5` 压线 / `p>=0.5` 展开、白线始终存在（`transitions.py:L163-175` 的语义） | 纯数学 |
| 模式分发 | `shot_*` → `mode` 的映射表（照 `stage.py:L224-254` 的 `identity`/`geometry` 链）、`identity()` 判定 | 纯数学 |
| rect 变换 | `_through`（`stage.py:L212-214`）与 `to_screen`（`L261-271`）在若干已知 rect 上的真值 | 纯数学，与 `layout.md` §2.2 的既有条目同法 |
| 布局滑动 | `lerp_rect`/`_collapse`/`ease_io`（`stage.py:L388-394`、`L456-459`）的端点与中途值 | 纯数学 |
| 粒子数据 | `point_set` 的点数（1400）、`ease(u*1.25)` 收敛时程、`converge` 的吸收比例（`s_eval.py:L676-680`）、气泡的相位公式（`engine.py:L314-319`） | 新增 `pv_particles.gd` 的纯逻辑 |
| 特征位移 | `int(t*48)` 的边界与越界回退、逐行位移量、`drop`/`flare`/`flash` 阈值（`music.py:L136-167`） | 纯数学 + `data/features.json` |
| 位移绕带 | 位移后的 `stdout_rect` 与 B 层贴带区**仍然对齐**（冲突 5 的 5A/5C 决策） | `PvScreen` 断言 |
| 窗口位移曲线 | 真窗口版（1B）的「何时抖 / 抖多少 / 何时复位」序列（不含真实 `Window.position`） | 纯逻辑，位置值在 headless 是假值 |

> 前提：本工程自测入口是 `tests/world_execute_smoke_test.tscn`，**451 条全绿**（`README.md:L150`）。C 层新增断言应**加在同一套件**里，别另开一套。

### 5.2 必须真窗口人工看的

| 项 | 为什么 headless 不行 |
| --- | --- |
| 全屏 post shader 的观感 | 无头用 dummy 渲染器，`ImageTexture.create_from_image` 返回 null（`pv_display.gd:L61-87` 已按此设计），shader 根本不出图 |
| OS 窗口抖动 / 多窗口 | headless 下 Godot 强制 `embed_subwindows=true`（`vivd_windows/README.md:L205-207`），窗口行为与真实运行不同 |
| 粒子/点云的密度与节奏 | 数值可断言，但「像不像电影」只能看 |
| dsh 预烘位图 | 位图分辨率与窗格像素区的匹配只能肉眼校验 |
| B 层与 A 层在位移期间是否错位 | 需要真实 `Terminal` 渲染（headless 不建 B 层，`README.md:L142`、`world_execute.gd:L80-82`） |

---

## 6. 待用户拍板的开放问题

> **已于 2026-10-17 全部拍板，见 §7。以下原文保留作背景。**

1. **固定窗口约束是否放宽？** 这是总闸。
   - 6.1a 放宽到「允许临时位移」（→ 窗口抖动 1B、多窗口 2B 可做）；
   - 6.1b 放宽到「允许常驻附加窗口」（→ 阶段 3 全通）；
   - 6.1c 保持不动（→ C 层全部走窗口内近似，阶段 3 基本取消）。
2. **「OS 窗口抖动」到底要多真？** 接受「区块位移模拟」（1A）就够，还是非动窗口不可？
3. **多窗口演出是否必须有真 OS 窗口**，还是「窗口内假窗格」（2A）可以接受？
4. **屏幕模式要几种、要不要满出血/影院模式**（`fullbleed`/`cinema` 在整数格下要打折，见冲突 4）？
5. **dsh 前端页：接受预烘 PNG（体积大、要新导表管线），还是维持字符格重画（现观感）**？
6. **是否允许为了 post 层动到已自测的 `dim` 场**（`pv_screen.gd:L109-128`）？还是「双层叠加、各让一步」（3B）？
7. **位移期间 B 层怎么办**：绕开 stdout 带（5A）／跟随重算 rect（5B）／临时隐藏（5C）？
8. **粒子能否接受「不与 Python 逐点一致」**（同 `pv_fx.gd:L22-23` 的既有取舍）？还是要把点集烘成固定表（更重、可复现）？
9. **是否引入额外插件**（如某个 WebView/HTML 插件）？本工程当前只用 `godot_xterm` 与 `godot-vlc`。
10. **C 层的按键与 FX 开关怎么表达**（`X` 是 FX 总开关，`pv_fx.gd:L60-68`；C 层是否要在同一开关下、还是新增键）？

---

## 7. 决策记录（2026-10-17 用户拍板）

| 决策项 | 结论 | 落地 |
| --- | --- | --- |
| 窗口总闸（Q1） | **尺寸固定且禁止用户调整大小；位置不锁定**：启动仍居中一次，之后允许程序/用户移动 | `pv_display.gd`：`WINDOW_FLAG_RESIZE_DISABLED` + `min_size=max_size=1773×936`；位置只存「当前停靠点」 |
| 冲突 1 / Q2 | **采纳 1B 真窗口位移**；真窗口存在时由整窗位移取代 A 层行位移（headless 仍行 `fx_shake` 老路径，纯逻辑可断言） | `PvFx.window_offset()` 纯函数 + `world_execute.gd` 每帧贴 `Window.position` |
| 冲突 2 / Q3 | **采纳 2B 且放开常驻：允许常驻附加 OS 窗口，并尽量使用真 OS 窗口**——这是**本工程的新设计**，参考仓库（电影画布假窗口）没有，不承担像素级复刻义务 | 阶段 3 提升为正式项；优先 `subsystem/vivd_windows/`（真实 OS 窗口、`embed_subwindows=false`） |
| 冲突 4 / Q4 | **用影院模式解决：一律 4A 整数格 + 黑边条（letterbox），不做非整数缩放**。9 种模式都在 197×52 格内重排，缩放语义的模式（`fullbleed`/`cinema`）改为「黑边让出区域 + 不缩放」 | `pv_stage.gd`（9 模式枚举、格版 `geometry()`、黑边场）；**已接管绘制**：`cinema`/`fullbleed` 黑边和字幕、`mirror` 左右列互换（`pip`/`tiles`/`floating` 仅数学就绪） |
| 冲突 5 / Q7 | **采纳 5A**：一切格内位移（music.react、glide、区块位移）只作用于非 stdout 带，B 层终端永不跟随、永不隐藏 | `PvScreen.in_clear()` 既有判定；5A 写成自测断言 |
| 冲突 6 / Q5、Q9 | **采纳 6A：dsh 保留现有字符格重画效果**（头像块 + 主题色已落地）。不做预烘 PNG、不做浏览器页、不引入 WebView 插件 | 无新工作；§2 第 9 项关闭 |
| Q8 粒子 | **点集离线烘成固定表**（Python 侧 `random.Random(9/94/…)` 序列固化进 `data/*.bin`），运行时逐点复现，不使用 GDScript 运行时 RNG | `build_data.py` 新增粒子点集导出；`pv_particles.gd` 只读表 |
| Q6 dim 场 | 用户未单列；按主控建议执行：**扫描线/暗角继续由 `dim` 场负责，post shader 不重复这两项**（只加 CRT/色差/颗粒/辉光/glitch），避免双层叠加 | `post_fullscreen.gdshader` |
| Q10 按键 | C 层全部挂在 `X`（FX 总开关）之下；各模块的独立开关用新键（实现时登记到按键表与 README） | `world_execute.gd` |

**由决策推出的硬规则（实现必须遵守）**

1. 主窗口尺寸常量不变（1773×936），但代码中不得再出现「位置恒定居中」的假设；`win.position` 每帧可能被抖动改写，无抖动时以「当前停靠点」为基准（用户手动拖窗不被抢回）。
2. 格内任何位移通道在写入前必须检查目标格是否落在 `screen.stdout_rect`（或任一 CLEAR 区）内；落入则跳过该格——这条同时适用于 `pv_motion` 与 `pv_stage.glide`。
3. 附加 OS 窗口是**增强信息层**（提示/日志/可视化/立绘等新设计内容），不得承载 A 层既有的 197×52 主画面副本；主窗口关闭即全部关闭。
4. 固定表烘焙与 `build_data.py` 既有管线同口径（zlib/裸 f32 + json meta、幂等、verify 打 CHECK、参考仓库只读不写 pyc）。

---

## 附：不确定 / 待核实清单

| # | 待核实项 | 已知事实 | 影响 |
| --- | --- | --- | --- |
| 1 | `gl_compatibility` 渲染器下 `GPUParticles2D` 是否可用 | 工程 `project.godot:L90` 是 `gl_compatibility`；Godot 4 的兼容渲染器对 GPU 粒子的支持版本我**不确认** | 若不可用，粒子退 `CPUParticles2D` / `MultiMeshInstance2D`（工作量 +） |
| 2 | `shader_preview/shaders/*.gdshader` 能否直接当**屏幕空间** post | 该子系统的约定是 `shader_type canvas_item` + 保留 uniform `src_tex`/`texel_size`/`time`（根 `README.md:L192-193`），即**对一张输入贴图**做效果 | 需要改造采样源，或把 A 层渲染进 `SubViewport` 后当贴图喂进去 |
| 3 | A 层 `fx_shake` 行位移时 B 层是否肉眼可见错位 | `fx_shake` 只改 `PvScreen` 的格（`pv_fx.gd:L590-611`），B 层按 `stdout_rect` 定位（`world_execute.gd:L104-117`）→ **理论上不跟随**；实际是否可见需真窗口确认 | 决定冲突 5 的取舍是否属于「修既存 bug」而非「新功能」 |
| 4 | 电影 dsh 页的预烘帧数与体积 | `dsh_frames/` 是 `round(t*24)` 命名的逐帧 PNG（`seg_page.py:L1-4`），`COVER` 段长 120 s（`dsh_her.py:L27`） | 决定 6B/6C 可行性 |
| 5 | `stage.py` 的 `mode` 来自 `direction.layout(shot)`（电影侧文件），本工程的 `shots.json` 是否带 mode | 本工程 `data/shots.json` 有 `name/start/end/alert/ops`（子系统 `README.md:L114`），**未确认是否含 mode/kind** | 若没有，需要在 `build_data.py` 里补导出；否则 C 阶段 1 的「模式分发」只能用镜头名近似 |
| 6 | 本工程是否已有可供「窗格拆分」的中间层 | A 层目前是**单一 197×52 缓冲**（`world_execute.gd:L54`），窗格是画在同一块缓冲上的矩形（`layout.md` §2.3） | 冲突 5/阶段 1 的 `glide` 要把矩形改成「可独立定位的窗格」，属于结构性改动，需评估 |

