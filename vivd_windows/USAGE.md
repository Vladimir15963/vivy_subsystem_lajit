# vivd_windows 使用手册

面向要**用**这套系统的人（写窗口类型、写演出逻辑）。概览和迁移表见 [README.md](README.md)，
后续功能规划见 [FEATURES_PLAN.md](FEATURES_PLAN.md)。

---

## 目录

1. [心智模型](#1-心智模型)
2. [五分钟上手](#2-五分钟上手)
3. [生命周期与时序](#3-生命周期与时序)
4. [config 配置字典完整参考](#4-config-配置字典完整参考)
5. [管理器 API 参考](#5-管理器-api-参考)
6. [窗口基类 VivdWindow 参考](#6-窗口基类-vivdwindow-参考)
7. [实战：写一个窗口类型](#7-实战写一个窗口类型)
8. [常见任务 Cookbook](#8-常见任务-cookbook)
9. [调试技巧](#9-调试技巧)
10. [坑与限制](#10-坑与限制)
11. [从外部驱动窗口](#11-从外部驱动窗口)
12. [视频窗口](#12-视频窗口)
13. [文本阅读窗口](#13-文本阅读窗口)
14. [自动化测试](#14-自动化测试)
15. [FAQ](#15-faq)

---

## 1. 心智模型

四个概念，理解了就不会用错：

| 概念 | 是什么 | 在哪 |
| --- | --- | --- |
| **管理器** | 全局单例，管所有窗口的生死和变换 | autoload `VivdWindowsNode` |
| **窗口类型** | 一个 `Window` 场景 = 一种窗口（比如"图片窗口"） | `vivd_windows/types/*.tscn` |
| **窗口实例** | 用类型实例化出来的具体窗口，有唯一名字 | 运行时，挂在管理器下面 |
| **窗口基类** | 所有窗口类型都继承它，白送生命周期/淡入淡出/调试浮层 | `vivd_window.gd` |

关系：

```
VivdWindowsNode  (autoload, Node)
├── window_types: { "image" → image.tscn, "default" → default.tscn, ... }   ← 类型表
└── 子节点 = 活着的窗口实例
    ├── "tip"    (image.tscn 的实例, 脚本 extends VivdWindow)
    └── "status" (default.tscn 的实例)

外部只通过 VivdWindowsNode 的 API 操作，不直接碰子节点。
每个窗口的名字既是节点名，也是 API 里用的 key。
```

**一句话**：`types/` 里放"模板"，`add_window()` 用模板造实例，之后所有操作都用名字找实例。

---

## 2. 五分钟上手

```gdscript
extends Node

func _ready() -> void:
    # 1. 打开调试浮层（每个窗口左上角实时显示坐标/尺寸）
    VivdWindowsNode.set_dev(true)

    # 2. 开一个通用窗口
    VivdWindowsNode.add_window("tip", "default", {
        "title": "提示",
        "position": Vector2i(600, 400),
        "size": Vector2i(400, 200),
    })

    # 3. 开一个图片窗口
    VivdWindowsNode.add_window("pic", "image", {
        "image": "res://icon.svg",
        "position": Vector2i(100, 100),
        "size": Vector2i(320, 320),
    })

    # 4. 操作它们
    VivdWindowsNode.move_window("tip", Vector2i(200, 200), 0.5)   # 0.5 秒动画
    VivdWindowsNode.fade_window_in("pic", 0.3)
    VivdWindowsNode.bring_window_to_front("pic")

    # 5. 关掉
    VivdWindowsNode.remove_window("tip")
```

在编辑器里跑 `system_test_1/test.tscn` 可以直接看到效果。

---

## 3. 生命周期与时序

### 3.1 `add_window()` 内部做了什么

按顺序，**这个顺序决定了几个行为特性**：

| # | 动作 | 说明 |
| --- | --- | --- |
| 1 | 校验窗口名非空 | 空/纯空白 → `push_error` + 返回 `null` |
| 2 | 校验重名 | 已存在 → `push_error` + 返回 `null`（**不会**顶掉旧窗口） |
| 3 | 校验类型已注册 | 未注册 → `push_error` + 返回 `null` |
| 4 | `scene.instantiate()` | |
| 5 | 设 `window.name` | 在入树**之前** |
| 6 | 从 config 设 `title` / `position` / `size` | **在入树之前** ← 所以不会"先闪一下默认位置再滑走" |
| 7 | 记入内部表 | |
| 8 | `add_child(window)` | 此时触发窗口自己的 `_ready()`（浮层在这里建好） |
| 9 | 连接 `vivd_close_requested` | 用户点 X 时能自动注销 |
| 10 | `window.vivd_setup(config)` | → `apply_window_flags()` → `setup()` → 发 `vivd_ready` |
| 11 | `window.vivd_set_dev(dev_mode)` | 按当前调试模式显隐浮层 |
| 12 | 发 `window_added` 信号 | **此时窗口已完全初始化**，监听者拿到的是可用状态 |
| 13 | 返回 window 实例 | |

**推论**：
* 你在 `window_added` 里可以直接操作窗口，不需要 `await`。
* 第 10 步的 `setup()` 在第 8 步的 `_ready()` **之后**，所以 `setup()` 里读 `@onready` 变量是安全的。
* 第 6 步保证位置/尺寸是瞬时的；想让窗口带位移动画入场，得自己调 `move_window`。

### 3.2 `remove_window()` 内部做了什么

| # | 动作 | 说明 |
| --- | --- | --- |
| 1 | 存在性检查 | 不存在 → `push_warning` + 返回 `false` |
| 2 | 取出引用 | |
| 3 | 从内部表抹掉 | **先抹表**，避免重入 |
| 4 | kill 掉该窗口的动画 tween | 否则动画会对着已释放节点报错 |
| 5 | `teardown()` | 你的清理钩子 |
| 6 | `remove_child()` | |
| 7 | `queue_free()` | |
| 8 | 发 `window_removed` 信号 | ⚠️ **此时节点还没真正释放**（`queue_free` 是延迟的） |
| 9 | 返回 `true` | |

**推论**：在 `window_removed` 回调里不要假设节点已销毁。想确认释放，等一帧后用 `weakref`。

### 3.3 与 `_ready` / `setup` / `teardown` 的关系

```
instantiate()
    ↓
_ready()                    ← 基类在这里建 dev 浮层、接 close_requested
    ↓  （add_child 触发）
vivd_setup(config)
    ├── apply_window_flags(config)    ← 基类处理 always_on_top 等通用开关
    ├── setup(config)                 ← ★ 你的初始化代码写这里
    └── emit vivd_ready
    ↓
（窗口正常运行）
    ↓
teardown()                  ← ★ 你的清理代码写这里，在 remove_child 之前
    ↓
remove_child() → queue_free()
```

**只有一个钩子必须注意**：子类重写了 `_ready()` 的话，第一行要 `super._ready()`。
漏了的话 dev 浮层和你自己窗口的关闭按钮联动都会失效（见 [第 10 节](#10-坑与限制)）。

---

## 4. config 配置字典完整参考

`add_window(name, type_name, config)` 的第三个参数。三类键：

### 4.1 管理器自己消费的键

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `title` | `String` | 窗口标题栏文字 |
| `position` | `Vector2i` | 窗口位置，**立即生效**（无动画） |
| `size` | `Vector2i` | 窗口尺寸，**立即生效** |

这三个在窗口入树前就设好。缺省则用场景里配的值。

### 4.2 基类自动处理的通用开关

以下键会被 `apply_window_flags()` 自动读取，**你不用在 `setup()` 里处理**：

| 键 | 类型 | 对应属性 | 说明 |
| --- | --- | --- | --- |
| `always_on_top` | `bool` | `Window.always_on_top` | 永远浮在其他窗口之上 |
| `unresizable` | `bool` | `Window.unresizable` | 禁止用户拖边缩放 |
| `borderless` | `bool` | `Window.borderless` | 无边框（要自己做标题栏和拖拽） |
| `transparent` | `bool` | `Window.transparent` | 逐像素透明（工程已开 `per_pixel_transparency/allowed`） |
| `wrap_controls` | `bool` | `Window.wrap_controls` | 窗口自动收缩到内容大小 |
| `exclusive` | `bool` | `Window.exclusive` | 独占输入焦点 |

注意这些是**覆盖**场景里的值，只处理你显式传了的键。

### 4.3 传给窗口 `setup()` 的自定义键

其余所有键原样进入 `setup(config)`。你的窗口类型自己定义约定，比如 `image` 类型认 `image` 键：

```gdscript
VivdWindowsNode.add_window("pic", "image", {
    "image": "res://icon.svg",     # ← image 类型自己认的
    "position": Vector2i(0, 0),    # ← 管理器认的
    "always_on_top": false,        # ← 基类认的
})
```

`setup()` 里拿到的是**完整的** config（包括 `title`/`position`/`size` 和通用开关），
所以窗口类型也能读到它们。

---

## 5. 管理器 API 参考

所有 API 都通过 autoload 名 `VivdWindowsNode` 调用。

### 5.1 窗口增删查

```gdscript
add_window(window_name: String, type_name: String, config: Dictionary = {}) -> Window
```
创建窗口。**失败返回 `null`** 并 `push_error`。失败原因：名字为空、名字已存在、类型未注册、场景实例化失败。

```gdscript
remove_window(window_name: String) -> bool
```
移除并释放。不存在返回 `false`（`push_warning`）。

```gdscript
has_window(window_name: String) -> bool
find_window(window_name: String) -> Window
```
查窗口。`find_window` 不存在返回 `null`。

> 为什么不叫 `get_window`：那会覆盖 `Node.get_window()`，本工程把这条警告当错误，直接解析失败。

```gdscript
list_windows() -> PackedStringArray
window_count() -> int
clear_windows() -> void
```
`clear_windows()` 内部先取快照再逐个删，所以边遍历边删是安全的。

### 5.2 窗口变换与方法调用

```gdscript
move_window(window_name: String, position: Vector2i, duration: float = -1.0) -> bool
resize_window(window_name: String, size: Vector2i, duration: float = -1.0) -> bool
```

`duration` 的三种取值：

| 值 | 行为 |
| --- | --- |
| 不传（`-1.0`） | 用 `animation_duration`（默认 **0.5 秒**） |
| `0` 或负数以外的 `<= 0` | **立即生效**，不走动画 |
| `> 0` | 指定秒数的 Cubic 缓动动画 |

同一个窗口连续调两次，**前一个动画会被 kill**，不会互相打架。

```gdscript
call_window_method(window_name: String, method: String, args: Array = []) -> Variant
```

调用窗口上的方法，`args` 会**展开**传进去（用 `callv`）：

```gdscript
# 窗口上有 func set_text(text: String, size: int)
VivdWindowsNode.call_window_method("tip", "set_text", ["你好", 24])
# 等价于 tip.set_text("你好", 24)
```

窗口不存在、或方法不存在 → `push_warning` + 返回 `null`。

```gdscript
fade_window_in(window_name: String, duration := 0.2) -> bool
fade_window_out(window_name: String, duration := 0.2, hide_after := true) -> bool
bring_window_to_front(window_name: String) -> bool
```
转发给窗口基类的同名方法。**不等待动画结束**（想等就直接拿窗口对象的 Tween，见 6.2）。

### 5.3 调试模式

```gdscript
set_dev(enabled: bool) -> void
is_dev() -> bool
```

`set_dev()` 会**同时作用到已经打开的窗口**，不只是之后新建的。

### 5.4 窗口类型注册

```gdscript
register_window_type(type_name: String, scene: PackedScene) -> bool
```
返回 `true` = 新增；返回 `false` = 之前就有（**但仍会用新场景覆盖**）。名字为空或场景为 `null` → `push_error` + `false`。

```gdscript
unregister_window_type(type_name: String) -> bool
```
注销。**已经打开的窗口不受影响**，只是不能再拿这个类型开新窗口。

```gdscript
get_window_type(type_name: String) -> PackedScene     # 不存在返回 null
has_window_type(type_name: String) -> bool
list_window_types() -> PackedStringArray
scan_window_types(dir_path: String) -> int
```

`scan_window_types()` 扫描目录里的 `*.tscn`，**按文件名**注册成类型名，
自动跳过根节点不是 `Window` 的场景。返回新注册的数量。

所以 `types/default.tscn` 会注册成 `default`。**文件名就是类型名**，这是刻意设计——
这样手动注册和目录扫描的结果一致，不会出现 `default` 和 `default_window` 两个类型。

### 5.5 信号

```gdscript
window_added(window_name: String, window: Window)
window_removed(window_name: String, window: Window)
window_type_registered(type_name: String)
window_type_unregistered(type_name: String)
```

```gdscript
func _ready() -> void:
    VivdWindowsNode.window_added.connect(_on_window_added)
    VivdWindowsNode.window_removed.connect(_on_window_removed)

func _on_window_added(window_name: String, window: Window) -> void:
    print("开了：", window_name)
    # 此时窗口已 setup 完毕，可以直接操作

func _on_window_removed(window_name: String, window: Window) -> void:
    print("关了：", window_name)
    # ⚠️ window 还没真正 free，queue_free 是延迟的
```

`window_removed` 在**用户点窗口 X** 时也会发（因为内部走的是同一个 `remove_window`）。

### 5.6 导出属性与常量

在 `vivd_windows.tscn` 的检查器里可以改：

| 属性 | 默认 | 说明 |
| --- | --- | --- |
| `window_types` | 3 个内置类型 | 类型表，可以直接在检查器里加 |
| `dev_mode` | `false` | 初始是否开调试浮层 |
| `animation_duration` | `0.5` | `move_window`/`resize_window` 不传 duration 时用的秒数 |
| `auto_scan_dirs` | 空 | 启动时自动扫描的目录列表 |

```gdscript
const DEFAULT_ANIMATION_DURATION := 0.5
```

---

## 6. 窗口基类 VivdWindow 参考

所有窗口类型的脚本都继承它（用路径式 `extends`，原因见第 10 节）。

### 6.1 生命周期钩子（你重写这两个）

```gdscript
func setup(config: Dictionary) -> void:
```
初始化。`config` 是 `add_window()` 收到的那本字典。只会被调一次（内部有 `_setup_done` 保护）。

```gdscript
func teardown() -> void:
```
清理。在 `remove_child()` **之前**调用，此时节点还在树上、连接还有效。

### 6.2 通用能力

```gdscript
func fade_in(duration := 0.2) -> Tween
func fade_out(duration := 0.2, hide_after := true) -> Tween
func fade_stop() -> void
```

* `fade_in()` 会先 `show()`，然后把内容透明度从 0 推到 1。
* `fade_out()` 从当前透明度推到 0，`hide_after` 为 `true` 时结束后 `hide()`。
* `fade_stop()` 立刻停掉动画并把透明度恢复到 1。
* 都**返回 Tween**，想等结束就：

```gdscript
var window := VivdWindowsNode.find_window("tip")
await window.fade_in(0.3).finished      # 注意：Window 类型上没这个方法，见下方说明
```

> ⚠️ `VivdWindowsNode.find_window()` 的静态返回类型是 `Window`，直接写
> `window.fade_in()` 会因为「Window 上没有这个方法」而**解析报错**。三种解决办法：
> 用管理器转发（`VivdWindowsNode.fade_window_in("tip")`）、用 `window.call("fade_in", 0.3)`、
> 或者把变量声明成 `Variant`。

```gdscript
func fade_stop() -> void
func bring_to_front() -> void      # 显示 + 抢焦点（4.7 起 move_to_foreground 已弃用）
func get_center() -> Vector2i      # 屏幕坐标下的中心点（整除）
func get_content_items() -> Array[CanvasItem]    # 直接子节点里的 CanvasItem
func is_dev() -> bool
```

### 6.3 dev 浮层

开启后每个窗口左上角显示实时属性，刷新间隔 `DEV_REFRESH_INTERVAL`（0.1 秒）。

默认监视 `position` / `size` / `visible` / `title`（常量 `DEV_WATCH_DEFAULT`）。

**改成监视你自己的属性**——在 `_init()` 或 `setup()` 里赋值 `dev_watch` 都行：

```gdscript
extends "res://vivd_windows/vivd_window.gd"

var image_path := ""

func setup(config: Dictionary) -> void:
    dev_watch = PackedStringArray(["position", "size", "image_path"])
    ...
```

因为内部用的是 `get(property)`，所以 `dev_watch` 里可以放**脚本自己的变量名**（上面例子的
`image_path` 就是），不只是 `Window` 的原生属性。

浮层实现细节：

* 节点名 `VivdDevOverlay`，里面是一个叫 `Info` 的 `VBoxContainer`，每个属性一个 `Label`。
* 整个浮层 `mouse_filter = IGNORE`，不吃鼠标输入。
* 刷新用独立的 `Timer`，**不用 `_process`**，所以子类可以随意重写 `_process` 而不影响浮层。

### 6.4 内部方法（别直接调）

```gdscript
vivd_setup(config)        # 管理器调用
vivd_set_dev(enabled)     # 管理器调用
apply_window_flags(config)  # vivd_setup 内部调用
```

### 6.5 信号

```gdscript
vivd_close_requested(window_name: String)   # 用户点了窗口 X
vivd_ready(window_name: String)             # setup() 执行完毕
```

`vivd_close_requested` 由管理器接管（自动 `remove_window`），一般不用你自己接。

---

## 7. 实战：写一个窗口类型

目标：一个「时钟窗口」，自定义 `setup()`、暴露一个方法、监视自己的属性。

**第一步**，新建脚本 `vivd_windows/types/clock_window.gd`：

```gdscript
extends "res://vivd_windows/vivd_window.gd"
## 时钟窗口：显示当前时间，可以切换 12/24 小时制。

var use_24h := true

@onready var _label: Label = get_node_or_null("TimeLabel")


func setup(config: Dictionary) -> void:
    # 监视自己的属性（第三个是自己脚本上的变量）
    dev_watch = PackedStringArray(["position", "size", "use_24h"])
    if config.has("use_24h"):
        use_24h = bool(config["use_24h"])
    _refresh()


func teardown() -> void:
    # 如果有定时器/连接，在这里断开
    pass


func _process(_delta: float) -> void:
    _refresh()


## 外部通过 VivdWindowsNode.call_window_method("clock", "set_24h", [false]) 调用
func set_24h(enabled: bool) -> void:
    use_24h = enabled
    _refresh()


func _refresh() -> void:
    if _label == null:
        return
    var now := Time.get_time_dict_from_system()
    _label.text = "%02d:%02d:%02d" % [now.hour, now.minute, now.second]
```

**第二步**，新建场景 `vivd_windows/types/clock.tscn`：

```
根节点类型选 Window，挂上 clock_window.gd
可以继承 default.tscn 复用默认外观（推荐）
加一个 Label，节点名改成 TimeLabel
```

**第三步**，注册。两种方式：

* **检查器**：打开 `vivd_windows/vivd_windows.tscn`，在 `window_types` 里加 `"clock" → clock.tscn`。
* **目录扫描**：把 `auto_scan_dirs` 设成 `["res://vivd_windows/types"]`，文件名 `clock.tscn`
  会自动注册成类型名 `clock`。

**第四步**，用：

```gdscript
VivdWindowsNode.add_window("clock", "clock", {
    "title": "时钟",
    "use_24h": false,
    "position": Vector2i(40, 40),
    "size": Vector2i(240, 100),
})
VivdWindowsNode.call_window_method("clock", "set_24h", [true])
```

> 直接用 `script_templates/Window/vivd_window.gd` 当模板创建脚本更省事。

---

## 8. 常见任务 Cookbook

### 开窗并带淡入

```gdscript
var w = VivdWindowsNode.add_window("tip", "default", {
    "title": "提示",
    "position": Vector2i(500, 400),
})
# add_window 是同步的，返回时窗口已就绪
VivdWindowsNode.fade_window_in("tip", 0.3)
```

### 进场动画：从右侧滑入

```gdscript
var target := Vector2i(600, 300)
VivdWindowsNode.add_window("panel", "default", {
    "position": target + Vector2i(300, 0),   # 先放在屏幕外（瞬时）
})
# 再动画移到目标位置
VivdWindowsNode.move_window("panel", target, 0.4)
```

关键是**用 `position` 设初始位置**（瞬时），再用 `move_window` 做动画。

### 让用户点 X 时做点什么

```gdscript
func _ready() -> void:
    VivdWindowsNode.window_removed.connect(_on_removed)

func _on_removed(window_name: String, _window: Window) -> void:
    if window_name == "settings":
        print("设置关了，恢复游戏")
```

### 安全地调窗口方法（可能还没开）

```gdscript
if VivdWindowsNode.has_window("tip"):
    VivdWindowsNode.call_window_method("tip", "set_text", ["你好"])
```

### 一组窗口一起动

目前没有分组 API，手动遍历即可：

```gdscript
const HUD := ["tip", "status", "clock"]

func shift_hud(offset: Vector2i) -> void:
    for window_name in HUD:
        var w := VivdWindowsNode.find_window(window_name)
        if w != null:
            VivdWindowsNode.move_window(window_name, w.position + offset, 0.3)
```

### 运行时换图

```gdscript
VivdWindowsNode.call_window_method("pic", "set_image", ["res://assets/new.png"])
```

### 动态注册类型（不碰场景文件）

```gdscript
func _ready() -> void:
    VivdWindowsNode.register_window_type("dlg", load("res://ui/dialog.tscn"))
```

### 让窗口跟着主窗口大小变化

系统目前**不做**自适应（见 [FEATURES_PLAN.md](FEATURES_PLAN.md) 第 2 条）。临时做法：

```gdscript
func _ready() -> void:
    get_window().size_changed.connect(_relayout)

func _relayout() -> void:
    var view := get_window().size
    VivdWindowsNode.move_window("tip", Vector2i(view.x - 420, view.y - 260), 0.0)
```

### 退出时清干净

```gdscript
func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST:
        VivdWindowsNode.clear_windows()
```

---

## 9. 调试技巧

**开调试浮层。** 最直接的排查手段：

```gdscript
VivdWindowsNode.set_dev(true)
```

**打印当前窗口清单和位置：**

```gdscript
for window_name in VivdWindowsNode.list_windows():
    var w := VivdWindowsNode.find_window(window_name)
    print("%s  pos=%s  size=%s  visible=%s  title=%s" % [
        window_name, w.position, w.size, w.visible, w.title,
    ])
```

**留意控制台里的 `[VivdWindows]` 前缀。** 所有失败都有明确原因，不会再静默：

```
ERROR: [VivdWindows] 窗口已存在：tip（先 remove_window 或换个名字）
ERROR: [VivdWindows] 未注册的窗口类型：pictur（已注册：default, file_examin, image）
WARNING: [VivdWindows] 移动失败，窗口不存在：tip
WARNING: [VivdWindows] 窗口 tip 上没有方法 set_txt
```

第三、四行是刻意区分的：**`ERROR` = 你调用方式有问题（参数/名字/类型），`WARNING` = 运行时状态不对（窗口不在了）**。

**检查是不是漏了 `super._ready()`：** 症状是 dev 浮层不出现、或者点窗口 X 关不掉。

---

## 10. 坑与限制

### 10.1 子类重写 `_ready()` 必须调 `super._ready()`

```gdscript
func _ready() -> void:
    super._ready()          # ← 漏了这行，dev 浮层和关闭按钮联动都会失效
    files_dropped.connect(_on_files_dropped)
```

基类的 `_ready()` 负责建 dev 浮层和接 `close_requested`。GDScript 里子类重写会覆盖父类实现。

（`setup()` 没有这个问题，因为管理器是显式调用 `vivd_setup()` 的。）

### 10.2 子类要用路径式 `extends`

```gdscript
extends "res://vivd_windows/vivd_window.gd"     # ✅ 到处都能跑
extends VivdWindow                              # ⚠️ 依赖编辑器生成的类缓存
```

全局类名要等编辑器扫描过、把 `VivdWindow` 写进 `.godot/global_script_class_cache.cfg`
之后才解析得到。路径式不依赖那个缓存，headless / CI / 刚克隆下来都能直接跑。

基类仍然保留了 `class_name VivdWindow`，所以你在编辑器里 `@export var w: VivdWindow` 是可以的。

### 10.3 `find_window()` 不叫 `get_window()`

`get_window()` 是 `Node` 的既有方法。重名会触发 "overrides a method from native class" 警告，
而本工程把警告当错误，会直接解析失败。

**连带影响**：`find_window()` 的静态类型是 `Window`，所以对它调 `fade_in()`、`is_dev()`
这类 `VivdWindow` 上的方法会解析报错。用管理器转发，或者用 `.call()`。

### 10.4 `Window` 没有 `modulate`

`Window` 继承自 `Viewport`，**不是 `CanvasItem`**，所以没有 `modulate`。实测
`Window.get("modulate")` 返回 `null`。

因此 `fade_in()` / `fade_out()` 是把透明度作用在窗口的**直接子节点里的 `CanvasItem`** 上的。
含义是"窗口内容淡入淡出"，不是"整窗变成半透明"。

* 基准透明度在首次淡入淡出前记录，所以反复淡入淡出不会把透明度叠乘坏。
* 想要真正的"透明穿透"效果，需要窗口 `transparent = true`（工程已开
  `per_pixel_transparency/allowed`）。
* 淡入淡出后新加的子节点不参与当前这次动画。

### 10.5 窗口是真实的操作系统窗口

工程里 `display/window/subwindows/embed_subwindows=false`，每个 `Window` 都是独立的
OS 窗口，不是嵌在游戏画面里的。这是既定前提。

* `position` 是**屏幕坐标**。
* 窗口的 z 序由操作系统决定，`bring_to_front()` 只能通过 `grab_focus()` 间接影响。
* 用户拖拽标题栏移动、拖边缩放由系统提供。
* **headless 运行时 Godot 会强制把 `embed_subwindows` 改成 `true`**（实测确认），
  所以命令行自检看到的行为和正式运行不同——自检验证的是管理器逻辑，不是观感。

### 10.6 `window_removed` 发出时节点还没释放

`queue_free()` 是延迟的。想在回调里确认对象已销毁，等一帧再用 `weakref` 判断。

### 10.7 `default.tscn` 默认 `always_on_top = true`

也就是**所有默认窗口都会浮在其他所有窗口之上**（包括别的应用）。不想要就在 config 里覆盖：

```gdscript
VivdWindowsNode.add_window("tip", "default", {"always_on_top": false})
```

或者直接改 `types/default.tscn` 的根节点属性。

### 10.8 `wrap_controls` 默认关了

旧实现开着，但有内容被移除时窗口会收缩到很小。现在 `default.tscn` 是 `wrap_controls = false`，
尺寸完全由你（或 config）决定。

### 10.9 `call_window_method` 的参数会展开

```gdscript
call_window_method("tip", "set_text", ["你好"])
# → tip.set_text("你好")      ✅

# 旧实现是 call(method, args)，数组整体作为一个参数传进去：
# → tip.set_text(["你好"])    ❌ 语义不同，迁移时注意
```

窗口方法想收数组，包一层：`call_window_method("tip", "set_list", [["a", "b"]])`。

### 10.10 类型名 = 文件名（用目录扫描时）

`scan_window_types()` 按文件名注册。所以 `types/` 里的场景文件名**就是**类型名，
这也是为什么它们叫 `default.tscn` 而不是 `default_window.tscn`。

### 10.11 内部状态是私有的

`_windows` / `_tweens` 是私有字段，用 `find_window()` / `list_windows()` / `window_count()` 查询，
不要直接访问。

---

## 11. 从外部驱动窗口

`vivd_windows` 的 API 都是普通方法调用，不绑定任何演出框架。谁能拿到 `VivdWindowsNode`
（autoload，全局可见）谁就能开窗关窗——你自己的剧本格式、时间轴、状态机、网络事件都行。

```gdscript
# 任何地方
VivdWindowsNode.add_window("photo", "image", {"image": "res://assets/photo.png"})
```

### 建议加一层薄桥

演出逻辑一旦散落在各处，直接调 API 会很快失控。建议写一个桥节点，
把**演出数据**和**执行**分开：

```gdscript
extends Node
## 把结构化演出指令翻译成 vivd 调用

func run(instructions: Array) -> void:
    for ins in instructions:
        await _run_one(ins)


func _run_one(ins: Dictionary) -> void:
    match ins.get("op", ""):
        "open":
            VivdWindowsNode.add_window(ins["name"], ins["type"], ins.get("config", {}))
        "close":
            VivdWindowsNode.remove_window(ins["name"])
        "move":
            var seconds: float = ins.get("duration", 0.3)
            VivdWindowsNode.move_window(ins["name"], ins["to"], seconds)
            await get_tree().create_timer(seconds).timeout
        "fade_in":
            VivdWindowsNode.fade_window_in(ins["name"], ins.get("duration", 0.3))
        "wait":
            await get_tree().create_timer(ins.get("duration", 1.0)).timeout
        _:
            push_warning("[Bridge] 未知指令：%s" % ins)
```

调用方只喂数据：

```gdscript
await bridge.run([
    {"op": "open", "name": "photo", "type": "image",
     "config": {"image": "res://a.png", "position": Vector2i(200, 150)}},
    {"op": "fade_in", "name": "photo", "duration": 0.3},
    {"op": "wait", "duration": 0.5},
    {"op": "move", "name": "photo", "to": Vector2i(600, 400), "duration": 0.6},
])
```

好处是演出内容能放进资源文件或 JSON，改演出不用改代码，
非程序员也能编。完整的「数据驱动演出」设计见 [FEATURES_PLAN.md](FEATURES_PLAN.md) 第 4 条。

---

## 12. 视频窗口

`video` 是**核心窗口类型**，在独立的真实 OS 窗口里播放视频。

它有**两个后端，按文件后缀自动选**，也可以用 `backend` 强制指定：

| 后端 | 解码器 | 认识的格式 | 额外体积 |
| --- | --- | --- | --- |
| `builtin` | Godot 内置 Theora | `.ogv` | **0 MB** |
| `vlc` | LibVLC（[godot-vlc](https://github.com/xiSage/godot-vlc) 插件） | mp4 / mkv / mov / webm / avi / flv / ts … 几乎万能 | 202 MB |

`auto`（默认）的规则：`.ogv` 走 `builtin`，其余后缀走 `vlc`；插件不在时自动退回
`builtin`，并给一条明确的报错。两个后端都是纯 CPU 解码，任何渲染器
（包括 `gl_compatibility`）都能跑。

```gdscript
# mp4 —— 自动选中 vlc 后端
VivdWindowsNode.add_window("movie", "video", {
    "video": "res://system_test_1/VID20250306230957.mp4",
    "position": Vector2i(300, 200),
    "size": Vector2i(540, 960),
    "autoplay": true,
    "loop": false,
    "volume_db": -6.0,
})
VivdWindowsNode.call_window_method("movie", "seek_ms", [12000])

# ogv —— 自动选中 builtin 后端
VivdWindowsNode.add_window("clip", "video", {"video": "res://assets/opening.ogv"})
```

### config 支持的键

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `video` | `String` | — | 视频路径 |
| `backend` | `String` | `"auto"` | `auto` / `builtin` / `vlc` |
| `autoplay` | `bool` | `true` | 载入后立刻播放 |
| `loop` | `bool` | `false` | 播完重播（VLC 没有原生 loop，靠 `stopped` 信号重播） |
| `volume_db` | `float` | `0.0` | 音量（分贝） |
| `expand` | `bool` | `true` | true = 铺满拉伸；false = 等比居中带黑边 |
| `bus` | `String` | 默认 | 输出到的音频总线 |
| `audio_track` | `int` | `0` | 多音轨时选哪条（**仅 builtin 后端**；VLC 自己选轨） |
| `speed_scale` | `float` | `1.0` | 播放速度 |

### 方法

`open` / `play` / `pause` / `resume` / `toggle_pause` / `stop` / `is_playing` /
`is_paused` / `get_time_ms` / `get_length_ms` / `seek_ms` / `seek_ratio` /
`set_volume_db` / `get_volume_db` / `set_rate` / `get_frame_texture` / `get_player`

信号：`video_state_changed(playing: bool)`、`video_finished()`。

`get_player()` 返回原始播放器节点：`builtin` 是 `VideoStreamPlayer`，
`vlc` 是 `VLCMediaPlayer`（章节、轨道选择、字幕那些都能直接用）。
窗口的 `active_backend` 属性是本次实际生效的后端名。

后端选择的判断逻辑抽成了纯函数 `resolve_backend(path, want)`（静态方法），
不依赖插件真的装好，方便单测。

> ⚠️ `seek_ms(ms, fast)` 的第二个参数只有 `vlc` 后端用得上
> （`true` = 允许非精确跳转，更快）。`builtin` 忽略它。
>
> ⚠️ 用 `Object.call()` 调这些方法时**不会**展开数组，多参数要用 `callv()`；
> 或者直接用管理器的 `call_window_method(name, method, [args])`，它会展开。

### 该装哪个解码器？

**务必先读 [VIDEO.md](VIDEO.md)** —— 那里有全部实测数据和体积明细。简版：

| 方案 | 体积 | 实测 |
|---|---|---|
| 内置 Theora（`.ogv`） | **0 MB** | ✅ 稳定 |
| **godot-vlc（`.mp4`）** | 202 MB | ✅ **稳定，本工程在用** |
| Native Video（`.mp4`） | 1.7 MB | ❌ 本机崩溃/挂死 |
| EIRTeam.FFmpeg（`.mp4`） | 10.3 MB | ❌ 不崩，但画面全空 |

---

## 13. 文本阅读窗口

`text` 是**核心窗口类型**，用来显示和滚动阅读多行文本。正文用 `RichTextLabel`，
**默认按 BBCode 解析** —— `[b]` `[i]` `[color=…]` `[center]` `[img]` 直接能用。
对齐也走 BBCode 的 `[center]…[/center]`（`RichTextLabel` 自己没有对齐属性）。

```gdscript
VivdWindowsNode.add_window("reader", "text", {
    "title": "序章",
    "text": "[center][b]第一章[/b][/center]\n\n那天晚上，整栋楼都停了电。",
    "position": Vector2i(400, 120),
    "size": Vector2i(640, 360),
    "font_size": 20,
})
VivdWindowsNode.call_window_method("reader", "append_line", ["后来又想起一件事……"])
VivdWindowsNode.call_window_method("reader", "scroll_to_bottom")
```

窗口结构是 `Background`(ColorRect) → `Margin`(MarginContainer) → `Body`(RichTextLabel)。
默认深色底、浅色字，开箱就能读。

### config 支持的键

不传的键就用场景里的默认值（写在 `types/text.tscn` 里，可以在编辑器里直接改）。

| 键 | 类型 | 场景默认 | 说明 |
| --- | --- | --- | --- |
| `text` | `String` | `""` | 正文，BBCode 字符串 |
| `bbcode` | `bool` | `true` | false 则按纯文本处理（标签会原样显示出来） |
| `font_size` | `int` | `18` | 正文字号 |
| `line_separation` | `int` | `6` | 行距（像素） |
| `padding` | `int` | `16` | 四边内边距 |
| `bg_color` | `Color` | 深色半透明 | 背景色。也可以传 `"#1a1a2e"` 这种字符串 |
| `text_color` | `Color` | 浅色 | 正文字色，同样接受颜色字符串 |
| `speed` | `float` | `0.0` | 逐字显示速度（**字/秒**）。0 = 一次性显示 |
| `auto_scroll` | `bool` | `false` | 追加内容时自动跟随到底部 |
| `scrollbar` | `bool` | `true` | 是否显示右侧滚动条 |
| `selectable` | `bool` | `false` | 允许鼠标选中文字 |

### 方法

| 方法 | 说明 |
| --- | --- |
| `set_text(value)` | 整体替换正文 |
| `append(value)` | 末尾追加一段（不自动换行） |
| `append_line(value)` | 末尾追加一行（正文非空时自动补换行） |
| `clear_text()` | 清空 |
| `get_text() -> String` | 当前正文原文 |
| `get_line_count() -> int` | 排版后的行数（通常要等下一帧才准） |
| `reveal_all()` | 立刻补全到全部可见 |
| `is_revealing() -> bool` | 是否正在逐字显示 |
| `set_reveal_speed(speed)` | 改逐字速度 |
| `get_scroll_ratio() -> float` | 阅读进度，0 = 顶部，1 = 底部 |
| `set_scroll_ratio(ratio)` | 跳到指定进度 |
| `scroll_to_top()` / `scroll_to_bottom()` | 跳到顶/底 |
| `scroll_by(pixels)` | 相对滚动（正数向下） |
| `is_at_bottom() -> bool` | 是否已读到底 |
| `set_auto_scroll(value)` | 追加时是否自动跟随 |
| `get_label() -> RichTextLabel` | 拿到内部节点，做上面没包过的事 |

信号：`text_changed()`、`reveal_finished()`、`reached_bottom()`。

### 逐字显示（打字机）

把 `speed` 设成正数（字/秒）即可。显示过程中调 `reveal_all()` 立刻补全 ——
这是「点击继续」的标准做法：

```gdscript
VivdWindowsNode.add_window("reader", "text", {"text": "很长的旁白……", "speed": 25.0})

# 玩家点了继续
VivdWindowsNode.call_window_method("reader", "reveal_all")
```

`reveal_finished` 的语义统一成「正文已经全部可见」：`speed` 为 0 时，
每次 `set_text` / `append` 之后也会立刻发一次，所以调用方不用分情况处理。

### 滚动

长文本靠滚动阅读，滚轮和滚动条都能用。`reached_bottom` 在「从未到底变成到底」时
触发一次，适合用来亮出「继续」按钮：

```gdscript
var w = VivdWindowsNode.add_window("reader", "text", {"text": 长文})
w.reached_bottom.connect(func(): print("读完了"))
```

> ⚠️ `get_scroll_ratio()` 在**内容没有超出可视区**时恒为 `1.0`
> （没得滚，视为已经看完）—— 所以别用「ratio < 1」判断"还有更多内容"，
> 那个判断在短文本上会误报。

> ⚠️ `scroll_to_bottom()` 里补了一次延迟重试，因为文本刚变过时滚动条范围要到
> 下一帧才刷新。同一帧里连续调用是安全的。

### 这个窗口没有翻页

长文本用滚动。真需要翻页的话，`get_label()` 拿到 `RichTextLabel`，
结合 `get_content_height()` / `get_v_scroll_bar().page` 自己切。

---

## 14. 自动化测试

```bash
godot --headless --path . res://vivd_windows/vivd_smoke_test.tscn
```

101 条断言，覆盖创建/配置、错误路径、五种窗口类型、**视频双后端选择**、**文本窗口的
滚动与逐字显示**、移动缩放、方法调用、淡入淡出、调试浮层、移除与泄漏
（`weakref` 确认对象真的被释放）、类型注册。全通过退出码 `0`。

输出里会夹着几条 `ERROR` / `WARNING`，那是**故意触发错误路径**（重名、未注册类型、
不存在的方法）产生的，属于预期。视频用例在 headless 下还会刷一屏
`godot-vlc: audio buffer full` —— 那是 Godot 的假音频驱动没人消费音频，不是错误
（见 [VIDEO.md](VIDEO.md)）。

---

## 15. FAQ

**Q：窗口没出现？**
A：依次检查 ① `add_window` 返回值是不是 `null`（看控制台 `[VivdWindows]` 报错）
② 类型名拼对了吗（`list_window_types()` 打印一下）③ 位置是不是跑到屏幕外了
④ `visible` 是不是被之前的 `fade_out` 隐藏了。

**Q：位置对了但窗口没动？**
A：`move_window` 不传 duration 是 **0.5 秒动画**，不是立即。想立即传 `0`。

**Q：点窗口的 X 关掉了，但我的代码还在引用它？**
A：点 X 会自动 `remove_window`。用 `has_window()` 判断，或接 `window_removed` 信号。

**Q：`fade_window_in` 返回了 `true` 但没看到效果？**
A：检查窗口有没有**内容子节点**——淡入淡出作用在直接子节点上，空窗口看起来没变化。

**Q：能不能同时开两个同名窗口？**
A：不能，名字是唯一 key。想要多个同类窗口就取不同名字（`"pic1"`、`"pic2"`）。

**Q：`add_window` 是异步的吗？**
A：不是。返回时窗口已经实例化、入树、`setup()` 完毕，可以直接操作。

**Q：怎么知道窗口类型有哪些？**
A：`print(VivdWindowsNode.list_window_types())`。

**Q：改了窗口类型的场景，运行时没生效？**
A：需要重启，或者重新 `register_window_type`。热重载还没做（见规划第 11 条）。
