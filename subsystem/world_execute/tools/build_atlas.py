"""Glyph atlas bake for the world_execute PV player port.

The Godot side renders the whole 197x52 character grid with one shader that samples a
pre-baked glyph atlas (white glyph on transparent, one atlas cell == one terminal cell).
Baking it here (instead of building a FontFile at runtime) has three advantages:

* exactly monospaced: the atlas cell *is* the terminal cell, so nothing can drift;
* CJK is split into two single-width halves at bake time, so the shader never needs
  to know about double-width characters (`wide` chars consume two consecutive slots);
* no runtime font dependency (the port needs no system font at run time).

Input : data/*.json (produced by tools/build_data.py) + Windows system fonts.
Output: data/glyphs.png (atlas), data/glyphs.json (metrics + char -> [slot, width]).

    $env:PYTHONIOENCODING="utf-8"; python build_atlas.py

Idempotent: re-running produces identical output.

Font notes (measured on this machine, see the WARN line the script prints):
* Consolas (consola.ttf) is the terminal font: its advance is exactly CELL_W px at size 16,
  and it has the box-drawing set. It does *not* have the block/shade elements
  (U+2581..U+259F), which a terminal nevertheless needs for bars and the waveform ramp --
  those are synthesised here so they tile pixel-perfectly instead of coming out as tofu.
* Microsoft YaHei (msyh.ttc) supplies every CJK character the data contains.
* A glyph is rejected when it renders exactly like the font's own .notdef box, which is how
  missing characters are detected without a cmap library.
"""
from __future__ import annotations

import json
import os
import unicodedata
import zlib
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

DATA = Path(__file__).resolve().parent.parent / "data"
OUT_PNG = DATA / "glyphs.png"
OUT_JSON = DATA / "glyphs.json"

# One terminal cell in pixels. MUST match CELL_W / CELL_H in scripts/pv.gd.
CELL_W, CELL_H = 9, 18
# Atlas width in slots; slot -> (slot % ATLAS_COLS, slot // ATLAS_COLS).
ATLAS_COLS = 32
# Ink margin inside a cell, so antialiased edges can never bleed into the next slot.
MARGIN = 1

FONT_MONO = os.environ.get("PV_F_MONO", r"C:\Windows\Fonts\consola.ttf")
FONT_CJK = os.environ.get("PV_F_CJK", r"C:\Windows\Fonts\msyh.ttc")
FONT_SYM = os.environ.get("PV_F_SYM", r"C:\Windows\Fonts\seguisym.ttf")

# Characters the layout needs that never show up in the data files.
FIXED_EXTRA = "─│┌┐└┘├┤┬┴┼╭╮╰╯▀▄█▁▂▃▄▅▆▇▓▒░●⋯…▸┤›"

# Strings baked in by the Godot panels rather than read from data/*.json -- keep this in
# sync with the literals in scripts/*.gd (the atlas must contain every printed character).
UI_LITERALS = (
    "WORLD.EXECUTE(ME); whale@deepsea:~ running paused lyric log feature bands ops "
    "大肥鱼 运行中 已连接 未连接 未探测 网络可用 请求失败 在吗？——没人回答。"
    "尺度 时间戳 电流 电源 开关 打开电源 保护措施 记忆 输入禁用"
)

# The 20 chapter panes' non-ASCII literals (see PANES_LITERALS in build_data.py); the rest of their
# text is ASCII or already in FIXED_EXTRA/RAMP/SCRAMBLE.
PANES_LITERALS = "·▪■║╲╱▼°Δθ∞"

ZERO_WIDTH = "\u200b\u200c\u200d\u00ad\ufeff\u2060"   # ZWSP/ZWNJ/ZWJ/SHY/BOM/word-joiner

NOTDEF_PROBE = "\uffff"     # never assigned -> whatever the font draws *is* its .notdef box


