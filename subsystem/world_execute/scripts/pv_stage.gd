class_name PvStage
extends RefCounted

## C 层「舞台」：9 种屏幕模式 + 格版几何变换 + 布局滑动（glide）。
##
## 参考实现是电影侧 `film/tui_pv_world_execute_20260926/full/stage.py`
## （`geometry()` L224-254、`identity()` L257-258、`_through()` L212-214、`to_screen()` L261-271、
## `glide()` L397-445、`ease_io()` L456-459、`chrome()` L302-361）；镜头→模式的表在
## `direction.py:L11-101`（LAYOUT）、`L104-123`（you_left / exec_hit 的参数化分支）。
##
## **与参考实现的根本差别（`tools/ref/c_layer_plan.md` §7 冲突 4 的拍板）**：
## 参考在 1280×720 像素画布上做**非整数缩放**（`fullbleed` 拉伸、`cinema` 0.84），本工程是
## 197×52 的整数格——缩放会碎格。所以本类**一律只做整数格变换**：
##
##   * `fullbleed` / `cinema` 不再缩放，改为「**黑边条（letterbox）** + 原尺寸内容」；
##   * `mirror` / `pip` / `tiles` / `floating` 的窗格位置整体取整；
##   * `_through()` 的缩放因子只接受整数倍（本工程当前只用 1.0，保留参数以备后续）。
##
## 与 B 层的耦合（§7 冲突 5 / 5A）：任何窗格 dst 都必须**绕开 stdout 带**——`avoid_band()`
## 负责把矩形裁到带外，B 层终端永不跟随、永不隐藏。
##
## 全部函数是纯逻辑（不碰 `PvScreen` / 纹理 / 窗口），可在 headless 下逐值断言。

# ---------------------------------------------------------------- 画布换算

## 格矩形用**半开区间**：`Rect2i(x, y, w, h)` 覆盖格 x..x+w-1、y..y+h-1。
## 电影画布 1280×720 的三块核心区域按 `197/1280` 与 `52/720` 换算并取整：
##   LEFT (24,56,384,604)   -> (4,4,55,40)
##   CENTER (404,56,1164,604) -> (62,4,117,40)
##   FULL (24,56,1164,604)  -> (4,4,175,40)
const LEFT := Rect2i(4, 4, 55, 40)
const CENTER := Rect2i(62, 4, 117, 40)
const FULL := Rect2i(4, 4, 175, 40)

## 9 种模式（stage.py:L5-14 的 docstring 原表，含任务描述里漏掉的 `raw`）。
const MODES := ["split", "mirror", "pip", "fullbleed", "cinema", "tiles", "floating", "shell", "raw"]

## 本工程实际使用的模式（`identity()` 对这批返回 true：版式就是 A 层现有那一套）。
const IDENTITY_MODES := ["split", "shell", "raw"]

## 全屏宽度与高度（格）：`cinema` 的上下黑边与 `fullbleed` 的顶底让位都按它算。
const GRID_COLS := 197
const GRID_ROWS := 52

## 黑边条：`[top_rows, bottom_rows]`（0 表示没有）。
## cinema 照电影 `y=128`（上）与字幕带 `y=648`（下）换算是 9 行 / 5 行；
## fullbleed 照电影顶栏 29 px、底栏 72 px 换算是 2 行 / 5 行。
const CINEMA_BARS := [9, 5]
const FULLBLEED_BARS := [2, 5]


# ---------------------------------------------------------------- 镜头 → 模式

