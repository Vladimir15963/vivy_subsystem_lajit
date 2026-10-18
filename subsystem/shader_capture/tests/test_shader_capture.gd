extends Node

## godotshaders.com 抓取器 —— 无头测试。
##
## 运行方式：
##   godot --headless --path "L:\项目\测试" shader_capture/tests/shader_capture_test.tscn
##
## 覆盖：夹具页解析（名字/作者/日期/类型/许可/版本/标签/介绍/代码）、实体解码、
##       shader_type 取值优先级、URL 规范化与去重、文件名安全化、
##       .gdshader 头部拼装且正文原样、index.json 清单、落盘与覆盖开关、
##       解析失败路径、界面节点构建。
##
## 全程离线：解析用 samples/ 里的夹具，落盘写到 tests/_tmp/ 并在结束时清干净。
## 约定：代码行数、标签个数这类数字都从解析结果动态读取，不写死，避免误报。

const CaptureScene := preload("res://subsystem/shader_capture/shader_capture.tscn")
const Parser := preload("res://subsystem/shader_capture/scripts/shader_page_parser.gd")

const FIXTURE := "res://subsystem/shader_capture/samples/squigglevision.html"
const FIXTURE_URL := "https://godotshaders.com/shader/squigglevision/"
const TMP_DIR := "res://subsystem/shader_capture/tests/_tmp"
const PLAN := 15

var _passed := 0
var _failed := 0
var _ran := 0
## 故意不写静态类型：抓取器是动态加载的场景，静态类型下 add_entry()/write_results()
## 这些自定义方法会被当成 Control 上没有的成员。
var _capture


func _ready() -> void:
	print("=== shader_capture · 无头测试 ===")

	_purge(TMP_DIR)

	_capture = CaptureScene.instantiate()
	add_child(_capture)

	_test_ui_built()
	_test_fixture_parsed()
	_test_code_pristine()
	_test_header_fields()
	_test_shader_type_priority()
	_test_url_helpers()
	_test_split_urls()
	_test_entities()
	_test_description_scope()
	_test_sanitize_filename()
	_test_index_json()
	_test_write_and_manifest()
	_test_overwrite_switch()
	_test_error_paths()

	# 先清干净，再让哨兵确认「清理」这件事真的做到了
	_purge(TMP_DIR)
	_test_sentinel()

	print("\n=== 结果：%d 通过 / %d 失败（用例组 %d/%d）===" % [_passed, _failed, _ran, PLAN])
	get_tree().quit(0 if _failed == 0 else 1)


# ──────────────────────────────────────────────────────────────── 用例

## 1) 代码建 UI：关键节点与访问器都在。
func _test_ui_built() -> void:
	_ran += 1
	_check("根布局 Margin/Layout 存在", _capture.get_node_or_null("Margin/Layout") is VBoxContainer)
	_check("链接输入框存在", _capture.url_edit() is TextEdit)
	_check("输出目录输入框存在", _capture.dir_edit() is LineEdit)
	_check("开始按钮存在", _capture.start_button() is Button)
	_check("停止按钮存在", _capture.stop_button() is Button)
	_check("进度条存在", _capture.progress_bar() is ProgressBar)
	_check("日志视图存在", _capture.log_view() is RichTextLabel)
	_check("默认输出目录正确", _capture.output_dir() == "res://subsystem/shader_capture/captured",
		_capture.output_dir())
	_check("初始不在运行中", not _capture.is_running())


