// ================================================================
// SDF Metaballs
// ================================================================
// 来源   https://godotshaders.com/shader/sdf-metaballs/
// 作者   vandroid  https://godotshaders.com/author/vandroid/
// 发布   2026-08-12
// 类型   spatial
// 许可   cc0
// Godot  4.3 / 4.4 / 4.5 / 4.6
// 标签   Blob, metaball, metaballs, ray marching, raymarching, SDF
// ================================================================
// 介绍
// This is a metaballs shader that uses ray marching to perfectly blend one ball into another.
//
// Set up :
//
// 1. Create a mesh instance and assign box mesh and set its size large enough (100,100,100 etc).
//
// 2. Attach this material to the mesh’s first material slot.
//
// 3. Pass the uniforms (ball_positions, ball_colors, and active_balls) from a script.
//
// This is the script im using for passing uniforms (attached to the mesh) :
//
// @tool 
// extends MeshInstance3D 
//  
// # if you want to see changes in editor, keep this true 
// @export var run_in_editor: bool = true 
// @export var mat : ShaderMaterial 
// @export var max_active : int = 20 
//  
// func _ready() -> void: 
//  mat = get_active_material(0) as ShaderMaterial 
//  
// func _process(delta): 
//  if Engine.is_editor_hint() and not run_in_editor: 
//  return 
//  
//  var positions = [] 
//  var colors = [] 
//  var active_count = 0 
//  for child in get_children(): 
//  if child is Metaball: 
//  var radius = child.radius 
//  positions.append(Vector4(child.global_position.x,child.global_position.y,child.global_position.z, radius)) 
//  
//  colors.append(child.color) 
//  active_count += 1 
//  
//  if child is MeshInstance3D and child.visible: 
//  child.visible = false 
//  
//  if active_count >= max_active: 
//  break 
//  
//  if active_count > 0: 
//  mat.set_shader_parameter("active_balls", active_count) 
//  mat.set_shader_parameter("ball_positions", positions) 
//  mat.set_shader_parameter("ball_colors", colors) 
//  
//
// you can pass the uniforms by adding nodes as children of the mesh or a group :
//
// extends Node3D 
//  
// class_name Metaball 
//  
// @export var color : Color 
// @export var radius : float
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type spatial;
render_mode unshaded, cull_disabled; //we handle lighting manually for performance

uniform int max_steps = 20;  //max number of steps in ray marching loop, reduce this to increase performance but reduce accuracy
uniform float max_dist = 20.0;    // max ray distance
uniform float surf_dist = 0.01;   // precision of the surface hit

uniform vec4 ball_positions[20]; //array to hold ball positions, vec4.w is radius of the metaball
uniform vec4 ball_colors[20];  // array to hold ball colors
uniform int active_balls = 0;     // how many balls are currently active
uniform float smoothness = 0.8;   // smoothness of the connection

float smin(float d1, float d2, float k) {
    float h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
    return mix(d2, d1, h) - k * h * (1.0 - h);
}

vec3 smin_col(float d1, float d2, vec3 c1, vec3 c2, float k) {
    float h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
    return mix(c2, c1, h);
}

vec4 get_scene(vec3 p) {
    float d = max_dist;
    vec3 col = vec3(0.0);

    for(int i = 0; i < active_balls; i++) {
        float sphere_dist = length(p - ball_positions[i].xyz) - ball_positions[i].w;
        vec3 sphere_col = ball_colors[i].rgb;

        if (i == 0) {
            d = sphere_dist;
            col = sphere_col;
        } else {
            col = smin_col(d, sphere_dist, col, sphere_col, smoothness);
            d = smin(d, sphere_dist, smoothness);
        }
    }
    return vec4(d, col);
}

vec3 get_normal(vec3 p) {
    float d = get_scene(p).x;
    vec2 e = vec2(0.01, 0);

    vec3 n = d - vec3(
        get_scene(p - e.xyy).x,
        get_scene(p - e.yxy).x,
        get_scene(p - e.yyx).x
    );

    return normalize(n);
}

void fragment() {

    vec3 ro = (inverse(VIEW_MATRIX) * vec4(0.0, 0.0, 0.0, 1.0)).xyz; //ray origin
    vec3 rd = normalize((inverse(VIEW_MATRIX) * vec4(VERTEX, 1.0)).xyz - ro); //ray direction

    // raymarching loop
    float d = 0.0; // distance traveled
    bool hit = false;
    vec3 p;
	vec4 result;
    for(int i = 0; i < max_steps; i++) {
        vec3 p = ro + rd * d;
        result = get_scene(p); //get distance and color
        float dS = result.x;
        d += dS;
        if(d > max_dist || dS < surf_dist) break;
    }

    if(d < max_dist) {
        vec3 p = ro + rd * d;
        vec3 n = get_normal(p);

        // rim lighting
        float rim = 1.0 - max(dot(n, -rd), 0.0);
        rim = pow(rim, 3.0);

        ALBEDO = result.yzw + (vec3(1.0) * rim * 0.5);
    } else {
        discard; // draw nothing if missed
    }
}
