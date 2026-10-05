extends Node2D
## player_system 沙盒场景控制器（新增，非剥离物）
##
## 用途：在不依赖 jump! 项目任何其它系统的前提下，单独跑通玩家实例，
## 直观验证「移动 / 跳跃 / 眼睛跟随 / 眼睛表情 / 死亡与复位」五条链路。
##
## 操作：
##   A / D        左右移动（手柄左摇杆同样可用）
##   空格 / 手柄A  跳跃
##   Q            切换眼睛模式：move（跟随朝向） ↔ look_at（望向鼠标）
##   R            复位玩家（调用 player.respawn()）
##   F            触发 die(HURT)  —— 玩家本身不放任何表现，这里只把信号打到屏幕上
##   G            触发 die(ASCEND)
##   [ / ]        缩小 / 放大玩家（观察缩放对运动的影响）
##   \            缩放归 1

const SPAWN := Vector2(0.0, -120.0)
const SCALE_STEP := 0.25
const SCALE_MIN := 0.5
const SCALE_MAX := 3.0

## 眼睛脚本常量（不用 class_name，见 eye.gd 顶部说明）
const Eye = preload("res://player_system/scripts/eye.gd")

@onready var player: CharacterBody2D = $player
@onready var eyes: Eye = $player/player/eyes
@onready var info: Label = $CanvasLayer/Info
@onready var hint: Label = $CanvasLayer/Hint

var _mode_text: String = ""
## 最近一次 died 信号，用来演示"玩家只发信号、表现交给外部"
var _last_death: String = "—"


func _ready() -> void:
	randomize()
	# 演示 D11 的新玩法：关卡接 died 信号自己决定演什么，玩家脚本里没有任何死亡表现
	player.died.connect(_on_player_died)
	player.respawned.connect(func(): _last_death = "已复位")
	_reset()
	_update_hint()


func _on_player_died(kind: int) -> void:
	_last_death = "died(%s)" % player.DeathKind.keys()[kind]


func _process(_delta: float) -> void:
	info.text = "\n".join([
		"position        : %s" % player.position,
		"velocity        : %s" % player.velocity,
		"on_floor        : %s" % player.is_on_floor(),
		"jump_count      : %d / %d" % [player.jump_count, player.max_jumps],
		"scale           : %s" % player.scale,
		"max_speed(有效) : %.1f" % player.max_speed,
		"jump_velocity   : %.1f" % player.jump_velocity,
		"gravity         : %.1f" % player.gravity,
		"air_drag        : %.2f/秒（%s）" % [player.air_drag,
			"本次滞空忽略（原地起跳）" if player.air_drag_suppressed else "生效"],
		"facing          : %d" % player.facing,
		"eye_target      : %s" % player._eye_target_offset(),
		"eyes_mode       : %s" % _mode_text,
		"eyes.deviation  : %s" % eyes.deviation,
		"eyes.face       : %s" % Eye.Face.keys()[eyes.current_expression],
		"eyes.knip(自动眨眼): %s" % eyes.outomaties_knip,
		"is_dead         : %s" % player.is_dead,
		"最近死亡信号     : %s" % _last_death,
	])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).physical_keycode:
			KEY_Q:
				_toggle_eyes_mode()
			KEY_R:
				_reset()
			KEY_F:
				player.die(player.DeathKind.HURT)
			KEY_G:
				player.die(player.DeathKind.ASCEND)
			KEY_BRACKETLEFT:
				_scale_by(-SCALE_STEP)
			KEY_BRACKETRIGHT:
				_scale_by(SCALE_STEP)
			KEY_BACKSLASH:
				_set_scale(1.0)


## 调整玩家整体缩放；运动参数会在下一个物理帧自动按新缩放重算
func _scale_by(delta: float) -> void:
	_set_scale(player.scale.x + delta)


func _set_scale(value: float) -> void:
	var s := clampf(snappedf(value, 0.05), SCALE_MIN, SCALE_MAX)
	player.scale = Vector2(s, s)


func _toggle_eyes_mode() -> void:
	# 注意枚举顺序：EYES_MODE { look_at = 0, move = 1 }
	player.set_eyes_mode(1 - int(player.eyes_mode))
	_update_hint()


func _update_hint() -> void:
	_mode_text = "move（跟随朝向）" if int(player.eyes_mode) == 1 else "look_at（望向鼠标）"
	hint.text = "A/D 移动　空格 跳跃　Q 眼睛模式　[/] 缩放　\\ 归 1　R 复位　F/G 死亡(HURT/ASCEND)　当前模式：%s" % _mode_text


## 复位：现在只需要一次 player.respawn()（D11）—— 位置/速度/跳跃/死亡状态一次清干净
func _reset() -> void:
	player.respawn_at(SPAWN)
	player.facing = 1
	_set_scale(1.0)
