class_name PvDisplay
extends Node2D

## 显示层：把 `PvScreen` 的三张格子数据纹理喂给 `glyph_grid.gdshader`，并负责固定窗口。
##
## 与 `PvScreen` 分开的理由：屏幕是纯逻辑（可在 headless 下自测），纹理与窗口是只在真实渲染
## 环境里才存在的东西。这样自测不会因为「沙箱没有 GPU」而失败（参考 shader_preview 的教训）。

const SHADER := preload("res://subsystem/world_execute/shaders/glyph_grid.gdshader")
## C 层全屏 post（色差/颗粒/辉光/glitch/CRT 转场）；参数与分工见 `pv_post.gd`。
const POST_SHADER := preload("res://subsystem/world_execute/shaders/post_fullscreen.gdshader")

## 窗口缩放：1.0 = 一格 9×18 px、整屏 1773×936（像素级 1:1）。
const WINDOW_SCALE := 1.0

var screen: PvScreen
var canvas: ColorRect
## 注意：不能叫 `material` —— `CanvasItem` 已有同名原生属性，重定义会解析报错。
var shader_mat: ShaderMaterial
## C 层全屏 post 层：盖在 `canvas` 之上（后加入 → 后绘制），用屏幕采样读字形画面。
var post_rect: ColorRect
var post_mat: ShaderMaterial
var _shown_size := Vector2.ZERO
## 抖动基准位置（最近一次「无抖动」时的窗口坐标）；见 `apply_fixed_window()` / `sync_rest_position()`。
var _rest_pos := Vector2i.ZERO
var _have_rest := false

var _idx_img: Image
var _fg_img: Image
var _bg_img: Image
var _idx_tex: ImageTexture
var _fg_tex: ImageTexture
var _bg_tex: ImageTexture


func setup(p_screen: PvScreen) -> void:
	screen = p_screen
	shader_mat = ShaderMaterial.new()
	shader_mat.shader = SHADER
	canvas = ColorRect.new()
	canvas.name = "GlyphCanvas"
	canvas.material = shader_mat
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(canvas)
	post_mat = ShaderMaterial.new()
	post_mat.shader = POST_SHADER
	post_rect = ColorRect.new()
	post_rect.name = "PostCanvas"
	post_rect.material = post_mat
	post_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post_rect.color = Color(1, 1, 1, 1)
	add_child(post_rect)
	_rebuild_textures()
	_refresh_uniforms()
	apply_fixed_window()


## 固定窗口**大小**（不做窄窗降级）：内容缩放关掉 → 视口尺寸 = 窗口尺寸 → 1:1。
##
## C 层决策（`tools/ref/c_layer_plan.md` §7）：只锁尺寸、**不锁位置**——启动居中一次，之后允许
## 用户拖放，也允许 1B 真窗口抖动临时改 `Window.position`。
func apply_fixed_window() -> void:
	var win := get_window()
	if win == null:
		return
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var px := Vector2i(
		roundi(screen.cols * screen.atlas.cell_w * WINDOW_SCALE),
		roundi(screen.rows * screen.atlas.cell_h * WINDOW_SCALE))
	win.size = px
	# 尺寸锁死：拖边框改不了大小，最大化/全屏也不给（窗口 1:1 的格几何是全场演出与 B 层贴带的基准）。
	win.min_size = px
	win.max_size = px
	win.unresizable = true
	var screen_pos: Vector2i = DisplayServer.screen_get_position(DisplayServer.window_get_current_screen())
	var screen_size: Vector2i = DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	win.position = screen_pos + (screen_size - px) / 2
	_rest_pos = win.position
	_have_rest = true


## 抖动基准位置：无抖动时每帧与真实窗口位置同步，于是用户手动拖窗不会被抢回居中；
## 抖动帧以「最近一次停靠点」为基准偏移，抖完自然回到用户自己放的位置。
func sync_rest_position() -> void:
	var win := get_window()
	if win == null:
		return
	if not _have_rest:
		_rest_pos = win.position
		_have_rest = true
		return
	_rest_pos = win.position


