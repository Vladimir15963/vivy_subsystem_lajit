extends Node
## Web3Forms API 客户端（Godot 4）
## 文档：https://docs.web3forms.com/getting-started/api-reference
##
## 两个接口都实现了：
##   POST https://api.web3forms.com/submit            用 access_key
##   POST https://api.web3forms.com/submit/{FORM_ID}  用 Form ID（和 access_key 是同一个 UUID，放 URL 里就不用再传字段）
##
## ── 用法 ──────────────────────────────────────────────────────────
##     const Web3Forms := preload("res://web3forms_test/web3forms_client.gd")
##
##     var client = Web3Forms.new()
##     add_child(client)                       # 必须先加入场景树
##     client.access_key = "你的 Access Key"    # https://web3forms.com 免费领
##     client.subject = "来自 Godot 的测试"
##     client.submit_completed.connect(func(r): print(r))
##     client.submit({"name": "小明", "message": "你好"})
##
## ── 结果 ──────────────────────────────────────────────────────────
## 是一个 Dictionary，键的含义：
##     code           HTTP 状态码，0 表示没拿到响应
##     success        业务是否成功
##     message        服务端提示（400/429/500 的原因都在这里）
##     data           服务端回显的提交数据
##     redirect_url   303 时 Location 头里的跳转地址
##     raw            原始响应体
##     error          网络层错误说明，为空表示拿到了 HTTP 响应
##
## 本目录不用 class_name：那玩意儿要编辑器刷新 .godot 缓存才生效，
## 用 preload 才能保证命令行 headless 也能直接跑。

signal submit_succeeded(result: Dictionary)
signal submit_failed(result: Dictionary)
signal submit_redirected(result: Dictionary)
signal submit_completed(result: Dictionary)   ## 总是最后触发

const DEFAULT_ENDPOINT := "https://api.web3forms.com/submit"

const NETWORK_ERRORS := {
	HTTPRequest.RESULT_CANT_CONNECT: "无法连接到服务器",
	HTTPRequest.RESULT_CANT_RESOLVE: "无法解析主机名（检查网络或 DNS）",
	HTTPRequest.RESULT_CONNECTION_ERROR: "连接被中断",
	HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "TLS 握手失败",
	HTTPRequest.RESULT_NO_RESPONSE: "服务器没有返回响应",
	HTTPRequest.RESULT_TIMEOUT: "请求超时",
}

@export var endpoint: String = DEFAULT_ENDPOINT
## Access Key（必填，除非用 form_id）
@export var access_key: String = ""
## Form ID。填了就改用 POST /submit/{form_id}
@export var form_id: String = ""

# 文档「Request Body」里的保留字段
@export var email: String = ""       ## 会作为邮件的 Reply-To
@export var subject: String = ""
@export var ccemail: String = ""     ## PRO
@export var replyto: String = ""
@export var redirect: String = ""    ## 成功后跳转的 URL
@export var botcheck: bool = false   ## 蜜罐字段，正常提交保持 false
@export var webhook: String = ""     ## PRO

## 其余自定义字段，原样发到邮箱
@export var custom_fields: Dictionary = {}
## 0 = 不自动跟随 303，把跳转地址原样交给你
@export_range(0, 20) var max_redirects: int = 0
@export var timeout: float = 20.0
@export var debug_log: bool = false

var _http: HTTPRequest
var _busy := false
var _url := ""
var _fields: Dictionary = {}


