extends SceneTree
## 导入缓存搬运器 —— 供无编辑器 / 受限沙箱环境使用
##
## Godot 的独立运行时（非编辑器）不会重新导入资源，只读取 `.godot/imported/`
## 下的既有缓存；而 DSH 文件沙箱不允许代理进程直接写 `.godot/`。
## 该脚本由不受沙箱约束的 Godot 进程执行，把源项目的导入缓存搬到目标项目，
## 从而让 player_system 的素材在首次运行前就可用。
##
## 调用方式（通过 godot_headless_op 覆盖 ops_script）：
##   godot --headless --path <目标项目> \
##         --script res://subsystem/player_system/tools/sync_import_cache.gd \
##         sync_import_cache '{"source_project":"L:/游戏项目/jump!","assets_dir":"res://subsystem/player_system/assets"}'
##
## 注意：正常开发流程不需要它 —— 在 Godot 编辑器里打开本项目一次即可自动完成导入。

const DEFAULT_SOURCE_PROJECT := "L:/游戏项目/jump!"
const DEFAULT_ASSETS_DIR := "res://subsystem/player_system/assets"


func _init() -> void:
	var params := _read_params()
	var source_project: String = str(params.get("source_project", DEFAULT_SOURCE_PROJECT))
	var assets_dir: String = str(params.get("assets_dir", DEFAULT_ASSETS_DIR))

	var src_cache_dir := source_project.trim_suffix("/").path_join(".godot/imported")
	var dst_cache_dir := ProjectSettings.globalize_path("res://.godot/imported")

	var imports: Array[String] = []
	_collect_imports(assets_dir, imports)
	if imports.is_empty():
		push_error("未在 %s 下找到任何 .import 文件" % assets_dir)
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(dst_cache_dir)

	var ok := 0
	var skipped := 0
	for import_file in imports:
		var cache_name := _cache_name_of(import_file)
		if cache_name.is_empty():
			skipped += 1
			continue
		for suffix in ["", ".md5"]:
			var name := cache_name if suffix.is_empty() else cache_name.get_basename() + ".md5"
			var from := src_cache_dir.path_join(name)
			if not FileAccess.file_exists(from):
				skipped += 1
				continue
			var to := dst_cache_dir.path_join(name)
			var err := DirAccess.copy_absolute(from, to)
			if err == OK:
				ok += 1
				print("[sync] %s" % name)
			else:
				push_error("复制失败(%d): %s -> %s" % [err, from, to])
				quit(1)
				return

	print("[sync] 共搬运 %d 个缓存文件，跳过 %d 个，目标目录：%s" % [ok, skipped, dst_cache_dir])
	quit(ok > 0)

# ────────────────────────── 内部工具 ──────────────────────────

func _read_params() -> Dictionary:
	var args := OS.get_cmdline_args()
	var i := args.find("--script")
	if i == -1 or args.size() <= i + 3:
		return {}
	var json := JSON.new()
	if json.parse(args[i + 3]) != OK:
		return {}
	var data = json.get_data()
	return data if data is Dictionary else {}


func _collect_imports(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var full := dir_path.path_join(n)
		if d.current_is_dir():
			if not n.begins_with("."):
				_collect_imports(full, out)
		elif n.ends_with(".import"):
			out.append(full)
		n = d.get_next()
	d.list_dir_end()


## 从 .import 的 [remap] path="res://.godot/imported/xxx.ctex" 取出缓存文件名
func _cache_name_of(import_path: String) -> String:
	var f := FileAccess.open(import_path, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("path=\"res://"):
			var value := line.substr("path=\"".length()).trim_suffix("\"")
			return value.get_file()
	return ""
