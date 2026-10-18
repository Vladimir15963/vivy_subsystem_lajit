# vivd_windows

Godot 4 的多窗口演出系统。按「窗口类型」动态创建/销毁窗口，提供移动、缩放、淡入淡出、方法调用等能力，给剧本开发做多窗口演出的基础设施。

在 `project.godot` 里注册为 autoload，名字是 **`VivdWindowsNode`**。

> 这套东西是重构版。旧实现已删除；完整备份在
> `_backup/vivdwindows_<时间戳>/`（带 `MANIFEST.txt` 和 sha256）。迁移对照见下文。

---



## 文档

| 文档 | 内容 |
| --- | --- |
| **README.md**（本文） | 概览、目录结构、快速开始、API 速查、迁移对照 |
| **[USAGE.md](USAGE.md)** | **详细使用手册**：心智模型、生命周期时序、config 全键参考、完整 API、窗口类型开发实战、Cookbook、调试技巧、坑与限制、FAQ |
| [FEATURES_PLAN.md](FEATURES_PLAN.md) | 后续功能规划（13 项，按性价比排序） |
| [VIDEO.md](VIDEO.md) | 视频播放：双后端选型、插件安装/卸载、体积实测、API 备忘、排查，若使用则必看 |

---

## 目录结构

```
res://subsystem/vivd_windows/
├── vivd_windows.gd        管理器（autoload 脚本）
├── vivd_windows.tscn      autoload 场景，顺便注册默认窗口类型
├── vivd_window.gd         窗口基类，所有窗口类型都继承它
├── vivd_smoke_test.gd     冒烟测试（101 条断言）
├── vivd_smoke_test.tscn
├── types/                 核心窗口类型（一个 .tscn 就是一个类型，文件名 = 类型名）
│   ├── default.tscn       通用窗口
│   ├── image.tscn         图片窗口
│   ├── file_examin.tscn   文件拖放窗口
│   ├── text.tscn          文本阅读窗口
│   └── video.tscn         视频窗口（双后端，见下）
├── sample/                样例素材
│   ├── sample_5s.ogv      5 秒测试视频（Theora）
│   └── screenshot.png     视频窗口的实际截图
└── test_fixtures/         冒烟测试用的场景
```

`script_templates/Window/vivd_window.gd` 是新建窗口类型用的脚本模板。

**文本阅读窗口**（[USAGE.md 第 13 节](USAGE.md)）用来显示和滚动阅读多行文本，
正文是 `RichTextLabel`、默认解析 BBCode，支持可选逐字显示。

