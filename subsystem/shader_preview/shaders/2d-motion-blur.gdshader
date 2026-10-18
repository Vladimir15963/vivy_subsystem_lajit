// ================================================================
// 2D Motion Blur
// ================================================================
// 来源   https://godotshaders.com/shader/2d-motion-blur/
// 作者   Hayden  https://godotshaders.com/author/hayden/
// 发布   2021-08-03
// 类型   canvas_item
// 许可   cc0
// 标签   2d, blur, canvas
// ================================================================
// 介绍
// Adds directional motion blur to canvas items like Sprite. Direction, size, and quality of blur can be configured.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;
uniform vec2 dir = vec2(0,0);
uniform int quality = 4;

void vertex(){
	vec2 blurSize = abs(dir) * 2.0;
	VERTEX *= blurSize + 1.0;
	UV = (UV - 0.5) * (blurSize + 1.0) + 0.5;
}

float insideUnitSquare(vec2 v) {
    vec2 s = step(vec2(0.0), v) - step(vec2(1.0), v);
    return s.x * s.y;
}

void fragment(){
	float inSquare = insideUnitSquare(UV);
	float numSamples = inSquare;
	COLOR = texture(TEXTURE, UV) * inSquare;
	vec2 stepSize = dir/(float(quality));
	vec2 uv;
	for(int i = 1; i <= quality; i++){
		uv = UV + stepSize * float(i);
		inSquare = insideUnitSquare(uv);
		numSamples += inSquare;
		COLOR += texture(TEXTURE, uv) * inSquare;

		uv = UV - stepSize * float(i);
		inSquare = insideUnitSquare(uv);
		numSamples += inSquare;
		COLOR += texture(TEXTURE, uv) * inSquare;
	}
	COLOR.rgb /= numSamples;
	COLOR.a /= float(quality)*2.0 + 1.0;
}