## 2) 夹具页解析：核心字段全部取到。
func _test_fixture_parsed() -> void:
	_ran += 1
	var meta := _parse_fixture()
	_check("解析成功", bool(meta["ok"]), str(meta["error"]))
	_check("名字", str(meta["name"]) == "Squigglevision", str(meta["name"]))
	_check("slug", str(meta["slug"]) == "squigglevision", str(meta["slug"]))
	_check("作者", str(meta["author"]) == "tentabrobpy", str(meta["author"]))
	_check("作者链接", str(meta["author_url"]).ends_with("/author/tentabrobpy/"), str(meta["author_url"]))
	_check("日期取 datetime", str(meta["date"]) == "2025-10-16", str(meta["date"]))
	_check("shader 类型", str(meta["shader_type"]) == "canvas_item", str(meta["shader_type"]))
	_check("许可", str(meta["license"]) == "cc0", str(meta["license"]))

	var versions: PackedStringArray = meta["godot_versions"]
	_check("Godot 版本 7 个（4.0–4.6）", versions.size() == 7, "实际 %d：%s" % [versions.size(), ", ".join(versions)])

	var tags: Array = meta["tags"]
	var labels := Parser.tag_labels(meta)
	_check("标签 10 个", tags.size() == 10, "实际 %d" % tags.size())
	_check("标签显示名含 hand drawn", labels.has("hand drawn"), ", ".join(labels))
	_check("标签 slug 形态正确", str(tags[0].get("slug", "")) == "cartoon", str(tags[0]))
	_check("代码非空", not str(meta["code"]).is_empty())


## 3) 正文原样：头部之后就是解析到的代码，一行没改。
func _test_code_pristine() -> void:
	_ran += 1
	var meta := _parse_fixture()
	var text := Parser.build_gdshader(meta)
	var code := str(meta["code"])

	var sep := text.find("\n\n")
	_check("头部与代码之间有分隔空行", sep != -1)
	var body := text.substr(sep + 2).strip_edges() if sep != -1 else ""
	_check("头部之后 == 原样代码", body == code)
	_check("代码以 shader_type 开头", code.begins_with("shader_type canvas_item;"))
	_check("代码含 render_mode", code.contains("render_mode world_vertex_coords;"))
	_check("代码里的 &#039; 已解码成单引号", code.contains("texture's size"),
		"实际含 &#039; = %s" % code.contains("&#039;"))
	_check("代码里的宏定义保留", code.contains("#define offset_multiplier vec2(PI, E)"))
	_check("整份文件里 shader_type 声明只出现一次", text.count("shader_type canvas_item;") == 1)


## 4) 头部注释：来源/作者/类型/许可/版本/标签/介绍都在。
func _test_header_fields() -> void:
	_ran += 1
	var meta := _parse_fixture()
	var text := Parser.build_gdshader(meta)
	_check("标题行", text.contains("// Squigglevision"))
	_check("来源行", text.contains("// 来源   " + FIXTURE_URL))
	_check("作者行", text.contains("// 作者   tentabrobpy"))
	_check("作者链接同行", text.contains("// 作者   tentabrobpy  https://godotshaders.com/author/tentabrobpy/"))
	_check("日期行", text.contains("// 发布   2025-10-16"))
	_check("类型行", text.contains("// 类型   canvas_item"))
	_check("许可行", text.contains("// 许可   cc0"))
	_check("版本行", text.contains("// Godot  4.0 / 4.1 / 4.2 / 4.3 / 4.4 / 4.5 / 4.6"))
	_check("标签行", text.contains("// 标签   cartoon, distortion"))
	_check("介绍标题", text.contains("// 介绍"))
	_check("介绍正文", text.contains("// Per-object Squigglevision"))
	_check("来源署名", text.contains("由 shader_capture 抓取自 godotshaders.com"))
	_check("文件以换行结尾", text.ends_with("\n"))


## 5) shader_type 以代码为准，article class 只是兜底。
func _test_shader_type_priority() -> void:
	_ran += 1
	var html := '<article class="entry shader_type-spatial"><h1 class="entry-title">Fake</h1>' \
		+ '<div class="entry-content single-content"><p>desc</p><h5>Shader code</h5>' \
		+ '<pre class="line-numbers code-block"><code class="language-glsl">shader_type canvas_item;\n' \
		+ 'void fragment() {}\n</code></pre></div><!-- .entry-content --></article>'
	var meta := Parser.parse(html, "https://godotshaders.com/shader/fake/")
	_check("代码里的 canvas_item 胜出", str(meta["shader_type"]) == "canvas_item", str(meta["shader_type"]))

	# 代码里没有声明时，退回 article class
	var html2 := '<article class="entry shader_type-sky"><h1 class="entry-title">Fake2</h1>' \
		+ '<div class="entry-content single-content"><h5>Shader code</h5>' \
		+ '<pre class="line-numbers code-block"><code>void fragment() {}\n</code></pre></div></article>'
	var meta2 := Parser.parse(html2, "https://godotshaders.com/shader/fake2/")
	_check("无声明时退回 class", str(meta2["shader_type"]) == "sky", str(meta2["shader_type"]))
	_check("无 shader_type 会给警告", not str(meta2.get("warning", "")).is_empty())


