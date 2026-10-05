#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 jump! 项目中的玩家实例剥离为测试项目下的独立子系统 player_system/。

用法:
    python extract_player_system.py [--source "L:/游戏项目/jump!"] [--target "L:/项目/测试"]

设计原则
--------
1. 行为零改动：.gd 脚本按字节原样复制，不修改任何逻辑。
2. uid 保持不变：脚本/场景/素材的 uid 原样保留，因此 .tscn 内部对
   eyes.tscn、player.gd、mist_*.png 等的 uid 引用依然成立。
3. 只改路径：把 res:// 前缀重定向到 res://player_system/ 下，
   并顺手把源项目拼错的 scipts/ 修正为 scripts/。
4. 幂等：重复执行只会覆盖同样的结果。
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

SOURCE_DEFAULT = Path(r"L:\游戏项目\jump!")
TARGET_DEFAULT = Path(r"L:\项目\测试")

# 拷贝进子系统的文件： (源相对路径, 目标相对路径)
MIST_FRAMES = [(f"assets/steve_anim/mist_{i:02d}.png", f"player_system/assets/fx/mist_{i:02d}.png")
               for i in range(1, 29)]

FILES: list[tuple[str, str]] = [
    # ---- 脚本（含 .uid，保证 uid 引用不破） ----
    ("scipts/player/player.gd", "player_system/scripts/player.gd"),
    ("scipts/player/player.gd.uid", "player_system/scripts/player.gd.uid"),
    ("scipts/player/eye.gd", "player_system/scripts/eye.gd"),
    ("scipts/player/eye.gd.uid", "player_system/scripts/eye.gd.uid"),
    # ---- 场景 ----
    ("scenes/player/player.tscn", "player_system/scenes/player.tscn"),
    ("scenes/player/eyes.tscn", "player_system/scenes/eyes.tscn"),
    # ---- 素材：玩家本体 ----
    ("assets/player/player.png", "player_system/assets/player/player.png"),
    ("assets/player/player.png.import", "player_system/assets/player/player.png.import"),
    ("assets/player/eyes2-1.png", "player_system/assets/player/eyes2-1.png"),
    ("assets/player/eyes2-1.png.import", "player_system/assets/player/eyes2-1.png.import"),
    # ---- 素材：烟雾（Steve 死亡特效，28 帧） ----
    *[(s, t) for s, t in MIST_FRAMES],
    *[(s + ".import", t + ".import") for s, t in MIST_FRAMES],
    # ---- 素材：音频 ----
    ("assets/FIX/我的世界玩家受伤.ogg", "player_system/assets/audio/我的世界玩家受伤.ogg"),
    ("assets/FIX/我的世界玩家受伤.ogg.import", "player_system/assets/audio/我的世界玩家受伤.ogg.import"),
    ("assets/FIX/天堂光芒_爱给网_aigei_com.mp3", "player_system/assets/audio/天堂光芒_爱给网_aigei_com.mp3"),
    ("assets/FIX/天堂光芒_爱给网_aigei_com.mp3.import", "player_system/assets/audio/天堂光芒_爱给网_aigei_com.mp3.import"),
    ("assets/FIX/我的世界 经验球 升级.ogg", "player_system/assets/audio/我的世界 经验球 升级.ogg"),
    ("assets/FIX/我的世界 经验球 升级.ogg.import", "player_system/assets/audio/我的世界 经验球 升级.ogg.import"),
]

# 文本文件内需要重定向的 res:// 前缀（顺序敏感：长前缀在前）
PATH_REWRITES: list[tuple[str, str]] = [
    ("res://scipts/player/", "res://player_system/scripts/"),
    ("res://scenes/player/", "res://player_system/scenes/"),
    ("res://assets/player/", "res://player_system/assets/player/"),
    ("res://assets/steve_anim/", "res://player_system/assets/fx/"),
    ("res://assets/FIX/", "res://player_system/assets/audio/"),
    # .import 的 source_file 行同样按上面的规则改写；下面是兜底：
    ("res://assets/", "res://player_system/assets/"),
]

TEXT_SUFFIXES = {".tscn", ".tres", ".import", ".gd", ".cfg", ".godot"}

