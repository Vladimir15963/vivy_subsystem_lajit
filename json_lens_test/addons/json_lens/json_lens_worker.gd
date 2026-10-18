@tool
extends RefCounted

## JSON Lens —— 后台解析调度器
##
## 只做一件事：把「读文件 + JSON 解析 + 摊平成类型化数组」丢进 WorkerThreadPool，
## 主线程每帧非阻塞 poll 一次。所以几十 MB 的文件在解析期间编辑器依然可操作。
##
## 线程安全约定（这部分是有实测依据的，别随手改）：
##   1. Model 对象在任务线程里 new + 写满，再通过 Mutex 一次性交给主线程，
##      之后主线程独占读取 —— 任何时刻只有一个线程碰它。
##   2. 绝不让工作线程去读主线程正在持有的 GDScript 对象（哪怕只读），
##      Godot 4.7 上这样做会在退出时崩溃（见 tests/thread_probe.gd）。
##      这也是「搜索」放在主线程分帧扫描而不是放这里的原因。
##   3. 取消用「代号（generation）」实现：每次 start 都让 _gen 自增，
##      旧任务的回写因 gen 不匹配被丢弃，因此不需要也无法强行中断线程。

const Model := preload("res://addons/json_lens/json_lens_model.gd")

var _mutex := Mutex.new()
var _gen := 0
var _task := -1
var _task_gen := -1
var _progress := 0
var _out_model = null
var _out_error := ""
var _out_ms := 0


func is_busy() -> bool:
	if _task < 0 or _task_gen != _gen:
		return false
	return not WorkerThreadPool.is_task_completed(_task)


func get_progress() -> int:
	_mutex.lock()
	var p := _progress
	_mutex.unlock()
	return p


## 丢弃在飞的任务结果（例如又打开了另一个文件）。
func invalidate() -> void:
	_mutex.lock()
	_gen += 1
	_mutex.unlock()
	_task = -1


func start_load(path: String) -> bool:
	_mutex.lock()
	_gen += 1
	_progress = 0
	_out_model = null
	_out_error = ""
	_out_ms = 0
	var g := _gen
	_mutex.unlock()
	_task_gen = g
	_task = WorkerThreadPool.add_task(_task_load.bind(path, g), false, "JSON Lens：解析 JSON")
	return _task >= 0


## 取回已完成的结果；没有就返回空字典。
func take() -> Dictionary:
	if _task < 0 or _task_gen != _gen:
		return {}
	if not WorkerThreadPool.is_task_completed(_task):
		return {}
	_task = -1
	_mutex.lock()
	var res := {
		"model": _out_model,
		"error": _out_error,
		"ms": _out_ms,
	}
	_out_model = null
	_out_error = ""
	_out_ms = 0
	_mutex.unlock()
	return res


# ------------------------------------------------------------------ 内部

func _report(gen: int, n: int) -> void:
	_mutex.lock()
	if gen == _gen:
		_progress = n
	_mutex.unlock()


func _commit(gen: int, model, err: String, ms: int) -> void:
	_mutex.lock()
	if gen == _gen:
		_out_model = model
		_out_error = err
		_out_ms = ms
	_mutex.unlock()


# 注意：这个函数运行在后台线程里，只能碰局部变量和 Mutex 保护的成员。
func _task_load(path: String, gen: int) -> void:
	var t0 := int(Time.get_ticks_msec())

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_commit(gen, null, "无法打开文件：%s（%s）" % [path, error_string(FileAccess.get_open_error())], 0)
		return
	var size := f.get_length()
	var bytes := f.get_buffer(size)
	f.close()

	if bytes.is_empty() and size > 0:
		_commit(gen, null, "读取文件失败：%s" % path, 0)
		return

	var src := _decode(bytes)
	bytes = PackedByteArray()

	var m = Model.new()
	var ok: bool = m.build(src, _report.bind(gen))
	if not ok:
		_commit(gen, null, m.error, int(Time.get_ticks_msec()) - t0)
		return
	_commit(gen, m, "", int(Time.get_ticks_msec()) - t0)


func _decode(bytes: PackedByteArray) -> String:
	var n := bytes.size()
	if n >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
		return bytes.slice(3).get_string_from_utf8()
	if n >= 2 and bytes[0] == 0xFF and bytes[1] == 0xFE:
		return bytes.slice(2).get_string_from_utf16()
	if n >= 2 and bytes[0] == 0xFE and bytes[1] == 0xFF:
		var swapped := bytes.slice(2)
		for i in range(0, swapped.size() - 1, 2):
			var t := swapped[i]
			swapped[i] = swapped[i + 1]
			swapped[i + 1] = t
		return swapped.get_string_from_utf16()
	return bytes.get_string_from_utf8()
