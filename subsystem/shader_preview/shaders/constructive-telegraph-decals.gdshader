// ================================================================
// Constructive telegraph decals
// ================================================================
// 来源   https://godotshaders.com/shader/constructive-telegraph-decals/
// 作者   Dezimos  https://godotshaders.com/author/dezimos/
// 发布   2026-06-09
// 类型   spatial
// 许可   mit
// Godot  4.2 / 4.6
// 标签   aoe, damage, indicator, Telegraph
// ================================================================
// 介绍
// Displays customizable telegraph decals on certain surfaces (also known in some games as AoE indicators, area of effect markers, or combat cues). Each indicator is constructed from one or more primitive shapes (box, cylinder, sphere) in a similar way to constructive solid geometry (union, intersection, subtraction).
//
// Telegraphs are rendered as signed-distance fields evaluated in the fragment shader of the overlay mesh. Per-frame, telegraph data is serialized into a tiny texture (using RGB32F format so that floats can be stored with no color space conversion). The texture acts as a data transfer bus, passed as a single uniform to the shader. The shader reads this texture to reconstruct the SDF scene at each fragment.
//
// This approach avoids uniform buffer size limits (see godot#55674, godot#85374) and works across all renderers (Forward+, Mobile, Compatibility) without compute shaders, storage buffers, or multi-pass rendering.
//
// The single-pixel outline works by evaluating the signed-distance field at the four adjacent pixel positions (obtained via dFdx/dFdy in world space). If the signs differ among neighbors, the fragment is on a shape boundary and receives the outline color, all without a screen-space pass.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type spatial;
render_mode unshaded;
#include "res://addons/constructive_telegraphs/shaders/inc/con_telegraph_next_pass.gdshaderinc"

uniform sampler2D data_transfer_texture;
uniform sampler2D noise_texture;
uniform sampler2D pattern_1_texture;

varying vec3 world_normal;
varying vec3 world_position;


void vertex() {
    world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
    vec3 dfdx = dFdx(world_position);
    vec3 dfdy = dFdy(world_position);
    vec4 decal_color = fn_decal_color(
        data_transfer_texture,
        world_normal,
        world_position,
        dfdx,
        dfdy,
        noise_texture,
        pattern_1_texture
    );
    ALBEDO = decal_color.rgb;
	ALPHA = decal_color.a;
}

///
/// con_telegraph_next_pass.gdshaderinc
///

#include "res://addons/constructive_telegraphs/shaders/inc/con_telegraph_reader.gdshaderinc"
#include "res://addons/constructive_telegraphs/shaders/inc/dist_functions.gdshaderinc"

// Only surfaces facing within a degree of up should be included, outside that angle should be clipped.
// basis[1] is the normalized up vector
// world_normal is the normal of the ground in world space
// normal_clip_angle_deg is the maximum angle away from up that should be visible
bool fn_is_normal_clipped(mat3 basis, vec3 world_normal, float normal_clip_angle_deg) {
	float dot_product = dot(world_normal, basis[1]); // Clip based on normal dot from up vector
	float to_compare = 1.00001 - (normal_clip_angle_deg / 90.);
	return to_compare > dot(world_normal, basis[1]);
}

/// Mirror the scale component of the basis while preserving the original rotation component.
mat3 fn_basis_with_inverted_scale(mat3 original) {
    float scaleX = length(vec3(original[0][0], original[0][1], original[0][2]));
    float scaleY = length(vec3(original[1][0], original[1][1], original[1][2]));
    float scaleZ = length(vec3(original[2][0], original[2][1], original[2][2]));

	mat3 inverse_scale = mat3(
		vec3(1. / scaleX, 0., 0.),
		vec3(0., 1. / scaleY, 0.),
		vec3(0., 0., 1. / scaleZ)
	);
	return original * inverse_scale * inverse_scale;
}

/// The corresponding local offset of a given world position relative to the local origin and basis.
vec3 fn_local_offset(vec3 origin, mat3 basis, vec3 world_position) {
    return (world_position - origin) * fn_basis_with_inverted_scale(basis);
}


