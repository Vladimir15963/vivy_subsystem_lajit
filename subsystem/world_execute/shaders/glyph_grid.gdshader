shader_type canvas_item;
render_mode unshaded;

// world.execute(me) 字符格渲染：一张图集 + 三张「每格」数据纹理。
//
//   atlas   —— data/glyphs.png（白字形 + alpha=覆盖度），一格 = 一个终端格
//   cell_idx—— RGBA8，R/G 两字节是图集槽位号（小端）；B/A 未用
//   cell_fg —— RGBA8，RGB = 前景色
//   cell_bg —— RGBA8，RGB = 背景色
//
// 三张数据纹理都是 cols × rows（197×52），每个纹素 = 终端的一格。节点尺寸必须是
// grid_size * cell_size，UV 才能一一对应到格子与格内像素。
//
// 双宽字不需要特判：图集烘焙时已把 CJK 切成左右两半，右半格的槽位是 slot+1。

uniform sampler2D atlas : filter_nearest, repeat_disable;
uniform sampler2D cell_idx : filter_nearest, repeat_disable;
uniform sampler2D cell_fg : filter_nearest, repeat_disable;
uniform sampler2D cell_bg : filter_nearest, repeat_disable;

uniform vec2 grid_size = vec2(197.0, 52.0);     // 列数, 行数
uniform vec2 cell_size = vec2(9.0, 18.0);       // 一格的像素尺寸
uniform vec2 atlas_size = vec2(288.0, 630.0);   // 图集像素尺寸
uniform float atlas_cols = 32.0;                // 图集每行槽数

void fragment() {
	// 虚拟屏幕像素坐标 → 格坐标 + 格内像素
	vec2 px = UV * grid_size * cell_size;
	vec2 cell = floor(px / cell_size);
	vec2 in_cell = px - cell * cell_size;

	vec2 cell_uv = (cell + 0.5) / grid_size;

	vec2 raw_slot = texture(cell_idx, cell_uv).rg;
	float slot = floor(raw_slot.r * 255.0 + 0.5) + floor(raw_slot.g * 255.0 + 0.5) * 256.0;

	vec3 fg = texture(cell_fg, cell_uv).rgb;
	vec3 bg = texture(cell_bg, cell_uv).rgb;

	float sx = mod(slot, atlas_cols);
	float sy = floor(slot / atlas_cols);
	vec2 atlas_px = vec2(sx, sy) * cell_size + in_cell;
	float cov = texture(atlas, (atlas_px + 0.5) / atlas_size).a;

	COLOR = vec4(mix(bg, fg, cov), 1.0);
}
