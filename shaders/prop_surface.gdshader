shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// 0 = bridge / member timber, 1 = ruin stone, 2 = barrel staves, 3 = crate planks.
uniform int prop_kind = 0;
uniform vec4 base_color : source_color = vec4(0.20, 0.13, 0.075, 1.0);
uniform vec4 debug_color : source_color = vec4(0.0, 1.0, 0.0, 1.0);
uniform bool debug_mask = false;
uniform float roughness_value = 0.93;
uniform vec4 shadow_sky : source_color = vec4(0.16, 0.18, 0.21, 1.0);
uniform vec3 sun_dir = vec3(0.624, 0.469, 0.624);

instance uniform vec3 prop_extent = vec3(0.5);
instance uniform vec3 prop_center = vec3(0.0);
instance uniform float prop_seed = 0.5;


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
		p = p * 2.03 + vec3(7.1, 3.7, 5.3);
		a *= 0.5;
	}
	return v;
}

// Local box-ish edge measure: 0 in the middle of a face, 1 on an arris.
float arris(vec3 v, vec3 e) {
	vec3 q = clamp(abs(v) / max(e, vec3(0.0001)), 0.0, 1.0);
	float hi = max(q.x, max(q.y, q.z));
	float lo = min(q.x, min(q.y, q.z));
	float mid = q.x + q.y + q.z - hi - lo;
	return smoothstep(0.86, 1.0, mid);
}

