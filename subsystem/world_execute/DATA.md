# `world_execute` 数据与素材说明

本子系统运行时会读取 `data/` 下的表、图集、音频与立绘。**`data/` 不进入 Git**
（见仓库根的 [.gitignore](../../.gitignore)），原因有三：

1. 其中包含**版权素材**（歌曲、歌词、立绘、头像），许可不允许随代码仓库转发；
2. 体积较大（约 **12.4 MB**，其中音频 8.5 MB）；
3. 所有表都可以由 [tools/build_data.py](tools/build_data.py) 与 [tools/build_atlas.py](tools/build_atlas.py)
   从上游参考包**确定性重建**（同一输入 → 同一输出）。

> 因此：克隆仓库后**不能直接播放** `world_execute`；请按本文在本地生成 `data/`。

---

## 1. 需要准备什么

| 依赖 | 用途 | 获取方式 |
| --- | --- | --- |
| 上游参考包 | 镜头表、dsh 逐帧、H3 take、立绘、逐词时间轴 | 上游 `world-execute-me-dsh-pv`（MisakaZentai，MIT）及其**终端实时版**（林原林海） |
| 歌曲 `input/song.mp3` | 音频时钟与波形 | 上游终端版包内自带一份；或自备并按上游说明放入 |
| 歌词 `.lrc` / `song.json` | 逐词与逐行时间轴 | 上游包内；若缺失，按上游 `tools/lyrics.py` 的说明获取 |
| Python **3.12+** | 跑离线管线 | <https://www.python.org/> |
| `pillow`、`numpy` | 图像与数值处理 | `python -m pip install pillow numpy` |
| Windows 字体 | 烘字形图集 | `consola.ttf`、`msyh.ttc`、`seguisym.ttf`（系统自带；**不随仓库分发**） |

参考包根目录下应能看到这些路径（`WE_REF` 指向的就是这一层）：

```text
<WE_REF>/
├── _tools/                                  # tui_live.py / dsh_text.py / her_glyphs.py …
├── film/
│   ├── tui_pv_world_execute_20260926/       # 镜头、full/、continuity_full_v2/
│   ├── mmd_motion_eval_20260927/            # dancer.py、h3_full.py
│   └── pv_dsh_frontend_20260927/            # dsh 逐帧 DOM 与 avatars/
└── input/                                   # song.mp3、lyrics.lrc
```

---

## 2. 重建步骤

在仓库根执行（PowerShell）：

```powershell
# 1) 指向上游参考包（按你的实际路径修改）
$env:WE_REF = "E:\WorldExecuteMeDSH-main\WorldExecuteMeDSH-main"
$env:PYTHONIOENCODING = "utf-8"

# 2) 生成所有 JSON / BIN / 立绘 / 头像（约 1 分钟）
python subsystem/world_execute/tools/build_data.py

# 3) 烘字形图集（需要 Windows 系统字体）
python subsystem/world_execute/tools/build_atlas.py
```

可选环境变量：

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `WE_REF` | 作者本机的参考包路径 | 上游参考包根目录 |
| `WE_OUT` | `subsystem/world_execute/data` | 输出目录 |
| `PV_F_MONO` | `C:\Windows\Fonts\consola.ttf` | 字形图集的等宽字体 |
| `PV_F_CJK` | `C:\Windows\Fonts\msyh.ttc` | CJK 字体 |
| `PV_F_SYM` | `C:\Windows\Fonts\seguisym.ttf` | 符号字体 |

两个脚本都是**幂等**的；`build_data.py` 对参考包**只读**（连 `.pyc` 都不写）。

### 验收输出（节选）

```text
CHECK shots              97
CHECK dsh.frames         2533
CHECK dsh.bin            62513 B (raw 5010508 B)
CHECK h3_takes           16 takes / 2188 frames / ink 34×39
CHECK points_set         1400 pts, 28000 B
CHECK whale_fall         t0=193.54 tc=203.54 shed=230 contact=100 words=171
```

然后跑无头自测：

```powershell
godot --headless --path . subsystem/world_execute/tests/world_execute_smoke_test.tscn
# === world_execute 自测结束：633 项检查，0 项失败 ===
```

最后启动：

```powershell
godot --path . res://subsystem/world_execute/world_execute.tscn
```

---

## 3. `data/` 里有什么

### 3.1 必须（缺了播放器起不来或画面不全）

