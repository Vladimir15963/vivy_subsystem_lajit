# `subsystem/shader_preview/` —— 通用 shader 效果预览（可调参数）

一个**不针对任何具体 shader** 的效果试验台：把 `shaders/` 里的任意 `.gdshader` 挂到一张图上，
按它声明的 uniform **自动生成参数面板**，拖一下就实时生效。

- 想快速看某个后处理效果长什么样 → 打开就能挑。
- 想调参调到满意再抄进正式项目 → 「复制参数」/ 预设 / 截图三条出口。
- 想往项目里加自己的效果 → 往 `shaders/` 丢一个 `.gdshader` 就行，不用改代码。

---

## 1. 三种跑法

```powershell
# ① 交互跑预览器（= F6）
godot --path "L:\项目\测试" subsystem/shader_preview/shader_preview.tscn

# ② 无头跑测试（退出码 0 = 全绿）
godot --headless --path "L:\项目\测试" subsystem/shader_preview/tests/shader_preview_test.tscn
```

> 在 DSH 里请用 `godot_run_headless` / `godot_run_project` 等 `godot_*` 工具，不要用 pwsh 直接起 Godot
> （文件沙箱会拦掉 `user://` 写入，进程以 signal 11 崩）。

---

## 2. 界面

```
┌─ 效果 [下拉] │ 源图 [下拉] │ 打开图片… 重置 随机 复制参数 截图 ──────────┐
│  [x]动画  速度[——]1.00x │ 最近邻过滤 │ [x]棋盘底                          │
├──────────────────────────────┬──────────────────────────────────────────┤
│                              │ 一句话说明 + 文件名                        │
│      预览区（棋盘底 = 看 alpha）│ 过滤 [________________]                   │
│      TextureRect + ShaderMaterial │ block_size   [滑块] [ 8 ]             │
│                              │  color_levels [滑块] [ 0 ]                │
│                              │  show_grid    [x]                         │
│                              │  grid_color   [色块]                      │
│                              ├──────────────────────────────────────────┤
│                              │ 预设 [名字][保存][删除] / [列表][加载]      │
├──────────────────────────────┴──────────────────────────────────────────┤
│ 效果名 · 源图 WxH · N 个可调参数 · FPS · 快捷键提示                        │
└─────────────────────────────────────────────────────────────────────────┘
```

**快捷键**：`空格` 播放/暂停 · `R` 重置参数 · `S` 随机参数 · `[` `]` 切换效果 · `F12` 截图

**出口三件事**

| 按钮 | 落点 | 用途 |
| --- | --- | --- |
| 复制参数 | 剪贴板 | 直接得到 `shader_material.set_shader_parameter("x", 0.45)` 这样的行 |
| 保存/加载预设 | `user://shader_preview_test/presets/<名字>.json` | 调好的一套参数存下来，跨次启动可复用 |
| 截图 | `user://shader_preview_test/shots/<效果>_<时间戳>.png` | 只截预览区，用来对比/存档 |

预设名里的 `/ \ : * ? " < > |` 空格会被替换成 `_`，开头的点会被去掉，**拼不出预设目录以外的路径**。

---

## 3. shader 侧约定（重要）

任何 `.gdshader` 都能被预览，只要满足两条：

1. `shader_type canvas_item;`（预览区是一个 `TextureRect`，材质是 `ShaderMaterial`）；
2. 声明下面三个**保留 uniform**，由预览器自动绑定，**不会**出现在参数面板里：

| 保留 uniform | 类型 | 预览器喂什么 |
| --- | --- | --- |
| `src_tex` | `sampler2D` | 当前源图 |
| `texel_size` | `vec2` | `1/源图尺寸`（做模糊/描边这类要算像素距离的用） |
| `time` | `float` | 秒（受「动画」勾选框与「速度」控制） |

```glsl
shader_type canvas_item;

// ---- 自动绑定 ----
uniform sampler2D src_tex : hint_default_white, filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform float amount : hint_range(0.0, 1.0, 0.01) = 0.5;

void fragment() {
    COLOR = texture(src_tex, UV) * amount;
}
```

> 用 `src_tex` 而不是内置的 `TEXTURE`：语义明确，而且采样过滤由 shader 自己用
> `filter_linear` / `filter_nearest` 声明（不受工程 `default_texture_filter=nearest` 影响）。

### 面板是怎么生成的

| shader 里写成 | 面板控件 |
| --- | --- |
| `uniform float x : hint_range(0, 1, 0.01)` | 滑块 + 数字框（双向同步） |
| `uniform int x : hint_range(2, 32, 1)` | 滑块 + 整数框 |
| `uniform int x : hint_enum("水平","垂直","径向")` | 下拉框 |
| `uniform bool x` | 勾选框 |
| `uniform vec3/vec4 x : source_color` | 颜色选择器 |
| `uniform vec2/3/4 x` | 每个分量一个数字框 |
| `uniform sampler2D x` | 跳过（采样器一律由预览器绑定） |

参数名过长会显示成 `scanline_stren…`，悬停 tooltip 里有完整名字与类型/范围。

### 默认值从哪来（踩过的坑）

