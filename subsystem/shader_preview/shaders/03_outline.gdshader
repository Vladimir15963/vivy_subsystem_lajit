shader_type canvas_item;
render_mode unshaded;

// ===========================================================================
// 03 描边 / 轮廓
//
// 按 alpha 阈值取形状，再在 8 邻域里找“形状边界”，把它涂成描边色。
// 外描边需要画在图形外面的像素上，而 TextureRect 的四边形就是图片本身，
// 所以这里用 padding 把源图往内缩一圈，留出画外描边的余量。
//
// 参数：
//   thickness       —— 描边粗细（源图像素）
//   outline_color   —— 描边颜色
//   alpha_threshold —— 多大的 alpha 算“实心”
//   inside          —— 关=外描边，开=内描边
//   fill_opacity    —— 原图整体透明度（压到 0 就只剩描边）
//   padding         —— 内缩比例，外描边必须 > 0 才看得见
//   glow            —— 描边外侧的额外辉光（只在外描边模式生效）
// ===========================================================================

// ---- 预览器自动绑定 ----
uniform sampler2D src_tex : hint_default_white, filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform float thickness : hint_range(0.0, 12.0, 0.1) = 2.0;
uniform vec3 outline_color : source_color = vec3(0.25, 0.95, 1.0);
uniform float alpha_threshold : hint_range(0.0, 1.0, 0.01) = 0.2;
uniform bool inside = false;
uniform float fill_opacity : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float padding : hint_range(0.0, 0.2, 0.002) = 0.06;
uniform float glow : hint_range(0.0, 1.0, 0.01) = 0.0;

// 把 UV 映射到内缩后的源图坐标，并返回“是否落在源图内”
vec2 sp_source_uv(vec2 uv, out float in_rect) {
	float k = max(1.0 - 2.0 * padding, 1e-4);
	vec2 s = (uv - 0.5) / k + 0.5;
	in_rect = step(0.0, s.x) * step(s.x, 1.0) * step(0.0, s.y) * step(s.y, 1.0);
	return s;
}

float sp_alpha_at(vec2 s, float in_rect) {
	return texture(src_tex, clamp(s, vec2(0.0), vec2(1.0))).a * in_rect;
}

void fragment() {
	float in_rect;
	vec2 s = sp_source_uv(UV, in_rect);

	vec4 src = texture(src_tex, clamp(s, vec2(0.0), vec2(1.0))) * in_rect;
	float center = src.a;

	float d = thickness * max(length(texel_size), 1e-6);
	float ring = 0.0;
	float ring_far = 0.0;
	for (int i = 0; i < 8; i++) {
		float ang = float(i) * PI * 0.25;
		vec2 dir = vec2(cos(ang), sin(ang));
		float a1 = texture(src_tex, clamp(s + dir * d, vec2(0.0), vec2(1.0))).a * in_rect;
		ring = max(ring, a1);
		float a2 = texture(src_tex, clamp(s + dir * d * 2.20, vec2(0.0), vec2(1.0))).a * in_rect;
		ring_far = max(ring_far, a2);
	}

	float is_edge = 0.0;
	if (inside) {
		is_edge = step(alpha_threshold, center) * step(ring, alpha_threshold - 0.001);
	} else {
		is_edge = step(center, alpha_threshold - 0.001) * step(alpha_threshold, ring);
	}

	float halo = 0.0;
	if (!inside) {
		halo = step(center, alpha_threshold - 0.001)
			* step(alpha_threshold, ring_far)
			* (1.0 - is_edge);
	}

	vec4 out_c = src;
	out_c.rgb = mix(src.rgb, outline_color, is_edge);
	out_c.a = max(src.a * fill_opacity, is_edge);
	out_c.a = max(out_c.a, halo * glow);

	COLOR = out_c;
}
