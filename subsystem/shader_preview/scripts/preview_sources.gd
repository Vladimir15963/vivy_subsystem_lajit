extends RefCounted

## 通用 shader 效果预览 —— 源图（着色器采样的输入 `src_tex`）。
##
## 全部程序化生成，不依赖工程素材，所以子系统单独拷走也能跑；
## 另外自动收录 res://icon.svg 和 assets/ 下的图片，方便拿真实素材看效果。

const ICON_PATH := "res://icon.svg"
const EXTRA_DIRS := ["res://assets"]
const EXTENSIONS := ["png", "webp", "jpg", "jpeg", "bmp", "tga"]


## 返回 [{name, texture, size}]。
static func build_all() -> Array:
	var out: Array = []

	out.append(entry("棋盘格", make_checker(256)))
	out.append(entry("彩条 / 渐变", make_gradient(256)))
	out.append(entry("UV 坐标", make_uv(256)))
	out.append(entry("色轮", make_color_wheel(256)))
	out.append(entry("圆形蒙版（带 alpha）", make_blob(256)))
	out.append(entry("圆环 + 十字（带 alpha）", make_ring(256)))
	out.append(entry("噪点", make_noise(256)))
	out.append(entry("灰阶卡", make_grayscale_steps(256)))

	if ResourceLoader.exists(ICON_PATH):
		var t := load(ICON_PATH)
		if t is Texture2D:
			out.append(entry("icon.svg（带 alpha）", t))

	for dir_path in EXTRA_DIRS:
		var d := DirAccess.open(dir_path)
		if d == null:
			continue
		var names: Array = []
		for f in d.get_files():
			names.append(String(f))
		names.sort()
		for f in names:
			if not EXTENSIONS.has(f.get_extension().to_lower()):
				continue
			var p := "%s/%s" % [dir_path, f]
			if not ResourceLoader.exists(p):
				continue
			var t := load(p)
			if t is Texture2D:
				out.append(entry("assets/" + f, t))

	return out


static func entry(label: String, tex: Texture2D) -> Dictionary:
	var size := Vector2i.ZERO
	if tex != null:
		size = tex.get_size()
	return {"name": label, "texture": tex, "size": size}


# --------------------------------------------------------------- 程序化图片

## 双色棋盘：看模糊 / 像素化 / 色差最直观。
@warning_ignore("integer_division")
static func make_checker(size: int, cell: int = 24) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var a := Color(0.20, 0.78, 0.82)
	var b := Color(0.96, 0.62, 0.22)
	for y in size:
		for x in size:
			var on := ((x / cell) + (y / cell)) % 2 == 0
			img.set_pixel(x, y, a if on else b)
	return ImageTexture.create_from_image(img)


## 横向色相扫 + 纵向明度坡：看调色 / 色阶 / 色差。
static func make_gradient(size: int) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		var v: float = 1.0 - float(y) / float(max(size - 1, 1))
		for x in size:
			var h := float(x) / float(max(size - 1, 1))
			img.set_pixel(x, y, Color.from_hsv(h, 1.0, 0.15 + 0.85 * v))
	return ImageTexture.create_from_image(img)


## r=u、g=v、b=0.5：畸变类效果一眼就能看出 UV 有没有被推歪。
static func make_uv(size: int) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			img.set_pixel(x, y, Color(
				float(x) / float(max(size - 1, 1)),
				float(y) / float(max(size - 1, 1)),
				0.5
			))
	return ImageTexture.create_from_image(img)


static func make_color_wheel(size: int) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) - c + 0.5, float(y) - c + 0.5) / c
			var r := d.length()
			if r > 1.0:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var h := fposmod(atan2(d.y, d.x) / TAU + 0.5, 1.0)
			img.set_pixel(x, y, Color.from_hsv(h, clamp(r * 1.15, 0.0, 1.0), 1.0))
	return ImageTexture.create_from_image(img)


## 圆形蒙版：上下两个圆叠出来的「雪人」，带抗锯齿 alpha。
## 描边 / 溶解这类吃 alpha 的效果必须拿它看。
static func make_blob(size: int) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var s := float(size)
	var head := Vector2(s * 0.32, s * 0.32)
	var body := Vector2(s * 0.42, s * 0.4)
	var head_c := Vector2(s * 0.5, s * 0.58)
	var body_c := Vector2(s * 0.5, s * 0.28)
	for y in size:
		for x in size:
			var p := Vector2(float(x) + 0.5, float(y) + 0.5)
			var a1 := 1.0 - smoothstep(head.x - 1.5, head.x + 1.5, p.distance_to(head_c))
			var a2 := 1.0 - smoothstep(body.x - 1.5, body.x + 1.5, p.distance_to(body_c))
			var a: float = max(a1, a2)
			var col := Color(0.95, 0.95, 0.98, a)
			# 内部画一点色彩花纹，方便看染色类效果
			var stripe := 0.5 + 0.5 * sin(p.y * 0.35)
			col.r = 0.5 + 0.5 * stripe
			col.g = 0.35 + 0.6 * (1.0 - stripe)
			col.b = 0.9
			col.a = a
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


## 圆环 + 十字：细线条形状，看描边粗细与模糊最直观。
static func make_ring(size: int) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	var outer := float(size) * 0.38
	var inner := float(size) * 0.28
	var bar := float(size) * 0.035
	for y in size:
		for x in size:
			var p := Vector2(float(x) + 0.5 - c, float(y) + 0.5 - c)
			var r := p.length()
			# 圆环 = 「比内径大」×「比外径小」，两个 smoothstep 相乘才对；
			# 写成 min(外, 1-内) 会让整圈恒为 0（这坑踩过一次）。
			var ring := smoothstep(inner - 1.5, inner + 1.5, r) * (1.0 - smoothstep(outer - 1.5, outer + 1.5, r))
			var cross := 0.0
			if abs(p.x) < bar or abs(p.y) < bar:
				cross = 1.0
			var a: float = clamp(max(ring, cross), 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 0.9, 0.35, a))
	return ImageTexture.create_from_image(img)


static func make_noise(size: int, seed_value: int = 20260101) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for y in size:
		for x in size:
			img.set_pixel(x, y, Color(rng.randf(), rng.randf(), rng.randf()))
	return ImageTexture.create_from_image(img)


@warning_ignore("integer_division")
static func make_grayscale_steps(size: int, steps: int = 8) -> ImageTexture:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var strip: int = maxi(size / 4, 1)
	for y in size:
		for x in size:
			if y >= size - strip:
				img.set_pixel(x, y, Color(float(x) / float(max(size - 1, 1)), 0, 0))
				continue
			var i := int(float(x) / float(max(size - 1, 1)) * float(steps - 1) + 0.5)
			var v := float(i) / float(max(steps - 1, 1))
			img.set_pixel(x, y, Color(v, v, v))
	return ImageTexture.create_from_image(img)
