extends Node
## Gist 客户端（Godot 4）
##
## 参考 F:\项目\测试\control.gd 的实现，在其基础上补齐：
##   - 可配置的代理（control.gd 里把 127.0.0.1:7890 写死了）
##   - POST / GET 两种方法（control.gd 的注释里示范了 POST，正文用的是 GET）
##   - 连接状态 / 网络状态 / 请求状态 三种状态查询
##   - 成功 / 失败 / 超时 / 异常响应 的分类与信号
##
## ── 用法 ──────────────────────────────────────────────────────────
##     const GistClient := preload("res://subsystem/gist/gist_client.gd")
##
##     var client = GistClient.new()
##     add_child(client)                       # 必须先加入场景树
##     client.proxy_host = "127.0.0.1"         # 需要走代理时再设
##     client.proxy_port = 7890
##     client.request_completed.connect(func(r): print(r["content"]))
##     client.request_gist("", HTTPClient.METHOD_POST)
##
## ── 结果 ──────────────────────────────────────────────────────────
## `result` 是个 Dictionary，键的含义：
##     code             HTTP 状态码，0 表示没拿到响应
##     success          是否成功（2xx 且传输层成功）
##     message          服务端提示或错误摘要
##     content          Gist 的文本内容（raw 原文，或从 JSON 里抽出来的）
##     files            JSON 形状 Gist 的文件字典，非 JSON 时为空
##     is_json          响应体是否被解析成了 JSON
##     method           本次请求用的方法（"GET" / "POST" …）
##     url              实际请求的地址
##     headers          响应头
##     raw              原始响应体
##     error            网络层错误说明，为空表示拿到了 HTTP 响应
##     transport_result HTTPRequest 的传输层结果码
##     timed_out        是否被判为超时
##
## 本目录不用 class_name：那玩意儿要编辑器刷新 .godot 缓存才生效，
## 用 preload 才能保证命令行 headless 也能直接跑。

signal request_succeeded(result: Dictionary)
signal request_failed(result: Dictionary)
signal request_timed_out(result: Dictionary)
signal request_completed(result: Dictionary)   ## 总是最后触发

## control.gd 里用的 Gist 地址（raw 地址会返回最新版本的第一个文件）
const DEFAULT_ENDPOINT := "https://gist.githubusercontent.com/Vladimir15963/523d15bc1d8cbc520f854967f7cfced2/raw"
## control.gd 注释里那个带 revision 的固定地址
const DEFAULT_RAW_FILE := "https://gist.githubusercontent.com/Vladimir15963/523d15bc1d8cbc520f854967f7cfced2/raw/b40b8a99d9b5f5c37ba7fac7ea8a64269652c00e/gistfile1.txt"

enum RequestStatus { IDLE, PENDING, DONE }
enum ConnectionStatus { DISCONNECTED, CONNECTING, CONNECTED, FAILED }

const NETWORK_ERRORS := {
	HTTPRequest.RESULT_CANT_CONNECT: "无法连接到服务器",
	HTTPRequest.RESULT_CANT_RESOLVE: "无法解析主机名（检查网络或 DNS）",
	HTTPRequest.RESULT_CONNECTION_ERROR: "连接被中断",
	HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "TLS 握手失败",
	HTTPRequest.RESULT_NO_RESPONSE: "服务器没有返回响应",
	HTTPRequest.RESULT_TIMEOUT: "请求超时",
}

@export var endpoint: String = DEFAULT_ENDPOINT
## 默认走 POST：gist.githubusercontent 的 raw 地址只支持 GET，
## 用 POST 会拿到 405，正好当作「异常响应」处理（和用户要求一致）。
@export var method: HTTPClient.Method = HTTPClient.METHOD_POST
@export var proxy_host: String = ""
@export_range(0, 65535) var proxy_port: int = 0
@export var timeout: float = 20.0
@export_range(0, 20) var max_redirects: int = 8
@export var custom_headers: PackedStringArray = PackedStringArray()
@export var debug_log: bool = false

var _http: HTTPRequest
var _busy := false
var _url := ""
var _method_name := "GET"
var _request_status: RequestStatus = RequestStatus.IDLE
var _connection_status: ConnectionStatus = ConnectionStatus.DISCONNECTED
var _last_transport := HTTPRequest.RESULT_SUCCESS
var _last_result: Dictionary = {}


