extends Node

## world_execute 子系统 headless 自测入口。
##
## 只测纯逻辑（图集契约、调色/节拍数学、镜头表、数据取法、字符格缓冲），不碰纹理与窗口——
## 沙箱里没有 GPU，纹理创建会失败（参考 shader_preview 的教训）。真实渲染走 world_execute.tscn。
##
## 运行方式（headless）：
##   godot --headless --path <项目> res://subsystem/world_execute/tests/world_execute_smoke_test.tscn
## 退出码：0 = 全部通过，1 = 有失败，2 = 超时。

func _ready() -> void:
	var runner := SmokeRunner.new()
	runner.name = "WorldExecuteSmokeRunner"
	get_tree().root.add_child.call_deferred(runner)


class SmokeRunner extends Node:
	const COLS := 197
	const ROWS := 52

	var _failures := PackedStringArray()
	var _checks := 0


	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		_run()


	func _run() -> void:
		print("=== world_execute 自测开始 ===")
		_start_watchdog()
		await get_tree().process_frame

		var atlas := PvAtlas.new()
		_test_atlas(atlas)
		_test_palette()
		_test_beat()
		_test_shots()
		_test_data()
		_test_her()
		_test_stream()
		_test_screen(atlas)
		_test_panels(atlas)
		_test_dsh_window(atlas)
		_test_panes(atlas)
		_test_fx(atlas)
		_test_c_layer(atlas)
		_test_world_api()

		_finish()


	# ------------------------------------------------------------ 图集契约（与 build_atlas.py 一致）
	func _test_atlas(atlas: PvAtlas) -> void:
		_check(atlas.cell_w == 9 and atlas.cell_h == 18, "图集：cell 为 9×18")
		_check(atlas.atlas_cols == 32 and atlas.atlas_rows == 36, "图集：32 列 × 36 行槽位")
		_check(atlas.slot_count == 1129, "图集：槽位数 1129")
		_check(atlas.baseline == 12, "图集：基线 12")
		_check(atlas.texture != null, "图集：glyphs.png 已加载")
		if atlas.texture != null:
			_check(atlas.texture.get_size() == Vector2(288, 648), "图集：纹理尺寸 288×648")
		_check(atlas.slot_of(" ") == 0 and atlas.width_of(" ") == 1, "图集：空格 = 槽 0、单宽")
		_check(atlas.width_of("A") == 1, "图集：ASCII 单宽")
		_check(atlas.width_of("中") == 2, "图集：CJK 双宽")
		_check(atlas.width_of("　") == 2, "图集：全角空格双宽")
		_check(atlas.width_of("\u200b") == 0, "图集：零宽字符 width 0")
		var pairs := ["─", "│", "┌", "┐", "└", "┘", "█", "▀", "▁", "▇", "░", "▒", "▓", "⋯", "…", "●", "▸"]
		var missing := PackedStringArray()
		for ch in pairs:
			if not atlas.has_char(ch):
				missing.append(ch)
		_check(missing.is_empty(), "图集：盒线/块元素/符号齐备（缺：%s）" % ", ".join(missing))
		# 双宽字右半格必须是 slot+1（烘焙时已切成两半）
		var mid := atlas.slot_of("中")
		var after: Variant = atlas.chars.get("中")
		_check(after != null and int(after[0]) == mid, "图集：CJK 槽位可查（%d）" % mid)
		# 面板硬编码文案必须都在图集里，否则会渲成空白
		atlas.missing_chars.clear()
		atlas.scan_missing("WORLD.EXECUTE(ME); whale@deepsea:~ " + " ".join(PackedStringArray(PV.BANDS))
			+ " 输入禁用")
		for ch in PV.SPIN:
			atlas.scan_missing(ch)
		atlas.scan_missing(PV.SCRAMBLE)
		atlas.scan_missing(PV.RAMP)
		_check(atlas.missing_chars.is_empty(),
			"图集：界面文案/字符合集齐备（缺：%s）" % ", ".join(atlas.missing_chars))


	# ------------------------------------------------------------ 调色与增益（§1.2）
	func _test_palette() -> void:
		_check(PV.mix(PV.UI, 0.5) == PV.rgb(102, 110, 124), "mix：UI 以 0.5 混到 BG")
		_check(PV.mix(PV.UI, 1.0) == PV.UI, "mix：level 1 = 原色")
		_check(PV.mix(PV.UI, 0.0) == PV.BG, "mix：level 0 = 底色")
		_check(PV.mix(PV.UI, 5.0) == PV.UI, "mix：level 上钳到 1")
		_check(PV.mix(PV.UI, -1.0) == PV.BG, "mix：level 下钳到 0")
		PV.UI_GAIN = 1.0
		_check(PV.ui(1.0) == PV.UI, "ui：增益 1 时等于原色")
		PV.UI_GAIN = 0.42
		_check(PV.ui(1.0) == PV.mix(PV.UI, 0.42), "ui：增益 0.42 时整体衰减")
		PV.UI_GAIN = 0.0
		_check(PV.ui(1.0) == PV.BG, "ui：增益 0 时沉到底色")
		PV.UI_GAIN = 1.0
		_check(PV.to_color(PV.ANOM) == Color8(255, 204, 0), "to_color：ANOM = #FFCC00")


	# ------------------------------------------------------------ 节拍与呼吸（§1.4）
	func _test_beat() -> void:
		_check(absf(PV.BEAT - 0.461538) < 1e-5, "节拍：BEAT = 60/130")
		# t=0 还在首拍（0.1587）之前，所以索引为 -1 —— 与 tui_live 的 floor 公式一致
		_check(PV.beat_index(0.0) == -1, "节拍：t=0 在第 0 拍之前（索引 -1）")
		_check(PV.beat_index(PV.beat_t(1) + 0.001) == 1, "节拍：beat_t(1) 之后落在第 1 拍")
		_check(absf(PV.beat_t(3) - (PV.FIRST_BEAT + 3.0 * PV.BEAT)) < 1e-9, "节拍：beat_t(3)")
		var p := PV.pulse(PV.beat_t(5))
		_check(absf(p - 1.0) < 1e-3, "节拍：pulse 在拍点 = 1（实测 %.4f）" % p)
		_check(PV.pulse(PV.beat_t(5) + 0.14) < 0.4, "节拍：pulse 在拍后 0.14 s 衰减到 0.37")
		PV.NOW = PV.beat_t(2)
		_check(absf(PV.beat_level(1.0) - 1.24) < 1e-3, "节拍：拍点上的框亮度 = 1.24×基准")
		# 差一点到下一拍：pulse = exp(-BEAT/0.14)，亮度回到 ≈0.78（永远不会低于 0.76）
		var tail := exp(-PV.BEAT / 0.14)
		PV.NOW = PV.beat_t(5) - 0.001
		var lv := PV.beat_level(1.0)
		_check(absf(lv - (0.76 + 0.48 * tail)) < 2e-3,
			"节拍：远离拍点回落到 0.76-0.78（实测 %.4f）" % lv)
		PV.NOW = 0.0


	# ------------------------------------------------------------ 镜头表 / 章节 / 增益
	func _test_shots() -> void:
		_check(PvShots.shots().size() == 97, "镜头：97 个镜头")
		_check(PvShots.chapter_at(0.0) == "00 / BOOT", "章节：t=0 为 BOOT")
		_check(PvShots.chapter_at(16.0) == "01 / PRETRAIN", "章节：t=16 为 PRETRAIN")
		_check(PvShots.chapter_at(211.0) == "09 / WHALE_FALL", "章节：片尾为 WHALE_FALL")
		_check(absf(PvShots.chapter_start("EXECUTION") - 147.4) < 1e-6, "章节：EXECUTION 起点 147.4")
		_check(absf(PvShots.chapter_start("EVAL") - 176.9) < 1e-6, "章节：EVAL 起点 176.9")
		_check(absf(PvShots.chapter_start("没有这个章节", -1.0) + 1.0) < 1e-9, "章节：未知标签走 default")
		var i := PvShots.shot_index_at(147.7)
		_check(i == 64 and str(PvShots.shots()[i]["name"]) == "shot_exec_hit", "镜头：147.7 s 命中 64 号")
		_check(PvShots.shot_index_at(-5.0) == 0, "镜头：越界下界贴到 0 号")
		_check(PvShots.shot_index_at(999.0) == 96, "镜头：越界上界贴到 96 号")
		var ent := PvShots.shot_at(147.7)
		_check(str(ent.get("alert", "")) == "err", "镜头：exec_hit 的 alert = err")
		_check((ent.get("ops", []) as Array).size() > 0, "镜头：ops 列表非空")
		_check(absf(PvShots.meta().get("hard_cut", 0.0) - 207.0833) < 1e-3, "元数据：片尾硬切 207.0833")
		_check(absf(PvShots.gain_at(0.0) - 1.0) < 1e-6, "增益：开场 1.0")
		_check(absf(PvShots.gain_at(116.5) - 0.42) < 1e-6, "增益：116.5 s 掉到 0.42")
		_check(absf(PvShots.gain_at(179.5) - 0.85) < 1e-6, "增益：179.5 s 回到 0.85")
		_check(absf(PvShots.ui_gain_at(150.0, "shot_red_if_i_can", 0.3) - 1.0) < 1e-6,
			"增益：red_if_i_can 恒 1.0")
		_check(PvShots.portrait_shots().has("shot_exec_hit"), "立绘：portrait_shots 含 exec_hit")
		_check(PvShots.figure_spans().size() == 2, "立绘：figure_spans 两条")
		_check(PvShots.shot_wants_figure(58.5433, 60.6202), "立绘：SFT 段内的镜头要立绘")
		_check(not PvShots.shot_wants_figure(147.62, 148.54), "立绘：EXECUTION 段的镜头不要立绘")
		_check(PvShots.kv_inset(0.9) == 3 and PvShots.kv_inset(0.0) == 0, "立绘：kv_inset 0-3")
		_check(PvShots.dsh_spans().size() == 9, "dsh：9 个覆盖段")
		_check(PvShots.dsh_inside(10.0) and not PvShots.dsh_inside(3.0), "dsh：10 s 在窗内、3 s 不在")
		_check(PvShots.dsh_gone(117.0) and not PvShots.dsh_gone(100.0), "dsh：GONE 115.42-121.77")
		_check(not PV.SHAKE_SHOTS.has(str(PvShots.shot_at(150.0)["name"])), "抖动：exec_hit 不在 SHAKE 列表")
		_check(PV.CUT_MECH.has(7) and (PV.CUT_MECH[7] as Array).has("CARRY"), "cut：7 号含 CARRY")


	# ------------------------------------------------------------ 重数据取法
	func _test_data() -> void:
		var d := PvData.new()
		_check(d.wave.size() == 21191, "波形：21191 个 100 Hz u8 采样（实测 %d）" % d.wave.size())
		_check(d.rate == 48.0, "特征：采样率 48 Hz")
		_check(d.loud.size() == 10180, "特征：loud 10180 点")
		_check(d.bands.size() == 7, "特征：7 条频段")
		_check(d.lines.size() == 98, "歌词：98 行（实测 %d）" % d.lines.size())
		_check(d.line_at(0.5)[0] is Dictionary and not (d.line_at(0.5)[0] as Dictionary).is_empty(),
			"歌词：0.5 s 有当前行")
		_check((d.line_at(210.0)[0] as Dictionary).is_empty(), "歌词：片尾无当前行")
		var ln: Dictionary = d.lines[0]
		_check(str(ln["text"]) == "Switch on the power line", "歌词：首行文本")
		var typed := d.typed(ln, 0.06)
		_check(int(typed[0]) >= 1, "歌词：0.06 s 已打出首字符")
		_check((typed[1] as PackedFloat32Array).size() == str(ln["text"]).length(), "歌词：when 长度 = 文本长度")
		_check(d.typed(d.lines[0], 1.792)[0] == str(ln["text"]).length(), "歌词：行尾 1.792 s 全出（24 字符）")
		_check(d.wave_at(0) >= 0.0 and d.wave_at(0) <= 1.0, "波形：0 ms 取值在 0..1")
		_check(d.wave_at(10) == d.wave[1] / 255.0, "波形：10 ms = 第 2 个 100 Hz 桶")
		_check(d.wave_at(-5) == 0.0 and d.wave_at(999999999) == 0.0, "波形：越界返回 0")
		_check(d.feat(0.0, "kick") >= 0.0 and d.feat(0.0, "nope") == 0.0, "特征：未知曲线返回 0")
		_check(d.band_at(30.0, 0) >= 0.0 and d.band_at(30.0, 99) == 0.0, "频段：越界返回 0")
		_check(d.lyric_cn_for("Switch on the power line") == "打开电源", "歌词：中文对照")
		_check(d.lyric_cn_for("不存在的一句") == "", "歌词：无对照返回空")
		_check(d.boot_printed(1.0).size() >= 3, "boot：1.0 s 已打印 3 行以上")
		_check(d.boot_printed(0.0).is_empty(), "boot：0 s 一行未打印")
		_check(d.expression_names().size() == 8, "立绘：8 个表情（实测 %d）" % d.expression_names().size())
		var e := d.expression("cheerful")
		_check((e.get("chars", []) as Array).size() == 44 * 36, "立绘：44×36 字形格")
		var fr := d.dsh_at(5.3)
		_check(not fr.is_empty() and (fr.get("rows", []) as Array).size() == 2, "dsh：5.3 s 有两行")


	# ------------------------------------------------------------ 她的三条渲染路径（pv_her.gd）
	## 数据来自 tools/build_data.py 烘出的表；下面贴的真值都是 Python 侧（与烘焙同一管线）算出来
	## 再抄进来的。`h3_cells` / `frame_cells` 是纯查表，逐格精确；`halfblock` 里远离 alpha 边界的
	## 格子也已核对一致（Godot 的 LANCZOS 与 PIL 不同，边缘个别格子会差一级，见 README）。
	func _test_her() -> void:
		var exprs := ["cheerful", "starry", "shy", "serious", "confused", "frightened", "angry",
			"exasperated"]
		_check(PvHer.sprite_available() and PvHer.h3_available(),
			"her：立绘 PNG 与 h3 take 都已加载")
		var missing := PackedStringArray()
		for e in exprs:
			if PvHer._sprite_image(e) == null:
				missing.append(e)
		_check(missing.is_empty(), "her：8 张立绘 PNG 可加载（缺：%s）" % ", ".join(missing))
		_check(PvHer._sprite_image("cheerful").get_size() == Vector2i(285, 512),
			"her：cheerful 缩放后 285×512")
		_check(PvHer._sprite_image("confused").get_size() == Vector2i(284, 512),
			"her：confused（原图高 1683）缩放后 284×512")

		# -------- crop 矩形（原图分数 / alpha getbbox 按缩放比例换算）
		var cf := PvHer.crop_box("cheerful", "full")
		_check(int(cf[0]) == 2 and int(cf[1]) == 6 and int(cf[2]) == 282 and int(cf[3]) == 498,
			"her：full 裁剪矩形 %s" % str(cf))
		var cfa := PvHer.crop_box("cheerful", "face")
		_check(int(cfa[0]) == 57 and int(cfa[1]) == 0 and int(cfa[2]) == 165 and int(cfa[3]) == 133,
			"her：face 裁剪矩形 %s" % str(cfa))
		var cb := PvHer.crop_box("confused", "bust")
		_check(int(cb[0]) == 45 and int(cb[1]) == 0 and int(cb[2]) == 193 and int(cb[3]) == 174,
			"her：confused 的 bust 矩形 %s" % str(cb))
		_check(absf(PvHer.crop_aspect("full") - 0.5650580329871716) < 1e-9, "her：crop_aspect full")
		_check(absf(PvHer.crop_aspect("face") - 1.240274599542334) < 1e-9, "her：crop_aspect face")

		# -------- pick_crop / fit
		_check(PvHer.pick_crop(116, 30) == "face", "her：pick_crop(116,30) = face")
		_check(PvHer.pick_crop(70, 27) == "face", "her：pick_crop(70,27) = face")
		_check(PvHer.pick_crop(30, 13) == "bust", "her：pick_crop(30,13) = bust")
		_check(PvHer.fit(30, 13, "face") == [30, 12], "her：fit(30,13,face)")
		_check(PvHer.fit(116, 30, "face") == [78, 30], "her：fit(116,30,face)")

		# -------- halfblock（cheerful / face / 70×27）：真值 [67, 27] + 若干格
		var hb := PvHer.halfblock("cheerful", "face", 70, 27)
		var blk: PackedInt32Array = hb[0]
		var baw := int(hb[1])
		var bah := int(hb[2])
		_check(baw == 67 and bah == 27, "her：halfblock aw/ah = 67/27（实测 %d/%d）" % [baw, bah])
		_check(blk.size() == 67 * 27 * 2, "her：halfblock 扁平表长度 = aw*ah*2")
		var row0_clear := true
		for c in 12:
			if blk[(0 * baw + c) * 2] != -1 or blk[(0 * baw + c) * 2 + 1] != -1:
				row0_clear = false
		_check(row0_clear, "her：halfblock 第 0 行（头顶之外）全透明 = -1")
		var expect13 := [[5, 5], [5, 5], [5, 5], [5, 5], [5, 5], [6, 6], [7, 7], [7, 6], [7, 5],
			[7, 4], [7, 4], [7, 6]]
		var ok13 := true
		for i in 12:
			var c: int = 30 + i
			if blk[(13 * baw + c) * 2] != int(expect13[i][0]) \
					or blk[(13 * baw + c) * 2 + 1] != int(expect13[i][1]):
				ok13 = false
		_check(ok13, "her：halfblock 第 13 行 30..41 列 = 真值")
		_check(blk[(0 * baw) * 2] == -1, "her：halfblock 左上角透明")

		# -------- glyph_lines（shy / face / 30×13）：维度与字符集契约（Sobel 逐格与 PIL 有 LANCZOS 偏差）
		var gl := PvHer.glyph_lines("shy", "face", 30, 13)
		var lines: Array = gl[0]
		var bright: PackedByteArray = gl[1]
		_check(lines.size() == 13 and str(lines[12]).length() == 30, "her：glyph_lines 13 行 × 30 列")
		_check(bright.size() == 30 * 13, "her：glyph_lines bright 长度 = cols*rows")
		_check(str(lines[0]).strip_edges().is_empty(), "her：glyph_lines 第 0 行（顶部）全空")
		var allowed := " " + PvHer.GLYPH_RAMP + "|\\-/"
		var bad := 0
		for r in 13:
			var row := str(lines[r])
			for c in 30:
				if not allowed.contains(row.substr(c, 1)):
					bad += 1
		_check(bad == 0, "her：glyph_lines 只用了方向笔画 + 密度梯度字符（越界 %d）" % bad)

		# -------- h3_cells（纯查表，逐格精确）t = 60 s、116×30 窗格
		var hc := PvHer.h3_cells(60.0, 116, 30, "blue")
		_check(int(hc[1]) == 39 and int(hc[2]) == 30 and int(hc[3]) == 38 and int(hc[4]) == 0,
			"her：h3_cells(60,116,30) aw/ah/ox/oy = 39/30/38/0")
		var cells: Array = hc[0]
		_check(cells.size() == 30 and (cells[0] as Array).size() == 39, "her：h3 cells 30 行 × 39 列")
		var c10: Array = cells[10]
		_check(c10[3] == null, "her：h3 第 10 行 3 列空")
		var cell_a: Array = c10[4]
		_check(str(cell_a[0]) == "\\" and int(cell_a[1]) == PV.rgb(139, 161, 254) and int(cell_a[2]) == -1,
			"her：h3 cell(10,4) = 反斜线 / 0x8B9DFE / 无底色")
		var cell_b: Array = c10[5]
		_check(str(cell_b[0]) == "-" and int(cell_b[1]) == PV.rgb(139, 161, 254), "her：h3 cell(10,5)")
		var cell_c: Array = cells[29][32]
		_check(str(cell_c[0]) == "/" and int(cell_c[1]) == PV.rgb(178, 196, 254)
			and int(cell_c[2]) == PV.rgb(55, 78, 189),
			"her：h3 cell(29,32) = 斜线 / 前景 / 有底色")
		_check(cells[29][33] == null, "her：h3 cell(29,33) 空")
		_check(PvHer.h3_cells(60.0, 70, 27, "blue").slice(1, 5) == [39, 27, 15, 0],
			"her：h3_cells(60,70,27) aw/ah/ox/oy = 39/27/15/0")
		_check(PvHer.h3_cells(3.0, 3, 3, "blue")[1] == 0, "her：h3_cells 窗格过小返回空")

		# -------- frame_cells（t = 100 s、红色）：:` 格被歌词填、颜色走红 ramp
		var fc := PvHer.frame_cells(100.0, "red")
		var fcr: Array = fc[20]
		var fd: Array = fcr[5]
		_check(str(fd[0]) == "·" and int(fd[1]) == PV.rgb(72, 21, 24) and int(fd[2]) == -1,
			"her：红色 frame_cells(100) cell(20,5) = 歌词点")
		var fe: Array = fcr[6]
		_check(str(fe[0]) == "t" and int(fe[1]) == PV.rgb(139, 35, 32), "her：红色 frame_cells(100) cell(20,6)")

		# -------- source / join / flow / text
		_check(PvHer.h3_source(60.0) == ["groove", 40], "her：source(60) = groove/40")
		_check(PvHer.h3_source(33.5) == ["turn", 22], "her：source(33.5) = turn/22（knots 段）")
		_check(PvHer.h3_source(110.5) == ["reach", 2], "her：source(110.5) = reach/2（knots 段）")
		_check(PvHer.h3_source(0.5) == ["inspect", 8], "her：source(0.5) = inspect/8")
		_check(PvHer.flow_offset(0.5) == 1 and PvHer.flow_offset(60.0) == 361
			and PvHer.flow_offset(110.5) == 804, "her：flow_offset 1 / 361 / 804")
		_check(PvHer._join(60.0).is_empty(), "her：join(60) = 无拼接")
		var jj := PvHer._join(10.01)
		_check(jj.size() == 2 and jj[0] == ["inspect", 121] and absf(float(jj[1]) - 0.31) < 1e-6,
			"her：join(10.01) 用上一帧 inspect/121 拼 0.31")
		_check(PvHer.text_at(60.0) == "If·I·can,·if·I·can·/·Give·you·all·the·simulations·/·"
			+ "Then·I·can,·then·I·can·/·Be·your·only·satisfaction·//·", "her：text_at(60)")
		_check(PvHer.text_at(0.5) == "Switch·on·the·power·line·/·Remember·to·put·on·protection·/·"
			+ "Lay·down·your·pieces·/·And·let's·begin·object·creation·//·", "her：text_at(0.5)")

		# -------- 切换三分支 + glitch
		var order := PvHer.flip_order(4)
		_check(order.size() == 4 and absf(order[0] - 0.3238327648) < 1e-6,
			"her：flip_order = random.Random(7)（首值 %.8f）" % order[0])
		var m_off := PvHer.morph_mask(-1.0, order, 0, 60.0)
		_check(bool(m_off[0]) and not bool(m_off[1]), "her：morph_mask u<0 → 画、不毛刺")
		var m_g0 := PvHer.morph_mask(0.05, order, 0, 60.0)
		_check(not bool(m_g0[0]) and not bool(m_g0[1]), "her：morph gone 段 th>阈值 → 不画不毛刺")
		var m_g1 := PvHer.morph_mask(0.05, order, 1, 60.0)
		_check(not bool(m_g1[0]) and bool(m_g1[1]), "her：morph gone 段 th<阈值 → 只毛刺")
		var m_n := PvHer.morph_mask(0.9, PvHer.flip_order(20), 17, 60.0)
		_check(not bool(m_n[0]) and not bool(m_n[1]), "her：morph 未到段 th>v → 不画不毛刺")
		var m_a := PvHer.morph_mask(0.9, order, 0, 60.0)
		_check(bool(m_a[0]) and not bool(m_a[1]), "her：morph 到达段 → 画、不毛刺")
		var m_gl := PvHer.morph_mask(0.91, PvHer.flip_order(3053), 3052, 60.0)
		_check(bool(m_gl[0]) and bool(m_gl[1]), "her：morph 到达且贴前缘 → 画 + 毛刺")
		_check(PvHer.glitch_char(60.0, 5) == "]", "her：glitch_char(60,5) = ]")
		_check(PvHer.tint_ramp("blue").size() == 256 and PvHer.tint_ramp("red").size() == 256,
			"her：h3_ramp 蓝/红各 256 级")
		_check(PvHer.tint_ramp8("blue")[0] == PvPanels.TINT_BLUE_LO
			and PvHer.tint_ramp8("blue")[7] == PvPanels.TINT_BLUE_HI, "her：8 级蓝 ramp 两端点")

		# -------- her_style 判定链各条规则
		var p := PvPanels.new()
		PvPanels.HER_RENDER = "auto"
		PvPanels.LAST_HER = false
		_check(p.her_style({}) == "h3" and p.her_tint({}) == "blue", "her_style：无镜头 → h3/blue")
		_check(p.her_style({"name": "shot_if_i_can", "start": 59.0, "end": 61.0}) == "h3",
			"her_style：CHAR_SHOTS → h3")
		_check(p.her_tint({"name": "shot_exec_hit", "start": 147.7, "end": 148.5}) == "red"
			and p.her_style({"name": "shot_exec_hit", "start": 147.7, "end": 148.5}) == "half",
			"her_style：立绘表 → half + 电影自己的色")
		PvPanels.LAST_HER = true
		_check(p.her_style({"name": "shot_power", "start": 0.3, "end": 1.3}) == "half",
			"her_style：last_her → half")
		PvPanels.LAST_HER = false
		_check(p.her_style({"name": "shot_you_left", "alert": "err", "start": 150.0, "end": 151.0}) == "half"
			and p.her_tint({"name": "shot_you_left", "alert": "err", "start": 150.0, "end": 151.0}) == "red",
			"her_style：err + EXECUTION 之后 → half/red")
		_check(p.her_style({"name": "shot_love_loop", "start": 177.5, "end": 179.0}) == "h3"
			and p.her_tint({"name": "shot_love_loop", "start": 177.5, "end": 179.0}) == "red",
			"her_style：EVAL 之后 → h3/red")
		_check(p.her_style({"name": "shot_x", "start": 58.5433, "end": 60.6202}) == "half",
			"her_style：shot_wants_figure → half/blue")
		PvPanels.HER_RENDER = "glyph"
		_check(p.her_style({"name": "shot_love_loop", "start": 177.5, "end": 179.0}) == "glyph"
			and p.her_tint({"name": "shot_love_loop", "start": 177.5, "end": 179.0}) == "blue",
			"her_style：非 auto 时强制该路径 + blue")
		PvPanels.HER_RENDER = "auto"


	# ------------------------------------------------------------ B 层：文本流层（pv_stream.gd）
	## `term` 传 null → 不碰真终端（headless 建不出 `Terminal` 需要的渲染资源），只把打完的整行
	## 记进 `log`，于是时序 / 去重 / 跳转重放这些逻辑都能在 headless 下断言。真终端走 world_execute.tscn。
	func _test_stream() -> void:
		var d := PvData.new()

		# -------- 起步：先落章节条，再落 ops 首步（t=0 还没到任何 boot 行）
		var s := PvStream.new(null)
		_check(s.log.is_empty(), "文本流：初始无输出")
		s.step(0.0, d, PvShots.shot_at(0.0))
		_check(str(s.log[0]) == "== 00 / BOOT ==", "文本流：t=0 首行是章节条（%s）" % str(s.log[0]))
		_check(_has(s.log, "$ POWER.ON"), "文本流：t=0 落 ops 首步 POWER.ON")

		# -------- boot：条数与 boot_printed 完全一致
		s.step(1.0, d, PvShots.shot_at(1.0))
		_check(_count_prefix(s.log, "[") == d.boot_printed(1.0).size(),
			"文本流：1.0 s 的 boot 条数与 boot_printed 一致（%d）" % _count_prefix(s.log, "["))
		_check(_has(s.log, "[OK  ] power: 8x H800 online"), "文本流：boot 行带状态牌")

		# -------- 歌词：打字中只覆写当前行不落行；行尾整行 + 中文对照才落
		var sl := PvStream.new(null)
		sl.step(0.5, d, PvShots.shot_at(0.5))
		_check(not _has_prefix(sl.log, "~ "), "文本流：歌词打字中不落行")
		sl.step(2.0, d, PvShots.shot_at(2.0))
		_check(_has(sl.log, "~ Switch on the power line"), "文本流：首行歌词打完落行")
		_check(_has(sl.log, "  // 打开电源"), "文本流：歌词中文对照落行")
		_check(_count_prefix(sl.log, "~ ") < d.lines.size(),
			"文本流：2.0 s 只落了少数几行歌词（%d）" % _count_prefix(sl.log, "~ "))

		# -------- ops：半拍滚动一步；同一步不重复落行
		var so := PvStream.new(null)
		so.step(0.3, d, PvShots.shot_at(0.3))
		_check(_has(so.log, "$ POST"), "文本流：0.3 s ops 滚到中心步 POST")
		var n_ops := _count_prefix(so.log, "$ ")
		so.step(0.4, d, PvShots.shot_at(0.4))
		_check(_count_prefix(so.log, "$ ") == n_ops, "文本流：同一 ops 步不重复落行")

		# -------- dsh 聊天：只落白名单对话行；同一帧去重
		var sc := PvStream.new(null)
		sc.step(30.0, d, PvShots.shot_at(30.0))
		_check(_has_prefix(sc.log, "you> 你好"), "文本流：dsh 对话行（you>）")
		var n_chat := _chat_count(sc.log)
		_check(n_chat > 0, "文本流：dsh 窗内打出对话（%d 行）" % n_chat)
		sc.step(30.02, d, PvShots.shot_at(30.02))
		_check(_chat_count(sc.log) == n_chat, "文本流：同一 dsh 帧不重复落行")

		# -------- 前跳（> BIG_JUMP）：清屏 + 静默重放，内容与 t 对齐
		var before := so.log.size()
		so.step(17.0, d, PvShots.shot_at(17.0))
		_check(_has(so.log, "== 00 / BOOT ==") and _has(so.log, "== 01 / PRETRAIN =="),
			"文本流：重放把走过的章节条补齐")
		_check(_has(so.log, "~ Switch on the power line"), "文本流：重放把早先的歌词补齐")
		_check(_count_prefix(so.log, "[") == d.boot_printed(17.0).size(),
			"文本流：重放后 boot 条数与 t 对齐（%d）" % _count_prefix(so.log, "["))
		_check(so.log.size() != before, "文本流：跳转后输出被重置（%d → %d）" % [before, so.log.size()])

		# -------- 回退：同样重置重放，晚出的章节条不再出现
		so.step(3.0, d, PvShots.shot_at(3.0))
		_check(not _has(so.log, "== 01 / PRETRAIN =="), "文本流：回退后晚出的章节条被清掉")
		_check(_has(so.log, "== 00 / BOOT =="), "文本流：回退后只剩已走过的章节条")

		# -------- 关掉重开：seek 把状态按当前时刻铺回
		var sd := PvStream.new(null)
		sd.step(50.0, d, PvShots.shot_at(50.0))
		var at50 := sd.log.size()
		sd.enabled = false
		sd.step(51.0, d, PvShots.shot_at(51.0))
		_check(sd.log.size() == at50, "文本流：关掉后不再输出")
		sd.enabled = true
		sd.seek(51.0, d, PvShots.shot_at(51.0))
		_check(sd.log.size() > 0 and _has_prefix(sd.log, "["), "文本流：重开时 seek 把内容铺回")


	# ------------------------------------------------------------ 文本流断言工具
	func _has(lines: Array, text: String) -> bool:
		for l in lines:
			if str(l) == text:
				return true
		return false


	func _has_prefix(lines: Array, prefix: String) -> bool:
		for l in lines:
			if str(l).begins_with(prefix):
				return true
		return false


	func _count_prefix(lines: Array, prefix: String) -> int:
		var n := 0
		for l in lines:
			if str(l).begins_with(prefix):
				n += 1
		return n


	## dsh 对话行：只可能是白名单 role 的前缀（歌词 `~ ` / ops `$ ` / boot `[` / 章节 `== ` 都不撞）。
	func _chat_count(lines: Array) -> int:
		var n := 0
		for l in lines:
			var s := str(l)
			if s.begins_with("you> ") or s.begins_with("dsh> ") or s.begins_with("ai> "):
				n += 1
		return n



	# ------------------------------------------------------------ 字符格缓冲（§4）
	func _test_screen(atlas: PvAtlas) -> void:
		PV.FX["vig"] = true
		var s := PvScreen.new(atlas, COLS, ROWS)
		_check(s.cols == COLS and s.rows == ROWS, "屏幕：197×52")
		_check(s.dim.size() == COLS * ROWS, "屏幕：暗角场尺寸")
		_check(absf(s.dim[25 * COLS + 98] - 1.0) < 1e-6, "屏幕：正中不吃暗角")
		_check(s.dim[0] < 1.0, "屏幕：左上角吃暗角（%.3f）" % s.dim[0])
		_check(absf(s.dim[26 * COLS + 98] - PV.SCAN_DIM) < 1e-6, "屏幕：每三行一档扫描线 0.86")

		# put / 双宽
		s.put(1, 0, "WORLD.EXECUTE(ME);")
		_check(s.cp[1] == "W".unicode_at(0), "屏幕：put 写入首字符")
		_check(s.slot[1] == atlas.slot_of("W"), "屏幕：put 写入槽位")
		s.put(3, 5, "中")
		var i0 := 5 * COLS + 3
		_check(s.cp[i0] == "中".unicode_at(0), "屏幕：CJK 左半格写字")
		_check(s.wide[i0] == 0 and s.wide[i0 + 1] == 1, "屏幕：CJK 右半格标记 wide")
		_check(s.slot[i0 + 1] == s.slot[i0] + 1, "屏幕：CJK 右半格 = 左半 slot+1")
		_check(s.fg[i0] == s.fg[i0 + 1], "屏幕：CJK 两半同前景色")
		# 零宽字（ZWSP）：图集 width=0（无字形），但 put 仍把它写进本格并步进 1 —— 与 tui_live 一致
		var j0 := 7 * COLS + 3
		s.put(3, 7, "\u200bA")
		_check(s.cp[j0] == "\u200b".unicode_at(0), "屏幕：零宽字写入本格（槽位 = 0 空白）")
		_check(s.slot[j0] == 0, "屏幕：零宽字槽位为空白槽 0")
		_check(s.cp[j0 + 1] == "A".unicode_at(0), "屏幕：零宽字后光标步进 1 格")

		# 越界
		s.put(0, ROWS, "X")
		s.put(COLS - 1, 9, "XY")
		_check(s.cp[9 * COLS + COLS - 1] == "X".unicode_at(0), "屏幕：列越界只写第一格")

		# box：四角
		s.box(20, 20, 30, 25, "test")
		_check(s.cp[20 * COLS + 20] == "┌".unicode_at(0), "屏幕：box 左上角 ┌")
		_check(s.cp[20 * COLS + 30] == "┐".unicode_at(0), "屏幕：box 右上角 ┐")
		_check(s.cp[25 * COLS + 20] == "└".unicode_at(0), "屏幕：box 左下角 └")
		_check(s.cp[25 * COLS + 30] == "┘".unicode_at(0), "屏幕：box 右下角 ┘")
		_check(s.cp[20 * COLS + 21] == "─".unicode_at(0), "屏幕：box 上边线")
		_check(s.cp[21 * COLS + 20] == "│".unicode_at(0), "屏幕：box 左边线")
		# 标题铭牌（带旋转子）
		var plaque := ""
		for x in range(22, 29):
			plaque += char(s.cp[20 * COLS + x])
		_check(plaque.contains("test"), "屏幕：box 标题铭牌（%s）" % plaque)
		_check(s.bg[20 * COLS + 22] == PV.BG, "屏幕：标题铭牌底色为 BG")
		s.box(0, 0, 2, 4, "")
		_check(true, "屏幕：过窄的 box 直接返回不崩")

		# hbar：八分之一块精度
		s.hbar(0, 40, 10, 1.0, PV.UI)
		_check(s.cp[40 * COLS + 0] == "█".unicode_at(0), "屏幕：hbar 满值写满格")
		_check(s.cp[40 * COLS + 9] == "█".unicode_at(0), "屏幕：hbar 写满整条")
		var k0 := 41 * COLS
		s.hbar(0, 41, 10, 0.05, PV.UI)
		_check(s.cp[k0] == PV.RAMP.substr(4, 1).unicode_at(0), "屏幕：hbar 半格以下用 ▄")
		_check(s.cp[k0 + 1] == " ".unicode_at(0), "屏幕：hbar 余量之外不写")
		s.hbar(0, 42, 10, 0.0, PV.UI)
		_check(s.cp[42 * COLS] == " ".unicode_at(0), "屏幕：hbar 0 值不写")

		# fill
		s.fill(0, 43, 20, 44, " ")
		var filled := true
		for x in range(0, 21):
			if s.cp[43 * COLS + x] != " ".unicode_at(0):
				filled = false
		_check(filled, "屏幕：fill 清行")

		# CLEAR 不吃暗角
		var y := 1
		var x := 2
		var idx := y * COLS + x
		_check(s.dim[idx] < 0.9, "屏幕：该测试格确实在暗角里（%.3f）" % s.dim[idx])
		s.begin_frame(1.0)
		s.put(x, y, "X", PV.UI)
		var dimmed := s.fg[idx]
		s.begin_frame(1.0)
		s.add_clear(0, 0, 10, 3)
		s.put(x, y, "X", PV.UI)
		var clean := s.fg[idx]
		_check(dimmed != PV.UI and clean == PV.UI, "屏幕：CLEAR 内不吃暗角（%06X vs %06X）" % [dimmed, clean])
		_check(s.in_clear(x, y) and not s.in_clear(50, 40), "屏幕：CLEAR 命中判定")

		# 输出字节
		var data := s.to_data()
		var n := COLS * ROWS
		_check((data["idx"] as PackedByteArray).size() == n * 4, "屏幕：idx 纹理字节数")
		_check((data["fg"] as PackedByteArray).size() == n * 4, "屏幕：fg 纹理字节数")
		_check((data["bg"] as PackedByteArray).size() == n * 4, "屏幕：bg 纹理字节数")
		var bytes: PackedByteArray = data["idx"]
		var o := (20 * COLS + 20) * 4
		var slot := bytes[o] + bytes[o + 1] * 256
		_check(slot == atlas.slot_of("┌"), "屏幕：纹理字节里的槽位正确（%d）" % slot)

		# text_dump
		s.begin_frame(0.0)
		s.put(0, 51, "AB")
		var dump := s.text_dump()
		_check(dump.split("\n").size() == ROWS, "屏幕：dump 行数 = 52")
		_check(str(dump.split("\n")[51]).begins_with("AB"), "屏幕：dump 第 51 行以 AB 开头")
		# 零宽字按参考实现留在 dump 里（剥色、剥尾空格，但不剥零宽字符）
		_check(str(dump.split("\n")[7]).contains("\u200bA"), "屏幕：dump 保留零宽字格")

		# 残影缓冲
		s.end_frame()
		_check(s.prev_cp.size() == n and s.prev_fg.size() == n, "屏幕：收帧快照 prev")
		_check(s.ghost_prev.size() == n and s.ghost_lv.size() == n, "屏幕：残影缓冲已分配")


	# ------------------------------------------------------------ 面板层（§3.1–§3.13）
	## 面板层只往字符格里写字，不碰 GPU，所以整套用例在 headless 下可跑：断言全部取
	## `PvScreen.text_dump()` 的纯文本（几何与配色由屏幕层用例覆盖）。
	func _test_panels(atlas: PvAtlas) -> void:
		var d := PvData.new()
		var p := PvPanels.new()
		PvPanels.CHAT = true
		PvPanels.LAST_HER = false
		PV.FX["vig"] = true
		# 本组测的是**基础版式**（split/full 的 119/195 列边界）；pip/tiles/floating 的窗格合成
		# 另有 `_test_c_layer` 的专项断言，这里先关掉舞台合成，避免坐标被合成后的 dst 改写。
		var stage_save := bool(PV.FX["stage"])
		PV.FX["stage"] = false

		# -------- 图集必须覆盖所有数据文案，否则面板会渲成空白
		atlas.missing_chars.clear()
		for row in d.boot_log:
			atlas.scan_missing(str(row[2]))
		for ln in d.lines:
			atlas.scan_missing(str(ln["text"]))
		for k in d.lyric_cn:
			atlas.scan_missing(str(d.lyric_cn[k]))
		for sh in PvShots.shots():
			atlas.scan_missing(str(sh.get("name", "")))
			for op in (sh.get("ops", []) as Array):
				atlas.scan_missing(str(op))
		for i in range(0, 2533, 12):
			var fr: Dictionary = d.dsh_at(float(i) / 12.0)
			for it in (fr.get("rows", []) as Array):
				atlas.scan_missing(str(it.get("text", "")))
		_check(atlas.missing_chars.is_empty(),
			"面板：图集覆盖全部数据文案（缺：%s）" % ", ".join(atlas.missing_chars))

		# -------- 纯工具
		_check(p._dw("ab中") == 4, "面板：dw 按格量宽（CJK 两格）")
		_check(PvPanels.is_wide("中") and not PvPanels.is_wide("A"), "面板：is_wide 判定")
		_check(PvPanels._tag4("OK") == " OK " and PvPanels._tag4("WARN") == "WARN",
			"面板：boot 状态铭牌居中 4 格")
		_check(p._hex("#4d6bfe") == PV.ME, "面板：hex 6 位解析")
		_check(p._hex("#abc") == PV.rgb(0xaa, 0xbb, 0xcc), "面板：hex 3 位解析")
		var hex_bad: Variant = p._hex("nope")
		_check(hex_bad == null, "面板：非法 hex 返回 null")
		_check(PvPanels.keyword_colour("exec") == PV.RED, "面板：exec 关键词为红")
		_check(PvPanels.keyword_colour("love") == PV.ME, "面板：love 关键词为蓝")
		var kw_none: Variant = PvPanels.keyword_colour("plain")
		_check(kw_none == null, "面板：普通词无关键词色")
		_check(p.token_id("love") == 57981, "面板：token_id = crc32 % 100000（love = 57981）")
		_check(p.token_id("EXEC") == 34053, "面板：token_id 先小写（EXEC = 34053）")
		var ramp := PvPanels.tint_ramp("blue")
		_check(ramp.size() == 8, "面板：tint_ramp 蓝 8 级")
		_check(int(ramp[0]) == PvPanels.TINT_BLUE_LO and int(ramp[7]) == PvPanels.TINT_BLUE_HI,
			"面板：tint_ramp 蓝 两端点 = lo/hi")
		var rramp := PvPanels.tint_ramp("red")
		_check(int(rramp[0]) == PvPanels.TINT_RED_LO and int(rramp[7]) == PvPanels.TINT_RED_HI,
			"面板：tint_ramp 红 两端点 = lo/hi")
		var wrapped := p.wrap_cells("alpha beta gamma delta", 11)
		var widest := 0
		for ln in wrapped:
			widest = maxi(widest, p._dw(str(ln)))
		_check(wrapped.size() >= 2 and widest <= 11, "面板：wrap_cells 每行不超宽")

		# -------- her_style 判定链（先于任何 draw，LAST_HER 为 false）
		_check(p.her_style({"name": "shot_if_i_can", "start": 59.0, "end": 61.0}) == "h3",
			"面板：CHAR_SHOTS 走 h3")
		_check(p.her_style({"name": "shot_exec_hit", "start": 147.7, "end": 148.5}) == "half",
			"面板：立绘表命中走 half")
		_check(p.her_keeps_pane({"name": "shot_if_i_can", "start": 59.0, "end": 61.0}),
			"面板：CHAR_SHOTS 的窗格归她")
		_check(not p.her_keeps_pane({"name": "shot_power", "start": 0.3, "end": 1.3}),
			"面板：普通镜头的窗格给 dsh")
		_check(p.her_tint({"name": "shot_exec_hit", "start": 147.7, "end": 148.5}) == "red",
			"面板：立绘表给了红")
		_check(p.her_tint({"name": "shot_whale_fall", "start": 200.0, "end": 205.0}) == "red",
			"面板：EVAL 之后一律红")

		var s := PvScreen.new(atlas, COLS, ROWS)

		# -------- t = 1.0：BOOT 章，stdout 带是 boot log
		p.draw(s, d, 1.0, PvShots.shot_at(1.0))
		var dump1 := s.text_dump()
		_check(dump1.contains("WORLD.EXECUTE(ME);"), "面板：顶栏标题")
		_check(dump1.contains("whale@deepsea:~"), "面板：顶栏提示符")
		_check(dump1.contains("00:01.0 / 03:32"), "面板：顶栏时钟")
		_check(dump1.contains("00 / BOOT"), "面板：顶栏章节标签")
		_check(dump1.contains("[ OK ]"), "面板：boot 行状态铭牌")
		_check(dump1.contains("power: 8x H800 online"), "面板：boot 行正文")
		_check(dump1.contains("post %d/14" % d.boot_printed(1.0).size()), "面板：boot 进度计数")
		_check(dump1.contains("shot %02d/97" % (PvShots.shot_index_at(1.0) + 1)), "面板：底栏镜头计数")
		_check(dump1.contains("win:") and dump1.contains("fx:on"), "面板：底栏窗口/FX 状态")
		_check(dump1.contains("feature bands") and dump1.contains("40-120"), "面板：feature bands 框与标签")

		# -------- t = 13.0：sim.start() 带
		p.draw(s, d, 13.0, PvShots.shot_at(13.0))
		_check(s.text_dump().contains("sim.start()"), "面板：sim 带标题")

		# -------- t = 30.0：歌词带（窗格内容随镜头而定，带子永远在窗格下方）
		p.draw(s, d, 30.0, PvShots.shot_at(30.0))
		var dump30 := s.text_dump()
		_check(dump30.contains("stdout · tokens"), "面板：歌词带标题")
		_check(dump30.contains("lyric log"), "面板：歌词日志区")

		# -------- 空镜头不占窗格（对应 tui_live 的 `ent is None` → room=False）
		p.draw(s, d, 30.0, {})
		_check(PvPanels.WINDOW == "-", "面板：无镜头时窗格为空（win=%s）" % PvPanels.WINDOW)

		# -------- t = 200.0：EVAL 之后的镜头按判定链走 h3，窗格让回 dsh 聊天窗
		PvPanels.LAST_HER = false
		p.draw(s, d, 200.0, PvShots.shot_at(200.0))
		var dump200 := s.text_dump()
		_check(PvPanels.WINDOW == "chat", "面板：EVAL 后镜头把窗格给 dsh（win=%s）" % PvPanels.WINDOW)
		_check(dump200.contains("dsh web"), "面板：dsh 窗标题")
		_check(dump200.contains("▀"), "面板：dsh 头像半块 ▀ 落地")

		# -------- 她：CHAR_SHOTS 镜头 → 窗格归她，h3 字符 take 渲染
		PvPanels._LAST_MODE = []
		PvPanels._SWITCH_AT = -1.0
		var ent_her: Dictionary = PvShots.shot_at(60.0).duplicate()
		ent_her["name"] = "shot_if_i_can"
		ent_her["her"] = true
		p.draw(s, d, 60.0, ent_her)
		var dump_her := s.text_dump()
		_check(PvPanels.WINDOW == "her", "面板：CHAR_SHOTS 镜头窗格归她（win=%s）" % PvPanels.WINDOW)
		_check(dump_her.contains("/dev/me  pid 4471"), "面板：她的框标题")
		_check(dump_her.contains("┤ pitch"), "面板：她的扫描线读数")

		# -------- ops ticker：中心行 = ops[floor(t / (BEAT/2))]（环形回绕）
		var ent150 := PvShots.shot_at(150.0)
		p.draw(s, d, 150.0, ent150)
		var dump150 := s.text_dump()
		var ops150: Array = ent150.get("ops", [])
		var base150 := int(150.0 / (PV.BEAT / 2.0))
		_check(dump150.contains("ops"), "面板：ops 框标题")
		_check(dump150.contains(str(ops150[wrapi(base150, 0, ops150.size())])),
			"面板：ops 中心行为当前步（%s）" % ops150[wrapi(base150, 0, ops150.size())])
		_check(dump150.contains("shot %02d/97" % (PvShots.shot_index_at(150.0) + 1)), "面板：底栏镜头号")
		_check(dump150.contains("her:auto->half/red"), "面板：底栏 her 渲染路径/色调")

		# -------- 底栏：非 auto 时只显示当前模式名（`H` 键循环的效果）
		PvPanels.HER_RENDER = "h3"
		p.draw(s, d, 150.0, ent150)
		var dump_h3 := s.text_dump()
		_check(dump_h3.contains("her:h3") and not dump_h3.contains("her:h3->"),
			"面板：非 auto 的底栏只显示模式名（her:h3）")
		PvPanels.HER_RENDER = "auto"

		# -------- 压力窗（§3.13）
		var win := p.pressure_window(d)
		_check(float(win[0]) > 0.0 and float(win[1]) > float(win[0]),
			"面板：压力窗有起止（%.2f–%.2f）" % [win[0], win[1]])
		_check(not p.draw_pressure(s, d, 0.0, 1, 10, 60, 40), "面板：压力窗之外不画")
		_check(p.draw_pressure(s, d, float(win[0]) + (float(win[1]) - float(win[0])) * 0.5, 1, 10, 60, 40),
			"面板：压力窗之内画出来")

		# -------- 表情选择：同一镜头每帧一致
		var e1 := p._expression_for(d, 100.0, ent150)
		var e2 := p._expression_for(d, 101.0, ent150)
		_check(e1 == e2 and not e1.is_empty(), "面板：同一镜头表情稳定（%s）" % e1)
		_check((d.expression(e1).get("chars", []) as Array).size() == 44 * 36, "面板：表情字形格 44×36")
		PV.FX["stage"] = stage_save


	# ------------------------------------------------------------ dsh 聊天窗（§3.7）
	## 头像块 `_avatar_block()` 与 PIL `Image.BOX` 逐值一致（真值在 build 前用 PIL 算出，源图
	## 120×120 RGB、面积平均降到 `cols × rows*2`）+ 主题强调色落到框线 + `▀` 半块 + NOGHOST +
	## 头像文件实拷数 == 引用数 + theme/dot 非空帧数。
	func _test_dsh_window(atlas: PvAtlas) -> void:
		var d := PvData.new()
		var p := PvPanels.new()

		# -------- _hex：#rgb 展开 / #rrggbb / 非法输入 → null
		_check(p._hex("#4d6bfe") == PV.ME, "dsh：_hex 6 位解析")
		_check(p._hex("#abc") == PV.rgb(0xaa, 0xbb, 0xcc), "dsh：_hex 3 位展开")
		_check(p._hex("#AbC") == PV.rgb(0xaa, 0xbb, 0xcc), "dsh：_hex 大小写不敏感")
		_check(p._hex("nope") == null, "dsh：_hex 非 # 开头 → null")
		_check(p._hex("#12345") == null, "dsh：_hex 长度 5 → null")
		_check(p._hex("#zzzzzz") == null, "dsh：_hex 非法十六进制字符 → null")
		_check(p._hex("#") == null, "dsh：_hex 只有 # → null")

		# -------- _avatar_block：逐值对齐 PIL Image.BOX（真值见函数注释，源图 120×120）
		var b147: Array = PvPanels._avatar_block("avatars/a2/00384.png", 14, 7)
		_check(b147 != null and b147.size() == 7 and (b147[0] as Array).size() == 14,
			"dsh：_avatar_block 14×7 尺寸正确")
		var b147_00: Array = (b147[0] as Array)[0]
		var b147_37: Array = (b147[3] as Array)[7]
		var b147_613: Array = (b147[6] as Array)[13]
		_check(int(b147_00[0]) == 0x5D75CA and int(b147_00[1]) == 0x2B3867,
			"dsh：_avatar_block 14×7 (0,0) = PIL 真值")
		_check(int(b147_37[0]) == 0x1F294E and int(b147_37[1]) == 0x5065AF,
			"dsh：_avatar_block 14×7 (3,7) = PIL 真值")
		_check(int(b147_613[0]) == 0x26315C and int(b147_613[1]) == 0x202A51,
			"dsh：_avatar_block 14×7 (6,13) = PIL 真值")
		var b105: Array = PvPanels._avatar_block("avatars/a2/00384.png", 10, 5)
		var b105_00: Array = (b105[0] as Array)[0]
		var b105_49: Array = (b105[4] as Array)[9]
		_check(int(b105_00[0]) == 0x4A5EA5 and int(b105_00[1]) == 0x35447B,
			"dsh：_avatar_block 10×5 (0,0) = PIL 真值")
		_check(int(b105_49[0]) == 0x3E4F8C and int(b105_49[1]) == 0x28335F,
			"dsh：_avatar_block 10×5 (4,9) = PIL 真值")
		var b63: Array = PvPanels._avatar_block("avatars/a2/00384.png", 6, 3)
		var b63_00: Array = (b63[0] as Array)[0]
		_check(int(b63_00[0]) == 0x3B4C88 and int(b63_00[1]) == 0x495CA3,
			"dsh：_avatar_block 6×3 (0,0) = PIL 真值")
		var bshy: Array = PvPanels._avatar_block("avatars/g/shy.png", 14, 7)
		var bshy_37: Array = (bshy[3] as Array)[7]
		_check(int(bshy_37[0]) == 0x4F63AD and int(bshy_37[1]) == 0x6A85E4,
			"dsh：_avatar_block g/shy 14×7 (3,7) = PIL 真值")
		_check(PvPanels._avatar_block("", 6, 3) == null, "dsh：_avatar_block 空路径 → null")
		_check(PvPanels._avatar_block("avatars/zzz/none.png", 6, 3) == null,
			"dsh：_avatar_block 缺图 → null")

		# -------- 头像引用数 == 实拷数；theme / dot 计数（12 Hz 逐帧）
		var refs := {}
		var theme_n := 0
		var dot_n := 0
		for k in 2533:
			var fr := d.dsh_at((k + 0.5) / 12.0)
			var av := str(fr.get("avatar", ""))
			if not av.is_empty():
				refs[av] = true
			var th: Array = fr.get("theme", [])
			if th.size() > 1 and str(th[1]) != "":
				theme_n += 1
			for it in (fr.get("rows", []) as Array):
				if str(it.get("role", "")) == "dot":
					dot_n += 1
					break
		_check(refs.size() == 745, "dsh：引用 745 张不同头像（实测 %d）" % refs.size())
		_check(_count_png("res://subsystem/world_execute/data/dsh_avatars") == refs.size(),
			"dsh：data/dsh_avatars/ 实拷数 == 引用数")
		_check(theme_n == 482, "dsh：brand 非空帧 %d（=482）" % theme_n)
		_check(dot_n == 2170, "dsh：带 dot 行的帧 %d（=2170）" % dot_n)
		var fr82: Dictionary = d.dsh_at(82.5)
		_check(str(fr82.get("avatar", "")) == "avatars/c/cat.png"
			and str((fr82.get("theme", []) as Array)[1]) == "#ff8fc0",
			"dsh：82.5 s 头像 c/cat、accent #ff8fc0")

		# -------- 落字：accent 到框线 / ▀ 半块 / NOGHOST（t=82.5，chat 窗格）
		PV.FX["vig"] = true
		PvPanels.CHAT = true
		PvPanels.LAST_HER = false
		var s := PvScreen.new(atlas, COLS, ROWS)
		p.draw(s, d, 82.5, PvShots.shot_at(82.5))
		_check(PvPanels.WINDOW == "chat", "dsh：82.5 s 窗格给 dsh（win=%s）" % PvPanels.WINDOW)
		var tick := minf(1.0, PV.beat_level(0.5) + 0.4)
		_check(s.fg[1 * COLS + 1] == PV.mix(PV.rgb(0xff, 0x8f, 0xc0), tick),
			"dsh：accent 落到框线（#ff8fc0）")
		_check(s.cp[2 * COLS + 3] == "▀".unicode_at(0), "dsh：头像区落地 ▀ 半块")
		_check(s.fg[5 * COLS + 10] == 0xE48EB7 and s.bg[5 * COLS + 10] == 0xE38CB5,
			"dsh：头像 cell(3,7) 前景/背景 = PIL BOX 真值")
		_check(s.in_noghost(1, 1) and s.in_noghost(118, 32), "dsh：窗口登记 NOGHOST（不许残影）")

		# -------- theme 空帧 → accent 缺省 ME_TEXT（t=200，chat 窗格）
		var s2 := PvScreen.new(atlas, COLS, ROWS)
		p.draw(s2, d, 200.0, PvShots.shot_at(200.0))
		_check(PvPanels.WINDOW == "chat", "dsh：200 s 窗格给 dsh（win=%s）" % PvPanels.WINDOW)
		var tick2 := minf(1.0, PV.beat_level(0.5) + 0.4)
		_check(s2.fg[1 * COLS + 1] == PV.mix(PV.ME_TEXT, tick2),
			"dsh：theme 空 → accent 缺省 ME_TEXT")


	## 递归数一个目录下的 `.png` 文件（`.import` 不算）。
	func _count_png(dir_path: String) -> int:
		var n := 0
		var da := DirAccess.open(dir_path)
		if da == null:
			return 0
		da.list_dir_begin()
		var f := da.get_next()
		while f != "":
			if da.current_is_dir():
				n += _count_png(dir_path + "/" + f)
			elif f.ends_with(".png"):
				n += 1
			f = da.get_next()
		da.list_dir_end()
		return n


	# ------------------------------------------------------------ 章节面板（§7）
	## 分发表 + 几何（pane_h / 画区 / ops_top）+ 真正往格子缓冲落字。面板只写字符格，headless 可跑。
	## 17 个 pane 的 pane_h 一律 = min(need, 32)：py0 = sp_bottom+1 = 10、bottom = 47、
	## avail = 47-10+1 = 38，故 38-6 = 32 恒大于任一 need。
	func _test_panes(atlas: PvAtlas) -> void:
		var d := PvData.new()
		var p := PvPanels.new()
		PvPanels.CHAT = true
		PvPanels.LAST_HER = false
		# 章节面板的几何断言按基础版式的 119/195 列写死；关掉舞台合成（pip/tiles/floating 另有专项）。
		var stage_save := bool(PV.FX["stage"])
		PV.FX["stage"] = false

		var rw := 75   # 197 - 2 - lx(118) - 2，与 draw_body() 一致

		# -------- 分发表：命中正确的 pane / need / least（逐条照抄 tui_live.py:L3086-3134）
		var disp := [
			["shot_corpus", "corpus", 10, 6],
			["shot_losscurve", "loss", 13, 8],
			["shot_blind", "mask", 14, 14],
			["shot_memory_ls", "memory", 13, 8],
			["shot_erase", "memory", 13, 8],
			["shot_trapped", "kv", 28, 26],
			["shot_red_trapped", "kv", 28, 26],
			["shot_strange", "expert", 26, 26],
			["shot_circle", "rope", 16, 12],
			["shot_sine", "sine", 18, 12],
			["shot_tangent", "tangent", 14, 9],
			["shot_limit", "limit", 10, 8],
			["shot_current", "gpu", 12, 10],
			["shot_then_i_can", "conv", 16, 12],
			["shot_red_then_i_can", "conv", 16, 12],
			["shot_simulations", "samples", 20, 14],
			["shot_execute_all", "exec_all", 20, 14],
			["shot_red_if_i_can", "ifican", 18, 12],
			["shot_only_execution", "logits", 15, 11],
			["shot_whale", "whale", 25, 19],
			["shot_dualpipe", "dualpipe", 11, 11],
			["shot_moe_dense", "moe", 12, 12],
			["shot_love_loop", "love", 24, 10],
		]
		for row in disp:
			var sp := PvPanes.spec(str(row[0]), rw)
			_check(str(sp[0]) == str(row[1]) and int(sp[1]) == int(row[2]) and int(sp[2]) == int(row[3]),
				"面板：分发表 %s → %s(%d,%d)" % [row[0], row[1], row[2], row[3]])
		_check(str(PvPanes.spec("shot_power", rw)[0]) == "",
			"面板：无面板镜头仍走「不画」分支")
		_check(str(PvPanes.spec("shot_whale", 60)[0]) == "", "面板：宽度不足 → 面板让行给 ops")
		_check(str(PvPanes.spec("shot_strange", 45)[0]) == "",
			"面板：expert 需 rw ≥ 46，rw=45 让行给 ops")
		_check(str(PvPanes.spec("shot_love_loop", 36)[0]) == "",
			"面板：love 需 rw ≥ 5*7+2=37，rw=36 让行给 ops")
		_check(str(PvPanes.spec("shot_corpus", 5)[0]) == "corpus", "面板：corpus 门槛低，窄列仍命中")

		# -------- 数据表都读到了
		_check(not PvPanes._data().is_empty(), "面板：panes.json 已加载")
		_check(not PvPanes._her().is_empty(), "面板：her_glyph.json 已加载")

		# -------- 几何 + 落字：每个 pane 的 pane_h / 画区顶行 / 左·右框角 / ops 起点
		var s := PvScreen.new(atlas, COLS, ROWS)
		var cases := [
			["shot_corpus", "corpus", "corpus.stream", 10],
			["shot_losscurve", "loss", "train/loss", 13],
			["shot_blind", "mask", "causal mask", 14],
			["shot_memory_ls", "memory", "~/memory/you/", 13],
			["shot_trapped", "kv", "kv_cache", 28],
			["shot_strange", "expert", "W[61].expert[07]", 26],
			["shot_circle", "rope", "embedding", 16],   # 圆的顶点落在框顶行，会吃掉标题里的一个字符
			["shot_sine", "sine", "positional code", 18],
			["shot_tangent", "tangent", "d/dx sin(x) = cos(x)", 14],
			["shot_limit", "limit", "limits", 10],
			["shot_current", "gpu", "nvidia-smi", 12],
			["shot_then_i_can", "conv", "conv2d", 16],
			["shot_simulations", "samples", "sample(n=12", 20],
			["shot_execute_all", "exec_all", "dispatch(execute, to=all)", 20],
			["shot_red_if_i_can", "ifican", "decode --render=glyph", 18],
			["shot_only_execution", "logits", "next_token", 15],
			["shot_whale", "whale", "checkpoint", 25],
			["shot_dualpipe", "dualpipe", "pipeline schedule", 11],
			["shot_moe_dense", "moe", "moe router", 12],
			["shot_love_loop", "love", "output", 24],
		]
		atlas.missing_chars.clear()
		for c in cases:
			var nm := str(c[0])
			var want_h := int(c[3])
			var ent: Dictionary = {"name": nm, "start": 0.0, "end": 100.0,
				"ops": ["STEP.0", "STEP.1", "STEP.2", "STEP.3"], "alert": "", "her": false}
			var got := p._draw_chapter_pane(s, 30.0, ent, nm, rw, 119, 10, 195, 47)
			_check(got == want_h, "面板：%s 的 pane_h = %d（实测 %d）" % [nm, want_h, got])
			p.draw(s, d, 30.0, ent)
			var rows_text := s.text_dump().split("\n")
			var row_pane := str(rows_text[10])
			_check(row_pane.contains(str(c[2])), "面板：%s 画区顶行（第 10 行）含标题" % nm)
			# 画区横向范围直接读格子（text_dump 里 CJK 只占 1 个字符，列号会被左列的宽字挤偏）
			var corner_l := int(s.cp[10 * COLS + 119])
			var corner_r := int(s.cp[10 * COLS + 195])
			_check(corner_l == "┌".unicode_at(0) and corner_r == "┐".unicode_at(0),
				"面板：%s 画区左右界 = 第 119/195 列" % nm)
			_check(str(rows_text[10 + want_h]).contains("ops"),
				"面板：%s 的 ops 起点 = 第 %d 行" % [nm, 10 + want_h])
			atlas.scan_missing(str(c[2]))
		atlas.scan_missing("·▪■║╲╱▼°Δθ\u221e\u2502")
		_check(atlas.missing_chars.is_empty(),
			"面板：图集覆盖章节面板字符（缺：%s）" % ", ".join(atlas.missing_chars))

		# -------- 三张新面板的落字内容：mask 的 -∞ 前沿 / expert 的 KL 行 / love 的词格
		var ent_mask: Dictionary = {"name": "shot_blind", "start": 0.0, "end": 100.0,
			"ops": ["MASK", "TRIU"], "alert": "", "her": false}
		p.draw(s, d, 48.5, ent_mask)                                # t ≥ T_BLIND(≈47.7)
		var rows_m := s.text_dump().split("\n")
		_check(str(rows_m[11]).contains("\u221e"),
			"面板：mask 在 t ≥ T_BLIND 后把未来格写成 -∞")

		var ent_ex: Dictionary = {"name": "shot_strange", "start": 0.0, "end": 100.0,
			"ops": ["KL", "NaN"], "alert": "", "her": false}
		p.draw(s, d, 30.0, ent_ex)                                  # u = 0.3 < 0.75
		var rows_e := s.text_dump().split("\n")
		_check(str(rows_e[34]).contains("KL rising"), "面板：expert 底部落 KL 行")
		_check(str(rows_e[11]).length() > 20, "面板：expert 首行有非空数值格")

		var ent_lv: Dictionary = {"name": "shot_love_loop", "start": 0.0, "end": 100.0,
			"ops": ["LOVE"], "alert": "", "her": false}
		p.draw(s, d, 30.0, ent_lv)                                  # lt = 30 → 154 个词
		var rows_l := s.text_dump().split("\n")
		_check(str(rows_l[11]).contains("love"), "面板：love 第 11 行起每格一个 love")

		# -------- 无面板时 pane_h = 0，ops 仍从第 10 行起（不空出一段）
		var ent_none: Dictionary = {"name": "shot_power", "start": 0.0, "end": 100.0,
			"ops": ["A", "B"], "alert": "", "her": false}
		_check(p._draw_chapter_pane(s, 30.0, ent_none, "shot_power", rw, 119, 10, 195, 47) == 0,
			"面板：无面板时 pane_h = 0")
		PV.FX["stage"] = stage_save


	# ------------------------------------------------------------ FX 层（§4.7）
	## FX 只改字符格、不碰 GPU，所以整层可测。随机数换成 GDScript 的 RNG（Python 侧是
	## Mersenne Twister + numpy，无法逐格复现），因此这里断言的是**结构不变量**与**调度/时序**，
	## 不是逐格像素：延迟场的形状、缓存的同一性、CLEAR 直通、残影衰减步数、行位移的同步。
	func _test_fx(atlas: PvAtlas) -> void:
		var d := PvData.new()
		PV.FX["on"] = true
		PV.FX["reveal"] = true
		PV.FX["mech"] = true
		PV.FX["trail"] = true
		PV.FX["vig"] = true
		PV.FX["shake"] = true
		PvFx._tables.clear()
		PvFx._prev_clear = []

		# -------- 字典内嵌 PackedInt32Array 必须能原位写（FX 的 cur/old/new 快照全靠它）
		var probe := {"a": PackedInt32Array([0, 0, 0])}
		probe["a"][1] = 7
		_check((probe["a"] as PackedInt32Array)[1] == 7,
			"FX：字典内嵌 PackedInt32Array 可原位写")

		# -------- 判定与打分
		_check(PvFx._cut_kind({}) == "radial", "FX：无镜头 → radial")
		_check(PvFx._cut_kind({"name": "shot_flood_hit", "alert": ""}) == "inward",
			"FX：flood → inward")
		_check(PvFx._cut_kind({"name": "shot_x", "alert": "err"}) == "inward",
			"FX：alert=err → inward")
		_check(PvFx._cut_kind({"name": "shot_whale_fall", "alert": ""}) == "sweep",
			"FX：whale → sweep")
		_check(PvFx._cut_kind({"name": "shot_power", "alert": ""}) == "radial",
			"FX：普通镜头 → radial")
		_check(PvFx._run_score("H800") == 9, "FX：run_score 数字+大写 = 4+3+2")
		_check(PvFx._run_score("power") == 5, "FX：run_score 纯小写 = 长度")

		# -------- 延迟场：四种形状的结构不变量
		var scan := PvFx._cut_tables("scan", 20, 10, 0.0, 0.0, 1)
		var scan_sd: Array = scan[1]
		_check(scan[0] != null and scan_sd.size() == 10, "FX：scan 每行一条切换顺序")
		var sr0: PackedFloat32Array = scan_sd[0]
		var sr9: PackedFloat32Array = scan_sd[9]
		_check(absf(sr0[0] - (0.5 / 10.0) * PV.CUT_DUR) < 1e-4,
			"FX：scan 首行延迟 = 0.5/rows×CUT_DUR")
		_check(absf(sr0[0] - sr0[19]) < 1e-6, "FX：scan 行内延迟相等")
		_check(sr9[0] > sr0[0], "FX：scan 逐行递增（自顶向下扫）")
		_check(int((scan[0] as Array)[0][0]) == 0 and int((scan[0] as Array)[0][19]) == 19,
			"FX：scan 行内顺序 = 下标升序")
		var scan2 := PvFx._cut_tables("scan", 20, 10, 0.0, 0.0, 1)
		_check(scan2[0] is Array and (scan2[0] as Array)[0] is Array
			and int((scan2[0] as Array)[0][0]) == 0, "FX：延迟场备忘命中（同形状同种子）")

		var unfold := PvFx._cut_tables("unfold", 20, 7, 0.0, 6.0, 1)
		var usd: Array = unfold[1]
		_check(absf((usd[3] as PackedFloat32Array)[0]) < 1e-6,
			"FX：unfold 种子行（sy/2=3）延迟 0")
		_check(absf((usd[0] as PackedFloat32Array)[0] - (usd[6] as PackedFloat32Array)[0]) < 1e-6,
			"FX：unfold 自种子行上下等距")
		_check(absf((usd[0] as PackedFloat32Array)[0] - PV.CUT_DUR) < 1e-6,
			"FX：unfold 最远端 = CUT_DUR")

		var morph := PvFx._cut_tables("morph", 20, 10, 0.0, 0.0, 1)
		var msd: Array = morph[1]
		var mrow: PackedFloat32Array = msd[0]
		var m_lo := mrow[0]
		var m_hi := mrow[0]
		for x in 20:
			m_lo = minf(m_lo, mrow[x])
			m_hi = maxf(m_hi, mrow[x])
		_check(m_lo >= 0.0 and m_hi < PV.CUT_DUR, "FX：morph 延迟落在 [0, CUT_DUR)")
		_check(m_hi > m_lo, "FX：morph 行内被打乱（不是整行同时切）")
		var morph_hard := PvFx._cut_tables("hard", 20, 10, 0.0, 0.0, 1)
		var morph_retain := PvFx._cut_tables("retain", 20, 10, 0.0, 0.0, 1)
		_check(morph_hard[0] == null and morph_retain[0] == null, "FX：hard/retain 没有延迟场")

		var radial := PvFx._cut_tables("radial", 8, 4, 2.0, 1.0, 1)
		var rsd: Array = radial[1]
		var r_order: Array = radial[0]
		var monotone := true
		var permuted := true
		for y in 4:
			var rrow: PackedFloat32Array = rsd[y]
			for x in range(1, 8):
				if rrow[x] < rrow[x - 1]:
					monotone = false
			var seen := {}
			for x in 8:
				seen[int((r_order[y] as Array)[x])] = true
			if seen.size() != 8:
				permuted = false
		_check(monotone, "FX：radial 每行延迟升序")
		_check(permuted, "FX：radial 每行顺序是 0..cols-1 的一个排列")
		var rmax := 0.0
		for y in 4:
			rmax = maxf(rmax, (rsd[y] as PackedFloat32Array)[7])
		_check(absf(rmax - PV.CUT_DUR) < 1e-6, "FX：radial 最远端 = CUT_DUR")

		var inward := PvFx._cut_tables("inward", 9, 9, 4.0, 4.0, 1)
		var isd: Array = inward[1]
		var i_order: Array = inward[0]
		_check(absf((isd[2] as PackedFloat32Array)[8] - PV.CUT_DUR) < 1e-6,
			"FX：inward 离种子最近的格最晚切（延迟 = CUT_DUR）")
		_check(int((i_order[2] as Array)[8]) == 4, "FX：inward 最后切的就是种子那一格（x=4）")
		# inward 的 y 坐标按 y*2 参与距离（见 _cut_tables），9×9 + 种子 (4,4) 时最远点在
		# y=8 那行（x=0 / x=8，d=sqrt(16+144)），不是左上角。
		_check(absf((isd[8] as PackedFloat32Array)[0]) < 1e-6,
			"FX：inward 最远的行（y=8）最先切（延迟 0）")

		var sd_in := PvFx._cut_seed("inward", 197, 52, RandomNumberGenerator.new())
		_check(absf(float(sd_in[0]) - 98.0) < 1e-6 and absf(float(sd_in[1]) - 25.5) < 1e-6,
			"FX：inward 种子 = 画面正中")
		var sd_sweep := PvFx._cut_seed("sweep", 197, 52, RandomNumberGenerator.new())
		# 扫过的种子要么 x 出界（-cols / 2*cols），要么 y 出界（-rows / 2*rows）；
		# 注意 -rows 只是落在屏幕上方、并不大于 rows，所以要用「出界」而不是「|坐标| > 尺寸」判。
		var sweep_offscreen := float(sd_sweep[0]) < 0.0 or float(sd_sweep[0]) > 197.0 \
			or float(sd_sweep[1]) < 0.0 or float(sd_sweep[1]) > 52.0
		_check(sweep_offscreen, "FX：sweep 种子在画面之外（扫过整屏）")

		# -------- 词游程 / 搬运 / 钉住（用合成快照，逐格可控）
		var syn := _syn(COLS, ROWS, atlas)
		_syn_put(syn, 5, 10, "power 8x H800 online", atlas)
		var runs := PvFx._word_runs(syn, COLS, ROWS, 1, ROWS - 6, syn["wide"], [], -1)
		_check(not runs.is_empty(), "FX：词游程找到候选（%d 段）" % runs.size())
		var best_run: Array = runs[0]
		_check(int(best_run[1]) == 10 and int(best_run[2]) == 14 and int(best_run[3]) == 17,
			"FX：最像名字的游程是 H800（y=%d x=%d..%d）" % [best_run[1], best_run[2], best_run[3]])
		var rng := RandomNumberGenerator.new()
		rng.seed = 13
		var plan := PvFx._carry_plan(syn, COLS, ROWS, rng, syn["wide"], int(COLS * 0.62))
		_check(not plan.is_empty() and (plan["cells"] as Array).size() == 4,
			"FX：搬运方案拎起 4 格（H800），实际 %d" % (plan["cells"] as Array).size())
		_check(absf(float((plan["src"] as Array)[0]) - 15.5) < 1e-6
			and absf(float((plan["src"] as Array)[1]) - 10.0) < 1e-6,
			"FX：搬运起点 = 游程中心 (15.5, 10)")
		_check(plan.get("dst") == null, "FX：起手未定落点（等新画面画出来再定）")
		# 真实路径里 rng 已被 _cut_seed 消耗，直接调 _carry_plan 时取到的档位不一定是最小档；
		# 断言退到「档位取自那四个候选」。
		_check([-0.22, -0.12, 0.12, 0.22].has(float(plan["bend"])),
			"FX：bend 取自 (-0.22,-0.12,0.12,0.22)（实测 %.2f）" % float(plan["bend"]))
		var syn_new := _syn(COLS, ROWS, atlas)
		_syn_put(syn_new, 40, 20, "552000000 bip", atlas)
		PvFx._carry_target(syn_new, plan, COLS, ROWS, syn_new["wide"], int(COLS * 0.62), [])
		_check(plan.get("dst") != null, "FX：新画面有更远的名字 → 落点定在那一段")
		_check(absf(float((plan["dst"] as Array)[1]) - 20.0) < 1e-6,
			"FX：落点行 = 新画面游程所在行")
		var syn_far := _syn(COLS, ROWS, atlas)
		var plan2 := PvFx._carry_plan(syn, COLS, ROWS, rng, syn["wide"], int(COLS * 0.62))
		PvFx._carry_target(syn_far, plan2, COLS, ROWS, syn_far["wide"], int(COLS * 0.62), [])
		_check(plan2.get("span") == null, "FX：新画面没有可用落点 → 不回话（span 为空）")
		_check(absf(float((plan2["dst"] as Array)[1]) - 0.42 * ROWS) < 1e-6,
			"FX：兜底落点 = 画面高度 42% 处")

		var dense := _syn(COLS, ROWS, atlas)
		for y in [20, 21]:
			_syn_put(dense, 10, y, "X".repeat(31), atlas)
		PvFx._prev_clear = []
		var retained := PvFx._retain_rects(dense, COLS, ROWS)
		_check(retained.size() == 1, "FX：钉住块命中 1 条（%d）" % retained.size())
		if retained.size() == 1:
			var rr: Array = retained[0]
			_check(int(rr[0]) == 20 and int(rr[1]) == 21 and int(rr[2]) == 9 and int(rr[3]) == 41,
				"FX：钉住块 = 两行、左右各外扩一格（%d,%d,%d,%d）" % [rr[0], rr[1], rr[2], rr[3]])

		# -------- 残影：生成 / 压暗 / 衰减步数 / NOGHOST 屏蔽
		var s := PvScreen.new(atlas, COLS, ROWS)
		PvFx.reset(s)
		s.put(5, 10, "H800 online")
		s.end_frame()
		s.begin_frame(1.0)
		s.fill(0, 10, COLS - 1, 10, " ")
		PvFx.fx_trail(s)
		_check(s.ghost.has(10 * COLS + 5), "FX：残影在「新变空」的格上生成")
		_check(s.cp[10 * COLS + 5] == "H".unicode_at(0), "FX：残影把旧字符写回空格")
		_check(s.fg[10 * COLS + 5] != PV.UI, "FX：残影前景已按 0.42 压暗")
		_check(s.ghost_prev[10 * COLS + 5] == 1, "FX：残影标记位已置起")
		var spawned := s.ghost.size()
		_check(spawned > 0, "FX：残影表非空（%d 格）" % spawned)
		PvFx.fx_trail(s)
		_check(s.ghost.size() == spawned, "FX：已占用的格不重复生成残影")
		var lv2 := float((s.ghost[10 * COLS + 5] as Array)[2])
		_check(absf(lv2 - PV.TRAIL * PV.TRAIL) < 1e-6, "FX：每帧级别 ×0.42（%.4f）" % lv2)
		PvFx.fx_trail(s)
		PvFx.fx_trail(s)
		_check(s.ghost.is_empty(), "FX：级别低于 0.06 后残影清空（4 帧内）")

		var s_nog := PvScreen.new(atlas, COLS, ROWS)
		PvFx.reset(s_nog)
		s_nog.put(5, 20, "H800 online")
		s_nog.end_frame()
		s_nog.begin_frame(1.0)
		s_nog.add_noghost(0, 20, COLS - 1, 20)
		s_nog.fill(0, 20, COLS - 1, 20, " ")
		PvFx.fx_trail(s_nog)
		_check(not s_nog.ghost.has(20 * COLS + 5), "FX：NOGHOST 行不留残影")

		# -------- 整行位移（抖动的基础动作）
		var s2 := PvScreen.new(atlas, 12, 4)
		for x in 12:
			s2.cp[x] = 10 + x
			s2.ghost_prev[x] = 10 + x
		s2.shift_row(0, 2)
		s2.shift_ghost_row(0, 2)
		_check(s2.cp[0] == 20 and s2.cp[2] == 10, "FX：整行右移 2 格（尾部回卷到行首）")
		_check(s2.ghost_prev[0] == 20 and s2.ghost_prev[2] == 10,
			"FX：ghost 标记与格子同步位移")
		s2.shift_row(0, -2)
		s2.shift_ghost_row(0, -2)
		_check(s2.cp[0] == 10 and s2.ghost_prev[0] == 10, "FX：左移 -2 还原")
		s2.shift_row(0, 12)
		_check(s2.cp[0] == 10, "FX：位移量 ≥ 行宽时不动")

		# -------- 抖动的三档守卫
		var s3 := PvScreen.new(atlas, 12, 4)
		for x in 12:
			s3.cp[x] = 1000 + x
		var before := s3.cp.duplicate()
		PvFx.fx_shake(s3, PV.beat_t(10), {"name": "shot_power", "alert": "", "index": 0})
		_check(s3.cp == before, "FX：非红镜头不抖")
		PvFx.fx_shake(s3, PV.beat_t(10) + 0.3, {"name": "shot_power", "alert": "err", "index": 0})
		_check(s3.cp == before, "FX：远离拍点不抖（pulse=0.12 < 0.45）")

		# 一次拍点的 0.15 闸门是确定性的，单拍可能恰好一行都不动；因此连拍 12 拍累计位移，
		# 并在每次位移后校验 ghost 标记与格子同步。
		var s4 := PvScreen.new(atlas, 24, 52)
		for y in 52:
			for x in 24:
				s4.cp[y * 24 + x] = x
				s4.ghost_prev[y * 24 + x] = x
		var moved := 0
		var synced := true
		for n in range(6, 18):
			var before4 := s4.cp.duplicate()
			PvFx.fx_shake(s4, PV.beat_t(n), {"name": "shot_power", "alert": "err", "index": 7})
			for y in 52:
				var base := y * 24
				if s4.cp[base] != before4[base]:
					moved += 1
					for x in 24:
						if s4.ghost_prev[base + x] != s4.cp[base + x]:
							synced = false
		_check(moved > 0, "FX：红镜头在拍点上抖动（%d 行位移）" % moved)
		_check(synced, "FX：位移行的 ghost 标记与格子保持同步")

		# -------- 亮线（scan 一行 / unfold 两行）
		var s7 := PvScreen.new(atlas, 20, 8)
		s7.put(0, 0, "ABCDEFGHIJ")
		PvFx._fx_front(s7, {"kind": "scan", "rows": 8, "cols": 20, "sy": 4.0}, 0.0)
		_check(s7.cp[0] == "─".unicode_at(0) and s7.cp[9] == "─".unicode_at(0),
			"FX：scan 亮线把首行非空格改成 ─")
		_check(s7.cp[10] == 32, "FX：亮线之外保持原样")
		var s7b := PvScreen.new(atlas, 20, 8)
		s7b.put(0, 2, "XYZ")
		PvFx._fx_front(s7b, {"kind": "unfold", "rows": 8, "cols": 20, "sy": 4.0}, 0.0)
		_check(s7b.cp[2 * 20] == "─".unicode_at(0), "FX：unfold 张开线落在种子行（sy/2=2）")

		# -------- 飞行（三次贝塞尔）
		var s8 := PvScreen.new(atlas, 20, 8)
		var carry := {
			"cells": [[0, 0, "H".unicode_at(0), PV.UI], [1, 0, "8".unicode_at(0), PV.UI]],
			"src": [0.5, 0.0], "dst": [10.0, 5.0], "span": null, "bend": 0.0,
		}
		var cc := {"carry": carry, "rows": 8, "cols": 20}
		PvFx._fx_carry(s8, cc, 0.0)
		_check(s8.cp[0] == "H".unicode_at(0) and s8.cp[1] == "8".unicode_at(0),
			"FX：u=0 时搬运落在起点")
		var s8b := PvScreen.new(atlas, 20, 8)
		PvFx._fx_carry(s8b, cc, PV.CARRY_DUR * 0.5)
		var found := 0
		for i in 20 * 8:
			if s8b.cp[i] == "H".unicode_at(0) or s8b.cp[i] == "8".unicode_at(0):
				found += 1
		_check(found == 2, "FX：飞行途中两格都在屏上（%d）" % found)
		var s8c := PvScreen.new(atlas, 20, 8)
		PvFx._fx_carry(s8c, cc, PV.CARRY_DUR)
		_check(s8c.cp[0] == 32, "FX：u≥1 后不再飞行")

		# -------- 调度：第一次 stage 不排揭示，换镜头才排
		var p := PvPanels.new()
		var shots := PvShots.shots()
		var t1 := float(shots[0]["start"]) + 0.05
		var t2 := float(shots[1]["start"]) + 0.05
		var e1 := PvShots.shot_at(t1)
		var e2 := PvShots.shot_at(t2)
		_check(int(e1["index"]) == 0 and int(e2["index"]) == 1, "FX：用例镜头 0 → 1（UNFOLD）")
		var s5 := PvScreen.new(atlas, COLS, ROWS)
		PvFx.reset(s5)
		PvFx.stage_cut(s5, t1, e1)
		_check(PvFx._cut.is_empty(), "FX：第一次 stage 不排揭示（还没有上一帧可切）")
		p.draw(s5, d, t1, e1)
		PvFx.apply(s5, t1, e1)
		s5.end_frame()
		PvFx.stage_cut(s5, t2, e2)
		_check(not PvFx._cut.is_empty() and str(PvFx._cut.get("kind", "")) == "unfold",
			"FX：1 号镜头排 UNFOLD（kind=%s）" % str(PvFx._cut.get("kind", "")))
		_check(PvFx._cut.get("order") != null, "FX：UNFOLD 有延迟场")
		p.draw(s5, d, t2, e2)
		PvFx.apply(s5, t2, e2)
		var s6 := PvScreen.new(atlas, COLS, ROWS)
		# 注意：这里不能 PvFx.reset(s6) —— 那会清掉静态 _cut，下面的「保持进行态」断言就没意义了。
		p.draw(s6, d, t2, e2)
		var with_fx := s5.text_dump().split("\n")
		var clean := s6.text_dump().split("\n")
		_check(str(with_fx[0]) == str(clean[0]), "FX：CLEAR 行（顶栏）切得干干净净")
		# 底栏同样是 CLEAR（揭示阶段直通新画面），但残影在揭示之后运行，会落进底栏的空白格 ——
		# 参考实现亦然（footer 区没登记 NOGHOST），所以这里只断言「底栏已登记为 CLEAR」。
		_check(s5.in_clear(0, ROWS - 1) and s5.in_clear(COLS - 1, ROWS - 1),
			"FX：底栏登记为 CLEAR")
		var held := 0
		for y in ROWS:
			if str(with_fx[y]) != str(clean[y]):
				held += 1
		_check(held > 0, "FX：揭示首帧仍保留旧画面（%d 行与新画面不同）" % held)
		_check(str(PvFx._cut.get("kind", "")) == "unfold" and not PvFx._cut.is_empty(),
			"FX：揭示未结束前保持进行态")

		# -------- cut 真实路径（CARRY + MORPH）：拎起 → 定落点 → 结束清空
		PV.FX["mech"] = true
		PvFx._prev_clear = []
		var s9 := PvScreen.new(atlas, COLS, ROWS)
		PvFx.reset(s9)
		s9.put(5, 10, "power 8x H800 online")
		s9.end_frame()
		PvFx.fx_cut(s9, 1.0, {"index": 7, "name": "shot_x", "alert": ""})
		_check(not PvFx._cut.is_empty() and str(PvFx._cut.get("kind", "")) == "morph",
			"FX：7 号镜头（CARRY+MORPH）排 morph（kind=%s）" % str(PvFx._cut.get("kind", "")))
		var c_carry: Dictionary = PvFx._cut.get("carry", {})
		_check((c_carry.get("cells", []) as Array).size() == 4,
			"FX：cut 真的把 H800 拎了起来（%d 格）" % (c_carry.get("cells", []) as Array).size())
		_check((PvFx._cut.get("holds", []) as Array).size() == 1,
			"FX：CARRY 先占一整屏等落地")
		_check(not (PvFx._cut.get("old", {}) as Dictionary).is_empty(),
			"FX：有 holds 才存 old 帧")
		s9.fill(0, 0, COLS - 1, ROWS - 1, " ")
		PvFx.fx_reveal(s9, 1.05)
		_check(c_carry.get("dst") != null, "FX：新画面画完后定下落点")
		_check((PvFx._cut.get("holds", []) as Array).is_empty()
			and (PvFx._cut.get("old", {}) as Dictionary).is_empty(),
			"FX：新画面没有可用落点 → 撤掉 hold 与 old")
		PvFx.fx_reveal(s9, 1.0 + PV.CUT_DUR + PV.CUT_CELL + 0.2)
		_check(PvFx._cut.is_empty(), "FX：越过 CUT_DUR+CUT_CELL 后揭示自动清空")

		# -------- 兜底：关掉 FX 时一切原样
		PV.FX["on"] = false
		var s10 := PvScreen.new(atlas, COLS, ROWS)
		PvFx.reset(s10)
		s10.put(5, 10, "H800 online")
		s10.end_frame()
		s10.begin_frame(1.0)
		s10.fill(0, 10, COLS - 1, 10, " ")
		PvFx.apply(s10, 1.0, {"index": 7, "name": "shot_x", "alert": ""})
		_check(s10.ghost.is_empty(), "FX：总开关关闭时不做残影")
		PV.FX["on"] = true


	# ------------------------------------------------------------ FX 测试用的合成快照
	func _syn(cols: int, rows: int, atlas: PvAtlas) -> Dictionary:
		var n := cols * rows
		var cp := PackedInt32Array()
		var slot := PackedInt32Array()
		var fg := PackedInt32Array()
		var bg := PackedInt32Array()
		var wide := PackedByteArray()
		cp.resize(n)
		slot.resize(n)
		fg.resize(n)
		bg.resize(n)
		wide.resize(n)
		for i in n:
			cp[i] = 32
			fg[i] = PV.UI
			bg[i] = PV.BG
		return {"cp": cp, "slot": slot, "fg": fg, "bg": bg, "wide": wide}


	func _syn_put(snap: Dictionary, x: int, y: int, text: String, atlas: PvAtlas) -> void:
		var cx := x
		for ch in text:
			snap["cp"][y * COLS + cx] = ch.unicode_at(0)
			snap["slot"][y * COLS + cx] = atlas.slot_of(ch)
			cx += 1


	# ------------------------------------------------------------ C 层（阶段 1 / 3）
	##
	## 覆盖 `tools/ref/c_layer_plan.md` §7 的五项拍板：舞台 9 模式与影院黑边（冲突 4）、
	## 特征位移与 5A 绕带（冲突 5）、点集固定表（Q8）、post 参数（Q6/CRT）、附加窗口（Q3）、
	## 以及 1B 整窗抖动的偏移上限（冲突 1）。
	func _test_c_layer(atlas: PvAtlas) -> void:
		# -------- 舞台：9 种模式
		_check(PvStage.MODES.size() == 9, "C/舞台：9 种屏幕模式（含 raw）")
		_check(PvStage.layout_of("shot_power") == ["raw", "full"], "C/舞台：shot_power → raw/full")
		_check(PvStage.layout_of("shot_corpus") == ["tiles", "split"], "C/舞台：shot_corpus → tiles/split")
		_check(PvStage.layout_of("shot_love_loop") == ["fullbleed", "full"],
			"C/舞台：shot_love_loop → fullbleed/full")
		_check(PvStage.layout_of("shot_you_left", 0) == ["tiles", "split"],
			"C/舞台：you_left 第 1 次 → tiles")
		_check(PvStage.layout_of("shot_you_left", 4) == ["shell", "split"],
			"C/舞台：you_left 第 5 次 → shell（剥到最底层）")
		_check(PvStage.layout_of("shot_you_left", 99)[0] == "shell",
			"C/舞台：you_left 超出表尾仍停在 shell")
		_check(PvStage.layout_of("shot_exec_hit", 0) == ["fullbleed", "full"],
			"C/舞台：exec_hit 第 1 次 → fullbleed/full")
		_check(PvStage.layout_of("shot_exec_hit", 1) == ["split", "split"],
			"C/舞台：exec_hit 第 2 次 → split")
		_check(PvStage.layout_of("shot_exec_hit", 11) == ["split", "split"],
			"C/舞台：exec_hit 第 12 次 → split（EXEC_HIT[4]）")
		_check(PvStage.layout_of("shot_exec_hit", 12) == ["fullbleed", "full"],
			"C/舞台：exec_hit 第 13 次回到 fullbleed")
		_check(PvStage.mode_of("shot_whale") == "cinema", "C/舞台：shot_whale → cinema")
		_check(PvStage.shot_layout(PvShots.shot_at(0.0))[0] == "raw",
			"C/舞台：t=0 的镜头布局 = raw")
		var third_you_left := {}
		var seen := 0
		for sh in PvShots.shots():
			if str(sh["name"]) == "shot_you_left":
				seen += 1
				if seen == 3:
					third_you_left = sh
		_check(PvStage.occurrence_of("shot_you_left", float(third_you_left["start"])) == 2,
			"C/舞台：同名镜头序号从 0 起（第 3 次 = 2）")

		# -------- identity / through / geometry / to_screen
		_check(PvStage.identity("split", "split"), "C/舞台：split/split 是 identity")
		_check(PvStage.identity("mirror", "full"), "C/舞台：mirror/full 是 identity")
		_check(not PvStage.identity("mirror", "split"), "C/舞台：mirror/split 要重排")
		_check(PvStage.through(PvStage.LEFT, 0, 0, 1) == Rect2i(0, 0, 55, 40),
			"C/舞台：through(LEFT,0,0,1) = 原点平移")
		var gm := PvStage.geometry("mirror", "split")
		_check((gm[1]["dst"] as Rect2i) == Rect2i(124, 4, 55, 40),
			"C/舞台：mirror 把她挪到右半边")
		var gc := PvStage.geometry("cinema", "split")
		_check((gc[1]["dst"] as Rect2i) == PvStage.LEFT,
			"C/舞台：cinema 不缩放（几何与 identity 相同，4A）")
		_check(PvStage.to_screen(Rect2i(10, 10, 4, 2), gm) == Rect2i(130, 10, 4, 2),
			"C/舞台：to_screen 按中心点归属 + 平移")

		# -------- 影院黑边（冲突 4）与 5A
		_check(PvStage.bars("cinema") == [9, 5], "C/舞台：cinema 黑边 9/5 行")
		_check(PvStage.bars("split") == [0, 0], "C/舞台：split 没有黑边")
		var band := Rect2i(1, 32, 118, 16)
		var br := PvStage.bar_rects("cinema", band)
		_check(br.size() == 2, "C/舞台：cinema 有上下两条黑边")
		_check((br[0] as Rect2i) == Rect2i(0, 0, 197, 9), "C/舞台：上黑边 = 0..8 行")
		_check((br[1] as Rect2i) == Rect2i(0, 48, 197, 4),
			"C/舞台：5A 下黑边让开 stdout 带（48..51）")
		_check(PvStage.avoid_band(Rect2i(0, 0, 10, 10), Rect2i(0, 20, 10, 5)) == Rect2i(0, 0, 10, 10),
			"C/5A：与带无交集则原样")
		_check(PvStage.avoid_band(Rect2i(0, 0, 10, 40), Rect2i(0, 30, 10, 5)) == Rect2i(0, 0, 10, 30),
			"C/5A：跨带的矩形截到带上方")
		_check(PvStage.avoid_band(Rect2i(0, 34, 10, 10), Rect2i(0, 30, 10, 5)) == Rect2i(0, 35, 10, 9),
			"C/5A：起点在带内则下移到带尾")
		_check((br[0] as Rect2i).position.y + (br[0] as Rect2i).size.y <= band.position.y,
			"C/5A：上黑边整体在 stdout 带之上")

		# -------- glide（布局滑动）
		_check(absf(PvStage.ease_io(0.0)) < 1e-9 and absf(PvStage.ease_io(1.0) - 1.0) < 1e-9,
			"C/glide：ease_io 两端为 0 / 1")
		_check(absf(PvStage.ease_io(0.5) - 0.5) < 1e-6, "C/glide：ease_io(0.5) = 0.5")
		_check(PvStage.glide_content_q(0.0) == 0.0 and absf(PvStage.glide_content_q(0.5) - 0.5) < 1e-6,
			"C/glide：内容重组进度 q 从 p=0.15 起算")
		var plan := PvStage.glide_plan("split", "split", "cinema", "split", band)
		_check(plan.size() == 2, "C/glide：split→cinema 有两个窗格")
		_check((plan[0]["from"] as Rect2i) == (plan[0]["to"] as Rect2i),
			"C/glide：identity→identity 的窗格不动（影院只加黑边）")
		_check(PvStage.lerp_rect(Rect2i(0, 0, 10, 10), Rect2i(0, 20, 10, 10), 0.5) == Rect2i(0, 10, 10, 10),
			"C/glide：lerp_rect 中点")
		_check(PvStage.collapse_rect(Rect2i(0, 0, 10, 10), 1.0) == Rect2i(5, 5, 0, 0),
			"C/glide：collapse 收拢到中心")

		# -------- 特征位移（music.react）
		_check(absf(PvMotion.phase(0.0)) < 1e-9, "C/位移：相位 t=0 为 0")
		_check(absf(PvMotion.phase(PV.BEAT) - PI) < 1e-5, "C/位移：一个拍 = 半个周期")
		_check(PvMotion.row_shift(0.0, 0.0, 1.0) == 0, "C/位移：顶行 t=0 不偏")
		_check(PvMotion.row_shift(0.0, 0.125, 1.0) == 2, "C/位移：1/8 高度处满幅 = 2 格")
		_check(absf(PvMotion.drop_ratio(0.0) - 0.3) < 1e-6, "C/位移：静音段掉格上限 30%")
		_check(PvMotion.drop_ratio(0.32) == 0.0, "C/位移：loud≥0.32 不掉格")
		_check(absf(PvMotion.flare(1.0) - 0.9) < 1e-6, "C/位移：满 kick 闪光 0.9")
		_check(PvMotion.flash_cells(1.0) == 28, "C/位移：满 flux 闪 28 格")
		_check(PvMotion.flash_cells(0.35) == 0, "C/位移：flux 阈值以下不闪")
		_check(PvMotion.hop_cells(1.0) == 4 and PvMotion.hop_cells(0.5) == 1,
			"C/位移：拍点跳 = 4·kick²")

		var s := PvScreen.new(atlas, 20, 6)
		s.begin_frame(0.0)
		for x in 20:
			s.set_raw(x, 3, char(65 + x % 26), PV.UI)
			s.set_raw(x, 2, char(97 + x % 26), PV.UI)
		var before := s.cp[3 * 20 + 0]
		_check(s.shift_row_span(3, 3, 0, 19), "C/5A：段内循环移位成功")
		_check(s.cp[3 * 20 + 3] == before, "C/5A：移位后第 3 格 = 原第 0 格")
		s.add_clear(0, 2, 19, 2)
		_check(not s.shift_row_span(2, 3, 0, 19), "C/5A：整行在 CLEAR 区时一格都不搬")
		s.stdout_rect = Rect2i(0, 3, 20, 1)
		_check(not PvMotion.row_free(s, 3), "C/5A：stdout 带内的行不参与位移")
		_check(PvMotion.row_free(s, 1), "C/5A：带外的行照常位移")
		s.stdout_rect = Rect2i(0, 5, 20, 1)

		# -------- mirror：窗格左右互换（C 层舞台接管实际绘制）
		var dm := PvData.new()
		var pm := PvPanels.new()
		PvPanels.CHAT = true
		var ent_world := {
			"index": 6, "name": "shot_world", "start": 11.004853846, "end": 12.38946923,
			"chapter": "00 / BOOT", "alert": "", "ops": [], "her": true,
		}
		_check(pm._mirror(ent_world, COLS), "C/mirror：shot_world → mirror/split")
		_check(not pm._mirror(PvShots.shot_at(0.0), COLS), "C/mirror：raw/full 不互换")
		_check(not pm._mirror({"name": "shot_losscurve", "start": 19.5433}, COLS),
			"C/mirror：split/split 不互换")
		var sm := PvScreen.new(atlas, COLS, ROWS)
		pm.draw(sm, dm, 11.5, ent_world)
		_check(sm.stdout_rect.position.x + sm.stdout_rect.size.x / 2 > COLS / 2,
			"C/mirror：stdout 带中心落在右半边（x=%d，宽 %d）"
			% [sm.stdout_rect.position.x, sm.stdout_rect.size.x])
		_check(sm.stdout_rect.position.x + sm.stdout_rect.size.x - 1 == COLS - 2,
			"C/mirror：带右缘贴到第 %d 列" % (COLS - 2))
		pm.draw(sm, dm, 20.0, PvShots.shot_at(20.0))
		_check(sm.stdout_rect.position.x == 1, "C/mirror：split 镜头仍是左列（x=1）")

		# -------- 气泡（shot_deeply）
		_check(PvPanels.bubbles_for("shot_deeply") == 1.0, "C/气泡：shot_deeply 打开")
		_check(PvPanels.bubbles_for("shot_world") == 0.0, "C/气泡：其它镜头关闭")
		var sb := PvScreen.new(atlas, 40, 20)
		sb.begin_frame(0.0)
		pm.draw_bubbles(sb, 1.0, 2, 2, 30, 18, 1.0)
		var found := 0
		for y in range(2, 19):
			for x in range(2, 31):
				if "oO°".contains(char(sb.cp[y * 40 + x])):
					found += 1
		var outside_blank := true
		for x in 40:
			if sb.cp[0 * 40 + x] != 32 or sb.cp[1 * 40 + x] != 32:
				outside_blank = false
		_check(found >= 1, "C/气泡：窗格内落了 %d 个 oO°" % found)
		_check(outside_blank, "C/气泡：不写到窗格之上（第 0/1 行仍空）")
		_check(PvPanels.BUBBLE_CHARS.length() == 5, "C/气泡：字符集 = oO°.o（5 个）")

		# -------- pip / tiles / floating：窗格合成（4A，1:1）
		for m in ["pip", "tiles", "floating"]:
			var g := PvStage.cell_geometry(m, "split")
			var want := 4 if m == "tiles" else 2
			_check(g.size() == want, "C/窗格：%s/split 有 %d 个窗格" % [m, want])
			for el in g:
				var dr: Rect2i = el["dst"]
				_check(dr.position.x >= 0 and dr.position.y >= 1
					and dr.position.x + dr.size.x <= COLS and dr.position.y + dr.size.y <= ROWS - 5,
					"C/窗格：%s 的 dst 在画布内（%s）" % [m, str(dr)])
			_check(PvStage.cell_geometry(m, "full").size() == 1,
				"C/窗格：%s/full 只有一个窗格" % m)
		PV.FX["stage"] = true
		var pst := PvPanels.new()
		var cases := {
			"pip": {"index": 5, "name": "shot_init", "start": 9.0, "end": 11.0},
			"tiles": {"index": 8, "name": "shot_corpus", "start": 16.6, "end": 18.6},
			"floating": {"index": 3, "name": "shot_creation", "start": 2.0, "end": 4.0},
		}
		for m in ["pip", "tiles", "floating"]:
			var ent: Dictionary = cases[m]
			ent["chapter"] = "00 / BOOT"
			ent["alert"] = ""
			ent["ops"] = []
			ent["her"] = false
			pst.draw(sm, dm, float(ent["start"]) + 0.5, ent)
			var g2 := PvStage.cell_geometry(m, "split")
			var me_dst: Rect2i = g2[0]["dst"] if m == "floating" else g2[1]["dst"]
			var viz_dst: Rect2i = g2[1]["dst"] if m == "floating" else g2[0]["dst"]
			var target: Rect2i = viz_dst if m == "pip" else me_dst
			var b := sm.stdout_rect
			_check(b.size.x > 0 and b.size.y > 0,
				"C/窗格：%s 的 stdout 带非空（%s）" % [m, str(b)])
			_check(b.position.x >= target.position.x
				and b.position.x + b.size.x <= target.position.x + target.size.x
				and b.position.y >= target.position.y
				and b.position.y + b.size.y <= target.position.y + target.size.y,
				"C/窗格：%s 的 stdout 带落在目标窗格内（%s）" % [m, str(target)])

		# tiles 的两个附加窗格（htop / 歌词日志）
		pst.draw(sm, dm, 17.1, cases["tiles"])
		var dump := sm.text_dump().split("\n")
		_check(str(dump[29]).contains("htop"), "C/窗格：tiles 右下有 htop")
		_check(str(dump[29]).contains("lyrics"), "C/窗格：tiles 左下有歌词日志")
		_check(str(dump[39]).contains("Mem["), "C/窗格：htop 画了内存条")

		# -------- 滑动转场（direction.py CHOREO）
		var sp1 := PvStage.transition_spec("shot_power", "shot_protection")
		_check(str(sp1["kind"]) == "reflow" and int(sp1["frames"]) == 12,
			"C/转场：power→protection = reflow 12")
		var sp2 := PvStage.transition_spec("shot_flood", "shot_exec_hit")
		_check(sp2.is_empty(), "C/转场：flood→exec_hit 是硬切")
		var sp3 := PvStage.transition_spec("shot_tangent", "shot_infinity")
		_check(str(sp3.get("dir", "")) == "right", "C/转场：tangent→infinity 向右推")
		var sp4 := PvStage.transition_spec("shot_a", "shot_you_left")
		_check(int(sp4["frames"]) == 6, "C/转场：切入 you_left 只有 6 帧")
		var sp5 := PvStage.transition_spec("shot_a", "shot_b")
		_check(str(sp5["kind"]) == "glide" and int(sp5["frames"]) == 11, "C/转场：默认 glide 11")
		var ta := PvScreen.new(atlas, 30, 12)
		var tb := PvScreen.new(atlas, 30, 12)
		for y in range(1, 7):
			for x in 30:
				ta.set_raw(x, y, "A", PV.UI)
				tb.set_raw(x, y, "B", PV.UI)
		var gspec := {"kind": "glide", "frames": 11}
		PvStage.apply_transition(tb, ta, 0.0, gspec)
		_check(tb.cp[3 * 30 + 10] == 65, "C/转场：p=0 时整块是 A")
		for y in range(1, 7):
			for x in 30:
				tb.set_raw(x, y, "B", PV.UI)
		PvStage.apply_transition(tb, ta, 1.0, gspec)
		_check(tb.cp[3 * 30 + 10] == 66, "C/转场：p=1 时整块是 B")
		var tz := PvScreen.new(atlas, 30, 12)
		var tz2 := PvScreen.new(atlas, 30, 12)
		for y in range(1, 7):
			for x in 30:
				tz.set_raw(x, y, "A", PV.UI)
				tz2.set_raw(x, y, "B", PV.UI)
		PvStage.apply_transition(tz2, tz, 0.0, {"kind": "zoom"})
		_check(tz2.cp[3 * 30 + 3] == 65, "C/转场：zoom p=0 边角仍是 A")
		for y in range(1, 7):
			for x in 30:
				tz2.set_raw(x, y, "B", PV.UI)
		PvStage.apply_transition(tz2, tz, 1.0, {"kind": "zoom"})
		_check(tz2.cp[3 * 30 + 3] == 66, "C/转场：zoom p=1 全是 B")

		# -------- 输入开关：底栏提示
		PvPanels.INPUT_ON = false
		pst.draw_footer(sm, dm, 1.0, {})
		var frows := sm.text_dump().split("\n")
		_check(str(frows[ROWS - 1]).contains("输入禁用"), "C/输入：禁用时底栏显示「输入禁用」")
		PvPanels.INPUT_ON = true
		pst.draw_footer(sm, dm, 1.0, {})
		var frows2 := sm.text_dump().split("\n")
		_check(str(frows2[ROWS - 1]).contains("q quit"), "C/输入：启用时恢复按键提示")

		# -------- music.react 三件套（drop / flare / flash）
		var rs := PvScreen.new(atlas, 30, 10)
		var rr := Rect2i(2, 2, 26, 6)
		rs.begin_frame(0.0)
		for y in range(rr.position.y, rr.position.y + rr.size.y):
			for x in range(rr.position.x, rr.position.x + rr.size.x):
				rs.set_raw(x, y, "A", PV.rgb(100, 100, 100))
		var dropped := PvMotion._apply_drop(rs, 0.0, rr, 0.0)
		_check(dropped > 0 and dropped < rr.size.x * rr.size.y,
			"C/三件套：静音段掉格 %d / %d" % [dropped, rr.size.x * rr.size.y])
		var rs2 := PvScreen.new(atlas, 30, 10)
		rs2.begin_frame(0.0)
		for y in range(rr.position.y, rr.position.y + rr.size.y):
			for x in range(rr.position.x, rr.position.x + rr.size.x):
				rs2.set_raw(x, y, "A", PV.rgb(100, 100, 100))
		PvMotion._apply_flare(rs2, rr, 1.0)
		_check(rs2.fg[2 * 30 + 2] == PV.rgb(176, 176, 176),
			"C/三件套：满 kick 提亮 100→176")
		var rs3 := PvScreen.new(atlas, 30, 10)
		rs3.begin_frame(0.0)
		for y in range(rr.position.y, rr.position.y + rr.size.y):
			for x in range(rr.position.x, rr.position.x + rr.size.x):
				rs3.set_raw(x, y, "A", PV.rgb(100, 100, 100))
		var flashed := PvMotion._apply_flash(rs3, 0.0, rr, 1.0)
		_check(flashed > 0 and flashed <= PvMotion.flash_cells(1.0),
			"C/三件套：满 flux 闪光 %d 格" % flashed)
		_check(rs3.fg[2 * 30 + 2] == PV.rgb(100, 100, 100) or rs3.fg[2 * 30 + 2] == 0xc4d4ff,
			"C/三件套：闪光只改颜色不改字符")
		_check(rs3.cp[2 * 30 + 2] == 65, "C/三件套：闪光后字符仍是 A")
		_check(PvMotion.noise8(3, 4, 5) == PvMotion.noise8(3, 4, 5),
			"C/三件套：噪点函数确定")

		# -------- her_glow（kit.py:L168-180）
		var sg := PvScreen.new(atlas, 20, 10)
		sg.begin_frame(0.0)
		sg.set_raw(5, 5, "A", PV.UI)
		var glowed := PvPanels.draw_glow(sg, Rect2i(3, 3, 5, 5), 1.0)
		_check(glowed > 0, "C/her_glow：写出 %d 个光晕格" % glowed)
		_check(char(sg.cp[5 * 20 + 4]) == "░", "C/her_glow：相邻空格写 ░")
		_check(sg.fg[5 * 20 + 4] == PV.mix(PV.ME_TEXT, 0.5),
			"C/her_glow：光晕色 = ME_TEXT × 0.5")
		_check(sg.fg[5 * 20 + 5] != PV.UI, "C/her_glow：已有笔画被提亮")
		_check(PvPanels.draw_glow(sg, Rect2i(0, 0, 2, 2), 1.0) == 0,
			"C/her_glow：没有笔画时不出光晕")

		# -------- post 参数与 CRT 转场
		var p0 := PvPost.params(0.0, 0.0, 0.0, 0.0, false)
		_check(absf(float(p0["chroma"]) - 0.06) < 1e-6, "C/post：静音色差 0.06")
		_check(absf(float(p0["grain"]) - 0.03) < 1e-6, "C/post：静音颗粒 0.03")
		var pe := PvPost.params(0.0, 0.0, 1.0, 1.0, true)
		_check(absf(float(pe["chroma"]) - 0.85) < 1e-6, "C/post：红系统满 kick 色差 0.85")
		_check(absf(float(pe["glitch"]) - 0.75) < 1e-6, "C/post：红系统满 flux glitch 0.75")
		_check(absf(PvPost.crt_progress(10.25, {"name": "shot_eggplant", "start": 10.0}) - 0.5) < 1e-6,
			"C/post：CRT 转场中点 = 0.5")
		_check(PvPost.crt_progress(10.6, {"name": "shot_eggplant", "start": 10.0}) < 0.0,
			"C/post：CRT 转场只持续 0.5 s")
		_check(PvPost.crt_progress(10.2, {"name": "shot_power", "start": 10.0}) < 0.0,
			"C/post：不在 CRT 白名单里的镜头没有转场")

		# -------- 点集固定表（Q8）
		_check(PvParticles.point_count() == 1400, "C/点集：固定表 1400 点")
		var raw := FileAccess.get_file_as_bytes("res://subsystem/world_execute/data/points_set.bin")
		_check(raw.size() == 28000, "C/点集：28000 B = 1400 × 5 × f32")
		var first := PvParticles.point(0)
		var conv := PvParticles.pos_at(0.0, 1.0, 0)
		_check(absf(conv.x - first[0]) < 1e-3 and absf(conv.y - first[1]) < 1e-3,
			"C/点集：u=1 收敛到目标点")
		_check(absf(conv.z - first[2]) < 1e-6, "C/点集：亮度随点带出")
		_check(PvParticles.cell_of(420.0, 70.0, Rect2i(0, 0, 11, 11)) == Vector2i(0, 0),
			"C/点集：画布左上映射到格区左上")
		_check(PvParticles.cell_of(1140.0, 590.0, Rect2i(0, 0, 11, 11)) == Vector2i(10, 10),
			"C/点集：画布右下映射到格区右下")

		# -------- 落鲸雪尘（固定表）
		var wr := PvWhale.time_range()
		_check(absf(wr.x - 193.54) < 0.05 and absf(wr.y - 205.54) < 0.05,
			"C/落鲸：时间轴 %.2f..%.2f" % [wr.x, wr.y])
		_check(absf(PvWhale.shot_time() - 203.54) < 0.05, "C/落鲸：TC = 结尾前 2 s")
		_check(FileAccess.get_file_as_bytes("res://subsystem/world_execute/data/whale_shed.bin").size()
			== 230 * 11 * 4, "C/落鲸：230 粒雪 × 11 f32")
		_check(FileAccess.get_file_as_bytes("res://subsystem/world_execute/data/whale_contact.bin").size()
			== 100 * 7 * 4, "C/落鲸：100 个接触尘 × 7 f32")
		_check(absf(PvWhale.floor_y(0.0) - 559.0) < 1e-6, "C/落鲸：落地线 x=0 → 559")
		_check(absf(PvWhale.floor_y(100.0) - (559.0 + 4.0 * sin(7.0))) < 1e-6,
			"C/落鲸：落地线 = 559 + 4·sin(0.07x)")
		var wq := PackedFloat32Array([10.0, 100.0, 200.0, 10.0, 5.0, 1.0, 0.0, 0.0, 0.8, 2.0, 0.5])
		var wp := PvWhale.shed_pos(wq, 10.0)
		_check(absf(wp.x - 100.0) < 1e-4 and absf(wp.y - 200.0) < 1e-4
			and absf(wp.z - 0.8) < 1e-6, "C/落鲸：出生瞬间 = (x0, y0, lv)")
		var wc0 := PvWhale.converge(100.0, 200.0, 0.5, 200.0)
		_check(absf(wc0.x - 100.0) < 1e-4 and absf(wc0.y - 200.0) < 1e-4,
			"C/落鲸：TC 之前 converge 不移动")
		var wc1 := PvWhale.converge(100.0, 200.0, 0.5, PvWhale.shot_time() + 1.3)
		_check(wc1.x < 0.0, "C/落鲸：吸完之后返回已吸收")
		var sw := PvScreen.new(atlas, COLS, ROWS)
		sw.begin_frame(0.0)
		sw.add_clear(0, 32, COLS - 1, 47)
		var whale_n := PvWhale.draw(sw, PvWhale.shot_time() + 0.3, Rect2i(4, 4, 175, 40))
		_check(whale_n > 0, "C/落鲸：落笔 %d 格" % whale_n)
		var band_clean := true
		for y in range(32, 48):
			for x in COLS:
				if sw.cp[y * COLS + x] != 32:
					band_clean = false
		_check(band_clean, "C/落鲸：5A 不写 stdout 带")
		_check(PvWhale.draw(sw, 10.0, Rect2i(4, 4, 175, 40)) == 0,
			"C/落鲸：不在该镜头时间时不画")

		# -------- 附加 OS 窗口（Q3，headless 下应安全空转）
		var w := PvWindows.new()
		w.setup(get_window(), Vector2(9, 18))
		_check(not w.available, "C/窗口：headless 下附加窗口不可用")
		w.toggle()
		_check(not w.open, "C/窗口：不可用时 toggle 不改状态")
		var rects: Array = w._layout()
		_check(rects.size() == 3 and (rects[0] as Rect2i).size.x > 0
			and (rects[1] as Rect2i).size.x > 0 and (rects[2] as Rect2i).size.x > 0,
			"C/窗口：三个附加窗口都有初始矩形")
		w.free()

		# -------- 1B 整窗抖动（冲突 1）
		PV.FX["on"] = true
		PV.FX["shake"] = true
		var ent_err := {"name": "shot_exec_hit", "alert": "err", "index": 64, "start": 147.620238}
		var on_beat := PV.beat_t(PV.beat_index(147.620238))
		var off := PvFx.window_offset(on_beat, ent_err)
		_check(absi(off.x) <= PvFx.WIN_SHAKE_PX and absi(off.y) <= PvFx.WIN_SHAKE_PX,
			"C/窗口抖动：偏移不超过 %d px" % PvFx.WIN_SHAKE_PX)
		_check(PvFx.window_offset(0.0, PvShots.shot_at(0.0)) == Vector2i.ZERO,
			"C/窗口抖动：普通镜头不抖")
		PV.FX["shake"] = false
		_check(PvFx.window_offset(on_beat, ent_err) == Vector2i.ZERO,
			"C/窗口抖动：FX.shake 关闭后不抖")
		PV.FX["shake"] = true


	# ------------------------------------------------------------ 主场景对外 API（信号 / 输入开关）
	func _test_world_api() -> void:
		var w: Node = load("res://subsystem/world_execute/world_execute.gd").new()
		for sig in ["playback_started", "playback_paused", "playback_finished",
				"seeked", "shot_changed", "chapter_changed", "input_enabled_changed"]:
			_check(w.has_signal(sig), "API：信号 %s 存在" % sig)
		var hits := [0]
		w.input_enabled_changed.connect(func(_v: bool) -> void: hits[0] += 1)
		w.set_input_enabled(false)
		_check(not w.input_enabled, "API：input_enabled 可关闭")
		_check(not PvPanels.INPUT_ON, "API：关闭后同步底栏 INPUT_ON")
		_check(hits[0] == 1, "API：关闭时发一次 input_enabled_changed")
		w.set_input_enabled(false)
		_check(hits[0] == 1, "API：重复设同值不再发信号")
		w.set_input_enabled(true)
		_check(hits[0] == 2 and PvPanels.INPUT_ON, "API：重新启用并恢复 INPUT_ON")
		w.free()


	# ------------------------------------------------------------ 工具
	func _check(condition: bool, message: String) -> void:
		_checks += 1
		if condition:
			print("  [PASS] ", message)
		else:
			print("  [FAIL] ", message)
			_failures.append(message)


	func _start_watchdog() -> void:
		var timer := Timer.new()
		timer.wait_time = 30.0
		timer.one_shot = true
		timer.process_mode = Node.PROCESS_MODE_ALWAYS
		timer.timeout.connect(func() -> void:
			print("  [FAIL] 自测超时（30 秒）")
			get_tree().quit(2))
		add_child(timer)
		timer.start()


	func _finish() -> void:
		print("=== world_execute 自测结束：%d 项检查，%d 项失败 ===" % [_checks, _failures.size()])
		for f in _failures:
			print("  失败：", f)
		get_tree().quit(0 if _failures.is_empty() else 1)
