extends Node2D
## player_system 无头冒烟测试（新增，非剥离物）
##
## 运行：
##   godot --headless --path <测试项目> res://subsystem/player_system/tests/player_smoke_test.tscn
## 或者用 godot_run_headless(scene="player_system/tests/player_smoke_test.tscn")。
##
## 覆盖范围：
##   1. 场景装配（节点结构 / 脚本挂载 / 素材解析 / D14·D9 的"不该有的东西确实没有"）
##   2. 重力落地
##   3. 水平移动（含 max_speed 钳制）
##   4. 跳跃 + 土狼时间 + 二段跳禁用
##   5. 眼睛朝向偏移翻转（facing / eye_offset）
##   6. 眼睛表情（地面自动眨眼 / 空中 blink / die / D7 幂等）
##   7. 玩家缩放对运动的影响
##   8. 空中阻力（朝向反方向 + 原地起跳例外）
##   9. 死亡与复位（D11 信号化 API / D14 无内置死亡表现 / 动画扩展点）
##
## 退出码：全部通过 0，任一断言失败 1。

const PLAYER_SCENE := preload("res://subsystem/player_system/scenes/player.tscn")
## 眼睛脚本常量（不用 class_name，无编辑器也能解析；见 eye.gd 顶部说明）
const Eye = preload("res://subsystem/player_system/scripts/eye.gd")
## 玩家脚本常量：用来取 DeathKind 枚举
const PlayerScript = preload("res://subsystem/player_system/scripts/player.gd")
## 死亡测试用的落点（地板顶面在 FLOOR_TOP=200，这里悬空起跳/下落）
const SPAWN_FOR_TEST := Vector2(0.0, 100.0)

const FLOOR_TOP := 200.0

const REGION_DEFAULT := Rect2(0, 2, 8, 3)
const REGION_BLINK := Rect2(0, 12, 9, 3)
const REGION_DIE := Rect2(0, 24, 9, 3)

var _player: CharacterBody2D
var _eyes: Eye
var _sprite: Sprite2D
var _death_animation: AnimationPlayer

var _checks: int = 0
var _failures: int = 0
## 跑完全部用例才会置位。用来防止"某段脚本错误导致测试中途截断，却仍然报绿"。
var _completed: bool = false


func _ready() -> void:
	print("=== player_system 冒烟测试 ===")
	_build_world()
	await _run()
	_report()


func _report() -> void:
	# 完整性哨兵：只要没有跑到最后一行，就判定失败 —— 否则运行时脚本错误会把
	# 余下的断言整段吞掉，而打印出来的却是"全绿"（这个坑真的踩过）。
	if not _completed:
		_failures += 1
		_checks += 1
		printerr("  [FAIL] 测试被中途中断，没有跑完全部用例 —— 本次结果不可信")
	print("=== 结果：%d/%d 通过，%d 失败 ===" % [_checks - _failures, _checks, _failures])
	_release_all()
	if _failures > 0:
		printerr("player_system 冒烟测试失败")
		get_tree().quit(1)
	else:
		print("player_system 冒烟测试通过")
		get_tree().quit(0)


# ────────────────────────── 基础设施 ──────────────────────────

func check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)


