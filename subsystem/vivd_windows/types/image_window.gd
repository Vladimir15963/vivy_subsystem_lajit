extends "res://subsystem/vivd_windows/vivd_window.gd"
## 图片窗口类型 —— 在独立窗口里显示一张图片。
##
## [codeblock]
## VivdWindowsNode.add_window("pic", "image", {
##     "image": "res://icon.svg",
##     "position": Vector2i(500, 500),
##     "size": Vector2i(320, 320),
## })
## [/codeblock]
##
## 场景里自带一个 [code]Texture[/code] 节点（TextureRect，铺满窗口、保持比例）。

## 当前显示的图片路径。
var image_path := ""

@onready var _texture: TextureRect = get_node_or_null("Texture")


## config.image 传图片路径。不传就保留场景里的默认图。
func setup(config: Dictionary) -> void:
	var path := str(config.get("image", ""))
	if not path.is_empty():
		set_image(path)


## 换图。返回是否成功。
func set_image(path: String) -> bool:
	if _texture == null:
		push_warning("[image_window] 场景里找不到 Texture 节点，无法显示图片")
		return false
	var texture := load(path)
	if texture == null:
		push_warning("[image_window] 图片加载失败：%s" % path)
		return false
	image_path = path
	_texture.texture = texture
	return true


## 让图片按窗口大小铺满（保持比例、居中）。
func fit_to_window() -> void:
	if _texture == null:
		return
	_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED


## 按图片原始像素尺寸调整窗口大小。
func resize_to_image() -> void:
	if _texture == null or _texture.texture == null:
		return
	size = Vector2i(_texture.texture.get_size())