Godot **没有** API 能读到 shader 源码里写的 `= 默认值`，三条路都试过，全是死路：

| 尝试 | 结果 |
| --- | --- |
| `Shader.get_shader_uniform_list(true)` | 返回的字典里**没有**默认值字段（`true` 与 `false` 结果一样） |
| `RenderingServer.shader_get_parameter_default(rid, name)` | 一律返回 `null` |
| `ShaderMaterial.get_shader_parameter(name)`（未手动设置时） | 返回 `null` |

所以 `shader_param_panel.gd` 直接**解析源码**：扫出 `uniform ... = <表达式>;` 的表达式，
把它翻译成 Godot 能求值的形式（`vec2/vec3/vec4` → `Vector2/Vector3/Color`，`PI` → 数值，
单参数构造展开成完整分量），交给 `Expression` 求值。
求值前还会做一次体检（括号配平 + 字符白名单 + 只允许已知构造名），
**坏表达式一律回落到类型零值，绝不往引擎里丢垃圾输入刷一屏 ERROR**。

副作用（好处）：面板里「重置」用的就是 shader 源码里的默认值，改 shader 默认值面板立刻跟着变。

---

## 4. 自带 10 个效果

| 文件 | 效果 | 一句话 |
| --- | --- | --- |
| `01_pixelate.gdshader` | 像素化 / 马赛克 | 方块化 + 可选色阶量化 + 网格线 |
| `02_dissolve.gdshader` | 溶解 / 燃尽 | 噪声阈值溶解，边缘发光带，可让亮部先溶解 |
| `03_outline.gdshader` | 描边 / 轮廓 | 按 alpha 找边界，内/外描边 + 辉光（外描边靠 `padding` 留余量） |
| `04_chromatic_aberration.gdshader` | 色差 / RGB 分离 | 径向（镜头色差）或均匀（VHS）R/B 错位 |
| `05_wave_distortion.gdshader` | 波动扭曲 / 水波 | 水平 / 垂直 / 径向 / 横竖，正弦推 UV |
| `06_posterize.gdshader` | 色阶分离 / 调色 | 亮度对比 gamma 饱和度 + 色阶量化 + 抖动 |
| `07_film_grain.gdshader` | 胶片颗粒 / 噪点 | 颗粒、彩噪、只压暗部、暗角 |
| `08_hologram.gdshader` | 全息投影 / 扫描线 | 染色 + 扫描线 + 闪烁 + 垂直投影辉光 |
| `09_gaussian_blur.gdshader` | 高斯模糊 | 单 pass 13 抽样，可只横向 / 只纵向 / 双向 |
| `10_digital_glitch.gdshader` | 数字故障 / Glitch | 方块撕裂 + 行跳变 + RGB 偏移 |

每个都带中文注释块，逐参数说明写什么、怎么调。

**加自己的效果**：把 `.gdshader` 丢进 `shaders/`，预览器会自动追加到效果列表末尾（名字取文件名）。
想要中文名 / 排在前面的顺序，就在 `scripts/shader_library.gd` 的 `ENTRIES` 里补一行。

## 5. 源图（被采样的输入）

程序化生成的 8 张（不依赖任何素材，子系统单独拷走也能跑）：

| 源图 | 用途 |
| --- | --- |
| 棋盘格 | 看模糊 / 像素化 / 色差 / 扭曲最直观 |
| 彩条 / 渐变 | 调色、色阶、色相类 |
| UV 坐标 | r=u、g=v、b=0.5，畸变类一眼看出 UV 有没有推歪 |
| 色轮 | 颜色类效果 |
| 圆形蒙版（带 alpha） | **吃 alpha 的效果（描边 / 溶解）必须用它** |
| 圆环 + 十字（带 alpha） | 细线条形状，看描边粗细与模糊 |
| 噪点 | 对比噪声类 |
| 灰阶卡 | 8 级灰阶 + 底部渐变条，看量化 |

另外自动收录 `res://icon.svg` 与 `assets/` 下的图片（当前共 12 张），
也可以「打开图片…」从磁盘临时载入任意图片（`Image.load`，支持 png/jpg/webp/bmp/tga，不支持 svg）。

---

## 6. 测试

```powershell
godot --headless --path "L:\项目\测试" subsystem/shader_preview/tests/shader_preview_test.tscn
```

**87 条断言 / 14 组用例 + 1 条完整性哨兵，实测全绿，退出码 0**（无头下 stderr 只有工程既有的 9090 端口占用提示）。

