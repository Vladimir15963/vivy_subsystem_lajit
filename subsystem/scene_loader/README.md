# SceneLoader —— 通用场景加载工具（autoload 全局单例）

一个不依赖任何插件、纯 GDScript 的通用场景加载工具，用 **autoload `SceneLoader`** 全局挂载，任何场景里直接 `SceneLoader.xxx()` 就能用。

覆盖三类需求：

| 需求 | 入口 |
| --- | --- |
| 进游戏时的**读条加载** | `SceneLoader.boot_to(path)` |
| 游戏进行中**预加载下一个场景**（后台线程，不卡帧） | `SceneLoader.preload_scene(path)` |
| 切场景，**可指定转场场景** / 或**无缝瞬时切换** | `SceneLoader.goto_scene(path, options)` |

## 1. 快速上手

```gdscript
# ① 启动读条：立刻显示读条界面，加载完成后自动进入主菜单
SceneLoader.boot_to("res://game/main_menu.tscn")

# ② 玩家还在关卡 A 里跑的时候，后台把关卡 B 读进内存（不阻塞主线程）
SceneLoader.preload_scene("res://game/level_b.tscn")
SceneLoader.preload_progress.connect(func(path, r): bar.value = r * 100.0)

# ③ 读条转场切换
SceneLoader.goto_scene("res://game/level_b.tscn", {"transition": "loading", "title": "载入关卡 B"})

# ④ 淡入淡出转场切换
SceneLoader.goto_scene("res://game/level_b.tscn", {"transition": "fade"})

# ⑤ 无缝切换：不带任何转场，预加载完成后 1~2 帧内完成切换
SceneLoader.goto_scene("res://game/level_b.tscn", {"seamless": true})

# ⑥ 指定自己的转场场景
SceneLoader.register_transition("wipe", preload("res://game/transitions/wipe.tscn"))
SceneLoader.goto_scene("res://game/level_b.tscn", {"transition": "wipe"})
```

## 2. 目录结构

```
subsystem/scene_loader/
├── scene_loader.gd                     # ★ autoload 单例本体（SceneLoader）
├── transitions/
│   ├── loading_screen.tscn/.gd         # 内置转场：读条加载界面（含最短匀速读条）
│   └── fade_transition.tscn/.gd        # 内置转场：全屏淡入淡出
├── demo/
│   ├── boot.tscn/.gd                   # 项目主场景 = 启动引导，触发 boot_to
│   ├── demo_menu.tscn/.gd              # 演示主菜单（四个按钮）
│   ├── level_a.tscn / level_b.tscn     # 演示关卡，共用 demo_level.gd
│   └── demo_level.gd
├── tests/
│   ├── scene_loader_smoke_test.tscn    # headless 自测入口
│   └── scene_loader_smoke_test.gd      # 42 项断言
└── _shots/                             # 运行时截图（验证用）
```

已写入 `project.godot` 的改动：

```ini
[autoload]
SceneLoader="*res://subsystem/scene_loader/scene_loader.gd"

[application]
run/main_scene="res://subsystem/scene_loader/demo/boot.tscn"
```

> 原来的项目没有主场景，这里补上了；如果不想让 `boot.tscn` 当主场景，改回 `run/main_scene` 即可，`SceneLoader` 本身不依赖主场景。

## 3. API 一览

### 启动读条

| 方法 | 说明 |
| --- | --- |
| `boot_to(path, options = {})` | 立刻显示转场（默认读条界面）→ 加载 `path` → 切过去 → 发 `boot_finished`。`options` 同 `goto_scene`，但 `seamless` 会被忽略（启动必须有读条界面）。 |

### 预加载

| 方法 | 说明 |
| --- | --- |
| `preload_scene(path) -> int` | 后台线程加载。重复调用幂等（命中缓存会补发一次 `preload_completed`，方便刚连接上的 UI 同步状态）。 |
| `preload_scenes(paths: Array)` | 批量。 |
| `is_preloaded(path) -> bool` | 是否已加载完并在缓存里。 |
| `is_preloading(path) -> bool` | 是否正在加载。 |
| `get_preload_progress(path) -> float` | 0~1，可直接喂进度条。 |
| `get_cached_scene(path) -> PackedScene` | 取出已缓存的场景。 |
| `release_preload(path)` / `clear_cache()` | 丢弃缓存，释放内存。 |
| `cancel_preload(path)` | 取消跟踪（Godot 无真正取消接口，后台线程仍会跑完，只是结果不再记录/通知）。 |

### 切场景

| 方法 | 说明 |
| --- | --- |
| `goto_scene(path, options = {})` | 协程，可 `await`（等待新场景就位）。 |
| `register_transition(id, scene)` | 注册具名转场，`scene` 可以是 `PackedScene` / 场景路径 / `null`（= 无缝）。 |
| `has_transition(id)` / `get_transition(id)` | 查询。 |
| `is_busy() -> bool` | 是否正在切场（切场期间重复请求会被忽略并告警）。 |
| `get_current_scene_path() -> String` | 当前场景路径，跟随 `SceneTree.current_scene`（外部直接 `change_scene_*` 也能同步）。 |

