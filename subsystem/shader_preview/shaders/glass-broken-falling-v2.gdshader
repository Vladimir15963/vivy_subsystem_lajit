// ================================================================
// Glass broken falling V2
// ================================================================
// 来源   https://godotshaders.com/shader/glass-broken-falling-v2/
// 作者   miwls  https://godotshaders.com/author/miwls/
// 发布   2026-07-04
// 类型   canvas_item
// 许可   cc0
// Godot  4.3 / 4.4 / 4.5 / 4.6
// 标签   glass
// ================================================================
// 介绍
// Hey! I imagine most of you have already seen this shader. A few days ago I came across a similar version of it and thought, “why not?”
//
// So here it is: Falling Glass Shader V2.
//
// This version also fixes my past shader stupidity XDDD
//
// This shader works by splitting the screen into Voronoi pieces. Each fragment is assigned to its closest Voronoi cell, which becomes an individual glass shard.
//
// Every shard receives its own random delay, horizontal drift, rotation, and falling speed, making the animation feel much more natural. Instead of simply moving the pixels downward, the shader reconstructs where each shard originally came from and samples the screen texture from that position. This keeps every piece intact while it falls.
//
// To make sure no shard gets stuck on screen, each one calculates exactly how far it needs to travel before it is completely outside the viewport. A small glow is also added along the Voronoi edges to help separate the shards visually, and an optional alpha fade can make them disappear smoothly near the end of the animation.
//
// The result is a lightweight fake glass-shattering effect that runs entirely inside a CanvasItem shader, with no particles, meshes, or physics required.
//
// Thanks to Ttiene63 for reminding me that this shader existed. :3
// https://godotshaders.com/shader/frostbite/
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

uniform float fall_progress : hint_range(0.0, 1.0) = 0.0;

uniform int pieces_x = 5;
uniform int pieces_y = 3;

// Multiplies the guaranteed falling distance
// (1.0 = "normal" fall, higher values make the piece
// accelerate and leave the screen faster).
uniform float gravity : hint_range(0.5, 3.0) = 1.15;
uniform float scatter : hint_range(0.0, 1.0) = 0.22;
uniform float rotation_amount : hint_range(0.0, 4.0) = 1.0;

uniform float point_jitter : hint_range(0.0, 0.48) = 0.34;
uniform float delay_variation : hint_range(0.0, 0.8) = 0.28;

// Extra margin (in screen heights) below the bottom edge
// to guarantee the piece is completely out of view
// when fall_progress reaches 1.0.
uniform float exit_margin : hint_range(0.0, 1.0) = 0.35;

uniform float edge_thickness : hint_range(0.0005, 0.05) = 0.01;
uniform float edge_brightness : hint_range(0.0, 2.0) = 0.35;

// Optional additional alpha fade near the end of the fall
// (1.0 = no fade).
uniform float alpha_fade_start : hint_range(0.0, 1.0) = 1.0;

const int SEARCH_RADIUS = 1;
const int MAX_ROWS = 32; // Safety limit for the row search loop

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
	return vec2(
		hash12(p + vec2(1.23, 4.56)),
		hash12(p + vec2(7.89, 0.12))
	);
}

mat2 rot(float a) {
	float s = sin(a);
	float c = cos(a);
	return mat2(vec2(c, -s), vec2(s, c));
}

vec2 cell_point(vec2 cell_id) {
	vec2 h = hash22(cell_id);
	return cell_id + 0.5 + (h - 0.5) * (point_jitter * 2.0);
}