| 组 | 覆盖 |
| --- | --- |
| 1 界面 | 代码建的 UI 关键节点都在，预览挂的是 `ShaderMaterial` |
| 2 效果清单 | 目录里 10 个 shader 全部可加载、都声明了三个保留 uniform，界面数量对得上 |
| 3 声明合法性 | 每个可调参数都写了 `= 默认值`；`hint_range` 的 `min<max`、`step>0`；`hint_enum` 至少两个候选 |
| 4 默认值 | 解析结果的 Variant 类型与 uniform 类型一致，数值落在声明的 `hint_range` 内 |
| 5 参数面板 | 控件数 = 可调参数数；bool/枚举/滑块/整数滑块/颜色五种控件都出现过；过滤器能收起再还原 |
| 6 参数往返 | 面板取的值真的写进了 material；写回再读回不漂移 |
| 7 切效果 | 换新材质、`time` 归零、保留 uniform 重新绑定、`texel_size` 正确、越界索引被拒 |
| 8 切源图 | 12 张源图逐个切，`texel_size` 都同步；追加外部纹理后立即可选 |
| 9 动画 | `tick` 按倍速推进、暂停不推进、0 倍速不推进、`material.time` 与状态一致 |
| 10 状态导入导出 | 改一堆再导入完全还原；`Vector/Color` 的 JSON 编解码往返一致 |
| 11 预设 | 存盘 / 读回一致 / 删除生效 / 预设名被安全化 |
| 12 默认值解析器 | 14 条合法表达式（含 `PI`、单参构造、`vec4`）逐个对答案；6 条坏表达式一律回落 `null` 且不崩 |
| 13 程序化源图 | 形状 / alpha / 颜色分布断言（**圆环那条抓过一次真回归**，见 §8） |
| 14 实时联动 | 模拟用户拖滑块 / 改数字框 / 点勾选框 / 选下拉 / 弹窗取色，material 必须立即更新 |
| 哨兵 | 用例组数与计划一致（14/14），协程中断/提前 return 会判失败 |

约定：断言里的参数个数、默认值一律**动态读取**（不写死数字），新增 shader 或改默认值不会误报。

---

## 7. 验证截图（`_shots/`）

`_shots/verify_all_effects.png` 是逐效果的**左＝无 shader 原图 / 右＝应用效果**对照大图，
每格标了平均差值；原始截图在 `_shots/v3/`（`*_ref.png` / `*_eff.png` 成对）；
`_shots/_ui_default.png`、`_shots/_ui_hologram.png` 是整窗界面截图。

实测的平均像素差（同一源图，无 shader 参考 vs 应用效果，1152×648 窗口、预览区 544×517）：

| 效果 | 平均差 | 明显变化像素占比 |
| --- | --- | --- |
| 01 像素化 | 2.36 | 5.97% |
| 02 溶解 | 35.38 | 27.23% |
| 03 描边 | 25.67 | 21.11% |
| 04 色差 | 3.22 | 7.27% |
| 05 波动 | 15.17 | 14.88% |
| 06 色阶 | 6.21 | 21.34% |
| 07 颗粒 | 9.52 | 35.07% |
| 08 全息 | 75.97 | 93.52% |
| 09 模糊 | 6.25 | 19.45% |
| 10 故障 | 23.70 | 38.49% |

这张表是**挑源图时的教训**：04 色差与 10 故障在「彩条/渐变」这种平滑源图上平均差只有 3.2 / 1.1，
看着像没生效；换成棋盘格这种有硬边的源图，平均差立刻变成 3.2 / 23.7 ——
**平滑源图会把位移类效果藏起来**，验证这类效果必须用带硬边或 alpha 的源图。

---

## 8. 踩过的坑（都留了回归用例）

1. **`make_ring` 的圆环公式写反过**：写成了 `min(外, 1-内)`，两个 smoothstep 相乘才对，
   结果整圈恒透明，只有十字画出来了；而「纹理存在 + 尺寸正确」这类断言完全抓不到。
   现在第 13 组会专门断言「环带实心 + 内孔透明」。
2. **Godot 读不到 shader 的默认值**（三条 API 全是死路，见 §3）→ 只能解析源码。
3. **`%g` 不是 Godot 的格式符**：`"%.4g" % x` 会在运行时报
   `String formatting error: unsupported format character`，得自己写 `format_number()`。
4. **`ColorPickerButton.color = x` 是静默的**：只有弹窗取色器发 `color_changed`。
   面板里的颜色联动测试走的是真实路径（`get_picker().color_changed.emit(...)`）。
5. **局部变量叫 `name` 会遮蔽 `Node.name`**：GDScript 会警告；已经全改成 `uniform_name` / `key`。
6. **交互运行时的 eval 别用裸 `get_viewport()`**：DSH 的 eval 包装会对基对象取 `_mini_window`，
   踩到就直接进 debugger 断点、命令服务器不再应答（截图那几次就是被这个坑住的，
   改成 `root.get_viewport()` 就没事）。

## 9. 已知限制

| 限制 | 说明 |
| --- | --- |
| 只做 2D `canvas_item` | 3D shader / `spatial` 不适用（预览区是一个 `TextureRect`） |
| 单 pass | 模糊/辉光都是单 pass 近似，不是多 pass 后处理链 |
| 截图需要真实窗口 | headless 下没有可读 framebuffer，`save_preview_png` 会返回 false 并提示 |
| 无屏幕纹理种类 | 自带效果全部只采样 `src_tex`；要 `SCREEN_TEXTURE` 的效果得自己接屏幕纹理 |
| 参数名过滤 | 只按参数名子串匹配，不搜注释/说明 |
| 描边的外扩余量 | 图形铺满画布时外描边会被四边形裁掉，靠 `padding` 参数内缩留白（默认 0.06） |
