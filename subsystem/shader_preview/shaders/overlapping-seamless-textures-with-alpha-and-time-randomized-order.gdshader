// ================================================================
// Overlapping Seamless Textures with Alpha and Time-Randomized Order
// ================================================================
// 来源   https://godotshaders.com/shader/overlapping-seamless-textures-with-alpha-and-time-randomized-order/
// 作者   stariluz  https://godotshaders.com/author/stariluz/
// 发布   2026-03-16
// 类型   canvas_item
// 许可   cc0
// Godot  4.6
// 标签   linear transition, mix textures, overlap, overlapping textures, patterns, textures, transitions
// ================================================================
// 介绍
// I needed to create a shader that does as follow:
//
// – Uses a background seamless texture, with a velocity and direction for an offset movement.
//
// – Mixes 4 seamless textures with alpha transparency and applies a random offset movement from an array of velocities and directions.
//
// – Every visible_duration seconds, the order in which the textures are displayed changes. A linear transition of transition_duration seconds will be displayed to show the new order of the textures.
//
// – You can control the overall movement velocity and the time scale of the patterns variables using the velocity_scale and time_scale uniforms.
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;
render_mode blend_mix;

uniform float time_scale:hint_range(0.0, 2.0, 0.1)=0.5;
uniform float velocity_scale:hint_range(0.1, 2.0, 0.1)=0.1;

group_uniforms Patterns;
uniform int amount:hint_range(0, 5, 1)=5;
uniform sampler2D patterns[5] : repeat_enable;
uniform vec2 directions[5];
uniform float velocities[5];

group_uniforms Animation;
uniform float visible_duration:hint_range(1.0, 30.0, 0.5)=15.0;
uniform float transition_duration:hint_range(0.0, 5.0, 0.5)=2.0;

float offset(float x, float dt, float complete_cycle){
	return floor((x-dt)/complete_cycle)*complete_cycle;
}
float time(float x, float spike_cycle){
	return x/(2.0*spike_cycle);
}
float local_time(float x, float dt,float spike_cycle){
	float scaledStartTime = -(transition_duration+visible_duration/2.0)*time_scale;
	return time(x-dt-scaledStartTime,spike_cycle);
}
float initial_delta_time(int position){
	return (float(position)*(visible_duration + transition_duration) - transition_duration)*time_scale;
}
float spike_with_hidden_duration(float x, float dt, float spike_cycle , float complete_cycle){
	float h=1.0 + visible_duration/(2.0*transition_duration);
	float lt = local_time(x-offset(x,dt,complete_cycle),dt,spike_cycle);

	return 2.0*h*(abs(2.0*(lt - floor(lt + 0.5))) - 0.5);
}

float intercalated_time_function(float x, float dt, float cycle){
	float spike_cycle=(2.0*transition_duration + visible_duration)*time_scale;
	float spike=spike_with_hidden_duration(x, dt, spike_cycle, cycle);

	return mod(x-dt,cycle)<=spike_cycle
		? spike > 1.0
			? 1.0
			: spike
		: 0.0;
}
vec4 intercalate_patterns(vec4 patternA, vec4 patternB, float cycle){
	float x=TIME;
	vec4 acc=vec4(0.0);

	for (int i = 0; i < 2; i++) {
		float dt = initial_delta_time(i);

		float f=intercalated_time_function(x,dt,cycle);
		vec4 pattern=f*(
			i==0
			? patternA
			: patternB
		);

	    acc += pattern;
	}

	return acc;
}

float hash(float n){
    return fract(sin(n) * 43758.5453123);
}

vec4 pattern_movement(vec2 direction, float velocity, sampler2D pattern, vec2 uv){
	direction=normalize(direction);
	vec2 movement=TIME*velocity_scale*velocity*direction;
	vec2 newUv=uv-movement;
	vec4 result=texture(pattern,newUv);
	return result;
}
/* Return an rando index based on the time iteration and position of the current mixed pattern. The first pattern is the background so it
 * never returns the first index.
 *
 * position: The posittion of the current pattern. Given a hide_duration equal to visible_duration, there are just 2 positions: 0 and 1.
 * unique_multiplier: An unique value that multiplies the iteration index that i based on the position. This unique multiplier asegurates
 * that 2 patterns at the same time does not have the same mix of patterns.
 */
int random_index(int position, float iteration, float unique_multiplier){
	return 1 + int(floor(hash(float(position) + float(iteration) * unique_multiplier) * float(amount - 1)));
}

/* x: time. Named this way because the simulations in geogebra of the function of time is based on the axis x.
 * position: The posittion of the current pattern. Given a hide_duration equal to visible_duration, there are just 2 positions: 0 and 1.
 * unique_multiplier: An unique value that multiplies the iteration index that i based on the position. This unique multiplier asegurates
 * that 2 patterns at the same time does not have the same mix of patterns.
 */
vec4 generate_mixed_pattern(float x, vec2 uv, float cycle, int position, float unique_multiplier){
	float dt = initial_delta_time(position);
	float iteration = floor((x-dt) / cycle);

	vec4 mixed = pattern_movement(directions[0], velocities[0], patterns[0], uv);

	for(int i=1; i<amount;i++){
		int r1 = random_index(i,iteration,unique_multiplier);
		int r2 = random_index(i,iteration,unique_multiplier*2.0);
		int r3 = random_index(i,iteration,unique_multiplier*3.0);
		vec4 anim=pattern_movement(directions[r1], velocities[r2], patterns[r3], uv);
		//vec4 anim = pattern_movement(directions[i], velocities[i], patterns[i], uv);
		mixed = mix(mixed, anim, anim.a);
	}
	return mixed;
}

vec4 shader(float x, vec2 uv){
	float hide_duration = visible_duration;
	float cycle = (2.0*transition_duration + visible_duration + hide_duration)*time_scale;

	vec4 mixedA=generate_mixed_pattern(x, uv, cycle, 0, 10.0);
	vec4 mixedB=generate_mixed_pattern(x, uv, cycle, 1, 20.0);

	return intercalate_patterns(mixedA,mixedB,cycle);
}


void fragment() {
	COLOR=shader(TIME, UV);
}