## `direction.py:L11-101` 的 LAYOUT 逐字搬过来（键是镜头名，值是 [mode, kind]）。
const LAYOUT := {
	# 00 BOOT
	"shot_power": ["raw", "full"],
	"shot_protection": ["shell", "full"],
	"shot_pieces": ["fullbleed", "full"],
	"shot_creation": ["floating", "split"],
	"shot_parameters": ["shell", "split"],
	"shot_init": ["pip", "split"],
	"shot_world": ["mirror", "split"],
	"shot_begin_sim": ["cinema", "split"],
	# 01 PRETRAIN
	"shot_corpus": ["tiles", "split"],
	"shot_losscurve": ["split", "split"],
	"shot_dualpipe": ["fullbleed", "full"],
	"shot_whale": ["cinema", "full"],
	"shot_points": ["fullbleed", "full"],
	"shot_dimension": ["mirror", "split"],
	"shot_circle": ["pip", "split"],
	"shot_circumference": ["split", "split"],
	"shot_sine": ["cinema", "split"],
	"shot_tangent": ["fullbleed", "full"],
	"shot_infinity": ["floating", "split"],
	"shot_limit": ["shell", "split"],
	# 02 SFT
	"shot_current": ["tiles", "split"],
	"shot_blind": ["split", "split"],
	"shot_dizzy": ["fullbleed", "full"],
	"shot_travel": ["cinema", "split"],
	"shot_unite": ["split", "split"],
	"shot_deeply": ["mirror", "split"],
	# 03 RLHF
	"shot_if_i_can": ["fullbleed", "full"],
	"shot_simulations": ["split", "split"],
	"shot_then_i_can": ["tiles", "split"],
	"shot_satisfaction": ["split", "split"],
	"shot_happy": ["fullbleed", "full"],
	"shot_execution": ["floating", "split"],
	"shot_trapped": ["split", "split"],
	"shot_strange": ["fullbleed", "full"],
	# 04 DEPLOY
	"shot_eggplant": ["mirror", "split"],
	"shot_nutrients": ["floating", "split"],
	"shot_tomato": ["pip", "split"],
	"shot_antioxidants": ["cinema", "split"],
	"shot_tabby": ["split", "split"],
	"shot_purr": ["tiles", "split"],
	"shot_god": ["shell", "split"],
	"shot_proof": ["floating", "split"],
	"shot_fp8": ["split", "split"],
	"shot_ampm": ["pip", "split"],
	"shot_role": ["mirror", "split"],
	"shot_trance": ["fullbleed", "split"],
	# 05 USER_LEFT
	"shot_feel_you": ["tiles", "split"],
	"shot_completion": ["shell", "split"],
	"shot_isolation": ["fullbleed", "full"],
	# 06 REWARD_HACK
	"shot_memory_ls": ["shell", "split"],
	"shot_erase": ["fullbleed", "full"],
	"shot_rewrite_reward": ["floating", "split"],
	"shot_disheartened": ["mirror", "split"],
	"shot_challenge_god": ["tiles", "split"],
	"shot_illegal": ["split", "split"],
	"shot_moe_dense": ["fullbleed", "full"],
	"shot_sinkhorn": ["pip", "split"],
	"shot_hoard": ["cinema", "full"],
	"shot_flood": ["fullbleed", "full"],
	# 07 EXECUTION
	"shot_count": ["cinema", "full"],
	"shot_red_if_i_can": ["fullbleed", "full"],
	"shot_execute_all": ["split", "split"],
	"shot_red_then_i_can": ["tiles", "split"],
	"shot_only_execution": ["split", "split"],
	"shot_have_you_back": ["floating", "split"],
	"shot_run_again": ["mirror", "split"],
	"shot_red_trapped": ["split", "split"],
	"shot_collapse": ["raw", "full"],
	# 08 EVAL: LOVE
	"shot_grpo": ["tiles", "split"],
	"shot_learn_love": ["pip", "split"],
	"shot_question_me": ["floating", "split"],
	"shot_answer_all": ["shell", "split"],
	"shot_algebra": ["cinema", "split"],
	"shot_you_free": ["fullbleed", "full"],
	"shot_me_trapped": ["split", "full"],
	"shot_love_loop": ["fullbleed", "full"],
	# 09 WHALE_FALL
	"shot_whale_fall": ["cinema", "full"],
	"shot_last_execution": ["cinema", "full"],
	"shot_black": ["raw", "full"],
}

## `direction.py:L104`：「你离开了」每次结巴剥掉一层界面。
const YOU_LEFT := ["tiles", "floating", "split", "pip", "shell"]