vec3 fn_normalized_offset(int flags, vec3 local_offset, float radius, vec3 extents) {
    if (is_shape_sphere(flags)) {
        return local_offset / radius;
    } else if (is_shape_box(flags)) {
        return local_offset / extents;
    } else if (is_shape_cylinder(flags)) {
        return vec3(local_offset.x / radius, local_offset.y / extents.y, local_offset.z / radius);
    } else {
        return vec3(1. / 0.);
    }
}


float fn_shape_sdist(int flags, vec3 local_offset, float radius, vec3 extents) {
    if (is_shape_sphere(flags)) {
        return sdSphere(local_offset, radius);
    } else if (is_shape_box(flags)) {
        return sdBoxOrthogonal(local_offset, extents);
    } else if (is_shape_cylinder(flags)) {
        return sdCappedCylinder(local_offset, extents.y, radius);
    } else {
        return 1. / 0.;
    }
}


float fn_op_sdist(float left, float right, int flags) {
    if (is_op_union(flags)) {
        return sdOpUnion(left, right);
    } else if (is_op_intersection(flags)) {
        return sdOpIntersection(left, right);
    } else if (is_op_subtraction(flags)) {
        return sdOpSubtraction(left, right);
    } else {
        return 1. / 0.;
    }
}


vec4 fn_op_sdist_vec4(vec4 left, vec4 right, int flags) {
    return vec4(
        fn_op_sdist(left.x, right.x, flags),
        fn_op_sdist(left.y, right.y, flags),
        fn_op_sdist(left.z, right.z, flags),
        fn_op_sdist(left.w, right.w, flags)
    );
}


float fn_intersect_angle(vec3 local_offset, float angle_radians, float sdf) {
    if (angle_radians >= 0.) {
        sdf = sdOpIntersection(sdf, sdAngle(local_offset.xz, angle_radians));
    }
    return sdf;
}


float fn_subtract_min_radius(vec3 local_offset, float min_radius, float sdist) {
    if (min_radius > -1.) {
        sdist = sdOpSubtraction(sdCircle(local_offset.xz, min_radius), sdist);
    }
    return sdist;
}


/// The signed distance from the border of the parameterized area shape.
float fn_base_sdist(AreaData area, vec3 local_offset) {
    float sdist = fn_shape_sdist(area.flags, local_offset, area.radius, area.extents);
    sdist = fn_intersect_angle(local_offset, radians(area.angle) * 0.5, sdist);
    sdist = fn_subtract_min_radius(local_offset, area.min_radius, sdist);
    return sdist;
}


/// The signed distance from the border of the progress shape.
/// Must be constrained by the area signed distance because it extends outside the bounds of the area shape.
/// It is unconstrained so that the threshold does not highlight all sides during progress.
float fn_fill_sdist(int area_flags, float radius, vec3 extents, vec3 local_offset, float base_sdist, float fill_progress) {
    float sdist = 1. / 0.;
    if (fill_progress < 0.) {
        return sdist;
    }
    bool is_inverted = is_fill_inverted(area_flags);
    if (is_inverted) {
        fill_progress = 1. - fill_progress;
    }
    if (is_fill_in_to_out(area_flags)) {
        sdist = fn_shape_sdist(
            area_flags,
            local_offset,
            radius * fill_progress,
            extents * fill_progress
        );
    } else if (is_fill_foward(area_flags)) {
        sdist = (-local_offset.z + extents.z) - (extents.z * fill_progress * 2.);
    }
    if (is_inverted) {
        sdist = -sdist;
    }
    // Constrain the progress distance outside the area shape by the distance from the area shape.
    if (base_sdist > 0.) {
        sdist = 1. / 0.;
    }
    return sdist;
}


float fn_border_noise(FamilyData family, TelegraphData telegraph, vec3 position, sampler2D noise_texture) {
    vec2 texture_pos_1 = vec2(position.x, position.z) * family.border_noise_1_frequency / telegraph.basis[1][1] + (TIME * family.border_noise_1_speed);
    float noise_1 = (texture(noise_texture, texture_pos_1).r * 2. - 1.) * family.border_noise_1_amplitude;
    vec2 texture_pos_2 = vec2(position.x, position.z) * family.border_noise_2_frequency / telegraph.basis[1][1] - (TIME * family.border_noise_2_speed);
    float noise_2 = (texture(noise_texture, texture_pos_2).r * 2. - 1.) * family.border_noise_2_amplitude;
    float noise = noise_1 + 0.25 * noise_2;
    noise = sign(noise) * max(0., abs(noise) - 0.125);
    return noise;
}


