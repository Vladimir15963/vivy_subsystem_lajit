// ================================================================
// Text Peel Shader
// ================================================================
// 来源   https://godotshaders.com/shader/text-peel-shader/
// 作者   ZareGameDev  https://godotshaders.com/author/zaregamedev/
// 发布   2026-07-30
// 类型   spatial
// 许可   cc0
// Godot  4.5
// 标签   3D noise dissolve, damaged text, dissolve shader, Godot 4 shader, peeled text, procedural dissolve, spatial shader, text dissolve, textmesh shader, world space dissolve
// ================================================================
// 介绍
// I needed a way to create dissolved, old, or peeled text without using images or decals, which makes it lighter and easier to use on many objects.
//
// Create a MeshInstance3D.
//
// Set the mesh type to TextMesh.
//
// Set Depth to 0.
//
// Adjust the shader parameters to get the look you want.
//
// This shader uses procedural 3D noise, so no texture is required.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_back;

uniform vec4 text_color : source_color = vec4(1.0);
uniform float fade_amount : hint_range(0.0, 1.0) = 0.0;
uniform float noise_scale : hint_range(0.1, 10.0) = 2.0;
uniform float edge_softness : hint_range(0.0, 0.5) = 0.1;

varying vec3 world_pos;


float hash(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float noise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);

    float n000 = hash(i + vec3(0,0,0));
    float n100 = hash(i + vec3(1,0,0));
    float n010 = hash(i + vec3(0,1,0));
    float n110 = hash(i + vec3(1,1,0));
    float n001 = hash(i + vec3(0,0,1));
    float n101 = hash(i + vec3(1,0,1));
    float n011 = hash(i + vec3(0,1,1));
    float n111 = hash(i + vec3(1,1,1));

    vec3 u = f * f * (3.0 - 2.0 * f);

    return mix(
        mix(mix(n000, n100, u.x),
            mix(n010, n110, u.x), u.y),
        mix(mix(n001, n101, u.x),
            mix(n011, n111, u.x), u.y),
        u.z
    );
}

void vertex() {
    world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {

    vec3 p = world_pos * noise_scale;

    float n = noise(p) * 0.6 +
              noise(p * 2.0) * 0.3 +
              noise(p * 4.0) * 0.1;

    float mask = smoothstep(
        fade_amount - edge_softness,
        fade_amount + edge_softness,
        n
    );

    ALBEDO = text_color.rgb;
    ALPHA = text_color.a * mask;

    if (ALPHA < 0.02) {
        discard;
    }
}
