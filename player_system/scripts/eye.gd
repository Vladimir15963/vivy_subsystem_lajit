extends Node2D

## 像素眼睛
##
## 这是一个像素眼睛的实现
##
## 职责分工（D7 重构后）：
##   · set_expression() —— 只负责「表情」，幂等：与当前表情相同时直接返回，
##     不会重写 AtlasTexture.region。因此调用方可以安全地每帧调用它。
##   · set_knip()       —— 只负责「自动眨眼的开关」，不再顺带修改表情。
##   旧实现里这两件事是混在一起的，而 player.gd 每帧都两个都调一遍，
##   导致每帧重写一次同一个 region。
##
## 枚举请通过脚本常量访问，不要再写成 eyes.expression.blink（那是"通过实例取枚举"）：
##     const Eye = preload("res://player_system/scripts/eye.gd")
##     eyes.set_expression(Eye.Face.BLINK)
## 这里刻意不使用 class_name —— 全局类名依赖编辑器生成的
## .godot/global_script_class_cache.cfg，在无编辑器的无头运行里解析不到。
@onready var timer: Timer = $Timer
@onready var animation_player: AnimationPlayer = $AnimationPlayer
## 眼睛的图像
@onready var texture: AtlasTexture=$TextureRect.texture
## 它爹的大小
var b_size: Vector2
## 它爹
@export var body: Sprite2D
## 边距，
@export var margin: Vector2= Vector2(0, 0)

## 当前相对于原点的偏移，原点是子节点的相对父节点的位置。请不要直接修改这个变量，而是使用lerp_position函数来移动。
@export var deviation: Vector2= Vector2(0, 0)

## 表情。
## ⚠ 数值顺序与图集区域一一对应，且旧代码/动画轨用整数 0~4 传参，不要随意调整顺序。
enum Face { DEFAULT, BLINK_LEFT, BLINK_RIGHT, BLINK, DIE }

## 当前表情。外部请通过 set_expression() 修改，不要直接赋值。
var current_expression: Face = Face.DEFAULT

## 若为true，开始自动倒计时，进行眨眼，也可以用set_knip(true)
var outomaties_knip :bool = false


func _ready():
	if body:
		b_size = body.texture.get_size()*body.scale
	else:
		b_size = Vector2(1, 1)
	margin.clamp(Vector2(0, 0),b_size-Vector2(1, 1))
	

## 以插值的方式移动至偏移位置
## [param dev]是偏移量,[param speed]是速度,建议乘上delta
## [param O]是原点位置，默认是(0,0)
##
## ⚠ 已知限制（D2 —— 决定：只记录、不改动。详见 docs/IMPROVEMENT_PLAN.md §1.7）——「插值速度与帧率相关」
## ---------------------------------------------------------------------------
## 问题：这里的 [param speed] 是**每一帧**的插值比例，不是"每秒"的速度。
##       而它的两个调用点传进来的都是 delta 的倍数：
##         · player.gd  _update_eyes() → eyes.lerp_position(_eye_target_offset(), eye_follow_speed * delta)
##         · 本文件      aiming_move()  → lerp_position(dev, delta)（player.gd.aim_mouse 传 delta * eye_aim_speed）
##       于是 60fps 下每帧比例是 3.4/60 ≈ 0.057，144Hz 下只有 3.4/144 ≈ 0.024。
##       同样的 0.5 秒，144Hz 下眼睛只走完一半左右的距离 —— 高刷屏与移动端手感不一致。
##
## 为什么不改：把它换成帧率无关的形式会同时改变 60fps 之外的既有观感，
##       属于"手感改动"，需要配套的高低帧对照验证（改进方案 P0-2 原本要求
##       "60Hz 与 144Hz 下 0.5s 位移差 < 5%"）。在没有做这个验证之前，
##       按当前优先级决定保留原行为，只在此处标注。
##
## 将来要改的话（已评估，低风险）：
##       调用点改传「60fps 基准的每帧比例」常量，并让本函数拿到 delta 后换算：
##           static func _smooth(alpha_60: float, delta: float) -> float:
##               return 1.0 - pow(1.0 - alpha_60, delta * 60.0)
##           position = position.lerp(target_pos, _smooth(alpha_60, delta))
##       注意调用点目前已经把 delta 乘进去了，改造时要去掉那个乘法，否则会二次缩放。
func lerp_position(dev: Vector2, speed: float, O := Vector2(0, 0)) -> void:
	if body:
		var center_position = texture.get_size() / 2

		# 计算最大可移动偏移量
		var max_offset = (b_size - margin) / 2
		# 限制 dev 在 [-1, 1] 范围内
		dev = dev.clamp(Vector2(-1, -1), Vector2(1, 1))
		deviation = dev
		# 计算目标位置（O 是中心点）
		var target_pos = (O-center_position) + max_offset * dev
		# 使用 lerp 平滑移动
		# ⚠ speed 是"每帧比例"而非"每秒速度"，所以收敛速度随帧率变化（详见函数头部的 D2 说明）
		position = position.lerp(target_pos, speed)
	else:
		_ready()  # 如果 body 未初始化，重新初始化