## 6) URL 规范化 / slug 提取。
func _test_url_helpers() -> void:
	_ran += 1
	_check("标准链接原样", Parser.normalize_url(FIXTURE_URL) == FIXTURE_URL)
	_check("裸域名补 https + 尾斜杠",
		Parser.normalize_url("godotshaders.com/shader/squigglevision") == FIXTURE_URL)
	_check("http + www + query 归一化",
		Parser.normalize_url("http://www.godotshaders.com/shader/foo/?x=1") == "https://godotshaders.com/shader/foo/")
	_check("标签页不算详情页", Parser.normalize_url("https://godotshaders.com/shader-tag/toon") == "")
	_check("列表页不算详情页", Parser.normalize_url("https://godotshaders.com/shader/?shader_type=sky") == "")
	_check("别的站点拒绝", Parser.normalize_url("https://example.com/shader/x/") == "")
	_check("snippet 拒绝", Parser.normalize_url("https://godotshaders.com/snippet/2d-noise/") == "")
	_check("注释行拒绝", Parser.normalize_url("# 这是注释") == "")

	_check("slug 带尾斜杠", Parser.slug_from_url(FIXTURE_URL) == "squigglevision")
	_check("slug 不带尾斜杠", Parser.slug_from_url("https://godotshaders.com/shader/squigglevision") == "squigglevision")
	_check("slug 忽略 query/fragment",
		Parser.slug_from_url("https://godotshaders.com/shader/squigglevision/?a=1#b") == "squigglevision")


## 7) 多行文本拆解：去重 + 报告无效行。
func _test_split_urls() -> void:
	_ran += 1
	var text := "# 注释\n\n" \
		+ "https://godotshaders.com/shader/a/\n" \
		+ "https://godotshaders.com/shader/a\n" \
		+ "godotshaders.com/shader/b/\n" \
		+ "https://example.com/nope\n"
	var split := Parser.split_urls(text)
	var valid: PackedStringArray = split["valid"]
	var invalid: PackedStringArray = split["invalid"]
	_check("有效链接 2 个（去重后）", valid.size() == 2, ", ".join(valid))
	_check("顺序保持 a、b", valid.size() == 2 and valid[0].ends_with("/shader/a/") and valid[1].ends_with("/shader/b/"))
	_check("无效行 1 条", invalid.size() == 1, ", ".join(invalid))
	_check("空文本得到空结果", Parser.split_urls("").size() == 2 and Parser.split_urls("")["valid"].size() == 0)


## 8) HTML 实体解码，含数字实体与 &amp; 的最后解码。
func _test_entities() -> void:
	_ran += 1
	var source := "&amp;|&lt;|&gt;|&#039;|&#65;|&#x42;|&nbsp;|&quot;"
	_check("实体解码", Parser.decode_entities(source) == "&|<|>|'|A|B| |\"",
		Parser.decode_entities(source))
	_check("&amp;lt; 只解一层", Parser.decode_entities("&amp;lt;") == "&lt;",
		Parser.decode_entities("&amp;lt;"))
	_check("去标签时 <br> 变行", Parser.strip_tags("a<br>b<br/>c") == "a\nb\nc",
		Parser.strip_tags("a<br>b<br/>c").replace("\n", "\\n"))
	_check("clean_text 折叠空白", Parser.clean_text("<p>a   b</p>\n\n\n<p>c</p>") == "a b\n\nc",
		Parser.clean_text("<p>a   b</p>\n\n\n<p>c</p>").replace("\n", "\\n"))


