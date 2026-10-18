extends CharacterBody2D

## 玩家控制器
##
## 职责边界（重构后）：
##   · 只负责「运动学 + 死亡状态 + 眼睛调度」三件事；
##   · 死亡[b]表现[/b]（动画 / 特效 / 音效 / 环境后处理）全部移出本场景：
##     玩家只置位 is_dead 并广播 died(kind)，由关卡或特效层决定怎么演。
##
## 想给死亡加动画而[b]不改代码[/b]：在 DeathAnimation（AnimationPlayer）里加一个
## 与 DeathKind 同名的动画即可，比如 &"hurt" / &"ascend"，die() 会自动播放它。
##
## 死亡后复位请用 respawn() / respawn_at()（见 D11 的改造）。

##死亡后请重新实例化或是调用 respawn() 复位
## 重复调用 _ready() 现在是安全的（初始化幂等，见 _initialize()）。
##
## 眼睛脚本的常量引用（D7）。用 preload 而不是 class_name：全局类名依赖编辑器生成的
## .godot/global_script_class_cache.cfg，无编辑器的无头运行解析不到。
const Eye = preload("res://subsystem/player_system/scripts/eye.gd")

@onready var eyes :Eye= $player/eyes
@onready var player: Sprite2D = $player
## 死亡动画播放器：默认为空的扩展点（本场景不内置任何死亡动画）。
## 放进与 DeathKind 同名的动画即可被 die() 自动播放。
@onready var death_animation: AnimationPlayer = $DeathAnimation

#### 手感参数（D12：全部可在检查器里调）
## ⚠ max_speed / jump_velocity 是「基准值」：运行时会被 _initialize() 再 ×1.5
##    （124.5 → 186.75，-340.0 → -510.0）。详见 docs/IMPROVEMENT_PLAN.md §1.8（D5）。
@export_group("Movement")
@export var max_speed :float= 124.5         # 最大移动速度（基准值，运行时 ×1.5）
@export var acceleration :float = 0.5       # 加速度系数(0-1)
## 地面摩擦：没有水平输入时每帧把速度乘以它（0.83/帧 ≈ 60fps 下 1 秒剩 1.4e-5）
## 原实现写死字面量 0.83、而 ground_friction 这个变量只在（错误的）空中公式里被用过；
## 现已接上，默认值取原来的字面量，**行为不变**。
@export_range(0.0, 1.0) var ground_friction :float = 0.83
@export var gravity :float = ProjectSettings.get_setting("physics/2d/default_gravity")*1.1  # 重力

@export_group("Jump")
@export var jump_velocity :float = -340.0    # 跳跃初速度(负值表示向上)（基准值，运行时 ×1.5）
@export var max_jumps :int = 1               # 最大跳跃次数
@export var coyote_time :float = 0.07        # 土狼时间
@export var jump_buffer_time :float = 0.1    # 跳跃缓冲时间

@export_group("Eyes")
## 眼睛的移动模式 look_at是描向鼠标,move是跟随玩家移动
enum EYES_MODE {look_at,move}
@export var eyes_mode:EYES_MODE=EYES_MODE.move
## 眼睛相对瞳孔中心的偏移（归一化 [-1,1]）。
## x 的符号在运行时按 facing 取（见 _eye_target_offset()），这里始终保持正数即可。
@export var eye_offset: Vector2 = Vector2(0.68, -0.636)
## 眼睛跟随朝向插值的速度（60fps 每帧比例基准，⚠ 帧率相关，见 eye.gd 的 D2 说明）
@export_range(0.0, 60.0) var eye_follow_speed: float = 3.4
## 眼睛描向鼠标时的跟随速度（60fps 每帧比例基准，⚠ 帧率相关）
@export_range(0.0, 60.0) var eye_aim_speed: float = 2.34

#### 玩家缩放对运动的影响
##
## CharacterBody2D.velocity 的单位是「全局像素/秒」，和节点 scale 无关。
## 也就是说：把玩家放大一倍，他会变大，但跑得跟原来一样快、跳得跟原来一样高，
## 于是相对自身身形的机动性变差、跳跃高度不足、滞空时间也不变。
##
## 打开下面这个开关后，运动参数会按当前 scale 等比补偿（相当于把整段运动学一起缩放）：
##     max_speed     *= sx     水平速度      → 位移 / 自身宽度 保持不变
##     jump_velocity *= sy     起跳初速度    → 负值等比放大
##     gravity       *= sy     重力          → 滞空时间不随体型变化
##
## 效果：放大 N 倍的玩家，跑动距离与跳跃高度（像素）都变成 N 倍，
## 而「跳起来有几个自己那么高」「一次跳跃滞空多久」和未缩放时完全一致。
##
## 注意：如果你用 scale 做「挤压拉伸（squash & stretch）」这类纯视觉动画，
## 请把 scale_affects_motion 关掉，改用 motion_scale 单独给运动倍率，
## 否则每一下挤压都会让移动速度跟着抖。
@export_group("Scale")
@export var scale_affects_motion: bool = true
## 额外的运动倍率，会与 scale 相乘；关掉 scale_affects_motion 后可用它单独控制
@export var motion_scale: Vector2 = Vector2.ONE

