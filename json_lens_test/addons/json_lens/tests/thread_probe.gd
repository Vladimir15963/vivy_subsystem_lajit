extends SceneTree

## 探针 4：对照实验
##   plain  = 任务完全不碰 model，只写一个整数
##   model  = 任务读取 model 的 Packed 数组（当前 json_lens_worker 的做法）
##   copied = 任务读取的是主线程拷贝出来的普通 Array

const Model := preload("res://addons/json_lens/json_lens_model.gd")

const MODE := "plain"

var mutex := Mutex.new()
var out := 0
var _task := -1


func _initialize() -> void:
	var arr := []
	for i in 3000:
		arr.append({"id": i, "name": "item_%d" % i})
	var m = Model.new()
	m.build(JSON.stringify({"items": arr}))
	print("mode=", MODE, " nodes=", m.total)

	match MODE:
		"plain":
			_task = WorkerThreadPool.add_task(_work_plain.bind(), false, "plain")
		"model":
			_task = WorkerThreadPool.add_task(_work_model.bind(m), false, "model")
		"copied":
			var texts := Array(m.texts)
			_task = WorkerThreadPool.add_task(_work_copied.bind(texts), false, "copied")

	while not WorkerThreadPool.is_task_completed(_task):
		OS.delay_msec(2)
	print("out = ", out)
	_task = -1
	quit(0)


func _work_plain() -> void:
	out = 42


func _work_model(m) -> void:
	var c := 0
	for i in m.total:
		if m.texts[i].findn("item_1234") >= 0:
			c += 1
		if m.keys[i] == "":
			pass
	out = c


func _work_copied(texts: Array) -> void:
	var c := 0
	for i in texts.size():
		var t: String = texts[i]
		if t.findn("item_1234") >= 0:
			c += 1
	out = c


func _process(_delta: float) -> bool:
	return false
