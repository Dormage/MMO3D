shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// Grass cards.
//
// One MultiMesh per island, two crossed quads per clump. The card is a
// screen-cutout (discard, not blend) so it can stay in the opaque pass and
// receive shadows without sorting. Everything that makes it move is here:
//
//   * wind      - two sine bands plus a slow gust, weighted by distance from
//                 the card's base so the root never slides on the ground;
//   * fade      - past `fade_start` the card loses alpha and gets slightly
//                 shorter, so a MultiMesh island melts into the fog instead of
//                 popping as a block;
//   * tint      - two linear multipliers mixed by per-instance custom data, so
//                 a pasture is not one flat green.

uniform sampler2D grass_texture : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tint_a = vec3(0.82, 0.92, 0.66);
uniform vec3 tint_b = vec3(1.06, 1.10, 0.82);
uniform float wind_strength = 0.10;   // metres of tip travel at full gust
uniform float wind_speed = 1.35;
uniform float wind_scale = 0.30;      // spatial frequency of the gust field
uniform float fade_start = 85.0;      // metres
uniform float fade_end = 170.0;       // metres
uniform float alpha_scissor = 0.10;
uniform float near_scale = 1.00;
uniform float min_height_at_fade = 0.55;
uniform float translucency = 0.30;
// Same world-space tone fields as terrain.gdshader.  The path mask and wear
// points are the terrain's baked lane and layout-driven high-traffic points.
uniform sampler2D path_mask : filter_linear, repeat_disable;
uniform vec4 path_rect = vec4(-82.0, -82.0, 164.0, 164.0);
uniform vec4 wear_pts[16];
uniform int wear_count = 0;
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

varying float v_fade;
varying float v_tip;
varying float v_dry;
varying float v_lush;
varying float v_worn;
varying vec3 v_tint;
varying vec3 v_world;
varying float v_near;

