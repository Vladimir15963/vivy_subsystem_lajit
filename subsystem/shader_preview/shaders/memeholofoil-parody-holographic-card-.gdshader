// ================================================================
// MemeHoloFoil – Parody Holographic Card Foil（全息卡片）
// ================================================================
// 来源   https://godotshaders.com/shader/memeholofoil-parody-holographic-card-/
// 作者   vino  https://godotshaders.com/author/vino/
// 发布   2026-08-27
// 类型   spatial
// 许可   cc0
// Godot  4.5 / 4.6
// 标签   card, chrome, foil, godot4, holo, holographic, iridescent, laser, meme, parody, rainbow, sci-fi, Spatial, tradingcard
// ================================================================
// 介绍
// Parody holographic foil shader with time-flowing rainbow effect, designed for meme trading cards. Supports albedo + mask.
//
// 一款专为模因（meme）集换式卡牌设计的恶搞全息面膜染色器，具有随时间流动的彩虹效果，支持反光率（albedo）与遮罩（mask）贴图。
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

/** MemeHoloFoil - 卡牌全息箔（带时间流动彩虹） */
shader_type spatial;
render_mode specular_schlick_ggx, blend_mix, depth_draw_opaque, cull_back;

// ========== 基础材质参数 ==========
/** 表面粗糙度，越低越像镜面镭射膜（推荐 0.02~0.08） */
uniform float roughness : hint_range(0.0, 1.0) = 0.04;

/** 金属度，全息箔建议保持 1.0 */
uniform float metallic : hint_range(0.0, 1.0) = 1.0;

/** 高光强度 */
uniform float specular : hint_range(0.0, 1.0) = 1.0;

// ========== 全息虹彩参数 ==========
/** 彩虹颜色条带密度，数值越大颜色切换越频繁 */
uniform float iridescence_scale : hint_range(0.5, 15.0) = 5.0;

/** 虹彩强度，0=无效果，1=完全彩虹 */
uniform float iridescence_intensity : hint_range(0.0, 1.0) = 0.9;

/** 边缘菲涅尔强度，控制边缘高光与彩虹的锐利程度 */
uniform float fresnel_power : hint_range(1.0, 8.0) = 2.8;

/** 自发光强度，让全息颜色在暗处也更醒目 */
uniform float emission_strength : hint_range(0.0, 2.0) = 0.35;

// ========== 时间流动参数 ==========
/** 彩虹流动速度，数值越大流动越快（建议 0.1~1.5） */
uniform float flow_speed : hint_range(0.0, 5.0) = 0.6;

/** 流动方向强度（影响 UV 与视角的混合权重） */
uniform float flow_direction : hint_range(0.0, 2.0) = 1.0;

// ========== 颜色与贴图 ==========
/** 基础金属底色（默认偏银色） */
uniform vec3 base_metal_color : source_color = vec3(0.82, 0.84, 0.9);

/** 卡牌基础贴图（可选，不填则使用纯色底） */
uniform sampler2D albedo_texture : source_color, hint_default_white;

/** 全息遮罩贴图（白色=全息区域，黑色=无全息。不填则整张卡都全息） */
uniform sampler2D holo_mask : source_color, hint_default_white;

/** 遮罩强度，控制遮罩影响程度 */
uniform float mask_strength : hint_range(0.0, 1.0) = 1.0;

// HSV 转 RGB
vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	// 采样基础贴图与遮罩
	vec4 tex = texture(albedo_texture, UV);
	float mask = texture(holo_mask, UV).r;
	mask = mix(1.0, mask, mask_strength);

	// 视角与法线夹角
	float NdotV = clamp(dot(NORMAL, VIEW), 0.0, 1.0);

	// 时间流动 + 视角 + UV 驱动的彩虹
	float flow = TIME * flow_speed;
	float hue = fract(
		(1.0 - NdotV) * iridescence_scale * 0.7 +
		UV.x * flow_direction +
		UV.y * flow_direction * 0.6 +
		flow
	);

	vec3 rainbow = hsv2rgb(vec3(hue, 0.92, 1.0));

	// Fresnel 边缘增强
	float fresnel = pow(1.0 - NdotV, fresnel_power);

	// 混合基础金属色与彩虹
	vec3 holo_color = mix(base_metal_color, rainbow, iridescence_intensity);
	holo_color = mix(holo_color, rainbow * 1.25, fresnel * 0.55);

	// 与卡牌贴图混合，并受遮罩控制
	vec3 final_albedo = mix(tex.rgb, holo_color, mask * iridescence_intensity);
	final_albedo = mix(final_albedo, holo_color, fresnel * mask * 0.4);

	ALBEDO = final_albedo;
	METALLIC = metallic * mask;
	ROUGHNESS = mix(0.6, roughness, mask);
	SPECULAR = specular;

	// 自发光让流动的彩虹更醒目
	EMISSION = holo_color * emission_strength * mask * (0.35 + fresnel * 0.65);
	ALPHA = tex.a;
}
