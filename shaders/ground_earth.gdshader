shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;


varying vec3 wp;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i), b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0)), d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 p = wp.xz;
	float n1 = vnoise(p * 1.35 + vec2(5.1, -2.3));
	float n2 = vnoise(p * 3.80 + vec2(-3.7, 8.4));
	float n3 = vnoise(p * 7.10 + vec2(-4.6, 1.7));
	float n4 = vnoise(p * 11.5 + vec2(7.1, -3.9));
	vec3 c = mix(vec3(0.085, 0.052, 0.030), vec3(0.190, 0.140, 0.085),
		n1 * 0.58 + n2 * 0.42);
	// compacted earth grain, then two sizes of embedded stones
	c *= 0.74 + 0.38 * n2 + 0.14 * n3;
	float peb = smoothstep(0.865, 0.935, n2 * 0.45 + n3 * 0.55);
	c = mix(c, vec3(0.185, 0.152, 0.112), peb * 0.62);
	float peb2 = smoothstep(0.925, 0.980, n3 * 0.55 + n4 * 0.45);
	c = mix(c, vec3(0.275, 0.240, 0.195), peb2 * 0.52);
	float chips = smoothstep(0.955, 0.992, n4);
	c = mix(c, vec3(0.335, 0.300, 0.250), chips * 0.38);
	c *= 0.86 + 0.24 * n1;
	ALBEDO = c;
	ROUGHNESS = 0.96;
	SPECULAR = 0.02;
}