float hash11(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash11(i.x + i.y * 57.0);
	float b = hash11(i.x + 1.0 + i.y * 57.0);
	float c = hash11(i.x + (i.y + 1.0) * 57.0);
	float d = hash11(i.x + 1.0 + (i.y + 1.0) * 57.0);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float tf(float x, float z, float ox, float oz, float freq) {
	return vnoise2(vec2(x, z) * freq + vec2(ox, oz));
}

void vertex() {
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float dist = length((VIEW_MATRIX * vec4(origin, 1.0)).xyz);
	v_fade = 1.0 - smoothstep(fade_start, fade_end, dist);
	v_world = origin;

	// the card's UVs run top = 0, base = 1 (image space)
	v_tip = 1.0 - UV.y;
	float bend = v_tip * v_tip;

	float phase = INSTANCE_CUSTOM.x * 6.2831853;
	float gain = 0.65 + INSTANCE_CUSTOM.z * 0.7;
	float gust = sin(TIME * wind_speed * 0.37 + origin.x * wind_scale * 0.42
			+ origin.z * wind_scale * 0.31);
	float sway = sin(TIME * wind_speed + phase + origin.x * wind_scale
			+ origin.z * wind_scale * 0.7);
	float chop = sin(TIME * wind_speed * 2.3 + phase * 1.7
			+ origin.x * wind_scale * 2.1);

	// local axes: the instance basis already has a random yaw and a slope tilt
	VERTEX.x += (sway * 0.65 + gust * 0.55 + chop * 0.18)
			* wind_strength * bend * gain;
	VERTEX.z += (cos(TIME * wind_speed * 0.83 + phase + origin.z * wind_scale)
			* 0.35 + gust * 0.2) * wind_strength * bend * gain;

	// shrink the card toward the ground as it fades: cheaper than dithering and
	// it stops a whole island's silhouette from vanishing on one frame
	float shrink = mix(1.0, min_height_at_fade, 1.0 - v_fade);
	VERTEX.y *= shrink;
	VERTEX.x *= mix(1.0, 0.9, 1.0 - v_fade);

	// first few metres: fewer, larger cards/blades; mid/far unchanged
	float near_k = mix(near_scale, 1.0, smoothstep(3.0, 9.0, dist));
	VERTEX.x *= near_k;
	VERTEX.z *= near_k;
	VERTEX.y *= near_k;

	// --- same 3-15 m world-space fields as the terrain turf ---------------
	vec2 wp = origin.xz;
	// 0.3-1.5 m surface relief: break the uniform card height near the player
	// so a mound is not a smooth green dough.
	float near_ground = 1.0 - smoothstep(12.0, 26.0, dist);
	v_near = near_ground;
	float hmod = tf(wp.x, wp.y, 6.3, -8.1, 0.72) * 0.62
		+ tf(wp.x, wp.y, -3.8, 4.7, 1.65) * 0.38;
	VERTEX.y *= 1.0 + (hmod - 0.5) * 0.42 * near_ground;
	float mp_broad = tf(wp.x, wp.y, 17.3, -4.2, 0.075);
	float mp_mid = tf(wp.x, wp.y, -9.8, 6.7, 0.160);
	float mp_small = tf(wp.x, wp.y, 5.1, 12.4, 0.340);
	float meadow_n = 0.55 * mp_broad + 0.30 * mp_mid + 0.15 * mp_small;
	float dry_m = smoothstep(0.49, 0.63, meadow_n);
	float lush_m = smoothstep(0.49, 0.64, 1.0 - meadow_n);
	float n_large = tf(wp.x, wp.y, 3.7, 8.9, 0.27);
	float n_med = tf(wp.x, wp.y, -4.1, 2.3, 0.61);
	float dry_field = smoothstep(0.62, 0.78, 0.55 * n_large + 0.45 * n_med);
	float mid_broad = tf(wp.x, wp.y, 21.4, -9.3, 0.145);
	float mid_patch = tf(wp.x, wp.y, -13.2, 4.8, 0.310);
	float mid_dry = smoothstep(0.47, 0.66,
		0.68 * mid_broad + 0.32 * mid_patch);
	float island_n = tf(wp.x, wp.y, -12.7, -3.9, 0.255);
	float dry_island = smoothstep(0.58, 0.76, island_n);
	float lush_island = smoothstep(0.56, 0.74, 1.0 - island_n);
	float island_dry = INSTANCE_CUSTOM.a;
	float dry = max(dry_m, max(dry_field * 0.78,
		max(mid_dry * 0.58, max(dry_island * 0.66, island_dry * 0.78))));
	float lush = max(lush_m, lush_island * 0.42);

	vec2 puv = (wp - path_rect.xy) / path_rect.zw;
	float path = smoothstep(0.12, 0.48, texture(path_mask, puv).r);
	float traffic = 0.0;
	for (int wi = 0; wi < 16; wi++) {
		if (wi >= wear_count) break;
		vec4 wq = wear_pts[wi];
		float wd = length(wp - wq.xy);
		traffic = max(traffic, (1.0 - smoothstep(wq.z * 0.30, wq.z, wd)) * wq.w);
	}
	float worn = max(path, traffic);
	v_dry = clamp(dry, 0.0, 1.0);
	v_lush = clamp(lush, 0.0, 1.0);
	v_worn = clamp(worn, 0.0, 1.0);

	// Let the shader shorten the little that survives on a lane: the CPU
	// already thinned and shortened these instances.
	VERTEX.y *= mix(1.0, 0.70, worn);

	vec3 base = mix(tint_a, tint_b, INSTANCE_CUSTOM.y);
	// Match the darker, slightly desaturated turf base rather than neon card
	// green, then push dry/wet/worn tone through the same bands as the ground.
	base = mix(vec3(dot(base, LUMA)), base, 0.20) * 0.84;
	base = mix(base, base * vec3(1.14, 1.04, 0.78), dry * 0.72);
	base = mix(base, base * vec3(0.78, 0.96, 0.80), lush * 0.55);
	base = mix(base, vec3(dot(base, LUMA)) * vec3(1.02, 0.94, 0.80),
		worn * 0.62);
	base *= 1.0 - 0.18 * worn;
	float hf1 = tf(wp.x, wp.y, 1.7, -6.3, 0.95);
	float hf2 = tf(wp.x, wp.y, -5.2, 2.8, 2.10);
	base *= 1.0 + ((hf1 - 0.5) * 0.28 + (hf2 - 0.5) * 0.14) * near_ground;
	v_tint = base;
}

void fragment() {
	vec4 tex = texture(grass_texture, UV);
	float alpha = tex.a * v_fade;
	if (alpha < alpha_scissor) {
		discard;
	}
	// The generated blade texture stores linear values around 0.02-0.25; with
	// a terrain turf around 0.10-0.20 the raw card was crushed to black.
	float far_lift = 1.0 + 0.45 * (1.0 - v_fade);
	vec3 lit = tex.rgb * v_tint * 3.0 * far_lift;
	// Per-clump 0.3-1.5 m tone breakup; the broad meadow fields are handled in
	// the vertex stage, this is the near-field surface grain.
	float ghf = vnoise2(v_world.xz * 1.35 + vec2(3.1, -7.4));
	lit *= 1.0 + (ghf - 0.5) * 0.62 * v_near;
	ALBEDO = lit;
	ROUGHNESS = 0.93;
	SPECULAR = 0.18;
	// A little forward scatter keeps the blades from turning into black
	// silhouettes when the sun is behind them.
	EMISSION = lit * translucency * (0.6 + 0.4 * v_tip)
		* (1.0 - 0.40 * v_worn);
}
