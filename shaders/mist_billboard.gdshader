shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled, fog_disabled;

// Soft mist puff.  A camera-facing quad whose alpha is radial and noisy: it
// reaches zero at every edge, so no card rim can ever read in frame.
uniform vec4 mist_color : source_color = vec4(0.50, 0.54, 0.62, 1.0);
uniform float opacity = 0.11;
uniform float near_fade_start = 2.4;
uniform float near_fade_end = 7.5;
uniform float far_fade_start = 100.0;
uniform float far_fade_end = 220.0;

instance uniform float mist_base_y = 0.0;
instance uniform float mist_height = 4.0;
instance uniform float mist_seed = 0.0;
instance uniform float mist_opacity = 1.0;

varying vec3 world_pos;

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
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	float sz = length(MODEL_MATRIX[2].xyz);
	vec4 c = MODEL_MATRIX[3];
	c.x += sin(t * 0.050 + mist_seed * 6.2831853) * 0.55;
	c.z += cos(t * 0.041 + mist_seed * 3.1415926) * 0.45;
	c.y += sin(t * 0.085 + mist_seed * 9.0) * 0.16;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(INV_VIEW_MATRIX[0].xyz * sx, 0.0),
		vec4(INV_VIEW_MATRIX[1].xyz * sy, 0.0),
		vec4(INV_VIEW_MATRIX[2].xyz * sz, 0.0),
		c);
	world_pos = c.xyz;
}

void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float r = length(q);
	float radial = smoothstep(1.0, 0.12, r);
	float h = clamp((world_pos.y - mist_base_y) / max(mist_height, 0.01), 0.0, 1.0);
	float low = 1.0 - smoothstep(0.0, 0.95, h);
	float n = vnoise(world_pos.xz * 0.20 + vec2(TIME * 0.020, mist_seed * 5.0));
	n = 0.55 * n + 0.45 * vnoise(world_pos.xz * 0.55 - vec2(TIME * 0.013, 0.0));
	float body = 0.55 + 0.55 * n;
	float dist = length(CAMERA_POSITION_WORLD - world_pos);
	float near = smoothstep(near_fade_start, near_fade_end, dist);
	float far = 1.0 - smoothstep(far_fade_start, far_fade_end, dist);
	float a = opacity * radial * low * body * near * far;
	ALBEDO = mist_color.rgb;
	ALPHA = clamp(a * mist_opacity, 0.0, 0.13);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
