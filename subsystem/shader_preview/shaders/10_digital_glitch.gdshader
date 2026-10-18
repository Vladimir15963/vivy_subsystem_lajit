shader_type canvas_item;
render_mode unshaded;

// ===========================================================================
// 10 数字故障 / Glitch
//
// 按方块格子随机撕裂缝：整块横向错位 + RGB 偏移，再叠一点行级跳变，
// 做出信号损坏的观感。
//
// 参数：
//   amount         —— 故障强度（错位幅度与撕裂概率都跟它走）
//   block_size     —— 撕裂块的高度/宽度（源图像素）
//   tear_chance    —— 出现撕裂的方块比例
//   rgb_shift      —— RGB 分离强度
//   line_jump      —— 整行错位的概率
//   speed          —— 每秒故障刷新次数（0 = 冻结成一帧）
// ===========================================================================

// ---- 预览器自动绑定 ----
uniform sampler2D src_tex : hint_default_white, filter_linear, repeat_enable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform float amount : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float block_size : hint_range(2.0, 64.0, 1.0) = 10.0;
uniform float tear_chance : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float rgb_shift : hint_range(0.0, 0.06, 0.0005) = 0.02;
uniform float line_jump : hint_range(0.0, 1.0, 0.01) = 0.2;
uniform float speed : hint_range(0.0, 24.0, 0.1) = 8.0;

float sp_hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	float frame = floor(time * speed);
	vec2 tsize = max(texel_size, vec2(1e-6));
	vec2 px = UV / tsize;

	vec2 blocks = vec2(max(block_size, 1.0), max(block_size, 1.0) * 0.5);
	vec2 bid = floor(px / blocks) + vec2(frame * 3.7, frame * 1.3);

	float r = sp_hash21(bid);
	float tear = step(1.0 - tear_chance * amount, r);

	vec2 uv = UV;
	uv.x += tear * (sp_hash21(bid + vec2(frame, 0.5)) - 0.5) * amount * 0.25;

	float row_id = floor(px.y) + frame * 11.0;
	float row_rand = sp_hash21(vec2(row_id, 7.0));
	float jump = step(1.0 - line_jump * amount, row_rand);
	uv.x += jump * (sp_hash21(vec2(row_id, 19.0)) - 0.5) * amount * 0.35;

	float rs = rgb_shift * amount * 3.0 * (0.4 + r);
	vec4 cg = texture(src_tex, uv);
	vec4 cr = texture(src_tex, uv + vec2(rs, 0.0));
	vec4 cb = texture(src_tex, uv - vec2(rs, 0.0));

	vec3 col = vec3(cr.r, cg.g, cb.b);
	float a = max(cg.a, max(cr.a, cb.a));

	// 撕裂块整体提亮一点，故障感更明显
	col += tear * amount * 0.08;

	COLOR = vec4(col, a);
}