## 提交表单。extra 会和 custom_fields 合并，保留字段优先级最高。
## 返回 OK 表示请求已发出，结果看 submit_* 信号。
func submit(extra: Dictionary = {}) -> Error:
	if _busy:
		push_warning("[Web3Forms] 上一个请求还没结束")
		return ERR_BUSY
	if form_id.strip_edges().is_empty() and access_key.strip_edges().is_empty():
		return _abort("缺少 access_key：到 https://web3forms.com 免费领一个，或填上 form_id。")
	if not is_inside_tree():
		return _abort("Web3FormsClient 需要先加入场景树。")

	_url = build_url()
	_fields = build_payload(extra)

	var http := _get_http()
	http.max_redirects = max_redirects
	http.timeout = timeout

	var body := JSON.stringify(_fields)
	_busy = true
	if debug_log:
		print("[Web3Forms] POST ", _url, "\n  ", body)

	var err := http.request(
		_url,
		PackedStringArray(["Content-Type: application/json", "Accept: application/json"]),
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		_busy = false
		_abort("无法发起 HTTP 请求（Error %d）" % err)
	return err


func is_busy() -> bool:
	return _busy


## 实际要 POST 的地址。填了 form_id 就变成 /submit/{form_id}。
func build_url() -> String:
	var base := endpoint.strip_edges().rstrip("/")
	var id := form_id.strip_edges()
	return base if id.is_empty() else "%s/%s" % [base, id]


## 生成最终请求体。保留字段最后写入，所以会覆盖同名的自定义字段。
func build_payload(extra: Dictionary = {}) -> Dictionary:
	var payload := {}
	for key in custom_fields:
		payload[str(key)] = custom_fields[key]
	for key in extra:
		payload[str(key)] = extra[key]

	if not access_key.strip_edges().is_empty():
		payload["access_key"] = access_key.strip_edges()
	if not email.strip_edges().is_empty():
		payload["email"] = email.strip_edges()
	if not subject.strip_edges().is_empty():
		payload["subject"] = subject
	if not ccemail.strip_edges().is_empty():
		payload["ccemail"] = ccemail.strip_edges()
	if not replyto.strip_edges().is_empty():
		payload["replyto"] = replyto.strip_edges()
	if not redirect.strip_edges().is_empty():
		payload["redirect"] = redirect.strip_edges()
	if not webhook.strip_edges().is_empty():
		payload["webhook"] = webhook.strip_edges()
	payload["botcheck"] = botcheck
	return payload


## 解析一次 HTTP 响应，兼容文档形状和线上真实形状。
## 文档 200：{"success":true,"body":{"data":{...},"message":"..."}}
## 线上 400：{"success":false,"data":{...},"message":"..."}      （没有 body 外层）
## 线上 500：{"message":"Internal server error"}                （没有 success 字段）
static func parse_response(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> Dictionary:
	var raw := body.get_string_from_utf8()
	var root: Dictionary = {}
	# 只在看着像 JSON 时才解析：303 的响应体是空的，出错页可能是 HTML，
	# 直接丢给 JSON.parse_string 会在控制台刷一堆引擎报错。
	var trimmed := raw.strip_edges()
	if trimmed.begins_with("{") or trimmed.begins_with("["):
		var parsed = JSON.parse_string(trimmed)
		if parsed is Dictionary:
			root = parsed
	var nested: Dictionary = root.get("body", {}) if root.get("body") is Dictionary else {}

	var message := ""
	for candidate in [root.get("message"), nested.get("message"), root.get("error"), root.get("statusCode")]:
		if candidate != null and not str(candidate).is_empty():
			message = str(candidate)
			break

	var data: Dictionary = {}
	var raw_data = root.get("data", nested.get("data", null))
	if raw_data is Dictionary:
		data = raw_data

	var success_flag = root.get("success", nested.get("success", null))
	var success: bool = success_flag if typeof(success_flag) == TYPE_BOOL else (code >= 200 and code < 300)

	var error := ""
	var is_redirect := code >= 300 and code < 400
	if result != HTTPRequest.RESULT_SUCCESS and not is_redirect:
		error = NETWORK_ERRORS.get(result, "传输层错误（%d）" % result)
	elif code == 0:
		error = "没有收到 HTTP 响应"

	return {
		"code": code,
		"success": success,
		"message": message,
		"data": data,
		"redirect_url": _header(headers, "location"),
		"raw": raw,
		"error": error,
		"transport_result": result,
	}


## 把结果整理成一行，方便直接打印。
static func describe(result: Dictionary) -> String:
	var code: int = result.get("code", 0)
	var label := "失败"
	if code >= 300 and code < 400:
		label = "重定向"
	elif result.get("success", false):
		label = "成功"
	elif not str(result.get("error", "")).is_empty():
		label = "网络错误"

	var text := ("[HTTP %d] %s" % [code, label]) if code > 0 else ("[无响应] %s" % label)
	var message := str(result.get("message", ""))
	if not message.is_empty():
		text += " · " + message
	var url := str(result.get("redirect_url", ""))
	if not url.is_empty():
		text += " → " + url
	var error := str(result.get("error", ""))
	if not error.is_empty():
		text += " · " + error
	return text


# ─────────────────────────────────────────────────────────────────────────────

func _get_http() -> HTTPRequest:
	if is_instance_valid(_http):
		return _http
	_http = HTTPRequest.new()
	_http.name = "Web3FormsHTTPRequest"
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	return _http


func _on_request_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if debug_log:
		print("[Web3Forms] HTTP %d\n  %s" % [code, body.get_string_from_utf8()])
	_emit(parse_response(result, code, headers, body))


func _abort(message: String) -> Error:
	push_error("[Web3Forms] " + message)
	var result := {
		"code": 0, "success": false, "message": message, "data": {},
		"redirect_url": "", "raw": "", "error": message,
		"transport_result": HTTPRequest.RESULT_REQUEST_FAILED,
	}
	_emit(result)
	return ERR_INVALID_PARAMETER


func _emit(result: Dictionary) -> void:
	if debug_log:
		print("[Web3Forms] ", describe(result))
	var code: int = result["code"]
	if code >= 300 and code < 400:
		submit_redirected.emit(result)
	elif result["success"] and str(result["error"]).is_empty():
		submit_succeeded.emit(result)
	else:
		submit_failed.emit(result)
	submit_completed.emit(result)


static func _header(headers: PackedStringArray, name: String) -> String:
	var prefix := name.to_lower() + ":"
	for header in headers:
		if header.to_lower().begins_with(prefix):
			return header.substr(prefix.length()).strip_edges()
	return ""
