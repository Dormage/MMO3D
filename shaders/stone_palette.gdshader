shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 lit_color : source_color = vec4(0.235, 0.205, 0.165, 1.0);
uniform vec4 shadow_color : source_color = vec4(0.145, 0.125, 0.105, 1.0);
uniform vec3 sun_dir = vec3(0.624, 0.469, 0.624);
uniform vec3 sky_bounce = vec3(0.012, 0.016, 0.022);
uniform bool roughness_debug = false;
uniform bool debug_b = false;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(i);
	float n100 = hash31(i + vec3(1, 0, 0));
	float n010 = hash31(i + vec3(0, 1, 0));
	float n110 = hash31(i + vec3(1, 1, 0));
	float n001 = hash31(i + vec3(0, 0, 1));
	float n101 = hash31(i + vec3(1, 0, 1));
	float n011 = hash31(i + vec3(0, 1, 1));
	float n111 = hash31(i + vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
			mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float fbm3(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise3(p);
		p = p * 2.03 + vec3(11.3, 7.7, 3.1);
		a *= 0.5;
	}
	return v;
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		vec2 i2 = floor(p);
		vec2 f = fract(p);
		f = f * f * (3.0 - 2.0 * f);
		float n = mix(mix(hash31(vec3(i2, 0.0)), hash31(vec3(i2 + vec2(1, 0), 0.0)), f.x),
				mix(hash31(vec3(i2 + vec2(0, 1), 0.0)), hash31(vec3(i2 + vec2(1, 1), 0.0)), f.x), f.y);
		v += a * n;
		p = p * 2.07 + vec2(5.2, 9.1);
		a *= 0.5;
	}
	return v;
}

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

void fragment() {
	vec3 L = normalize((VIEW_MATRIX * vec4(sun_dir, 0.0)).xyz);
	float ndl = clamp(dot(normalize(NORMAL), L), 0.0, 1.0);
	float lit = smoothstep(0.04, 0.42, ndl);
	vec3 col = mix(shadow_color.rgb, lit_color.rgb, lit);
	vec3 flat_col = col;

	vec3 P = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 Nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);

	// 1. Per-block value and hue variation, baked per connected block into
	// COLOR by VillagePalette.  This follows the real irregular block edges;
	// a quantised world cell would paint rectangles across the masonry.
	float h0 = COLOR.r;
	float h1 = COLOR.g;
	float value_mul = 1.0 + (h0 - 0.5) * 0.70;
	value_mul *= 0.90;
	vec3 hsv = rgb2hsv(col);
	hsv.x = fract(hsv.x + (h1 - 0.5) * (8.0 / 360.0));
	col = hsv2rgb(hsv) * value_mul;

	// 3. Joint AO: the baked vertex colour carries the block's normalised
	// vertical position, so the contact darkening follows the real block top
	// and bottom edges rather than an offset world-space course grid.
	float edge_y = min(COLOR.b, 1.0 - COLOR.b) * 0.32;
	float edge_x = min(COLOR.a, 1.0 - COLOR.a) * 0.36;
	float joint_y = 1.0 - smoothstep(0.0, 0.070, edge_y);
	float joint_x = 1.0 - smoothstep(0.0, 0.035, edge_x);
	col *= mix(1.0, 0.66, joint_y);
	col *= mix(1.0, 0.84, joint_x);

	// 2. Fine grain, 0.02-0.15 m.
	float g0 = fbm3(P * 11.0 + vec3(4.0, 8.0, 1.0));
	float g1 = fbm3(P * 26.0);
	float g2 = fbm3(P * 61.0 + vec3(5.0, 2.0, 8.0));
	float g3 = fbm3(P * 130.0 + vec3(13.0, 3.0, 21.0));
	float g4 = fbm3(P * 260.0 + vec3(2.0, 9.0, 4.0));
	float grain = (g0 - 0.5) * 0.85 + (g1 - 0.5) * 0.80
			+ (g2 - 0.5) * 0.65 + (g3 - 0.5) * 0.75
			+ (g4 - 0.5) * 0.40;
	col *= 1.0 + grain * 0.60;
	// Fine mineral speckle: 2-8 mm, strong enough to survive TAA at 1.5 m.
	float speck = hash31(floor(P * 420.0));
	float speck2 = hash31(floor(P * 130.0) + vec3(19.0, 7.0, 3.0));
	col *= 0.90 + speck * 0.20 + (speck2 - 0.5) * 0.10;


	// 4. Weathering: 8:1 vertical streaks, warm-green, stronger up and low.
	float streak = fbm2(vec2((P.x + P.z) * 2.1, P.y * 0.26));
	float up = clamp(Nw.y, 0.0, 1.0);
	float low = 1.0 - smoothstep(0.2, 2.2, P.y);
	float weather = (streak - 0.45) * (0.35 + 0.65 * up) * (0.45 + 0.55 * low);
	col = mix(col, col * vec3(1.12, 1.04, 0.86), clamp(weather * 0.80, 0.0, 0.32));

	// Stone-roofed buildings bypass palette_surface.  Give their upward slabs
	// the same terracotta roof read so no building is a black rectangle from
	// the top-down RPG camera.
	if (Nw.y > 0.55 && P.y > 1.55) {
		float bseed = hash31(floor(vec3(P.xz, 1.0) * 0.31));
		vec3 clay = mix(vec3(0.185, 0.105, 0.072),
			vec3(0.255, 0.160, 0.110), bseed);
		float row = fract(P.y / 0.27);
		float course = 1.0 - smoothstep(0.02, 0.13, row);
		float tile = hash31(floor(vec3(P.x, P.y, P.z) * 3.2 + vec3(4.7)));
		col = clay * (0.86 + 0.28 * tile);
		col *= 1.0 - 0.26 * course;
		col = max(col, vec3(0.120, 0.060, 0.036));
	}
	ALBEDO = col;
	ROUGHNESS = clamp(0.80 + grain * 0.35 + (h0 - 0.5) * 0.08
			+ (streak - 0.5) * 0.06, 0.65, 1.0);
	METALLIC = 0.0;

	// Keep the far field on the flat palette; the procedural detail is for
	// close inspection and must not darken the village silhouettes.
	float view_dist = length((VIEW_MATRIX * vec4(P, 1.0)).xyz);
	col = mix(flat_col, col, 1.0 - smoothstep(1.5, 3.0, view_dist));

	// 5. Shadow-only sky bounce.
	EMISSION = (shadow_color.rgb * 0.55 + sky_bounce) * (1.0 - lit);
	if (roughness_debug) {
		ALBEDO = vec3(ROUGHNESS);
		EMISSION = vec3(0.0);
	}
	if (debug_b) {
		ALBEDO = vec3(COLOR.b);
		EMISSION = vec3(0.0);
	}
}
