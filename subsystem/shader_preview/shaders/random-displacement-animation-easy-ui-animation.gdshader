// ================================================================
// Random displacement animation (Easy UI animation)
// ================================================================
// 来源   https://godotshaders.com/shader/random-displacement-animation-easy-ui-animation/
// 作者   enekoassets  https://godotshaders.com/author/enekoassets/
// 发布   2025-05-28
// 类型   canvas_item
// 许可   cc0
// 标签   2d, animation, Baba is you
// ================================================================
// 介绍
// This animation shader is inspired by the game Baba is you. In Baba is you, the game’s looks are very minimalistic and monochromatic, but the animation cycle has a very special look. Baba is you uses spritesheets to animate its components, and this shader is not strictly the same thing.
//
// However, with this shader you can achieve a similar effect, using just one sprite per element. The shader randomly changes the position of the 4 vertices every n seconds, animating the sprite continuously.
//
// To use the shader just paste the code into a UI element’s shader.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;
uniform float interval = 0.5; // the displacement will happen every [interval] seconds
uniform float timeDelay = 0.0; // use it if you don't want all the sprites to move at the same time
uniform float intensityX = 20.0; // X axis force of movement
uniform float intensityY = 20.0; // Y axis force of movement
uniform float seed = 42.0; // seed to randomize movement

void vertex() {
	float chunk = floor((TIME + timeDelay) / interval);
	float seedNum = VERTEX.x + VERTEX.y + chunk + seed;
	float offsetX = sin(seedNum * 12.9898) * 43758.5453;
	float offsetY = sin(seedNum * 32.9472) * 94726.0482;
	offsetX = fract(offsetX);
	offsetX = offsetX * 2.0 - 1.0;
	offsetY = fract(offsetY);
	offsetY = offsetY * 2.0 - 1.0;
	VERTEX += vec2(offsetX * intensityX, offsetY * intensityY);
}
