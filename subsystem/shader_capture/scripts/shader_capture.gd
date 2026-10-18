extends Control

## godotshaders.com shader 抓取器 —— 主控制器。
##
## 交互跑：
##     godot --path "L:\项目\测试" shader_capture/shader_capture.tscn
##
## 干三件事：
##   1. 把「链接框」里的每一行规范成详情页 URL（只认 godotshaders.com/shader/<slug>/）；
##   2. 串行 GET（带间隔 + 重试一次），HTML 交给 shader_page_parser.gd 解析；
##   3. 每个 shader 写成一个独立 .gdshader（头部注释带名字/作者/链接/标签/介绍），
##      并在输出目录生成 index.json 清单。
##
## 无头测试只走「纯逻辑入口」：split_urls / add_entry / write_results，
## 不碰网络也不碰界面 —— 所以 UI 全部代码构建，测试里照样能实例化。
##
## 注意：输出目录默认在 res:// 下（开发期工具）。导出成发行版后 res:// 只读，
## 那时请把输出目录改成 user:// 或绝对路径。

const Parser := preload("res://subsystem/shader_capture/scripts/shader_page_parser.gd")

const DEFAULT_OUTPUT_DIR := "res://subsystem/shader_capture/captured"
const INDEX_FILE := "index.json"
const REQUEST_DELAY := 0.6
const RETRY_DELAY := 1.0
const MAX_ATTEMPTS := 2
const REQUEST_TIMEOUT := 30.0
const USER_AGENT := "Mozilla/5.0 (compatible; GodotShaderCapture/1.0)"

signal capture_started(total: int)
signal entry_captured(entry: Dictionary)
signal entry_failed(url: String, error: String)
signal capture_finished(summary: Dictionary)

var _entries: Array = []
var _failures: Array = []
var _running := false
var _cancel := false

var _url_edit: TextEdit
var _dir_edit: LineEdit
var _overwrite_check: CheckBox
var _start_button: Button
var _stop_button: Button
var _open_button: Button
var _progress: ProgressBar
var _status_label: Label
var _log_view: RichTextLabel
var _dir_dialog: FileDialog

var _http: HTTPRequest


# ──────────────────────────────────────────────────────────────── 生命周期

func _ready() -> void:
	_build_ui()
	_sync_buttons()
	_log("把 godotshaders.com 的 shader 详情页链接粘到上面（一行一个），再点「开始抓取」。")
	_log("例：https://godotshaders.com/shader/squigglevision/")


# ──────────────────────────────────────────────────────────────── 对外 API

func entries() -> Array:
	return _entries


func failures() -> Array:
	return _failures


func clear_entries() -> void:
	_entries.clear()
	_failures.clear()


func is_running() -> bool:
	return _running


func urls_text() -> String:
	return _url_edit.text if _url_edit != null else ""


func set_urls_text(text: String) -> void:
	if _url_edit != null:
		_url_edit.text = text


func output_dir() -> String:
	var text := _dir_edit.text.strip_edges() if _dir_edit != null else ""
	return text if not text.is_empty() else DEFAULT_OUTPUT_DIR


func set_output_dir(path: String) -> void:
	if _dir_edit != null:
		_dir_edit.text = path


func overwrite_enabled() -> bool:
	return _overwrite_check.button_pressed if _overwrite_check != null else false


func set_overwrite_enabled(value: bool) -> void:
	if _overwrite_check != null:
		_overwrite_check.button_pressed = value


# 界面节点访问器：无头测试用
func url_edit() -> TextEdit:
	return _url_edit


func dir_edit() -> LineEdit:
	return _dir_edit


func start_button() -> Button:
	return _start_button


func stop_button() -> Button:
	return _stop_button


func progress_bar() -> ProgressBar:
	return _progress


func log_view() -> RichTextLabel:
	return _log_view


func status_label() -> Label:
	return _status_label


## 把一条解析结果收进待写列表，分配不重名的文件名并预生成文件正文。
func add_entry(meta: Dictionary) -> Dictionary:
	var entry := meta.duplicate(true)
	var slug := str(entry.get("slug", "")).strip_edges()
	if slug.is_empty():
		slug = Parser.sanitize_filename(str(entry.get("name", "")))
	if slug.is_empty():
		slug = "shader"
	entry["slug"] = slug
	entry["file"] = _unique_filename(slug)
	entry["text"] = Parser.build_gdshader(entry)
	_entries.append(entry)
	return entry