# 剥离之后在子系统里做过的本地改动：脚本重跑时**不要**覆盖它们，
# 而是把源项目版本另存为 *.from_source 供人工比对。
LOCALLY_MODIFIED = {
    "player_system/scripts/player.gd",   # 缩放补偿 / 空中阻力 / D7 眼睛调用 / D9 去 Environment /
                                         # D11 信号化死亡 API / D12 @export / D13 重命名 / D5 注释
    "player_system/scripts/eye.gd",      # D7 表情状态机幂等 + 职责拆分 / D2 已知限制注释
    "player_system/scenes/player.tscn",  # D14 去烟雾 SpriteFrames / D9 去 WorldEnvironment /
                                         # D11 去预制死亡动画与音频，只留 DeathAnimation 扩展点
    "player_system/scenes/eyes.tscn",    # D1 修复：chiler 末帧 null → 睁眼图集
}


def rewrite_text(text: str) -> str:
    for old, new in PATH_REWRITES:
        text = text.replace(old, new)
    return text


def _import_dest(res_import: Path) -> str | None:
    """从 .import 文件里取出 [remap] path= 指向的 res:// 缓存路径。"""
    for line in res_import.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s.startswith("path=\"res://"):
            return s[len("path=\""):].rstrip("\"")
    return None


def copy_import_cache(source: Path, target: Path, src_import_rel: str) -> int:
    """把源项目 .godot/imported 里的缓存产物（.ctex/.oggvorbisstr/... 与 .md5）搬到目标项目。

    Godot 的独立运行时（非编辑器）不会重新导入资源，只会读取既有缓存；
    而缓存名与 source_md5 都与源文件字节绑定，此处源文件是逐字节复制的，
    因此搬运缓存自洽，编辑器下次打开也只会校验通过、不必重导。
    """
    dest_res = _import_dest(source / src_import_rel)
    if dest_res is None:
        return 0

    cache_name = dest_res.replace("res://", "").split("/")[-1]
    copied = 0
    # Godot 的校验文件命名规则：产物名去掉扩展名后加 .md5
    for name in (cache_name, Path(cache_name).stem + ".md5"):
        src_cache = source / ".godot" / "imported" / name
        if src_cache.is_file():
            dst_cache = target / ".godot" / "imported" / name
            dst_cache.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_cache, dst_cache)
            copied += 1
    return copied


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=str(SOURCE_DEFAULT))
    ap.add_argument("--target", default=str(TARGET_DEFAULT))
    args = ap.parse_args()

    source = Path(args.source)
    target = Path(args.target)

    if not (source / "project.godot").is_file():
        print(f"[x] 源项目不存在或不是 Godot 项目: {source}", file=sys.stderr)
        return 1
    if not (target / "project.godot").is_file():
        print(f"[x] 目标项目不存在或不是 Godot 项目: {target}", file=sys.stderr)
        return 1

    copied = 0
    rewritten = 0
    cached = 0
    protected: list[str] = []
    missing: list[str] = []

    for src_rel, dst_rel in FILES:
        src = source / src_rel
        dst = target / dst_rel
        if not src.is_file():
            missing.append(src_rel)
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst_rel in LOCALLY_MODIFIED and dst.is_file():
            # 保留本地改动，源版本落盘到 *.from_source 以便 diff
            dst = dst.with_name(dst.name + ".from_source")
            protected.append(dst_rel)
        if src.suffix.lower() in TEXT_SUFFIXES:
            raw = src.read_text(encoding="utf-8")
            new = rewrite_text(raw)
            dst.write_text(new, encoding="utf-8", newline="")
            if new != raw:
                rewritten += 1
        else:
            shutil.copy2(src, dst)
        copied += 1
        if src_rel.endswith(".import"):
            cached += copy_import_cache(source, target, src_rel)

    print(f"[+] 已复制 {copied} 个文件到 {target / 'player_system'}")
    print(f"[+] 其中 {rewritten} 个文本文件完成了 res:// 路径重定向")
    print(f"[+] 已搬运 {cached} 个导入缓存文件到 .godot/imported（免编辑器重导）")
    if protected:
        print(f"[i] 以下 {len(protected)} 个文件存在本地改动，未被覆盖，源版本另存为 *.from_source：")
        for p in protected:
            print(f"    - {p}")
    if missing:
        print(f"[!] 缺失 {len(missing)} 个源文件:")
        for m in missing:
            print(f"    - {m}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
