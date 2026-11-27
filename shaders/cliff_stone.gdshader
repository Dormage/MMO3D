shader_type spatial;
render_mode unshaded, cull_disabled;

// Per-island overlay for the baked mat_stone cliff surface.  The GLB texture
// carries the original columnar mineral grain; this shader keeps that texture
// and only adds island-seeded rhythm on top, so the dramatic layering survives.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 island_centers[24];
uniform int island_count = 0;
uniform float detail = 1.0;
uniform float debug = 0.0;
uniform float uv_scale = 0.09;   // 1 / 11 m tile, soft at inspection range

varying vec3 world_pos;
varying vec3 world_normal;
varying vec2 uv;

float ihash(float x) {
	return fract(sin(x * 12.9898 + 4.1414) * 43758.5453);
}

float vn2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = ihash(i.x + i.y * 57.0);
	float b = ihash(i.x + 1.0 + i.y * 57.0);
	float c = ihash(i.x + (i.y + 1.0) * 57.0);
	float d = ihash(i.x + 1.0 + (i.y + 1.0) * 57.0);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

int nearest_island(vec2 xz) {
	int best = 0;
	float bd = 1e20;
	for (int i = 0; i < 24; i++) {
		if (i >= island_count) break;
		vec2 d = xz - island_centers[i].xy;
		float q = dot(d, d);
		if (q < bd) { bd = q; best = i; }
	}
	return best;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	uv = UV;
}

void fragment() {
	int isl = nearest_island(world_pos.xz);
	float h0 = ihash(float(isl) + 0.37);
	float h1 = ihash(float(isl) * 3.71 + 17.2);
	float h2 = ihash(float(isl) * 8.13 + 41.7);
	float type = floor(ihash(float(isl) * 5.37 + 9.1) * 3.0);
	float ts = 1.0 - step(0.5, abs(type));
	float tc = step(0.5, type) * (1.0 - step(1.5, type));
	float tb = step(1.5, type);

	// The baked mesh UV spans 0..1 across the whole terrain, so the columnar
	// texture was stretched into a few huge vertical bands down every cliff.
	// Sample in world space at a fixed metre tile: XZ on top, XY/YZ on walls.
	vec3 an = abs(normalize(world_normal));
	vec2 cuv = an.y > 0.62
		? world_pos.xz * uv_scale
		: vec2(world_pos.x + world_pos.z, world_pos.y) * uv_scale;
	// Break the constant vertical period: warp the sample by up to ~4 m at a
	// low frequency, plus a smaller metre-scale irregularity.
	vec2 warp = vec2(vn2(world_pos.xz * 0.026 + vec2(h0 * 7.0)),
		vn2(world_pos.xz * 0.031 + vec2(4.7, h1 * 5.0))) - 0.5;
	cuv += warp * 0.72;
	vec3 base = textureLod(albedo_tex, cuv, 2.0).rgb * 1.04;
	// The slate atlas is high-contrast grey.  Compress it toward a neutral
	// grey-brown so vertical cleavage is bedding, not cream flutes.
	float blum = dot(base, vec3(0.299, 0.587, 0.114));
	base = mix(vec3(blum), base, 0.30);
	base = mix(base, vec3(0.215, 0.195, 0.165), 0.16);
	base *= 0.94;
	// Bed height: different period per island.  Smooth islands get broad soft
	// beds, columnar islands thin beds plus strong vertical joints, blocky
	// islands a quarried course with one orthogonal joint set.
	float bed_period = mix(0.55, 1.65, h0) * mix(1.25, 0.82, tc);
	float y = world_pos.y + (sin(world_pos.x * 0.23 + world_pos.z * 0.19
		+ h1 * 6.2831853) * 0.22);
	float bed_id = floor(y / bed_period);
	float bed_f = fract(y / bed_period);
	float bed_hash = ihash(bed_id * 1.73 + float(isl) * 13.1);
	float bed_tone = mix(0.56, 1.34, bed_hash);
	bed_tone *= mix(1.0, 0.72, smoothstep(0.92, 1.0, bed_f));
	bed_tone = mix(1.0, bed_tone, detail * 0.16);
	bed_tone = mix(bed_tone, 1.0, 0.20);
	base *= bed_tone;

	float vangle = h2 * 6.2831853;
	vec2 vdir = vec2(cos(vangle), sin(vangle));
	float vperiod = mix(0.42, 1.30, h1)
		* mix(0.72, 1.38, vn2(world_pos.xz * 0.018 + vec2(h2 * 11.0)));
	float vcoord = dot(world_pos.xz, vdir)
		+ (sin(world_pos.y * 0.55 + h0 * 6.2831853) * 0.24);
	float vjoint = 1.0 - smoothstep(0.0, 0.055, abs(fract(vcoord / vperiod) - 0.5));
	base *= 1.0 - (tc * 0.012 + tb * 0.008) * vjoint;

	float jperiod = mix(1.2, 2.6, h0);
	float jcoord = dot(world_pos.xz, vec2(-vdir.y, vdir.x));
	float jjoint = 1.0 - smoothstep(0.0, 0.045, abs(fract(jcoord / jperiod) - 0.5));
	base *= 1.0 - tb * 0.035 * jjoint;

	// Keep the stone palette: only value and low-amplitude warm/cool bedding.
	base *= mix(vec3(1.02, 0.97, 0.88), vec3(1.14, 1.00, 0.82), h0);
	// Hemispheric stone response instead of fighting the blue ambient.  Both
	// the sun and the sky term are warm-neutral, and the shadow value stays
	// within ~1.7x of the lit value, so a cliff cannot read as two suns.
	vec3 n = normalize(world_normal);
	float ndl = clamp(dot(n, normalize(vec3(-0.45, 0.82, 0.35))), 0.0, 1.0);
	float sky = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
	float light = clamp(ndl * 0.72 + sky * 0.28, 0.0, 1.0);
	vec3 stone = base * vec3(1.03, 0.98, 0.90);
	vec3 shade = stone * vec3(0.58, 0.55, 0.50);
	vec3 lit = stone * vec3(1.04, 1.00, 0.93);
	vec3 col = mix(shade, lit, light);
	ALBEDO = debug > 0.5 ? vec3(1.0, 0.0, 1.0) : col;
	EMISSION = vec3(0.0);
}