## 9) 介绍只取代码块之前的 <p>，不会把 Tags / Live Preview 混进来。
func _test_description_scope() -> void:
	_ran += 1
	var meta := _parse_fixture()
	var desc := str(meta["description"])
	_check("两段介绍", desc.split("\n\n").size() == 2, desc.replace("\n", "\\n"))
	_check("第一段正确", desc.begins_with("Per-object Squigglevision"))
	_check("第二段正确", desc.contains("Noise should be a seamless grayscale texture."))
	_check("不含 Live Preview", not desc.contains("Live Preview"))
	_check("不含 Tags", not desc.contains("Tags"))
	_check("不含标签名 cartoon", not desc.contains("cartoon"))
	_check("链接文字保留（去标签不去文字）", desc.contains("Squigglevision"))


## 10) 文件名安全化。
func _test_sanitize_filename() -> void:
	_ran += 1
	_check("普通名小写", Parser.sanitize_filename("Squigglevision") == "squigglevision")
	_check("空格变下划线", Parser.sanitize_filename("Hello World!") == "hello_world")
	_check("连字符保留", Parser.sanitize_filename("  a--b  ") == "a--b")
	_check("路径分隔符变下划线", Parser.sanitize_filename("a/b\\c") == "a_b_c")
	_check("纯中文名清空（由调用方兜底）", Parser.sanitize_filename("中文名") == "",
		Parser.sanitize_filename("中文名"))
	_check("连续符号折叠", Parser.sanitize_filename("a...b") == "a_b", Parser.sanitize_filename("a...b"))


## 11) index.json 清单：合法 JSON、字段齐全、给定时间戳时输出确定。
func _test_index_json() -> void:
	_ran += 1
	var meta := _parse_fixture()
	meta["file"] = "squigglevision.gdshader"
	var entries := [meta]
	var stamp := "2026-01-01T00:00:00"
	var text_a := Parser.build_index(entries, stamp)
	var text_b := Parser.build_index(entries, stamp)
	_check("同一输入输出一致", text_a == text_b)

	var parsed = JSON.parse_string(text_a)
	_check("是合法 JSON 对象", parsed is Dictionary)
	if parsed is Dictionary:
		var root: Dictionary = parsed
		_check("count 正确", int(root.get("count", -1)) == 1, str(root.get("count")))
		_check("时间戳写入", str(root.get("generated_at", "")) == stamp)
		_check("source 正确", str(root.get("source", "")) == "https://godotshaders.com")
		var items: Array = root.get("shaders", [])
		_check("shaders 数组 1 项", items.size() == 1)
		if items.size() == 1:
			var item: Dictionary = items[0]
			_check("清单含 file/url/type", str(item.get("file", "")) == "squigglevision.gdshader"
				and str(item.get("url", "")) == FIXTURE_URL
				and str(item.get("shader_type", "")) == "canvas_item")
			_check("清单含标签与介绍", (item.get("tags", []) as Array).size() == 10
				and not str(item.get("description", "")).is_empty())
			_check("清单记录代码行数", int(item.get("code_lines", 0)) > 10, str(item.get("code_lines")))
			_check("清单不含代码正文", not item.has("code"))


## 12) 落盘：写 .gdshader + index.json，重名自动编号。
func _test_write_and_manifest() -> void:
	_ran += 1
	_capture.clear_entries()
	var meta := _parse_fixture()

	var first: Dictionary = _capture.add_entry(meta)
	var second: Dictionary = _capture.add_entry(meta)
	_check("首个文件名", str(first["file"]) == "squigglevision.gdshader", str(first["file"]))
	_check("重名自动编号", str(second["file"]) == "squigglevision_2.gdshader", str(second["file"]))

	var summary: Dictionary = _capture.write_results(TMP_DIR)
	_check("落盘成功", bool(summary["ok"]), str(summary.get("error", "")))
	_check("写入 2 个", int(summary["written"]) == 2, str(summary["written"]))

	var path_a := "%s/squigglevision.gdshader" % TMP_DIR
	var path_b := "%s/squigglevision_2.gdshader" % TMP_DIR
	_check("文件 A 存在", FileAccess.file_exists(path_a))
	_check("文件 B 存在", FileAccess.file_exists(path_b))
	if FileAccess.file_exists(path_a):
		_check("文件内容 == entry.text", FileAccess.get_file_as_string(path_a) == str(first["text"]))

	# 「godot 可用」的硬校验：写出来的文件得能被引擎真的编译出 uniform
	var shader: Shader = load(path_a)
	_check("生成的 .gdshader 能被 Godot 载入", shader != null)
	if shader != null:
		var uniforms := shader.get_shader_uniform_list()
		_check("生成的 .gdshader 能编译出 uniform", uniforms.size() >= 4,
			"实际 %d 个" % uniforms.size())

	var index_path := str(summary["index_path"])
	_check("清单路径在输出目录", index_path == "%s/index.json" % TMP_DIR, index_path)
	_check("清单文件存在", FileAccess.file_exists(index_path))
	if FileAccess.file_exists(index_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(index_path))
		_check("清单可解析且 count=2", parsed is Dictionary and int(parsed.get("count", -1)) == 2)


