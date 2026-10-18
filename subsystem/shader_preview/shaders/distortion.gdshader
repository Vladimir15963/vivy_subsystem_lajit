// ================================================================
// Distortion/Shockwave Shader
// ================================================================
// 来源   https://godotshaders.com/shader/distortion/
// 作者   mrsir8433  https://godotshaders.com/author/mrsir8433/
// 发布   2022-04-16
// 类型   canvas_item
// 许可   cc0
// 标签   aberration, distortion, godot_4_1_1, lens, screen-space, shockwave
// ================================================================
// 介绍
// A basic distortion shader with chromatic abberation, with modular parameters.
//
// # Edit – 4.1.1
//
// 0. Godot 4.1.1 update
//
// 1. Ok. First of all, it is a screen-space shader. If one wants to add this to specific node with texture, it has to be modified a bit. Like the screen-texture has to be changed to node-specific texture with sampler2d.
//
// 2. You can download the demo-project here. godot_shaders_distortion
//
// 3. You have to animate the radius and center parameters from outside. Add this shader to a color-rect above all nodes as a canvas layer. The center property is in range 0 to 1. So you have to normalise the position u want the distortion to originate from.
//
// 4. If any problem happens, comment here; I will try to response accordingly.
//
// Peace!!!
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

uniform float strength: hint_range(0.0, 0.1, 0.001) = 0.08;
uniform vec2 center = vec2(0.5, 0.5);
uniform float radius: hint_range(0.0, 1.0, 0.001) = 0.25;


uniform float aberration: hint_range(0.0, 1.0, 0.001) = 0.425;
uniform float width: hint_range(0.0, 0.1, 0.0001) = 0.04;
uniform float feather: hint_range(0.0, 1.0, 0.001) = 0.135;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

void fragment() {
	vec2 st = SCREEN_UV;
	float aspect_ratio = SCREEN_PIXEL_SIZE.y/SCREEN_PIXEL_SIZE.x;
	vec2 scaled_st = (st -vec2(0.0, 0.5)) / vec2(1.0, aspect_ratio) + vec2(0,0.5);
	vec2 dist_center = scaled_st - center;
	float mask =  (1.0 - smoothstep(radius-feather, radius, length(dist_center))) * smoothstep(radius - width - feather, radius-width , length(dist_center));
	vec2 offset = normalize(dist_center)*strength*mask;
	vec2 biased_st = scaled_st - offset;

	vec2 abber_vec = offset*aberration*mask;

	vec2 final_st = st*(1.0-mask) + biased_st*mask;

	vec4 red = texture(SCREEN_TEXTURE, final_st + abber_vec);
	vec4 blue = texture(SCREEN_TEXTURE, final_st - abber_vec);
	vec4 ori = texture(SCREEN_TEXTURE, final_st);
	COLOR = vec4(red.r, ori.g, blue.b, 1.0);
}
