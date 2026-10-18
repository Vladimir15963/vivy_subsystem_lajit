"""Offline data build for the world_execute PV player port (Godot).

Reads the reference film repo read-only and writes every table the player needs into
`subsystem/world_execute/data/`.

    $env:WE_REF="E:\\WorldExecuteMeDSH-main\\WorldExecuteMeDSH-main"
    $env:PYTHONIOENCODING="utf-8"; python build_data.py

`WE_REF` defaults to the author's local checkout; `WE_OUT` defaults to `../data` next to this
script. Nothing in the reference repo is modified (sys.dont_write_bytecode is set before any
import, so not even a .pyc is written). Re-running is idempotent.
"""
from __future__ import annotations

import ast
import hashlib
import json
import math
import os
import random
import shutil
import sys
import zlib
from pathlib import Path

# never leave a .pyc behind in the read-only reference repo
sys.dont_write_bytecode = True

REF = Path(os.environ.get("WE_REF", r"E:\WorldExecuteMeDSH-main\WorldExecuteMeDSH-main"))
TUI_DIR = REF / "film" / "tui_pv_world_execute_20260926"
FULL_DIR = TUI_DIR / "full"
V2_DIR = TUI_DIR / "continuity_full_v2"
MMD_DIR = REF / "film" / "mmd_motion_eval_20260927"
TOOLS_DIR = REF / "_tools"
DSH_DIR = REF / "film" / "pv_dsh_frontend_20260927"
OUT = Path(os.environ.get("WE_OUT", str(Path(__file__).resolve().parent.parent / "data")))
# dsh.json 引用到的逐帧头像落在这里（见 `copy_dsh_avatars`）
DSH_AVATARS = OUT / "dsh_avatars"

for p in (FULL_DIR, V2_DIR, MMD_DIR, TOOLS_DIR, TUI_DIR):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

import numpy as np  # noqa: E402
from PIL import Image, ImageFilter  # noqa: E402

# --------------------------------------------------------------------------- helpers

_MANIFEST: list[tuple[str, int, str]] = []