func wait_physics(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame


func wait_process(n: int) -> void:
	for _i in n:
		await get_tree().process_frame


func _release_all() -> void:
	for a in ["move_left", "move_right", "jump"]:
		Input.action_release(a)


## 等待玩家落地并静止几帧
func _settle_on_floor() -> void:
	for _i in 300:
		await get_tree().physics_frame
		if _player.is_on_floor():
			break
	await wait_physics(3)


## 测量一次跳跃中水平速度的保留率。
## [param press_at_takeoff] true = 起跳瞬间按住方向（阻力生效）；
##                          false = 起跳前松手（原地起跳，整段滞空忽略阻力）
func _measure_air_retention(press_at_takeoff: bool, air_frames: int = 40) -> Dictionary:
	await _settle_on_floor()
	Input.action_press("move_right")
	await wait_physics(30)              # 先把水平速度跑满

	if not press_at_takeoff:
		Input.action_release("move_right")
		await wait_physics(1)           # 让起跳那一帧的输入为 0

	Input.action_press("jump")
	await wait_physics(2)
	Input.action_release("jump")
	if press_at_takeoff:
		Input.action_release("move_right")

	var v0: float = _player.current_velocity.x
	var suppressed: bool = _player.air_drag_suppressed
	await wait_physics(air_frames)
	var v1: float = _player.current_velocity.x
	return {
		"v0": v0,
		"v1": v1,
		"retained": v1 / v0 if v0 > 0.0 else 0.0,
		"suppressed": suppressed,
	}


## 把玩家置于「滞空且阻力生效」的状态：起跳瞬间按住方向，随后全部松手
func _take_off_with_input() -> void:
	await _settle_on_floor()
	Input.action_press("move_right")
	await wait_physics(2)
	Input.action_press("jump")
	await wait_physics(2)
	Input.action_release("jump")
	Input.action_release("move_right")


## 执行一次跳跃，返回 {"height": 最高点相对落点的像素高度, "frames": 从起跳到落地的物理帧数}
func _measure_jump() -> Dictionary:
	await _settle_on_floor()
	var ground_y: float = _player.position.y
	var apex: float = ground_y
	var frames: int = 0

	Input.action_press("jump")
	await wait_physics(2)
	Input.action_release("jump")

	for _i in 400:
		await get_tree().physics_frame
		frames += 1
		apex = minf(apex, _player.position.y)
		if frames > 5 and _player.is_on_floor():
			break
	return {"height": ground_y - apex, "frames": frames}


func _build_world() -> void:
	# 简易地板：静态刚体 + 矩形碰撞，顶面位于 y = FLOOR_TOP
	var floor_body := StaticBody2D.new()
	floor_body.name = "Floor"
	floor_body.position = Vector2(0, FLOOR_TOP + 20.0)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(4000, 40)
	shape.shape = rect
	floor_body.add_child(shape)
	add_child(floor_body)

	_player = PLAYER_SCENE.instantiate()
	_player.name = "player"
	add_child(_player)

	_eyes = _player.eyes
	_sprite = _player.player
	_death_animation = _player.death_animation


# ────────────────────────── 用例 ──────────────────────────

func _run() -> void:
	await wait_process(2)

	_test_assembly()
	await _test_gravity_and_landing()
	await _test_ground_eyes()
	await _test_horizontal_move()
	await _test_jump()
	await _test_air_eyes()
	await _test_eye_expressions()
	await _test_scale_affects_motion()
	await _test_air_drag()
	await _test_death_and_respawn()
	await _test_robustness()
	_completed = true


func _test_assembly() -> void:
	print("[1] 场景装配")
	check(_player is CharacterBody2D, "根节点是 CharacterBody2D")
	check(_player.get_script() != null and _player.get_script().resource_path.ends_with("player_system/scripts/player.gd"),
		"player.gd 已挂载（脚本路径位于 player_system 内）")
	check(_eyes != null and _eyes.get_script() != null and _eyes.get_script().resource_path.ends_with("player_system/scripts/eye.gd"),
		"eyes 子场景已挂载 eye.gd")
	check(_eyes.get_node_or_null("TextureRect") != null, "eyes/TextureRect 存在")
	check(_eyes.get_node_or_null("AnimationPlayer") != null, "eyes/AnimationPlayer 存在")
	check(_eyes.get_node_or_null("Timer") != null, "eyes/Timer 存在")

	check(_sprite.texture != null, "玩家本体贴图解析成功（player.png）")
	check(_eyes.texture != null, "眼睛图集解析成功（eyes2-1.png）")
	check(_eyes.get_node("AnimationPlayer").has_animation(&"chiler"), "眼睛眨眼动画 chiler 存在")

	# ── D14：死亡特效素材不再常驻玩家场景 ──
	check(_player.get_node_or_null("smoke") == null, "D14：玩家场景已无 smoke(AnimatedSprite2D)")
	check(_find_first_animated_sprite(_player) == null, "D14：玩家场景整棵树里没有 AnimatedSprite2D")
	check(not ResourceLoader.has_cached("res://subsystem/player_system/assets/fx/mist_01.png"),
		"D14：加载玩家场景不会把 28 帧烟雾拉进资源缓存")
	check(not ResourceLoader.has_cached("res://subsystem/player_system/assets/audio/我的世界玩家受伤.ogg"),
		"D14：玩家场景不再引用受伤音效")
	check(ResourceLoader.exists("res://subsystem/player_system/assets/fx/mist_01.png"),
		"D14：烟雾素材仍留在素材库里，供特效层或将来使用")

	# ── D9：玩家不再自带 WorldEnvironment / Environment ──
	check(_player.get_node_or_null("WorldEnvironment") == null, "D9：玩家场景已无 WorldEnvironment")
	check(_find_first_world_environment(_player) == null, "D9：玩家场景整棵树里没有 WorldEnvironment")

	# ── D11：死亡表现改为扩展点 ──
	check(_death_animation != null, "D11：DeathAnimation 扩展点存在")
	check(_death_animation.get_animation_list().size() == 0,
		"D11：DeathAnimation 默认是空的（不内置任何死亡动画）")
	check(not _player.has_method("deal"), "D11：旧的 deal(String) 已移除")
	check(not _player.has_method("_on_button_button_up"), "D11：UI 耦合的 _on_button_button_up 已移除")
	check(_player.has_signal("died") and _player.has_signal("respawned"), "D11：died / respawned 信号已暴露")
	check(_player.has_method("die") and _player.has_method("respawn") and _player.has_method("respawn_at"),
		"D11：die() / respawn() / respawn_at() 已暴露")

	# ── D13：命名与显式化 ──
	check("facing" in _player and not ("player_direction" in _player), "D13：player_direction → facing")
	check("eye_offset" in _player and not ("dirrction_dev" in _player), "D13：dirrction_dev → eye_offset")

	# ── D12：手感参数可在检查器里调 ──
	var exported: Array[String] = []
	for p in _player.get_property_list():
		if p.usage & PROPERTY_USAGE_EDITOR and p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			exported.append(p.name)
	for want in ["max_speed", "jump_velocity", "gravity", "acceleration", "ground_friction",
			"max_jumps", "coyote_time", "jump_buffer_time", "eye_offset", "eye_follow_speed",
			"eye_aim_speed", "air_drag", "air_control", "in_place_epsilon", "eyes_mode"]:
		check(want in exported, "D12：%s 已 @export" % want)


## 递归找第一个 AnimatedSprite2D（D14 用：应该一个都没有）
func _find_first_animated_sprite(n: Node) -> AnimatedSprite2D:
	if n is AnimatedSprite2D:
		return n
	for c in n.get_children():
		var hit := _find_first_animated_sprite(c)
		if hit:
			return hit
	return null


## 递归找第一个 WorldEnvironment（D9 用：应该一个都没有）
func _find_first_world_environment(n: Node) -> WorldEnvironment:
	if n is WorldEnvironment:
		return n
	for c in n.get_children():
		var hit := _find_first_world_environment(c)
		if hit:
			return hit
	return null


func _test_gravity_and_landing() -> void:
	print("[2] 重力与落地")
	check(not _player.is_on_floor(), "初始悬空")
	var start_y: float = _player.position.y

	var landed := false
	for _i in 240:
		await get_tree().physics_frame
		if _player.is_on_floor():
			landed = true
			break
	check(landed, "在 240 个物理帧内落地")
	check(_player.position.y > start_y, "受重力下落（y 增大）")
	check(absf(_player.position.y - (FLOOR_TOP - 5.98)) < 4.0,
		"停在地板顶面附近（y=%.2f，期望约 %.2f）" % [_player.position.y, FLOOR_TOP - 5.98])
	check(absf(_player.velocity.y) < 5.0, "落地后垂直速度归零")
	check(Input.get_axis("move_left", "move_right") == 0.0, "输入映射 move_left/move_right 已注册")


func _test_ground_eyes() -> void:
	print("[3] 地面眼睛状态")
	await wait_process(3)
	check(_eyes.outomaties_knip == true, "地面开启自动眨眼（set_knip(true)）")
	check(_eyes.texture.region == REGION_DEFAULT, "地面表情为 default")


func _test_horizontal_move() -> void:
	print("[4] 水平移动")
	var x0: float = _player.position.x
	Input.action_press("move_right")
	await wait_physics(40)
	check(_player.velocity.x > 0.0, "按右键后 x 速度为正（%.1f）" % _player.velocity.x)
	check(_player.position.x > x0, "向右位移生效")
	check(_player.velocity.x <= _player.max_speed + 1.0,
		"x 速度不超过 max_speed（%.1f ≤ %.1f）" % [_player.velocity.x, _player.max_speed])

	await wait_process(5)
	check(_eyes.deviation.x > 0.0, "向右移动时眼睛偏移 x 为正（%.3f）" % _eyes.deviation.x)

	Input.action_release("move_right")
	var x_mid: float = _player.position.x
	Input.action_press("move_left")
	await wait_physics(40)
	check(_player.velocity.x < 0.0, "按左键后 x 速度为负（%.1f）" % _player.velocity.x)
	check(_player.position.x < x_mid, "向左位移生效")

	await wait_process(5)
	check(_eyes.deviation.x < 0.0, "向左移动时眼睛偏移 x 翻转为负（%.3f）" % _eyes.deviation.x)
	Input.action_release("move_left")

	# 松手后地面摩擦应让速度衰减
	await wait_physics(30)
	check(absf(_player.velocity.x) < 5.0, "松手后地面摩擦使速度衰减（%.2f）" % _player.velocity.x)


func _test_jump() -> void:
	print("[5] 跳跃")
	Input.action_press("jump")
	await wait_physics(2)
	Input.action_release("jump")
	await wait_physics(3)
	check(_player.velocity.y < 0.0, "起跳瞬间垂直速度为负（%.1f）" % _player.velocity.y)
	check(_player.jump_count == 1, "跳跃计数为 1")

	var apex_y: float = _player.position.y
	for _i in 12:
		await get_tree().physics_frame
		apex_y = minf(apex_y, _player.position.y)
	check(not _player.is_on_floor(), "起跳后离地")
	check(apex_y < FLOOR_TOP - 20.0, "确实上升了（最高 y=%.1f）" % apex_y)

	# 空中再次按跳：max_jumps = 1，不应触发二段跳
	Input.action_press("jump")
	await wait_physics(3)
	Input.action_release("jump")
	check(_player.jump_count == 1, "空中不得二段跳（jump_count 仍为 1）")
	check(_player.velocity.y > -800.0, "空中按键未重置起跳速度")

	# 等待落地
	for _i in 240:
		await get_tree().physics_frame
		if _player.is_on_floor():
			break
	check(_player.is_on_floor(), "重新落地")
	# is_on_floor() 在 move_and_slide() 之后才翻转，需再等一帧让 _physics_process 重置计数
	await wait_physics(1)
	check(_player.jump_count == 0, "落地后跳跃计数重置")


func _test_air_eyes() -> void:
	print("[6] 空中眼睛状态")
	Input.action_press("jump")
	await wait_physics(2)
	Input.action_release("jump")
	await wait_physics(2)
	await wait_process(2)
	check(not _player.is_on_floor(), "空中")
	check(_eyes.outomaties_knip == false, "空中关闭自动眨眼")
	check(_eyes.texture.region == REGION_BLINK, "空中表情切到 blink")

	for _i in 240:
		await get_tree().physics_frame
		if _player.is_on_floor():
			break
	await wait_process(3)
	check(_eyes.outomaties_knip == true, "落地后恢复自动眨眼")


func _test_eye_expressions() -> void:
	print("[7] 眼睛表情与眨眼动画")
	_eyes.set_expression(Eye.Face.DIE)
	check(_eyes.texture.region == REGION_DIE, "set_expression(DIE) 区域正确")
	_eyes.set_expression(Eye.Face.BLINK_LEFT)
	check(_eyes.texture.region == Rect2(8, 7, 8, 3), "set_expression(BLINK_LEFT) 区域正确")
	_eyes.set_expression(Eye.Face.BLINK_RIGHT)
	check(_eyes.texture.region == Rect2(0, 7, 8, 3), "set_expression(BLINK_RIGHT) 区域正确")
	_eyes.set_expression(Eye.Face.DEFAULT)
	check(_eyes.texture.region == REGION_DEFAULT, "set_expression(DEFAULT) 区域还原")
	check(_eyes.current_expression == Eye.Face.DEFAULT, "current_expression 随 set_expression 更新")

	# ── D7 回归：set_expression 幂等（同表情重复调用不重写 region） ──
	# 直接验证"没写"：人为把 region 改坏，再用同一表情调用一次，region 必须原样保留。
	_eyes.set_expression(Eye.Face.BLINK)
	var tampered := Rect2(99, 99, 9, 3)
	_eyes.texture.region = tampered
	_eyes.set_expression(Eye.Face.BLINK)
	check(_eyes.texture.region == tampered, "D7：同表情重复调用不重写 region（幂等）")
	_eyes.set_expression(Eye.Face.DEFAULT)
	check(_eyes.texture.region == REGION_DEFAULT, "D7：换表情时确实重写 region")

	# ── D7 回归：set_knip 与 set_expression 职责已拆分 ──
	_eyes.set_expression(Eye.Face.BLINK)
	_eyes.set_knip(true)
	check(_eyes.current_expression == Eye.Face.BLINK, "D7：set_knip 不再顺带把表情重置为 default")
	_eyes.set_knip(false)
	check(_eyes.current_expression == Eye.Face.BLINK, "D7：set_knip(false) 也不动表情")
	_eyes.set_expression(Eye.Face.DEFAULT)

	_eyes._on_timer_timeout()
	await wait_process(2)
	check(_eyes.animation_player.is_playing(), "眨眼计时器回调驱动 chiler 动画")

	# ── D1 回归：完整跑一次眨眼，逐帧确认「眼睛不会消失」 ──
	# chiler 的贴图轨道末帧曾被写成 null（离散轨道，值会一直保持），
	# 实测每次眨眼有连续 3 帧（≈50ms）整只眼睛没有贴图。这里把不变量钉死。
	var tr: TextureRect = _eyes.get_node("TextureRect")
	_eyes.set_knip(true)
	await wait_process(2)
	await get_tree().create_timer(0.4).timeout   # 等上一次眨眼彻底结束
	_eyes._on_timer_timeout()
	var null_frames: int = 0
	var regions: Dictionary = {}
	for _i in 24:
		if tr.texture == null:
			null_frames += 1
		elif tr.texture is AtlasTexture:
			regions[tr.texture.region] = true
		await get_tree().process_frame
	check(null_frames == 0, "眨眼全程 TextureRect.texture 都不为 null（实测 %d 帧为空）" % null_frames)
	check(regions.size() >= 3, "眨眼过程确实切换了多个图集区域（%d 种）" % regions.size())
	check(tr.texture == _eyes.texture,
		"眨眼结束后贴图回到脚本缓存的图集（set_expression 仍作用在显示中的资源上）")
	_eyes.set_expression(0)
	await wait_process(1)
	check(tr.texture != null and tr.texture is AtlasTexture and tr.texture.region == REGION_DEFAULT,
		"眨眼结束后表情仍可正常切换")

	# 眼睛偏移始终被钳制在 [-1, 1]
	_eyes.lerp_position(Vector2(9.0, -9.0), 1.0)
	check(_eyes.deviation.x <= 1.0 and _eyes.deviation.y >= -1.0, "lerp_position 对偏移做 [-1,1] 钳制")

	# 眼睛模式切换（枚举顺序：look_at = 0, move = 1）
	_player.set_eyes_mode(0)
	var pos_before: Vector2 = _eyes.position
	await wait_process(5)
	check(int(_player.eyes_mode) == 0, "eyes_mode 已切到 look_at(0)")
	check(_eyes.position.distance_to(pos_before) < 200.0, "look_at 模式下眼睛位置仍在合理范围")
	check(absf(_eyes.deviation.x) <= 1.0 and absf(_eyes.deviation.y) <= 1.0,
		"look_at 模式偏移仍在 [-1,1] 内")

	# 切回 move 并由移动方向驱动
	_player.set_eyes_mode(1)
	Input.action_press("move_right")
	await wait_physics(20)
	await wait_process(5)
	check(int(_player.eyes_mode) == 1, "eyes_mode 已切回 move(1)")
	check(_eyes.deviation.x > 0.0, "move 模式下眼睛随朝向偏移")
	Input.action_release("move_right")


func _test_scale_affects_motion() -> void:
	print("[8] 玩家缩放对运动的影响")

	# ── 基准态：scale = 1 时一切与改造前一致 ──
	_player.scale_affects_motion = true
	_player.motion_scale = Vector2.ONE
	_player.scale = Vector2.ONE
	Input.action_release("move_left")
	Input.action_release("move_right")
	await _settle_on_floor()
	# 基准值不写死：调参（max_speed / jump_velocity / gravity）后测试自动跟随
	var base_speed: float = _player.max_speed
	var base_jump: float = _player.jump_velocity
	var base_gravity: float = _player.gravity
	check(base_speed > 0.0 and base_jump < 0.0, "scale=1 读出基准 max_speed=%.1f / jump_velocity=%.1f / gravity=%.1f"
		% [base_speed, base_jump, base_gravity])

	# 基准跳跃：记录像素高度与滞空帧数
	var ref := await _measure_jump()

	# ── 放大到 2 倍 ──
	_player.scale = Vector2(2.0, 2.0)
	await wait_physics(2)
	check(is_equal_approx(_player.max_speed, base_speed * 2.0), "scale=2 时 max_speed 随 sx 等比放大（%.1f）" % _player.max_speed)
	check(is_equal_approx(_player.jump_velocity, base_jump * 2.0), "scale=2 时 jump_velocity 随 sy 等比放大（%.1f）" % _player.jump_velocity)
	check(is_equal_approx(_player.gravity, base_gravity * 2.0), "scale=2 时 gravity 随 sy 等比放大（%.1f）" % _player.gravity)

	var scaled := await _measure_jump()
	var h_ref: float = ref["height"]
	var h_scaled: float = scaled["height"]
	var f_ref: int = ref["frames"]
	var f_scaled: int = scaled["frames"]

	check(h_scaled / h_ref > 1.75 and h_scaled / h_ref < 2.25,
		"跳跃高度（像素）随缩放线性变化：%.1f → %.1f（×%.2f）" % [h_ref, h_scaled, h_scaled / h_ref])
	check(absi(f_scaled - f_ref) <= 4,
		"滞空帧数不随体型变化：%d → %d 帧" % [f_ref, f_scaled])

	# 相对自身体型的跳跃高度（像素高度 / 体型缩放）应保持不变
	var ratio_ref: float = h_ref / 1.0
	var ratio_scaled: float = h_scaled / 2.0
	check(absf(ratio_scaled - ratio_ref) / ratio_ref < 0.15,
		"折算成「几个自己那么高」后一致：%.1f px vs %.1f px" % [ratio_ref, ratio_scaled])

	# ── 缩回 1 倍应完全还原 ──
	_player.scale = Vector2.ONE
	await wait_physics(2)
	check(is_equal_approx(_player.max_speed, base_speed) and is_equal_approx(_player.jump_velocity, base_jump)
			and is_equal_approx(_player.gravity, base_gravity),
		"缩回 1 倍后运动参数完全还原")

	# ── 关掉开关：缩放不再影响运动 ──
	_player.scale_affects_motion = false
	_player.scale = Vector2(3.0, 3.0)
	await wait_physics(2)
	check(is_equal_approx(_player.max_speed, base_speed) and is_equal_approx(_player.jump_velocity, base_jump),
		"scale_affects_motion=false 时缩放不影响运动参数")

	# ── motion_scale 可单独给倍率 ──
	_player.motion_scale = Vector2(0.5, 0.5)
	await wait_physics(2)
	check(is_equal_approx(_player.max_speed, base_speed * 0.5), "motion_scale 可脱离 scale 单独调参（%.1f）" % _player.max_speed)
	_player.motion_scale = Vector2.ONE

	# ── 负缩放（水平翻转）只取模，不反转移动方向 ──
	_player.scale_affects_motion = true
	_player.scale = Vector2(-2.0, 2.0)
	await wait_physics(2)
	check(_player.max_speed > 0.0 and is_equal_approx(_player.max_speed, base_speed * 2.0),
		"负缩放取模，不把移动方向反转（max_speed=%.1f）" % _player.max_speed)

	# 还原
	_player.scale = Vector2.ONE
	await wait_physics(2)
	check(is_equal_approx(_player.max_speed, base_speed), "测试结束后缩放影响已还原")


func _test_air_drag() -> void:
	print("[9] 空中阻力（朝向反方向 + 原地起跳例外）")
	Input.action_release("move_left")
	Input.action_release("move_right")

	check(is_equal_approx(_player.air_drag, 0.35) and is_equal_approx(_player.air_control, 0.35),
		"air_drag=%.2f/秒、air_control=%.2f" % [_player.air_drag, _player.air_control])

	# ── 规则 1：原地起跳（起跳瞬间无输入）→ 整段滞空忽略阻力 ──
	var held := await _measure_air_retention(true)
	var in_place := await _measure_air_retention(false)
	check(held["suppressed"] == false, "起跳瞬间按住方向 → 阻力生效")
	check(in_place["suppressed"] == true, "起跳瞬间无输入 → 判定为原地起跳，忽略阻力")
	check(in_place["retained"] > 0.95,
		"原地起跳全程保留水平速度：%.1f → %.1f（保留 %.0f%%）"
		% [in_place["v0"], in_place["v1"], in_place["retained"] * 100.0])
	check(held["retained"] < 0.85,
		"非原地起跳被阻力削减：%.1f → %.1f（保留 %.0f%%）"
		% [held["v0"], held["v1"], held["retained"] * 100.0])
	check(in_place["retained"] > held["retained"] + 0.1, "原地起跳明显比非原地起跳更保速")

	# ── 规则 2：方向恒为「朝向的反方向」，而不是「速度的反方向」 ──
	await _take_off_with_input()
	_player.facing = 1
	_player.current_velocity.x = 100.0
	await wait_physics(30)
	check(_player.current_velocity.x < 90.0,
		"朝向前方的动量被阻力削减（100 → %.1f）" % _player.current_velocity.x)

	await _take_off_with_input()
	_player.facing = 1
	_player.current_velocity.x = -100.0
	await wait_physics(30)
	check(absf(_player.current_velocity.x + 100.0) < 1.0,
		"往身后滑时阻力不再起作用，不会被推向后方（-100 → %.1f）" % _player.current_velocity.x)

	await _take_off_with_input()
	_player.facing = 1
	_player.current_velocity.x = 0.0
	await wait_physics(30)
	check(absf(_player.current_velocity.x) < 0.5,
		"静止的滞空玩家不会被阻力推着飘起来（%.2f）" % _player.current_velocity.x)

	await _take_off_with_input()
	_player.facing = -1
	_player.current_velocity.x = -100.0     # 朝左且向左移动 = 朝向前方
	await wait_physics(30)
	check(_player.current_velocity.x > -90.0,
		"朝向翻转后阻力方向同步翻转（-100 → %.1f）" % _player.current_velocity.x)

	# ── air_drag = 0 时完全不衰减 ──
	await _take_off_with_input()
	var saved_drag: float = _player.air_drag
	_player.air_drag = 0.0
	_player.facing = 1
	_player.current_velocity.x = 100.0
	await wait_physics(30)
	check(absf(_player.current_velocity.x - 100.0) < 1.0,
		"air_drag=0 时不施加阻力（%.1f）" % _player.current_velocity.x)
	_player.air_drag = saved_drag

	# 复位
	_player.facing = 1
	Input.action_release("move_left")
	Input.action_release("move_right")
	await _settle_on_floor()
	await wait_physics(2)
	check(_player.air_drag_suppressed == false, "落地后阻力抑制状态已复位")


## 测量「松手后地面摩擦 20 帧的残余水平速度」，用来证明 ground_friction 真的是接上的参数
func _measure_ground_stop(friction: float) -> float:
	await _settle_on_floor()
	var saved: float = _player.ground_friction
	_player.ground_friction = friction
	Input.action_press("move_right")
	await wait_physics(30)
	Input.action_release("move_right")
	await wait_physics(20)
	var residual: float = absf(_player.current_velocity.x)
	_player.ground_friction = saved
	await _settle_on_floor()
	return residual


func _test_robustness() -> void:
	print("[11] 初始化幂等（D5）+ ground_friction 真的生效（D4b）")

	# ── D5 回归：重复调用 _ready() 不再叠乘 ×1.5 ──
	# 改造前实测：首次 186.75 → 再次 280.13 → 第三次 420.19（累计 ×3.375），无报错无日志。
	await _settle_on_floor()
	var speed_before: float = _player.max_speed
	var jump_before: float = _player.jump_velocity
	var spawn_before: Vector2 = _player.spawn_position
	_player._ready()
	_player._ready()
	await wait_physics(1)
	check(is_equal_approx(_player.max_speed, speed_before),
		"D5：重复 _ready() 不再叠乘（max_speed %.2f → %.2f）" % [speed_before, _player.max_speed])
	check(is_equal_approx(_player.jump_velocity, jump_before), "D5：jump_velocity 同样不叠乘")
	check(_player.spawn_position == spawn_before, "D5：重复 _ready() 不覆盖已记录的出生点")

	# ── D4b：ground_friction 现在真的接在地面分支上 ──
	var no_friction := await _measure_ground_stop(1.0)
	var heavy_friction := await _measure_ground_stop(0.2)
	check(no_friction > 100.0,
		"ground_friction=1.0 时地面不减速，残余 %.1f（证明这个参数在起作用）" % no_friction)
	check(heavy_friction < 5.0, "ground_friction=0.2 时地面迅速刹停，残余 %.2f" % heavy_friction)

	# ── 默认值仍是原来的 0.83（行为与改造前一致）──
	check(is_equal_approx(_player.ground_friction, 0.83), "ground_friction 默认值 = 原字面量 0.83")


func _test_death_and_respawn() -> void:
	print("[10] 死亡与复位（D11 信号化 API / D14 无内置死亡表现）")
	await _settle_on_floor()

	# ── 死亡：只置状态 + 发信号 ──
	var deaths: Array[int] = []
	_player.died.connect(func(kind: int): deaths.append(kind))
	var respawns: Array[int] = []
	_player.respawned.connect(func(): respawns.append(1))

	var v_before := _player.velocity
	_player.die(PlayerScript.DeathKind.HURT)
	check(_player.is_dead == true, "die(HURT) 置位 is_dead")
	check(deaths == [PlayerScript.DeathKind.HURT], "died 信号恰好 emit 一次且带对了 kind")

	# 幂等：重复 die 不再发信号
	_player.die(PlayerScript.DeathKind.ASCEND)
	check(deaths.size() == 1, "重复 die() 幂等，不会重复广播")

	await wait_physics(6)
	check(_player.velocity.is_equal_approx(v_before), "死亡后 _physics_process 提前返回，速度被冻结")

	# 死亡时眼睛锁成 blink（原来的表现保留）
	await wait_process(3)
	check(_eyes.texture.region == REGION_BLINK, "死亡时眼睛锁成 blink 表情")

	# 玩家本身不带任何死亡表现
	check(not _death_animation.is_playing(), "默认没有任何死亡动画在播（玩家不内置死亡表现）")
	check(_find_first_world_environment(_player) == null, "玩家不会去动任何 Environment（D9）")

	# ── 扩展点：往 DeathAnimation 里加一个同名动画，die() 就应该自动播它，不需要改代码 ──
	var probe := Animation.new()
	probe.length = 5.0
	var lib := AnimationLibrary.new()
	lib.add_animation(&"ascend", probe)
	_death_animation.add_animation_library(&"", lib)
	_player.respawn_at(SPAWN_FOR_TEST)
	_player.die(PlayerScript.DeathKind.ASCEND)
	check(_death_animation.is_playing() and _death_animation.current_animation == &"ascend",
		"D11/D14 扩展点：DeathAnimation 里有同名动画时 die() 会自动播放")
	_death_animation.stop()
	_death_animation.remove_animation_library(&"")
	check(not _death_animation.has_animation(&"ascend"), "移除动画库后扩展点恢复为空")
	_player.respawn_at(SPAWN_FOR_TEST)

	# ── 复位 ──
	_player.current_velocity = Vector2(123.0, 45.0)
	_player.jump_count = 1
	var respawns_before: int = respawns.size()
	_player.respawn_at(Vector2(7.0, 8.0))
	check(_player.is_dead == false, "respawn_at() 清掉死亡状态")
	check(_player.position == Vector2(7.0, 8.0), "respawn_at() 移动到指定位置")
	check(_player.velocity == Vector2.ZERO and _player.current_velocity == Vector2.ZERO, "respawn_at() 清零速度")
	check(_player.jump_count == 0, "respawn_at() 清零跳跃计数")
	check(_player.air_drag_suppressed == false, "respawn_at() 清掉阻力抑制状态")
	check(respawns.size() == respawns_before + 1, "respawned 信号恰好 emit 一次")

	# 不带参数的 respawn() 回到出生点
	var spawn: Vector2 = _player.spawn_position
	_player.respawn()
	check(_player.position == spawn, "respawn() 回到 _ready() 时记录的出生点")

	# ── 冻结开关 ──
	_player.freeze_on_death = false
	_player.die(PlayerScript.DeathKind.HURT)
	await wait_physics(3)
	check(_player.velocity.y > 0.0,
		"freeze_on_death=false 时死亡不再冻结物理（vy=%.1f）" % _player.velocity.y)

	# ── 复位后可以正常继续游玩 ──
	_player.freeze_on_death = true
	_player.respawn_at(SPAWN_FOR_TEST)
	await _settle_on_floor()
	check(_player.is_dead == false and _player.is_on_floor(), "复位后重新落地、状态正常")
	check(_eyes.outomaties_knip == true, "复位后自动眨眼恢复")
