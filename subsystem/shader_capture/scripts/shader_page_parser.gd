extends RefCounted

## godotshaders.com 详情页解析器。
##
## 纯函数：只吃 HTML 字符串，不碰网络、不碰文件，所以能脱离网络做无头测试。
##
## 页面上真正有用的信息都在这几处（2026-10 实测结构）：
##   <h1 class="entry-title">名字</h1>
##   <span class="author vcard"><a href="作者页">作者</a></span>
##   <time class="entry-date published" datetime="2025-10-16T20:26:21+00:00">
##   <div class="entry-content single-content"> … <p>介绍</p> … <h5>Shader code</h5>
##   <pre class="line-numbers code-block"><code class="language-glsl">代码</code></pre>
##   <h6>Tags</h6> <a href="…/shader-tag/cartoon">cartoon</a>, …
##   <article class="… shader_type-canvas_item … shader_license-cc0 … godot_version-godot_version_46 …">
##
## 用法：
##     const Parser := preload("res://subsystem/shader_capture/scripts/shader_page_parser.gd")
##     var meta := Parser.parse(html, url)
##     if meta["ok"]:
##         print(Parser.build_gdshader(meta))
##
## 本目录不用 class_name：那玩意儿要编辑器刷新 .godot 缓存才生效，
## 用 preload 才能保证命令行 headless 也能直接跑。

const SITE_HOST := "godotshaders.com"
const INDEX_SOURCE := "https://godotshaders.com"

# 正则懒编译缓存：pattern -> RegEx
static var _cache: Dictionary = {}


# ──────────────────────────────────────────────────────────────── 对外主入口

## 解析一个详情页。返回的 Dictionary 见 _blank_meta()；ok=false 时 error 有话说。
static func parse(html: String, url: String) -> Dictionary:
	var meta := _blank_meta(url)

	if html.strip_edges().is_empty():
		meta["error"] = "页面内容为空"
		return meta

	var code := extract_code(html)
	if code.is_empty():
		meta["error"] = "没找到 shader 代码块（<pre class=\"line-numbers code-block\">）"
		meta["name"] = extract_name(html)
		return meta

	var author := extract_author(html)
	var tags := extract_tags(html)
	var versions := extract_godot_versions(html)

	meta["name"] = extract_name(html)
	meta["code"] = code
	meta["author"] = str(author.get("name", ""))
	meta["author_url"] = str(author.get("url", ""))
	meta["date"] = extract_date(html)
	meta["shader_type"] = extract_shader_type(code, html)
	meta["license"] = extract_license(html)
	meta["godot_versions"] = versions
	meta["description"] = extract_description(html)
	meta["tags"] = tags
	meta["ok"] = true

	if not code.contains("shader_type"):
		meta["warning"] = "代码里没有 shader_type 声明，可能不是可直接使用的 .gdshader"
	return meta


## 把解析结果拼成一个完整的 .gdshader 文本：头部是 // 注释，正文是原样代码。
static func build_gdshader(meta: Dictionary) -> String:
	var name := str(meta.get("name", "")).strip_edges()
	if name.is_empty():
		name = str(meta.get("slug", "shader"))

	var lines := PackedStringArray()
	lines.append("// " + _rule())
	lines.append("// " + name)
	lines.append("// " + _rule())
	lines.append("// 来源   " + str(meta.get("url", "")))

	var author := str(meta.get("author", "")).strip_edges()
	if not author.is_empty():
		var author_url := str(meta.get("author_url", "")).strip_edges()
		lines.append("// 作者   " + (author + "  " + author_url if not author_url.is_empty() else author))

	var date := str(meta.get("date", "")).strip_edges()
	if not date.is_empty():
		lines.append("// 发布   " + date)

	var shader_type := str(meta.get("shader_type", "")).strip_edges()
	if not shader_type.is_empty():
		lines.append("// 类型   " + shader_type)

	var license := str(meta.get("license", "")).strip_edges()
	if not license.is_empty():
		lines.append("// 许可   " + license)

	var versions := _as_string_array(meta.get("godot_versions", []))
	if not versions.is_empty():
		lines.append("// Godot  " + " / ".join(versions))

	var tags := tag_labels(meta)
	if not tags.is_empty():
		lines.append("// 标签   " + ", ".join(tags))

	var description := str(meta.get("description", "")).strip_edges()
	if not description.is_empty():
		lines.append("// " + _rule())
		lines.append("// 介绍")
		for row in description.split("\n"):
			lines.append(("// " + row) if not row.is_empty() else "//")

	lines.append("// " + _rule())
	lines.append("// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。")
	lines.append("// " + _rule())
	lines.append("")
	lines.append(str(meta.get("code", "")).strip_edges())
	lines.append("")
	return "\n".join(lines)