# ─────────────────────────────────────────────────────────────────────────────
#  请求
# ─────────────────────────────────────────────────────────────────────────────

## 发起一次 Gist 请求。body 只在 POST/PUT 时使用。
## 传 method_override 可以临时改方法（比如面板上用下拉框切 GET / POST）。
## 返回 OK 表示请求已发出，结果看 request_* 信号。
func request_gist(body: String = "", method_override: int = -1, url_override: String = "") -> Error:
	if _busy:
		push_warning("[Gist] 上一个请求还没结束")
		return ERR_BUSY
	if not is_inside_tree():
		return _abort("GistClient 需要先加入场景树。")

	var use_method: int = method_override if method_override >= 0 else method
	_url = url_override.strip_edges() if not url_override.strip_edges().is_empty() else endpoint.strip_edges()
	if _url.is_empty():
		return _abort("endpoint 为空，没有可请求的地址。")
	_method_name = _http_method_name(use_method)

	var http := _get_http()
	http.max_redirects = max_redirects
	http.timeout = timeout
	if proxy_host.strip_edges().is_empty():
		http.set_http_proxy("", 0)
	else:
		http.set_http_proxy(proxy_host.strip_edges(), proxy_port)

	_busy = true
	_request_status = RequestStatus.PENDING
	_connection_status = ConnectionStatus.CONNECTING
	if debug_log:
		print("[Gist] %s %s\n  %s" % [_method_name, _url, body])

	var headers := PackedStringArray(["Accept: application/json, text/plain, */*"])
	headers.append_array(custom_headers)

	var err := http.request(_url, headers, use_method, body)
	if err != OK:
		_busy = false
		_request_status = RequestStatus.IDLE
		_connection_status = ConnectionStatus.DISCONNECTED
		_abort("无法发起 HTTP 请求（Error %d）" % err)
	return err


func is_busy() -> bool:
	return _busy


## 面板上用：把 HTTPClient.METHOD_* 转成可读名字
static func _http_method_name(m: int) -> String:
	match m:
		HTTPClient.METHOD_GET: return "GET"
		HTTPClient.METHOD_POST: return "POST"
		HTTPClient.METHOD_PUT: return "PUT"
		HTTPClient.METHOD_DELETE: return "DELETE"
		HTTPClient.METHOD_HEAD: return "HEAD"
		HTTPClient.METHOD_PATCH: return "PATCH"
	return "METHOD_%d" % m


# ─────────────────────────────────────────────────────────────────────────────
#  状态查询
# ─────────────────────────────────────────────────────────────────────────────

## 请求状态：IDLE（空闲）/ PENDING（进行中）/ DONE（已完成）
func get_request_status() -> RequestStatus:
	return _request_status


func get_request_status_text() -> String:
	match _request_status:
		RequestStatus.PENDING: return "进行中"
		RequestStatus.DONE: return "已完成"
	return "空闲"


## 连接状态：是否成功连上过服务器
func get_connection_status() -> ConnectionStatus:
	return _connection_status


func get_connection_status_text() -> String:
	match _connection_status:
		ConnectionStatus.CONNECTING: return "连接中"
		ConnectionStatus.CONNECTED: return "已连接"
		ConnectionStatus.FAILED: return "连接失败"
	return "未连接"


## 网络状态：把传输层结果码翻译成人话
func get_network_status() -> String:
	if _request_status == RequestStatus.IDLE and _last_result.is_empty():
		return "未探测"
	if _last_transport == HTTPRequest.RESULT_SUCCESS:
		return "网络可用"
	if NETWORK_ERRORS.has(_last_transport):
		return NETWORK_ERRORS[_last_transport]
	return "网络异常（%d）" % _last_transport


## 最近一次请求的结果字典，未请求过时为空
func get_last_result() -> Dictionary:
	return _last_result


# ─────────────────────────────────────────────────────────────────────────────
#  解析
# ─────────────────────────────────────────────────────────────────────────────