## 13) 覆盖开关：关着跳过、开着重写。
func _test_overwrite_switch() -> void:
	_ran += 1
	_capture.set_overwrite_enabled(false)
	var skipped: Dictionary = _capture.write_results(TMP_DIR)
	_check("不覆盖时写入 0", int(skipped["written"]) == 0, str(skipped["written"]))
	_check("不覆盖时跳过 2", (skipped["skipped"] as PackedStringArray).size() == 2,
		", ".join(skipped["skipped"]))

	_capture.set_overwrite_enabled(true)
	var again: Dictionary = _capture.write_results(TMP_DIR)
	_check("覆盖时写入 2", int(again["written"]) == 2, str(again["written"]))
	_check("覆盖时跳过 0", (again["skipped"] as PackedStringArray).size() == 0)
	_capture.set_overwrite_enabled(false)


## 14) 失败路径：空页面 / 没有代码块。
func _test_error_paths() -> void:
	_ran += 1
	var empty := Parser.parse("", FIXTURE_URL)
	_check("空内容失败", not bool(empty["ok"]) and str(empty["error"]) == "页面内容为空",
		str(empty["error"]))

	var no_code := Parser.parse('<html><body><h1 class="entry-title">X</h1></body></html>', FIXTURE_URL)
	_check("无代码块失败", not bool(no_code["ok"]) and str(no_code["error"]).contains("代码块"),
		str(no_code["error"]))
	_check("失败时仍给出名字", str(no_code["name"]) == "X", str(no_code["name"]))
	_check("失败时 slug 仍在", str(no_code["slug"]) == "squigglevision", str(no_code["slug"]))

	var non_shader := Parser.parse(
		'<article class="entry"><h1 class="entry-title">Y</h1><div class="entry-content single-content">'
		+ '<h5>Shader code</h5><pre class="line-numbers code-block"><code>void main() {}</code></pre></div></article>',
		"https://godotshaders.com/shader/y/")
	_check("缺 shader_type 只警告不失败", bool(non_shader["ok"]) and not str(non_shader["warning"]).is_empty())


## 15) 哨兵：确认用例跑全了。
func _test_sentinel() -> void:
	_ran += 1
	_check("用例组数 == PLAN", _ran == PLAN, "%d / %d" % [_ran, PLAN])
	_check("夹具文件可读", not FileAccess.get_file_as_string(FIXTURE).is_empty())
	_check("临时目录已清理", not DirAccess.dir_exists_absolute(TMP_DIR))


# ──────────────────────────────────────────────────────────────── 小工具

func _parse_fixture() -> Dictionary:
	var html := FileAccess.get_file_as_string(FIXTURE)
	if html.is_empty():
		push_error("读不到夹具：%s" % FIXTURE)
	return Parser.parse(html, FIXTURE_URL)


func _purge(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	var handle := DirAccess.open(dir)
	if handle != null:
		for name in handle.get_files():
			DirAccess.remove_absolute("%s/%s" % [dir, name])
	handle = null
	DirAccess.remove_absolute(dir)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  [PASS] ", label, "" if detail.is_empty() else "  (%s)" % detail)
	else:
		_failed += 1
		print("  [FAIL] ", label, "" if detail.is_empty() else "  (%s)" % detail)