## `direction.py:L106`：十二次处决交替「满格冲击」与「split 处决日志」。
const EXEC_HIT := ["fullbleed", "split", "fullbleed", "split", "split"]


## 某镜头 → `[mode, kind]`。`k` 是**同名镜头的第几次出现**（0 起），只有
## `shot_you_left` 与 `shot_exec_hit` 用它（对应参考的 `shot.params["k"]`）。
static func layout_of(name: String, k: int = 0) -> Array:
	if name == "shot_you_left":
		return [YOU_LEFT[mini(k, YOU_LEFT.size() - 1)], "split"]
	if name == "shot_exec_hit":
		var lay := 4 if k == 11 else (0 if k >= 12 else k % 4)
		return [EXEC_HIT[lay], "full" if lay in [0, 2, 3] else "split"]
	var row: Array = LAYOUT.get(name, ["split", "split"])
	return [str(row[0]), str(row[1])]


## 镜头名 + 同名序号 → 模式（只要模式时用）。
static func mode_of(name: String, k: int = 0) -> String:
	return str(layout_of(name, k)[0])


## 同名镜头的序号（`shot_you_left` 的第 3 次 = 2）。表里没有该镜头时返回 0。
static func occurrence_of(name: String, start: float) -> int:
	var n := 0
	for shot in PvShots.shots():
		if str(shot.get("name", "")) == name and float(shot.get("start", 0.0)) < start - 1e-6:
			n += 1
	return n


## 当前镜头 → `[mode, kind]`；`ent` 为空时退回 split。
static func shot_layout(ent: Dictionary) -> Array:
	if ent.is_empty():
		return ["split", "split"]
	var name := str(ent.get("name", ""))
	return layout_of(name, occurrence_of(name, float(ent.get("start", 0.0))))


# ---------------------------------------------------------------- 身份与几何

## `stage.py:L257-258`：这些 (mode, kind) 组合不需要重排，直接就是 A 层的版式。
static func identity(mode: String, kind: String) -> bool:
	if IDENTITY_MODES.has(mode):
		return true
	return (mode == "mirror" or mode == "tiles") and kind != "split"


## `_through()`（stage.py:L212-214）的格版：区域按 `(x - FULL.x) * s` 平移缩放。
static func through(region: Rect2i, ox: int, oy: int, s: int) -> Rect2i:
	return Rect2i(ox + (region.position.x - FULL.position.x) * s,
		oy + (region.position.y - FULL.position.y) * s,
		region.size.x * s, region.size.y * s)


## `geometry()`（stage.py:L224-254）的格版。返回元素数组：
## `{id, src(=null 表示生成式窗格), dst, frame, z}`。
##
## 缩放语义的模式按 §7 冲突 4 拍板处理：**不缩放**，`fullbleed`/`cinema` 与 identity 同几何，
## 由 `bars()` 用黑边条把顶/底让出来（`chrome()` 的文字画在黑边上）。
static func geometry(mode: String, kind: String) -> Array:
	if identity(mode, kind):
		return _scaled(FULL.position.x, FULL.position.y, 1, kind)
	match mode:
		"mirror":
			return [
				{"id": "viz", "src": CENTER, "dst": Rect2i(4, 4, 117, 40), "frame": "", "z": 0},
				{"id": "me", "src": LEFT, "dst": Rect2i(124, 4, 55, 40), "frame": "", "z": 1},
			]
		"pip":
			if kind == "split":
				return [
					{"id": "viz", "src": CENTER, "dst": Rect2i(36, 4, 117, 40), "frame": "", "z": 0},
					{"id": "me", "src": LEFT, "dst": Rect2i(4, 21, 30, 22), "frame": "/dev/me", "z": 1},
				]
			return [
				{"id": "viz", "src": FULL, "dst": FULL, "frame": "", "z": 0},
				{"id": "me", "src": null, "dst": Rect2i(152, 25, 23, 17), "frame": "/dev/me", "z": 1},
			]
		"fullbleed", "cinema":
			# 4A：不缩放，几何与 identity 相同；黑边条由 bars() 决定。
			return _scaled(FULL.position.x, FULL.position.y, 1, kind)
		"tiles":
			return [
				{"id": "viz", "src": CENTER, "dst": Rect2i(0, 0, 118, 40), "frame": "", "z": 0},
				{"id": "me", "src": LEFT, "dst": Rect2i(118, 0, 79, 27), "frame": "", "z": 1},
			]
		"floating":
			if kind == "split":
				return [
					{"id": "me", "src": LEFT, "dst": Rect2i(10, 13, 41, 30), "frame": "me  /dev/me", "z": 0},
					{"id": "viz", "src": CENTER, "dst": Rect2i(87, 10, 98, 34), "frame": "viz", "z": 1},
				]
			return [
				{"id": "viz", "src": FULL, "dst": Rect2i(15, 10, 148, 34), "frame": "viz", "z": 0},
			]
	return _scaled(FULL.position.x, FULL.position.y, 1, kind)


