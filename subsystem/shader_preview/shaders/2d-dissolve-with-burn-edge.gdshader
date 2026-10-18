// ================================================================
// 2D dissolve with burn edge
// ================================================================
// 来源   https://godotshaders.com/shader/2d-dissolve-with-burn-edge/
// 作者   mreliptik  https://godotshaders.com/author/mreliptik/
// 发布   2024-03-12
// 类型   canvas_item
// 许可   cc0
// 标签   2d, burn, dissolve
// ================================================================
// 介绍
// It’s a modification of the 2D Simple dissolve shader to add a burn edge.
//
// How to setup
//
// How to use
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

uniform sampler2D dissolve_texture : source_color;
uniform float dissolve_value : hint_range(0,1);
uniform float burn_size: hint_range(0.0, 1.0, 0.01);
uniform vec4 burn_color: source_color;

void fragment(){
    vec4 main_texture = texture(TEXTURE, UV);
    vec4 noise_texture = texture(dissolve_texture, UV);

	// This is needed to avoid keeping a small burn_color dot with dissolve being 0 or 1
	// is there another way to do it?
	float burn_size_step = burn_size * step(0.001, dissolve_value) * step(dissolve_value, 0.999);
	float threshold = smoothstep(noise_texture.x-burn_size_step, noise_texture.x, dissolve_value);
	float border = smoothstep(noise_texture.x, noise_texture.x + burn_size_step, dissolve_value);

	COLOR.a *= threshold;
	COLOR.rgb = mix(burn_color.rgb, main_texture.rgb, border);
}
