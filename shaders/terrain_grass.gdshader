shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Dedicated turf surface for mat_grass.  The shared terrain shader's
// dry/meadow/soil passes were fighting each other on the flat village shelf and
// turning the whole lawn into tan earth.  This is the same grass tile and path
// lane, with only broad green variation and a dark packed-earth lane.
uniform sampler2D base_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D base_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D base_rough : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D path_albedo : source_color, filter_linear, repeat_disable;
uniform sampler2D path_mask : filter_linear, repeat_disable;
uniform vec4 path_rect = vec4(-82.0, -82.0, 164.0, 164.0);
uniform vec2 base_uv = vec2(2.667, 2.667);
uniform vec4 base_tint : source_color = vec4(0.74, 0.82, 0.66, 1.0);
uniform float path_strength = 1.0;

varying vec3 v_world;
varying vec3 v_wn;

float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vn(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1,0)), f.x),
			mix(h21(i + vec2(0,1)), h21(i + vec2(1,1)), f.x), f.y);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 uv = v_world.xz * base_uv * 0.5;
	vec3 grass = texture(base_albedo, uv).rgb * base_tint.rgb;
	// Broad 6-20 m green/yellow modulation, no sub-metre dirt.
	float a = vn(v_world.xz * 0.055 + vec2(13.0, -7.0));
	float b = vn(v_world.xz * 0.15 + vec2(-4.0, 9.0));
	float c = vn(v_world.xz * 0.38 + vec2(5.0, 2.0));
	float tone = a * 0.55 + b * 0.30 + c * 0.15;
	grass *= mix(vec3(0.78, 0.90, 0.74), vec3(1.03, 1.01, 0.82), smoothstep(0.35, 0.72, tone));
	grass *= 0.72 + 0.10 * c;
	// Keep it turf, not a flat painted green.
	vec3 lum = vec3(dot(grass, vec3(0.2126, 0.7152, 0.0722)));
	grass = mix(lum, grass, 0.64);

	// Damp packed-earth lane.  The baked lane albedo is a light grey pickup;
	// tint it down to soil before it hits the tonemap.
	vec2 puv = (v_world.xz - path_rect.xy) / path_rect.zw;
	vec4 pa = texture(path_albedo, puv);
	vec3 pm = texture(path_mask, puv).rgb;
	float cov = smoothstep(0.15, 0.40, pa.a
		+ (vn(v_world.xz * 4.1 + vec2(3.7, -1.9)) - 0.5) * 0.20);
	vec3 dirt = pa.rgb * vec3(0.30, 0.225, 0.150);
	float lat = (pm.g - 0.5) * 2.0;
	float groove = 1.0 - smoothstep(0.0, 0.13, abs(abs(lat) - 0.40));
	dirt = mix(dirt, vec3(0.050, 0.031, 0.019), groove * 0.85);
	dirt *= 0.92 + 0.14 * vn(v_world.xz * 0.55 + vec2(9.0, -4.0));
	dirt *= 1.0 - 0.18 * (1.0 - smoothstep(15.0, 17.5, v_world.z));
	float path = cov * path_strength;
	ALBEDO = mix(grass, dirt, path);
	ROUGHNESS = mix(0.97, 0.99, path);
	SPECULAR = mix(0.04, 0.02, path);
	NORMAL_MAP = texture(base_normal, uv).rgb;
	NORMAL_MAP_DEPTH = 0.42 * (1.0 - path);
	EMISSION = grass * 0.006;
}
