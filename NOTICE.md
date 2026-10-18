# NOTICE —— 第三方素材、代码与许可

本仓库的**代码**按 [LICENSE](LICENSE)（MIT）发布。
下面这些内容**不属于**那份 MIT 许可，各自保留原来的许可与权利。

> 本仓库是**非官方同人实验工程**，与 DeepSeek、Mili、VLC、Godot 及下列作者没有从属或合作关系，
> 也未经其审阅或背书。产品名、角色名与商标归各自权利人所有。

---

## 1. 上游项目与移植关系

`subsystem/world_execute/` 是以下两个上游项目的 **Godot 4 重实现（port）**，不是上游的一部分：

| 上游 | 作者 | 内容 | 许可 |
| --- | --- | --- | --- |
| [world-execute-me-dsh-pv](https://github.com/MisakaZentai/world-execute-me-dsh-pv) | **MisakaZentai** | 原片《world.execute(me);》TUI 版、97 镜头、dsh 逐帧页面、逐词时间轴、MMD 参考链 | **MIT**（代码） |
| 终端实时版（本移植的直接参照） | **林原林海** | `_tools/tui_live.py`、`film_panels.py`、`her_glyphs.py`、`dsh_text.py`、`pv_audio.py`、`tui_shot.py` 等 | **MIT**（代码） |

本仓库的 GDScript 播放器（`scripts/*.gd`）、Python 离线管线（`tools/*.py`）与测试（`tests/*.gd`）
是独立重写的；镜头表、版式、逐帧数据与素材来自上游。上游代码的 MIT 版权行已保留在 [LICENSE](LICENSE)。

---

## 2. 鲸鱼娘立绘、表情与衍生画面 —— CC BY-NC-SA 4.0

**涉及内容**（均位于 `subsystem/world_execute/data/`，**不随本仓库分发**）：

- 立绘源图与八种表情（`her_sprite/*.png`）；
- 由立绘/表情派生的字符网格、H3 take、半块亮度表、字形降级表；
- dsh 聊天窗的逐帧头像（`dsh_avatars/`）；
- 落鲸雪尘的轮廓采样、屏幕上的她的形象。

**完整署名链**（按 CC BY-NC-SA 4.0 保留）：

1. **角色原作**：溟月 © 上善无形
   - <https://www.pixiv.net/users/62155430>
   - <https://space.bilibili.com/4456176>
2. **女仆版设计**：ZipZipPipe
   - <https://www.pixiv.net/users/18604994>
   - <https://space.bilibili.com/4168597>
   - Pixiv《AI娘化》原帖：<https://www.pixiv.net/artworks/148186519>（要求署名、非商业）
3. **立绘**：Small-tailqwq / [dsh-deep-whale · maid-atelier](https://github.com/Small-tailqwq/dsh-deep-whale/tree/main/maid-atelier)
4. **八种表情**：JAdpp / [dsh-whale-galgame](https://github.com/JAdpp/dsh-whale-galgame)

**许可**：[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)
（署名 / 非商业性使用 / 相同方式共享）。

**本移植的改动**：裁切、缩放、像素化、调色、表情与头像合成、半块/字符网格化、轮廓采样。
这些改编部分同样按 CC BY-NC-SA 4.0 分享；不得商用。

---

## 3. 音乐与歌词 —— Mili，非本仓库授权

- **歌曲**：`world.execute(me);`，作者 **Mili**。
- **歌词**：歌词作者（Mili）；`words.json`、`lyrics_cn.json`、`h3_text.json` 等表由上游构建。
- **状态**：歌曲与歌词**不随本仓库分发**。`subsystem/world_execute/data/` 已被 `.gitignore` 排除。
- **使用**：按 [Mili Copyright Guidelines](https://projectmili.com/copyright-guidelines) 处理。
  个人非商业二创可按指引使用；全部或部分含 AI 的同人内容须明确标注；商业用途需另行确认。
- 本仓库**不授予**音乐或歌词的任何再许可。请不要把 `data/song.mp3` 或歌词表提交到公开仓库。

---

## 4. dsh 前端 —— MIT（DeepSeek）

- 上游工程中的 dsh 页面由 `@deepseek-ai/dsh-web-frontend`、`@deepseek-ai/dsh-client-ui-*` 等包渲染，
  这些包为 **MIT**，Copyright (c) 2026 DeepSeek。
- 本移植的 `draw_dsh()` 用字符格**重画**该界面的文本与头像，不包含前端 JS/CSS 源码；
  逐帧文本快照（`dsh.bin`）属于上游构建产物。
- 前端 bundle 内的 React / React DOM / scheduler 保留 Facebook, Inc. 及其关联公司的 **MIT** 标头；
  本仓库不分发该 bundle。
- MIT 许可**不包括商标**：DeepSeek 的名称与标识归其权利人所有。

---

## 5. 字体

| 字体 | 用途 | 许可 / 分发 |
| --- | --- | --- |
| Space Mono | 原片字体 | **SIL OFL 1.1**（上游随附 OFL 文本） |
| Anton | 原片横幅字体 | **SIL OFL 1.1**（上游随附 OFL 文本） |
| Consolas | 字形图集的等宽来源 | Windows 系统字体，**不随本仓库分发** |
| 微软雅黑（Microsoft YaHei） | 字形图集的 CJK 来源 | Windows 系统字体，**不随本仓库分发** |
| Segoe UI Symbol | 字形图集的符号来源 | Windows 系统字体，**不随本仓库分发** |

`data/glyphs.png` 是由上述系统字体在**本地**烘出的字形图集，已随 `data/` 一起被 Git 忽略；
如需重新生成，见 [DATA.md](subsystem/world_execute/DATA.md)。

---

## 6. Godot 插件与二进制

| 组件 | 位置 | 许可 | 说明 |
| --- | --- | --- | --- |
| **godot_xterm** | `addons/godot_xterm/` | **MIT**（Leroy Hopson 与贡献者） | 许可见 `LICENSE.md`；`lib/` 内含平台相关 `libstdc++` 等二进制 |
| **godot-vlc** | `addons/godot-vlc/` | **LGPL 2.1** | 许可见 `LICENSE`；`bin/` 内含 Windows / Linux / Android 的 LibVLC 动态库，分发时请遵守 LGPL（保留许可与可替换性） |
| **Dialogic 2** | `addons/dialogic/` | **MIT**（上游仓库） | `Example Assets/` 内的字体与音效另有 `LICENSE.txt` |
| Godot Engine | 运行时 | **MIT** | 本仓库不包含引擎二进制 |

`addons/` 体积较大（尤其 `godot-vlc` 的多平台二进制），克隆时请预留空间。

---

## 7. 其他子系统的素材（未逐一登记）

以下内容**没有**在本仓库完成许可登记，公开发布前请自行核实或移除：

- `assets/`（`0.png`、`DSniang1.png`、`test.webp`）；
- `subsystem/shader_preview/shaders/` 中非 `01_`–`10_` 前缀的 `.gdshader`：由 `shader_capture` 抓自
  [godotshaders.com](https://godotshaders.com/)，**来源、作者与许可写在每个文件头部的注释里**（多数为 CC0），
  `index.json` 记录同一批元数据；未逐条人工复核，公开前请按文件头核对；
- `subsystem/player_system/assets/`（玩家/眼睛贴图、`mist_*.png` 雾效帧、`我的世界玩家受伤.ogg`）；
- `system_test_1/VID20250306230957.mp4`、`subsystem/vivd_windows/sample/sample_5s.ogv`；
- `subsystem/scene_loader/_shots/`、`subsystem/shader_preview/_shots/` 等截图；
- `dialogic/` 与 `chapter/` 中的剧本文本。

其中 `我的世界玩家受伤.ogg` 的名称表明它可能来自《Minecraft》，相关权利归 Mojang / Microsoft；
若公开仓库，建议替换为自制音效或删除。

---

## 8. 发布前检查清单

- [ ] `git status` 中**没有** `subsystem/world_execute/data/`（歌曲、立绘、头像、字形图集）。
- [ ] 没有 `data/song.mp3`、`words.json`、`lyrics_cn.json`、`h3_text.json`。
- [ ] `NOTICE.md` 与 `LICENSE` 随仓库一起发布，且署名链未被删改。
- [ ] 如果分发了任何鲸鱼娘衍生图，确认标注 **CC BY-NC-SA 4.0** 且**非商业**。
- [ ] 如果分发了 `addons/godot-vlc/bin/`，随附 LGPL 2.1 许可文本。
- [ ] 如果替换/新增了第三方素材，在本文件登记来源与许可。

---

## 9. 更正与联系

如果本仓库使用了你的作品而署名有误、缺失，或你认为某处分发超出了许可范围，
请开 Issue 说明作品与位置；维护者会尽快更正或移除。

---

## 10. 上游许可全文索引

- MIT：<https://opensource.org/license/mit>
- CC BY-NC-SA 4.0：<https://creativecommons.org/licenses/by-nc-sa/4.0/legalcode>
- SIL OFL 1.1：<https://openfontlicense.org/>
- LGPL 2.1：<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>
- Mili Copyright Guidelines：<https://projectmili.com/copyright-guidelines>
