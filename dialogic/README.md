# Dialogic 剧本转写说明（第一幕）

本目录是 Dialogic 2 的剧本资源目录，由 `doc/剧本/01第一幕.md` 按 Dialogic 官方
Timeline Text Syntax（https://docs.dialogic.pro/timeline-text-syntax.html ）转写而来。

## 文件一览

| 路径 | 说明 |
| --- | --- |
| `res://dialogic/timelines/01第一幕.dtl` | 第一幕时间线（166 个事件：**107 条台词** / 48 注释 / 5 背景 / 5 信号 / 1 结束） |
| `res://dialogic/characters/旁白.dch` | 旁白（原剧本 `N`） |
| `res://dialogic/characters/电线杆vv.dch` | 电线杆vv（原剧本 `dv`） |
| `res://dialogic/characters/邪恶vv.dch` | 邪恶vv（原剧本 `bv`） |
| `res://dialogic/characters/我.dch` | 主人公「我」/ 翌川屿芊 |
| `res://dialogic/characters/老师.dch` | 班主任 |
| `res://dialogic/characters/？？？.dch` | 身份不明者（原剧本 `？`） |

插件本体：`res://addons/dialogic/`（已在 `project.godot` 的 `[editor_plugins]` 中启用，
并自动注册了 `Dialogic` 自动加载与 `dialogic_default_action` 输入动作）。

## 转写规则（重要）

原稿是**一行一次发言**写的，缩进只表示「这一行仍然是上一位在说」：

| 原稿 | .dtl |
| --- | --- |
| 顶格行 `N 来自星尘，我是大地的孩子，向往天空` | `旁白: 来自星尘，我是大地的孩子，向往天空` |
| 紧接的 TAB 缩进行 `希望在群星消逝前写下更多创作` | `旁白: 希望在群星消逝前写下更多创作`（**另起一个 Text 事件**，重复写上同一位说话人） |

也就是说：**原稿每一行 ＝ 一个 Text 事件 ＝ 游戏里一次点击推进**，不会把几行合并成一屏多行文本。

### 关于 `\`（实测结论）

`\` 是**同一个 Text 事件内部的文本换行**，用了它就会把多行并进**一个**事件（一次点击）：

| 写法 | 插件实际解析结果 |
| --- | --- |
| `旁白: 第一行\` ＋ 下一行 `第二行` | 1 个事件，角色=旁白，文本=`第一行⏎第二行` |
| `旁白: 第一行\` ＋ 下一行 `旁白: 第二行` | 1 个事件，文本=`第一行⏎旁白: 第二行`（**第二个「旁白:」会显示在正文里**） |
| `旁白: 第一行` ＋ 下一行 `旁白: 第二行` | 2 个事件，各带角色（本文件采用） |

所以：本文件按「一行一句、每行都写角色」处理，不使用 `\`。

## 原稿 → .dtl 语法对应

| 原稿写法 | .dtl 写法 |
| --- | --- |
| 顶格行 `名字 台词` | `旁白: 台词`（新的一次发言） |
| TAB 缩进行 | `旁白: 台词`（沿用上一位说话人，另起一个 Text 事件） |
| `## 切入 云朵背景` | `[background arg="#cfe8ff" fade="1.0" wait="true"]`（颜色为占位，见下） |
| `>黑屏谈出` | `[background arg="#000000" fade="0.8" wait="true"]` |
| `>事件 打开留言1.txt` | `[signal arg="event:open_file:留言1.txt"]` |
| `>--- 事件：文件检测` | `[signal arg="event:file_check:Vladimir"]` |
| `>--- 事件：进入战斗` | `[signal arg="event:battle:邪恶vv"]` |
| `> 第一幕结束` | `[signal arg="event:act1_finished"]` ＋ `[end_timeline]` |
| 场景说明 / 分隔线 `---` | `#` 开头的注释行 |
| 代码块里的 `留言1.txt` 内容 | 同样逐行转成无说话人的 Text 事件（`>` 空行→事件之间的空行） |

## 剧情交互信号（需要游戏代码接管）

时间线只会抛出信号，具体表现（打开文件、拖拽检测、战斗、音乐）需要自己在代码里实现：

```gdscript
func _ready() -> void:
	Dialogic.signal_event.connect(_on_dialogic_signal)

func _on_dialogic_signal(arg: String) -> void:
	match arg:
		"event:play_music:裸体之舞":
			pass          # 播放 BGM
		"event:open_file:留言1.txt":
			pass          # 打开桌面上的 留言1.txt
		"event:file_check:Vladimir":
			pass          # 弹出文件检测窗口，拖入并校验 Vladimir
		"event:battle:邪恶vv":
			pass          # 进入回合制战斗（战败剧情）
		"event:act1_finished":
			pass          # 第一幕结束
```

## 播放方式

```gdscript
Dialogic.start("01第一幕")
```

## 待替换的占位内容

1. **背景**：目前用纯色占位（云朵 `#cfe8ff`、教室 `#f3e7cd`、天台 `#ffd9a0`、黑屏 `#000000`），
   有美术素材后改成 `[background arg="res://assets/bg/xxx.png" ...]` 即可。
2. **立绘**：各 `.dch` 的 `portraits` 为空，加入立绘后可在台词里用
   `旁白 (立绘名): ...` 或 `join 电线杆vv (默认) center` 显示。
3. **《裸体之舞》** 等音频：改为 Dialogic 的 `audio` 事件并填入音频路径。