vec4 fn_pixel_neighbors_sdist(FamilyData family, TelegraphData telegraph, AreaData area, vec3 world_position, vec3 dfdx, vec3 dfdy, sampler2D noise_texture) {
    vec3 left_world_position = world_position - dfdx;
    vec3 left_telegraph_offset = fn_local_offset(telegraph.origin, telegraph.basis, left_world_position);
    vec3 left_area_offset = fn_local_offset(area.origin, area.basis, left_world_position);
    float left_sdist = fn_base_sdist(area, left_area_offset);
    vec3 right_world_position = world_position + dfdx;
    vec3 right_telegraph_offset = fn_local_offset(telegraph.origin, telegraph.basis, right_world_position);
    vec3 right_area_offset = fn_local_offset(area.origin, area.basis, right_world_position);
    float right_sdist = fn_base_sdist(area, right_area_offset);
    vec3 above_world_position = world_position + dfdy;
    vec3 above_telegraph_offset = fn_local_offset(telegraph.origin, telegraph.basis, above_world_position);
    vec3 above_area_offset = fn_local_offset(area.origin, area.basis, above_world_position);
    float above_sdist = fn_base_sdist(area, above_area_offset);
    vec3 below_world_position = world_position - dfdy;
    vec3 below_telegraph_offset = fn_local_offset(telegraph.origin, telegraph.basis, below_world_position);
    vec3 below_area_offset = fn_local_offset(area.origin, area.basis, below_world_position);
    float below_sdist = fn_base_sdist(area, below_area_offset);
    if (telegraph.has_border_noise) {
        left_sdist += fn_border_noise(family, telegraph, left_telegraph_offset, noise_texture);
        right_sdist += fn_border_noise(family, telegraph, right_telegraph_offset, noise_texture);
        above_sdist += fn_border_noise(family, telegraph, above_telegraph_offset, noise_texture);
        below_sdist += fn_border_noise(family, telegraph, below_telegraph_offset, noise_texture);
    }
    return vec4(left_sdist, right_sdist, above_sdist, below_sdist);
}


float fn_pattern(mat3 basis, vec3 position, float amplitude, float frequency, float speed, sampler2D pattern_texture) {
	vec2 texture_pos = vec2(position.x, position.z) * frequency / basis[1][1] + (TIME * speed);
	return texture(pattern_texture, texture_pos).r * amplitude;
}


/// Blend two colors with variable opacities.
vec4 fn_color_blend(vec4 foreground, vec4 background) {
    vec4 blended;
    // Find the combined alpha at overlaps. The transparency of the background is modulated by the transparency of the foreground.
    blended.a = foreground.a + background.a * (1. - foreground.a);
    if (blended.a < 0.0001) {
        return vec4(0.);
    }
    // Find the combined albedo at overlaps. Weight each albedo by its alpha and normalize the result by the blended alpha.
    blended.rgb = (foreground.rgb * foreground.a + background.rgb * background.a * (1. - foreground.a)) / blended.a;
    return blended;
}


/// base_sdist: SDF value of the fragment for telegraph base shape
/// fill_sdist: SDF value of the fragment for telegraph fill shape at current fill progress
/// fill_begin_at: SDF value of the fragment for telegraph fill shape at empty fill progress
/// fill_end_at: SDF value of the fragment for telegraph fill shape at full fill progress
vec4 fn_telegraph_decal_color(FamilyData family, TelegraphData telegraph, float base_sdist, float fill_sdist, float pulse_sdist) {
	vec4 color = vec4(0.);
    if (base_sdist > 0.) {
        return color;
    }
    if (fill_sdist < -family.fill_highlight_width) {
		// Inside fill shape
        float mix_ratio;
		mix_ratio = family.fill_highlight_trail + fill_sdist;
		mix_ratio /= family.fill_highlight_trail;
		mix_ratio = clamp(mix_ratio, 0., 1.);
        color = mix(family.fill_color, family.fill_highlight_color, mix_ratio);
	} else if (fill_sdist < 0.) {
		// Inside fill border width
        color = family.fill_highlight_color;
    } else {
		// Outline fill shape inside base shape
        color = family.base_color;
    }
    return color;
}


