class_name PV
extends RefCounted

## world.execute(me) 终端 PV 播放器 —— 全局常量与纯函数。
##
## 对应参考实现 `tui_live.py` 顶部常量区（逐值见 tools/ref/layout.md §1）。本类只放常量与
## 纯函数，不持有实例状态（除 UI_GAIN / NOW / FX 三个「每帧可变」的静态变量，对应 Python
## 侧 `UI_GAIN[0]`、`NOW[0]`、`FX[]`）。
##
## 颜色一律用 `0xRRGGBB` 整数：每格存储/比较都用它，且 `mix()` 里 `int(base + (c-base)*level)`
## 的截断语义与 Python `int()` 完全一致（Godot 的 `int(float)` 同样向零截断）。

# ---------------------------------------------------------------- 时间与屏幕（§1.1）
const FPS := 24
const END := 211.9
const SPAN := 2.4
const SIM_START := 12.389
const SIM_END := 16.082
const BEAT := 60.0 / 130.0          # 0.46153846153846156，BPM 130
const FIRST_BEAT := 0.1587

const BANDS := ["40-120", "120-300", "300-700", "700-1.5k", "1.5-3k", "3-6k", "6-10k"]
const RAMP := " ▁▂▃▄▅▆▇█"
const SCRAMBLE := "!<>-_\\/[]{}=+*^?#%$&@01|~:;"
const SPIN := "|/-\\"

# ---------------------------------------------------------------- deepsea 调色板（§1.2）
const BG := 0x04070f
const UI := 0xc8d6ea
const UI_DIM_LEVEL := 0.55
const ME := 0x4d6bfe
const ME_MID := 0x4d6bfe
const ME_TEXT := 0x7e98ff
const ME_HI := 0xc4d4ff
const RED := 0xff3b30
const ANOM := 0xffcc00
const UI_DIM := 0x78869e
const ERR_RED := 0xff4a3d

# ---------------------------------------------------------------- 后处理与 cut FX（§1.3）
const TRAIL := 0.42
const TRAIL_MIN := 0.06
const SCAN_DIM := 0.86
const VIG_FLOOR := 0.75
const CUT_DUR := 0.55
const CUT_CELL := 0.09
const CUT_FRONT := 0.40
const CARRY_DUR := 0.45
const CARRY_CELLS := 13
const RETAIN_HOLD := 0.50
const RETAIN_WIDE := 56
const CUT_REVEAL := 3
const SHAKE_LEVEL := 0.45

const SHAKE_SHOTS := ["shot_strange", "shot_collapse", "shot_flood", "shot_erase", "shot_drowned"]

const CUT_HEAVY := [
	"shot_power", "shot_flood", "shot_love_loop", "shot_travel", "shot_isolation",
	"shot_unite", "shot_red_if_i_can", "shot_you_left", "shot_eggplant", "shot_exec_hit",
]

## CUT_MECH（§1.3，逐字照抄）：镜头号 → 该次硬切使用的机制组合。
const CUT_MECH := {
	1: ["UNFOLD"], 2: ["MORPH"], 3: ["MORPH"], 4: ["RETAIN"], 5: ["CARRY"], 6: ["MORPH"],
	7: ["CARRY", "MORPH"], 21: ["UNFOLD"], 34: ["UNFOLD"], 35: ["CARRY"], 36: ["CARRY", "MORPH"],
	37: ["CARRY"], 38: ["MORPH"], 39: ["CARRY"], 40: ["UNFOLD"], 41: ["CARRY"], 42: ["CARRY"],
	43: ["MORPH"], 44: ["CARRY"], 55: ["CARRY", "UNFOLD"], 56: ["CARRY"], 57: ["CARRY"],
	58: ["CARRY", "SCAN"], 59: ["CARRY"], 60: ["CARRY"], 62: ["CARRY"], 63: ["UNFOLD"],
	78: ["MORPH"], 79: ["MORPH"], 80: ["CARRY"], 81: ["UNFOLD", "SCAN"], 82: ["RETAIN"],
	83: ["CARRY"], 84: ["CARRY", "SCAN"], 86: ["UNFOLD", "SCAN"], 87: ["CARRY"], 88: ["MORPH"],
	89: ["UNFOLD"], 90: ["UNFOLD"], 91: ["CARRY"], 92: ["RETAIN"], 93: ["CARRY"], 94: ["CARRY"],
}

# ---------------------------------------------------------------- 每帧可变状态
## 本帧的 UI 增益（`film_panels.ui_gain_at` 的结果，所有 `ui()` 色都要过它）。
static var UI_GAIN := 1.0
## 本帧时间（`box()` 的旋转子与呼吸需要）。
static var NOW := 0.0
## FX 总开关；`--no-fx` 等价于把 on/reveal/mech/trail/vig 全关。
## C 层新增五项（`tools/ref/c_layer_plan.md` §7）：`post` 全屏后处理、`motion` 特征反应
## （含滑动转场的调度）、`stage` 屏幕模式与黑边、`points` 点云、`whale` 落鲸雪尘。
## 五者同样挂在 `on` 之下。
static var FX := {
	"on": true, "reveal": true, "mech": true, "trail": true, "vig": true, "shake": true,
	"post": true, "motion": true, "stage": true, "points": true, "whale": true,
}

# ---------------------------------------------------------------- 颜色与数值

static func rgb(r: int, g: int, b: int) -> int:
	return (r << 16) | (g << 8) | b


static func ch_r(c: int) -> int:
	return (c >> 16) & 0xff


static func ch_g(c: int) -> int:
	return (c >> 8) & 0xff


static func ch_b(c: int) -> int:
	return c & 0xff


static func to_color(c: int) -> Color:
	return Color8(ch_r(c), ch_g(c), ch_b(c))


## `tui_live.mix()`：把 c 以 level 混到 base 上，逐通道向零截断。
static func mix(c: int, level: float, base: int = BG) -> int:
	level = clampf(level, 0.0, 1.0)
	return rgb(
		int(ch_r(base) + (ch_r(c) - ch_r(base)) * level),
		int(ch_g(base) + (ch_g(c) - ch_g(base)) * level),
		int(ch_b(base) + (ch_b(c) - ch_b(base)) * level))


## `tui_live.ui()`：UI 色经过本帧增益。凡界面色（框/标题/时钟/章节/ops）都必须过它。
static func ui(level: float) -> int:
	return mix(UI, level * UI_GAIN)


# ---------------------------------------------------------------- 节拍与呼吸（§1.4）

static func beat_t(n: float) -> float:
	return FIRST_BEAT + n * BEAT


static func beat_index(t: float) -> int:
	return int(floor((t - FIRST_BEAT) / BEAT + 1e-6))


## 1.0 落在节拍上，随后按 decay 指数衰减到 0。
static func pulse(t: float, decay: float = 0.14) -> float:
	return exp(-(t - beat_t(beat_index(t))) / decay)


## 每个框都在呼吸：`level * (0.76 + 0.48 * pulse(NOW))`。
static func beat_level(level: float) -> float:
	return level * (0.76 + 0.48 * pulse(NOW))
