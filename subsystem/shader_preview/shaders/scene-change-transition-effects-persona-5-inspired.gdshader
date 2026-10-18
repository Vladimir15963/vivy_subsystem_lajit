// ================================================================
// Scene Change Transition Effects (persona 5 inspired)
// ================================================================
// 来源   https://godotshaders.com/shader/scene-change-transition-effects-persona-5-inspired/
// 作者   ProfesorShader  https://godotshaders.com/author/profesorshader/
// 发布   2026-06-14
// 类型   canvas_item
// 许可   cc0
// Godot  4.6
// 标签   change, scene, transition
// ================================================================
// 介绍
// These are two very simple Persona 5 inspired transition shaders. I’ve created this for my “scene change with transtions” tutorial. I’m also using the new Godot 4.7 control nodes transform offset, so if you try the github demo, be sure to use Godot 4.7 Dev 3 or above.
//
// For more details, please take a look to the sample/demo project on my github and/or watch my youtube video for a detailed explanation of this shader (its in spanish).
//
// Enjoy! 😘​
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

// Persona 5 slash transition
shader_type canvas_item;
render_mode unshaded;

uniform float t = 0.5; // value between 0 and 1 (animation start and end)
uniform float power = 10.0;
uniform vec4 mask_color : source_color = vec4(0.0, 0.0, 0.5, 1.0);
uniform vec4 background_color : source_color = vec4(0.0, 0.0, 0.0, 0.0);
uniform vec2 normal = vec2(1.0, 1.0);
uniform float offset = -0.5;

void fragment() {
    vec2 p = UV;

    float dist = abs(dot(normalize(normal), p) + offset);

	float thickness = pow(t, power);

    float line = dist <= thickness ? 1.0 : 0.0;

    COLOR = mix(background_color, mask_color, line);
}

// Persona 5 square transition
shader_type canvas_item;
render_mode unshaded;

uniform float t = 0.5; // value between 0 and 1 (animation start and end)
uniform vec4 mask_color : source_color = vec4(0.0, 0.0, 0.5, 1.0);
uniform vec4 background_color : source_color = vec4(0.0, 0.0, 0.0, 0.0);
uniform vec2 translate = vec2(-0.25, -0.25);
uniform float extra_size = 1.0;

// returns 1 if it's inside the square, otherwise returns 0
float square(vec2 uv, float width)
{
    return step(max(abs(uv.x), abs(uv.y)), width);
}

vec2 rotate(vec2 uv, float angle)
{
	return uv * mat2(vec2(sin(angle), -cos(angle)), vec2(cos(angle), sin(angle)));;
}

void fragment() {
	// convert from 0..1 to -1..1
	vec2 uv = UV * 2.0 - 1.0;

	// fix aspect ratio
	uv.y *= SCREEN_PIXEL_SIZE.x / SCREEN_PIXEL_SIZE.y;

	// translate
	uv += translate;

	// rotate UVs
	uv = rotate(uv, PI * 0.25);

	// "draw" square
    float sqr = square(uv, (1.0 + extra_size) * t);
	COLOR = mix(mask_color, background_color, sqr);
}