float fn_telegraph_decal_pattern(FamilyData family, TelegraphData telegraph, vec3 local_offset, float base_sdist, sampler2D noise_texture, sampler2D pattern_1_texture) {
    float alpha_multiplier = telegraph.alpha_multiplier;
    if (base_sdist > 0.) {
        return alpha_multiplier;
    }
    if (telegraph.has_pattern_noise) {
        float pattern_noise = fn_pattern(
			telegraph.basis,
			local_offset,
			1.,
			family.pattern_noise_frequency,
			-family.pattern_noise_speed,
			noise_texture
			);
		float denormalized_noise = pattern_noise * 2. - 1.;
        alpha_multiplier *= 1. + denormalized_noise * family.pattern_noise_amplitude;
    }
    if (telegraph.has_pattern_1) {
		float pattern_1_angle = 45.;
        mat3 rotation_matrix = mat3(
            vec3(cos(radians(pattern_1_angle)), 0., sin(radians(pattern_1_angle))),
            vec3(0., 1., 0.),
            vec3(-sin(radians(pattern_1_angle)), 0., cos(radians(pattern_1_angle)))
        );
        float pattern_1 = fn_pattern(
			telegraph.basis,
			local_offset * rotation_matrix + vec3(TIME * family.pattern_1_speed, 0., 3. * -TIME * family.pattern_1_speed),
			family.pattern_1_amplitude,
			family.pattern_1_frequency,
			family.pattern_1_speed,
			pattern_1_texture
			);
        alpha_multiplier *= 1. + pattern_1;
    }
    return alpha_multiplier;
}


vec4 fn_outline_color(float sdist, vec4 pixel_neighbors_sdist, vec4 base_outline_color, float width, int flags) {
    if (is_outline_pixel(flags)) {
        float sign_count = sign(pixel_neighbors_sdist.x) + sign(pixel_neighbors_sdist.y) + sign(pixel_neighbors_sdist.z) + sign(pixel_neighbors_sdist.w);
        float is_visible = step(abs(sign_count), 3.5);
        return is_visible * base_outline_color;
    } else if (is_outline_spatial(flags)) {
        return step(0., sdist) * step(sdist, width) * base_outline_color;
    }
}


