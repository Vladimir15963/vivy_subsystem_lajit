// ================================================================
// Modified 2D-perspective (sprite-sheet)
// ================================================================
// 来源   https://godotshaders.com/shader/modified-2d-perspective-sprite-sheet/
// 作者   nswagg  https://godotshaders.com/author/nswagg/
// 发布   2025-09-05
// 类型   canvas_item
// 许可   mit
// ================================================================
// 介绍
// Derivative of Hei’s 2D-perspective shader to work when Sprite2D is a sprite sheet (instead of using animated sprite2D). Check out their work and forum: https://godotshaders.com/shader/2d-perspective/ (MIT License)
//
// The UVs are calculated by the whole texture on the original shader (as designed), which can make the perspective look incorrect when only viewing part of the whole sprite.
//
// It’s important that the Sprite2D does not use the “Region” option, or the effect will not work as expected.
//
// Tested with “horizontal” sprite sheet, sprites on same Y layer for simplicity. Define number of sprites in sheet with num_col and active sprite frame to view with active_frame
//
// EDIT: Corrected projection; frames were calculating differently when re-projecting after translation. Offset was missed. Added back for pivots around origin instead of translating unnecessarily.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

// This shader "fakes" a 3D-camera perspective on CanvasItems, based on Hei's
// 2d-perspective shader. See URL below
// URL: https://godotshaders.com/shader/2d-perspective/
// License: MIT
// Docs: https://docs.godotengine.org/en/stable/tutorials/shaders/
// shader_reference/canvas_item_shader.html

shader_type canvas_item;



uniform int num_col: hint_range(0, 8) = 2;
uniform int active_frame = 0;
// Camera FOV
uniform float fov : hint_range(1, 179) = 90;
uniform float y_rot : hint_range(-180, 180) = 0.0;
uniform float x_rot : hint_range(-180, 180) = 0.0;
// can change to uniform if needed
uniform bool cull_back = true;
// At 0, the image retains its size when unrotated.
// At 1, the image is resized so that it can do a full
// rotation without clipping inside its rect.
uniform float inset : hint_range(0, 1) = 0.0;
// Consider changing this to a uniform and changing it from code

varying flat vec2 o;
varying vec3 p;

// Creates rotation matrix
void vertex(){
	float sin_b = sin(y_rot / 180.0 * PI);
	float cos_b = cos(y_rot / 180.0 * PI);
	float sin_c = sin(x_rot / 180.0 * PI);
	float cos_c = cos(x_rot / 180.0 * PI);

	mat3 inv_rot_mat;
	inv_rot_mat[0][0] = cos_b;
	inv_rot_mat[0][1] = 0.0;
	inv_rot_mat[0][2] = -sin_b;

	inv_rot_mat[1][0] = sin_b * sin_c;
	inv_rot_mat[1][1] = cos_c;
	inv_rot_mat[1][2] = cos_b * sin_c;

	inv_rot_mat[2][0] = sin_b * cos_c;
	inv_rot_mat[2][1] = -sin_c;
	inv_rot_mat[2][2] = cos_b * cos_c;


	float t = tan(fov / 360.0 * PI);
	p = inv_rot_mat * vec3((UV - 0.50), 0.5 / t);
	float v = (0.5 / t) + 0.5;
	p.xy *= v * inv_rot_mat[2].z; // 3D projection
	o = v * inv_rot_mat[2].xy;

	VERTEX += (UV - 0.5) / TEXTURE_PIXEL_SIZE * t * (1.0 - inset);
}

void fragment(){
	// cull backside of sprite
	if (cull_back && p.z <= 0.0) discard;
	// project to 2D
	vec2 uv = (p.xy / p.z).xy - o;
	// normalize projection back into [0..1]
	uv = vec2(uv.x*float(num_col) + 0.5, uv.y+0.5);
	// select frame
	float frame_width = 1.0 / float(num_col);
	uv.x = uv.x * frame_width + frame_width * float(active_frame);

	// validate possible value
	if (num_col > 1 && active_frame >= 0 && active_frame < num_col) {
		// cull regions outside active frame pixel region
		if (uv.x < 0.0 + (float(active_frame)/float(num_col))) discard; //left
		if (uv.x > 0.5 + (float(active_frame)/float(num_col))) discard; // right
	}
	COLOR = texture(TEXTURE, uv);
	// keep alpha in bounds of projection
	COLOR.a *= step(max(abs((p.x/p.z) - o.x), abs((p.y/p.z) - o.y)), 0.5);
}
