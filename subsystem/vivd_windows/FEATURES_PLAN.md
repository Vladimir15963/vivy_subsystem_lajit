# vivd_windows 新功能规划

本文是**规划**，不是已实现的功能。已经落地的部分见 [README.md](README.md)，
用法见 [USAGE.md](USAGE.md)。

当前系统能做的事：开窗/关窗、移动、缩放、淡入淡出、调用窗口方法、调试浮层、
类型注册、视频窗口。下面按「值不值得做」排序。

> **设计底线：核心代码零第三方依赖。** `types/`、管理器和窗口基类都不 `import` 任何插件、
> 不引用工程里别的模块的代码或资源 —— 这样它可以被单独拎走、单独测试。
> 视频窗口是这条底线的样板：它**从不写插件的类名**（那会在工程导入期变成解析错误），
> 只用 `ClassDB` 动态探测。插件装了就用、没装就自动退回内置解码器，代码一行都不用改
> （见 [VIDEO.md](VIDEO.md)）。

---

## 优先级总览

| # | 功能 | 价值 | 工作量 | 依赖 | 风险 |
|---|---|---|---|---|---|
| 1 | 窗口过渡效果（shader 转场） | 高 | 2–3 天 | 无（自己写 shader） | 低 |
| 2 | 窗口定位（锚点 / 相对） | 高 | 1 天 | 无 | 低 |
| 3 | 布局快照与恢复 | 高 | 半天 | 无 | 低 |
| 4 | 数据驱动演出（指令桥） | 高 | 1 天 | 无 | 低 |
| 5 | 窗口组 / 联动 | 中 | 1 天 | 无 | 低 |
| 6 | 层级与焦点管理 | 中 | 1–2 天 | 无 | 中 |
| 7 | 拖拽移动 / 边缘缩放 | 中 | 1–2 天 | 无边框窗口 | 中 |
| 8 | 无边框 + 自定义标题栏 | 中 | 1 天 | #7 | 低 |
| 9 | 状态持久化 | 低 | 半天 | #3 | 低 |
| 10 | 非活动窗口降频 | 低 | 半天 | 无 | 低 |
| 11 | 调试工具增强 | 中 | 1–2 天 | 无 | 低 |
| 12 | 输入路由 | 低 | 1 天 | 多窗口同时收输入 | 中 |
| 13 | 演出录制 / 回放 | 低 | 2–3 天 | #3 | 中 |

---

## P1 · 下一步最值得做

### 1. 窗口过渡效果（shader 转场）

**问题。** 这套系统叫「多窗口**动态演示**」，但窗口进出只有一种效果：整体淡入淡出
（而且因为 `Window` 没有 `modulate`，它其实是作用在内容子节点上的）。
演出效果太单薄。

**做法。** 在 `subsystem/vivd_windows/shaders/` 下自己写一组转场 shader，
配套一个 `vivd_window_transition.gd`：

```
subsystem/vivd_windows/
├── shaders/
│   ├── wt_alpha_fade.gdshader      整窗淡入淡出
│   ├── wt_blinds.gdshader          百叶窗
│   ├── wt_wave.gdshader            波浪推进
│   ├── wt_erase.gdshader           擦除
│   ├── wt_vortex.gdshader          漩涡
│   ├── wt_windmill.gdshader        风车
│   ├── wt_glitch.gdshader          故障风
│   └── wt_blink.gdshader           闪烁
└── vivd_window_transition.gd       过渡层：喂两张纹理 + 推 progress
```

实现骨架：一个全屏 `ColorRect` + `ShaderMaterial`，把「起始画面」和「目标画面」
两张纹理传给 shader，用 tween 推 `progress` 从 0 到 1。

```gdscript
VivdWindowsNode.add_window("pic", "image", {
    "image": "res://icon.svg",
    "transition": "windmill",       # 效果名
    "transition_duration": 0.4,
})
VivdWindowsNode.set_transition("pic", "vortex", 0.3)   # 事后改
```

效果名统一用一套（`fade` / `blinds` / `wave` / `erase` / `vortex` / `windmill` /
`glitch` / `blink` / `none`）。

**注意。** 工程是真实 OS 窗口（`embed_subwindows=false`），
**抓「整个窗口」的纹理成本很高**。所以更实际的分工是：

