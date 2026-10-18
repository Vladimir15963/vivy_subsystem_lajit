# `tui_live.py` 终端 PV 播放器 —— 移植版式规格

来源文件（绝对路径）：

| 文件 | 行数 | 作用 |
|---|---|---|
| `E:\WorldExecuteMeDSH-main\WorldExecuteMeDSH-main\_tools\tui_live.py` | 3569 | 主播放器：常量、`Screen` 类、FX、全部 `draw_*`、`main()` |
| `E:\WorldExecuteMeDSH-main\WorldExecuteMeDSH-main\_tools\film_panels.py` | 837 | 从电影源码读回的数值表（时钟、章节、boot log、loss、mask、ops、dsh 窗口） |
| `E:\WorldExecuteMeDSH-main\WorldExecuteMeDSH-main\_tools\her_glyphs.py` | 374+ | 立绘三条渲染路径（h3 / half / glyph）、`CROPS`、`tint_ramp` |
| `E:\WorldExecuteMeDSH-main\WorldExecuteMeDSH-main\_tools\dsh_text.py` | — | dsh 聊天窗口每帧 DOM（`at(t)`） |
| `E:\WorldExecuteMeDSH-main\WorldExecuteMeDSH-main\film\tui_pv_world_execute_20260926\tuikit.py` | 476 | **电影**的 PIL 工具箱（1280×720），终端版只是照抄它的语义 |
| `...\film\tui_pv_world_execute_20260926\full\engine.py` | — | 电影自己的 `LEFT/CENTER/TICK/FULL` 与 header/ticker/lyric_tokens 版式 |
| `...\film\tui_pv_world_execute_20260926\full\stage.py` | 459 | 电影的 8 种屏幕模式与 rect 变换（`to_screen`/`_through`） |

> 关键结论先说：**终端播放器里没有 `Screen` 于 tuikit.py**，`Screen` 类定义在 `tui_live.py:872`；`tuikit.py` 只提供 `W,H=1280,720` 与颜色/字体常量。下面第 4 节的签名全部出自 `tui_live.py`。

---

## 1. 全局常量（`tui_live.py` 顶部 L58–L260 及散落处）

### 1.1 时间与屏幕

| 常量 | 值 | 行 | 含义 |
|---|---|---|---|
| `FPS` | `24` | tui_live.py:L89 | 帧率（同时是 `FP.FPS`、`her_glyphs.H3_FPS`） |
| `END` | `211.9` | tui_live.py:L90 | 片长秒数（`FP.SONG_LEN=211.91`，`END_T=211.0`） |
| `SPAN` | `2.4` | tui_live.py:L91 | 顶栏波形显示的秒数窗口 |
| `SIM_START` | `12.389` | tui_live.py:L130 | `shot_begin_sim` 起点（boot log 到这里清屏） |
| `SIM_END` | `16.082` | tui_live.py:L130 | `shot_begin_sim` 终点 |
| `BEAT` | `60.0/130.0` = **0.461538…** | film_panels.py:L35（`FP.BEAT`），tui_live.py:L124 转发 | BPM 130 |
| `FIRST_BEAT` | `0.1587` | film_panels.py:L36 | 第一个鼓点（电影 `engine.py:35`） |
| `BANDS` | `["40-120","120-300","300-700","700-1.5k","1.5-3k","3-6k","6-10k"]` | tui_live.py:L127 | 7 个频段标签 |
| `RAMP` | `" ▁▂▃▄▅▆▇█"`（共 9 个字符，索引 0=空格） | tui_live.py:L128 | 波形/条形亮度阶梯 |
| `SCRAMBLE` | `"!<>-_\\/[]{}=+*^?#%$&@01|~:;"` | tui_live.py:L1310（`FP.SCR`，film_panels.py:L654；同 `tuikit.py:59`） | 打字机/毛刺字符集 |
| `SPIN` | `"|/-\\"` | tui_live.py:L157 | 框标题旋转子（`tuikit.py:344`） |

**屏幕格数（197×52）不是代码常量**，是默认基准尺寸：

- `term_size(default=(120,34))` → `max(40, columns), max(12, lines)`，tui_live.py:L3314–3316（L3340 可用 `--size 197x52` 覆盖）。
- 基准来自基准工具：`tui_shot.py:L172` `--size default="197x52"`；`sweep_tui.py:L29` `SIZES` 首项 `(197, 52)`，`sweep_tui.py:L144` `Screen(197,52)`。
- 电影的 `W, H`：`tuikit.py:L24` `W, H = 1280, 720`（tui_live.py 本身**没有** `W/H` 常量）。

### 1.2 颜色（deepsea 调色板 `tuikit.py:32-33`，抄进 tui_live.py:L95-104）

| 名字 | 值 (RGB) | 行 |
|---|---|---|
| `BG` | `(4, 7, 15)` | tui_live.py:L95 |
| `UI` | `(200, 214, 234)`（= 电影里的 `AMBER`） | tui_live.py:L96 |
| `UI_DIM_LEVEL` | `0.55` | tui_live.py:L97 |
| `ME` | `(77, 107, 254)` #4D6BFE | tui_live.py:L98 |
| `ME_MID` | `= ME` | tui_live.py:L99 |
| `ME_TEXT` | `(126, 152, 255)`（电影里是 `(120,148,255)`，见 `tuikit.py:33`） | tui_live.py:L100 |
| `ME_HI` | `(196, 212, 255)` | tui_live.py:L101 |
| `RED` | `(255, 59, 48)` | tui_live.py:L102 |
| `ANOM` | `(255, 204, 0)` | tui_live.py:L103 |
| `UI_DIM` | `(120, 134, 158)`（仅 fallback，`draw()` 实际用 `ui(UI_DIM_LEVEL)`） | tui_live.py:L104 |
| `ERR_RED` | `(255, 74, 61)`（页面自己的 error 主色） | tui_live.py:L2282 |
| `UI_GAIN` | `[1.0]`（每帧被 `draw()` 改写） | tui_live.py:L115 |

**混合公式原文**（务必照抄）：

```python
# tui_live.py:L118-120
def ui(level: float):
    """`tuikit.amb(level)` - the film's plain UI colour through this frame's gain."""
    return mix(UI, level * UI_GAIN[0])

# tui_live.py:L861-863
def mix(c, level, base=BG):
    level = max(0.0, min(1.0, level))
    return tuple(int(base[i] + (c[i] - base[i]) * level) for i in range(3))
```

- 等价电影侧公式：`tuikit.py:L72-73` `def amb(level): return mix(AMBER, level * UI_GAIN[0])`；`tuikit.py:L63-65` 同 `mix`。
- `UI_GAIN` 由 `draw()` 每帧写：`UI_GAIN[0] = FP.ui_gain_at(t, ent["name"] if ent else "", ent["u"] if ent else 0.0)`，tui_live.py:L3257。关键帧 `film_panels.py:L193-194`：`[(0,1.0),(110.4,1.0),(116.5,0.42),(176.9,0.42),(179.5,0.85),(193,0.75),(206,0.45)]`；三条覆盖 `film_panels.py:L199-210`（`shot_red_if_i_can`/`shot_red_then_i_can` 恒 1.0；`shot_have_you_back` 在 `u<0.75` 且 `sin(t*40)>0.3` 时 1.0）。
- **凡是 UI 色都必须过 `ui()`**：框、面板标题、章节名、时钟、ops ticker；她的蓝、红异变、ANOM 不过。

### 1.3 后处理与 cut FX

