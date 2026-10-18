// ================================================================
// 2D Foliage Wind Effect
// ================================================================
// 来源   https://godotshaders.com/shader/2d-foliage-wind-effect/
// 作者   jess.codes  https://godotshaders.com/author/jess-codes/
// 发布   2025-06-10
// 类型   canvas_item
// 许可   cc0
// ================================================================
// 介绍
// A fragment shader made in Godot 4.4 that creates a windy effect. It works by rotating UVs around a specified pivot point, and fluctuates the strength based on a noise texture. By rotating around a fixed point at the bottom of the trunk, the tree trunk can remain still while the top of the leaves can move freely.
//
// Apply the shader to a Sprite2D node, and add a noise texture, then set the parameters however you want.
//
// Other notes:
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

uniform bool render_noise = false;
uniform sampler2D noise_texture : repeat_enable; // set in inspector
uniform float amplitude : hint_range(0.0, 0.5, 0.01) = 0.2;
uniform float time_scale : hint_range(0.0, 5.0, 0.01) = 0.04;
uniform float noise_scale : hint_range(0.0, 2.0, 0.0001) = 0.001;
uniform float rotation_strength : hint_range(0.0, 5.0, 0.1) = 1;
uniform vec2 rotation_pivot = vec2(0.5, 1);
varying vec2 world_position;

void vertex(){
    world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

vec2 get_sample_pos(vec2 pos, float scale, float offset) {
	pos *= scale;
	pos += offset;
	return pos;
}

vec2 rotate_vec(vec2 vec, vec2 pivot, float rotation) {
	float cosa = cos(rotation);
	float sina = sin(rotation);
	vec -= pivot;
	return vec2(
		cosa * vec.x - sina * vec.y,
		cosa * vec.y + sina * vec.x
	) + pivot;
}

void fragment() {
	// get noise from texture
	vec2 noise_sample_pos = get_sample_pos(world_position, noise_scale, TIME * time_scale);
	float noise_amount = texture(noise_texture, noise_sample_pos).r - 0.5f;

	// get rotation position around a pivot
	float rotation = amplitude * noise_amount;
	vec2 rotated_uvs = rotate_vec(UV, rotation_pivot, rotation);

	// blend original uvs and rotated uvs based on distance to pivot
	float dist = distance(UV, rotation_pivot) * rotation_strength;
	vec2 result_uvs = mix(UV, rotated_uvs, dist);

	// output color
	COLOR = texture(TEXTURE, result_uvs);

	// optional, preview noise texture for debugging
	if (render_noise) {
		vec4 noise_color = texture(noise_texture, noise_sample_pos);
		COLOR = noise_color;
	}
}
