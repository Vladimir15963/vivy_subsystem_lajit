// ================================================================
// 2D outline/inline
// ================================================================
// 来源   https://godotshaders.com/shader/2d-outline-inline/
// 作者   Juulpower  https://godotshaders.com/author/juulpower/
// 发布   2021-01-19
// 类型   canvas_item
// 许可   cc0
// 标签   2d, border, configurable, inline, outline, stroke
// ================================================================
// 介绍
// Adds an outer or inner stroke to a texture. Just attach the shader to a material and the material to a canvas item like a sprite. This shader is robust and configurable (color, width, pattern, placement, and the ability to add margins to the texture to make room for an outline). However, for textures with anti-aliased edges this shader might provide a better result.
//
// For Godot 3, replace source_color at line 3 by hint_color.
//
// For Godot 4, if you also want to use the modulate property, you can incorporate this solution for now and then replace texture(TEXTURE, uv) by texture(TEXTURE, uv) * modulate twice, color.rgb (case-sensitive) by color.rgb * modulate.rgb twice, and color.a (case-sensitive) by color.a * modulate.a twice.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

uniform vec4 color : source_color = vec4(1.0);
uniform float width : hint_range(0, 10) = 1.0;
uniform int pattern : hint_range(0, 2) = 0; // diamond, circle, square
uniform bool inside = false;
uniform bool add_margins = true; // only useful when inside is false

void vertex() {
	if (add_margins) {
		VERTEX += (UV * 2.0 - 1.0) * width;
	}
}

bool hasContraryNeighbour(vec2 uv, vec2 texture_pixel_size, sampler2D texture) {
	for (float i = -ceil(width); i <= ceil(width); i++) {
		float x = abs(i) > width ? width * sign(i) : i;
		float offset;

		if (pattern == 0) {
			offset = width - abs(x);
		} else if (pattern == 1) {
			offset = floor(sqrt(pow(width + 0.5, 2) - x * x));
		} else if (pattern == 2) {
			offset = width;
		}

		for (float j = -ceil(offset); j <= ceil(offset); j++) {
			float y = abs(j) > offset ? offset * sign(j) : j;
			vec2 xy = uv + texture_pixel_size * vec2(x, y);

			if ((xy != clamp(xy, vec2(0.0), vec2(1.0)) || texture(texture, xy).a <= 0.0) == inside) {
				return true;
			}
		}
	}

	return false;
}

void fragment() {
	vec2 uv = UV;

	if (add_margins) {
		vec2 texture_pixel_size = vec2(1.0) / (vec2(1.0) / TEXTURE_PIXEL_SIZE + vec2(width * 2.0));

		uv = (uv - texture_pixel_size * width) * TEXTURE_PIXEL_SIZE / texture_pixel_size;

		if (uv != clamp(uv, vec2(0.0), vec2(1.0))) {
			COLOR.a = 0.0;
		} else {
			COLOR = texture(TEXTURE, uv);
		}
	} else {
		COLOR = texture(TEXTURE, uv);
	}

	if ((COLOR.a > 0.0) == inside && hasContraryNeighbour(uv, TEXTURE_PIXEL_SIZE, TEXTURE)) {
		COLOR.rgb = inside ? mix(COLOR.rgb, color.rgb, color.a) : color.rgb;
		COLOR.a += (1.0 - COLOR.a) * color.a;
	}
}