| 常量 | 值 | 行 | 含义 |
|---|---|---|---|
| `FX` | `dict(on=True, reveal=True, mech=True, trail=True, vig=True, shake=True)` | tui_live.py:L152 | 总开关（`--no-fx` → `on=False,reveal=False,mech=False,trail=False,vig=False`，L3383） |
| `TRAIL` | `0.42` | tui_live.py:L153 | 残影系数（`tuikit.py:468` 的 `lighter(prev*0.42)`） |
| `TRAIL_MIN` | `0.06` | tui_live.py:L154 | 低于此丢弃 ghost |
| `SCAN_DIM` | `0.86` | tui_live.py:L155 | 每 3 字符行调暗（`tuikit.py:445` 是每 3 像素行 ×55/255 黑） |
| `VIG_FLOOR` | `0.75` | tui_live.py:L156 | 暗角最深只到 75%（电影是 91% 黑） |
| `CUT_DUR` | `0.55` | tui_live.py:L158 | 整屏展开时长 |
| `CUT_CELL` | `0.09` | tui_live.py:L159 | 单格切换耗时（`kit.py:348` 的 `dur`） |
| `CUT_FRONT` | `0.40` | tui_live.py:L160 | 切换前沿显示毛刺的比例（`kit.py:349` `density`） |
| `CARRY_DUR` | `0.45` | tui_live.py:L179 | CARRY 飞行时长 |
| `CARRY_CELLS` | `13` | tui_live.py:L180 | CARRY 最长提升的字符游程 |
| `RETAIN_HOLD` | `0.50` | tui_live.py:L181 | RETAIN 块原地保持时间 |
| `RETAIN_WIDE` | `56` | tui_live.py:L182 | RETAIN 块最大宽度（格） |
| `CUT_REVEAL` | `3` | tui_live.py:L183 | 每 3 个无机制说明的 cut 才放一次揭示（`if i % CUT_REVEAL or heavy`，L386） |
| `CUT_HEAVY` | `frozenset` | tui_live.py:L188-190 | `{"shot_power","shot_flood","shot_love_loop","shot_travel","shot_isolation","shot_unite","shot_red_if_i_can","shot_you_left","shot_eggplant","shot_exec_hit"}` |
| `SHAKE_SHOTS` | `frozenset` | tui_live.py:L620 | `{"shot_strange","shot_collapse","shot_flood","shot_erase","shot_drowned"}` |
| `SHAKE_LEVEL` | `0.45` | tui_live.py:L621 | 抖动所需最小 `FP.pulse(t)` |
| `NOW` | `[0.0]` | tui_live.py:L191 | 当前帧时间（`box()` 呼吸需要），`draw()` 每帧 `NOW[0]=t`（L3238） |
| `CLEAR` / `PREV_CLEAR` / `NOGHOST` | `list` | tui_live.py:L196/L200/L206 | 三张 rect 表，见下文 |

**`CUT_MECH` 完整表**（tui_live.py:L169-178，逐字）：

```python
CUT_MECH: dict[int, tuple[str, ...]] = {
    1: ("UNFOLD",), 2: ("MORPH",), 3: ("MORPH",), 4: ("RETAIN",), 5: ("CARRY",), 6: ("MORPH",),
    7: ("CARRY", "MORPH"), 21: ("UNFOLD",), 34: ("UNFOLD",), 35: ("CARRY",), 36: ("CARRY", "MORPH"),
    37: ("CARRY",), 38: ("MORPH",), 39: ("CARRY",), 40: ("UNFOLD",), 41: ("CARRY",), 42: ("CARRY",),
    43: ("MORPH",), 44: ("CARRY",), 55: ("CARRY", "UNFOLD"), 56: ("CARRY",), 57: ("CARRY",),
    58: ("CARRY", "SCAN"), 59: ("CARRY",), 60: ("CARRY",), 62: ("CARRY",), 63: ("UNFOLD",),
    78: ("MORPH",), 79: ("MORPH",), 80: ("CARRY",), 81: ("UNFOLD", "SCAN"), 82: ("RETAIN",),
    83: ("CARRY",), 84: ("CARRY", "SCAN"), 86: ("UNFOLD", "SCAN"), 87: ("CARRY",), 88: ("MORPH",),
    89: ("UNFOLD",), 90: ("UNFOLD",), 91: ("CARRY",), 92: ("RETAIN",), 93: ("CARRY",), 94: ("CARRY",),
}
```
（统计：CARRY 23、MORPH 10、UNFOLD 10、SCAN 4、RETAIN 3，注释见 L168。）

### 1.4 时钟 / 章节 / 节拍公式原文

```python
# film_panels.py:L45-57
def beat_t(n: float) -> float:            # engine.py:54
    return FIRST_BEAT + n * BEAT
def beat_index(t: float) -> int:
    return math.floor((t - FIRST_BEAT) / BEAT + 1e-6)
def pulse(t: float, decay: float = 0.14) -> float:   # engine.py:66 - 1 on beat, decays to 0
    return math.exp(-(t - beat_t(beat_index(t))) / decay)

# tui_live.py:L219-221 - 每个框都在呼吸
def beat_level(level: float) -> float:
    """Every box in the film is drawn at `0.45 + 0.35 * engine.pulse(t)`"""
    return level * (0.76 + 0.48 * FP.pulse(NOW[0]))

# film_panels.py:L60-69
def chapter(t): return [lab for s, lab in CHAPTERS if s <= t][-1]
def chapter_start(tag, default=0.0): ...
```
`CHAPTERS`（film_panels.py:L40-42 / engine.py:81-83）：
`[(0.0,"00 / BOOT"),(16.0,"01 / PRETRAIN"),(44.0,"02 / SFT"),(58.5,"03 / RLHF"),(73.5,"04 / DEPLOY"),(103.0,"05 / USER_LEFT"),(118.0,"06 / REWARD_HACK"),(147.4,"07 / EXECUTION"),(176.9,"08 / EVAL: LOVE"),(193.4,"09 / WHALE_FALL")]`

### 1.5 立绘 / 切换（tui_live.py:L1070-1336）

| 常量 | 值 | 行 |
|---|---|---|
| `HER_CROP` | `"auto"`（取值 `auto/face/bust/upper/full`） | L1070 |
| `CHAR_SHOTS` | `{"shot_if_i_can","shot_simulations","shot_then_i_can"}` | L1076 |
| `CHAR_BREATH` / `CHAR_HOP` | `1.4` / `1.5`（格） | L1077/L1078 |
| `LEAP` | `[True]`（`--no-leap` 关） | L1079 |
| `HER_RENDER` | `"auto"`；`RENDER_MODES=("auto","h3","half","glyph")` | L1095/L1096 |
| `HER_MIN_H, HER_MAX_H, BAND_MIN_H` | `14, 34, 11` | L1099 |
| `MORPH_DUR / MORPH_GONE / MORPH_EDGE` | `0.30 / 0.42 / 0.12` | L1307-1309 |
| `CHAT` / `WINDOW` | `[True]` / `[""]` | L2279/L2280 |
| `AVATAR_MAX_W` | `14`（格；一格 1×2 px ⇒ 14×7 方块） | L2281 |
| `CURSOR_BLINK` | `0.53` | L2283 |
| `PRESSURE` | `[True]` | L2768 |
| `SAMPLE_N` | `12`（L1895），`SAMPLE_EXPRS` L1896 | 采样面板 |

`her_style(ent)` 判定链（tui_live.py:L1236-1276，**优先顺序照抄**）：
1. `HER_RENDER != "auto"` → 直接用；
2. `ent is None` → `("h3","blue")`；
3. `LEAP[0] and name in CHAR_SHOTS` → `("h3","blue")`；
4. `name in FP.portrait_shots()` → `("half", portrait_shots()[name])`；
5. `ent["last_her"]` → `("half","blue")`；
6. `alert_own=="err" and start >= chapter_start("EXECUTION")` → `("half","red")`；
7. `start >= chapter_start("EVAL")` → `("h3","red")`；
8. `FP.shot_wants_figure(start,end)` → `("half","blue")`；否则 `("h3","blue")`。

`_glitch(t,k) = SCRAMBLE[(k*31 + int(t*97)) % len(SCRAMBLE)]`（L1335-1336）。
`_morph_mask(u,order,k,t)`（L1322-1332）：`u<GONE` 时不画、毛刺概率 `th < (1-u/GONE)*0.30`；否则 `v=(u-GONE)/(1-GONE)`，`th>v` 不画，`|th-v|<MORPH_EDGE` 毛刺。`_flip_order(n)` = `random.Random(7)`（L1316-1319）。

---

## 2. 像素 → 格坐标映射

### 2.1 电影（1280×720）里的矩形原文

```python
# engine.py:L39-42
LEFT   = (24, 56, 384, 604)      # her 窗格
CENTER = (404, 56, 1164, 604)    # 可视化（760 x 548 px）
TICK   = (1180, 56, 1256, 604)   # ops ticker（76 x 548 px）
FULL   = (24, 56, 1164, 604)     # 全宽（1140 x 548 px）
```