## 把当前所有 entry 写成 .gdshader + index.json。返回统计信息。
func write_results(dir_path: String = "") -> Dictionary:
	var dir := dir_path.strip_edges() if not dir_path.strip_edges().is_empty() else output_dir()
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		return {"ok": false, "error": "无法创建目录 %s（Error %d）" % [dir, err],
			"dir": dir, "written": 0, "skipped": PackedStringArray(), "index_path": "", "total": _entries.size()}

	var base := dir.rstrip("/")
	var written := 0
	var skipped := PackedStringArray()
	var overwrite := overwrite_enabled()

	for entry in _entries:
		var path := "%s/%s" % [base, str(entry.get("file", ""))]
		if not overwrite and FileAccess.file_exists(path):
			skipped.append(path.get_file())
			continue
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			skipped.append("%s（写入失败 %d）" % [path.get_file(), FileAccess.get_open_error()])
			continue
		file.store_string(str(entry.get("text", "")))
		file.close()
		written += 1

	var index_path := "%s/%s" % [base, INDEX_FILE]
	var index_file := FileAccess.open(index_path, FileAccess.WRITE)
	var index_ok := index_file != null
	if index_ok:
		index_file.store_string(Parser.build_index(_entries, Time.get_datetime_string_from_system(true)))
		index_file.close()

	return {
		"ok": true, "error": "", "dir": dir, "written": written,
		"skipped": skipped, "index_path": index_path if index_ok else "", "total": _entries.size(),
	}


## 开始抓取（异步，结果看信号 + 日志）。
func start_capture() -> void:
	if _running:
		return
	var split := Parser.split_urls(urls_text())
	for bad in split["invalid"]:
		_log("跳过无效链接：%s" % bad, "orange")
	var urls: PackedStringArray = split["valid"]
	if urls.is_empty():
		_log("没有可抓取的链接。", "orange")
		return

	_running = true
	_cancel = false
	_entries.clear()
	_failures.clear()
	_sync_buttons()
	capture_started.emit(urls.size())
	_log("开始抓取 %d 个链接 → %s" % [urls.size(), output_dir()], "cyan")
	_run(urls)


func cancel_capture() -> void:
	if _running:
		_cancel = true


# ──────────────────────────────────────────────────────────────── 抓取流程

func _run(urls: PackedStringArray) -> void:
	for i in urls.size():
		if _cancel:
			_log("已取消，剩余 %d 个未抓。" % (urls.size() - i), "orange")
			break

		var url := urls[i]
		_set_progress(i, urls.size(), "抓取中 %s" % url)

		var html := ""
		var error := ""
		for attempt in MAX_ATTEMPTS:
			var response: Dictionary = await _fetch(url)
			if response["ok"]:
				html = str(response["html"])
				break
			error = str(response["error"])
			if attempt < MAX_ATTEMPTS - 1:
				await _sleep(RETRY_DELAY)

		if html.is_empty():
			_failures.append({"url": url, "error": error})
			_log("失败 %s · %s" % [url, error], "red")
			entry_failed.emit(url, error)
		else:
			var meta := Parser.parse(html, url)
			if not meta["ok"]:
				_failures.append({"url": url, "error": str(meta["error"])})
				_log("失败 %s · %s" % [url, meta["error"]], "red")
				entry_failed.emit(url, str(meta["error"]))
			else:
				var entry := add_entry(meta)
				_log("成功 %s → %s（%d 行代码）" % [meta["name"], entry["file"], str(meta["code"]).split("\n").size()], "green")
				if not str(meta.get("warning", "")).is_empty():
					_log("　注意：%s" % meta["warning"], "orange")
				entry_captured.emit(entry)

		_set_progress(i + 1, urls.size(), "")
		if i < urls.size() - 1 and not _cancel:
			await _sleep(REQUEST_DELAY)

	_finish()


func _finish() -> void:
	_running = false
	var summary := write_results()
	if summary["ok"]:
		_log("完成：写入 %d / %d 个 .gdshader · 清单 %s" % [summary["written"], summary["total"], summary["index_path"]], "cyan")
	else:
		_log("落盘失败：%s" % summary["error"], "red")
	if not summary["skipped"].is_empty():
		_log("跳过 %d 个：%s" % [summary["skipped"].size(), ", ".join(summary["skipped"])], "orange")
	_log("合计 成功 %d · 失败 %d" % [_entries.size(), _failures.size()], "cyan")
	_sync_buttons()
	capture_finished.emit(summary)


