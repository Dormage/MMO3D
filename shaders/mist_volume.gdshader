shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled, fog_disabled;

// Soft ground mist.  The source asset is a cluster of puffy icospheres; this
// material keeps that soft silhouette but gives it height falloff, a view-edge
// fade, slow drift and a near-camera guard so it cannot wash the RPG screen.
uniform vec4 mist_color : source_color = vec4(0.55, 0.59, 0.69, 1.0);
uniform float opacity = 0.17;
uniform float near_fade_start = 2.0;
uniform float near_fade_end = 6.0;
uniform float far_fade_start = 90.0;
uniform float far_fade_end = 190.0;

instance uniform float mist_base_y = 0.0;
instance uniform float mist_height = 4.0;
instance uniform float mist_seed = 0.0;

varying vec3 world_pos;
varying vec3 world_normal;

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = fract(sin(dot(i, vec2(127.1, 311.7)) + mist_seed) * 43758.5453);
	float b = fract(sin(dot(i + vec2(1.0, 0.0), vec2(127.1, 311.7)) + mist_seed) * 43758.5453);
	float c = fract(sin(dot(i + vec2(0.0, 1.0), vec2(127.1, 311.7)) + mist_seed) * 43758.5453);
	float d = fract(sin(dot(i + vec2(1.0, 1.0), vec2(127.1, 311.7)) + mist_seed) * 43758.5453);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	float t = TIME;
	// Slow horizontal drift plus a small upward breathing motion.  The puffs
	// move as a body, not as billboards, so no card edge can appear.
	VERTEX.x += sin(t * 0.055 + mist_seed * 6.2831853) * 0.42;
	VERTEX.z += cos(t * 0.043 + mist_seed * 3.1415926) * 0.34;
	VERTEX.y += sin(t * 0.090 + mist_seed * 9.0) * 0.10;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float h = clamp((world_pos.y - mist_base_y) / max(mist_height, 0.01), 0.0, 1.0);
	// Density pools at the base: full at the floor, gone by the top of the
	// volume.  No constant slab.
	float low = 1.0 - smoothstep(0.0, 0.92, h);
	float body = 0.62 + 0.38 * vnoise(world_pos.xz * 0.34 + vec2(TIME * 0.018, mist_seed * 7.0));
	// Soft silhouette on every side: fade when the normal turns away from view.
	vec3 V = normalize(CAMERA_POSITION_WORLD - world_pos);
	float facing = abs(dot(normalize(world_normal), V));
	float soft = smoothstep(0.04, 0.62, facing);
	float dist = length(CAMERA_POSITION_WORLD - world_pos);
	float near = smoothstep(near_fade_start, near_fade_end, dist);
	float far = 1.0 - smoothstep(far_fade_start, far_fade_end, dist);
	float a = opacity * low * body * soft * near * far;
	a *= 0.90 + 0.10 * vnoise(world_pos.xz * 0.9 + vec2(0.0, TIME * 0.03));
	ALBEDO = mist_color.rgb;
	ALPHA = clamp(a, 0.0, 0.22);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