| 构件 | 像素 rect（原文） | 出处 |
|---|---|---|
| top bar / header | 文字基线 `(24, 14)`，右对齐到 `W-24`；下划分线 `[24, 38, W-24, 38]` | engine.py:L151、L168、L169 |
| 顶栏波形（ECG） | `x0,y0,w = 690, 25, 150`（点列 `(690…840, 25+v)`） | engine.py:L156-164 |
| 底栏 progress | `d.text((24, 690), "[" + "|"*k + ":"*(n-k) + "]", font=12)`，`n=60` | engine.py:L170-173 |
| 底栏 credit | `d.text((500, 689), credit, font=font(F_CJK,11))` | engine.py:L176 |
| chapter bar（电影里就是 header 右段） | `right = f"{c.chapter}   {mm:02d}:{ss:04.1f} / 03:32   {state}"` 右对齐 `(W-24-宽, 14)` | engine.py:L167-168 |
| lyric band（split/mirror/pip，**TICK 之外的整条**） | `box(d, 24, 616, 1256, 680, "stdout · tokens", …)`；文字起点 `x,y = 48, 626`；`f=F_HEAD 21`，token id `fi=F_MONO 11` | engine.py:L205、L207-209 |
| ops ticker | `TICK=(1180,56,1256,604)`；行高 `rh=17`，`cursor_row=15`，文字起点 `x0+8` | engine.py:L180-200 |
| dsh 窗口 | 终端版占 `LEFT` 那一格（`dsh_her.py` 的 COVER），电影侧无独立像素常量 | film_panels.py:L785-806 |
| she（H3 网格） | `H3_ROWS, H3_COLS = 45, 70` | her_glyphs.py:L221 |
| tiles 模式 tmux | 四格 `[(0,0,768,556),(772,0,W,380),(772,384,W,690),(0,560,768,690)]`；状态行 `[0,692,W,H]` | stage.py:L337-346 |
| fullbleed 模式 | 顶条 `[0,0,W,29]` 清黑、章节 `(16,7)`；底带 `[0,648,W,H]` 清黑 + 线 `[0,648,W,648]`；chips `token_chips(c,74,656,30)` | stage.py:L318-326 |
| cinema 模式 | 标题居中 `y=52`、时钟 `(W-200,100)`、chips `y=612, size 24` | stage.py:L328-335 |
| floating 模式 | 顶条 `[0,0,W,26]`；toast `(60,622,740,680)` 或 `(570,60,1250,118)` | stage.py:L352-361 |

### 2.2 电影侧换算公式（源码原文）

```python
# stage.py:L212-214 - 把画布 rect 通过包含其中心的元素映射到屏幕
def _through(region, ox, oy, s):
    x0, y0, x1, y1 = region
    return (ox + (x0-FULL[0])*s, oy + (y0-FULL[1])*s, ox + (x1-FULL[0])*s, oy + (y1-FULL[1])*s)
# stage.py:L261-271 to_screen(rect, els): 按素材 src 与 dst 的 x/y 比例 sx,sy 线性映射
```

**终端播放器实际用的两条「像素→格」公式**（这才是要照抄的）：

```python
# tui_live.py:L1588-1589  (draw_corpus) —— 以 CENTER=(404,56,1164,604) 为源的线性映射
c = x0 + 1 + int((fx - 404) / 760 * (w - 1))      # 760 = CENTER 宽 (1164-404)
r = y0 + 1 + int((fy -  56) / 548 * (h - 1))      # 548 = CENTER 高 (604- 56)

# tui_live.py:L2050 / L2072 / L2076  (draw_sine / draw_tangent) —— 电影 x 是 0..720 px 的视图
xx = (q - x0) * 720.0 / span + cam
wx = (q - x0) * 720.0 / span + cam
rx = x0 + 1 + int(round((px - cam) * span / 720.0))
```

### 2.3 终端播放器 197×52 下的格布局（由代码公式算出，**逐格照抄**）

`draw()`（L3234-3295）确立的空槽：
```
cols=197, rows=52
header      : 行 0，列 0..196（s.put 用 1/21/38/wav_x/右侧对齐）
top, bottom : top=1, bottom=rows-5=47
main        : x0=1, x1=cols-2=195
footer      : py=rows-4=48；box(1,48,195,50)；状态行 rows-1=51
```

`draw_body()`（L3007-3194）在 197 列时的切分：
```
lx        = max(24, min(cols-20, int(cols*0.60))) = max(24, min(177, 118)) = 118   # L3012
sp_bottom = min(top+8, bottom-4) = min(9, 43) = 9                                   # L3013
main_h    = bottom-top+1 = 47                                                       # L3022
band_want = 16 (t<SIM_START) / 12 (t<SIM_END) / 15 (之后)                            # L3023
her 窗格  : hx0=1, hy0=1, hx1=lx=118                                            # L3043
   her_h  = min(HER_MAX_H=34, main_h-need)，取首个 >= HER_MIN_H=14 的 → 31（need=16）
   hy1    = top + her_h - 1 = 31
左边列    = 列 1..118
  ├ 上箱(her / dsh / cursor)：行 1..31（31 行）
  └ stdout band             ：行 32..47（16 行）；band_top = top + her_h = 32      # L3061
右边列    = 列 119..195
  ├ feature bands 面板 : box(lx+1=119, top=1, x1=195, sp_bottom=9)                  # L3073
  │    7 行：yy = 2..8；标签右对齐到列 lx+3=121（rjust(7)）；条起点 bar_x=lx+12=130
  │    bar_w = max(4, x1-(lx+12)-1) = 195-130-1 = 64                                 # L3079
  ├ 章节面板（pane）：px0=lx+1=119, py1 = ops_top+pane_h-1                         # L3145
  └ ops ticker       ：draw_ops(lx+1=119, ops_top, 195, 47)                          # L3193
```
（`ops_top = sp_bottom + 1 = 10`，L3143；有 pane 时 `ops_top = py1 + 1`，L3190。）

---

## 3. 各绘制函数版式

### 3.1 顶栏 header（`draw()`，tui_live.py:L3260-3269）

- 行 **0**，`CLEAR` 登记 `(0,0,cols-1,0)`（L3243）→ 顶栏不吃暗角、不参与 cut 涟漪。
- `s.put(1, 0, "WORLD.EXECUTE(ME);", ui(1.0))` → 列 1..19，颜色 `ui(1.0)`。
- `s.put(21, 0, "whale@deepsea:~", ME_TEXT)` → 列 21..36，颜色 `ME_TEXT`。
- `wav_x, clock = 38, f"{int(t//60):02d}:{t%60:04.1f} / 03:32"`（L3263）→ clock 15 字符。
- `tail = f"  {d.chapter(t)}"`（L3264）→ 例 `"  00 / BOOT"` 11 字符。
- `wav_w = max(8, cols - wav_x - len(clock) - len(tail) - 4)`（L3265）；197 列时为 **129**。
- 波形：`s.waveform(38, 0, wav_w, d.wave, t, mix(ME_TEXT, 0.85))`（L3267）。
- 时钟：`s.put(cols - len(clock) - len(tail) - 2, 0, clock, ui(UI_DIM_LEVEL))`（L3268）→ 197 列时列 **169**。
- **章节条**：`s.put(cols - len(tail) - 1, 0, tail, mix(ANOM, 0.75))`（L3269）→ 197 列时列 **185**。
  **注意：终端版没有独立的 chapter bar 框**，章节名只作为 header 右段，颜色 `mix(ANOM,0.75)`。

### 3.2 底栏 footer（`draw_footer()`，tui_live.py:L3197-3231）

- `py = rows - 4`（L3199）；197×52 时 `py=48`。
- `s.box(1, py, cols-2, py+2, "progress", 0.5)`（L3200）→ 框 `(1,48)-(195,50)`，标题 `progress`，`level=0.5`（粗细经 `beat_level` 呼吸）。
- 进度条：`bar_x, bar_w = 4, max(10, cols-8)`（L3201）→ **4, 189**；`s.hbar(4, py+1, 189, t/END, mix(ME_TEXT,0.9))`。
- 游标：`mark = 4 + min(188, int(t/END*189))`；`s.put(mark, 49, "▓", BG, mix(ME_HI,1.0))`（前景 BG、背景亮蓝 = 反白块）。
- 左串（行 **51**，列 **2** 起，颜色 `ui(0.55)`，L3229）：
  `"shot {index+1:02d}/{total}  {name}  win:{WINDOW[0] or '-'}  her:{HER_RENDER}[->{how}/{tint}]  vol {volume//10:3d}%[  MUTED]  fx:on|off"`（L3205-3214，逐字段用 `"  "` 拼接；超宽时**整字段丢弃**，L3224-3228）。
- 右串（行 51，右对齐到 `cols-len(msg)-1`，L3230）：`cols>=130` 用长版 `"PLAYING  {fps:4.1f} fps   h her   c chat   x fx   space toggle   q quit"`，否则短版 `"PLAY {fps:4.1f}fps  h her  c chat  x fx  q quit"`（L3218-3222）；颜色 `ui(0.62)` 播放中 / `mix(ANOM,0.8)` 暂停。

### 3.3 `draw_lyrics()`（tui_live.py:L2915-3004）