def collect_chars() -> list[str]:
    """Every character the player can print: ASCII + everything found in the data files."""
    chars: set[str] = {chr(c) for c in range(32, 127)}
    chars.update(FIXED_EXTRA)
    chars.update(UI_LITERALS)
    chars.update(PANES_LITERALS)

    def walk(node) -> None:
        if isinstance(node, str):
            chars.update(node)
        elif isinstance(node, dict):
            for k, v in node.items():
                walk(k)
                walk(v)
        elif isinstance(node, (list, tuple)):
            for v in node:
                walk(v)

    for name in ("lyrics_cn.json", "words.json", "boot_log.json", "dsh.json",
                 "chapters.json", "shots.json", "cursor.json", "panes.json"):
        p = DATA / name
        if p.exists():
            walk(json.loads(p.read_text(encoding="utf8")))

    # build_data.py 现在把 dsh 快照压成 dsh.bin（zlib），字符仍要收进来，
    # 否则图集缺字、面板上的聊天内容会变空白。
    dsh_bin = DATA / "dsh.bin"
    dsh_meta = DATA / "dsh_meta.json"
    if dsh_bin.exists() and dsh_meta.exists():
        walk(json.loads(zlib.decompress(dsh_bin.read_bytes()).decode("utf8")))

    chars.update("!<>-_\\/[]{}=+*^?#%$&@01|~:;")   # tui_live SCRAMBLE (L1310)
    chars.update(" ▁▂▃▄▅▆▇█")                       # tui_live RAMP (L128)
    for c in ("\n", "\r", "\t"):
        chars.discard(c)
    return sorted(chars, key=ord)


def is_wide(ch: str) -> bool:
    """Same test the reference player uses (tui_live.py `_wide_char`)."""
    return unicodedata.east_asian_width(ch) in "WF"


def load_font(path: str, size: int):
    if not Path(path).exists():
        return None
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return None


def fit_mono_size(path: str):
    """Pick the size whose 'M' advance is closest to CELL_W (keeps the grid monospaced)."""
    best, best_err, best_adv = None, 1e9, 0.0
    for size in range(8, 30):
        f = load_font(path, size)
        if f is None:
            break
        adv = f.getlength("M")
        if abs(adv - CELL_W) < best_err:
            best, best_err, best_adv = f, abs(adv - CELL_W), adv
        if adv > CELL_W + 1:
            break
    if best is None:
        raise SystemExit(f"cannot load {path}")
    return best, best_adv


# ---------------------------------------------------------------- rendering one glyph

def render_narrow(ch: str, font, baseline: int) -> Image.Image | None:
    """ASCII / box drawing / symbols: pen-aligned on a shared baseline.

    Pen alignment (and not ink centring) is what keeps box-drawing characters tiling
    seamlessly from one cell into the next, like a real terminal.

    Returns the full CELL_W x CELL_H canvas (never a cropped ink box): the glyph's
    offset inside the cell is the whole point, and the caller pastes at (0, 0).
    """
    canvas = Image.new("L", (CELL_W, CELL_H), 0)
    tmp = Image.new("L", (CELL_W + 48, CELL_H + 48), 0)
    ImageDraw.Draw(tmp).text((24, baseline + 24), ch, font=font, anchor="ls", fill=255)
    bbox = tmp.getbbox()
    if bbox is None:
        return None
    # tmp keeps a 24 px border: tmp_x = cell_x + 24 and tmp_y = cell_y + 24 (the baseline
    # is baked into the tmp y already), so the border is the only thing to subtract.
    canvas.paste(255, (bbox[0] - 24, bbox[1] - 24), tmp.crop(bbox))
    return canvas


