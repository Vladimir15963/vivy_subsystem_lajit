shader_type canvas_item;
render_mode unshaded;

// ===========================================================================
// 08 全息投影 / 扫描线
//
// 老科幻片那种「绿色/青色半透明投影」：染色 + 扫描线 + 闪烁 + 噪点，
// 再往垂直方向叠几层错位采样做出投影辉光。
//
// 参数：
//   tint              —— 投影颜色
//   tint_mix          —— 染色比例（0 = 原色，1 = 纯 tint）
//   scanline_count    —— 扫描线根数
//   scanline_strength —— 扫描线深浅
//   scanline_speed    —— 扫描线滚动速度
//   flicker           —— 整体亮度闪烁
//   noise_amount      —— 投影噪点
//   edge_glow         —— 垂直方向的错位辉光层数强度
//   brightness        —— 投影整体亮度
// ===========================================================================

// ---- 预览器自动绑定 ----
uniform sampler2D src_tex : hint_default_white, filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(0.001, 0.001);
uniform float time : hint_range(0.0, 3600.0, 0.001) = 0.0;

// ---- 可调参数 ----
uniform vec3 tint : source_color = vec3(0.35, 0.95, 1.0);
uniform float tint_mix : hint_range(0.0, 1.0, 0.01) = 0.75;
uniform float scanline_count : hint_range(10.0, 800.0, 1.0) = 200.0;
uniform float scanline_strength : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float scanline_speed : hint_range(0.0, 20.0, 0.1) = 2.0;
uniform float flicker : hint_range(0.0, 1.0, 0.01) = 0.1;
uniform float noise_amount : hint_range(0.0, 1.0, 0.01) = 0.08;
uniform float edge_glow : hint_range(0.0, 2.0, 0.01) = 0.45;
uniform float brightness : hint_range(0.0, 3.0, 0.01) = 1.0;

float sp_hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec4 src = texture(src_tex, UV);
	vec3 c = src.rgb;
	float a = src.a;

	// 垂直错位辉光：往上采几层，越远越淡
	if (edge_glow > 0.0) {
		vec3 sum = vec3(0.0);
		float wsum = 0.0;
		for (int i = 1; i <= 6; i++) {
			float fi = float(i);
			float w = edge_glow / fi;
			sum += texture(src_tex, UV + vec2(0.0, texel_size.y * fi * 2.0)).rgb * w;
			wsum += w;
		}
		if (wsum > 0.0) {
			c += sum / wsum * 0.6;
			a = max(a, texture(src_tex, UV + vec2(0.0, texel_size.y * 2.0)).a * 0.6);
		}
	}

	c *= brightness;
	c = mix(c, tint * (0.35 + 0.65 * dot(c, vec3(0.2126, 0.7152, 0.0722))) * 1.9, tint_mix);

	float sl = sin((UV.y * scanline_count + time * scanline_speed) * PI * 2.0);
	c *= 1.0 - scanline_strength * (0.5 + 0.5 * sl);

	if (flicker > 0.0) {
		float f = sp_hash21(vec2(floor(time * 24.0), 3.0));
		c *= 1.0 - flicker * f;
	}

	if (noise_amount > 0.0) {
		float n = sp_hash21(floor(UV / max(texel_size, vec2(1e-6))) + vec2(floor(time * 30.0) * 5.3, 0.0));
		c += (n - 0.5) * noise_amount;
	}

	COLOR = vec4(clamp(c, 0.0, 1.0), a);
}