#### 空中阻力（水平）
##
## 取代了原来的 `air_resistance`（那个系数是 ×1.1/×1.4 的**加速**，方向与名字完全相反）。
## 现在的规则：
##
## 1. 方向恒为「玩家朝向」的反方向 —— 朝向右侧时阻力向左，朝向左侧时阻力向右。
##    不是简单地与速度相反；朝向翻转时阻力方向跟着翻转。
## 2. 只削减「朝向前方」的那部分动量：如果玩家已经在往身后滑（沿朝向的分量为负）
##    或者完全静止，阻力就不起作用 —— 它既不会把玩家推向后方，
##    也不会让静止的滞空玩家自己飘起来。
## 3. 原地起跳（起跳那一帧没有水平输入）时，整段滞空都不施加阻力：
##    起跳时的水平速度原样保持到落地或重新输入。
##
## 数值含义：每秒沿朝向轴衰减掉的比例。0.35 = 一秒后还剩 65%。
## 换算是帧率无关的：每帧乘以 pow(1.0 - air_drag, delta)。
@export_group("Air")
@export_range(0.0, 0.95) var air_drag: float = 0.35
## 空中操控力：每帧把水平速度拉向「输入方向的最大速度」的比例（60fps 基准）
@export_range(0.0, 1.0) var air_control: float = 0.35
## 起跳那一帧的水平输入绝对值不超过该值，即视为「原地起跳」
@export_range(0.0, 1.0) var in_place_epsilon: float = 0.01

#### 死亡 / 复位（D11：信号化 API，玩家不内置任何死亡表现）
##
## 原来的 `deal(anim_name: String)`（字符串 match 分派 god/steve、直接改 WorldEnvironment 的 glow、
## 播放 28 帧烟雾）已全部移除。现在玩家只做两件事：
##   1. 置位 is_dead（并按 freeze_on_death 冻结运动学）；
##   2. 广播 died(kind)。
## 死亡动画 / 特效 / 音效 / 后处理由关卡或特效层接 died 信号自己演。
enum DeathKind {
	HURT,    ## 普通死亡（对应原 "steve" 分支）
	ASCEND,  ## 升天 / 成神（对应原 "god" 分支）
}

## 死亡时广播，一次死亡只发一次
signal died(kind: DeathKind)
## 复位完成后广播
signal respawned

## 死亡后是否冻结运动学与输入（等价于原来的 is_deal 行为）
@export var freeze_on_death: bool = true

## 死亡状态（替代原来的 is_deal）
var is_dead: bool = false
## 出生点：_ready() 时记录，respawn() 不带参数时回到这里
var spawn_position: Vector2 = Vector2.ZERO

#### 运动学状态
var current_velocity : Vector2= Vector2.ZERO
var jump_count :int = 0            # 跳跃计数器

var coyote_timer :float = 0.0
var jump_buffer_timer :float= 0.0

## 当前朝向：1 = 右，-1 = 左。只由 _update_facing() 修改。
## （替代原来的 player_direction；眼睛偏移的符号由它派生，见 _eye_target_offset()）
var facing: int = 1

## 本次滞空是否忽略阻力（原地起跳 → true）
var air_drag_suppressed: bool = false
## 上一物理帧结束时是否站在地面上，用来检测「刚离地那一帧」
var _was_grounded: bool = false

## 一次性初始化是否已完成（让 _initialize() 幂等）
var _initialized: bool = false

## _initialize() 之后、尚未叠加玩家缩放的基准运动参数
var _base_max_speed: float = 0.0
var _base_jump_velocity: float = 0.0
var _base_gravity: float = 0.0
## 上次已应用的运动缩放；哨兵值保证首次一定生效
var _applied_motion_scale: Vector2 = Vector2.ZERO

#### 基本
func _ready() -> void:
	_initialize()
	refresh_motion_scale(true)
	is_dead = false
	player.visible = true

