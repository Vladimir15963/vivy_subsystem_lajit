// ================================================================
// Canvas drop shadow and inner shadow shader
// ================================================================
// 来源   https://godotshaders.com/shader/canvas-drop-shadow-and-inner-shadow-shader/
// 作者   Gencreezo  https://godotshaders.com/author/gencreezo/
// 发布   2025-10-06
// 类型   canvas_item
// 许可   cc0
// 标签   2d shadow, canvas shadow, drop shadow, inner shadow, shadow
// ================================================================
// 介绍
// This shader is AI generated.
//
// It’s purpose is to give drop and inner shadow functionality that can be added to canvas elements in a similar way as design tool such as Figma.
//
// I use it mostly for UI Icons, so it works best with TextureRects, i have not tested it with other elements.
//
// How to use:
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;
render_mode blend_mix, unshaded;

// Simple, configurable drop shadow and inner shadow for any shape with an alpha channel.
// Groups: General, Drop Shadow, Inner Shadow

// General
group_uniforms General;
uniform sampler2D source_texture; // group("General")
// Optional override for pixel-to-UV conversion (e.g., atlas region size in px)
uniform vec2 source_size_px = vec2(0.0, 0.0); // group("General")
uniform bool use_base_tint = true; // true: use base_tint, false: use node modulate (COLOR) // group("General")
uniform vec4 base_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0); // group("General")
uniform bool draw_base = true;   // Set false to render only the base // group("General")

// Drop Shadow
group_uniforms Drop_Shadow;
uniform bool draw_shadow = true; // Set false to disable the outer shadow // group("General")
uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.5); // group("Drop Shadow")
uniform vec2 shadow_offset = vec2(0.0, -10.0); // pixels // group("Drop Shadow")
uniform float shadow_softness : hint_range(0.0, 64.0) = 4.0; // pixels // group("Drop Shadow")
uniform float shadow_spread : hint_range(0.0, 1.0) = 0.0; // group("Drop Shadow")

group_uniforms Inner_Shadow;
uniform bool enable_inner_shadow = false; // group("Inner Shadow")
uniform vec4 inner_shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.5); // group("Inner Shadow")
uniform vec2 inner_shadow_offset = vec2(0.0, 10.0); // pixels // group("Inner Shadow")
uniform float inner_shadow_softness : hint_range(0.0, 64.0) = 4.0; // pixels // group("Inner Shadow")
uniform float inner_shadow_spread : hint_range(0.0, 1.0) = 0.0; // group("Inner Shadow")

float sample_alpha(vec2 uv) {
  return texture(source_texture, uv).a;
}

void fragment() {
  vec4 base = texture(source_texture, UV);

  // Apply either shader tint OR node modulate, not both
  vec4 tinted = base;
  if (use_base_tint) {
    tinted *= base_tint;
  } else {
    tinted.rgb *= COLOR.rgb;
    tinted.a *= COLOR.a;
  }

  // Convert pixel amounts to UV space using source size
  vec2 tex_size = source_size_px;
  if (tex_size.x <= 0.0 || tex_size.y <= 0.0) {
    tex_size = vec2(textureSize(source_texture, 0));
  }
  tex_size = max(tex_size, vec2(1.0));
  vec2 texel_size = 1.0 / tex_size;
  vec2 px = texel_size * max(shadow_softness, 0.0);
  vec2 off = texel_size * shadow_offset;

  // 9-tap box blur on the alpha around the offset position
  float a = 0.0;
  a += sample_alpha(UV + off);
  a += sample_alpha(UV + off + vec2(px.x, 0.0));
  a += sample_alpha(UV + off + vec2(-px.x, 0.0));
  a += sample_alpha(UV + off + vec2(0.0, px.y));
  a += sample_alpha(UV + off + vec2(0.0, -px.y));
  a += sample_alpha(UV + off + vec2(px.x, px.y));
  a += sample_alpha(UV + off + vec2(-px.x, px.y));
  a += sample_alpha(UV + off + vec2(px.x, -px.y));
  a += sample_alpha(UV + off + vec2(-px.x, -px.y));
  a /= 9.0;

  // Tighten or expand the shadow edge
  if (shadow_spread > 0.0) {
    a = clamp((a - shadow_spread) / max(1e-4, 1.0 - shadow_spread), 0.0, 1.0);
  }

  // Inner shadow: blur alpha at opposite offset and invert to keep inside
  if (enable_inner_shadow) {
    vec2 in_px = texel_size * max(inner_shadow_softness, 0.0);
    vec2 in_off = texel_size * inner_shadow_offset;

    float ia = 0.0;
    ia += texture(source_texture, UV - in_off).a;
    ia += texture(source_texture, UV - in_off + vec2(in_px.x, 0.0)).a;
    ia += texture(source_texture, UV - in_off + vec2(-in_px.x, 0.0)).a;
    ia += texture(source_texture, UV - in_off + vec2(0.0, in_px.y)).a;
    ia += texture(source_texture, UV - in_off + vec2(0.0, -in_px.y)).a;
    ia += texture(source_texture, UV - in_off + vec2(in_px.x, in_px.y)).a;
    ia += texture(source_texture, UV - in_off + vec2(-in_px.x, in_px.y)).a;
    ia += texture(source_texture, UV - in_off + vec2(in_px.x, -in_px.y)).a;
    ia += texture(source_texture, UV - in_off + vec2(-in_px.x, -in_px.y)).a;
    ia /= 9.0;

    float inner = 1.0 - ia;
    if (inner_shadow_spread > 0.0) {
      inner = clamp((inner - inner_shadow_spread) / max(1e-4, 1.0 - inner_shadow_spread), 0.0, 1.0);
    }
    inner *= base.a; // constrain to inside of the shape

    float inner_mix = inner * inner_shadow_color.a * float(draw_base);
    tinted.rgb = mix(tinted.rgb, inner_shadow_color.rgb, inner_mix);
  }

  // Composite: shadow behind the base image (Porter-Duff over)
  float s = shadow_color.a * a * (draw_shadow ? 1.0 : 0.0);
  float b = tinted.a * (draw_base ? 1.0 : 0.0);

  vec3 out_rgb = tinted.rgb * b + (1.0 - b) * shadow_color.rgb * s;
  float out_a = b + (1.0 - b) * s;

  COLOR = vec4(out_rgb, out_a);
}
