shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

varying vec3 lpos;

float hash11(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

void vertex() {
	lpos = VERTEX;
}

void fragment() {
	float seed = hash11(dot(floor(MODEL_MATRIX[3].xz * 0.37), vec2(12.9, 78.2)));
	vec3 clay = mix(vec3(0.150, 0.064, 0.032),
		vec3(0.235, 0.105, 0.052), seed);
	float row = fract(lpos.z / 0.30);
	float course = 1.0 - smoothstep(0.02, 0.14, row);
	float joint = 1.0 - smoothstep(0.02, 0.10, abs(fract(lpos.x / 0.42) - 0.5));
	float ridge = 1.0 - smoothstep(0.0, 0.10, abs(lpos.x));
	// keep the very edge a little darker as an eave lip
	float eave = 1.0 - smoothstep(0.40, 0.50, max(abs(lpos.x), abs(lpos.z)));
	vec3 col = clay;
	col *= 0.90 + 0.20 * hash11(seed * 91.0 + floor(lpos.x * 3.0) * 7.0 + floor(lpos.z * 3.0) * 13.0);
	col *= 1.0 - 0.24 * course;
	col *= 1.0 - 0.10 * joint;
	col = mix(col, vec3(0.105, 0.055, 0.032), ridge * 0.65);
	col *= 1.0 - 0.20 * eave;
	ALBEDO = max(col, vec3(0.10, 0.05, 0.03));
}