**视频窗口有双后端，按后缀自动选：** `.ogv` 走 Godot 内置的 `VideoStreamPlayer`
（零依赖、零额外体积），其余格式走 [godot-vlc](https://github.com/xiSage/godot-vlc)
插件自带的 LibVLC。两个后端都是纯 CPU 解码，`gl_compatibility` 下都能跑。
插件不在时自动退回内置后端，不会崩也不会解析失败。

选型对比、体积/稳定性实测数据、API 备忘和排查表见 [VIDEO.md](VIDEO.md)。

---

## 快速开始

```gdscript
func _ready() -> void:
    VivdWindowsNode.set_dev(true)          # 打开调试浮层

    VivdWindowsNode.add_window("tip", "default", {
        "title": "提示",
        "position": Vector2i(500, 500),
        "size": Vector2i(400, 240),
    })

    VivdWindowsNode.move_window("tip", Vector2i(100, 100), 0.5)
    VivdWindowsNode.call_window_method("tip", "ping", ["你好"])
    VivdWindowsNode.fade_window_out("tip", 0.3)
    VivdWindowsNode.remove_window("tip")
```

`add_window` 的 `config` 里，管理器自己消费 `title` / `position` / `size`，
其余键会原样传给窗口的 `setup(config)`；`always_on_top`、`unresizable`、`borderless`、
`transparent`、`wrap_controls`、`exclusive` 这几个通用开关由基类自动处理。

**位置和尺寸是在窗口入树之前设好的**，不会出现「先闪一下默认位置再滑过去」。

---

## API 速查

**增删查**

| 方法 | 说明 |
| --- | --- |
| `add_window(name, type_name, config := {}) -> Window` | 失败返回 `null`（重名 / 未注册类型 / 空名字） |
| `remove_window(name) -> bool` | 移除并 `queue_free` |
| `has_window(name) -> bool` | |
| `find_window(name) -> Window` | 不存在返回 `null` |
| `list_windows() -> PackedStringArray` | |
| `window_count() -> int` | |
| `clear_windows() -> void` | |

> 不叫 `get_window` 是因为那会覆盖 `Node.get_window()`，本工程把这条警告当错误。

**操作**

| 方法 | 说明 |
| --- | --- |
| `move_window(name, position, duration := -1.0) -> bool` | `duration` 传 `0` 立即生效；不传用 `animation_duration`（默认 0.5s） |
| `resize_window(name, size, duration := -1.0) -> bool` | 同上 |
| `call_window_method(name, method, args := []) -> Variant` | `args` 会**展开**传给方法 |
| `fade_window_in(name, duration := 0.2) -> bool` | |
| `fade_window_out(name, duration := 0.2, hide_after := true) -> bool` | |
| `bring_window_to_front(name) -> bool` | |

同一个窗口的连续动画会自动 kill 掉上一个，不会互相打架。

**信号**

```gdscript
window_added(window_name, window)
window_removed(window_name, window)
window_type_registered(type_name)
window_type_unregistered(type_name)
```

**调试**

```gdscript
VivdWindowsNode.set_dev(true)   # 会同时作用到已经打开的窗口
VivdWindowsNode.is_dev()
```

**窗口类型注册**

```gdscript
register_window_type(type_name, scene) -> bool
unregister_window_type(type_name) -> bool
get_window_type(type_name) -> PackedScene
has_window_type(type_name) -> bool
list_window_types() -> PackedStringArray
scan_window_types(dir_path) -> int    # 把目录里的 *.tscn 按文件名注册
```

想「往目录里丢一个场景就能当窗口用」，把 `vivd_windows.tscn` 的 `auto_scan_dirs`
加上目录即可。类型名取自文件名，所以**文件名最好就是类型名**（`types/` 就是这么做的）。

---

## 写一个自己的窗口类型

```gdscript
extends "res://subsystem/vivd_windows/vivd_window.gd"

func setup(config: Dictionary) -> void:
    $Content/Label.text = str(config.get("text", ""))

func teardown() -> void:
    pass
```

用 `VivdWindowsNode.add_window("w1", "my_type", {"text": "hi"})` 打开。

基类白送这些，不用重复写：

* `setup(config)` / `teardown()` 生命周期
* `fade_in()` / `fade_out()` / `fade_stop()` / `bring_to_front()` / `get_center()`
* **dev 浮层**：代码自动生成，显示 `position` / `size` / `visible` / `title`（可用 `dev_watch` 改）
* **关闭按钮联动**：点窗口的 X 会自动注销，不留幽灵条目

> ⚠️ 子类如果重写了 `_ready()`，第一行要 `super._ready()`。
>
> 子类用**路径式** `extends` 而不是 `extends VivdWindow`：全局类名要等编辑器扫描过
> 写进 `.godot/global_script_class_cache.cfg` 才解析得到，路径式不依赖那个缓存，
> headless / CI / 刚克隆下来都能直接跑。基类仍保留 `class_name`，编辑器里照常能当类型用。

---

## 从旧版迁移

autoload 名字 `VivdWindowsNode` **没变**，但场景路径变了（原来指向测试目录）：
`*uid://4rt778ueud57` → `*res://subsystem/vivd_windows/vivd_windows.tscn`。

| 旧写法 | 新写法 |
| --- | --- |
| `add_window(name, title, type, ...args)` | `add_window(name, type, { "title": ..., ... })` |
| 类型名 `defaultf` | `default` |
| 类型名 `file_examin` / `image` | 不变 |
| `VivdWindowsNode.windows` | `find_window(name)` / `list_windows()` |
| `window_type` 属性 | `window_types` |
| 窗口里 `_start(args: Array)` | `setup(config: Dictionary)` |
| `call_window_method(n, m, a, b)` | `call_window_method(n, m, [a, b])`，参数会展开 |
| `move_window(n, pos)` | 默认仍是 0.5s 动画；`move_window(n, pos, 0)` 立即 |
| `resize_window(n, size)` | 同上 |
| 注释里提到的 `vivd_windows_node.gd` | 实际文件是 `vivd_windows.gd`（旧注释写错了） |

---

## 设计要点与已知限制

**窗口是真实的操作系统窗口。** 工程里 `display/window/subwindows/embed_subwindows=false`，
每个 `Window` 都是独立的 OS 窗口，不是嵌在游戏画面里的。这是刻意保留的行为。

**`Window` 没有 `modulate`。** `Window` 继承自 `Viewport`，不是 `CanvasItem`，所以没法直接
给窗口做整体透明度。`fade_in()` / `fade_out()` 是作用在窗口的**直接子内容节点**上的。
想要真正的「透明穿透」，把窗口的 `transparent` 打开（工程已开 `per_pixel_transparency/allowed`）。

**headless 下行为不同。** 无头运行时 Godot 会把 `embed_subwindows` 强制成 `true`，
所以命令行自检验证的是管理器逻辑，不是真实 OS 窗口的观感。真实观感请在编辑器里跑
`system_test_1/test.tscn`。

**文件拖放只在真实窗口下有效**，headless 收不到。

---

## 冒烟测试

```bash
godot --headless --path . res://subsystem/vivd_windows/vivd_smoke_test.tscn
```

101 条断言，全通过退出码 `0`。覆盖创建/配置、错误路径、五种窗口类型、**视频双后端选择**、
**文本窗口的滚动与逐字显示**、移动缩放、方法调用、淡入淡出、调试浮层、移除与泄漏
（用 `weakref` 确认对象真的被释放）、类型注册。

输出里会夹着几条 `ERROR` / `WARNING`，那是故意触发错误路径产生的。
视频用例在 headless 下还会刷一屏 `godot-vlc: audio buffer full` —— 那是 Godot 的假音频
驱动没人消费音频，不是错误（见 [VIDEO.md](VIDEO.md)）。

---

## 回滚

```powershell
# 备份目录
L:\项目\测试\_backup\vivdwindows_<时间戳>\
```

里面是旧实现的原样拷贝 + `MANIFEST.txt`（含每个文件的 sha256）。`_backup/` 下有一个
`.gdignore`，Godot 会完全跳过它，不会产生重复 uid 或重复类名。