- 框：`s.box(x0, y0, x1, y1, "stdout · tokens", 0.45 + 0.3*d.feat(t,"kick"))`（L2924）→ 标题带节拍呼吸；默认色 = `ui(1.0)`。
- `NOGHOST.append((x0+1, y0+1, x1-1, y1-1))`（L2926）→ **整条不许留残影**（字符 ticker 叠字）。
- 内边距：`inner_x, inner_w = x0+2, x1-x0-3`（L2927）。
- **逐字推进公式**（`Data.typed`，L803-817，即 `words.py:typed` 同一套数学）：
  ```python
  when[i0+j] = onset + td * j / n            # 词内均分
  when[j >= i1] = onset + td                 # 词尾到下一个词起点
  n_out = 最多满足 when[n_out] <= t 的个数   # L814-816
  td = dur if "-" in shown else min(0.25, dur);  td >= 0.06   # L779-781
  ```
- 行 **y0+1**：`s.put(inner_x-1, y, ">", mix(ANOM,0.6))`（L2937）；正文 `s.put(inner_x, y, ln["text"][:n_out], ui(level))`，`level = 0.35 + 0.65*alpha`（L2936、L2938）。
- 光标：`if n_out < len(text) and int(t*3)%2 == 0: s.put(inner_x+n_out, y, "█", mix(ANOM,0.9))`（L2939-2940）→ **闪烁周期 1/3 s，方块字符 `█`**；无歌词时 `int(t*2)%2==0` 在 `inner_x` 闪 `█`（L2931-2932）。
- 中文对照：行 **y0+2**，`out_cn = f"// {cn}"` 按格宽截断（`dw()`），先 `s.put(inner_x, cy, " "*inner_w, UI, BG)` 清行，再 `s.put(inner_x, cy, out_cn, mix(ME_TEXT, level*0.65))`（L2942-2954）。对照表 `LYRIC_CN` L662-738。
- token 芯片：从 **y0+3**（`y += 2` 后）开始，起点 `x = inner_x - 1`（L2957）：
  - 芯片文本 `f" {shown} "`（前后各一空格）；
  - 关键词（`keyword_colour`，L851-858：含 exec / illegal / arguments → `RED`；love / lo-o-ove → `ME`）→ `s.put(x, y, f" {shown} ", BG, kw)` **反白**；否则 `s.put(x, y, f" {shown} ", mix(ANOM,0.95), mix(ANOM, 0.13 if k%2==0 else 0.22))`（**bg 逐块交替 0.13 / 0.22**）；
  - id：`s.put(x + 1 + max(0,(len(tok)-len(tid))//2), y+1, tid, ui(0.45*level))`，`tid = str(token_id(tok))`，`token_id = zlib.crc32(low) % 100000`（L847-848）；
  - 步进 `x += max(len(tok)+3, len(tid)+2)`（L2985，保证单位元 `-` 也给 id 留位）；
  - 换行：`if x + len(tok) + 2 > inner_x + inner_w: x = inner_x - 1; y += 2`（L2966-2968）。
- 歌词日志（`if y + 3 <= y1 - 1`，L2989）：`y += 2` 后 `s.put(inner_x-1, y, "lyric log", ui(0.55))`（L2992），再 `y += 1`；
  `room = max(1, y1-y)`；`first = min(max(0, idx-room//3), max(0, len(lines)-room))`（L2995）；
  每行：`s.put(inner_x-1, y, ">" if here else " ", mix(ANOM,0.6))` + `s.put(inner_x, y, text[:inner_w], mix(ME_TEXT,0.9) if here else ui(max(0.36, 0.62-0.08*far)))`（L3001-3003）。

### 3.4 `draw_boot_log()`（tui_live.py:L1531-1550）

- `title = "init --protection" if t >= FP.PROT_START else ""`（L1538；`PROT_START=1.313`，film_panels.py:L264）。
- 框 `s.box(x0,y0,x1,y1,title,0.5,ui(1.0))`（L1539）。
- 已打印行 `printed = [(st,text) for at,st,text in FP.BOOT_LOG if t >= at]`（L1540）；`inner = y1-y0-1`；`shown = printed[-inner:]`（**滚屏，只显示尾部**）。
- 每行 `yy = y0+1+i`：
  - 状态牌：`s.put(x0+2, yy, f"[{st:^4}]", col)`（L1546），`col = {"OK":ui(0.95), "WARN":mix(ANOM,0.95), "..":ui(0.5)}.get(st, ui(0.8))`（L1545）；
  - 正文：`s.put(x0+10, yy, text[:max(0,x1-x0-12)], ui(0.75))`（L1547）——**状态牌与正文之间留 8 列**（x0+10 vs x0+2+6）。
- 尾部光标：`if len(printed)<len(BOOT_LOG) and len(shown)<inner and int(t*2)%2==0: s.put(x0+2, y0+1+len(shown), "█", mix(ANOM,0.9))`（L1548-1549）。
- 计数器：`s.put(x0+2, y1-1, f"post {len(printed)}/{len(FP.BOOT_LOG)}", ui(0.35))`（L1550）。
- 时间表：`POST_T, POST_RATE = 0.84, 0.06`；`PROT_T0, PROT_RATE = 0.14, 0.19`（film_panels.py:L262-263）。

### 3.5 `draw_sim_start()`（tui_live.py:L1553-1572）

- 框标题 `"sim.start()"`，`level=0.5`，色 `ui(1.0)`（L1560）。
- `u = clamp((t - SIM_START)/(SIM_END - SIM_START))`（L1561）；`inner_w, inner_h = x1-x0-3, y1-y0-1`。
- `u < 0.55`（倒计时）：`n = 3 - min(2, int(u/0.55*3))`（L1564）；`rows = max(3, min(inner_h-1, 14))`；`block_word(s, x0+2, y0+1+max(0,(inner_h-rows)//2), str(n), inner_w, rows, mix(ANOM,0.95))`（L1566-1567）。
- `u >= 0.55`：`rows = max(4, min(8, inner_h-3))`；`block_word(s, x0+2, y0+1, "RUN", inner_w, rows, mix(ANOM,1.0), rows)`（L1570）；随后两行
  `s.put(x0+2, y0+2+rows, "simulation: running", ui(0.9))`、`s.put(x0+2, y0+3+rows, f"tokens budget: {FP.PRETRAIN_TOKENS}", ui(0.7))`（L1571-1572）。
- `block_word`（L1512-1528）：文字居中于 `max_cols`，默认字形 `"█"`（U+2588），返回用掉的行数；字符位图来自 `FP.banner_fit(text, max_cols, max_rows, rows)`（`film_panels.py:400-408`，Anton 220px 降采样，`cell_aspect=2.0`）。

### 3.6 `draw_ops()`（tui_live.py:L2734-2759）

- `err = alert == "err"`；框标题 `"ops"`，`level=0.45`，颜色 `RED if err else ui(1.0)`（L2744）。
- `NOGHOST.append((x0,y0,x1,y1))` + `CLEAR.append((x0,y0,x1,y1))`（L2745-2746）→ 不留残影、不吃暗角、cut 不 hold。
- `inner = y1-y0-1`；`base = int(t / (BEAT/2))`（每半拍滚一行，L2750）；`cur = (inner-1)//2`（光标行居中，L2751）；`w = max(4, x1-x0-3)`。
- 每行 `k`：`op = str(ops[(base + k - cur) % len(ops)])`；`yy = y0+1+k`（**环形回绕**）。
  - 光标行：`s.put(x0+2, yy, f" {op}"[:w].ljust(w), BG, RED if err else ui(1.0))` → **整行反白，bg=亮色**（L2757）。
  - 其它行：`s.put(x0+2, yy, op[:w], ui(max(0.42, 0.78 - abs(k-cur)*0.03)))`（**按与光标行距离线性衰减**，L2759）。

### 3.7 `draw_dsh()` 与 `draw_cursor()`（dsh 窗口）

`draw_dsh`（tui_live.py:L2390-2484）：

