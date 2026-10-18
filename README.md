# Godot 子系统试验场

>是的这是vv的垃圾桶，我把沉积了有段时间的子系统丢在这个仓库中进行测试调试
这个仓库相当于收集了一些用godot做的小垃圾，且deepseek含量极高，相关内容可参考[垃圾分类](NOTICE.md)
我感觉最有意思的是/world_execute 的godot实现，虽然不完善，但是很酷！！

> **来源声明（Source & Attribution）
> 本仓库是一个**独立的 Godot 4 实验工程**，不是任何上游项目的一部分。
>
> 其中 [`subsystem/world_execute/`](subsystem/world_execute/README.md) 是对 **MisakaZentai** 的开源同人 PV 工程
> [`world-execute-me-dsh-pv`](https://github.com/MisakaZentai/world-execute-me-dsh-pv)（MIT）及其
> **终端实时版**（作者 **林原林海**）的 **Godot 4 重实现（port）**：镜头表、版式、逐帧数据与素材来自上游，
> 本仓库的 GDScript 播放器、Python 离线管线与自动化测试是**独立重写**的。
> 本移植**未经原作者审阅或背书**；上游代码与素材的许可各自保留，详见 [NOTICE.md](NOTICE.md)。
>
> This repository is an independent Godot 4 playground. `subsystem/world_execute/` is a **Godot 4 port**
> of MisakaZentai's open-source fan PV project and 林原林海's terminal realtime player (both MIT for code).
> It is **not** part of, nor endorsed by, the upstream projects. Asset licences are kept separately —
> see [NOTICE.md](NOTICE.md).

一个把若干**待验证子系统**装进同一个 Godot 4 工程的试验场。每个子系统尽量做到
**自带场景、自带测试、边界清晰**，可以单独跑、单独改、单独回归。

| 项 | 值 |
| --- | --- |
| 引擎 | Godot **4.7.2** stable |
| 渲染器 | `gl_compatibility` |
| 主场景 | `subsystem/scene_loader/demo/boot.tscn`（读条 → 演示主菜单） |
| 代码许可 | **MIT**（见 [LICENSE](LICENSE)）；素材另计（见 [NOTICE.md](NOTICE.md)） |

> **这是一个非官方同人实验仓库**，与 DeepSeek、Mili 及素材作者没有从属或合作关系，也未经其认可。
> 仓库中的 `world.execute(me)` 相关内容**仅供个人非商业学习与测试**。

---

## 目录

- [仓库里有什么](#仓库里有什么)
- [快速开始](#快速开始)
- [子系统一览](#子系统一览)
- [目录结构](#目录结构)
- [测试](#测试)
- [文档索引](#文档索引)
- [素材、版权与许可](#素材版权与许可)
- [贡献](#贡献)

---

## 仓库里有什么

- **`subsystem/world_execute/`** —— 本仓库最完整的子系统：用godot实现「大肥鱼」的 `world.execute(me)` 终端 PV
- **`subsystem/vivd_windows/`** —— 多窗口演出系统：按类型动态 OS 窗口，支持移动、缩放、淡入淡出。
- **`subsystem/fake_terminal/`** —— 不依赖 PTY 的伪终端，直接驱动 `godot_xterm` 的 `Terminal`。
- **`subsystem/battle_system/`** —— 回合制战斗：状态机、技能结算、目标校验、txt 存档、可继承 UI 基类。
- **`subsystem/player_system/`** —— 从正式项目剥离的玩家实例：移动/跳跃/眼睛/死亡，自带素材与沙盒。
- **`subsystem/scene_loader/`** —— 启动读条、后台预加载、可指定转场的切场景。
- **`subsystem/shader_preview/`** —— 通用 shader 效果预览器：按 uniform 自动生成参数面板。
- **`subsystem/shader_capture/`** —— godotshaders.com 详情页抓取器：落成可直接使用的 `.gdshader`。
- **`subsystem/gist/`** —— Gist 请求客户端 。
- **`subsystem/web3forms/`** —— Web3Forms 表单客户端（一次性邮件提交）。

> 详细说明、设计取舍与踩坑记录见 [ENGINEERING.md](ENGINEERING.md)。

---

## 环境

| 依赖 | 用途 |
| --- | --- |
| [Godot 4.7.2](https://godotengine.org/) | 运行全部子系统 |
| Python **3.12+**（可选） | 重建 `world_execute` 的数据表与字形图集 |
| Pillow / numpy（可选） | 同上,自行在环境中装 |


---

## 子系统一览

| 子系统 | 一句话 | 入口 |
| --- | --- | --- |
| [`world_execute`](subsystem/world_execute/README.md) | `world.execute(me)` 终端 PV 的 Godot 复刻（A/B/C 三层） | `world_execute.tscn` |
| [`vivd_windows`](subsystem/vivd_windows/README.md) | 真实 OS 多窗口演出管理器（6 种窗口类型） | `vivd_windows.tscn` / `window_type_test.tscn` |
| [`fake_terminal`](subsystem/fake_terminal/README.md) | 伪终端：纯 GDScript 写 xterm，无 PTY | `demo.tscn` |
| [`battle_system`](subsystem/battle_system/README.md) | 回合制战斗：状态机 + 技能 + txt 存档 | `battle_test.tscn` |
| [`player_system`](subsystem/player_system/README.md) | 玩家实例：移动 / 跳跃 / 眼睛 / 死亡 | `demo/player_sandbox.tscn` |
| [`scene_loader`](subsystem/scene_loader/README.md) | 读条加载 / 预加载 / 转场切场景 | `demo/boot.tscn` |
| [`shader_preview`](subsystem/shader_preview/README.md) | 通用 shader 预览 + 自动参数面板 | `shader_preview.tscn` |
| [`shader_capture`](subsystem/shader_capture/README.md) | godotshaders.com 抓取器 | `shader_capture.tscn` |
| [`gist`](subsystem/gist/README.md) | Gist 请求客户端 | `gist_test.tscn` |
| [`web3forms`](subsystem/web3forms/README.md) | Web3Forms 表单客户端 | `web3forms_test.tscn` |

---

## 目录结构

```text
.
├── README.md                  # 本文件：项目首页、来源声明、快速开始
├── ENGINEERING.md             # 详细工程手册：环境、子系统细节、测试矩阵、已知问题
├── NOTICE.md                  # 第三方素材与许可（务必先读）
├── LICENSE                    # 代码许可（MIT）
├── project.godot
├── addons/                    # dialogic / godot-vlc / godot_xterm（各自许可见 NOTICE）
├── autoload/                  # McpInteractionServer
├── subsystem/
│   ├── world_execute/         # 终端 PV 播放器（Godot 移植）
│   │   ├── README.md          #   子系统说明、按键、数据表、已知取舍
│   │   ├── DATA.md            #   数据/素材清单与本地重建步骤
│   │   ├── scripts/           #   GDScript（不再依赖 Python）
│   │   ├── shaders/           #   字形图集采样 + 全屏 post
│   │   ├── tools/             #   离线数据管线 + 版式/C 层规格
│   │   ├── tests/             #   headless 自测
│   │   └── data/              #   【不入库】生成的表、图集、音频、立绘
│   ├── vivd_windows/ …        # 其余子系统
├── dialogic/ · chapter/       # 剧本资源与草稿
└── system_test_1/ · lajitest/ # 历史遗留 / 草稿（见 ENGINEERING.md）
```

---

## 测试

详见 [ENGINEERING.md §5](ENGINEERING.md#5-测试矩阵实测)。

---

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [ENGINEERING.md](ENGINEERING.md) | 环境与启动、全局注册表、逐子系统说明、测试矩阵、已知问题、约定与经验 |
| [NOTICE.md](NOTICE.md) | **第三方素材与许可**：上游项目、鲸鱼娘美术、音乐/歌词、dsh 前端、字体、插件 |
| [subsystem/world_execute/README.md](subsystem/world_execute/README.md) | 播放器：A/B/C 三层、文件与数据表、按键、接线顺序、已知取舍、自测覆盖 |
| [subsystem/world_execute/DATA.md](subsystem/world_execute/DATA.md) | 数据/素材清单、许可状态、本地重建步骤（`WE_REF` / `WE_OUT`） |
| [subsystem/world_execute/tools/ref/layout.md](subsystem/world_execute/tools/ref/layout.md) | 版式权威规格：`tui_live.py` 逐函数对照、常量、章节面板 §7 |
| [subsystem/world_execute/tools/ref/c_layer_plan.md](subsystem/world_execute/tools/ref/c_layer_plan.md) | C 层方案与拍板记录：效果映射、冲突折中、阶段计划、决策表 |
| [subsystem/vivd_windows/USAGE.md](subsystem/vivd_windows/USAGE.md) | 多窗口系统使用手册（1000+ 行） |
| [subsystem/vivd_windows/VIDEO.md](subsystem/vivd_windows/VIDEO.md) | 视频双后端选型与实测 |
| 各子系统 `README.md` | 各自的 API、边界、取舍与运行方式 |

---

## 素材、版权与许可

**代码**：本仓库的代码按 **MIT** 发布，见 [LICENSE](LICENSE)。上游代码（MisakaZentai、林原林海）同样是 MIT；
`LICENSE` 中保留了他们的版权行。

**素材不是 MIT**，且**不随本仓库分发**。`subsystem/world_execute/data/` 已被 [.gitignore](.gitignore) 排除，因为其中包含：

| 内容 | 来源 / 权利人 | 许可 |
| --- | --- | --- |
| 鲸鱼娘立绘、表情、头像、由其衍生的字符网格 | 溟月 © 上善无形；女仆版 ZipZipPipe；立绘 Small-tailqwq / dsh-deep-whale；表情 JAdpp / dsh-whale-galgame | **CC BY-NC-SA 4.0**（署名 / 非商业 / 相同方式共享） |
| 歌曲《world.execute(me);》 | **Mili** | 按 [Mili Copyright Guidelines](https://projectmili.com/copyright-guidelines) 个人非商业使用；**本仓库不授予再许可** |
| 歌词与逐词时间轴 | Mili / 上游构建 | 同上；请自备或按上游说明获取 |
| dsh 前端样式与图标 | **DeepSeek** | MIT（商标不随代码授权） |
| 字形图集（由系统字体烘出） | Windows Consolas / 微软雅黑 / Segoe UI Symbol | **不随仓库分发**；需在本地重烘 |
| 字体 Space Mono / Anton | Google Fonts 作者 | SIL OFL 1.1 |
| `addons/godot_xterm` | Leroy Hopson 等 | MIT |
| `addons/godot-vlc`（含 LibVLC 二进制） | VLC / VideoLAN | LGPL 2.1（二进制随插件分发，请遵守 LGPL） |

完整署名链、上游链接与许可全文索引见 **[NOTICE.md](NOTICE.md)**。

> **发布/商用前请注意**：鲸鱼娘美术是 **CC BY-NC-SA 4.0**（禁止商用）；音乐与歌词不在本仓库，
> 且需要遵守 Mili 的使用指引；`world_execute` 的 `data/` **不应**被提交到公开仓库。
> 本仓库仅用于个人非商业的学习与实验。

---

## 贡献

毕竟是个人垃圾桶，并不欢迎 Issue 与 PR（（

---

## 致谢

- **MisakaZentai** —— 原片《world.execute(me);》TUI 版、97 镜头数据与开源重建
  <https://github.com/MisakaZentai/world-execute-me-dsh-pv>（MIT）
- **林原林海** —— 终端实时版播放器（`tui_live.py` / `film_panels.py` / `her_glyphs.py` / `dsh_text.py` 等）；
  本移植的版式与行为以其为直接参照
- **溟月 © 上善无形 / ZipZipPipe / Small-tailqwq / JAdpp** —— 鲸鱼娘角色与立绘、表情
- **Mili** —— 原曲与歌词
- **DeepSeek** —— dsh 前端界面与样式
- **Godot、godot_xterm、godot-vlc、Dialogic** 及所有上游开源作者

如果这份移植用到了你的作品而署名有误或缺失，请联系vivy_me@qq.com，我会尽快更正喵。
