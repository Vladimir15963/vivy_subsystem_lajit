// ================================================================
// Foggy Glass Shader
// ================================================================
// 来源   https://godotshaders.com/shader/foggy-glass-shader/
// 作者   Star  https://godotshaders.com/author/star/
// 发布   2026-06-20
// 类型   canvas_item
// 许可   cc0
// Godot  4.6
// 标签   blur, foggy, foggy blur, glass, steam, steamy, ui, ux
// ================================================================
// 介绍
// A foggy glass shader for the settings background of a VN im working on.
//
// To use it apply it to a color rect, or whatever you want to have the affect, then add the noise image(or really any image you want) and tick seamless.
//
// if you’re wanting a more pixelated “fogginess” effect change “filter_linear_mipmap” in ScreenTexture to “filter_nearest_mipmap”
//
// GlassColor: modulation color aplied to the shader
//
// Fogginess: how blurred the texture is
//
// NoiseTexture: the texture overlayed to give variation
//
// NoiseMoveSpeed: how fast the texture overlay moves, its sin(TIME / NoiseMoveSpeed) so lower = faster
//
// TextureModulationStregnth: how strong the texture overlay is
//
// CelShading: toggles the celshading effect, it doesnt work well if using "filter_nearest_mipmap" and NoiseTexture overlay
//
// CelShadingStregnth: uses COLOR.rgb = round(COLOR.rgb * CelShadingStregnth) / CelShadingStregnth so the lower the CelShadingStregnth the more intense the color limiting, round numbers work best
//
// mess around with the variables to get what you want, the default settings are what i am useing
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

uniform sampler2D ScreenTexture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform vec4 GlassColor : source_color;
uniform float Fogginess : hint_range(0.0, 10.0, 0.1) = 2.0;

group_uniforms TextureOverlay;
uniform bool TextureOverlay = false;
uniform sampler2D TextureOverlayTexture : hint_default_white, repeat_enable;
uniform float TextureMoveSpeed : hint_range(1.0, 200.0, 1.0) = 75;
uniform float TextureModulationStregnth : hint_range(0.0, 1.0, 0.1) = .1;

group_uniforms CelShading;
uniform bool CelShading = false;
uniform float CelShadingStregnth : hint_range(1.0, 20.0, 0.1) = 10;


void fragment() {
	COLOR = textureLod(ScreenTexture, SCREEN_UV, Fogginess);
	if (TextureOverlay == true) {
		COLOR.rgb = clamp(COLOR.rgb + GlassColor.rgb + (texture(TextureOverlayTexture, UV + sin(TIME / TextureMoveSpeed)).rgb * TextureModulationStregnth) , 0, 1);
	} else {
		COLOR.rgb = clamp(COLOR.rgb + GlassColor.rgb, 0, 1);
	}
	if (CelShading == true) {
		COLOR.rgb = round(COLOR.rgb * CelShadingStregnth) / CelShadingStregnth;
	}
	COLOR.a = GlassColor.a;
}
