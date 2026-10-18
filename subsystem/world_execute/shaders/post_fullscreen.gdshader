shader_type canvas_item;
render_mode unshaded;

// C 层全屏 post：色差 / 颗粒 / 辉光 / glitch / CRT 开关机转场。
//
// 分工见 scripts/pv_post.gd 文件头：扫描线与暗角**不在这里**（由 PvScreen.dim 场负责），
// 否则会叠出双层扫描线。
//
// 本着色器挂在 PvDisplay 的一块全屏 ColorRect 上，用屏幕采样读下方已画好的字形画面。

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform float time = 0.0;
uniform float chroma = 0.06;      // 色差强度（像素比例）
uniform float grain = 0.03;       // 颗粒
uniform float glow = 0.12;        // 辉光
uniform float glitch = 0.0;       // 横向撕裂
uniform float crt = -1.0;         // <0 关闭；[0,1) 转场进度
uniform float texel_w = 0.00056;  // 1 / 1773

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;

	// ---- CRT 开关机：把画面压成中间一条线再展开（transitions.py:L163-175）
	float line = 0.0;
	float outside = 0.0;
	if (crt >= 0.0) {
		float k = crt < 0.5 ? (1.0 - crt * 2.0) : (crt * 2.0 - 1.0);
		float sy = mix(1.0, 0.004, clamp(k, 0.0, 1.0));
		float half_h = sy * 0.5;
		float d = abs(uv.y - 0.5);
		if (d > half_h) {
			// 线外：纯黑，但始终保留那条白线
			line = 1.0 - smoothstep(0.0015, 0.0045, d);
			outside = 1.0;
		} else {
			uv.y = 0.5 + (uv.y - 0.5) / max(sy, 0.0001);
			line = 1.0;
		}
	}

	vec3 col = vec3(0.0);
	if (outside > 0.5) {
		col = vec3(line);
	} else {
		// ---- glitch：按行哈希做横向撕裂
		vec2 guv = uv;
		if (glitch > 0.001) {
			float band = floor(uv.y * 52.0);
			float n = hash(vec2(band, floor(time * 24.0)));
			if (n < glitch * 0.35) {
				guv.x += (hash(vec2(band, 7.0)) - 0.5) * 0.06 * glitch;
			}
		}

		// ---- 色差：红蓝往两侧各偏一点
		if (chroma > 0.0005) {
			float o = chroma * texel_w * 24.0;
			col.r = texture(screen_tex, guv + vec2(o, 0.0)).r;
			col.g = texture(screen_tex, guv).g;
			col.b = texture(screen_tex, guv - vec2(o, 0.0)).b;
		} else {
			col = texture(screen_tex, guv).rgb;
		}

		// ---- 辉光：四点降采样叠加
		if (glow > 0.001) {
			vec2 d = vec2(texel_w * 6.0, texel_w * 6.0 * 1.78);
			vec3 acc = texture(screen_tex, guv + vec2(d.x, 0.0)).rgb
				+ texture(screen_tex, guv - vec2(d.x, 0.0)).rgb
				+ texture(screen_tex, guv + vec2(0.0, d.y)).rgb
				+ texture(screen_tex, guv - vec2(0.0, d.y)).rgb;
			col += acc * 0.25 * glow * 0.35;
		}

		// ---- 颗粒
		if (grain > 0.001) {
			float n = hash(uv * vec2(1773.0, 936.0) + vec2(time * 60.0, time * 37.0));
			col += (n - 0.5) * grain;
		}

		// CRT 白线叠加
		col = mix(col, vec3(1.0), line * 0.9);
	}

	COLOR = vec4(col, 1.0);
}
