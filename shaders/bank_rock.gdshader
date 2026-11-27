shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

// C's bank-rock props have position/normal only (no UVs).  This triplanar
// basalt material is shared by all 75 placements, so they read as stone.
uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_rough : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float rock_tile = 0.75;
uniform vec3 rock_tone = vec3(1.0);

varying vec3 v_world;
varying vec3 v_wn;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1, 0)), u.x),
		mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), u.x), u.y);
}

vec3 tri_sample(sampler2D tex, vec3 p, vec3 w, float s) {
	return texture(tex, p.zy * s).rgb * w.x
		+ texture(tex, p.xz * s).rgb * w.y
		+ texture(tex, p.xy * s).rgb * w.z;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 w = abs(normalize(v_wn));
	w = w * w * w * w;
	w /= max(w.x + w.y + w.z, 1e-5);
	vec3 tex = tri_sample(rock_albedo, v_world, w, rock_tile);
	// Large irregular slabs, not a pale grey polygon net.  The imported rock
	// texture's crack lines remain only as a faint grain, while a slow
	// world-space field provides the real slab-to-slab variation.
	float slab = vnoise(v_world.xz * 1.25 + v_world.y * 0.23);
	vec3 c = mix(vec3(0.055, 0.048, 0.041),
		vec3(0.150, 0.132, 0.112), smoothstep(0.32, 0.72, slab));
	c *= 0.86 + 0.24 * dot(tex, vec3(0.333));
	c *= 0.86 + 0.28 * vnoise(v_world.xz * 4.7 + vec2(3.1, -2.2));
	c *= rock_tone;
	ALBEDO = c;
	EMISSION = vec3(0.0);
	ROUGHNESS = 0.96;
	METALLIC = 0.0;
	SPECULAR = 0.03;
}
