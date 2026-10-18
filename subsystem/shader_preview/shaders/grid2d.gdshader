// ================================================================
// Grid 2D
// ================================================================
// 来源   https://godotshaders.com/shader/grid2d/
// 作者   MarshallNekiu  https://godotshaders.com/author/marshallnekiu/
// 发布   2026-08-25
// 类型   canvas_item
// 许可   cc0
// Godot  4.6
// 标签   grid
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

// https://codeberg.org/MarshallNekiu/Grid2D_demo

shader_type canvas_item;

#define CUSTOM_ASPECT_RATIO false

const vec3[4] COLOR4 = { vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(1.0, 0.0, 1.0), vec3(0.0, 1.0, 1.0) };
const float SQRT2h = sqrt(2.0) / 2.0;

#if CUSTOM_ASPECT_RATIO
uniform float aspect_ratio = 1.0; // size.x / size.y
#endif
uniform float base = 3.0;
uniform vec3 color_grid_1 : source_color = vec3(1.0);
uniform vec3 color_grid_2 : source_color = vec3(0.0);
uniform vec3 color_grid_3 : source_color = vec3(0.5);
uniform bool draw_references = true;
uniform bool floor_grid;
uniform float grid_size = 6.0;
uniform float grid_1_step = 3.0;
uniform float grid_2_step = 3.0;
uniform float line_width = 6.0;
uniform vec2 uv_offset;
uniform float uv_rotation;
uniform float uv_scale = 8.0;

varying float calc_grid_exponent;
varying float calc_grid_pow_this;
varying float calc_grid_pow_next;
varying float calc_line_width;
varying float calc_line_width_half;
varying vec2 calc_uv_offset45;

float angle_subdivision(float phi, float div) {
	return mod(div / TAU * phi, div);
}

vec2 rotated(vec2 v, float phi) {
	float cosi = cos(phi), sine = sin(phi);
	return vec2(cosi * v.x + sine * v.y, cosi * v.y - sine * v.x);
}

bool get_axis(vec2 pos) {
	return abs(pos.x) < calc_line_width_half || abs(pos.y) < calc_line_width_half;
}

bool get_offset_reference(vec2 pos, vec2 off) {
	vec2 pos_abs = abs(pos);
	vec2 off_abs = abs(off);

	return sign(pos) == sign(off)
		&& (pos_abs.x < off_abs.x + calc_line_width_half && pos_abs.y < off_abs.y + calc_line_width_half)
		&& (pos_abs.x > off_abs.x - calc_line_width_half || pos_abs.y > off_abs.y - calc_line_width_half);
}

bool[4] get_grid_line(vec2 pos) {
	vec2 a = mod(pos + calc_line_width_half, grid_1_step * calc_grid_pow_this);
	vec2 b = mod(pos + calc_line_width_half, grid_1_step * calc_grid_pow_next);
	vec2 c = mod(pos + calc_line_width_half, grid_1_step / grid_2_step * calc_grid_pow_this);
	vec2 d = mod(pos + calc_line_width_half, grid_1_step / grid_2_step * calc_grid_pow_next);

	return {
		a.x - calc_line_width_half < calc_line_width_half || a.y - calc_line_width_half < calc_line_width_half,
		b.x - calc_line_width_half < calc_line_width_half || b.y - calc_line_width_half < calc_line_width_half,
		c.x - calc_line_width_half < calc_line_width_half || c.y - calc_line_width_half < calc_line_width_half,
		d.x - calc_line_width_half < calc_line_width_half || d.y - calc_line_width_half < calc_line_width_half
	};
}

void vertex() {
	calc_grid_exponent = log(max(uv_scale / grid_size, 1.0)) / log(base);
	calc_grid_pow_this = pow(base, floor(calc_grid_exponent));
	calc_grid_pow_next = pow(base, ceil(calc_grid_exponent));
	calc_line_width = line_width / 1000.0 * uv_scale;
	calc_line_width_half = calc_line_width / 2.0;
	calc_uv_offset45 = rotated(uv_offset, PI / 4.0);

	if (floor_grid) calc_grid_exponent = floor(calc_grid_exponent);
}

void fragment() {
	#if !CUSTOM_ASPECT_RATIO
		vec2 d = fwidth(UV);
		float aspect_ratio = d.y / d.x;
	#endif

	vec2 uv = (UV - 0.5) * vec2(aspect_ratio, 1.0);
	vec2 position = rotated(uv, uv_rotation) * uv_scale + uv_offset;
	vec2 position45 = rotated(uv, uv_rotation + PI / 4.0) * uv_scale + calc_uv_offset45;

	vec4 new_color_axis, new_color_offset_reference, new_color_reference;
	vec4 new_color_diagonal_this, new_color_grid_this, new_color_subgrid_this, new_color_this;
	vec4 new_color_diagonal_next, new_color_grid_next, new_color_subgrid_next, new_color_next;
	vec4 new_color;

	if (draw_references && get_axis(position)) {
		float asd = angle_subdivision(atan(position.y, -position.x) - PI * 0.75, 4.0);
		new_color_axis = vec4(COLOR4[int(floor(asd))], 1.0);
	}
	else if (draw_references && get_offset_reference(position, uv_offset)) {
		float asd = angle_subdivision(atan(position.y / abs(uv_offset.y), -position.x / abs(uv_offset.x)) - PI * 0.75, 4.0);
		new_color_offset_reference = vec4(COLOR4[int(floor(asd))], 1.0);
	}

	bool[4] grid_line = get_grid_line(position);

	if (grid_line[0]) new_color_grid_this = vec4(color_grid_1, 1.0);
	if (grid_line[1]) new_color_grid_next = vec4(color_grid_1, 1.0);
	if (grid_line[2]) new_color_subgrid_this = vec4(color_grid_2, 1.0);
	if (grid_line[3]) new_color_subgrid_next = vec4(color_grid_2, 1.0);

	bool[4] grid_line45 = get_grid_line(position45 * SQRT2h);

	if (grid_line45[0]) new_color_diagonal_this = vec4(color_grid_3, 1.0);
	if (grid_line45[1]) new_color_diagonal_next = vec4(color_grid_3, 1.0);

	new_color_this = mix(new_color_subgrid_this, new_color_grid_this, new_color_grid_this.a);
	new_color_this = mix(new_color_this, new_color_diagonal_this, new_color_diagonal_this.a);

	new_color_next = mix(new_color_subgrid_next, new_color_grid_next, new_color_grid_next.a);
	new_color_next = mix(new_color_next, new_color_diagonal_next, new_color_diagonal_next.a);

	new_color_reference = mix(new_color_offset_reference, new_color_axis, new_color_axis.a);

	new_color = mix(new_color_this, new_color_next, fract(calc_grid_exponent));
	new_color = mix(new_color, new_color_reference, new_color_reference.a);

	COLOR = mix(COLOR, new_color, new_color.a);
}
