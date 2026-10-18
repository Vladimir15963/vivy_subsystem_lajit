shader_type canvas_item;
render_mode unshaded;

// ===========================================================================
// 09 高斯模糊
//
// 单 pass 13 抽样高斯（sigma 由 radius 反推）。direction=双向时先横后纵各算一次，
// 效果更接近真正的两 pass，代价是 26 次采样。
//
// 参数：
//   radius    —— 模糊半径（源图像素，换算成 sigma = radius * 0.5）
//   direction —— 水平 / 垂直 / 双向
//   strength  —— 与原图混合比例（0 = 不模糊）
//   alpha_boost —— 额外增强 alpha，减少半透明边缘发灰
//
// 注意：repeat_disable + 边缘 clamp，模糊到画面外会拉出边缘拖尾，这是预期行为。
// ===========================================================================

// ---- 预览器自动绑定 ----
uniform sampler2D src_tex : hint_default_white, filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform float radius : hint_range(0.0, 32.0, 0.1) = 4.0;
uniform int direction : hint_enum("水平", "垂直", "双向") = 2;
uniform float strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float alpha_boost : hint_range(0.0, 1.0, 0.01) = 0.0;

vec4 sp_blur_1d(vec2 uv, vec2 dir, float sigma) {
	vec4 acc = vec4(0.0);
	float wsum = 0.0;
	for (int i = -6; i <= 6; i++) {
		float fi = float(i);
		float w = exp(-(fi * fi) / (2.0 * sigma * sigma));
		acc += texture(src_tex, uv + dir * texel_size * fi) * w;
		wsum += w;
	}
	return acc / max(wsum, 1e-6);
}

void fragment() {
	vec4 src = texture(src_tex, UV);
	vec4 blurred;

	float sigma = max(radius * 0.5, 0.5);

	if (direction == 0) {
		blurred = sp_blur_1d(UV, vec2(1.0, 0.0), sigma);
	} else if (direction == 1) {
		blurred = sp_blur_1d(UV, vec2(0.0, 1.0), sigma);
	} else {
		vec4 h = sp_blur_1d(UV, vec2(1.0, 0.0), sigma);
		vec4 acc = vec4(0.0);
		float wsum = 0.0;
		for (int i = -6; i <= 6; i++) {
			float fi = float(i);
			float w = exp(-(fi * fi) / (2.0 * sigma * sigma));
			acc += texture(src_tex, UV + vec2(0.0, texel_size.y * fi)) * w;
			wsum += w;
		}
		blurred = mix(h, acc / max(wsum, 1e-6), 0.5);
	}

	vec4 out_c = mix(src, blurred, strength);
	out_c.a = max(out_c.a, blurred.a * alpha_boost);

	COLOR = out_c;
}
