shader_type canvas_item;
render_mode unshaded;

// ===========================================================================
// 04 色差 / RGB 分离
//
// R 通道往一个方向偏、B 通道往反方向偏，G 不动。radial=true 时偏移量随
// 离画面中心的距离增长（镜头色差），false 时全画面均匀偏移（VHS 味）。
//
// 参数：
//   amount        —— 偏移强度（UV 单位）
//   angle         —— 均匀模式的偏移方向（度）
//   radial        —— 径向（边缘更强）还是均匀
//   radial_power  —— 径向增长的幂次，越大越集中在边缘
//   wobble/speed  —— 让强度随时间抖动
// ===========================================================================

// ---- 预览器自动绑定 ----
uniform sampler2D src_tex : hint_default_white, filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform float amount : hint_range(0.0, 0.08, 0.0005) = 0.006;
uniform float angle : hint_range(0.0, 360.0, 1.0) = 0.0;
uniform bool radial = true;
uniform float radial_power : hint_range(0.5, 4.0, 0.05) = 1.5;
uniform float wobble : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float speed : hint_range(0.0, 20.0, 0.1) = 4.0;

void fragment() {
	vec2 dir = vec2(cos(radians(angle)), sin(radians(angle)));
	float amt = amount;

	if (radial) {
		vec2 d = UV - vec2(0.5);
		float r = length(d) * 1.41421;
		amt = amount * pow(max(r, 0.0), max(radial_power, 0.05));
		if (length(d) > 1e-5) {
			dir = normalize(d);
		}
	}

	if (wobble > 0.0) {
		amt *= 1.0 + sin(time * speed + UV.y * 9.0) * wobble;
	}

	vec2 off = dir * amt;
	vec4 cr = texture(src_tex, UV + off);
	vec4 cg = texture(src_tex, UV);
	vec4 cb = texture(src_tex, UV - off);

	vec3 col = vec3(cr.r, cg.g, cb.b);
	float a = max(cg.a, max(cr.a, cb.a));

	COLOR = vec4(col, a);
}