void fragment() {
	if (debug_mask) {
		ALBEDO = vec3(0.0);
		EMISSION = debug_color.rgb;
		ROUGHNESS = 1.0;
		METALLIC = 0.0;
	} else {
	vec3 e = max(prop_extent, vec3(0.0001));
	vec3 LP = VERTEX - prop_center;
	// Choose the member's long axis in object space, then one cross-section
	// axis.  At 2 m this is what makes the grain run along the bridge member
	// instead of looking like a paper texture pasted on every face.
	vec3 axis = vec3(0.0, 1.0, 0.0);
	vec3 cross1 = vec3(1.0, 0.0, 0.0);
	vec3 cross2 = vec3(0.0, 0.0, 1.0);
	if (e.x >= e.y && e.x >= e.z) {
		axis = vec3(1.0, 0.0, 0.0); cross1 = vec3(0.0, 1.0, 0.0); cross2 = vec3(0.0, 0.0, 1.0);
	} else if (e.y >= e.z) {
		axis = vec3(0.0, 1.0, 0.0); cross1 = vec3(1.0, 0.0, 0.0); cross2 = vec3(0.0, 0.0, 1.0);
	} else {
		axis = vec3(0.0, 0.0, 1.0); cross1 = vec3(0.0, 1.0, 0.0); cross2 = vec3(1.0, 0.0, 0.0);
	}
	float along = dot(LP, axis);
	// Grain lines must be parallel to the member: vary only across the
	// cross-section, never diagonally across the length.
	float across = dot(LP, cross1);
	float u = along / max(e.x, max(e.y, e.z));
	float edge = arris(LP, e);
	float seed = prop_seed;
	vec3 col = base_color.rgb;
	float rough = roughness_value;

	if (prop_kind == 0 || prop_kind == 4) {
		// Timber member: per-member tone, low-frequency grain running the
		// length, tight pore lines, darker weathered ends and worn arrises.
		float tone = 0.70 + 0.55 * hash31(vec3(seed * 17.0, 0.0, 0.0));
		float grain = 0.5 + 0.5 * sin(across * 72.0
				+ sin(along * 5.0 + seed * 8.0) * 2.2);
		float ring = 0.5 + 0.5 * sin(across * 17.0 + along * 1.6);
		float pore = 0.5 + 0.5 * sin(across * 260.0 + along * 9.0);
		col *= tone * (0.72 + grain * 0.58) * (0.84 + ring * 0.28)
				* (0.94 + pore * 0.12);
		float knot = smoothstep(0.78, 0.97,
				sin(across * 27.0 + along * 3.2 + seed * 30.0)
				* sin(along * 9.0 - across * 3.0 + 1.7));
		col *= 1.0 - knot * 0.38;
		// Weathered/dark end grain at the member ends.
		float ends = smoothstep(0.78, 0.99, abs(u));
		col = mix(col, col * vec3(0.48, 0.34, 0.23), ends * 0.85);
		// Sun-bleached top and dark damp underside.
		float up = clamp(normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz).y, 0.0, 1.0);
		col *= mix(0.72, 1.08, up);
		// Worn arrises: pale exposed wood, with irregular chipping.
		float chip = edge * smoothstep(0.55, 0.85,
				vnoise3(LP * 38.0 + vec3(seed * 13.0)));
		col = mix(col, col * vec3(1.34, 1.22, 1.05), edge * 0.42);
		col *= 1.0 - chip * 0.34;
		rough = 0.91 + (1.0 - grain) * 0.07;
	} else if (prop_kind == 1) {
		// Ruin stone: broad damp/lime patches, mid and fine grain, hairline
		// cracks, dirt packed into recesses and pale chipped arrises.
		float n1 = fbm3(LP * 0.95 + vec3(seed * 11.0, 0.7, 2.0));
		float n2 = fbm3(LP * 5.5 + vec3(3.0, seed * 7.0, 1.0));
		float n3 = fbm3(LP * 27.0 + vec3(seed * 3.0));
		float n4 = vnoise3(LP * 115.0 + vec3(seed * 17.0));
		col *= 0.48 + 1.00 * n1;
		col *= 0.68 + 0.62 * n2;
		col *= 0.82 + 0.32 * n3;
		col *= 0.91 + 0.16 * n4;
		// Hairline cracks: long joints plus short branches.
		float cr = abs(sin(LP.x * 5.3 + LP.z * 3.7
				+ sin(LP.y * 2.2 + seed * 4.0) * 1.6));
		float cr2 = abs(sin(LP.z * 7.1 - LP.x * 2.4 + LP.y * 0.8));
		float crack = smoothstep(0.965, 0.996, cr)
				+ smoothstep(0.985, 0.999, cr2) * 0.7;
		col *= 1.0 - clamp(crack, 0.0, 1.0) * 0.42;
		// Dirt/moss in broad recesses and low down.
		float recess = (1.0 - smoothstep(0.30, 0.66, n1))
				* (1.0 - smoothstep(0.0, 0.7,
					normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz).y));
		float low = 1.0 - smoothstep(0.0, e.y * 1.9, LP.y + e.y);
		col = mix(col, col * vec3(0.44, 0.40, 0.30),
				clamp(recess * 0.70 + low * 0.25, 0.0, 0.82));
		// Moss patches sit in the broad hollows facing up.
		float mpatch = smoothstep(0.54, 0.74,
				fbm3(LP * 1.6 + vec3(seed * 8.0, 1.0, 5.0)))
				* smoothstep(0.15, 0.75,
					normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz).y);
		col = mix(col, vec3(0.070, 0.115, 0.045), mpatch * 0.32);
		// Chipped arrises: pale broken stone with a dark dirt lip.
		float chip_n = vnoise3(LP * 8.0 + vec3(seed * 5.0));
		float chip = smoothstep(0.40, 0.70, chip_n) * (0.18 + 0.82 * edge);
		col = mix(col, col * vec3(1.30, 1.20, 1.02), edge * 0.36);
		col *= 1.0 - chip * 0.52;
		rough = 0.94 + (1.0 - n2) * 0.05;
	} else if (prop_kind == 2) {
		// Barrel: 16 staves around local Y, each with its own weathered tone;
		// dark stave seams, lengthwise grain and dark end grain.
		float ang = atan(LP.x, LP.z);
		float s = fract((ang / TAU) * 16.0 + seed * 0.05);
		float stave_id = floor((ang / TAU) * 16.0 + seed * 0.05);
		float stave_tone = 0.48 + 0.95 * hash31(vec3(stave_id, seed * 19.0, 3.0));
		float seam = 1.0 - smoothstep(0.0, 0.075, min(s, 1.0 - s));
		float grain = 0.5 + 0.5 * sin(ang * 53.0 + LP.y * 31.0 + seed * 9.0);
		float ring = 0.5 + 0.5 * sin(LP.y * 44.0 + stave_id * 1.7);
		// Low-frequency break-up guarantees the staves read at 2 m even when
		// the high-frequency grain is partially averaged by TAA.
		float band = 0.5 + 0.5 * sin((LP.x + LP.z) * 37.0
				+ LP.y * 7.0 + seed * 17.0);
		col *= stave_tone * (0.58 + grain * 0.82) * (0.82 + ring * 0.30);
		// One band per stave: 16 around the barrel.  This is the cue that
		// reads at 2 m; the high-frequency grain is deliberately subordinate.
		float stave_band = 0.5 + 0.5 * sin(ang * 16.0 + seed * 6.0);
		col *= 0.48 + stave_band * 0.84;
		col *= 1.0 - seam * 0.62;
		float ends = smoothstep(0.80, 0.99, abs(LP.y) / max(e.y, 0.0001));
		col = mix(col, col * vec3(0.52, 0.38, 0.25), ends * 0.80);
		col *= mix(0.88, 1.06, smoothstep(-e.y, e.y, LP.y));
		col = mix(col, col * vec3(1.25, 1.14, 1.00), edge * 0.25);
		rough = 0.90 + (1.0 - grain) * 0.08;
	} else {
		// Crate: plank courses on each face, per-plank tone, dark joints,
		// lengthwise grain, worn corners and a dirt line at the base.
		vec3 an = abs(NORMAL);
		vec2 uv = an.y > 0.6 ? LP.xz : (an.x > 0.6 ? LP.zy : LP.xy);
		float pw = 0.16;
		float pid = floor(uv.x / pw + seed * 0.11);
		float pf = fract(uv.x / pw + seed * 0.11);
		float ptone = 0.46 + 0.98 * hash31(vec3(pid, seed * 23.0, 5.0));
		float joint = 1.0 - smoothstep(0.0, 0.06, min(pf, 1.0 - pf));
		float grain = 0.5 + 0.5 * sin(uv.x * 22.0 + uv.y * 61.0 + seed * 12.0);
		float ring = 0.5 + 0.5 * sin(uv.y * 35.0 + pid);
		col *= ptone * (0.56 + grain * 0.86) * (0.84 + ring * 0.28);
		// Plank-width bands independent of the face selection.
		float broad_plank = 0.5 + 0.5 * sin(uv.x * 82.0 + uv.y * 5.0 + seed * 7.0);
		col *= 0.68 + broad_plank * 0.55;
		col *= 0.72 + 0.32 * (0.5 + 0.5 * sin(uv.y * 55.0 + uv.x * 7.0 + seed * 9.0));
		col *= 1.0 - joint * 0.58;
		col = mix(col, col * vec3(1.25, 1.15, 1.00), edge * 0.35);
		col *= 1.0 - edge * 0.08;
		rough = 0.92 + (1.0 - grain) * 0.06;
	}

	// A little directional weathering streak, strongest on the bridge.
	if (prop_kind == 0 || prop_kind == 4) {
		float streak = 0.5 + 0.5 * sin(across * 3.1 + along * 0.11 + seed * 8.0);
		col *= 1.0 + (streak - 0.5) * 0.12;
	}

	if (prop_kind == 1) {
		ALBEDO = col;
		EMISSION = col * 0.10 + shadow_sky.rgb * 0.012;
	} else {
		// Props sit under a strongly blue ambient fill and small timber members
		// were dominated by it.  Reduce the diffuse/ambient term and carry the
		// grain in a warm, self-lit component so the hue stays in the timber
		// range instead of going navy/magenta in shadow.
		ALBEDO = vec3(0.0);
		vec3 warm = (prop_kind == 4) ? vec3(0.055, 0.046, 0.010) : vec3(0.048, 0.038, 0.017);
		EMISSION = col * 0.85 + warm;
	}
	ROUGHNESS = clamp(rough, 0.42, 1.0);
	METALLIC = 0.0;
	}
}
