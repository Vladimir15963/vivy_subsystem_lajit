// ================================================================
// Simple Zoom Reflections / Mirrors
// ================================================================
// 来源   https://godotshaders.com/shader/simple-zoom-reflections-mirrors/
// 作者   Maaack  https://godotshaders.com/author/maaack/
// 发布   2026-09-15
// 类型   canvas_item
// 许可   cc0
// Godot  4.6
// 标签   mirror, reflection, zoom
// ================================================================
// 介绍
// Inspired by Nested Tinted Zooms by coprsinhere.
//
// Usage:
//
// The shader takes several arguments:
//
// input_texture is the texture that should receive the effect.
//
// zoom_center is the point from which the zoom effect should originate.
//
// layers adjusts the number of times the texture should get mirrored.
//
// opacity adjusts the alpha/transparency of each layer relative to the last.
//
// zoom adjusts the magnification of each layer relative to the last.
//
// normalization is a range between 0 and 1 of how much to use a normalized vector from the zoom origin.
//
// normalized_scale is a range between -1 and 1 of how much to zoom the normalized vector relative to the screen size.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

// The texture to receive the effect.
uniform sampler2D input_texture: hint_default_black, filter_linear_mipmap, repeat_enable;
// Defines the origin point of the zoom effect relative to the texture size.
uniform vec2 zoom_center = vec2(0.5, 0.5);
// Adjusts the number of times the texture should get mirrored.
uniform int layers = 5;
// Adjusts the alpha/transparency of each layer relative to the last.
uniform float opacity = 0.5;
// Adjusts the boost given to the colors of the input texture.
uniform float original_opacity_mod: hint_range(0.0, 1.0) = 0.0;
// Adjusts the magnification of each layer relative to the last.
uniform float zoom = 0.25;
// Range between 0 and 1 of how much to use a normalized vector from the zoom origin.
uniform float normalization: hint_range(0.0, 1.0) = 1.0;
// Range between -1 and 1 of how much to zoom the normalized vector relative to the texture size.
uniform float normalized_scale: hint_range(-1.0, 1.0) = 0.01;

// Adjust UV per new scale and pivot
vec2 adj_uv(vec2 a_uv, float a_scale, vec2 a_pivot){
	return a_pivot + (a_uv - a_pivot) * pow(a_scale, -1.0);
}

void fragment() {
	vec4 original_color = texture(input_texture, UV);
	COLOR = original_color;
	for (int iter = 1; iter < layers + 1; iter++){
		vec2 adjusted_uv = adj_uv(UV, 1.0 + (zoom * float(iter)), zoom_center);
		vec2 adjusted_vector = adjusted_uv - UV;
		vec2 zoom_vector = (zoom_center - UV);
		vec2 normalized_vector = normalize(zoom_vector) * float(iter) * normalized_scale;
		zoom_vector = mix(adjusted_vector, normalized_vector, normalization);
		vec4 sample_color = texture(input_texture, zoom_vector + UV);
		float opacity_mod = 1.0 - (original_color.a * original_opacity_mod);
		COLOR = mix(COLOR, sample_color, sample_color.a * pow(opacity, float(iter)) * opacity_mod);
	}
}