## 一次性初始化：记录出生点 + 把「基准值」×1.5 变成运行时值。
##
## ⚠ 幂等 —— 重复调用（例如误调 _ready()）是安全的空操作：不会再次叠乘 ×1.5，
##    也不会覆盖已经记录的出生点。这条曾经是真实的雷：改造前重复调 _ready() 三次，
##    max_speed 会从 186.75 叠到 420.19（×3.375）且没有任何报错。
##
## ⚠ 这里保留的 ×1.5 是「隐藏倍率」（D5）：检查器里 max_speed 显示 124.5，
##    运行时是 186.75；jump_velocity 显示 -340.0，运行时是 -510.0（gravity 不参与）。
##    完整说明见 docs/IMPROVEMENT_PLAN.md §1.8。
func _initialize() -> void:
	if _initialized:
		return
	_initialized = true
	spawn_position = position
	var c := 1.5
	max_speed *= c
	jump_velocity *= c
	# 记下基准值，玩家缩放的补偿以它为起点反复计算，避免缩放来回改时误差累积
	_base_max_speed = max_speed
	_base_jump_velocity = jump_velocity
	_base_gravity = gravity

## 当前生效的运动缩放 = scale（可关闭） × motion_scale
func _current_motion_scale() -> Vector2:
	var s := motion_scale
	if scale_affects_motion:
		s *= scale.abs()   # 取模：水平翻转（负缩放）不应该把移动方向也反过来
	# 兜底：缩放到 0 或极端值时不让速度参数变成 0 或负数
	return Vector2(maxf(s.x, 0.01), maxf(s.y, 0.01))

## 按玩家缩放重算运动参数。
## 缩放没变时立即返回，因此可以安全地每帧调用（用于支持运行时/动画改缩放）。
func refresh_motion_scale(force: bool = false) -> void:
	var s := _current_motion_scale()
	if not force and s.is_equal_approx(_applied_motion_scale):
		return
	_applied_motion_scale = s
	max_speed = _base_max_speed * s.x
	jump_velocity = _base_jump_velocity * s.y
	gravity = _base_gravity * s.y

## 施加空中阻力：沿「玩家朝向」轴，方向恒为朝向的反方向
func _apply_air_drag(delta: float) -> void:
	if air_drag <= 0.0:
		return
	var face := float(facing)
	var along := current_velocity.x * face             # 沿「前方」的速度分量
	if along <= 0.0:
		return                                          # 在往身后滑或静止：阻力不把玩家推向后方
	var decayed := along * pow(1.0 - air_drag, delta)   # 帧率无关的衰减
	current_velocity.x += face * (decayed - along)

## 检测「刚离地那一帧」：起跳瞬间没有水平输入 → 原地起跳，整段滞空忽略阻力
func _refresh_air_drag_suppression(input_dir: float) -> void:
	var grounded := is_on_floor()
	if _was_grounded and not grounded:
		air_drag_suppressed = absf(input_dir) <= in_place_epsilon
	elif grounded:
		air_drag_suppressed = false
	_was_grounded = grounded

#### 死亡 / 复位

## 让玩家进入死亡状态。幂等：已死亡时重复调用不会有任何副作用。
## 只发信号，不做任何表现（见顶部的职责边界说明）。
func die(kind: DeathKind = DeathKind.HURT) -> void:
	if is_dead:
		return
	is_dead = true
	_play_death_animation(kind)
	died.emit(kind)

## 复位到 _ready() 时记录的出生点。替代原来"关卡自己把 player.position tween 到硬编码坐标"的写法。
func respawn() -> void:
	_respawn(spawn_position)

## 复位并移动到 [param at]。关卡接 died 信号后调用它即可。
func respawn_at(at: Vector2) -> void:
	_respawn(at)

func _respawn(where: Vector2) -> void:
	is_dead = false
	position = where
	velocity = Vector2.ZERO
	current_velocity = Vector2.ZERO
	jump_count = 0
	jump_buffer_timer = 0.0
	coyote_timer = 0.0
	air_drag_suppressed = false
	_was_grounded = false
	if death_animation and death_animation.is_playing():
		death_animation.stop()
	respawned.emit()

## 扩展点：DeathAnimation 里若有与 kind 同名的动画就播放，没有就什么都不做。
## 本场景默认一个动画都没有，所以默认行为 = 只发信号。
func _play_death_animation(kind: DeathKind) -> void:
	if death_animation == null:
		return
	var anim := StringName(DeathKind.keys()[kind].to_lower())
	if death_animation.has_animation(anim):
		death_animation.play(anim)

#### 每帧逻辑