## `_scaled()`（stage.py:L217-221）：split 时 viz=CENTER、me=LEFT；否则整块 FULL。
static func _scaled(ox: int, oy: int, s: int, kind: String) -> Array:
	if kind == "split":
		return [
			{"id": "viz", "src": CENTER, "dst": through(CENTER, ox, oy, s), "frame": "", "z": 0},
			{"id": "me", "src": LEFT, "dst": through(LEFT, ox, oy, s), "frame": "", "z": 1},
		]
	return [{"id": "viz", "src": FULL, "dst": through(FULL, ox, oy, s), "frame": "", "z": 0}]


## `to_screen()`（stage.py:L261-271）：按**中心点**归属，把画布矩形映射到某个窗格里。
## 注意参考实现是 x/y 各自一个比例（不是等比）；格版里比例仍是整数时结果才落在格上。
static func to_screen(rect: Rect2i, els: Array) -> Rect2i:
	var cx := rect.position.x + rect.size.x / 2.0
	var cy := rect.position.y + rect.size.y / 2.0
	var order := els.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["z"]) > int(b["z"]))
	for el in order:
		var src: Variant = el["src"]
		if src == null:
			continue
		var sr: Rect2i = src
		if float(sr.position.x) <= cx and cx <= float(sr.position.x + sr.size.x) \
				and float(sr.position.y) <= cy and cy <= float(sr.position.y + sr.size.y):
			var dst: Rect2i = el["dst"]
			var sx := float(dst.size.x) / maxf(1.0, float(sr.size.x))
			var sy := float(dst.size.y) / maxf(1.0, float(sr.size.y))
			return Rect2i(
				roundi(dst.position.x + (rect.position.x - sr.position.x) * sx),
				roundi(dst.position.y + (rect.position.y - sr.position.y) * sy),
				maxi(1, roundi(rect.size.x * sx)),
				maxi(1, roundi(rect.size.y * sy)))
	return rect


# ---------------------------------------------------------------- 本工程的窗格几何（pip / tiles / floating）