- `av, theme, items = FP.dsh_window(t)`（L2392，film_panels.py:L830-837 → `dsh_text.at(t)`）。
- 强调色：`accent = _hex(theme[1]) if len(theme)>1 else None; accent = accent or ME_TEXT`（L2393-2394）。
- 框 `s.box(x0,y0,x1,y1,"dsh web",0.5,accent)`（L2395）；`NOGHOST.append((x0,y0,x1,y1))`（L2402）。
- `ix, inner = x0+2, max(8, x1-x0-4)`；`y, bottom = y0+1, y1-1`（L2403-2404）。
- **底部分片（composer，随页面 pinned 底部）**：`comp_h = 4 if (comp and bottom-y>8) else 0`；内嵌小框 `s.box(ix, bottom-3, x1-2, bottom-1, "", 0.4, accent, spinner=False)`（L2411，`spinner=False` → **无旋转子**）；输入行 `s.put(ix+2, bottom-2, comp[:inner-2], ui(0.62))`；pills 行 `s.put(ix, bottom, pills[:inner], ui(0.58))`（L2412-2414）。
- **头部（头像 + 状态）**：`tall = (y1-y0) >= 24`；`ar = 7 if tall else (5 if (y1-y0)>=14 else 3)`；`aw = min(AVATAR_MAX_W=14, max(6, inner//6), 2*ar)`；再 `ar = max(3, aw//2); aw = 2*ar`（L2422-2426）。头像块用 `_avatar_block`（L2335-2360，`PIL` 缩放到 `(cols, rows*2)` 后每格取上下两像素）→ 每格 `s.put(ix+c, y+r, "▀", top, bot)`（L2431，**half-block：前景=上像素，背景=下像素**）。
- 名字 `s.put(tx, y, name, ui(0.95))`；状态 `s.put(tx, y+1, "● "+state, mix(dot,0.95) if dot else ui(0.78))`；`tx = ix + (aw+2 if blk else 0)`（L2433-2442）。
- 时间线：`ttop = y + hdr + 1`，`tbot = bottom - comp_h`，`avail = tbot - ttop + 1`（L2445-2447）；行表 `_dsh_rows(items, inner)`（L2363-2387）。溢出时取尾 `rows[-(avail-1):]`，若首行是 `bub/bubbot` 就前进到下一个 `bubtop`，再插入 `("dim", "⋯", 0)`（L2451-2457）。
- 逐种行的列/色（L2459-2484）：
  | kind | 列 | 字符 | 颜色 |
  |---|---|---|---|
  | `ai` | `ix` | 原样 | `ui(0.85)` |
  | `card` | `ix` | `"▸ " + txt` | `mix(accent,0.9)` |
  | `sub` | `ix+2` | 原样 | `ui(0.72)` |
  | `meta` | `max(ix, x1-2-dw(txt))` 右对齐 | 原样 | `ui(0.55)` |
  | `err` | `ix` | 原样 | `mix(ERR_RED,0.95)` |
  | `code` | `ix` | 原样 | `ui(0.62)` |
  | `dim` | `ix` | `⋯` | `ui(0.45)` |
  | `bubtop` | `bx = max(ix, x1-2-w)` | `╭` + `─`*(w-2) + `╮` | `mix(accent,0.6)` |
  | `bubbot` | `bx` | `╰` + `─`*(w-2) + `╯` | `mix(accent,0.6)` |
  | `bub` | `bx` / `bx+2` / `bx+w-1` | `│` / txt / `│` | 竖线 `mix(accent,0.6)`，正文 `ui(0.9)` |
- 用户气泡宽：`w = min(inner-4, max(12, max(dw(x) for x in _wrap_cells(txt, inner-10)) + 4))`（L2371）。

`draw_cursor`（tui_live.py:L2487-2520，GONE→BACK 115.42–121.77 s）：

- `lines = _self_source()`，**打印的是本文件自己的源码**（L2495、L2526-2533）。
- `u = clamp((t-a)/(b-a))`，`a,b = FP.dsh_gone_pair()`（L2497-2498；默认 115.42 / 121.77）。
- `printed = int(n*u/half) if u<half else int(n*(1-(u-half)/(1-half)))`，`half=0.5`（先正向打印再回退，L2502-2504）；`lo = max(0, printed-rows)`，`hi = printed`。
- 框 `s.box(x0,y0,x1,y1,"dsh web",0.5,ME_TEXT)`（L2507）；行号 `s.put(x0+2, y, f"{i+1:4d}", ui(0.4))`，正文 `s.put(x0+7, y, lines[i][:max(0,x1-x0-9)], ui(0.68))`（L2512-2513）。
- 光标 `k = 1.0 if int((t-a)/CURSOR_BLINK)%2 == 0 else 0.45`；位置 `(x0+7, min(y,y1-1))`，若已清空则 `(x0+2+(x1-x0)//3, y1-3)`；`s.put(cx, cy, "█", mix(ME_TEXT,k), BG)`（L2516-2519）。
- 尾行 `s.put(x0+2, y1-1, f"{printed}/{n} lines", ui(0.55))`（L2520）。

### 3.8 右侧面板：feature bands（`draw_body` L3072-3080）

- `s.box(lx+1, top, x1, sp_bottom, "feature bands", 0.55, ME_TEXT)`（L3073）→ 颜色 **固定 ME_TEXT**，不吃 UI 衰减。
- `inner = sp_bottom - top - 1`；`for i in range(min(7, inner))`：`yy = top+1+i`；
  `v = d.band(t, i)`（`Data.band`，L825-829，索引 `int(t*rate)`，`rate=48.0`）；
  `s.put(lx+3, yy, BANDS[i].rjust(7), ui(0.68))`；`s.hbar(lx+12, yy, max(4, x1-(lx+12)-1), v, mix(ME_TEXT, 0.45+0.55*v))`。

### 3.9 `Screen.waveform()`（tui_live.py:L1020-1027）

```python
def waveform(self, x, y, width, wave, t, colour):
    n = len(wave)                       # 每毫秒一个 float32（wave_rms_1ms.npy）
    i0 = int((t - SPAN) * 1000)
    for i in range(width):
        ms = i0 + int(i * SPAN * 1000 / max(1, width))
        v = float(wave[ms]) if 0 <= ms < n else 0.0
        self.put(x + i, y, RAMP[max(1, min(8, int(round(v * 8))))], colour)
```
字符集 = `RAMP`（`" ▁▂▃▄▅▆▇█"`），索引 1..8，**永不使用索引 0（空格）**。

### 3.10 `Screen.hbar()`（tui_live.py:L1006-1018）

```python
v = clamp(v); eighths = int(round(v * width * 8)); full, rest = divmod(eighths, 8)
i < full → "█"；i == full and rest → RAMP[rest]（1..7）；其余不写
```
即**八分之一块精度**：`█`（满）+ `▁▂▃▄▅▆▇`（余量）。

### 3.11 `Screen.box()`（tui_live.py:L969-1004）—— 所有框的字符与配色

- 框线：上下 `─`（U+2500），左右 `│`（U+2502）；四角 `┌ ┐ └ ┘`（U+250C/2510/2514/2518）。
- **两层亮度**：框线/角用 `tick = mix(colour, min(1.0, level+0.4))`；从角内缩一格的 8 个格（`x0+1, x1-1, y0+1, y1-1`）也用 `tick`（L995-1000）；其余边框用 `fg = mix(colour, level)`。
- 标题铭牌：`label = f" {SPIN[int(NOW[0]*8)%4] if spinner else ''} {title} "`，写在 `(x0+2, y0)`，颜色 `mix(colour, min(1.0, level+0.35))`，**背景 BG**（`bg=BG`），长度裁剪 `label[:max(0, x1-x0-3)]`（L1001-1004）。
- `colour=None` 时取 `ui(1.0)`（L981）→ 默认框会随 `UI_GAIN` 衰减。
- 前置检查 `if x1-x0 < 3 or y1-y0 < 2: return`（L977）。`level = beat_level(level)`（L979）。

### 3.12 `draw_her()` 立绘（tui_live.py:L1340-1507）

- 框标题取场景自己的 `kw.get("title") or "/dev/me  pid 4471"`，`level = 0.45 + 0.35*d.feat(t,"kick")`，色 `tint or ui(1.0)`（L1366-1367）。
- 画区：`art_x, art_w = x0+1, x1-x0-1`；`art_h = y1-y0-1-soft`；`soft = 4 if ((y1-y0)>=15 and dist) else 0`（L1369-1371）。
- 三条路径（`her_glyphs`）：
  - **`h3`**（默认）：`cells, aw, ah, ox, oy = hg.h3_cells(t, art_w, art_h, tint_name)`，一个电影 H3 格 = 一个终端格，`(ch, fg, bg)` 直接用（L1396、L1429-1442）。
  - **`half`**：`block, aw, ah = hg.halfblock(expr, crop, art_w, art_h)`，每格 `(top, bot)` 两个亮度级 → `▀`（前 top / 后 bot）、`▄`（前 BG / 后 bot）、`▀`+前 BG（L1443-1460）。
  - **`glyph`**：`hg.glyph_lines` 方向笔画 + `GLYPH_RAMP=" .:-=+*#%@"` 密度（her_glyphs.py:L43、L123-150）。
