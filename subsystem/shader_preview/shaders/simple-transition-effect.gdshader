// ================================================================
// Simple Transition Effect
// ================================================================
// 来源   https://godotshaders.com/shader/simple-transition-effect/
// 作者   CamiXes  https://godotshaders.com/author/camixes/
// 发布   2021-07-31
// 类型   canvas_item
// 许可   cc0
// ================================================================
// 介绍
// this is my first shader!
//
// I was messing around with some trigonometry functions and some other functions and accidentally made this effect.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;
uniform float Speed = 1f; // movement speed

uniform float Intensity = 2f; // higher numbers add a second color
uniform float Hardness = 500f; // circle sizes
uniform vec2 Scale = vec2(1f,1f); // scale
uniform float RotationSpeed = 1f; // rotation speed
uniform vec3 Color = vec3(1f,1f,1f); //attempt at color changing, doesn't really work, only barely noticeable when hardness is at 1f

// one thing that may happen is that the second color may match your theme for some reason, but it should go back to being black when running the game.

void fragment()
{
	float coolEffect = pow(sin((sin(UV.x*(100f)*Scale.x)*cos(UV.y*(100.f*Scale.y)))+(sin(UV.x+TIME*RotationSpeed)+cos(UV.y+TIME*RotationSpeed))+TIME*Speed)*Intensity,Hardness);

	vec4 offsetColor = vec4(coolEffect+Color.r,coolEffect+Color.g,coolEffect+Color.b,coolEffect);
	COLOR = offsetColor;
}
