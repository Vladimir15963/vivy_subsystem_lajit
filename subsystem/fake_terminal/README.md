# `FakeTerminal` —— 不依赖 PTY 的伪终端

在 [`godot_xterm`](../../addons/godot_xterm) 的 `Terminal` 节点上实现的「假终端」：
**不起子进程、不走 PTY**，所有输出由 GDScript 直接以 UTF-8 写入。
因此中文不会乱码、内容 100% 可控，适合日志屏、状态屏、过场字幕与演出文本流。

`subsystem/world_execute/` 的 **B 层**就是用它逐帧显示 boot 日志、章节、歌词与 ops。

## 场景

| 场景 | 说明 |
| --- | --- |
| `demo.tscn` | 全中文演示：颜色、打字机、进度条、假命令 |
| `fake_terminal.tscn` | 裸 `FakeTerminal` 节点 |
| `vivd_terminal_demo.tscn` | 作为 `vivd_windows` 的 `terminal` 窗口打开（会弹独立 OS 窗口） |

```powershell
godot --path . subsystem/fake_terminal/demo.tscn
```

## 常用 API

```gdscript
$FakeTerminal.println("你好，世界")
$FakeTerminal.println_colored("警告", FakeTerminal.Ansi.YELLOW)
await $FakeTerminal.type_line("正在连接……", 0.03)
$FakeTerminal.progress_bar("加载中", 1.5, 30)

$FakeTerminal.register_command("help", _cmd_help, "显示帮助")
$FakeTerminal.set_fallback_handler(_unknown)
```

- **模式**：`Mode.INTERACTIVE`（提示符、历史、Tab 补全）与 `Mode.OUTPUT_ONLY`（只输出，不吃按键）。
  切换：`set_output_only(true)` / `set_mode_by_name("output")`。
- **ANSI**：`Ansi` 枚举 16 色；`colorize()` / `colorize_index()` / `bold()` / `underline()` / `dim()`。
- **信号**：`input_line` / `command_entered` / `unknown_command`。
- **字体**：ASCII 用主字体（默认 JetBrains Mono），CJK 走显式 fallback 列表
  （`Microsoft YaHei UI`、`SimHei`、`Noto Sans SC` 等）；`can_render()` 可探测。
- **输入控制**：`set_accept_input(false)` 后仍可输出，但按键不会进入终端；
  `world_execute` 的主场景按键因此不会被终端吃掉。

## 与真 PTY 的区别

`lajitest/` 里是另一路实验：`pty.fork("ping", ["google.com"])` 的真终端。
`FakeTerminal` 刻意**不**走那条路：没有子进程、没有平台差异、能精确编排每一行出现的时刻。

## 许可

本目录代码按仓库根 [LICENSE](../../LICENSE)（MIT）发布；
依赖的 `godot_xterm` 为 MIT（Leroy Hopson 与贡献者），见 [NOTICE.md](../../NOTICE.md)。
