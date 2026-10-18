// ================================================================
// Grid Shader
// ================================================================
// 来源   https://godotshaders.com/shader/grid-shader-2/
// 作者   Bandhu789  https://godotshaders.com/author/bandhu789/
// 发布   2026-04-05
// 类型   canvas_item
// 许可   cc0
// Godot  4.6
// 标签   cell, Cellular, grid
// ================================================================
// 介绍
// This shader draws a grid of custom cell size, cell offset, line width, and line color. Designed for debugging chunking in my upcoming game Bitbound.
//
// Note: Line width is defined in screen space, while grid size is defined in world space.
//
// Hope that this can be of use to someone <:
//
// Published in the public domain — free for anyone to use without any restrictions.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

// Uniforms
uniform float line_width: hint_range(1.0, 10.0, 1.0) = 1.0;
uniform float cell_size = 32.0;
uniform vec4 line_color: source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec2 grid_offset = vec2(0.0, 0.0);

// Variables
varying vec2 pixel_coordinate;
varying float screen_line_width;

// Calculate vertex coordinates
void vertex() {
	// Convert from local to world space coordinates
	pixel_coordinate = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;

	// Adjust line width via screen
	float world_scale = length(vec2(CANVAS_MATRIX[0][0], CANVAS_MATRIX[1][0]));
	screen_line_width = line_width / world_scale;
}

// Check if pixel falls on a grid line
bool falls_on_grid(vec2 world_position) {
	// Calculate offset position
    float width_offset = screen_line_width * 0.5;
    float x_frag = world_position.x + width_offset - grid_offset.x;
    float y_frag = world_position.y + width_offset - grid_offset.y;

	// Wrap coordinates
    float x_mod = mod(x_frag, cell_size);
    float y_mod = mod(y_frag, cell_size);

	// Calculate distance from axis lines
    float l_mod = min(x_mod, y_mod);

	// Return value
    if (l_mod < screen_line_width) {
        return true;
    }
    else {
        return false;
    }
}

// Calculate pixel color
void fragment() {
	// Check if falls on grid or discard
    if (falls_on_grid(pixel_coordinate)) {
        COLOR = line_color;
    }
	else {
		discard;
	}
}