## 生成 index.json 清单。generated_at 由调用方传入，方便测试做确定性比对。
static func build_index(entries: Array, generated_at: String = "") -> String:
	var items: Array = []
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var code := str(e.get("code", ""))
		items.append({
			"file": str(e.get("file", "")),
			"name": str(e.get("name", "")),
			"slug": str(e.get("slug", "")),
			"url": str(e.get("url", "")),
			"author": str(e.get("author", "")),
			"author_url": str(e.get("author_url", "")),
			"date": str(e.get("date", "")),
			"shader_type": str(e.get("shader_type", "")),
			"license": str(e.get("license", "")),
			"godot_versions": _as_string_array(e.get("godot_versions", [])),
			"tags": tag_labels(e),
			"code_lines": code.split("\n").size() if not code.is_empty() else 0,
			"description": str(e.get("description", "")),
		})

	var root := {
		"generated_at": generated_at,
		"source": INDEX_SOURCE,
		"count": items.size(),
		"shaders": items,
	}
	return JSON.stringify(root, "  ") + "\n"


# ──────────────────────────────────────────────────────────────── 单项提取

## 名字：优先 <h1 class="entry-title">，退回 <title>（去掉站名后缀）。
static func extract_name(html: String) -> String:
	var m := _search('(?s)<h1[^>]*class="[^"]*entry-title[^"]*"[^>]*>(.*?)</h1>', html)
	if m != null:
		return clean_text(m.get_string(1))
	m = _search("(?s)<title>(.*?)</title>", html)
	if m != null:
		var text := clean_text(m.get_string(1))
		for suffix in [" - Godot Shaders", " – Godot Shaders", " | Godot Shaders"]:
			text = text.replace(suffix, "")
		return text.strip_edges()
	return ""


## shader 代码：只认 code-block 那一个 <pre>，正文做实体解码 + 行尾去空白。
static func extract_code(html: String) -> String:
	var m := _search('(?s)<pre[^>]*class="[^"]*code-block[^"]*"[^>]*>\\s*<code[^>]*>(.*?)</code>', html)
	if m == null:
		m = _search("(?s)<pre[^>]*>\\s*<code[^>]*>(.*?)</code>", html)
	if m == null:
		return ""

	var code := decode_entities(m.get_string(1))
	code = code.replace("\r\n", "\n").replace("\r", "\n")
	# 源码里的空行常带缩进，逐行去掉行尾空白，行结构保持不变
	var rows := code.split("\n")
	for i in rows.size():
		rows[i] = rows[i].rstrip(" \t")
	return "\n".join(rows).strip_edges()


## 介绍：取正文里、<h5>Shader code</h5> 之前的全部 <p>。
static func extract_description(html: String) -> String:
	var start := html.find('<div class="entry-content single-content">')
	if start == -1:
		start = html.find('<div class="entry-content')
	if start == -1:
		return ""

	var end := html.find("<h5>Shader code</h5>", start)
	if end == -1:
		end = html.find('<pre class="line-numbers code-block">', start)
	if end == -1:
		end = html.find("<pre", start)
	if end == -1:
		end = html.length()

	var region := html.substr(start, end - start)
	var parts := PackedStringArray()
	for m in _all("(?s)<p[^>]*>(.*?)</p>", region):
		var text := clean_text(m.get_string(1))
		if not text.is_empty():
			parts.append(text)
	return "\n\n".join(parts)


## 作者：<span class="author vcard"> 里的链接。返回 {name, url}。
static func extract_author(html: String) -> Dictionary:
	var m := _search('(?s)<span class="author vcard">\\s*<a([^>]*)>(.*?)</a>', html)
	if m == null:
		m = _search('(?s)<a[^>]*class="[^"]*url fn n[^"]*"[^>]*>(.*?)</a>', html)
		if m == null:
			return {"name": "", "url": ""}
		return {"name": clean_text(m.get_string(1)), "url": ""}
	return {
		"name": clean_text(m.get_string(2)),
		"url": _attr(m.get_string(1), "href"),
	}