// Finds the closest Voronoi owner (cell/point) to p,
// along with an approximate distance to the cell boundary.
void voronoi_info(vec2 p, out vec2 owner_cell, out vec2 owner_point, out float edge_dist) {
	vec2 base = floor(p);

	float best_d = 1e20;
	float second_d = 1e20;
	vec2 best_cell = vec2(0.0);
	vec2 best_point = vec2(0.0);

	for (int j = -SEARCH_RADIUS; j <= SEARCH_RADIUS; j++) {
		for (int i = -SEARCH_RADIUS; i <= SEARCH_RADIUS; i++) {
			vec2 c = base + vec2(float(i), float(j));
			vec2 pt = cell_point(c);
			float d = distance(p, pt);

			if (d < best_d) {
				second_d = best_d;
				best_d = d;
				best_cell = c;
				best_point = pt;
			} else if (d < second_d) {
				second_d = d;
			}
		}
	}

	owner_cell = best_cell;
	owner_point = best_point;
	edge_dist = second_d - best_d;
}

// Piece transform:
// Ensures that, in the worst-case scenario (t = 1),
// the piece has already moved completely below the screen
// (plus a safety margin), preventing it from stopping
// halfway or overshooting prematurely.
void piece_transform(
	vec2 piece_cell,
	vec2 point,
	vec2 grid,
	out float t,
	out vec2 piece_offset_uv,
	out float piece_angle
) {
	float rnd  = hash12(piece_cell);
	float rnd2 = hash12(piece_cell + 17.37);
	float rnd3 = hash12(piece_cell + 91.11);

	float delay = rnd * delay_variation;
	t = clamp((fall_progress - delay) / max(0.0001, 1.0 - delay), 0.0, 1.0);

	float center_y = point.y / grid.y;

	// Distance required for this piece to fully leave the screen.
	float needed = (1.0 - center_y) + exit_margin;

	float speed_variance = 0.6 + rnd2 * 0.8;
	float fall_y = needed * (t * t) * gravity * speed_variance;

	float drift_x = (rnd2 - 0.5) * scatter * t;

	piece_offset_uv = vec2(drift_x, fall_y);
	piece_angle = (rnd3 - 0.5) * rotation_amount * t;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 grid = vec2(float(pieces_x), float(pieces_y));
	vec2 p_now = uv * grid;
	vec2 base_cell = floor(p_now);

	vec4 result = vec4(0.0);
	bool found = false;
	float found_edge = 0.0;
	float found_t = 0.0;

	// Horizontal drift is small (limited by "scatter"),
	// so only neighboring columns need to be checked.
	// Vertical movement, however, can be large, so we scan
	// every row to determine which transformed piece
	// actually covers this pixel.
	for (int iy = 0; iy < MAX_ROWS; iy++) {
		if (iy >= pieces_y) break;

		for (int dx = -1; dx <= 1; dx++) {
			float cx = base_cell.x + float(dx);
			if (cx < 0.0 || cx >= grid.x) continue;

			vec2 cell_id = vec2(cx, float(iy));
			vec2 point = cell_point(cell_id);
			vec2 piece_center_uv = point / grid;

			float t;
			vec2 offset;
			float angle;
			piece_transform(cell_id, point, grid, t, offset, angle);

			vec2 rel_now = uv - piece_center_uv;
			vec2 uv_from = piece_center_uv + rot(-angle) * (rel_now - offset);

			if (uv_from.x < 0.0 || uv_from.y < 0.0 || uv_from.x > 1.0 || uv_from.y > 1.0) {
				continue;
			}

			vec2 p_from = uv_from * grid;
			vec2 from_cell;
			vec2 from_point;
			float from_edge;
			voronoi_info(p_from, from_cell, from_point, from_edge);

			if (distance(from_cell, cell_id) > 0.001) continue;

			result = texture(screen_tex, uv_from);
			found_edge = from_edge;
			found_t = t;
			found = true;
		}
	}

	if (!found) {
		COLOR = vec4(0.0);
		discard;
	}

	float edge = 1.0 - smoothstep(0.0, edge_thickness, found_edge);
	result.rgb += edge * edge_brightness;

	float fade = 1.0 - smoothstep(alpha_fade_start, 1.0, found_t);
	result.a *= fade;

	COLOR = result;
}
