// ================================================================
// Clean UI Skeleton Loader / Shimmer
// ================================================================
// 来源   https://godotshaders.com/shader/clean-ui-skeleton-loader-shimmer/
// 作者   Dzsulioo  https://godotshaders.com/author/dzsulioo/
// 发布   2026-08-06
// 类型   canvas_item
// 许可   cc0
// Godot  4.6
// 标签   2d, animated, canvas_item, godot4, loader, loading, panel, Procedural, shimmer, skeleton, Stencil, ui
// ================================================================
// 介绍
// A modern, highly customizable skeleton screen loader for Godot 4.x UI panels. Features a smooth Gaussian glint sweep, adjustable colors, and a subtle background breathing pulse to make loading placeholders feel alive.
//
// How to Use
//
// Add a Panel node to your UI.
//
// In Theme Overrides > Styles, create a StyleBoxFlat.
//
// Under CanvasItem > Material, create a new ShaderMaterial and load this shader.
//
// Set the shader parameter corner_radius to 0.0, and use the StyleBoxFlat corner settings to control panel rounding.
//
// Features
//
// Smooth Gaussian shimmer curve (no harsh linear edges).
//
// Idle ambient breathing animation.
//
// Fully tweakable sweep angle, speed, shimmer width, and colors.
//
// Built-in optional SDF rounding fallback.
//
// License: CC0 1.0 Universal (Public Domain) – Free for personal and commercial projects!
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

// CC0 1.0 Universal - Public Domain Dedicated
// Clean Light-Theme Skeleton Loader Shader
shader_type canvas_item;

group_uniforms Base_Style;
uniform vec4 base_color : source_color = vec4(0.902, 0.902, 0.902, 1.0);
uniform vec4 shimmer_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float corner_radius : hint_range(0.0, 0.5) = 0.00;
uniform float aspect_ratio : hint_range(0.1, 10.0) = 1.0;

group_uniforms Sweep_Glint;
uniform float speed : hint_range(0.1, 5.0) = 2.2;
uniform float angle_degrees : hint_range(-180.0, 180.0) = 25.0;
uniform float shimmer_width : hint_range(0.02, 0.4) = 0.3;
uniform float shimmer_intensity : hint_range(0.0, 2.0) = 0.17
;

group_uniforms Micro_Polish;
uniform float ambient_depth : hint_range(0.0, 0.5) = 0.0;
uniform float base_pulse : hint_range(0.0, 0.4) = 0.4;

float sd_rounded_box(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

void fragment() {
    // 1. Aspect-Corrected UVs
    vec2 aspect_uv = (UV - vec2(0.5)) * vec2(aspect_ratio, 1.0);
    vec2 half_size = vec2(0.5 * aspect_ratio, 0.5);
    float clamped_radius = min(corner_radius, min(half_size.x, half_size.y));

    // 2. SDF Anti-Aliased Mask
    float dist = sd_rounded_box(aspect_uv, half_size, clamped_radius);
    float mask = 1.0 - smoothstep(-fwidth(dist), fwidth(dist), dist);

    // 3. Subtle Ambient Gradient & Base Pulse
    vec4 dynamic_base = base_color * (1.0 + ambient_depth * (0.5 - UV.y));
    float pulse = (sin(TIME * speed * 1.5) * 0.5 + 0.5) * base_pulse;
    dynamic_base.rgb = mix(dynamic_base.rgb, shimmer_color.rgb, pulse);

    // 4. Smooth Sweep Curve
    float rad = radians(angle_degrees);
    vec2 dir = vec2(cos(rad), sin(rad));
    float proj = dot(UV - vec2(0.5), dir);

    float period = 2.2;
    float sweep_pos = mod(TIME * speed, period) - 1.1;

    float norm_dist = (proj - sweep_pos) / shimmer_width;
    float wave = exp(-0.5 * norm_dist * norm_dist) * shimmer_intensity;

    // 5. Output
    vec4 final_color = mix(dynamic_base, shimmer_color, wave);
    COLOR = vec4(final_color.rgb, final_color.a * mask);
}
