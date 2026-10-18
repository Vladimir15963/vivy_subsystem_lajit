extends RefCounted

## 通用 shader 效果预览 —— 效果清单。
##
## 清单 = 目录扫描 + 手工命名：
##   * `shaders/` 里登记在 ENTRIES 的 .gdshader 按 ENTRIES 的顺序排，带中文名和说明；
##   * 目录里其它 .gdshader 自动追加到末尾，名字取文件名。
##
## 所以往 `shaders/` 丢一个新的 .gdshader 就能在预览器里直接选到，不用改这个文件；
## 想让它排在前面 / 有中文名，再往 ENTRIES 里补一行即可。

const SHADER_DIR := "res://subsystem/shader_preview/shaders"

const ENTRIES := [
	{"file": "01_pixelate.gdshader", "name": "像素化 / 马赛克", "note": "方块化，可叠色阶量化，复古 8bit"},
	{"file": "02_dissolve.gdshader", "name": "溶解 / 燃尽", "note": "噪声阈值溶解 + 边缘发光带"},
	{"file": "03_outline.gdshader", "name": "描边 / 轮廓", "note": "按 alpha 找边界，内外描边 + 辉光"},
	{"file": "04_chromatic_aberration.gdshader", "name": "色差 / RGB 分离", "note": "径向或均匀的 R/B 通道错位"},
	{"file": "05_wave_distortion.gdshader", "name": "波动扭曲 / 水波", "note": "正弦推 UV，水平/垂直/径向/横竖"},
	{"file": "06_posterize.gdshader", "name": "色阶分离 / 调色", "note": "亮度对比 gamma 饱和 + 色阶量化 + 抖动"},
	{"file": "07_film_grain.gdshader", "name": "胶片颗粒 / 噪点", "note": "颗粒、彩噪、暗部限噪、暗角"},
	{"file": "08_hologram.gdshader", "name": "全息投影 / 扫描线", "note": "染色 + 扫描线 + 闪烁 + 垂直投影辉光"},
	{"file": "09_gaussian_blur.gdshader", "name": "高斯模糊", "note": "单 pass 13 抽样，可只横向/纵向"},
	{"file": "10_digital_glitch.gdshader", "name": "数字故障 / Glitch", "note": "方块撕裂 + 行跳变 + RGB 偏移"},
]


## 返回 [{path, file, name, note}]，顺序即界面里的顺序。
static func list_effects() -> Array:
	var out: Array = []
	var present := scan_files()
	var used := {}

	for e in ENTRIES:
		var f := String(e["file"])
		if not present.has(f):
			continue
		out.append({
			"path": "%s/%s" % [SHADER_DIR, f],
			"file": f,
			"name": String(e["name"]),
			"note": String(e["note"]),
		})
		used[f] = true

	# 未登记的自定义 shader
	var rest: Array = []
	for f in present:
		if not used.has(f):
			rest.append(f)
	rest.sort()
	for f in rest:
		out.append({
			"path": "%s/%s" % [SHADER_DIR, f],
			"file": f,
			"name": String(f).get_basename(),
			"note": "自定义 shader（未登记在 ENTRIES 里）",
		})

	return out


## `shaders/` 目录下的全部 .gdshader 文件名。
static func scan_files() -> Array:
	var files: Array = []
	var d := DirAccess.open(SHADER_DIR)
	if d == null:
		push_warning("shader_preview_test: 打不开 %s" % SHADER_DIR)
		return files
	for f in d.get_files():
		if String(f).ends_with(".gdshader"):
			files.append(String(f))
	return files


## 保留 uniform：预览器自动绑定，不作为可调参数出现在面板里。
static func reserved_uniforms() -> Array:
	return ["src_tex", "texel_size", "time"]