* 窗口**出现/消失** → 用 `transparent = true` + shader 做整窗转场
* 窗口**内容切换**（比如图片窗口换图） → 只对内容区域做 shader 转场

两件事都要做，但要分清，不要混成一个 API。

**风险。** 低。纯新增，不动现有代码。

---

### 2. 窗口定位（锚点 / 相对）

**问题。** 现在位置是硬编码像素（`Vector2i(500, 500)`），换分辨率或换显示器就全废。
做演出时反复出现「在我机器上位置是对的」。

**做法。** 在 `add_window` 的 config 里支持相对定位：

```gdscript
VivdWindowsNode.add_window("tip", "default", {
    "anchor": "bottom_right",        # 九宫格：top_left/top_center/.../bottom_right/center
    "offset": Vector2i(-40, -40),    # 相对锚点的偏移
    # 或者相对某个已有窗口
    "anchor_window": "main",
    "offset": Vector2i(20, 0),
})
```

实现要点：

* 监听主窗口 `size_changed`，重新计算所有相对定位窗口的位置。
* 用 `DisplayServer.screen_get_usable_rect()` 拿可用区域（排除任务栏），
  多显示器下要先确定「参考屏幕」。
* 相对定位的窗口，`position` 不再由调用方直接写；要给个 `anchor: "manual"` 的逃生口。

**风险。** 低。纯计算，不改架构。**性价比第二高。**

---

### 3. 布局快照与恢复

**问题。** 调多窗口演出时反复开窗、拖位置、记坐标，全靠手抄。重开一次全丢。

**做法。**

```gdscript
var layout := VivdWindowsNode.dump_layout()
# [{ "name": ..., "type": ..., "config": {...}, "position": ..., "size": ... }, ...]

VivdWindowsNode.apply_layout(layout)
```

顺手加文件版：

```gdscript
VivdWindowsNode.save_layout("user://layout_demo.json")
VivdWindowsNode.load_layout("user://layout_demo.json")
```

配上 #11 的实时拖拽，就是一套「所见即所得」的演出编排工具。
`dump_layout()` 现在（半小时）就能写，不用等别的功能。

**风险。** 低。

---

### 4. 数据驱动演出（指令桥）

**问题。** 系统是给「多窗口演出」用的，但只能从 GDScript 一行行调 API。
演出一复杂，调用逻辑就散落在各处；而且演出内容（什么时候开什么窗、放在哪）
和代码绑死，改演出就得改代码、重新跑。

**做法。** 加一个 `VivdStageBridge`：吃结构化指令，翻译成 vivd 调用。

```gdscript
var bridge := VivdStageBridge.new()
add_child(bridge)

await bridge.run([
    {"op": "open", "name": "photo", "type": "image",
     "config": {"image": "res://a.png", "position": Vector2i(200, 150)}},
    {"op": "fade_in", "name": "photo", "duration": 0.3},
    {"op": "wait", "duration": 1.0},
    {"op": "move", "name": "photo", "to": Vector2i(600, 400), "duration": 0.6},
    {"op": "close", "name": "photo"},
])
```

指令表可以直接从 JSON / `.tres` 资源加载，于是：

* 演出内容和代码解耦，改演出不用重新编译逻辑
* 非程序员也能编演出
* 录制回放（#13）天然接上——录下来的就是指令流

**要做的事：**

1. 定义指令集（open / close / move / resize / fade_in / fade_out / call / wait / group…）
2. `run(instructions) -> void`，逐条 await（这样才有序）
3. 支持 `parallel` 块，一条指令里并发跑多个窗口操作
4. 校验：未知 op、缺字段、窗口不存在，都要给出清楚警告而不是静默失败

**风险。** 低。纯新增。

---

## P2 · 有用但不急

### 5. 窗口组 / 联动

一次操作一组窗口，避免逐窗调用。

```gdscript
VivdWindowsNode.add_to_group("hud", ["tip", "status"])
VivdWindowsNode.fade_group_in("hud", 0.3)
VivdWindowsNode.move_group("hud", Vector2i(0, -20), 0.4)
```

演出里「一组窗口整体上移」很常见。实现就是在现有 API 外面套一层遍历。
注意组内某个窗口被销毁时不要报错。

### 6. 层级与焦点管理

现在有 `bring_window_to_front()`，但没有 z 序概念，也没有模态窗口。
`default.tscn` 里写死 `always_on_top = true`，所有窗口都会盖住一切。

