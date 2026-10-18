// ================================================================
// Chromatic Abberation
// ================================================================
// 来源   https://godotshaders.com/shader/chromatic-abberation/
// 作者   Hayden  https://godotshaders.com/author/hayden/
// 发布   2022-06-09
// 类型   canvas_item
// 许可   cc0
// ================================================================
// 介绍
// Adjustable chromatic abberation.
//
// levels determines the level of detail.
//
// spread determines the intensity of the effect.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

uniform int levels = 3;
uniform float spread = 0.01;

vec3 chromatic_slice(float t){
	vec3 res = vec3(1.0-t, 1.0 - abs(t - 1.0), t - 1.0);
	return max(res, 0.0);
}

void fragment(){
	vec3 sum;
	COLOR.rgb = vec3(0);
	vec2 offset = (UV - vec2(0.5))*vec2(1,-1);
	for(int i = 0; i < levels; i++){
		float t = 2.0*float(i)/float(levels-1); // range 0.0->2.0
		vec3 slice = vec3(1.0-t, 1.0 - abs(t - 1.0), t - 1.0);
		slice = max(slice, 0.0);
		sum += slice;
		vec2 slice_offset = (t-1.0)*spread*offset;
		COLOR.rgb += slice * texture(SCREEN_TEXTURE, SCREEN_UV + slice_offset).rgb;
	}
	COLOR.rgb /= sum;
}