def _summary(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()[:12]


def emit(name: str, data: bytes) -> None:
    (OUT / name).write_bytes(data)
    dig = _summary(data)
    _MANIFEST.append((name, len(data), dig))
    print(f"OK {name} {len(data)}  data/{name}  sha1:{dig}")


def emit_json(name: str, obj) -> None:
    emit(name, json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf8"))


def ok(name: str) -> None:
    print(f"CHECK {name}")


# --------------------------------------------------------------------------- 1. song

import pv_full  # noqa: E402

# her_glyphs keeps the real PIL.Image.open captured at its own import time; warm it *before* the
# engine is installed so her sprite webps can still be read (see _tools/her_glyphs.py:41,1150).
import her_glyphs as HG  # noqa: E402

HG.warm()

v2, h3 = pv_full.install()
engine = v2.engine

import film_panels as FP  # noqa: E402
import dsh_text  # noqa: E402

# h3 三条渲染路径的数据源：`dancer`（她自己画的字符串网格）、`choreo`（flow 速度）。
# h3_full.PLAN 与 cache/h3_full_v1 由 build_h3_takes() 直接从磁盘读（pv_full.install() 已经把
# h3_full.PLAN/grids 换成了 mmd 版本，这里要的是作者批准的 50 段原表，所以不经过 h3_full）。
import dancer  # noqa: E402

END = float(getattr(engine, "END", getattr(engine, "END_T", 211.0)))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    # -- 1  song.mp3 ---------------------------------------------------------
    song = Path(pv_full.SONG)
    emit("song.mp3", song.read_bytes())

    # -- 2  wave_rms.bin / wave_rms.json -------------------------------------
    # 顶栏波形只有约 140 格 × 2.4 s（≈17 ms/格），1 ms f32 是 30 倍冗余。
    # 降到 100 Hz、u8（每 10 ms 取该桶峰值），848 KB → ~21 KB，柱高 8 级看不出差别。
    wave = np.load(DSH_DIR / "wave_rms_1ms.npy")
    K = 10
    n_bucket = len(wave) // K * K
    peaks = wave[:n_bucket].reshape(-1, K).max(axis=1) if n_bucket else wave
    u8 = np.clip(np.round(peaks * 255.0), 0, 255).astype(np.uint8)
    emit("wave_rms.bin", u8.tobytes())
    emit_json("wave_rms.json", {
        "shape": int(u8.shape[0]), "sample_rate": 100, "dtype": "u8",
        "source_rate": 1000, "reduce": "max",
    })

    # -- 3  features.json / meta.json ----------------------------------------
    feats = json.loads((FULL_DIR / "audio_features.json").read_text(encoding="utf8"))
    emit("features.json", (FULL_DIR / "audio_features.json").read_bytes())
    rate = float(feats.get("rate", 48.0))
    curves = {}
    covered = {}
    for k in ("loud", "kick", "flux", "cent"):
        row = feats.get(k) or []
        curves[k] = len(row)
        covered[k] = round(len(row) / rate, 4) if rate else None
    bands = feats.get("bands") or []
    curves["bands"] = [len(b) for b in bands]
    covered["bands"] = [round(len(b) / rate, 4) for b in bands]
    meta = {
        "source": "film/tui_pv_world_execute_20260926/full/audio_features.json",
        "rate": rate,
        "bands_count": len(bands),
        "curve_lengths": curves,
        "covered_seconds": covered,
    }
    emit_json("meta.json", meta)

    # -- 4  words.json -------------------------------------------------------
    wt = json.loads((REF / "film" / "world_execute_word_timing_20260927" /
                     "word_timeline.json").read_text(encoding="utf8"))
    lines = []
    for ln in wt["lines"]:
        lines.append({
            "text": ln["text"],
            "start": ln["start"],
            "end": ln["end"],
            "display_end": ln.get("display_end"),
            "words": [{"text": w["text"], "start": w["start"], "end": w["end"]} for w in ln["words"]],
        })
    words = {"duration": wt.get("duration"), "global_offset": wt.get("global_offset"), "lines": lines}
    emit_json("words.json", words)

    # -- 5  lyrics_cn.json (parsed with ast; tui_live is NOT imported) --------
    src = (TOOLS_DIR / "tui_live.py").read_text(encoding="utf8")
    lyric_cn = None
    for node in ast.parse(src).body:
        if isinstance(node, ast.AnnAssign) and getattr(node.target, "id", None) == "LYRIC_CN":
            lyric_cn = ast.literal_eval(node.value)
        elif isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "LYRIC_CN" for t in node.targets):
            lyric_cn = ast.literal_eval(node.value)
    assert isinstance(lyric_cn, dict), "LYRIC_CN not found in tui_live.py"
    emit_json("lyrics_cn.json", lyric_cn)

    # -- 6  shots.json / shots_meta.json -------------------------------------
    panels = FP.shots()
    shots = []
    for i, shot in enumerate(v2.ALL):
        name = shot.fn.__name__
        d = panels.get(name) or {}
        shots.append({
            "index": i,
            "name": name,
            "start": shot.start,
            "end": shot.end,
            "chapter": shot.chapter,
            "alert": shot.alert,
            "ops": d.get("ops") or [],
            "her": bool(d.get("her")),
        })
    shots.sort(key=lambda s: s["start"])
    emit_json("shots.json", shots)
    emit_json("shots_meta.json", {
        "count": len(shots),
        "hard_cut": engine.HARD_CUT,
        "end": END,
        "fps": engine.FPS,
        "first_beat": engine.FIRST_BEAT,
        "beat": engine.BEAT,
        "bpm": engine.BPM,
    })

    # -- 7  chapters.json ----------------------------------------------------
    emit_json("chapters.json", [[s, lab] for s, lab in engine.CHAPTERS])

    # -- 8  gain.json --------------------------------------------------------
    # ui_gain_at(t, name, u): u is the *shot-local* progress 0..1 (Ctx.u = lt/dur, engine.py:117-118;
    # tui_live passes ent["u"] = (t-start)/(end-start), tui_live.py:1227,3257).
    hz = 10
    n = int(round(END * hz))
    values = []
    for k in range(n + 1):
        t = k / hz
        s = engine.shot_at(t)
        u = min(1.0, max(0.0, (t - s.start) / max(1e-6, s.end - s.start)))
        values.append(float(FP.ui_gain_at(t, s.fn.__name__, u)))
    emit_json("gain.json", {"hz": hz, "values": values})

    # -- 9  boot_log.json ----------------------------------------------------
    emit_json("boot_log.json", [[t, tag, text] for t, tag, text in FP.BOOT_LOG])

    # -- 10 dsh.bin（zlib 压缩的逐帧聊天快照） --------------------------------
    # dsh_text.at(t) -> (avatar:str, theme:tuple[str,str,str], [(role,text)])。
    # `theme` = dsh_text.theme_of(body) = (bg-base, brand-primary, border-l1)：页面按章节换主题，
    # `brand-primary` 就是窗口的强调色（`draw_dsh` 的 accent）。`dot` role 由 dsh_text.build()
    # 插进 rows 头部，主题色帧里带着它（状态点色）。
    #
    # 体积：原始 JSON 5.0 MB（106k 行、只有 2911 种不同文本），zlib 后 62 KB。
    # 运行时用 `dsh_meta.json` 的 raw_size 一次性解压，再交给 JSON.parse_string。
    dhz = 12
    frames = []
    for k in range(int(round(211 * dhz)) + 1):
        t = k / dhz
        av, theme, entries = dsh_text.at(t)
        frames.append({
            "t": round(t, 6),
            "avatar": av or "",
            "theme": list(theme),
            "rows": [{"role": role, "text": txt} for role, txt in entries],
        })
    dsh_raw = json.dumps({"hz": dhz, "frames": frames},
                         ensure_ascii=False, separators=(",", ":")).encode("utf8")
    emit("dsh.bin", zlib.compress(dsh_raw, 9))
    emit_json("dsh_meta.json", {"raw_size": len(dsh_raw), "hz": dhz, "frames": len(frames)})

    # -- 10b dsh 头像 PNG ----------------------------------------------------
    copy_dsh_avatars(frames)

    # -- 11 figure_spans / portrait_shots / dsh_spans ------------------------
    emit_json("figure_spans.json", [[a, b] for a, b in FP.figure_spans()])
    emit_json("portrait_shots.json", dict(FP.portrait_shots()))
    emit_json("dsh_spans.json", [[a, b] for a, b in FP.dsh_spans()])

    # -- 12 her_glyph.json / her_glyph_meta.json -----------------------------
    build_her_glyph()

    # -- 12a her 三条渲染路径的数据（h3 / half / glyph） ----------------------
    build_her_sprite()
    build_h3_takes()
    build_h3_ramp()
    build_h3_flow()
    build_h3_text()
    build_her_morph()

    # -- 13 cursor.json ------------------------------------------------------
    cur = DSH_DIR / "cursor.json"
    if cur.exists():
        emit("cursor.json", cur.read_bytes())
    else:
        print("WARN cursor.json missing in reference repo; skipped")

    # -- 12b panes.json ------------------------------------------------------
    panes = build_panes(src)
    emit_json("panes.json", panes)

    # -- 12c 点集固定表（C 层粒子） ------------------------------------------
    points = build_point_set()

    # -- 12d 落鲸雪尘固定表（C 层粒子） --------------------------------------
    whale = build_whale_fall()

    # ------------------------------------------------------------------ report
    print("\n---- artifacts ----")
    for name, size, dig in _MANIFEST:
        print(f"  data/{name:22s} {size:>9d} B  sha1:{dig}")
    verify(words, lyric_cn, shots, frames, panes, points, whale)


# ------------------------------------------------------------------ her glyph bake

CELL_ASPECT = HG.CELL_ASPECT              # 2.1, _tools/her_glyphs.py:48
RAMP = HG.GLYPH_RAMP                      # " .:-=+*#%@"
GCOLS, GROWS = 44, 36
# the film's own 4-way edge glyphs (tuikit.glyph_grid via her_glyphs.glyph_lines:143-144);
# `edge` additionally records the 8-way Sobel direction bin.
KX = [-1, 0, 1, -2, 0, 2, -1, 0, 1]
KY = [-1, -2, -1, 0, 0, 0, 1, 2, 1]


def build_her_glyph() -> None:
    crop = HG.pick_crop(GCOLS, GROWS)
    aspect = GCOLS / max(1, GROWS * CELL_ASPECT)
    exprs: dict = {}
    name_map: dict = {}
    for expr in HG.EXPRESSIONS:
        small = HG.cropped(expr, crop, aspect).resize((GCOLS, GROWS), Image.LANCZOS)
        lum_img = small.convert("L")
        alpha_img = small.getchannel("A")
        gx = lum_img.filter(ImageFilter.Kernel((3, 3), KX, scale=4, offset=128))
        gy = lum_img.filter(ImageFilter.Kernel((3, 3), KY, scale=4, offset=128))
        L = np.asarray(lum_img, dtype=np.float64) / 255.0
        A = np.asarray(alpha_img, dtype=np.int64)
        X = np.asarray(gx, dtype=np.float64)
        Y = np.asarray(gy, dtype=np.float64)
        ex, ey = (X - 128.0) / 32.0, (Y - 128.0) / 32.0
        mag = np.hypot(ex, ey)
        ang = np.degrees(np.arctan2(ey, ex)) + 180.0
        ang = np.mod(ang, 180.0)
        eb = np.floor(ang / 22.5).astype(np.int64)
        eb = np.clip(eb, 0, 7)
        edge_mask = (A >= 110) & (mag > 1.1)
        opaque = A >= 110

        ramp_idx = np.minimum(len(RAMP) - 1, 1 + (L * (len(RAMP) - 1)).astype(np.int64))
        ramp_idx = np.clip(ramp_idx, 0, len(RAMP) - 1)
        ramp_arr = np.array(list(RAMP))
        chars = ramp_arr[ramp_idx]
        # edge glyphs: same 4-way mapping as her_glyphs.glyph_lines:143-144
        a0 = ang
        edge_ch = np.full(ramp_idx.shape, "|", dtype="<U1")
        edge_ch[(a0 >= 22.5) & (a0 < 67.5)] = "\\"
        edge_ch[(a0 >= 67.5) & (a0 < 112.5)] = "-"
        edge_ch[(a0 >= 112.5) & (a0 < 157.5)] = "/"
        chars[edge_mask] = edge_ch[edge_mask]
        chars[~opaque] = " "

        lum = np.where(edge_mask, 255.0, np.floor(255.0 * (0.35 + 0.65 * L)))
        lum = np.where(opaque, lum, 0.0).astype(np.int64)
        edge = np.where(edge_mask, eb, 0).astype(np.int64)

        exprs[expr] = {
            "chars": chars.ravel().tolist(),
            "lum": lum.ravel().tolist(),
            "edge": edge.ravel().tolist(),
        }
        name_map[expr] = f"whale-{expr}.webp"

    emit_json("her_glyph.json", {"cols": GCOLS, "rows": GROWS, "ramp": RAMP, "expressions": exprs})
    emit_json("her_glyph_meta.json", {
        "cols": GCOLS,
        "rows": GROWS,
        "ramp": RAMP,
        "crop": crop,
        "cell_aspect": CELL_ASPECT,
        "edge_dirs": 8,
        "edge_note": "edge is the 8-way Sobel direction bin 0..7 for detected edges, 0 elsewhere; "
                     "chars uses the film's own 4-way edge glyphs",
        "files": name_map,
    })


# ------------------------------------------------------------------ her 三条渲染路径

# `her_glyphs.py` 的三条路径（h3 / half / glyph）需要的东西，GDScript 无法从参考仓库现算的一律烘下来。

SPRITE_MAX = 512                       # 立绘源图最长边降到 512 px（原始 935x1682）
SPRITE_EXPRS = ["cheerful", "starry", "shy", "serious", "confused", "frightened", "angry",
                "exasperated"]
CROP_NAMES = ("full", "upper", "face", "bust")
SPRITE_DIR = OUT / "her_sprite"


def _crop_box_orig(im: Image.Image, crop: str):
    """`her_glyphs._crop_box()` 的矩形，坐标在原图（未缩放）像素里。"""
    spec = HG.CROPS[crop]
    if spec is None:
        return im.getchannel("A").getbbox()
    w, h = im.size
    a, b, c, e = spec
    return (int(w * a), int(h * b), int(w * c), int(h * e))


def build_her_sprite() -> None:
    """8 张 `data/her_sprite/{expr}.png` + `her_sprite.json`。

    存成 8 位 RGBA：R=G=B=原图 convert("L") 的亮度、A=原图 alpha —— 这样 `glyph_lines` /
    `halfblock` 要的 L、A 两张通道都能在同一张 PNG 上取到。降到最长边 512（PIL LANCZOS）后
    重新算 crop 矩形（CROPS 的分数与 `full` 的 alpha getbbox 都在原图上量，再按缩放比例换算）。
    """
    SPRITE_DIR.mkdir(parents=True, exist_ok=True)
    sprites: dict = {}
    for expr in SPRITE_EXPRS:
        im = HG.sprite(expr)
        w, h = im.size
        s = min(1.0, SPRITE_MAX / max(w, h))
        nw, nh = max(1, int(round(w * s))), max(1, int(round(h * s)))
        lum = im.convert("L")
        alpha = im.getchannel("A")
        small = Image.merge("RGBA", (lum, lum, lum, alpha)).resize((nw, nh), Image.LANCZOS)
        small.save(SPRITE_DIR / f"{expr}.png")
        sx, sy = nw / w, nh / h
        crops: dict = {}
        for cname in CROP_NAMES:
            x0, y0, x1, y1 = _crop_box_orig(im, cname)
            x0 = max(0, min(nw - 1, int(round(x0 * sx))))
            y0 = max(0, min(nh - 1, int(round(y0 * sy))))
            x1 = max(x0 + 1, min(nw, int(round(x1 * sx))))
            y1 = max(y0 + 1, min(nh, int(round(y1 * sy))))
            crops[cname] = [x0, y0, x1 - x0, y1 - y0]
        sprites[expr] = {"orig": [w, h], "size": [nw, nh], "crops": crops}

    # `crop_aspect()`：四张裁剪自身的宽/高。八张表情共享同一张画布，用 cheerful 量即可。
    cheer = HG.sprite("cheerful")
    aspects: dict = {}
    for cname in CROP_NAMES:
        bx0, by0, bx1, by1 = _crop_box_orig(cheer, cname)
        aspects[cname] = (bx1 - bx0) / (by1 - by0)

    emit_json("her_sprite.json", {"max_side": SPRITE_MAX, "aspects": aspects, "sprites": sprites})
    for expr in SPRITE_EXPRS:
        p = SPRITE_DIR / f"{expr}.png"
        print(f"  sprite {expr:11s} {sprites[expr]['orig']} -> {sprites[expr]['size']}  {p.stat().st_size} B")


def build_h3_takes() -> None:
    """16 个 take 的 `art`+`shade`，只存墨迹框 rows 10..43 × cols 17..55（34×39），zlib 压缩。

    直接读 `continuity_full_v2/h3_full.py` 的 PLAN 字面量与 `cache/h3_full_v1/{name}.json`
    （不经过 h3_full，因为 `pv_full.install()` 已把它换成了 mmd 版本）。`art` 存字符集下标、
    `shade` 的数字存 0-9、非数字统一存 255（运行侧 `lv=4`）。
    """
    src = (V2_DIR / "h3_full.py").read_text(encoding="utf8")
    plan = _src_const(src, "PLAN", [])
    assert len(plan) == 50, len(plan)
    names = list(dict.fromkeys(p[2] for p in plan))
    cache = V2_DIR / "cache" / "h3_full_v1"
    raws = {n: json.loads((cache / f"{n}.json").read_text(encoding="utf8")) for n in names}

    # 墨迹框：对**每一帧**（不是 0.5 s 采样）量并集，确认整片只在 rows 10-43 / cols 17-55 落墨，
    # 这样只存 34×39 与存整块 45×70 等价（`:` 的 lyric 流下标只数非空格，框外全空）。
    r0, r1, c0, c1 = 10 ** 9, -1, 10 ** 9, -1
    for n in names:
        for fr in raws[n]:
            art = fr["art"]
            for r, row in enumerate(art):
                for c, ch in enumerate(row):
                    if ch != " ":
                        r0, r1 = min(r0, r), max(r1, r)
                        c0, c1 = min(c0, c), max(c1, c)
    assert (r0, r1, c0, c1) == (10, 43, 17, 55), (r0, r1, c0, c1)
    # 字符集：墨迹框里出现过的全部字符（空格算一个字符，运行侧它就是「这一格空」）。
    charset: set = set()
    for n in names:
        for fr in raws[n]:
            art = fr["art"]
            for r in range(r0, r1 + 1):
                charset.update(art[r][c0:c1 + 1])
    chars = "".join(sorted(charset))
    idx = {ch: i for i, ch in enumerate(chars)}
    hr, hc = r1 - r0 + 1, c1 - c0 + 1

    blob = bytearray()
    takes: dict = {}
    for n in names:
        frames = raws[n]
        takes[n] = [len(frames), len(blob)]
        for fr in frames:
            art, shade = fr["art"], fr["shade"]
            for r in range(r0, r1 + 1):
                arow = art[r]
                for c in range(c0, c1 + 1):
                    blob.append(idx[arow[c]])
            for r in range(r0, r1 + 1):
                srow = shade[r]
                for c in range(c0, c1 + 1):
                    sh = srow[c]
                    blob.append(int(sh) if sh.isdigit() else 255)
    raw = bytes(blob)
    comp = zlib.compress(raw, 9)
    emit("h3_takes.bin", comp)
    emit_json("h3_takes.json", {
        "charset": chars, "rows": hr, "cols": hc, "ink": [r0, r1, c0, c1], "fps": 24,
        "raw_size": len(raw), "total_frames": sum(len(raws[n]) for n in names),
        "takes": takes, "plan": [list(p) for p in plan],
    })


def build_h3_ramp() -> None:
    """两条色阶表：

    * `blue`/`red` —— `dancer._ramp(tint)` 的 256 级查表（PIL ImageOps.colorize），h3 路径用它；
      注意 `red` 用的是 tuikit.TINTS["red"] = (BG, RED, None) = (4,7,15)/(255,59,48)。
    * `blue8`/`red8` —— `her_glyphs.tint_ramp(tint, 8)`，half 路径用它；红的常量与上面**不同**
      （her_glyphs 自己那对 (8,6,4)/(255,58,40)），所以单独烘，不能从 256 级采样推出来。
    """
    emit_json("h3_ramp.json", {
        "blue": [list(c) for c in dancer._ramp("blue")],
        "red": [list(c) for c in dancer._ramp("red")],
        "blue8": [list(c) for c in HG.tint_ramp("blue")],
        "red8": [list(c) for c in HG.tint_ramp("red")],
    })


def build_h3_flow() -> None:
    """`dancer._flow_table()`：每视频帧的累积 lyric 流偏移（float32），外加 CPS / SONG_LEN。"""
    ft = dancer._flow_table()
    emit("h3_flow.bin", np.asarray(ft, dtype="<f4").tobytes())
    emit_json("h3_flow.json", {"count": len(ft), "cps": float(dancer.CPS),
                               "song_len": float(dancer.SONG_LEN), "fps": float(dancer.FPS)})


def build_h3_text() -> None:
    """`engine.LYRICS` = `dancer._text_at` 用的 `(start, end, line)` 表（来自 lyrics_synced.lrc）。

    words.json 的 `text` 虽然一致，但 `start/end` 是逐词时间线而非 .lrc 时间戳（首行 0.06/1.701
    vs 0.03/1.33），两者**不相等**，所以这里单独导出。
    """
    emit_json("h3_text.json", [[float(a), float(b), s] for a, b, s in dancer.LYRICS])


def build_her_morph() -> None:
    """`tui_live._flip_order(7722)` = `random.Random(7)` 的前 7722 个 random()。"""
    rnd = random.Random(7)
    emit_json("her_morph.json", [rnd.random() for _ in range(7722)])


# ------------------------------------------------------------------ chapter panes

# Every literal the 20 chapter panes print that is not already in FIXED_EXTRA/UI_LITERALS.
PANES_LITERALS = "·▪■║╲╱▼°Δθ∞"


def _src_const(src: str, name: str, default):
    """ast-literal-eval a top-level assignment in a source string (same trick as LYRIC_CN)."""
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == name for t in node.targets):
            try:
                return ast.literal_eval(node.value)
            except Exception:
                return default
    return default