`options` 字段：

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `transition` | `PackedScene` / `String` / `null` | `default_transition` | 转场场景，或已注册的 id；`null` / `"none"` / `"seamless"` = 无缝 |
| `seamless` | `bool` | `false` | `true` 时强制不使用任何转场（覆盖 `transition`） |
| `params` | `Dictionary` | `{}` | 交给新场景（见下） |
| `title` | `String` | 文件名 | 转场标题 |
| `min_time` | `float` | `0.6` | 转场最短显示时间，防止场景太小“闪一下” |

### 信号

```gdscript
preload_started(path)                 preload_progress(path, ratio)
preload_completed(path, packed)       preload_failed(path, error)
preload_cancelled(path)

load_started(path, transition_name)   load_progress(path, ratio)
load_finished(path)                   boot_finished(path)
transition_in_finished()              transition_out_finished()
scene_changed(from_path, to_path)
```

### 可调配置（运行时直接赋值）

```gdscript
SceneLoader.default_transition = preload("res://.../my_loading.tscn")  # 默认转场（null = 默认无缝）
SceneLoader.min_transition_time = 0.6        # 转场最短显示时间
SceneLoader.boot_min_transition_time = 1.0   # 启动读条最短显示时间
SceneLoader.transition_layer = 128           # 转场 CanvasLayer 层级
SceneLoader.verbose = true                   # 调试日志
```

## 4. 转场场景的接口约定

转场场景由 `SceneLoader` 实例化到自己的 `CanvasLayer`（默认 layer 128）下，**全部接口都是可选的**，实现哪个用哪个：

```gdscript
extends Control

signal in_finished      # 进场动画结束（没有此信号时用 in_duration 属性兜底）
signal out_finished

var in_duration := 0.2
var out_duration := 0.3

func set_title(text: String) -> void         # 显示标题
func set_progress(ratio: float) -> void      # 0~1 喂读条
func set_min_display_time(sec: float) -> void# 本次转场至少显示多久
func play_in() -> void                       # 进场动画
func play_out() -> void                      # 退场动画
```

生命周期：`instantiate → set_title/set_progress/set_min_display_time → play_in() → (加载，期间不断 set_progress) → 黑场/覆盖状态下切场景 → play_out() → queue_free()`。

## 5. 把数据交给新场景

```gdscript
SceneLoader.goto_scene("res://game/level_b.tscn", {"params": {"from": "level_a", "spawn": "north"}})
```

新场景根节点二选一接收：

```gdscript
# 方式 1：实现回调（推荐）
func on_scene_entered(params: Dictionary) -> void:
    print(params.from, params.spawn)

# 方式 2：暴露属性
var scene_params: Dictionary
```

## 6. 演示 & 自测

**演示**：直接运行项目（F5）。启动即走 `boot.tscn → 读条界面 → 主菜单`；主菜单四个按钮分别演示读条转场 / 后台预加载 / 无缝切换 / 淡入淡出转场，关卡里还能看到预加载进度、缓存状态和转场参数。

**自测（headless，42 项断言）**：

```powershell
godot --headless --path . res://subsystem/scene_loader/tests/scene_loader_smoke_test.tscn
```

覆盖：注册表、场景资源可加载/可实例化、预加载完成与进度、重复预加载幂等、失败分支、转场切换（含 `min_time`、`params` 注入）、无缝切换耗时 < 0.5s、缓存释放、启动读条 `boot_finished`。退出码 0 = 全绿。

截图见 `_shots/`：`02_loading.png`（读条 16%）、`04_menu_preloaded.png`（预加载完成状态）、`05_fade_cover.png`（淡入淡出黑场覆盖时换场）、`06_level_b_params.png`（新场景收到转场参数）。

## 7. 设计要点 / 注意事项

1. **类名不能叫 `SceneLoader`**。autoload 名与 `class_name` 同名时 Godot 会报 `Class 'X' hides an autoload singleton`，所以脚本类名是 `SceneLoaderService`，autoload 名才是 `SceneLoader`。
2. **线程加载靠逐帧轮询**：`_process` 统一调用 `load_threaded_get_status()`，是所有进度信号与缓存写入的唯一出口；`goto_scene` 只是 `await` 缓存出现，不重复实现一套轮询。`SceneLoader` 的 `process_mode` 是 `ALWAYS`，暂停中也能切场景。
3. **请求先发、动画后播**：`goto_scene` 先发起 `load_threaded_request`，再播 `play_in`，两者并行，避免白等一个动画时长。
4. **无缝切换的前提是已预加载**。没预加载时 `seamless` 也能切，但会退化成同步等待（掉帧）；demo 里的按钮会先检查 `is_preloaded()`。
5. **`min_time` 是可见性下限，不是加载时间**：读条界面会按 `min_time` 做“最短匀速读条”，小场景不会出现进度条一闪而过；真实加载更慢时完全跟随真实进度。
6. **`cancel_preload` 不是真取消**：Godot 没有暴露线程加载的取消接口，这里只是停止跟踪。真正释放内存用 `release_preload()` / `clear_cache()`。
7. **切场景用的是 `change_scene_to_packed`**，所以老场景在帧末释放；`SceneLoader` 会等新场景真正成为 `current_scene` 之后才注入 `params`。
