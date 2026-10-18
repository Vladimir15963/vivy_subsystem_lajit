// ================================================================
// 2D Black Hole
// ================================================================
// 来源   https://godotshaders.com/shader/2d-black-hole/
// 作者   Dan  https://godotshaders.com/author/dan/
// 发布   2026-02-21
// 类型   canvas_item
// 许可   cc0
// Godot  4.4 / 4.5 / 4.6
// 标签   2d, blackhole, canvas
// ================================================================
// 介绍
// Simple 2D black hole like effect 🌟
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

uniform bool _ShowDebugColors = false;
uniform sampler2D _ScreenTex : source_color, hint_screen_texture, repeat_disable;
uniform float _DistortionStrenght = 0.9;
uniform float _Attenuation = 10.0;

void fragment() {
        // compute uv dist from center
	vec2 dir = (UV - vec2(0.5));
	float dist = length(dir);
        // add distortion based on the distance
	dir *= pow(dist, -_DistortionStrenght);
        // use attenuation to ease the effect on the edge
	dir *= pow((1.0 - dist), _Attenuation);
        // apply distortion to screen
	COLOR = vec4(texture(_ScreenTex, SCREEN_UV - dir).rgb, 1.0);

	if (_ShowDebugColors) {
		COLOR = vec4(UV - vec2(0.5), 0.0, 1.0);
	}
}