## 1B 真窗口抖动：`offset` 为非零时把窗口挪到基准 + 偏移，为零时贴回基准。
## headless / 内嵌子窗口环境下位置是假值，调用方应先用 `PvFx.window_shake_active()` 判断。
func apply_window_offset(offset: Vector2i) -> void:
	var win := get_window()
	if win == null or not _have_rest:
		return
	win.position = _rest_pos + offset


## 每帧调用：把当前缓冲上传成三张纹理。
##
## 无 GPU 时（headless / dummy 渲染器）`ImageTexture.create_from_image` 返回 null，这里直接跳过：
## 显示层只服务真实渲染，纯逻辑自测在 tests/ 里跑（headless 不建纹理，是 shader_preview 的教训）。
func update_textures() -> void:
	if _idx_tex == null or _fg_tex == null or _bg_tex == null:
		return
	var d := screen.to_data()
	_idx_img = Image.create_from_data(screen.cols, screen.rows, false, Image.FORMAT_RGBA8, d["idx"])
	_fg_img = Image.create_from_data(screen.cols, screen.rows, false, Image.FORMAT_RGBA8, d["fg"])
	_bg_img = Image.create_from_data(screen.cols, screen.rows, false, Image.FORMAT_RGBA8, d["bg"])
	_idx_tex.update(_idx_img)
	_fg_tex.update(_fg_img)
	_bg_tex.update(_bg_img)


## headless 下 dummy 渲染器建不出纹理（会刷一堆 "Invalid image: image is empty"），故直接跳过。
static func can_create_textures() -> bool:
	return DisplayServer.get_name() != "headless"


func _rebuild_textures() -> void:
	if not can_create_textures():
		return
	# 注意：Image.create() 是静态方法，必须接收返回值；Image.new() 造出来的是空图，
	# 对它调 create() 不会填充它（实测窗口化时报 "Invalid image: image is empty"）。
	var blank := Image.create(screen.cols, screen.rows, false, Image.FORMAT_RGBA8)
	_idx_tex = ImageTexture.create_from_image(blank)
	_fg_tex = ImageTexture.create_from_image(blank)
	_bg_tex = ImageTexture.create_from_image(blank)
	update_textures()


func _refresh_uniforms() -> void:
	shader_mat.set_shader_parameter("atlas", screen.atlas.texture)
	shader_mat.set_shader_parameter("cell_idx", _idx_tex)
	shader_mat.set_shader_parameter("cell_fg", _fg_tex)
	shader_mat.set_shader_parameter("cell_bg", _bg_tex)
	shader_mat.set_shader_parameter("grid_size", Vector2(screen.cols, screen.rows))
	shader_mat.set_shader_parameter("cell_size", screen.atlas.cell_size_vec())
	shader_mat.set_shader_parameter("atlas_size", screen.atlas.atlas_size())
	shader_mat.set_shader_parameter("atlas_cols", float(screen.atlas.atlas_cols))
	var shown := Vector2(screen.cols, screen.rows) * screen.atlas.cell_size_vec() * WINDOW_SCALE
	_shown_size = shown
	canvas.size = shown
	canvas.position = Vector2.ZERO
	post_rect.size = shown
	post_rect.position = Vector2.ZERO
	post_mat.set_shader_parameter("texel_w", 1.0 / maxf(1.0, shown.x))


## 每帧喂 post 参数（`PvPost.params_at()` 的结果）。关闭时把强度清零而不是隐藏节点——
## 隐藏会让屏幕采样读到「没有下层」的黑屏。
func update_post(p: Dictionary) -> void:
	if post_mat == null:
		return
	var on := bool(p.get("enabled", false))
	post_mat.set_shader_parameter("time", float(p.get("time", 0.0)))
	post_mat.set_shader_parameter("chroma", float(p.get("chroma", 0.0)) if on else 0.0)
	post_mat.set_shader_parameter("grain", float(p.get("grain", 0.0)) if on else 0.0)
	post_mat.set_shader_parameter("glow", float(p.get("glow", 0.0)) if on else 0.0)
	post_mat.set_shader_parameter("glitch", float(p.get("glitch", 0.0)) if on else 0.0)
	post_mat.set_shader_parameter("crt", float(p.get("crt", -1.0)) if on else -1.0)