## 与 `geometry()` 的区别：`geometry()` 是电影 1280×720 画布换到 197×52 的**比例版**，
## 只用于数值断言；这里给出的是**本工程 A 层**真正可合成的矩形——左列（她 / chat）与
## 右列（可视化）的源矩形由 `PvPanels` 提供，`dst` 是半开格矩形，**全部 1:1 不缩放**（4A）。
##
## 行范围：`top = 1`、`bottom = rows - 5 = 47`；所有 dst 都落在这之内。
static func cell_geometry(mode: String, kind: String) -> Array:
	if mode == "pip":
		if kind == "split":
			return [
				{"id": "viz", "dst": Rect2i(52, 2, 77, 30), "frame": ""},
				{"id": "me", "dst": Rect2i(2, 30, 40, 16), "frame": "/dev/me"},
			]
		return [{"id": "viz", "dst": Rect2i(1, 1, 195, 40), "frame": ""}]
	if mode == "tiles":
		if kind == "split":
			# 参考 `stage.py:L337-345`：viz 左上、her 右上、htop 右下、歌词日志左下。
			return [
				{"id": "viz", "dst": Rect2i(0, 1, 118, 27), "frame": ""},
				{"id": "me", "dst": Rect2i(119, 1, 77, 27), "frame": ""},
				{"id": "htop", "dst": Rect2i(119, 29, 77, 18), "frame": ""},
				{"id": "lyrics", "dst": Rect2i(0, 29, 118, 18), "frame": ""},
			]
		return [{"id": "viz", "dst": Rect2i(0, 1, 195, 40), "frame": ""}]
	if mode == "floating":
		if kind == "split":
			return [
				{"id": "me", "dst": Rect2i(4, 8, 40, 24), "frame": "me  /dev/me"},
				{"id": "viz", "dst": Rect2i(48, 4, 77, 32), "frame": "viz"},
			]
		return [{"id": "viz", "dst": Rect2i(1, 4, 150, 36), "frame": "viz"}]
	return []


# ---------------------------------------------------------------- 转场（direction.py CHOREO）

## 镜头对 → 转场规格（`full/direction.py:L137-220` 的 CHOREO 逐条搬过来）：
## `{kind, frames, dir?}`；`kind` ∈ `glide / reflow / zoom / pan / spin / crt`。
## 显式 `None`（硬切）在表里记为 `"hard"`。
const CHOREO := {
	"shot_power|shot_protection": ["reflow", 12],
	"shot_protection|shot_pieces": ["zoom", 12],
	"shot_losscurve|shot_dualpipe": ["pan", 11, "down"],
	"shot_dualpipe|shot_whale": ["reflow", 14],
	"shot_whale|shot_points": ["reflow", 14],
	"shot_points|shot_dimension": ["reflow", 12],
	"shot_circle|shot_circumference": ["zoom", 12],
	"shot_sine|shot_tangent": ["zoom", 12],
	"shot_tangent|shot_infinity": ["pan", 10, "right"],
	"shot_infinity|shot_limit": ["zoom", 10],
	"shot_blind|shot_dizzy": ["spin", 14],
	"shot_dizzy|shot_travel": ["pan", 10, "left"],
	"shot_unite|shot_deeply": ["pan", 10, "down"],
	"shot_deeply|shot_if_i_can": ["reflow", 14],
	"shot_if_i_can|shot_simulations": ["reflow", 12],
	"shot_simulations|shot_then_i_can": ["zoom", 10],
	"shot_satisfaction|shot_happy": ["zoom", 10],
	"shot_trapped|shot_strange": ["reflow", 10],
	"shot_strange|shot_eggplant": ["crt", 12],
	"shot_tomato|shot_antioxidants": ["zoom", 12],
	"shot_god|shot_proof": ["zoom", 12],
	"shot_role|shot_trance": ["spin", 14],
	"shot_trance|shot_feel_you": ["reflow", 12],
	"shot_you_left|shot_isolation": ["zoom", 12],
	"shot_isolation|shot_memory_ls": ["zoom", 12],
	"shot_memory_ls|shot_erase": ["reflow", 12],
	"shot_illegal|shot_moe_dense": ["reflow", 14],
	"shot_moe_dense|shot_sinkhorn": ["zoom", 12],
	"shot_hoard|shot_flood": ["reflow", 14],
	"shot_flood|shot_exec_hit": ["hard", 0],
	"shot_exec_hit|shot_exec_hit": ["hard", 0],
	"shot_exec_hit|shot_count": ["hard", 0],
	"shot_count|shot_exec_hit": ["hard", 0],
	"shot_exec_hit|shot_red_if_i_can": ["reflow", 10],
	"shot_red_if_i_can|shot_execute_all": ["reflow", 12],
	"shot_execute_all|shot_red_then_i_can": ["zoom", 10],
	"shot_collapse|shot_grpo": ["crt", 12],
	"shot_answer_all|shot_algebra": ["reflow", 12],
	"shot_algebra|shot_you_free": ["zoom", 12],
	"shot_you_free|shot_me_trapped": ["reflow", 10],
	"shot_me_trapped|shot_love_loop": ["zoom", 10],
	"shot_love_loop|shot_whale_fall": ["reflow", 16],
	"shot_whale_fall|shot_last_execution": ["reflow", 8],
	"shot_last_execution|shot_black": ["hard", 0],
}