def _moe_rank_table() -> list:
    """scenes_reward.moe_rank(): grid distance from the source plus noise, seeded 60."""
    rng = random.Random(60)
    n, src = FP.N_EXP, FP.MOE_SRC
    qs, rs = src % 32, src // 32
    key = {i: math.hypot(i % 32 - qs, (i // 32 - rs) * 36 / 34) + rng.random() * 2.4 for i in range(n)}
    order = sorted(range(n), key=key.get)
    rank = [0] * n
    for k, i in enumerate(order):
        rank[i] = k
    return rank


def _moe_routed_table() -> list:
    """Per-beat `random.Random(beat_index(t)).sample(range(256), 6)`; beats -1..470 -> index beat+1."""
    out = []
    for b in range(-1, 471):
        out.append(sorted(random.Random(b).sample(range(FP.N_EXP), 6)))
    return out


def build_panes(src: str) -> dict:
    """panes.json - the tables the 17 chapter panes need that GDScript cannot reproduce.

    The film's rng draws (Mersenne Twister), its PIL silhouettes and its Anton banner are baked
    here; every pure function (loss/lr/kv/pipe/moe maths) is rewritten in scripts/pv_panes.gd.
    """
    rng4 = random.Random(4)
    noise = [rng4.gauss(0.0, 1.0) for _ in range(600)]

    # IF I CAN banner: one bit grid per row count `banner_fit` may pick (rows 2..12)
    banner = {"text": "IF I CAN", "cell_aspect": 2.0, "rows": {}}
    try:
        for nrows in range(2, 13):
            cols_, _r, data = FP.banner_bits("IF I CAN", nrows)
            banner["rows"][str(nrows)] = {
                "cols": int(cols_),
                "lines": ["".join("#" if data[r * cols_ + q] else " " for q in range(cols_))
                          for r in range(nrows)],
            }
    except Exception as exc:                                  # no Antone font / PIL missing
        print(f"WARN banner_bits unavailable ({exc}); IFICAN banner left empty")

    # whale: one silhouette per film frame over shot_whale's window (the tail flaps on t*5)
    shot = next((sh for sh in v2.ALL if sh.fn.__name__ == "shot_whale"), None)
    f0 = int(shot.start * 24) - 3 if shot is not None else 0
    frames = []
    if shot is not None:
        for k in range(f0, int(shot.end * 24) + 4):
            grid = [[" "] * FP.WHALE_COLS for _ in range(FP.WHALE_ROWS)]
            for r, q, ch in FP.whale_letters(k / 24.0):
                grid[r][q] = ch
            frames.append(["".join(row) for row in grid])

    # tuikit.decode("while can(): give()", lt, random.Random(9), 30.0) - the scramble sequence
    r9 = random.Random(9)
    decode9 = [r9.choice(FP.SCR) for _ in range(64)]

    mem_files = _src_const(src, "MEM_FILES", [])
    mem_dig = _src_const(src, "MEM_DIG", [])
    mem_span = _src_const(src, "MEM_SPAN", (118.10, 121.80))

    # mask (shot_blind): scenes_sft.cell_value draws one *fresh* `random.Random(i*13+j)` per cell,
    # so the raw 0..1 draws are baked here; the -inf front (`mask_time`) is pure maths and is
    # rewritten in scripts/pv_panes.gd (it only needs the baked T_BLIND / MASK_DUR constants).
    mk_n = int(FP.MN)
    mask_cells = [random.Random(i * 13 + j).random()
                  for i in range(mk_n) for j in range(mk_n)]

    # expert (shot_strange): FP.expert_grid(u) draws `random.Random(8).gauss(0, 0.05)` for the
    # *good* cells only, in row-major order -- so the k-th good cell always takes the k-th draw.
    # Bake the first EXPERT_ROWS*EXPERT_COLS draws; GDScript consumes them in the same order.
    ex_rows, ex_cols = int(FP.EXPERT_ROWS), int(FP.EXPERT_COLS)
    erng = random.Random(8)
    expert_gauss = [erng.gauss(0.0, 0.05) for _ in range(ex_rows * ex_cols)]

    return {
        "chars": PANES_LITERALS + "".join(FP.CORPUS),
        "corpus": list(FP.CORPUS),
        "facts": {
            "pretrain_tokens": str(FP.PRETRAIN_TOKENS),
            "pretrain_tokens_t": float(FP.PRETRAIN_TOKENS_T),
            "ctx": int(FP.FACTS.CTX),
            "gpu": str(FP.FACTS.GPU),
        },
        "loss": {"noise": noise},
        "mask": {"n": mk_n, "t_blind": float(FP.T_BLIND), "mask_dur": float(FP.MASK_DUR),
                 "cells": mask_cells},
        "memory": {
            "files": list(mem_files),
            "dig": [[str(n), float(at), str(ts)] for n, at, ts in mem_dig],
            "span": [float(mem_span[0]), float(mem_span[1])],
        },
        "kv": {"cols": int(FP.KV_COLS), "rows": int(FP.KV_ROWS),
               "pinned": [[int(q), int(r)] for q, r in FP.KV_PINNED]},
        "expert": {"rows": ex_rows, "cols": ex_cols, "w": int(FP.EXPERT_W), "gauss": expert_gauss},
        "pipe": {"ranks": int(FP.PIPE.get("ranks", 8)), "steps": int(FP.PIPE.get("steps", 27))},
        "moe": {"n_exp": int(FP.N_EXP), "src": int(FP.MOE_SRC),
                "cols": int(FP.MOE_COLS), "rows": int(FP.MOE_ROWS),
                "rank": _moe_rank_table(), "routed": _moe_routed_table()},
        "kernels": [[int(v) for v in k] for k in FP.KERNELS],
        "samples": {
            "exprs": ["cheerful", "starry", "shy", "serious", "confused", "frightened",
                      "angry", "exasperated"],
            "starts": [0.0] + [random.Random(i).random() * 0.35 for i in range(1, 12)],
        },
        "whale": {"cols": int(FP.WHALE_COLS), "rows": int(FP.WHALE_ROWS),
                  "hz": 24, "f0": int(f0), "frames": frames},
        "banner": banner,
        "decode9": decode9,
        # love (shot_love_loop): LOVE_PER_ROW only -- love_words()/love_cells() are pure maths
        # (`max(0, int((lt-0.12)*50))`, `divmod(i, 7)`) and are rewritten in scripts/pv_panes.gd.
        "love": {"per_row": int(FP.LOVE_PER_ROW)},
    }


# ------------------------------------------------------------------ dsh avatars

def copy_dsh_avatars(frames) -> None:
    """把 dsh.json 实际引用到的逐帧头像 PNG 拷进 `data/dsh_avatars/`。

    路径映射（与 `pv_panels.gd._avatar_block()` 的解析一致）：
        dsh.json 里的 `avatars/<子目录>/<名>.png`（参考仓库 `film/pv_dsh_frontend_20260927/` 下）
        -> `data/dsh_avatars/<子目录>/<名>.png`（去掉前导 `avatars/`，其余相对路径原样保留；
           根目录的 `avatars/a1_noise00.png` 就落在 `data/dsh_avatars/a1_noise00.png`）。

    只拷被引用到的那些（745 张），不是整目录 1456 张；重复运行先清空再拷，幂等。
    """
    if DSH_AVATARS.exists():
        shutil.rmtree(DSH_AVATARS)
    rels = sorted({f["avatar"] for f in frames if f["avatar"]})
    total = 0
    for rel in rels:
        src = DSH_DIR / rel
        assert src.exists(), f"avatar missing in reference repo: {rel}"
        sub = rel[len("avatars/"):] if rel.startswith("avatars/") else rel
        dst = DSH_AVATARS / sub
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())
        total += dst.stat().st_size
    print(f"OK data/dsh_avatars/  -> {len(rels)} files, {total} B")
    _MANIFEST.append(("dsh_avatars/", total, _summary(str(rels).encode())))


# ------------------------------------------------------------------ point set (C layer)

def build_point_set() -> dict:
    """把 `shot_points` 的 1400 个点烘成固定表（C 层决策 §7 Q8：不使用运行时 RNG）。

    来源 `continuity_full_v2/scenes.py:L276-285`（`point_set()`）：
        pts = sec_verse1.her_points(1400, 120, 240)      # 她轮廓内的点 + 亮度
        rnd = random.Random(9)
        (tx, ty) = (440 + px*260, 70 + py*520)           # 收敛后的目标
        (rx, ry) = (420 + rnd*720, 70 + rnd*520)         # 初始散布

    每点 5 个 f32：`tx, ty, lv, rx, ry`（顺序与参考的 `(tx, ty, lv, rx, ry)` 一致）。
    参考侧是 `@lru_cache`，这里等价于把它固化成二进制，运行时逐点复现、不再摇 RNG。
    """
    import scenes as SCN  # noqa: E402  (continuity_full_v2)
    pts = SCN.point_set()
    arr = np.asarray(pts, dtype="<f4")
    assert arr.shape == (1400, 5), arr.shape
    emit("points_set.bin", arr.tobytes())
    meta = {
        "count": int(arr.shape[0]),
        "stride": 5,
        "fields": ["tx", "ty", "lv", "rx", "ry"],
        "seed": 9,
        "sample": [120, 240],
        "source": "continuity_full_v2/scenes.py: point_set()",
    }
    emit_json("points_set.json", meta)
    return meta


# ------------------------------------------------------------------ whale fall (C layer)

def build_whale_fall() -> dict:
    """把落鲸段的雪 / 接触尘 / 歌词碎屑烘成固定表（决策 §7 Q8：运行时不用 RNG）。

    参考 `continuity_full_v2/s_eval.py` 的 `WhaleFall.build()`（L550-623）。**不直接调用它**：
    它取 `her_layer()` 的 alpha 来撒雪，而参考仓库缺 `cache/h3_full_v1/rgba/settle/030.png`，
    会直接抛 `FileNotFoundError`。这里按同一顺序重放 `random.Random(94)` 的每一步，
    只把「她轮廓内的采样点」换成我们已烘的 `her_sprite/cheerful.png` alpha（同一窗格、同一阈值）。

    位置公式（`shed_pos` / `contact_pos` / `word_state` / `converge`）是 `t` 的闭式函数，
    所以只烘参数；落地线 `floor_y(x) = 559 + 4*sin(0.07x)` 由 meta 带出。
    """
    import s_eval as SE  # noqa: E402  (continuity_full_v2)
    import scenes_eval as S  # noqa: E402

    # --- 时间轴：第 94 个镜头（shot_whale_fall）
    shots = v2.ALL
    i_whale = next(i for i, sh in enumerate(shots) if sh.fn.__name__ == "shot_whale_fall")
    T0, T1 = float(shots[i_whale].start), float(shots[i_whale].end)
    TC = T1 - 2.0
    FIG_CX, RISE, SINK = 216.0, 24.0, 262.0
    HX = float(S.HX)

    def offset(t: float):
        a = _ease_io((t - T0) / 0.92)
        dx = (HX - FIG_CX) * a
        rise = -RISE * _ease_out((t - T0) / 1.1)
        u = _clamp((min(t, TC) - (T0 + 0.5)) / (TC - T0 - 0.5))
        s = u * u * (1.6 - 0.6 * u)
        return dx, rise + SINK * s

    # --- 她轮廓内的采样点（替代 her_layer 的 alpha）
    pts = _sprite_alpha_points("cheerful")
    floor_y = lambda x: S.floor_y(x)  # noqa: E731

    rng = random.Random(94)
    shed = []
    tries = 0
    while len(shed) < 230 and tries < 5000:
        tries += 1
        b = rng.uniform(T0 + 1.0, TC - 0.25)
        rx, ry = rng.choice(pts)
        dx, dy = offset(b)
        x0, y0 = rx + dx, ry + dy
        if y0 > floor_y(x0) - 6:
            continue
        shed.append(dict(b=b, x0=x0, y0=y0, v=rng.uniform(7, 15), amp=rng.uniform(4, 12),
                         w=rng.uniform(0.8, 1.6), ph=rng.uniform(0, 6.28),
                         drift=rng.uniform(-4, 4), lv=rng.uniform(0.55, 0.95),
                         sz=rng.choice((2, 2, 3))))

    contact = []
    for rx, ry in pts[::3]:
        lo, hi = T0 + 0.5, TC
        def fy(tt, _rx=rx, _ry=ry):
            return _ry + offset(tt)[1] - floor_y(_rx + offset(tt)[0])
        if fy(hi) < 0 or fy(lo) >= 0:
            continue
        for _ in range(22):
            mid = (lo + hi) / 2
            if fy(mid) < 0:
                lo = mid
            else:
                hi = mid
        if rng.random() < 0.55:
            contact.append(dict(b=hi, x0=rx + offset(hi)[0],
                                side=rng.choice((-1, 1)) * rng.uniform(8, 46),
                                up=rng.uniform(3, 12), lv=rng.uniform(0.5, 0.9),
                                sz=rng.choice((2, 3))))

    # --- 歌词碎屑（love_loop 最后一帧的内容）
    lt_love = T0 - float(shots[i_whale - 1].start)
    words = []
    for it in S.love_items(lt_love, True):
        if it[0] == "t":
            _, s, f, col, (x, y), key = it
            words.append(dict(kind="t", s=s, col=col, x=x, y=y, key=key))
        else:
            x0, y0, x1, y1 = it[1]
            words.append(dict(kind="r", box=it[1], col=it[2], x=x0, y=y0, key=it[3]))
    rows = max(1, max((w["y"] - 76) // 20 for w in words if w["key"] >= 100))
    for wd in words:
        if wd["key"] >= 100:
            r = (wd["y"] - 76) // 20
            wd["delay"] = 0.035 * (rows - r) + 0.006 * ((wd["x"] - 800) / 50) + rng.uniform(0, 0.03)
            wd["whole"] = 0.55
        else:
            wd["delay"] = rng.uniform(0.0, 0.08)
            wd["whole"] = 0.3
        wd["specks"] = [(rng.uniform(-4, 36), rng.uniform(-2, 12), rng.uniform(24, 42),
                         rng.uniform(0, 6.28), rng.uniform(0.5, 0.9))
                        for _ in range(3 if wd["kind"] == "t" else 5)]

    for q in shed + contact:
        q["d"] = rng.uniform(0.0, 1.05)
    for wd in words:
        wd["d"] = [rng.uniform(0.0, 1.05) for _ in wd["specks"]]

    shed_arr = np.asarray([[q["b"], q["x0"], q["y0"], q["v"], q["amp"], q["w"],
                            q["ph"], q["drift"], q["lv"], q["sz"], q["d"]] for q in shed], dtype="<f4")
    contact_arr = np.asarray([[q["b"], q["x0"], q["side"], q["up"], q["lv"], q["sz"], q["d"]]
                              for q in contact], dtype="<f4")
    emit("whale_shed.bin", shed_arr.tobytes())
    emit("whale_contact.bin", contact_arr.tobytes())

    out_words = []
    for wd in words:
        col = wd["col"]
        col_i = int((col[0] << 16) | (col[1] << 8) | col[2]) if isinstance(col, (tuple, list)) else int(col)
        rec = {
            "kind": wd["kind"], "col": col_i, "x": float(wd["x"]), "y": float(wd["y"]),
            "key": float(wd["key"]), "delay": float(wd["delay"]), "whole": float(wd["whole"]),
            "specks": [[float(v) for v in sp] for sp in wd["specks"]],
            "d": [float(v) for v in wd["d"]],
        }
        if wd["kind"] == "t":
            rec["s"] = str(wd["s"])
        else:
            rec["box"] = [float(v) for v in wd["box"]]
        out_words.append(rec)

    cw, ch = dancer._cell()
    meta = {
        "t0": T0, "t1": T1, "tc": TC, "hx": HX, "floor": float(S.FLOOR),
        "cell": [HX, floor_y(HX) - 10 / 2 - 1],
        "shed": int(shed_arr.shape[0]), "stride_shed": 11,
        "contact": int(contact_arr.shape[0]), "stride_contact": 7,
        "words": len(out_words), "word_cell": [float(cw), float(ch)],
    }
    emit_json("whale_words.json", {"words": out_words})
    emit_json("whale_fall.json", meta)
    return meta


def _ease_out(u: float) -> float:
    u = max(0.0, min(1.0, u))
    return 1.0 - (1.0 - u) ** 3


def _ease_io(u: float) -> float:
    u = max(0.0, min(1.0, u))
    return 4 * u ** 3 if u < 0.5 else 1.0 - (-2 * u + 2) ** 3 / 2


def _clamp(v: float) -> float:
    return max(0.0, min(1.0, v))


def _sprite_alpha_points(expr: str) -> list:
    """她在 `CALL_VIEW`（24,56,384,532）里的 alpha 采样点：每 10 行、每 5 列取 alpha > 90 的位置。

    参考用 `her_layer()` 的渲染结果；这里用 `her_sprite/{expr}.png`（已由 `build_her_sprite()` 写好），
    按 `me_pane` 的摆放（水平居中、y0+16）贴进 1280×720 画布后采样。
    """
    from PIL import Image
    src = (OUT / "her_sprite" / f"{expr}.png")
    assert src.exists(), f"her sprite missing: {src}"
    sprite = Image.open(src).convert("RGBA")
    x0, y0, x1, y1 = 24, 56, 384, 532
    avail_w, avail_h = (x1 - x0) - 36, (y1 - y0) - 22
    scale = min(avail_w / sprite.width, avail_h / sprite.height)
    sw, sh = max(1, int(sprite.width * scale)), max(1, int(sprite.height * scale))
    sprite = sprite.resize((sw, sh), Image.LANCZOS)
    canvas = Image.new("L", (1280, 720), 0)
    canvas.paste(sprite.getchannel("A"), ((x0 + x1 - sw) // 2, y0 + 16))
    A = canvas.load()
    pts = []
    for y in range(60, 540, 10):
        for x in range(26, 382, 5):
            if A[x + 2, y + 5] > 90:
                pts.append((x + 2, y + 5))
    assert pts, "her alpha sampling produced no points"
    return pts


# ------------------------------------------------------------------ acceptance

def verify(words, lyric_cn, shots, frames, panes, points, whale) -> None:
    wave_n = len(open(OUT / "wave_rms.bin", "rb").read())
    print("\n---- acceptance ----")
    print(f"CHECK wave length        {wave_n}  (u8 @100 Hz)")
    print(f"CHECK words.lines        {len(words['lines'])}")
    print(f"CHECK lyrics_cn          {len(lyric_cn)}")
    print(f"CHECK shots              {len(shots)}")
    print(f"CHECK chapters           {len(json.loads((OUT/'chapters.json').read_text(encoding='utf8')))}")
    print(f"CHECK boot_log           {len(json.loads((OUT/'boot_log.json').read_text(encoding='utf8')))}")
    g = json.loads((OUT / "gain.json").read_text(encoding="utf8"))
    print(f"CHECK gain.values        {len(g['values'])}  (~END*10={round(END*10)})")
    print(f"CHECK dsh.frames         {len(frames)}  (~211*12={211*12})")
    print(f"CHECK dsh.bin            { (OUT/'dsh.bin').stat().st_size } B "
          f"(raw {json.loads((OUT/'dsh_meta.json').read_text(encoding='utf8'))['raw_size']} B)")
    dsh_av = sorted({f["avatar"] for f in frames if f["avatar"]})
    copied = list(DSH_AVATARS.rglob("*.png"))
    theme_n = sum(1 for f in frames if len(f.get("theme", ())) > 1 and f["theme"][1])
    dot_n = sum(1 for f in frames if any(r["role"] == "dot" for r in f["rows"]))
    print(f"CHECK dsh.avatars        referenced {len(dsh_av)}  copied {len(copied)}")
    print(f"CHECK dsh.theme          brand non-empty {theme_n}/{len(frames)}")
    print(f"CHECK dsh.dot            frames with a dot row {dot_n}")
    assert len(copied) == len(dsh_av), (len(copied), len(dsh_av))
    hg = json.loads((OUT / "her_glyph.json").read_text(encoding="utf8"))
    n_expr = len(hg["expressions"])
    lens = sorted({len(v["chars"]) for v in hg["expressions"].values()})
    print(f"CHECK her_glyph          {n_expr} expressions, chars lens {lens} (=44*36={44*36})")
    print(f"CHECK panes.corpus       {len(panes['corpus'])} fragments")
    print(f"CHECK panes.loss.noise   {len(panes['loss']['noise'])}")
    print(f"CHECK panes.memory.dig   {len(panes['memory']['dig'])} names in {panes['memory']['span']}")
    print(f"CHECK panes.moe          rank {len(panes['moe']['rank'])} routed {len(panes['moe']['routed'])}")
    print(f"CHECK panes.whale        {len(panes['whale']['frames'])} frames f0={panes['whale']['f0']}")
    print(f"CHECK panes.mask.cells   {len(panes['mask']['cells'])} (=MN*MN={panes['mask']['n'] ** 2})")
    print(f"CHECK panes.expert.gauss {len(panes['expert']['gauss'])} "
          f"(=EXPERT_ROWS*EXPERT_COLS={panes['expert']['rows'] * panes['expert']['cols']})")
    print(f"CHECK panes.love.per_row {panes['love']['per_row']}")
    print(f"CHECK panes.banner       rows {sorted(panes['banner']['rows'].keys(), key=int)}")
    print(f"CHECK songs/count        song={ (OUT/'song.mp3').stat().st_size } B")
    # ---- her 三条渲染路径 ----
    sp = json.loads((OUT / "her_sprite.json").read_text(encoding="utf8"))
    sizes = [tuple(v["size"]) for v in sp["sprites"].values()]
    png_n = len([p for p in SPRITE_DIR.glob("*.png")])
    print(f"CHECK her_sprite         {len(sp['sprites'])} sprites, {png_n} png, sizes {sorted(set(sizes))}")
    print(f"CHECK her_sprite.aspects " + "  ".join(f"{k}={sp['aspects'][k]:.4f}" for k in CROP_NAMES))
    tk = json.loads((OUT / "h3_takes.json").read_text(encoding="utf8"))
    print(f"CHECK h3_takes           {len(tk['takes'])} takes, {tk['total_frames']} frames, "
          f"ink {tk['ink']} {tk['rows']}x{tk['cols']}, charset {tk['charset']!r}")
    print(f"CHECK h3_takes.bin       { (OUT/'h3_takes.bin').stat().st_size } B "
          f"(raw {tk['raw_size']} B), plan {len(tk['plan'])} segs")
    print(f"CHECK h3_ramp            256 blue + 256 red, 8-level blue/red")
    hf = json.loads((OUT / "h3_flow.json").read_text(encoding="utf8"))
    print(f"CHECK h3_flow            {hf['count']} f32, cps {hf['cps']}, song_len {hf['song_len']}")
    print(f"CHECK h3_text            {len(json.loads((OUT/'h3_text.json').read_text(encoding='utf8')))} lines")
    print(f"CHECK her_morph          {len(json.loads((OUT/'her_morph.json').read_text(encoding='utf8')))} thresholds")
    print(f"CHECK points_set         {points['count']} pts, stride {points['stride']}, "
          f"{ (OUT/'points_set.bin').stat().st_size } B")
    print(f"CHECK whale_fall         t0={whale['t0']:.2f} tc={whale['tc']:.2f} "
          f"shed={whale['shed']} contact={whale['contact']} words={whale['words']}")
    # spot checks
    print("\n---- spot checks ----")
    print("shots[0]  :", json.dumps(shots[0], ensure_ascii=False))
    print("shots[32] :", json.dumps(shots[32], ensure_ascii=False))
    print("shots[95] :", json.dumps(shots[95], ensure_ascii=False))
    first = words["lines"][0]
    print("opening lyric:", first["text"], "->", lyric_cn.get(first["text"]))
    print("dsh.frames[0]:", json.dumps(frames[0], ensure_ascii=False)[:400])


if __name__ == "__main__":
    main()
