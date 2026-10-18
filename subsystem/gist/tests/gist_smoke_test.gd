extends Node

## Gist 子系统 headless 自测入口。
## 只测纯函数与状态机，不发起真实网络请求（沙箱 / CI 通常没有外网）。
## 真实网络交互走 gist_test.tscn 面板。
##
## 运行方式（headless）：
##   godot --headless --path <项目> res://subsystem/gist/tests/gist_smoke_test.tscn
## 退出码：0 = 全部通过，1 = 有失败，2 = 超时。

func _ready() -> void:
	var runner := SmokeRunner.new()
	runner.name = "GistSmokeRunner"
	get_tree().root.add_child.call_deferred(runner)


class SmokeRunner extends Node:
	const GistClient := preload("res://subsystem/gist/gist_client.gd")

	const RAW_TEXT := "# Hello Gist\n这是一段纯文本内容。"
	const API_JSON := '{"id":"523d15bc","files":{"gistfile1.txt":{"filename":"gistfile1.txt","content":"来自 files 的内容"}}}'

	var _failures := PackedStringArray()
	var _checks := 0


	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		_run()


	func _run() -> void:
		print("=== Gist 自测开始 ===")
		_start_watchdog()
		await get_tree().process_frame

		_test_parse_gist()
		_test_parse_response()
		_test_describe()
		await _test_state_machine()
		_test_not_in_tree()

		_finish()


	# ------------------------------------------------------------ 解析 Gist 内容
	func _test_parse_gist() -> void:
		var raw := GistClient.parse_gist(RAW_TEXT.to_utf8_buffer())
		_check(raw["content"] == RAW_TEXT, "纯文本响应：content 就是原文")
		_check(raw["is_json"] == false, "纯文本响应：is_json == false")
		_check(raw["files"].is_empty(), "纯文本响应：files 为空")

		var api := GistClient.parse_gist(API_JSON.to_utf8_buffer())
		_check(api["is_json"] == true, "Gist API JSON：is_json == true")
		_check(api["files"].has("gistfile1.txt"), "Gist API JSON：解析出 files 字典")
		_check(api["content"] == "来自 files 的内容", "Gist API JSON：content 取自 files 里的内容")

		var empty := GistClient.parse_gist(PackedByteArray())
		_check(empty["content"] == "" and empty["is_json"] == false, "空响应：content 为空、is_json == false")


	# ------------------------------------------------------------ 解析 HTTP 响应
	func _test_parse_response() -> void:
		var ok := GistClient.parse_response(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), RAW_TEXT.to_utf8_buffer())
		_check(ok["success"] == true, "200：success == true")
		_check(ok["code"] == 200, "200：code == 200")
		_check(str(ok["error"]).is_empty(), "200：error 为空")
		_check(ok["content"] == RAW_TEXT, "200：content 是原文")

		var notfound := GistClient.parse_response(HTTPRequest.RESULT_SUCCESS, 404, PackedStringArray(), PackedByteArray())
		_check(notfound["success"] == false, "404：success == false")
		_check(str(notfound["message"]).contains("404"), "404：message 说明是异常响应")

		var bad_method := GistClient.parse_response(HTTPRequest.RESULT_SUCCESS, 405, PackedStringArray(), PackedByteArray())
		_check(bad_method["success"] == false, "405（POST 到 raw 地址）：success == false")
		_check(str(bad_method["message"]).contains("405"), "405：message 说明方法不被允许")

		var timed := GistClient.parse_response(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())
		_check(timed["timed_out"] == true, "超时：timed_out == true")
		_check(timed["success"] == false, "超时：success == false")
		_check(timed["error"] == "请求超时", "超时：error == 请求超时")

		var no_conn := GistClient.parse_response(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())
		_check(no_conn["error"] == "无法连接到服务器", "连接拒绝：error 正确")
		_check(no_conn["timed_out"] == false, "连接拒绝：不算超时")


	# ------------------------------------------------------------ 单行摘要
	func _test_describe() -> void:
		var ok := GistClient.describe(GistClient.parse_response(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), RAW_TEXT.to_utf8_buffer()))
		_check(ok.contains("成功"), "describe：成功时带「成功」")
		var bad := GistClient.describe(GistClient.parse_response(HTTPRequest.RESULT_SUCCESS, 405, PackedStringArray(), PackedByteArray()))
		_check(bad.contains("失败"), "describe：405 时带「失败」")
		var timed := GistClient.describe(GistClient.parse_response(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray()))
		_check(timed.contains("超时"), "describe：超时时带「超时」")


	# ------------------------------------------------------------ 状态机与信号
	func _test_state_machine() -> void:
		var client = GistClient.new()
		add_child(client)
		await get_tree().process_frame

		_check(client.get_request_status() == GistClient.RequestStatus.IDLE, "初始：请求状态为空闲")
		_check(client.get_connection_status() == GistClient.ConnectionStatus.DISCONNECTED, "初始：连接状态为未连接")
		_check(client.get_network_status() == "未探测", "初始：网络状态为未探测")

		var got := {"success": false, "failed": false, "timeout": false, "completed": false}
		client.request_succeeded.connect(func(_r): got["success"] = true)
		client.request_failed.connect(func(_r): got["failed"] = true)
		client.request_timed_out.connect(func(_r): got["timeout"] = true)
		client.request_completed.connect(func(_r): got["completed"] = true)

		# 模拟一次成功响应
		client._on_request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), RAW_TEXT.to_utf8_buffer())
		_check(got["success"] and got["completed"], "成功响应：触发 succeeded + completed")
		_check(client.get_connection_status_text() == "已连接", "成功响应：连接状态为已连接")
		_check(client.get_network_status() == "网络可用", "成功响应：网络状态为可用")
		_check(client.get_request_status_text() == "已完成", "成功响应：请求状态为已完成")

		# 重置信号标记，模拟超时响应
		_reset_flags(got)
		client._on_request_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())
		_check(got["timeout"] and got["completed"], "超时响应：触发 timed_out + completed")
		_check(got["success"] == false and got["failed"] == false, "超时响应：不触发 succeeded / failed")
		_check(client.get_connection_status_text() == "连接失败", "超时响应：连接状态为失败")

		# 模拟一次异常响应（405）
		_reset_flags(got)
		client._on_request_completed(HTTPRequest.RESULT_SUCCESS, 405, PackedStringArray(), PackedByteArray())
		_check(got["failed"] and got["completed"], "405 异常响应：触发 failed + completed")
		_check(client.get_last_result()["code"] == 405, "405 异常响应：last_result 记录状态码")

		client.queue_free()


	## 把信号标记复位（原地改，保证被 lambda 捕获的那个字典同步生效）
	func _reset_flags(flags: Dictionary) -> void:
		for key in flags:
			flags[key] = false


	# ------------------------------------------------------------ 未入树时的保护
	func _test_not_in_tree() -> void:
		var client = GistClient.new()
		var err = client.request_gist("", HTTPClient.METHOD_POST)
		_check(err != OK, "未加入场景树时发起请求会返回错误")
		_check(client.get_last_result()["success"] == false, "未加入场景树时 last_result 记为失败")
		client.free()


	# ------------------------------------------------------------ 工具
	func _check(condition: bool, message: String) -> void:
		_checks += 1
		if condition:
			print("  [PASS] ", message)
		else:
			print("  [FAIL] ", message)
			_failures.append(message)


	func _start_watchdog() -> void:
		var timer := Timer.new()
		timer.wait_time = 30.0
		timer.one_shot = true
		timer.process_mode = Node.PROCESS_MODE_ALWAYS
		timer.timeout.connect(func() -> void:
			print("  [FAIL] 自测超时（30 秒）")
			get_tree().quit(2))
		add_child(timer)
		timer.start()


	func _finish() -> void:
		print("=== Gist 自测结束：%d 项检查，%d 项失败 ===" % [_checks, _failures.size()])
		for f in _failures:
			print("  失败：", f)
		get_tree().quit(0 if _failures.is_empty() else 1)