要做：z 序显式管理、模态窗口（挡住其他窗口的输入）、焦点跟随、失焦视觉提示。

**但要注意限制**：真实 OS 窗口的 z 序由操作系统决定，
`bring_to_front()` 只能通过 `grab_focus()` 间接影响。
所以这块能力天然有限——**先确认到底需要多强的层级控制**，可能只做「点一下提到最前」就够。

### 7. 拖拽移动 / 边缘缩放

真实 OS 窗口自带标题栏拖拽和边缘缩放，所以这个只在**无边框窗口**下才有价值。
如果用 `borderless = true` 做自定义外观，就需要自己实现：
拖拽标题区移动、边缘命中区缩放（8 个方向的鼠标指针要换）。

config 里加 `draggable` / `resizable_edges` / `drag_area_height`。

### 8. 无边框 + 自定义标题栏

配合 #7。`default.tscn` 现在 `borderless = false`。
无边框 + `transparent = true` + 圆角/阴影 shader，能做出更有质感的窗口。

工程已开 `per_pixel_transparency/allowed=true`，底子有了。
要注意无边框窗口在**真实 OS 窗口**模式下没有系统提供的关闭/最小化按钮，
得自己画。

### 9. 状态持久化

记住每个窗口上次的位置/尺寸，下次开在同一处。依赖 #3 的序列化。

对调试友好，但**对正式演出可能反而添乱**——演出的位置应该由演出数据决定，
不应该被上次运行的状态污染。所以做成明确 opt-in，默认关。

### 10. 非活动窗口降频

多窗口同时跑时，非活动窗口的 `_process` 白白烧 CPU。
可以给非活动窗口降 `Engine.max_fps`，或者把其子节点设成
`process_mode = PROCESS_MODE_DISABLED`。

**前提是确实测出瓶颈**。多窗口演出一般也就三五个窗口，很可能根本不需要。
不要过早优化。

---

## P3 · 想做再说

### 11. 调试工具增强

现在的 dev 浮层只显示几个属性。可以扩展成：

* 窗口树可视化（谁在最前、谁被遮挡、谁隐藏了）
* **实时拖拽改位置**，松手后直接打印出可粘贴进演出数据的 config
* 窗口类型热重载（改完窗口场景不用重启）
* 一键 dump 当前布局（接 #3）

这条和 #3、#4 组合起来就是「演出编排工具」，实际价值可能比看起来大得多。

### 12. 输入路由

多个窗口同时接收键盘输入时，得知道焦点在哪个窗口。
`Window.focus_entered` / `focus_exited` 已经有了，包一层焦点栈即可。

**只在真有多窗口输入需求时才做**——如果窗口只用于展示，这条可以直接砍掉。

### 13. 演出录制 / 回放

把一段时间内的所有窗口操作记录下来，可回放、可逐帧步进。
对调试复杂演出很有用。

依赖 #4 的指令格式先稳定下来，否则录下来的格式还要改。

---

## 明确不做

* **核心代码不依赖任何第三方插件或外部模块。** 见文首的设计底线。
  需要的能力自己写，或者复制文件进来并注明来源。
  插件只能作为**可选增强**存在：没有它功能要能往下退回，有它才多出能力
  （`video` 窗口的双后端就是范例）。
* **不做内嵌模式。** `embed_subwindows=false` 是既定前提，
  窗口就是真实的 OS 窗口，不会为了「统一行为」改成内嵌。
* **不做通用 UI 框架。** 窗口内容的布局是窗口类型自己的事，
  管理器只管窗口的生命周期和变换。
* **不在没有性能证据时做优化。** 见 #10。

---

## 待你决策

1. **#1 的转场作用在哪一层**：窗口边框内的内容，还是整个窗口？
   这决定了要不要 `transparent = true`、以及要不要抓窗口纹理。
2. **#2 的锚点基准**：相对屏幕，还是相对主游戏窗口？（多显示器下两者不同）
3. **#4 的指令格式**：用 `Dictionary`/JSON，还是做成 `Resource`（能在检查器里编辑、有类型提示）？
4. **#6 到底需要多强的层级控制？** 真实 OS 窗口的 z 序由系统决定，
   如果只需要「点一下提到最前」，那 #6 可以砍掉大半。
5. **#12 需不需要？** 窗口是只用来展示，还是要接收输入？这决定要不要做焦点管理。
