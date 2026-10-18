// ================================================================
// Luminance Mask Transition
// ================================================================
// 来源   https://godotshaders.com/shader/luminance-mask-transition/
// 作者   null_builds  https://godotshaders.com/author/null_builds/
// 发布   2026-04-10
// 类型   canvas_item
// 许可   cc0
// Godot  4.4 / 4.5 / 4.6
// 标签   animated, luminance, mask, transition
// ================================================================
// 介绍
// A general purpose transition shader which uses greyscale masks to obscure/reveal the canvas behind a color rect over a scene.
//
// Parameters:
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

uniform float luminance_cutoff: hint_range(0.0, 1.0) = 0.0;
uniform bool invert = false;
uniform sampler2D mask_texture;
uniform sampler2D display_texture;

void fragment() {
	vec4 sample_color = texture(mask_texture, UV);
	float luminance = dot(sample_color.rgb, vec3(0.2126, 0.7152, 0.0722));
	bool filter = luminance > luminance_cutoff;
	if (invert) {
		filter = !filter;
	}

	if (filter) {
		COLOR = texture(display_texture, UV);
	} else {
		COLOR = vec4(1.0, 1.0, 1.0, 0.0) * texture(display_texture, UV);
	}
}