## 发布日期：优先 datetime 属性（ISO），退回可见文本。
static func extract_date(html: String) -> String:
	var tag := _search('(?s)<time[^>]*class="[^"]*entry-date[^"]*"[^>]*>', html)
	if tag == null:
		return ""
	var iso := _attr(tag.get_string(0), "datetime")
	if not iso.is_empty():
		return iso.substr(0, 10)
	var m := _search('(?s)<time[^>]*class="[^"]*entry-date[^"]*"[^>]*>(.*?)</time>', html)
	return clean_text(m.get_string(1)) if m != null else ""


## shader 类型：以代码里的 shader_type 为准，退回 <article> 上的 class。
static func extract_shader_type(code: String, html: String = "") -> String:
	var m := _search("(?m)^\\s*shader_type\\s+([a-z_]+)\\s*;", code)
	if m != null:
		return m.get_string(1)
	if not html.is_empty():
		var am := _search('(?s)<article[^>]*class="[^"]*shader_type-([a-z0-9_]+)[^"]*"', html)
		if am != null:
			return am.get_string(1)
	return ""


## 许可证：<article> class 上的 shader_license-xxx。
static func extract_license(html: String) -> String:
	var m := _search('(?s)<article[^>]*class="[^"]*shader_license-([a-z0-9_\\-]+)[^"]*"', html)
	return m.get_string(1) if m != null else ""


## 支持的 Godot 版本：<article> class 上的 godot_version-godot_version_46 → "4.6"。
static func extract_godot_versions(html: String) -> PackedStringArray:
	var out := PackedStringArray()
	var m := _search('(?s)<article[^>]*class="([^"]*)"', html)
	if m == null:
		return out
	for hit in _all("godot_version-godot_version_([0-9]+)", m.get_string(1)):
		out.append(_version_label(hit.get_string(1)))
	return out


## 标签：优先正文 <h6>Tags</h6> 里的链接（有显示名），退回 <article> class。
static func extract_tags(html: String) -> Array:
	var out: Array = []
	var start := html.find("<h6>Tags</h6>")
	if start != -1:
		var end := html.find("</div>", start)
		if end == -1:
			end = html.length()
		var region := html.substr(start, end - start)
		for m in _all('(?s)<a[^>]*href="[^"]*shader-tag/([^"/]+)"[^>]*>(.*?)</a>', region):
			var slug: String = m.get_string(1)
			var label := clean_text(m.get_string(2))
			out.append({"slug": slug, "label": label if not label.is_empty() else slug})

	if out.is_empty():
		var am := _search('(?s)<article[^>]*class="([^"]*)"', html)
		if am != null:
			for hit in _all("shader_tag-([a-z0-9\\-]+)", am.get_string(1)):
				out.append({"slug": hit.get_string(1), "label": hit.get_string(1)})
	return out