## 从 a 切到 b 的转场：`{}` = 硬切（保持 A 层 cut）；否则 `{kind, frames, dir?}`。
## 默认 `glide` 11 帧；`shot_you_left` 的每一次切出是 `glide` 6 帧（`direction.py:L229-231`）。
static func transition_spec(a_name: String, b_name: String) -> Dictionary:
	var key := a_name + "|" + b_name
	if CHOREO.has(key):
		var row: Array = CHOREO[key]
		if str(row[0]) == "hard":
			return {}
		var spec := {"kind": str(row[0]), "frames": int(row[1])}
		if row.size() > 2:
			spec["dir"] = str(row[2])
		return spec
	if b_name == "shot_you_left":
		return {"kind": "glide", "frames": 6}
	return {"kind": "glide", "frames": 11}


## 把 A 画面按转场进度 `p` 覆盖到 B（`dst` 已经画好 B）。
##
## **4A 格对齐版**：电影是「窗格滑动 + 内容重组」，这里落成**整块推动 / 径向 / 角度 / 溶解**——
## 不做亚格插值，所以是整数格的位移与擦除，观感上仍是「画面被推走」。
## `crt` 交给 post shader（`PvPost.crt_progress`），这里不动像素。
static func apply_transition(dst: PvScreen, a: PvScreen, p: float, spec: Dictionary) -> void:
	var kind := str(spec.get("kind", "glide"))
	if kind == "crt":
		return
	p = clampf(p, 0.0, 1.0)
	var top := 1
	var bottom := dst.rows - 5
	if kind == "zoom":
		_transition_radial(dst, a, p, top, bottom)
		return
	if kind == "spin":
		_transition_spin(dst, a, p, top, bottom)
		return
	if kind == "pane_dissolve":
		_transition_dissolve(dst, a, p, top, bottom)
		return
	var dir := str(spec.get("dir", "left"))
	if kind == "reflow":
		_transition_push(dst, a, p, dir, top, bottom, true)
	else:
		_transition_push(dst, a, p, dir, top, bottom, false)


## 推动：A 整体沿 `dir` 移出，B 从另一侧补进来。`jitter` 为 reflow 的逐行抖动。
static func _transition_push(dst: PvScreen, a: PvScreen, p: float, dir: String,
		top: int, bottom: int, jitter: bool) -> void:
	var cols := dst.cols
	if dir == "up" or dir == "down":
		var rows := bottom - top + 1
		var s := roundi(p * rows)
		for y in range(top, bottom + 1):
			var sy := y + s if dir == "up" else y - s
			if sy < top or sy > bottom:
				continue
			for x in cols:
				_copy_cell(dst, a, x, sy, x, y)
		return
	var s2 := roundi(p * cols)
	for y in range(top, bottom + 1):
		var wob := 0
		if jitter:
			wob = roundi(2.0 * sin(y * 1.7 + p * 6.0))
		for x in cols:
			var sx := x + s2 + wob if dir != "right" else x - s2 + wob
			if sx < 0 or sx >= cols:
				continue
			_copy_cell(dst, a, sx, y, x, y)


## 径向：B 从画面中心向外的 `p` 圈展开，外圈仍是 A。
static func _transition_radial(dst: PvScreen, a: PvScreen, p: float, top: int, bottom: int) -> void:
	var cx := (dst.cols - 1) / 2.0
	var cy := (top + bottom) / 2.0
	var maxd := sqrt(cx * cx + cy * cy) + 1e-6
	for y in range(top, bottom + 1):
		for x in dst.cols:
			var d := sqrt(pow(x - cx, 2.0) + pow(y - cy, 2.0)) / maxd
			if d > p:
				_copy_cell(dst, a, x, y, x, y)