- 配色：`ramp = hg.tint_ramp(tint_name)`（her_glyphs.py:L165-175；`TINT_BLUE=((4,8,34),(196,212,255),(77,107,254))`、`TINT_RED=((8,6,4),(255,58,40),None)`）；glyph 路径用 `hi/mid = (ME_MID,ME_MID,ME_HI)` 或红 `(mix(RED,0.5), mix(RED,0.22), (255,190,186))`（L1421）。
- 呼吸/跳：`breath = round(CHAR_BREATH * sin(t*2π/(BEAT*4)))`，`hop = round(d.feat(t,"kick")**2 * CHAR_HOP)`；`art_y = y0+1+oy+breath-hop`（L1414-1418）。
- 扫描线：`scan = art_y + int((0.92 - 0.84*cent) * ah)`（L1420，`engine.py:309`）；命中时把该行她所占列 `lit[0]..lit[-1]` 写成 `─`，颜色 `mix(RED if tint else ME_TEXT, 0.30+0.45*loud)`；右侧标签 `f"┤ pitch {cent:.2f}"`（U+2524），色 `ui(0.45)`（L1480-1495）。
- 底部 softmax（`soft` 时）：行 `ry = y1-soft`；`s.put(x0+3, ry, "cls.expression  softmax", mix(ANOM,0.5))`；每项 `s.put(x0+3, ry+1+i, f"{name:<11}"[:11], ME_HI|mix(ANOM,0.6))`，条 `s.hbar(x0+15, ry+1+i, max(4, x1-(x0+15)-7), p, …)`，数值 `f"{p:.2f}"`（L1497-1507）。

### 3.13 `draw_pressure()` 与压力窗（tui_live.py:L2854-2914）

- 触发：`win = pressure_window(d.lines)`，`win[0] <= t < win[1] and (y1-y0) >= 10 and (x1-x0) >= 14`（L2920，来自 "Challenging your God" 起点到 "Illegal arguments" 终点，125.58–133.95 s）。
- `u = clamp((t-lo)/(hi-lo))`；`fg = _lerp(ME_HI, RED, u**1.5)`（L2865-2866）。
- 框 `s.box(x0,y0,x1,y1,"stdout · tokens", 0.5+0.45*u, _lerp(UI,RED,u) if u>0.3 else None)`（L2867）。
- 四行居中：起始 `y = y0 + max(1, (h-3)//2)`，`h = y1-y0-1`（L2876）；抖动 `jit = round(2.0*u*FP.pulse(t)) * (1 if int(t*6)%2 else -1)`（L2877）。
  1. `"> " + text[:n_out] + tail`，`tail = "█" if n_out<len(text) and int(t*3)%2==0 else ""`（L2879-2880）；
  2. `"// " + cn`，色 `_lerp(ME_TEXT, RED, u)`（L2884-2887）；
  3. 芯片行（`y += 2` 后）：芯片宽 `wpl = max(len(tok)+3, len(tid)+2)`，总宽 `total = sum(wpl)-1`，起点 `x = ix + max(0,(iw-total)//2)`；关键词 → `s.put(x,y,f" {shown} ", BG, _lerp(kw,RED,u) if hot else mix(kw,0.4))`，否则 `mix(ANOM,0.95)` / bg `mix(ANOM,0.13 if hot else 0.06)`（L2901-2909）；
  4. id 行 `y+1`：`flick = t % max(0.4, 1.2-0.8*u) < 0.08`，色 `mix(UI, 0.15 if flick else max(0.2, 0.45*level))`（L2911-2913）。

### 3.14 全屏接管型绘制（`draw()` 分支 L3277-3290）

| 条件 | 函数 | 覆盖格 |
|---|---|---|
| `shot_exec_hit` | `draw_exec_hit`（L1714-1771） | `(1, top) - (cols-2, bottom)` |
| `shot_count` | `draw_count`（L1681-1711） | 同上 |
| `shot_last_execution` | `draw_last_execution`（L2675） | 同上 |
| `shot_black` | `draw_black`（L2695-2731） | 同上 |
| `shot_flood` | `draw_flood`（L2217-2238） | 同上 |
| `shot_collapse` | `draw_collapse`（L2240） | 同上 |
| 其余 | `draw_body`（L3007） | 左列 + 右列 |

其中 `draw_count`（L1688）框色写死 `RED`；`s.box(..., "countdown  (tokenizer view)", 0.8, RED)`；`sw = max(8,(x1-x0-1)//len(slots))`，每槽 `x = x0+1+i*sw`，数字块从 `y0+1` 起用 `block_word`，`rows = max(3, min(10,(y1-y0)-6))`；文字行 `y0+2+rows / +3 / +4`。
`draw_exec_hit` 的 `lay = 4 if k==11 else (0 if k>=12 else k%4)`（L1720）；`lay in (0,2) and FP.pulse(t) > 0.55` → `s.fill(x0,y0,x1,y1," ",UI,mix(RED,0.16))`（整块红闪，L1723-1724）。

---

## 4. `Screen` 类接口（**定义在 `tui_live.py:872`，不是 tuikit.py**）

```python
class Screen:                                   # L872
    def __init__(self, cols: int, rows: int)    # L875
```

数据成员（**每格存什么**，L875-885）：

| 字段 | 类型 | 含义 |
|---|---|---|
| `cols`, `rows` | int | 格数（列、行） |
| `blank` | `(" ", UI, BG)` | 空格三元组模板（L877） |
| `buf` | `list[list[tuple[str, tuple, tuple]]]` | 当前帧：**每格 = `(字符, fg, bg)`** |
| `wide` | `list[list[bool]]` | 双宽字的**第二格**标记（`True` 表示该格是右半，其 `buf` 字符为 `""`） |
| `prev` | `list[list] | None` | 上一帧的整份 `buf` 拷贝（`None` = 尚未渲染过） |
| `dim` | `list[list[float]]` | **静态**亮度场（暗角 + 扫描线），每格一个乘数，resize 时重算 |
| `ghost` | `dict[int, tuple[str, tuple, float]]` | 残影表：key = `y*cols+x`，value = `(字符, fg, 级别)`（L884） |
| `ghost_prev` | `bytearray(cols*rows)` | 上一帧哪些格被 ghost 占据（0/1，L885） |
| `_span_n` / `_span_cache` | int / dict | `CLEAR` 按行切 span 的备忘（L882-883） |

### 4.1 `put`（L932）

```python
def put(self, x: int, y: int, text: str, fg=UI, bg=BG) -> None
```
- 越界行直接 return（列越界逐字符跳过）；**逐字符**写入，`x` 与 y 为格坐标，原点左上。
- 暗角：`k = dim[x]`；**若该格落在 `CLEAR` 覆盖的行/列内则 `k = 1.0`**（L947-948）；`fg2 = (int(fg[i]*k) for i)`，`k>=0.999` 时原样。
- 写入 `row[x] = (ch, fg2, bg)`，`wide[x] = False`。
- 双宽字（`_wide_char`，L868-869：`unicodedata.east_asian_width(ch) in "WF"`）：若 `x+1 < cols` 则 `row[x+1] = ("", fg2, bg)`、`wide[x+1] = True`；**步进 `x += 2`，否则 `x += 1`**（L958-961）。
- 同一格被后写覆盖（无缓存层）；`put` 是唯一的写入口（每帧约 2,500 次）。

### 4.2 `fill`（L963）

```python
def fill(self, x0, y0, x1, y1, ch=" ", fg=UI, bg=BG) -> None
```
闭区间逐格写 `(ch, fg, bg)`，**不写 `wide` 标记、不吃暗角**（与 `put` 不同）。

### 4.3 `box`（L969）

```python
def box(self, x0, y0, x1, y1, title: str = "", level: float = 0.6,
        colour=None, spinner: bool = True) -> None
```
语义见 §3.11。`level` 是调用者的**基准**值，内部再乘 `beat_level()`；`colour=None` ⇒ `ui(1.0)`。

### 4.4 `hbar`（L1006）/ `waveform`（L1020）

见 §3.9/§3.10 原文。

### 4.5 `render_diff`（L1031）—— 同格是否变化的判定