## 返回原点位置到[param a]的偏移在原大小中的比值，如果[param is_exceed]为true，则允许超出边界，否则返回该向量最大值
func _aiming_deviation(a:Vector2=Vector2.ZERO,is_exceed:bool=false) -> Vector2:
	var dev:Vector2=2*a/(b_size-margin)
	if is_exceed:return dev
	else:return Vector2(min(max(dev.x,-1),1),min(max(dev.y,-1),1))

func aiming_move(delta:float,a:Vector2=Vector2.ZERO,is_exceed:bool=false) -> void:
	var dev:Vector2=_aiming_deviation(a,is_exceed)
	lerp_position(dev,delta)

################### 表情控制

## 切换表情。
## [b]幂等[/b]：与当前表情相同时直接返回，不重写 AtlasTexture.region —— 所以可以安全地每帧调用（D7）。
func set_expression(face: Face = Face.DEFAULT) -> void:
	if face == current_expression:
		return
	current_expression = face
	texture.region = _region_for(face)

## 表情 → 图集区域 的唯一映射表（纯手 k 的像素区域）
func _region_for(face: Face) -> Rect2:
	match face:
		Face.BLINK_LEFT:	return Rect2(8, 7, 8, 3)
		Face.BLINK_RIGHT:	return Rect2(0, 7, 8, 3)
		Face.BLINK:		return Rect2(0, 12, 9, 3)
		Face.DIE:			return Rect2(0, 24, 9, 3)
		_:						return Rect2(0, 2, 8, 3)


func play_animation(id:int) -> void:
	if animation_player.is_playing():
		animation_player.stop()
	match id:
		# 这里 play 之后紧跟 play_backwards 是**有意保留**的：chiler 是反向播放的眨眼，
		# 它同时让动画结束时贴图停在睁眼帧。不要"顺手优化"成单次 play()，
		# 否则眨眼结束后 TextureRect.texture 会变成 null、眼睛整只消失（详见 README §8）。
		0:animation_player.play("chiler");animation_player.play_backwards("chiler")

## 开关自动眨眼。幂等。
## 注意：它现在只管"眨不眨"，不再顺带把表情重置为 default —— 表情统一交给 set_expression()（D7）。
func set_knip(a:bool=true) -> void:
	if outomaties_knip!= a:
		outomaties_knip = a
		if a :
			set_random_timer()
		else:
			timer.stop()
	
func set_random_timer():
	if outomaties_knip == true and not timer.is_stopped():
		timer.stop()
	var random_time = randf_range(0.89, 3.4)
	timer.wait_time = random_time
	timer.start()

func _on_timer_timeout():
	play_animation(0)
	set_random_timer()