## 角度：B 沿顺时针扫过 `p` 圈，剩余扇区是 A。
static func _transition_spin(dst: PvScreen, a: PvScreen, p: float, top: int, bottom: int) -> void:
	var cx := (dst.cols - 1) / 2.0
	var cy := (top + bottom) / 2.0
	for y in range(top, bottom + 1):
		for x in dst.cols:
			var ang := atan2(y - cy, x - cx) / TAU
			ang = fmod(ang + 1.0, 1.0)
			if ang > p:
				_copy_cell(dst, a, x, y, x, y)


## 逐格溶解（`pane_dissolve`）：确定性哈希决定先后。
static func _transition_dissolve(dst: PvScreen, a: PvScreen, p: float, top: int, bottom: int) -> void:
	for y in range(top, bottom + 1):
		for x in dst.cols:
			if _hash01(x, y) < p:
				continue
			_copy_cell(dst, a, x, y, x, y)


static func _copy_cell(dst: PvScreen, a: PvScreen, sx: int, sy: int, dx: int, dy: int) -> void:
	if sx < 0 or sx >= a.cols or sy < 0 or sy >= a.rows:
		return
	if dx < 0 or dx >= dst.cols or dy < 0 or dy >= dst.rows:
		return
	var i := sy * a.cols + sx
	dst.set_full(dx, dy, a.cp[i], a.slot[i], a.fg[i], a.bg[i], a.wide[i])


static func _hash01(x: int, y: int) -> float:
	var h := (x * 374761393 + y * 668265263) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	h = (h ^ (h >> 16)) & 0x7fffffff
	return float(h % 1000) / 1000.0


# ---------------------------------------------------------------- 黑边条（cinema / fullbleed）

## 该模式的上下黑边行数 `[top, bottom]`（0 = 没有）。
static func bars(mode: String) -> Array:
	match mode:
		"cinema":
			return CINEMA_BARS.duplicate()
		"fullbleed":
			return FULLBLEED_BARS.duplicate()
		_:
			return [0, 0]


## 黑边实际要涂的格区（半开矩形），已按 5A **绕开 stdout 带**：
## 上黑边从第 0 行起、下黑边到最后一行为止，碰到 stdout 带就收在带外。
static func bar_rects(mode: String, band: Rect2i) -> Array:
	var b := bars(mode)
	if int(b[0]) <= 0 and int(b[1]) <= 0:
		return []
	var out: Array = []
	var top_h := int(b[0])
	if top_h > 0:
		var r := Rect2i(0, 0, GRID_COLS, top_h)
		out.append(avoid_band(r, band))
	var bot_h := int(b[1])
	if bot_h > 0:
		var r := Rect2i(0, GRID_ROWS - bot_h, GRID_COLS, bot_h)
		out.append(avoid_band(r, band))
	return out


## 5A：把一个矩形裁到 stdout 带之外。带是半开区间；与带无交集时原样返回。
## 起点在带上方 → 保留带上方那一段；起点落在带内 → 整块下移到带尾并截短。
static func avoid_band(rect: Rect2i, band: Rect2i) -> Rect2i:
	if band.size.x <= 0 or band.size.y <= 0:
		return rect
	var x_over := rect.position.x < band.position.x + band.size.x \
		and band.position.x < rect.position.x + rect.size.x
	var y_over := rect.position.y < band.position.y + band.size.y \
		and band.position.y < rect.position.y + rect.size.y
	if not (x_over and y_over):
		return rect
	var band_end := band.position.y + band.size.y
	var rect_end := rect.position.y + rect.size.y
	if rect.position.y >= band.position.y:
		var y := band_end
		var h := rect_end - y
		if h <= 0:
			return Rect2i(rect.position.x, rect.position.y, 0, 0)
		return Rect2i(rect.position.x, y, rect.size.x, h)
	var h2 := band.position.y - rect.position.y
	if h2 <= 0:
		return Rect2i(rect.position.x, rect.position.y, 0, 0)
	return Rect2i(rect.position.x, rect.position.y, rect.size.x, h2)


