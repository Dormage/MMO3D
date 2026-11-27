shader_type spatial;
// Unlit soil collar with the same dirt_soil albedo the terrain edge wear uses.
// Unlit avoids the fixed-sun normal problem that turned this black, while the
// real texture avoids a procedural pattern that read as cobblestones.
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tint = vec3(0.72, 0.65, 0.55);
// The soil caps over the terrain apertures are the village lane.  Reuse the
// baked compacted-earth map so the cap shows ruts, stones and a ragged edge
// instead of a flat unlit beige strip.
uniform sampler2D path_albedo : source_color, filter_linear, repeat_disable;
uniform vec4 path_rect = vec4(-82.0, -82.0, 164.0, 164.0);
varying vec3 v_w;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}


void vertex() {
	v_w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_w.xz;
	float n1 = vnoise(p * 1.35 + vec2(5.1, -2.3));
	float n2 = vnoise(p * 3.80 + vec2(-3.7, 8.4));
	float n3 = vnoise(p * 7.10 + vec2(-4.6, 1.7));
	vec3 c = mix(vec3(0.095, 0.060, 0.036), vec3(0.185, 0.135, 0.082),
		n1 * 0.62 + n2 * 0.38);
	float peb = smoothstep(0.925, 0.978, n2 * 0.55 + n3 * 0.45);
	c = mix(c, vec3(0.195, 0.160, 0.120), peb * 0.55);
	float peb2 = smoothstep(0.958, 0.993, n3);
	c = mix(c, vec3(0.270, 0.235, 0.190), peb2 * 0.45);
	c *= 0.88 + 0.24 * n1;
	// same compacted earth as the bank, gently lit by depth
	float depth = clamp((v_w.y + 0.05) / 0.5, 0.0, 1.0);
	c *= tint * mix(0.78, 1.05, depth);
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
