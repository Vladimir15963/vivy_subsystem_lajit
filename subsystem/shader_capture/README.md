# `subsystem/shader_capture/` —— godotshaders.com 抓取器

把 [godotshaders.com](https://godotshaders.com) 的 shader **详情页链接**批量粘进来，
自动扒下**名字 / 代码 / 介绍 / 作者 / 标签 / 类型 / 许可 / 支持的 Godot 版本**，
每个 shader 存成一个**独立的、Godot 直接能用**的 `.gdshader`，并在输出目录生成 `index.json` 清单。

- 想收一批现成效果进项目 → 粘链接、点一下，`captured/` 里就多出一堆 `.gdshader`。
- 想看某个 shader 是谁写的、什么许可、什么标签 → 不用回头翻网页，文件头注释和清单里都有。
- 想拿页面 HTML 离线试解析 → 解析器是纯函数，见 §5。

---

## 1. 两种跑法

```powershell
# ① 交互跑抓取器（= F6）
godot --path "L:\项目\测试" subsystem/shader_capture/shader_capture.tscn

# ② 无头跑测试（退出码 0 = 全绿）
godot --headless --path "L:\项目\测试" subsystem/shader_capture/tests/shader_capture_test.tscn
```

> 在 DSH 里请用 `godot_run_headless` / `godot_run_project` 等 `godot_*` 工具，不要用 pwsh 直接起 Godot
> （文件沙箱会拦掉 `user://` 写入，进程以 signal 11 崩）。

---

## 2. 界面

```
┌─ godotshaders.com 抓取器 ─────────────────────────────────────────┐
│ 每行一个 shader 详情页链接，例如 …/shader/squigglevision/          │
│ ┌───────────────────────────────────────────────────────────┐    │
│ │ https://godotshaders.com/shader/squigglevision/           │    │
│ │ https://godotshaders.com/shader/…                         │    │
│ └───────────────────────────────────────────────────────────┘    │
│ 输出目录 [res://subsystem/shader_capture/captured          ] [选择…]         │
│ [ ]覆盖已存在   [开始抓取] [停止] [打开输出目录]                    │
│ [██████████████░░░░░░░░░░░░░░]  3 / 7                            │
│ 日志（彩色）：跳过无效链接 / 成功 xxx → xxx.gdshader / 失败 …       │
└──────────────────────────────────────────────────────────────────┘
```

流程：粘链接 → 点「开始抓取」→ 串行 GET（每个之间隔 0.6 s、失败重试 1 次）→ 解析 → 写盘 → 打印汇总。
抓的过程中「开始抓取」禁用、「停止」可用；点停止会在当前这个链接抓完后收工，**已经抓到的照常落盘**。

---

## 3. 输出

### 3.1 `<slug>.gdshader`

文件名取 URL 里的 slug（`…/shader/squigglevision/` → `squigglevision.gdshader`），同一批里重名会自动加 `_2`、`_3`。
文件内容 = **头部注释 + 原样代码**：

```glsl
// ================================================================
// Squigglevision
// ================================================================
// 来源   https://godotshaders.com/shader/squigglevision/
// 作者   tentabrobpy  https://godotshaders.com/author/tentabrobpy/
// 发布   2025-10-16
// 类型   canvas_item
// 许可   cc0
// Godot  4.0 / 4.1 / 4.2 / 4.3 / 4.4 / 4.5 / 4.6
// 标签   cartoon, distortion, doodle, drawing, hand drawn, shimmer, sketch, squiggle, toon, wiggle
// ================================================================
// 介绍
// Per-object Squigglevision, also known as shimmer or boiling lines. …
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;
…
```

**代码一行没动**（只做 HTML 实体解码 + 行尾去空白），所以文件拿去 Godot 里就是能编译的 ——
测试里会真的 `load()` 一次、确认它编译得出 uniform 列表。

### 3.2 `index.json` 清单

```json
{
  "count": 1,
  "generated_at": "2026-10-06T06:00:04",
  "source": "https://godotshaders.com",
  "shaders": [
    {
      "file": "squigglevision.gdshader",
      "name": "Squigglevision",
      "slug": "squigglevision",
      "url": "https://godotshaders.com/shader/squigglevision/",
      "author": "tentabrobpy",
      "author_url": "https://godotshaders.com/author/tentabrobpy/",
      "date": "2025-10-16",
      "shader_type": "canvas_item",
      "license": "cc0",
      "godot_versions": ["4.0", "4.1", "4.2", "4.3", "4.4", "4.5", "4.6"],
      "tags": ["cartoon", "distortion", "…"],
      "code_lines": 38,
      "description": "Per-object Squigglevision, also known as shimmer or boiling lines. …"
    }
  ]
}
```

清单**不含代码正文**（代码在 `.gdshader` 里，避免重复占体积），但含代码行数便于一眼扫出「抓到了没有」。

---

## 4. 每个字段从哪来

| 字段 | 页面来源 | 兜底 |
| --- | --- | --- |
| 名字 | `<h1 class="entry-title">` | `<title>` 去掉 ` - Godot Shaders` 后缀 |
| 代码 | `<pre class="line-numbers code-block"><code>` | 任意 `<pre><code>` |
| 介绍 | 正文里 `<h5>Shader code</h5>` 之前的全部 `<p>` | — |
| 作者 / 作者页 | `<span class="author vcard">` 里的链接 | — |
| 发布日期 | `<time class="entry-date published" datetime="…">` | 该 `<time>` 的可见文本 |
| shader 类型 | **代码里的** `shader_type xxx;` | `<article>` class 上的 `shader_type-xxx` |
| 许可 | `<article>` class 上的 `shader_license-xxx` | — |
| Godot 版本 | `<article>` class 上的 `godot_version-godot_version_46` → `4.6` | — |
| 标签 | `<h6>Tags</h6>` 之后的标签链接（取**显示名**，如 `hand drawn`） | `<article>` class 上的 `shader_tag-xxx` |
| slug | URL 里的 `/shader/<slug>/` | 文件名安全化后为空则由调用方兜底成 `shader` |

> 类型优先取代码而不是 class：class 只能说明「这个页面被归到哪一类」，代码里的 `shader_type` 才是真的。

---

## 5. 文件与「纯逻辑」入口

| 文件 | 干什么 |
| --- | --- |
| `shader_capture.tscn` | 入口场景（= F6） |
| `scripts/shader_capture.gd` | UI + 串行抓取 + 落盘。纯逻辑入口 `split_urls` / `add_entry` / `write_results` 可脱离网络调用 |
| `scripts/shader_page_parser.gd` | 纯函数解析器：`parse` / `build_gdshader` / `build_index` / `normalize_url` … 不碰网络、不碰文件 |
| `tests/shader_capture_test.gd` | 无头测试（111 条断言，15 个用例组） |
| `samples/squigglevision.html` | 测试夹具：真实页面的裁剪版，保留全部用到的标签与 class |
| `captured/` | 默认输出目录（现在放的是抓 `squigglevision` 的实测产物） |

解析器单独用法：

```gdscript
const Parser := preload("res://subsystem/shader_capture/scripts/shader_page_parser.gd")
var meta := Parser.parse(FileAccess.get_file_as_string("res://some_page.html"), url)
if meta["ok"]:
	print(Parser.build_gdshader(meta))   # 完整 .gdshader 文本
```

---

## 6. 边界与已知限制

- **只认 godotshaders.com 的 `/shader/<slug>/` 详情页**。标签页 `/shader-tag/…`、列表页 `/shader/?…`、
  `/snippet/…`、别站链接都会被判无效并跳过（日志里列出来）。输入可以省略 `https://` 和 `www.`，会被自动补全。
- **页面结构靠正则，不靠 DOM 解析器**。站点改版（改 class 名、改标题层级）会让字段取不到 ——
  不会静默出错：要么 `ok=false` 并给出明确原因，要么字段留空。夹具页就是为这类回归留的锚点。
- **输出目录默认在 `res://` 下**，这是开发期工具。导出成发行版后 `res://` 只读，那时请把输出目录改成
  `user://` 或绝对路径。
- **故意不并发**：串行 + 0.6 s 间隔，避免被站点当爬虫。批量上百个会慢。
- **不抓图片/预览帧**：只抓文本信息与代码；页面上的 GIF 预览、Live Preview iframe 一律跳过。
- **`generated_at` 由落盘时写入**，所以两次运行的 `index.json` 不会逐字节相同；测试里传固定时间戳以保证可比对。