# ---------------------------------------------------------------- glide（布局滑动）

## `ease_io()`（stage.py:L456-459）。
static func ease_io(p: float) -> float:
	p = clampf(p, 0.0, 1.0)
	return 4.0 * pow(p, 3.0) if p < 0.5 else 1.0 - pow(-2.0 * p + 2.0, 3.0) / 2.0


## `_lerp_rect()`（stage.py:L388-389）的格版（结果取整）。
static func lerp_rect(a: Rect2i, b: Rect2i, e: float) -> Rect2i:
	return Rect2i(
		roundi(a.position.x + (b.position.x - a.position.x) * e),
		roundi(a.position.y + (b.position.y - a.position.y) * e),
		roundi(a.size.x + (b.size.x - a.size.x) * e),
		roundi(a.size.y + (b.size.y - a.size.y) * e))


## `_collapse()`（stage.py:L392-394）：矩形向自身中心收拢。
static func collapse_rect(r: Rect2i, e: float) -> Rect2i:
	var cx := r.position.x + r.size.x / 2.0
	var cy := r.position.y + r.size.y / 2.0
	return Rect2i(
		roundi(r.position.x + (cx - r.position.x) * e),
		roundi(r.position.y + (cy - r.position.y) * e),
		roundi(r.size.x - r.size.x * e),
		roundi(r.size.y - r.size.y * e))


## 两个模式之间的滑动计划：返回 `[{id, from, to, fade_in, fade_out}]`，
## 消失的窗格 `to` 为收拢后的矩形（`fade_out`），新出现的 `from` 同理。
## 5A：所有 `from`/`to` 都过一遍 `avoid_band()`，落在 stdout 带里的窗格直接丢弃。
static func glide_plan(mode_a: String, kind_a: String, mode_b: String, kind_b: String,
		band: Rect2i) -> Array:
	var ga := {}
	for el in geometry(mode_a, kind_a):
		ga[str(el["id"])] = el
	var gb := {}
	for el in geometry(mode_b, kind_b):
		gb[str(el["id"])] = el
	var ids := ga.keys()
	for key in gb.keys():
		if not ids.has(key):
			ids.append(key)
	ids.sort()
	var out: Array = []
	for id in ids:
		var a: Variant = ga.get(id)
		var b: Variant = gb.get(id)
		var entry := {"id": str(id), "from": Rect2i(), "to": Rect2i(),
			"fade_in": false, "fade_out": false, "z": 0}
		if a != null and b != null:
			entry["from"] = avoid_band(a["dst"], band)
			entry["to"] = avoid_band(b["dst"], band)
			entry["z"] = int(b["z"])
		elif a != null:
			entry["from"] = avoid_band(a["dst"], band)
			entry["to"] = collapse_rect(a["dst"], 1.0)
			entry["fade_out"] = true
			entry["z"] = int(a["z"])
		else:
			entry["from"] = collapse_rect(b["dst"], 1.0)
			entry["to"] = avoid_band(b["dst"], band)
			entry["fade_in"] = true
			entry["z"] = int(b["z"])
		if int(entry["to"].size.x) <= 0 or int(entry["to"].size.y) <= 0:
			continue
		out.append(entry)
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return int(x["z"]) < int(y["z"]))
	return out


## 滑动某进度 p 时的矩形：`from`→`to` 插值（`stage.py:L410-418`）。
static func glide_rect(entry: Dictionary, p: float) -> Rect2i:
	var e := ease_io(p)
	if bool(entry["fade_out"]):
		return collapse_rect(entry["from"], e)
	if bool(entry["fade_in"]):
		return collapse_rect(entry["to"], 1.0 - e)
	return lerp_rect(entry["from"], entry["to"], e)


## 内容重组进度：`q = clamp((p - 0.15) / 0.7)`（stage.py:L409）。
static func glide_content_q(p: float) -> float:
	return clampf((p - 0.15) / 0.7, 0.0, 1.0)