vec4 fn_decal_color(
    sampler2D from,
    vec3 world_normal,
    vec3 world_position,
    vec3 dfdx,
    vec3 dfdy,
    sampler2D noise_texture,
    sampler2D pattern_1_texture)
{
    SceneData scene;
    FamilyData family;
    TelegraphData telegraph;
    AreaData area;
    OutlineData outline;

    read_scene_data(scene, from);

    if (scene.area_count == 0)
        return vec4(0.);

    int[OUTLINE_LIMIT] outline_family_idx;
    float[OUTLINE_LIMIT] outline_base_sdist;
    float[OUTLINE_LIMIT] outline_fill_sdist;
    vec4[OUTLINE_LIMIT] outline_pixel_neighbors_sdist;

    for (int i = 0; i < OUTLINE_LIMIT; i++) {
        outline_family_idx[i] = 0;
        outline_base_sdist[i] = 1. / 0.;
        outline_fill_sdist[i] = 1. / 0.;
        outline_pixel_neighbors_sdist[i] = vec4(1. / 0.);
    }

    vec4 color = vec4(0.);

    int telegraph_idx = 0;
    int area_idx = 0;

    while (telegraph_idx < scene.telegraph_count) {
        read_telegraph_data(telegraph, from, telegraph_idx);
		telegraph_idx += 1;
        read_family_data(family, from, telegraph.family_idx);

        float telegraph_base_sdist = 1. / 0.;
        float telegraph_fill_sdist = 1. / 0.;
        float telegraph_pulse_sdist = 1. / 0.;
        vec4 telegraph_pixel_neighbors_sdist = vec4(1. / 0.);
        vec3 telegraph_local_offset = fn_local_offset(
            telegraph.origin,
            telegraph.basis,
            world_position);

        while (area_idx < telegraph.last_area_idx && area_idx < scene.area_count) {
            read_area_data(area, from, area_idx);
			area_idx += 1;
			if (fn_is_normal_clipped(telegraph.basis, world_normal, family.normal_clip_angle_deg)) { continue; }
            vec3 area_local_offset = fn_local_offset(area.origin, area.basis, world_position);
            float area_base_sdist = fn_base_sdist(area, area_local_offset);
            if (telegraph.has_border_noise) {
                area_base_sdist += fn_border_noise(family, telegraph, telegraph_local_offset, noise_texture);
            }
            float area_fill_sdist = fn_fill_sdist(area.flags, area.radius, area.extents, area_local_offset, area_base_sdist, area.fill_progress);
            telegraph_base_sdist = fn_op_sdist(area_base_sdist, telegraph_base_sdist, area.flags);
            telegraph_fill_sdist = sdOpUnion(area_fill_sdist, telegraph_fill_sdist);
            if (is_outline_pixel(family.flags)) {
                vec4 area_pixel_neighbors_sdist = fn_pixel_neighbors_sdist(family, telegraph, area, world_position, dfdx, dfdy, noise_texture);
                telegraph_pixel_neighbors_sdist = fn_op_sdist_vec4(area_pixel_neighbors_sdist, telegraph_pixel_neighbors_sdist, area.flags);
            }
        }
        vec4 telegraph_color = fn_telegraph_decal_color(
            family, telegraph,
            telegraph_base_sdist,
            telegraph_fill_sdist,
            telegraph_pulse_sdist);
		if (telegraph_color.a == 0.) { continue; }
        telegraph_color.a *= fn_telegraph_decal_pattern(
            family, telegraph,
            telegraph_local_offset,
            telegraph_base_sdist,
            noise_texture,
            pattern_1_texture);
        color = fn_color_blend(telegraph_color, color);
        int family_outline_idx = family.outline_idx;
        outline_family_idx[family_outline_idx] = telegraph.family_idx;
        if (
            is_outline_individual(family.flags)
            && (telegraph.fill_progress < 1. || telegraph.alpha_multiplier >= 1.)
        ) {
            // Draw individual outlines
            vec4 outline_color = fn_outline_color(
                telegraph_base_sdist,
                telegraph_pixel_neighbors_sdist,
                family.base_outline_color,
                family.base_outline_width,
                family.flags);
            color = fn_color_blend(outline_color, color);
        } else if (
            is_outline_grouped(family.flags)
            && family_outline_idx < OUTLINE_LIMIT
            && (telegraph.fill_progress < 1. || telegraph.alpha_multiplier >= 1.)
        ) {
            outline_base_sdist[family_outline_idx] = sdOpUnion(outline_base_sdist[family_outline_idx], telegraph_base_sdist);
            if (is_outline_pixel(family.flags)) {
                outline_pixel_neighbors_sdist[family_outline_idx] = fn_op_sdist_vec4(
                    telegraph_pixel_neighbors_sdist,
                    outline_pixel_neighbors_sdist[family_outline_idx],
                    FLAG_A_OP_UNION);
            }
        }
    }
	//return vec4(-outline_base_sdist[0], -outline_base_sdist[1], -outline_base_sdist[2], 1.);
    int outline_idx = 0;
    while (outline_idx <= scene.outline_count && outline_idx < OUTLINE_LIMIT) {
        // Draw grouped outlines
        read_outline_data(outline, from, outline_family_idx[outline_idx]);
        vec4 outline_color = fn_outline_color(
            outline_base_sdist[outline_idx],
            outline_pixel_neighbors_sdist[outline_idx],
            outline.base_outline_color,
            outline.base_outline_width,
            outline.flags);
        outline_idx += 1;
		color = fn_color_blend(outline_color, color);
    }

    return color;
}