## 把 tags（Dictionary 或 String 混合）统一成显示名数组。
static func tag_labels(meta: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for tag in _as_array(meta.get("tags", [])):
		if tag is Dictionary:
			var label := str(tag.get("label", tag.get("slug", ""))).strip_edges()
			if not label.is_empty():
				out.append(label)
		elif tag is String:
			var text := str(tag).strip_edges()
			if not text.is_empty():
				out.append(text)
	return out


# ──────────────────────────────────────────────────────────────── URL / 文件名

## 把一行输入规范成详情页 URL；不合法（不是 godotshaders 的 /shader/<slug>/）返回 ""。
static func normalize_url(raw: String) -> String:
	var text := raw.strip_edges()
	if text.is_empty() or text.begins_with("#"):
		return ""
	if not (text.begins_with("http://") or text.begins_with("https://")):
		text = "https://" + text
	var m := _search('(?s)^https?://(?:www\\.)?godotshaders\\.com/shader/([^/?#]+)/?', text)
	if m == null:
		return ""
	return "https://%s/shader/%s/" % [SITE_HOST, m.get_string(1)]


## 拆多行文本：valid 是去重后的规范 URL，invalid 是原样保留的无效行。
static func split_urls(text: String) -> Dictionary:
	var valid := PackedStringArray()
	var invalid := PackedStringArray()
	var seen := {}
	for row in text.split("\n"):
		var line := row.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var url := normalize_url(line)
		if url.is_empty():
			invalid.append(line)
			continue
		if seen.has(url):
			continue
		seen[url] = true
		valid.append(url)
	return {"valid": valid, "invalid": invalid}


## 从详情页 URL 取 slug（文件名用）。
static func slug_from_url(url: String) -> String:
	var text := url.strip_edges()
	for cut in ["?", "#"]:
		var at := text.find(cut)
		if at != -1:
			text = text.substr(0, at)
	text = text.rstrip("/")
	var m := _search('(?s)/shader/([^/]+)$', text)
	if m != null:
		return sanitize_filename(m.get_string(1))
	return sanitize_filename(text.get_file())


## 文件名安全化：小写，非 [a-z0-9_-] 一律变 _，折叠连续 _。
static func sanitize_filename(name: String) -> String:
	var text := name.strip_edges().to_lower()
	text = _regex("[^a-z0-9_\\-]+").sub(text, "_", true)
	text = _regex("_+").sub(text, "_", true)
	return text.trim_prefix("_").trim_suffix("_")


# ──────────────────────────────────────────────────────────────── 文本清洗

## 去标签 + 解实体 + 折叠空白，用于一切「显示用文本」。
static func clean_text(source: String) -> String:
	var text := decode_entities(strip_tags(source))
	text = _regex("[ \\t\\r]+").sub(text, " ", true)
	text = _regex("\\n{3,}").sub(text, "\n\n", true)
	return text.strip_edges()


## 去掉所有标签；<br> 变行。
static func strip_tags(source: String) -> String:
	var text := source
	for br in ["<br>", "<br/>", "<br />", "<BR>"]:
		text = text.replace(br, "\n")
	return _regex("(?s)<[^>]*>").sub(text, "", true)


## HTML 实体解码。&amp; 放最后，避免 &amp;lt; 被二次解码成 <。
static func decode_entities(source: String) -> String:
	if source.find("&") == -1:
		return source
	var text := source
	for pair in [
		["&#039;", "'"], ["&#39;", "'"], ["&apos;", "'"],
		["&quot;", "\""], ["&#34;", "\""],
		["&lt;", "<"], ["&gt;", ">"],
		["&nbsp;", " "], ["&hellip;", "…"], ["&mdash;", "—"], ["&ndash;", "–"],
	]:
		text = text.replace(pair[0], pair[1])
	text = _decode_numeric(text)
	return text.replace("&amp;", "&")


# ──────────────────────────────────────────────────────────────── 内部小工具

static func _blank_meta(url: String) -> Dictionary:
	return {
		"ok": false,
		"error": "",
		"warning": "",
		"url": url,
		"slug": slug_from_url(url),
		"name": "",
		"author": "",
		"author_url": "",
		"date": "",
		"shader_type": "",
		"license": "",
		"godot_versions": PackedStringArray(),
		"description": "",
		"tags": [],
		"code": "",
	}


static func _rule(width: int = 64) -> String:
	return "=".repeat(width)


static func _version_label(digits: String) -> String:
	if digits.length() <= 1:
		return digits
	if digits.length() == 2:
		return "%s.%s" % [digits[0], digits[1]]
	return "%s.%s" % [digits[0], digits.substr(1)]


## 从属性串里取 name="value"。
static func _attr(attrs: String, name: String) -> String:
	var m := _search('(?s)(?:^|\\s)%s="([^"]*)"' % name, attrs)
	return m.get_string(1) if m != null else ""


static func _decode_numeric(source: String) -> String:
	var matches := _all("&#(x?)([0-9A-Fa-f]+);", source)
	if matches.is_empty():
		return source
	var out := ""
	var last := 0
	for m in matches:
		out += source.substr(last, m.get_start() - last)
		var is_hex: bool = m.get_string(1) == "x"
		var code: int = ("0x" + m.get_string(2)).hex_to_int() if is_hex else int(m.get_string(2))
		if code > 0 and code <= 0x10FFFF:
			out += String.chr(code)
		else:
			out += m.get_string(0)
		last = m.get_end()
	return out + source.substr(last)


static func _as_array(value: Variant) -> Array:
	if value is Array:
		return value
	if value is PackedStringArray:
		var out: Array = []
		for item in value:
			out.append(item)
		return out
	return []


static func _as_string_array(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	for item in _as_array(value):
		out.append(str(item))
	return out


static func _regex(pattern: String) -> RegEx:
	if _cache.has(pattern):
		return _cache[pattern]
	var re := RegEx.new()
	re.compile(pattern)
	_cache[pattern] = re
	return re


static func _search(pattern: String, text: String) -> RegExMatch:
	return _regex(pattern).search(text)


static func _all(pattern: String, text: String) -> Array:
	return _regex(pattern).search_all(text)