shader_type canvas_item;
render_mode unshaded;

// ===========================================================================
// 05 波动扭曲 / 水波
//
// 用正弦波推动采样坐标。axis 决定波怎么走：水平（横向推）、垂直（纵向推）、
// 径向（从中心扩散，像水滴滴进水面）、横竖（两个方向一起）。
//
// 参数：
//   amplitude —— 扭曲幅度（UV 单位，0.02 ≈ 2% 画面宽）
//   frequency —— 波数，越大波纹越密
//   speed     —— 相位推进速度，0 = 静止
//   axis      —— 波的方向
//   fade_edges—— 屏幕边缘衰减（中心不动）
// ===========================================================================

// ---- 预览器自动绑定 ----
uniform sampler2D src_tex : hint_default_white, filter_linear, repeat_enable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform float amplitude : hint_range(0.0, 0.3, 0.001) = 0.02;
uniform float frequency : hint_range(0.0, 80.0, 0.5) = 14.0;
uniform float speed : hint_range(0.0, 10.0, 0.01) = 1.2;
uniform int axis : hint_enum("水平", "垂直", "径向", "横竖") = 0;
uniform float fade_edges : hint_range(0.0, 1.0, 0.01) = 0.0;

void fragment() {
	vec2 uv = UV;
	float amp = amplitude;

	if (fade_edges > 0.0) {
		vec2 e = min(UV, vec2(1.0) - UV) * 2.0;
		amp *= mix(1.0, clamp(min(e.x, e.y), 0.0, 1.0), fade_edges);
	}

	if (axis == 0) {
		uv.x += sin(UV.y * frequency + time * speed) * amp;
	} else if (axis == 1) {
		uv.y += sin(UV.x * frequency + time * speed) * amp;
	} else if (axis == 2) {
		vec2 d = UV - vec2(0.5);
		float r = length(d);
		if (r > 1e-5) {
			uv += (d / r) * sin(r * frequency - time * speed * 3.0) * amp;
		}
	} else {
		uv.x += sin(UV.y * frequency + time * speed) * amp;
		uv.y += cos(UV.x * frequency + time * speed * 0.87) * amp;
	}

	COLOR = texture(src_tex, uv);
}
