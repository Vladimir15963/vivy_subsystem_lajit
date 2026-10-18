shader_type canvas_item;
render_mode unshaded;

// ===========================================================================
// 02 溶解 / 燃尽
//
// 用一张程序化噪声图跟 threshold 比大小：噪声小的像素先消失，形成溶解边缘。
// 噪声自带 fbm 多八度选项（noise_softness），越大越像云雾而不是白噪点。
//
// 参数：
//   threshold      —— 溶解进度（0=完整，1=全没）
//   edge_width     —— 溶解边缘的发光带宽
//   edge_color     —— 边缘颜色（默认燃尽橙）
//   noise_scale    —— 噪声密度
//   noise_softness —— 0=白噪声，1=fbm 云雾
//   use_luminance  —— 亮部先溶解（做“过曝烧掉”效果）
//   speed/auto_range —— 让 threshold 自己来回摆（无人值守演示用）
// ===========================================================================

// ---- 预览器自动绑定 ----
uniform sampler2D src_tex : hint_default_white, filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform float threshold : hint_range(0.0, 1.0, 0.005) = 0.45;
uniform float edge_width : hint_range(0.0, 0.25, 0.005) = 0.05;
uniform vec3 edge_color : source_color = vec3(1.0, 0.62, 0.15);
uniform float noise_scale : hint_range(1.0, 120.0, 0.5) = 22.0;
uniform float noise_softness : hint_range(0.0, 1.0, 0.01) = 0.4;
uniform bool use_luminance = false;
uniform float speed : hint_range(0.0, 4.0, 0.01) = 0.0;
uniform float auto_range : hint_range(0.0, 1.0, 0.01) = 0.0;

float sp_hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float sp_value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = sp_hash21(i);
	float b = sp_hash21(i + vec2(1.0, 0.0));
	float c = sp_hash21(i + vec2(0.0, 1.0));
	float d = sp_hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float sp_fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += amp * sp_value_noise(p);
		p *= 2.03;
		amp *= 0.5;
	}
	return v / 0.9375;
}

void fragment() {
	vec4 src = texture(src_tex, UV);

	float t = clamp(threshold + sin(time * speed) * auto_range * 0.5, 0.0, 1.0);

	vec2 np = UV * noise_scale;
	float n = mix(sp_value_noise(np), sp_fbm(np), noise_softness);

	if (use_luminance) {
		float lum = dot(src.rgb, vec3(0.2126, 0.7152, 0.0722));
		n = clamp(n * (0.35 + 0.65 * lum), 0.0, 1.0);
	}

	float m = smoothstep(t - edge_width, t + edge_width, n);
	float band = smoothstep(edge_width, 0.0, abs(n - t)) * step(0.001, src.a);

	vec4 out_c = src;
	out_c.rgb = mix(src.rgb, edge_color, clamp(band, 0.0, 1.0));
	out_c.a = max(src.a * m, band * src.a);

	COLOR = out_c;
}