## 一次 GET，返回 {ok, html} 或 {ok:false, error}。
func _fetch(url: String) -> Dictionary:
	if _http == null:
		_http = HTTPRequest.new()
		_http.name = "CaptureHTTP"
		add_child(_http)
	_http.timeout = REQUEST_TIMEOUT

	var headers := PackedStringArray([
		"User-Agent: " + USER_AGENT,
		"Accept: text/html,application/xhtml+xml",
		"Accept-Language: en-US,en;q=0.8",
	])
	var err := _http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		return {"ok": false, "error": "无法发起请求（Error %d）" % err}

	var response: Array = await _http.request_completed
	var result: int = response[0]
	var code: int = response[1]
	var body: PackedByteArray = response[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": _transport_error(result)}
	if code != 200:
		return {"ok": false, "error": "HTTP %d" % code}
	return {"ok": true, "html": body.get_string_from_utf8()}


func _transport_error(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "无法连接"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "无法解析域名（检查网络/DNS）"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "连接被中断"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS 握手失败"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "服务器没有响应"
		HTTPRequest.RESULT_TIMEOUT:
			return "请求超时"
	return "传输层错误（%d）" % result


func _sleep(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _unique_filename(slug: String) -> String:
	var taken := {}
	for entry in _entries:
		taken[str(entry.get("file", ""))] = true
	var candidate := "%s.gdshader" % slug
	var n := 2
	while taken.has(candidate):
		candidate = "%s_%d.gdshader" % [slug, n]
		n += 1
	return candidate


# ──────────────────────────────────────────────────────────────── 界面

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)

	var layout := VBoxContainer.new()
	layout.name = "Layout"
	layout.add_theme_constant_override("separation", 8)
	margin.add_child(layout)

	var title := Label.new()
	title.name = "Title"
	title.text = "godotshaders.com 抓取器"
	layout.add_child(title)

	var hint := Label.new()
	hint.name = "Hint"
	hint.text = "每行一个 shader 详情页链接，例如 https://godotshaders.com/shader/squigglevision/"
	layout.add_child(hint)

	_url_edit = TextEdit.new()
	_url_edit.name = "UrlEdit"
	_url_edit.custom_minimum_size = Vector2(0, 150)
	_url_edit.placeholder_text = "https://godotshaders.com/shader/…\nhttps://godotshaders.com/shader/…"
	_url_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	layout.add_child(_url_edit)

	var dir_row := HBoxContainer.new()
	dir_row.name = "DirRow"
	layout.add_child(dir_row)

	var dir_label := Label.new()
	dir_label.text = "输出目录"
	dir_row.add_child(dir_label)

	_dir_edit = LineEdit.new()
	_dir_edit.name = "DirEdit"
	_dir_edit.text = DEFAULT_OUTPUT_DIR
	_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dir_row.add_child(_dir_edit)

	var pick_button := Button.new()
	pick_button.name = "PickButton"
	pick_button.text = "选择…"
	pick_button.pressed.connect(_on_pick_pressed)
	dir_row.add_child(pick_button)

	var action_row := HBoxContainer.new()
	action_row.name = "ActionRow"
	layout.add_child(action_row)

	_overwrite_check = CheckBox.new()
	_overwrite_check.name = "OverwriteCheck"
	_overwrite_check.text = "覆盖已存在"
	action_row.add_child(_overwrite_check)

	_start_button = Button.new()
	_start_button.name = "StartButton"
	_start_button.text = "开始抓取"
	_start_button.pressed.connect(start_capture)
	action_row.add_child(_start_button)

	_stop_button = Button.new()
	_stop_button.name = "StopButton"
	_stop_button.text = "停止"
	_stop_button.pressed.connect(cancel_capture)
	action_row.add_child(_stop_button)

	_open_button = Button.new()
	_open_button.name = "OpenButton"
	_open_button.text = "打开输出目录"
	_open_button.pressed.connect(_on_open_pressed)
	action_row.add_child(_open_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_row.add_child(spacer)

	_progress = ProgressBar.new()
	_progress.name = "Progress"
	_progress.max_value = 1
	_progress.value = 0
	layout.add_child(_progress)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.text = "就绪"
	layout.add_child(_status_label)

	_log_view = RichTextLabel.new()
	_log_view.name = "Log"
	_log_view.bbcode_enabled = true
	_log_view.scroll_following = true
	_log_view.selection_enabled = true
	_log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(_log_view)

	_dir_dialog = FileDialog.new()
	_dir_dialog.name = "DirDialog"
	_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = FileDialog.ACCESS_RESOURCES
	_dir_dialog.current_dir = DEFAULT_OUTPUT_DIR
	_dir_dialog.dir_selected.connect(_on_dir_selected)
	add_child(_dir_dialog)


func _sync_buttons() -> void:
	if _start_button != null:
		_start_button.disabled = _running
	if _stop_button != null:
		_stop_button.disabled = not _running
	if _url_edit != null:
		_url_edit.editable = not _running


func _set_progress(done: int, total: int, text: String) -> void:
	if _progress != null:
		_progress.max_value = maxi(total, 1)
		_progress.value = done
	if _status_label != null:
		_status_label.text = text if not text.is_empty() else "%d / %d" % [done, total]


func _log(message: String, color: String = "") -> void:
	if _log_view == null:
		return
	var line := message.replace("[", "[lb]")
	if color.is_empty():
		_log_view.append_text(line + "\n")
	else:
		_log_view.append_text("[color=%s]%s[/color]\n" % [color, line])


func _on_pick_pressed() -> void:
	if _dir_dialog != null:
		_dir_dialog.current_dir = output_dir()
		_dir_dialog.popup_centered_ratio(0.6)


func _on_dir_selected(path: String) -> void:
	set_output_dir(path)


func _on_open_pressed() -> void:
	var dir := output_dir()
	var global := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(global) or DirAccess.dir_exists_absolute(dir):
		OS.shell_open(global)
	else:
		_log("目录还不存在：%s" % dir, "orange")