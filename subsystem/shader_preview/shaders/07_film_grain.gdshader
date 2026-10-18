shader_type canvas_item;
render_mode unshaded;

// ===========================================================================
// 07 胶片颗粒 / 噪点
//
// 在像素格子上撒噪声，可选彩色颗粒、只压暗部、加暗角，做出老胶片观感。
//
// 参数：
//   strength      —— 颗粒强度
//   grain_size    —— 颗粒大小（源图像素，1 = 每像素独立）
//   colored       —— 彩噪（RGB 各自独立）还是单色噪
//   shadows_only  —— 只在暗部加噪
//   vignette      —— 暗角强度
//   speed         —— 每秒刷新次数，0 = 静止颗粒
// ===========================================================================

// ---- 预览器自动绑定 ----
uniform sampler2D src_tex : hint_default_white, filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform float strength : hint_range(0.0, 1.0, 0.01) = 0.12;
uniform float grain_size : hint_range(0.5, 8.0, 0.1) = 1.0;
uniform bool colored = false;
uniform float shadows_only : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float vignette : hint_range(0.0, 2.0, 0.01) = 0.35;
uniform float speed : hint_range(0.0, 60.0, 0.5) = 8.0;

float sp_hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec4 src = texture(src_tex, UV);
	vec3 c = src.rgb;

	float frame = floor(time * speed);
	vec2 gp = floor(UV / max(texel_size, vec2(1e-6)) / max(grain_size, 0.01)) + vec2(frame * 7.13, frame * 3.71);

	float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
	float amt = strength * mix(1.0, 1.0 - lum, shadows_only);

	if (colored) {
		vec3 g = vec3(sp_hash21(gp), sp_hash21(gp + vec2(17.0, 5.0)), sp_hash21(gp + vec2(3.0, 29.0)));
		c += (g - 0.5) * amt * 2.0;
	} else {
		float g = sp_hash21(gp);
		// 用三个偏移的哈希做一次轻量去相关，颗粒不至于太规律
		g = mix(g, sp_hash21(gp + vec2(41.0, 13.0)), 0.35);
		c += (g - 0.5) * amt * 2.0;
	}

	if (vignette > 0.0) {
		float d = length(UV - vec2(0.5)) * 1.41421;
		float v = 1.0 - smoothstep(0.35, 1.0, d);
		c *= mix(1.0, v, clamp(vignette, 0.0, 2.0));
	}

	COLOR = vec4(clamp(c, 0.0, 1.0), src.a);
}
