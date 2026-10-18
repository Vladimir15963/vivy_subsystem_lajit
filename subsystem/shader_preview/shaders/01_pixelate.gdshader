shader_type canvas_item;
render_mode unshaded;

// ===========================================================================
// 01 像素化 / 马赛克
//
// 把画面按 block_size 个源像素为一个方块取平均（这里取方块中心，够用且便宜），
// color_levels > 0 时再顺手做一次色阶量化，得到复古 8bit 观感。
//
// 参数：
//   block_size   —— 方块边长（源图像素），越大越糊
//   color_levels —— 每通道色阶数，0/1 = 关闭量化
// ===========================================================================

// ---- 预览器自动绑定（面板不显示，也不要手改） ----
uniform sampler2D src_tex : hint_default_white, filter_nearest, repeat_disable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform float block_size : hint_range(1.0, 64.0, 1.0) = 8.0;
uniform float color_levels : hint_range(0.0, 32.0, 1.0) = 0.0;
uniform bool show_grid = false;
uniform vec4 grid_color : source_color = vec4(0.0, 0.0, 0.0, 0.35);

void fragment() {
	vec2 size = 1.0 / max(texel_size, vec2(1e-6));
	vec2 blocks = max(floor(size / max(block_size, 1.0)), vec2(1.0));
	vec2 uv = (floor(UV * blocks) + 0.5) / blocks;
	vec4 c = texture(src_tex, uv);

	if (color_levels >= 2.0) {
		c.rgb = floor(c.rgb * color_levels + 0.5) / color_levels;
	}

	if (show_grid) {
		vec2 g = abs(fract(UV * blocks) - 0.5);
		float line = step(0.46, max(g.x, g.y));
		c = mix(c, vec4(grid_color.rgb, 1.0), line * grid_color.a);
	}

	COLOR = c;
}
