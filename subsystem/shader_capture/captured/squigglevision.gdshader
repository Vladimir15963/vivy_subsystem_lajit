// ================================================================
// Squigglevision
// ================================================================
// 来源   https://godotshaders.com/shader/squigglevision/
// 作者   tentabrobpy  https://godotshaders.com/author/tentabrobpy/
// 发布   2025-10-16
// 类型   canvas_item
// 许可   cc0
// Godot  4.0 / 4.1 / 4.2 / 4.3 / 4.4 / 4.5 / 4.6
// 标签   cartoon, distortion, doodle, drawing, hand drawn, shimmer, sketch, squiggle, toon, wiggle
// ================================================================
// 介绍
// Per-object Squigglevision, also known as shimmer or boiling lines. Helps emulate a hand drawn, frame-by-frame look.
//
// Noise should be a seamless grayscale texture. The shader uses world space coordinates for consistency across objects.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;
render_mode world_vertex_coords;

group_uniforms Squiggle;
/**
 * Noise texture scale
 * By default, the noise texture's size in world coordinates is set by its resolution
*/
uniform vec2 scale = vec2(1.0, 1.0);
uniform float strength = 1.0;
/**
 * Number of squiggle frames per second
*/
uniform float fps = 6.0;
uniform sampler2D noise : filter_linear, repeat_enable;
group_uniforms;

varying vec4 modulate;
varying vec2 noise_uv;

void vertex() {
	modulate = COLOR;

	// Use world coordinates for scale-independent squiggles, offset by position to keep pattern attached to object
	noise_uv = (VERTEX - MODEL_MATRIX[3].xy) / (vec2(textureSize(noise, 0)) * scale);
}

// Use irrational constants for unique squiggles every frame
#define offset_multiplier vec2(PI, E)

void fragment() {
	vec2 noise_offset = vec2(floor(TIME * fps)) * offset_multiplier;
	float noise_sample = texture(noise, noise_uv + noise_offset).r * 4.0 * PI;
	vec2 direction = vec2(cos(noise_sample), sin(noise_sample));
	vec2 squiggle_uv = UV + direction * strength * 0.005;

	COLOR = texture(TEXTURE, squiggle_uv) * modulate;
}