| 文件 | 内容 | 来源 | 许可 |
| --- | --- | --- | --- |
| `song.mp3` | 原曲（音频时钟） | Mili / 上游包 | 按 Mili 指引，非商业；**不随仓库分发** |
| `wave_rms.bin` / `.json` | 100 Hz u8 波形（顶栏） | 由 `song`/上游 RMS 处理 | 派生数据 |
| `features.json` | 48 Hz 音频特征 + 7 频段 | 上游构建 | 派生数据 |
| `words.json` / `lyrics_cn.json` | 逐词时间轴 + 中文对照 | 上游构建 / 翻译 | 歌词权利归 Mili |
| `shots.json` / `shots_meta.json` | 97 镜头、章节、ops、增益、cut | 上游 `full/` | MIT 代码产物 |
| `chapters.json`、`boot_log.json`、`gain.json`、`cursor.json` | 章节 / boot / 增益 / 光标窗格 | 上游 | MIT 代码产物 |
| `glyphs.png` / `glyphs.json` | 32×36 槽位、1129 字形的图集 | 本地系统字体烘出 | **不随仓库分发** |
| `panes.json` | 20 种章节面板的表 | 上游 + 本地 RNG 固化 | 派生数据 |
| `dsh.bin` / `dsh_meta.json` / `dsh_spans.json` | dsh 逐帧文本快照（zlib） | 上游 DOM | 文本来自上游；界面 MIT |
| `her_sprite/*.png` + `her_sprite.json` | 8 张立绘源图（最长边 512） | 上游立绘 | **CC BY-NC-SA 4.0** |
| `h3_takes.bin` / `.json`、`h3_ramp.json`、`h3_flow.*`、`h3_text.json`、`her_morph.json` | 她的 H3 字符 take、色表、歌词流、morph 阈值 | 上游 | 派生自立绘 → **CC BY-NC-SA 4.0** |
| `her_glyph.json` / `her_glyph_meta.json` | 旧 44×36 字形降级表 | 上游 | 派生自立绘 → **CC BY-NC-SA 4.0** |
| `figure_spans.json`、`portrait_shots.json`、`meta.json` | 立绘段 / 立绘镜头 / 杂项 | 上游 | MIT 代码产物 |
| `dsh_avatars/` | 745 张逐帧头像 | 上游 `avatars/` | **CC BY-NC-SA 4.0** |
| `points_set.bin` / `.json` | 1400 点 × 5 f32 点云固定表 | 本地 `Random(9)` 固化 | MIT 代码产物 |
| `whale_shed.bin`、`whale_contact.bin`、`whale_words.json`、`whale_fall.json` | 落鲸雪 / 尘 / 歌词碎屑固定表 | 本地 `Random(94)` 固化 + 立绘轮廓 | 派生自立绘 → **CC BY-NC-SA 4.0** |

### 3.2 说明

- `dsh.bin` 是 **zlib 压缩的 JSON**（5.01 MB → 62.5 KB）；`dsh_meta.json` 存 `raw_size` / `hz` / 帧数，
  运行时按需解压。压缩是**无损**的。
- `wave_rms.bin` 是 **100 Hz u8**（每 10 ms 取 1 kHz 源的峰值）；顶栏波形只有约 140 格 × 2.4 s，
  精度完全够用。
- 若你只想要「能跑」的最小集，至少需要 `glyphs.*`、`shots.*`、`chapters.json`、`features.json`、
  `wave_rms.*`、`words.json`、`lyrics_cn.json`、`boot_log.json`、`gain.json`、`panes.json`、
  `her_sprite/*`、`h3_*`、`dsh.*`、`song.mp3`。缺失时播放器会报错或降级，自测会失败。

---

## 4. 自定义数据

| 想改 | 改哪里 |
| --- | --- |
| 歌词文本 / 时间轴 | 上游 `.lrc` 或 `words.json`（改完重跑 `build_data.py`） |
| dsh 聊天内容 | 上游 `dsh_text.py` 的源 DOM；或在 `build_data.py` 的 `dsh_text.at(t)` 之后加过滤，再重跑管线 |
| 镜头 / 章节 | 上游 `shots.json` 的源数据（`build_data.py` 会重新导出） |
| 立绘 / 头像 | 替换 `her_sprite/` / `dsh_avatars/` 中同名文件（注意许可） |
| 字形图集 | `build_atlas.py` 的 `FIXED_EXTRA` / `UI_LITERALS`，然后重烘 |
| 点云 / 落鲸 | `build_data.py` 的 `build_point_set()` / `build_whale_fall()` |

> 改任何数据表后都要重跑 `world_execute_smoke_test.tscn`；断言里写死了若干表长与首尾值。

---

## 5. 许可提醒

**不要把 `data/` 提交到公开仓库。** 其中：

- 歌曲与歌词归 **Mili**，按 [Mili Copyright Guidelines](https://projectmili.com/copyright-guidelines)
  个人非商业使用，不能再许可；
- 立绘、表情、头像及由其派生的字符网格归原作者链（溟月 © 上善无形 / ZipZipPipe /
  Small-tailqwq / JAdpp），按 **CC BY-NC-SA 4.0**：署名、非商业、相同方式共享；
- 字形图集由 Windows 系统字体烘出，字体本身不可再分发。

完整说明与署名链见仓库根 [NOTICE.md](../../NOTICE.md)。
