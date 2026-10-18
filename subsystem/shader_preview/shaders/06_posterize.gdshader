shader_type canvas_item;
render_mode unshaded;

// ===========================================================================
// 06 色阶分离 / 调色
//
// 先把亮度/对比度/gamma/饱和度调一遍，再把每个通道量化到 levels 级，
// 最后可选加一点抖动（dither）来掩盖色带。
//
// 参数：
//   levels        —— 每通道色阶数（2 = 极简，32 = 几乎看不出）
//   gamma         —— <1 提亮中间调，>1 压暗
//   saturation    —— 0 = 灰度，1 = 原样，>1 更艳
//   contrast      —— 围绕 0.5 拉开/压缩
//   brightness    —— 整体加减
//   dither_amount —— 量化前叠加的随机抖动强度
// ===========================================================================

// ---- 预览器自动绑定 ----
uniform sampler2D src_tex : hint_default_white, filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform int levels : hint_range(2, 32, 1) = 6;
uniform float gamma : hint_range(0.2, 4.0, 0.01) = 1.0;
uniform float saturation : hint_range(0.0, 3.0, 0.01) = 1.1;
uniform float contrast : hint_range(0.0, 3.0, 0.01) = 1.1;
uniform float brightness : hint_range(-1.0, 1.0, 0.01) = 0.0;
uniform float dither_amount : hint_range(0.0, 1.0, 0.01) = 0.0;

float sp_hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec4 src = texture(src_tex, UV);
	vec3 c = src.rgb;

	c = pow(max(c, vec3(0.0)), vec3(gamma));
	c = (c - 0.5) * contrast + 0.5;
	c += brightness;

	float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = mix(vec3(lum), c, saturation);
	c = clamp(c, 0.0, 1.0);

	if (dither_amount > 0.0) {
		float r = sp_hash21(floor(UV / max(texel_size, vec2(1e-6)))) - 0.5;
		c += r * dither_amount / max(float(levels), 2.0);
		c = clamp(c, 0.0, 1.0);
	}

	float lv = max(float(levels), 2.0);
	c = floor(c * lv + 0.5) / lv;

	COLOR = vec4(c, src.a);
}