def render_wide(ch: str, font) -> Image.Image | None:
    """CJK: centred in a 2-cell-wide box (CJK glyphs are square, so this is on-grid)."""
    w = CELL_W * 2
    canvas = Image.new("L", (w, CELL_H), 0)
    tmp = Image.new("L", (w + 64, CELL_H + 64), 0)
    ImageDraw.Draw(tmp).text((w // 2 + 32, CELL_H // 2 + 32), ch, font=font,
                             anchor="mm", fill=255)
    bbox = tmp.getbbox()
    if bbox is None:
        return None
    canvas.paste(255, (bbox[0] - 32, bbox[1] - 32), tmp.crop(bbox))
    return canvas


def synth(ch: str, px, w: int, h: int) -> bool:
    """Block / shade / box-drawing elements, drawn arithmetically into `px`.

    These are synthesised rather than taken from the font because a font glyph is sized
    for its own idea of the line box: Consolas' box strokes stop two pixels short of the
    cell, which turns a panel border into a dotted line, and it has no block elements at
    all. Drawing them by hand makes bars, ramps and borders tile pixel-perfectly instead.

    Returns False when `ch` is not a synthesised element (the caller then tries the fonts).
    """
    if _synth_box(ch, px, w, h):
        return True

    if ch == "█":
        fill = lambda x, y: True
    elif ch == "▀":
        fill = lambda x, y: y < h // 2
    elif ch == "▄":
        fill = lambda x, y: y >= (h + 1) // 2
    elif ch in "▁▂▃▄▅▆▇":
        n = "▁▂▃▄▅▆▇".index(ch) + 1
        rows = max(1, round(n * h / 8.0))
        fill = lambda x, y: y >= h - rows
    elif ch == "░":
        fill = lambda x, y: (x + y) % 4 == 0
    elif ch == "▒":
        fill = lambda x, y: (x + y) % 2 == 0
    elif ch == "▓":
        fill = lambda x, y: (x + y) % 4 != 0 or (x % 2 == 1 and y % 2 == 1)
    elif ch in ("⋯", "…"):
        # Just above the baseline, the same rows Consolas puts U+2026 on, so both match.
        for cx in (1, 4, 7):
            for dx in range(2):
                px[min(w - 1, cx + dx), h - 8] = 255
                px[min(w - 1, cx + dx), h - 7] = 255
        return True
    else:
        return False
    for y in range(h):
        for x in range(w):
            if fill(x, y):
                px[x, y] = 255
    return True


# Stroke geometry of the synthesised box-drawing set. BOX_HY is the optical centre of a
# text line at this cell size (cap height 11 -> letters span rows 1..11); BOX_VX is the
# pen centre of the cell, which is where a one-column border line has to sit.
BOX_HY, BOX_VX = 6, 4

# ch -> (horizontal segment, vertical segment); each segment is a (from, to) span on the
# stroke's own axis, or None. Segments always meet, so corners and tees can never crack.
BOX_SPANS: dict[str, tuple[tuple[int, int] | None, tuple[int, int] | None]] = {
    "─": ((0, CELL_W), None),
    "│": (None, (0, CELL_H)),
    "┌": ((BOX_VX, CELL_W), (BOX_HY, CELL_H)),
    "┐": ((0, BOX_VX + 1), (BOX_HY, CELL_H)),
    "└": ((BOX_VX, CELL_W), (0, BOX_HY + 1)),
    "┘": ((0, BOX_VX + 1), (0, BOX_HY + 1)),
    "├": ((BOX_VX, CELL_W), (0, CELL_H)),
    "┤": ((0, BOX_VX + 1), (0, CELL_H)),
    "┬": ((0, CELL_W), (BOX_HY, CELL_H)),
    "┴": ((0, CELL_W), (0, BOX_HY + 1)),
    "┼": ((0, CELL_W), (0, CELL_H)),
    # Rounded corners: the square ones with the corner pixel left out.
    "╭": ((BOX_VX + 1, CELL_W), (BOX_HY + 1, CELL_H)),
    "╮": ((0, BOX_VX), (BOX_HY + 1, CELL_H)),
    "╰": ((BOX_VX + 1, CELL_W), (0, BOX_HY)),
    "╯": ((0, BOX_VX), (0, BOX_HY)),
}


def _synth_box(ch: str, px, w: int, h: int) -> bool:
    spans = BOX_SPANS.get(ch)
    if spans is None:
        return False
    hspan, vspan = spans
    if hspan is not None:
        for x in range(hspan[0], hspan[1]):
            px[x, BOX_HY] = 255
    if vspan is not None:
        for y in range(vspan[0], vspan[1]):
            px[BOX_VX, y] = 255
    return True


# ---------------------------------------------------------------- bake

def bake() -> tuple[Image.Image, dict, list[str], list[str]]:
    chars = collect_chars()
    mono, mono_adv = fit_mono_size(FONT_MONO)
    cjk = load_font(FONT_CJK, CELL_H)
    sym = load_font(FONT_SYM, mono.size)
    _ascent, descent = mono.getmetrics()
    baseline = max(2, CELL_H - MARGIN - max(1, descent))

    # .notdef probe per (font, render mode): the bytes a font emits for a codepoint it
    # does not have. Keyed by mode too, because the wide and narrow paths crop differently.
    notdef: dict[tuple[str, bool], bytes | None] = {}
    for tag, font in (("m", mono), ("c", cjk), ("s", sym)):
        if font is None:
            notdef[(tag, False)] = None
            notdef[(tag, True)] = None
            continue
        probe_narrow = render_narrow(NOTDEF_PROBE, font, baseline)
        probe_wide = render_wide(NOTDEF_PROBE, font)
        notdef[(tag, False)] = probe_narrow.tobytes() if probe_narrow is not None else None
        notdef[(tag, True)] = probe_wide.tobytes() if probe_wide is not None else None

    entries: dict[str, list[int]] = {}
    slots: list[Image.Image] = [Image.new("L", (CELL_W, CELL_H), 0)]   # slot 0 = blank
    slot = 1
    undefined: list[str] = []

    for ch in chars:
        if ch == " ":
            entries[ch] = [0, 1]
            continue
        if ch in ZERO_WIDTH or unicodedata.combining(ch) or \
                unicodedata.category(ch) in ("Cf", "Mn", "Me", "Cc"):
            entries[ch] = [0, 0]    # zero-width (ZWSP & friends): consumes no cell
            continue
        wide = is_wide(ch)
        if unicodedata.category(ch) == "Zs":    # other blanks (U+3000 &c): empty but wide
            entries[ch] = [0, 2 if wide else 1]
            continue
        ink: Image.Image | None = None
        if not wide:                # every synthesised element is one cell wide
            canvas = Image.new("L", (CELL_W, CELL_H), 0)
            if synth(ch, canvas.load(), CELL_W, CELL_H):
                ink = canvas
        if ink is None:
            ink = _try_fonts(ch, wide, mono, cjk, sym, baseline, notdef)
        if ink is None:
            undefined.append(ch)
            ink = (render_wide("?", cjk) if (wide and cjk is not None)
                   else render_narrow("?", mono, baseline))
            if ink is None:
                ink = Image.new("L", (CELL_W * (2 if wide else 1), CELL_H), 0)
        if wide:
            entries[ch] = [slot, 2]
            slot += 2
            big = Image.new("L", (CELL_W * 2, CELL_H), 0)
            big.paste(ink, (0, 0))
            slots.append(big.crop((0, 0, CELL_W, CELL_H)))
            slots.append(big.crop((CELL_W, 0, 2 * CELL_W, CELL_H)))
        else:
            entries[ch] = [slot, 1]
            slot += 1
            slots.append(ink)

    rows = (len(slots) + ATLAS_COLS - 1) // ATLAS_COLS
    coverage = Image.new("L", (ATLAS_COLS * CELL_W, rows * CELL_H), 0)
    for i, cell in enumerate(slots):
        coverage.paste(cell, ((i % ATLAS_COLS) * CELL_W, (i // ATLAS_COLS) * CELL_H))

    rgba = Image.new("RGBA", coverage.size, (255, 255, 255, 0))
    rgba.putalpha(coverage)
    rgba.save(OUT_PNG, optimize=True)

    metrics = {
        "cell_w": CELL_W,
        "cell_h": CELL_H,
        "atlas_cols": ATLAS_COLS,
        "atlas_rows": rows,
        "slot_count": len(slots),
        "baseline": baseline,
        "fonts": {"mono": FONT_MONO, "mono_size": mono.size,
                  "mono_advance": round(mono_adv, 3),
                  "cjk": FONT_CJK, "cjk_size": cjk.size if cjk else 0,
                  "sym": FONT_SYM},
        "synthesised": sorted(set(BOX_SPANS) | set("█▀▄▁▂▃▄▅▆▇░▒▓⋯…")),
        "chars": entries,
    }
    OUT_JSON.write_text(json.dumps(metrics, ensure_ascii=False, separators=(",", ":")),
                        encoding="utf8")

    print(f"OK {OUT_PNG.name} {OUT_PNG.stat().st_size}B  {coverage.width}x{coverage.height}px")
    print(f"OK {OUT_JSON.name} {OUT_JSON.stat().st_size}B")
    print(f"   slots={len(slots)} narrow={sum(1 for e in entries.values() if e[1] == 1)}"
          f" wide={sum(1 for e in entries.values() if e[1] == 2)}"
          f" mono_size={mono.size} advance={mono_adv:.2f} baseline={baseline}")
    if undefined:
        print(f"   WARN {len(undefined)} chars had no glyph: {''.join(undefined)}")
    return coverage, metrics, undefined


def _try_fonts(ch: str, wide: bool, mono, cjk, sym, baseline: int,
               notdef: dict[tuple[str, bool], bytes | None]) -> Image.Image | None:
    """First font that has a real glyph for `ch` (a .notdef box does not count)."""
    order = [("c", cjk), ("s", sym)] if wide else [("m", mono), ("s", sym), ("c", cjk)]
    for tag, font in order:
        if font is None:
            continue
        ink = render_wide(ch, font) if wide else render_narrow(ch, font, baseline)
        if ink is None:
            continue
        if ink.tobytes() == notdef.get((tag, wide)):
            continue            # the font rendered its "missing glyph" box
        return ink
    return None


def preview(coverage: Image.Image, metrics: dict) -> None:
    """Render a few representative lines with the baked atlas, for eyeballing."""
    lines = [
        "WORLD.EXECUTE(ME);  whale@deepsea:~   03:12.4 / 03:32  00 / BOOT",
        "┌─ /dev/me  pid 4471 ───────┬─ feature bands ──┬─ ops ────┐",
        "│ ▁▂▃▅▇█ ▓▒░ ●⋯▸ ╭╮╰╯ ├┤ ┤│ ▁▃▅▇ ▂▄▆█ ░▒▓█          │",
        "> Switch on the power line",
        "// 打开电源    [ 电源 ] [ 开关 ] [ 电流 ]",
        "lyric log   > Remember to put on protection",
        "issue: EPERM  →  在吗？—— 没人回答。",
    ]
    cols = metrics["atlas_cols"]
    chars = metrics["chars"]
    grid = Image.new("L", (197 * CELL_W, len(lines) * CELL_H), 0)
    for r, line in enumerate(lines):
        x = 0
        for ch in line:
            if x >= 197:
                break
            idx, wide = chars.get(ch, chars.get("?") or [0, 1])
            for k in range(wide):
                if x + k >= 197:
                    break
                i = idx + k
                ax, ay = (i % cols) * CELL_W, (i // cols) * CELL_H
                grid.paste(coverage.crop((ax, ay, ax + CELL_W, ay + CELL_H)),
                           ((x + k) * CELL_W, r * CELL_H))
            x += wide
    out = Path(os.environ.get("TEMP", ".")) / "world_execute_atlas_preview.png"
    grid.save(out)
    print(f"   preview -> {out}")


if __name__ == "__main__":
    coverage, metrics, _undefined = bake()
    preview(coverage, metrics)