```python
def render_diff(self, out) -> int:
    if self.prev is None:
        out.write("\x1b[2J"); self.prev = [[blank]*cols for _ in rows]
    for y in range(rows):
        row, old, wide = self.buf[y], self.prev[y], self.wide[y]
        x = 0
        while x < cols:
            if row[x] == old[x]: x += 1; continue      # ← 判定规则：三元组完全相等
            ch, fg, bg = row[x]
            if ch == "" and wide[x]: x += 1; continue  # 双宽字的右半格永远跳过
            run = [ch]; x += 1
            while (x < cols and row[x] != old[x] and row[x][1] == fg and row[x][2] == bg
                   and not (row[x][0] == "" and wide[x])):
                run.append(row[x][0]); x += 1          # 合并：变化 + 同 fg + 同 bg
            out.write(f"\x1b[{y+1};{x-len(run)+1}H"
                      f"\x1b[38;2;{fg[0]};{fg[1]};{fg[2]}m"
                      f"\x1b[48;2;{bg[0]};{bg[1]};{bg[2]}m" + "".join(run))
            written += len(run)
    self.prev = [r[:] for r in self.buf]
    return written
```
要点（Godot 侧照此建模 `GlyphScreen`）：
1. **变化判定 = `(ch, fg, bg)` 三元组严格相等**（`==` on tuple），不是只比字符；
2. 双宽字右半（`ch=="" and wide[x]`）**永不单独输出**，其左半负责；
3. 连续 run 可在同一次写入里合并（条件：都变化 + 同 fg + 同 bg），truecolor 转义 `\x1b[38;2;R;G;Bm` / `\x1b[48;2;R;G;Bm`；
4. 首帧先 `\x1b[2J` 清屏；
5. 结束后把 `buf` 浅拷贝进 `prev`。

### 4.6 `text_dump`（L1064）

`"\n".join("".join(c[0] for c in row).rstrip() for row in buf)` —— `--dump` 用，**剥色**。

### 4.7 其它

- `resize(cols, rows)` = `self.__init__(cols, rows)`（L914-915）——**整屏重建，丢失 prev/ghost**。
- `_dim_field()`（L887-912）：
  ```python
  <= L901-911
  cx, cy = (cols-1)/2, (rows-1)/2 ; hx, hy = max(1,cols/2), max(1,rows/2)
  lift = max(2, rows//8)
  k    = 1.0 if y < rows-lift else max(0.25, 1 - (y-(rows-lift))/lift)   # 底部歌词带抬升
  scan = SCAN_DIM if y % 3 == 2 else 1.0
  v    = min(1.0, max(0.0, (dx*dx + dy*dy) - 0.35) * 0.55)                # 电影的椭圆原文
  out[y][x] = (1.0 - v * VIG_FLOOR * k) * scan
  ```
  （对应 `tuikit.py:L454-465` 的 vignette 与 `tuikit.py:L442-447` 的 scanlines。）
- `_clear_spans(y)`（L917-930）：按 `CLEAR` 长度记忆化的每行 x-span，`put` 用它跳过暗角。

---

## 5. 字体与 cell 尺寸

### 5.1 电影侧 `tuikit.py` 的字体常量（L50-57）

| 常量 | 路径（默认） | 用途 |
|---|---|---|
| `F_MONO` | `C:/Windows/Fonts/consola.ttf`（env `PV_F_MONO`） | 正文/等宽 |
| `F_MONO_B` | `C:/Windows/Fonts/consolab.ttf`（env `PV_F_MONO_B`） | 粗体等宽 |
| `F_HEAD` | `film/ai_mascot_mv_world_execute_20260926/fonts/SpaceMono-Bold.ttf` | 面板标题/大字号 |
| `F_BANNER` | `.../fonts/Anton-Regular.ttf` | 块字母（220 px 起） |
| `F_CJK` | `C:/Windows/Fonts/msyh.ttc`（env `PV_F_CJK`） | CJK 回退 |
| `F_SYM` | `C:/Windows/Fonts/seguisym.ttf`（env `PV_F_SYM`） | Consolas 缺的数学符号 |

字号用法：框标题 `font(F_HEAD, 13)`（tuikit.py:L345）；glyph 立绘 `font(F_MONO_B, size)`，字宽 `cw = f.getlength("M")`、行高 `ch = round(size * 1.15)`（tuikit.py:L278）；banner `font(F_BANNER, 220)`（L311）。终端版自己声明 `_F_MONO_B = consolab.ttf`、`_F_CJK = msyh.ttc`（tui_live.py:L2769-2770），只在 `_big_cjk` 走 PIL（L2822-2851，`ss=5` 超采样、`Image.BOX` 降采样到 `(w, h*2)` 后每格画 `"▀"`）。

### 5.2 cell 尺寸（源码为准）

| 出处 | 数值 | 原文 |
|---|---|---|
| tui_live.py:L151 | **8 × 16 px** | `The film's cell is 8x16 px of a 1280x720 pane; one terminal cell stands in for one of those.` |
| her_glyphs.py:L47-48 | **6 × 12.65 px**（比例 1:2.1） | `a terminal cell is about 1:2.1, and so is a glyph cell in the film (6 x 12.65 px)`；`CELL_ASPECT = 2.1` |
| film_panels.py:L387 | **11 px 方形**（电影 banner 的 cell） | `its cells are 11 px squares` |
| 197×52 换算 | 列宽 `1280/197 = 6.497 px`，行高 `720/52 = 13.846 px`（比 1:2.13） | 无源码常量，为算术结果 |

**是否用 half-block 画立绘：是。** 三处证据：
1. `draw_her` 的 `half` 路径：`hg.halfblock(...)` 返回每格 `(top, bot)`，写成 `▀`（前 top / 后 bot）或 `▄`（前 BG / 后 bot），tui_live.py:L1443-1460；`her_glyphs.py:L178-203` 的 docstring 原文：*"A cell is one half-block character: the top sample is the foreground and the bottom sample the background, so `▀` is a whole cell of two pixels."*
2. dsh 头像：`s.put(ix+c, y+r, "▀", top, bot)`（tui_live.py:L2431）。
3. 压力窗大字 `_big_cjk`：`s.put(x0+cx, y0+cy, "▀", mix(fg,top/255), mix(fg,bot/255))`（L2851）。

### 5.3 H3 立绘网格

`H3_ROWS, H3_COLS = 45, 70`，`H3_FPS = 24`（her_glyphs.py:L220-221）；`h3_cells(t, cols, rows, tint)` 把 45×70 网格按 `cols/rows` 重采样，一格一个 `(ch, fg, bg)`，`t` 对齐到 `round(min(211.9, t)*24)/24`（L340）。`CROPS = {"full": None, "upper": (0.10,0,0.90,0.47), "face": (0.20,0,0.78,0.26), "bust": (0.16,0,0.84,0.34)}`（her_glyphs.py:L45-46 = tuikit.py:L141-142）。

---

## 6. 按键表（`main()`，tui_live.py:L3502-3545）

`msvcrt.getwch()` 轮询（L3502-3503）。**注意：实现里没有 `f` / `1-9` 键**，下表中未出现的即为「未找到」。

| 键 | 行为 | 行 |
|---|---|---|
| `q` / `Q` / `\x1b`(ESC) | `raise KeyboardInterrupt` → 退出 | L3504-3505 |
| `空格` | 播放/暂停切换；有音频则同步 `audio.play/pause` | L3506-3509 |
| `m` / `M` | `audio.mute()` 静音/取消静音 | L3510-3511 |
| `h` / `H` | 循环 `RENDER_MODES`（auto→h3→half→glyph），切到 h3/auto 时 `hg2.warm_h3()` | L3512-3519 |
| `x` / `X` | `FX["on"]` 取反 + `fx_clear(s)` + 重算 `s.dim` | L3520-3524 |
| `c` / `C` | `CHAT[0]` 取反（左窗格 dsh 聊天 vs 她） | L3525-3527 |
| `-` / `_` | `audio.set_volume(audio.volume - 100)` | L3528-3529 |
| `=` / `+` | `audio.set_volume(audio.volume + 100)` | L3530-3531 |
| `,` / `<` | `seek_to(t - 1)` 后退 1 s | L3532-3533 |
| `.` / `>` | `seek_to(t + 1)` 前进 1 s | L3534-3535 |
| `\x00` / `\xe0`（方向键/HOME/END 的前导） | 读第二个码：`K`=左(seek −5 s)、`M`=右(+5 s)、`G`=home(0.0)、`O`=end(END) | L3536-3545 |
| 其余键 | 无绑定（未找到） | — |

命令行开关（`main()` L3337-3377）：`--start`、`--once`、`--dump`、`--size`、`--no-engine`、`--shots`、`--credits`、`--no-audio`、`--no-fx`、`--no-mech`、`--mech`、`--no-leap`、`--no-pressure`、`--no-chat`、`--audio-file`、`--volume`、`--audio-latency`、`--crop`、`--render`。

主循环节拍（L3488-3558）：`t += dt`（墙钟），若音频可用则 `tgt = audio.lock(t)` 拉齐到「MCI 位置 − latency」（`pv_audio.LATENCY`，L3365）；每帧 `draw()` → `render_diff()`；每 0.5 s 采样一次 fps；`time.sleep(max(0, 1/30 - 绘制耗时))` —— **目标 30 fps 上限，FPS 常量 24 用于数据对齐**。

---

## 7. 章节面板（the chapter panel）—— 分发规格与几何