## 把响应体解析成 Gist 内容。
## raw 地址直接返回文件原文；若拿到的是 JSON（GitHub API 形状），
## 则从 files 字段里抽出内容。
## 返回 {content: String, files: Dictionary, is_json: bool}。
static func parse_gist(body: PackedByteArray) -> Dictionary:
	var raw := body.get_string_from_utf8()
	var trimmed := raw.strip_edges()
	var files: Dictionary = {}
	var content := raw
	var is_json := false

	# 只在看着像 JSON 时才解析，避免 HTML 错误页刷引擎报错
	if trimmed.begins_with("{") or trimmed.begins_with("["):
		var parsed = JSON.parse_string(trimmed)
		if parsed != null:
			is_json = true
			if parsed is Dictionary:
				var raw_files = parsed.get("files", null)
				if raw_files is Dictionary:
					files = raw_files
					content = _first_file_content(files)
				else:
					content = JSON.stringify(parsed, "  ")

	return {"content": content, "files": files, "is_json": is_json}


## 从 GitHub API 形状的 files 字典里取第一个文件的内容
static func _first_file_content(files: Dictionary) -> String:
	for key in files:
		var entry = files[key]
		if entry is Dictionary and entry.has("content"):
			return str(entry["content"])
	return ""


## 解析一次 HTTP 响应，产出统一的 result 字典。
static func parse_response(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> Dictionary:
	var gist := parse_gist(body)
	var raw := body.get_string_from_utf8()

	var error := ""
	if result != HTTPRequest.RESULT_SUCCESS:
		error = NETWORK_ERRORS.get(result, "传输层错误（%d）" % result)
	elif code == 0:
		error = "没有收到 HTTP 响应"

	var ok_http := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	var message := ""
	if ok_http:
		message = "请求成功"
	elif not error.is_empty():
		message = error
	else:
		message = _http_error_message(code)

	return {
		"code": code,
		"success": ok_http,
		"message": message,
		"content": gist["content"],
		"files": gist["files"],
		"is_json": gist["is_json"],
		"headers": headers,
		"raw": raw,
		"error": error,
		"transport_result": result,
		"timed_out": result == HTTPRequest.RESULT_TIMEOUT,
	}


static func _http_error_message(code: int) -> String:
	match code:
		400: return "异常响应 400：请求格式错误"
		401: return "异常响应 401：未授权"
		403: return "异常响应 403：被拒绝"
		404: return "异常响应 404：地址不存在"
		405: return "异常响应 405：该方法不被允许（raw 地址只支持 GET）"
		429: return "异常响应 429：请求过于频繁"
	return "异常响应 %d" % code


## 把结果整理成一行，方便直接打印
static func describe(result: Dictionary) -> String:
	var code: int = result.get("code", 0)
	var label := "失败"
	if result.get("success", false):
		label = "成功"
	elif result.get("timed_out", false):
		label = "超时"
	elif not str(result.get("error", "")).is_empty():
		label = "网络错误"

	var text := ("[HTTP %d] %s" % [code, label]) if code > 0 else ("[无响应] %s" % label)
	var message := str(result.get("message", ""))
	if not message.is_empty():
		text += " · " + message
	var content := str(result.get("content", ""))
	if not content.is_empty():
		text += " · 内容 %d 字节" % content.length()
	return text


# ─────────────────────────────────────────────────────────────────────────────

func _get_http() -> HTTPRequest:
	if is_instance_valid(_http):
		return _http
	_http = HTTPRequest.new()
	_http.name = "GistHTTPRequest"
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	return _http


func _on_request_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	_request_status = RequestStatus.DONE
	_last_transport = result
	_connection_status = ConnectionStatus.CONNECTED if result == HTTPRequest.RESULT_SUCCESS else ConnectionStatus.FAILED

	var parsed := parse_response(result, code, headers, body)
	parsed["method"] = _method_name
	parsed["url"] = _url
	_last_result = parsed

	if debug_log:
		print("[Gist] HTTP %d\n  %s" % [code, body.get_string_from_utf8()])

	_emit(parsed)


func _abort(message: String) -> Error:
	push_error("[Gist] " + message)
	var result := {
		"code": 0, "success": false, "message": message, "content": "",
		"files": {}, "is_json": false, "headers": PackedStringArray(),
		"raw": "", "error": message, "transport_result": HTTPRequest.RESULT_REQUEST_FAILED,
		"timed_out": false, "method": _method_name, "url": _url,
	}
	_last_result = result
	_emit(result)
	return ERR_INVALID_PARAMETER


func _emit(result: Dictionary) -> void:
	if debug_log:
		print("[Gist] ", describe(result))
	if result.get("timed_out", false):
		request_timed_out.emit(result)
	elif result.get("success", false):
		request_succeeded.emit(result)
	else:
		request_failed.emit(result)
	request_completed.emit(result)