## 每个物理帧的主流程（D6：拆成三个各自独立的步骤，顺序与原实现逐一对应）
##
## 帧边界约定（重要）：
##   is_on_floor() / is_on_ceiling() 由 move_and_slide() 更新，而 move_and_slide() 在本函数**末尾**。
##   所以本帧读到的 grounded 实际上是「上一帧 move_and_slide() 之后」的结果 ——
##   这里显式缓存成 grounded 并在帧首取一次，既避免重复查询，也让这个语义不再隐式（原来 4 次
##   裸调 is_on_floor()，读代码的人很难意识到它们是同一个值）。
##   ⚠ 本函数只做结构拆分，未改变任何执行顺序或数值。
func _physics_process(delta: float) -> void:
	refresh_motion_scale()
	if is_dead and freeze_on_death:
		return

	var input_dir := Input.get_axis("move_left", "move_right")
	var grounded := is_on_floor()

	_update_vertical(grounded, delta)
	_update_horizontal(input_dir, grounded, delta)

	current_velocity.x = clampf(current_velocity.x, -max_speed, max_speed)
	velocity = current_velocity
	move_and_slide()
	# 放在 move_and_slide() 之后，才能拿到本帧刚翻转的 is_on_floor()
	_refresh_air_drag_suppression(input_dir)


## 竖直方向：土狼时间 / 跳跃缓冲 / 起跳 / 顶头 / 重力
func _update_vertical(grounded: bool, delta: float) -> void:
	# 落地：重置土狼计时与跳跃计数；离地：递减土狼计时
	if grounded:
		coyote_timer = coyote_time
		jump_count = 0
	else:
		coyote_timer -= delta

	# 跳跃输入：按下即充值缓冲；在地面且没按跳时把竖直速度清零；空中则递减缓冲
	if Input.is_action_just_pressed("jump"):
		jump_buffer_timer = jump_buffer_time
	elif grounded:
		current_velocity.y = 0.0
	else:
		jump_buffer_timer -= delta

	# 起跳：缓冲未过期 且（土狼时间未过期 或 剩余跳跃次数）
	if jump_buffer_timer > 0.0 and (coyote_timer > 0.0 or jump_count < max_jumps):
		current_velocity.y = jump_velocity
		jump_count += 1
		jump_buffer_timer = 0.0
		coyote_timer = 0.0  # 使用土狼时间后立即清零

	if is_on_ceiling():
		current_velocity.y = 0.0
	# 重力在起跳之后施加（所以起跳帧的竖直速度是 jump_velocity + gravity*delta）—— 不要调整顺序
	current_velocity.y += gravity * delta


## 水平方向：地面加速 + 摩擦，或空中阻力 + 操控力
func _update_horizontal(input_dir: float, grounded: bool, delta: float) -> void:
	var desired_velocity := input_dir * max_speed

	if grounded:
		current_velocity.x = lerp(current_velocity.x, desired_velocity + current_velocity.x, acceleration)
		# 没有输入时应用地面摩擦
		if is_zero_approx(input_dir):
			current_velocity.x *= ground_friction
	else:
		# 空中阻力：方向恒为玩家朝向的反方向；原地起跳时整段滞空忽略
		if not air_drag_suppressed:
			_apply_air_drag(delta)
		# 空中操控力：只在玩家有水平输入时生效，目标就是输入方向的最大速度。
		# （原公式里的 0.7·vx 阻力项与误用的 ground_friction 都已移除，见 README §6）
		if not is_zero_approx(input_dir):
			current_velocity.x = lerp(current_velocity.x, desired_velocity, air_control)

func _process(delta: float) -> void:
	var input_dir = Input.get_axis("move_left", "move_right")
	_update_facing(int(input_dir))
	_update_eyes(delta)
	if eyes_mode == EYES_MODE.look_at:
		aim_mouse(delta)

#### 眼睛调度（D7：这里的每次调用都是幂等的，可以安全地每帧跑）

## 眼睛的每帧调度：自动眨眼开关 / 表情 / 位置。
func _update_eyes(delta: float) -> void:
	# 空中与死亡时：关掉自动眨眼并锁成 blink 表情；落地且活着时：default + 自动眨眼。
	var can_auto_blink := is_on_floor() and not is_dead
	eyes.set_knip(can_auto_blink)
	eyes.set_expression(Eye.Face.BLINK if not can_auto_blink else Eye.Face.DEFAULT)
	eyes.lerp_position(_eye_target_offset(), eye_follow_speed * delta)

## 眼睛的目标偏移：把 eye_offset.x 按朝向取符号，保证它永远指向玩家「前方」。
## 这样 eye_offset 本身不需要被就地修改，"向左时 x 取反"也不再是隐式约定（D13）。
func _eye_target_offset() -> Vector2:
	return Vector2(absf(eye_offset.x) * float(facing), eye_offset.y)

## 更新朝向。0（无输入）不改变朝向。
func _update_facing(dir: int) -> void:
	if dir == 0 or dir == facing:
		return
	facing = dir

## 鼠标跟随
func aim_mouse(delta):
	eyes.aiming_move(delta * eye_aim_speed, self.to_local(get_parent().get_local_mouse_position()))

## 眼睛模式切换
func set_eyes_mode(mode:EYES_MODE) -> void:
	eyes_mode = mode