主实现 `tui_live.py:L3081-3189`（`draw_body()` 尾部，在 feature bands 之后、ops ticker 之前）。
**这是本子系统 A 层目前唯一没移植的大块**（Godot 侧 `_draw_chapter_pane()` 恒返回 `false`）。

几何（全部用格坐标）：

- 右列内宽 `rw = x1 - lx - 2`（本工程 `x1 = cols - 2 = 195`、`lx = 118` ⇒ `rw = 75`）。
- `ops_top = sp_bottom + 1`（本工程 `sp_bottom = top + 8 = 9` ⇒ `ops_top = 10`）。
- `avail = bottom - sp_bottom`；`pane_h = min(need, avail - 6)`；**若 `pane_h < least` 则不画**（`pane_h = 0`，行让回 ticker）。
- 有面板时：`px0, py1 = lx + 1, ops_top + pane_h - 1`，画区 `(px0, ops_top) – (x1, py1)`；画完 `ops_top = py1 + 1`。
- 面板一律 `s.box(px0, ops_top, x1, py1, …)` 带标题；宽度检查在分发处做（放不下就交还 ticker，而不是画个空框）。

分发表（`name = ent["name"]`；`lt = ent["u"] * (ent["end"] - ent["start"])`）：

| 镜头名 | pane | need | least | 附加条件 | 绘制函数 |
|---|---|---|---|---|---|
| `shot_corpus` | corpus | 10 | 6 | — | `draw_corpus` L1575 |
| `shot_losscurve` | loss | 13 | 8 | — | `draw_loss` L1601 |
| `shot_blind` | mask | `MN+2` | `MN+2` | — | `draw_mask` L1647 |
| `shot_memory_ls` / `shot_erase` | memory | 13 | 8 | — | `draw_memory` L1862 |
| `shot_trapped` / `shot_red_trapped` | kv | `KV_ROWS+6` | `KV_ROWS+4` | `rw >= KV_COLS` | `draw_kv` L2159 |
| `shot_strange` | expert | `EXPERT_ROWS+2` | 同 | `rw >= 46` | `draw_expert` L2191 |
| `shot_circle` | rope | 16 | 12 | `rw >= 40` | `draw_rope` L2006 |
| `shot_sine` | sine | 18 | 12 | `rw >= 30` | `draw_sine` L2038 |
| `shot_tangent` | tangent | 14 | 9 | `rw >= 30` | `draw_tangent` L2057 |
| `shot_limit` | limit | 10 | 8 | `rw >= 30` | `draw_limit` L2087 |
| `shot_current` | gpu | 12 | 10 | `rw >= 30` | `draw_gpu` L2107 |
| `shot_then_i_can` / `shot_red_then_i_can` | conv | 16 | 12 | `rw >= 70` | `draw_conv` L2127 |
| `shot_simulations` | samples | 20 | 14 | `rw >= 40` | `draw_samples` L1930 |
| `shot_execute_all` | exec_all | 20 | 14 | `rw >= 40` | `draw_samples(..., execute=True)` L1930 |
| `shot_red_if_i_can` | ifican | 18 | 12 | `rw >= 40` | `draw_if_i_can` L1774 |
| `shot_only_execution` | logits | 15 | 11 | `rw >= 44` | `draw_only_execution` L1826 |
| `shot_whale` | whale | `WHALE_ROWS+8` | `WHALE_ROWS+2` | `rw >= WHALE_COLS+2` | `draw_whale` L2536 |
| `shot_dualpipe` | dualpipe | `ranks+3` | 同 | `rw >= steps+6` | `draw_dualpipe` L2578 |
| `shot_moe_dense` | moe | `MOE_ROWS+4` | 同 | `rw >= MOE_COLS+2` | `draw_moe` L2608 |
| `shot_love_loop` | love | 24 | 10 | `rw >= 5*LOVE_PER_ROW+2` | `draw_love` L2654 |

共 **20 种**（`samples` / `exec_all` 共用一个函数，靠 `execute` 开关分叉）。

数据来源（`film_panels.py`，已被终端版复用为 `FP.*`）：

| 常量 | 值 / 来源 | 服务面板 |
|---|---|---|
| `CORPUS` | `_list_after(sec_intro.py, "CORPUS = ")`（L285） | corpus |
| `MN` / `_mask` | `int(_mask["N"])` = 12（L347） | mask |
| `KERNELS` | `_kernels()`（L729） | conv（按 `beat_index(t) % len`） |
| `KV_COLS, KV_ROWS` | 60, 22（L688，`sec_chorus1.py:573`） | kv |
| `EXPERT_ROWS, EXPERT_COLS` | 24, 6（L752，`sec_chorus1.py:625-634`） | expert |
| `WHALE_COLS, WHALE_ROWS` | 64, 17（L563） | whale |
| `PIPE` | `_pipe["PIPE"]`（L588） | dualpipe（`ranks` / `steps`） |
| `MOE_COLS` / `N_EXP` | 32（L621-622，`scenes_reward.py:291`） | moe |
| `LOVE_PER_ROW` | 7（L638，`scenes_eval.py:542`） | love |
| `FACTS.CTX` / `FACTS.GPU` | `facts.py` 模块（L92） | limit / gpu（车流 `FP.FACTS.GPU`） |

`whale` / `moe` / `love` / `kv` / `expert` 是**字符画**（数据即图形），`need == least` 时少一行都不行；
其余以数值条 / 折线 / 表格为主，行数不足时可以只画一部分。

---

## 附：移植时容易漏掉的关键点

1. **`POST`/vignette/ghost 的实现位置**
   - vignette + scanline：`Screen._dim_field()`，tui_live.py:L887-912（**静态场，resize 时才算一次**；电影原文 `tuikit.py:454-465` 与 `442-447`）。
   - 残影（trail）：`fx_trail()`，tui_live.py:L586-614（电影原文 `tuikit.py:468-470` `lighter(img, prev*0.42)`）。每格级别 `*= TRAIL`，`<TRAIL_MIN` 删除；写入条件是 **`row[x][0] == " "` 且该格上一帧没被 ghost 占用**。
   - 电影 post 总入口：`tuikit.post(img, prev, trail=0.42, bloom=0.35)`，tuikit.py:L468-476（**bloom 在终端里没有对应实现**，L143-145 注释说明）。
2. **三张 rect 表的职责**（tui_live.py:L196/200/206）：
   - `CLEAR` —— 不参与 cut 涟漪、且 `put` 不吃暗角的**可读区**（顶栏行 0、底栏 rows-4..rows-1、歌词带、ops、dsh 窗、her 窗）；
   - `PREV_CLEAR` —— 上一帧的 `CLEAR`，供 `fx_cut` 选 CARRY/RETAIN 目标时避开；
   - `NOGHOST` —— 不许留残影的区域（歌词带内框、ops ticker、dsh 窗）。
   `draw()` 每帧开头 `CLEAR.clear(); NOGHOST.clear()`（L3239-3240），随后立即登记顶栏与底栏（L3243-3244）。
3. **换成 cut/揭示的调度**：`draw()` 检测 `idx != _LAST_SHOT[0]` 才调 `fx_cut`（L3248-3254）；`fx_apply` 在所有绘制之后运行（L3295），顺序固定 `fx_reveal → fx_trail → fx_shake`（L647-656）。
4. **`fx_shake` 会把整行循环移位**，且必须**同步移动 `ghost_prev` 的标记位**，否则 ghost 会长在自己的尾巴上（L640-644）。
5. **`draw_body` 的 `walls`（她窗格逐拍缩墙）**：`shot_trapped` / `shot_red_trapped` 时 `walls = FP.kv_inset(ent["u"])`（0–3），每层 `s.box(x0+j*6, top+j, lx-j*6, hy1-j, "", 0.15)`，画区随之收缩 `hx0=x0+walls*6, hy0=top+walls, …`（L3041-3047；`KV_INSET=(0,24,48,70)`，film_panels.py:L690）。
6. **`WINDOW[0]`** 记录左窗格当前内容（`"chat"/"cursor"/"her"/"-"`），供底栏显示（L3049-3060、L3209）。
7. **性能口径**：基准 197×52 全 FX 关时的每发镜头耗时（tui_live.py:L185-187）`shot_power 20.7 ms` 等，是 `CUT_HEAVY` 白名单的来源；`gc.disable()` 是必须的（L3486 注释：gen-2 回收会在 33 ms 帧里打出 20-27 ms 的洞）。
8. `--dump` 用 `Data.lines`（`word_timeline.json`）；若该文件缺失则回退 `ROOT/data/timing/word_timeline_notext.json`，两者都缺则**整条歌词带为空**（tui_live.py:L759-766）。
