shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform vec4 cloth_base_color = vec4(0.35, 0.35, 0.35, 1.0);
uniform vec4 shadow_sky : source_color = vec4(0.160, 0.180, 0.210, 1.0);
uniform float shadow_energy = 0.20;
uniform float roughness_value = 0.9;
uniform float metallic_value = 0.0;
uniform vec3 sun_dir = vec3(0.624, 0.469, 0.624);
uniform vec3 extra_fill = vec3(0.0);
uniform float wood_gain = 1.0;
uniform int surface_kind = 0;   // 0 plaster, 1 timber, 2 iron, 3 trim, 4 grip, 5 cloth
uniform bool roughness_debug = false;

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
		p = p * 2.07 + vec2(9.2, 4.1);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec3 P = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 Nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// Surface detail runs in object space: it is stable under the building's
	// yaw/scale and avoids any dependence on world-space derivative precision.
	vec3 L = VERTEX;
	vec3 base_col = (surface_kind == 5) ? cloth_base_color.rgb : base_color.rgb;
	vec3 col = base_col;
	float rough = roughness_value;
	float base_y = MODEL_MATRIX[3].y;
	float rel_y = P.y - base_y;
	float up = clamp(Nw.y, 0.0, 1.0);
	// Roofs are the up-facing wood/metal above the eave line.  This deliberately
	// excludes counters, crate lids and barrel tops.
	// Roofs are up-facing wood/metal surfaces.  Height alone was unreliable
	// once the GLB merge re-based the roof geometry; the world normal is not.
	float roof = smoothstep(0.12, 0.45, up);
	// Sloped shingle planes sit high but their normal y is only ~0.4-0.6, so
	// the normal test alone under-detected them.  Height above the building
	// base identifies the roof slab reliably.
	roof = max(roof, smoothstep(1.55, 2.15, rel_y));
	// Metal roof slabs can have weak/garbled normals; classify them by slot
	// and height so no black metal roof survives from above.
	if (surface_kind == 2 && rel_y > 1.55) {
		roof = max(roof, 0.90);
	}

	if (surface_kind == 0) {
		// Plaster: multi-scale lime mottling, raised repair patches with a
		// darker broken lip, base splashback and fine hairline cracks.
		float n1 = vnoise3(L * 2.8);
		float n2 = vnoise3(L * 8.6 + vec3(1.7, 4.1, 2.3));
		float n3 = vnoise3(L * 27.0 + vec3(5.3, 1.1, 7.7));
		// Low-amplitude lime mottling only.  The old 2.35x multiplier made
		// near-black islands that read as fire damage.
		float mott = (n1 - 0.5) * 0.16 + (n2 - 0.5) * 0.06
				+ (n3 - 0.5) * 0.025;
		float patch_w = vnoise3(L * 3.1 + vec3(2.3, 0.7, 1.9));
		float patch = smoothstep(0.60, 0.74, patch_w);
		float lip = smoothstep(0.57, 0.62, patch_w)
				* (1.0 - smoothstep(0.62, 0.68, patch_w));
		float patch2 = smoothstep(0.64, 0.80,
				vnoise3(L * 5.6 + vec3(4.0, 5.0, 0.5)));
		col *= 1.0 + mott - patch * 0.07;
		col = mix(col, col * vec3(1.10, 1.06, 1.00), patch * 0.30);
		col *= 1.0 - lip * 0.07;
		col *= 1.0 - patch2 * 0.05;
		rough = 0.97;

		// Dirt and splashback at the base of the wall.
		float low = 1.0 - smoothstep(0.55, 2.6, P.y);
		float dirt_w = 0.5 + 0.5 * sin(L.x * 2.2 + L.z * 1.7
				+ sin(P.y * 0.9) * 1.4);
		float dirt = low * smoothstep(0.25, 0.75, dirt_w);
		col = mix(col, col * vec3(0.66, 0.60, 0.48), dirt * 0.55);
		// Eave shadow line, not a black patch: a narrow damp band just under
		// the roof edge.
		float eave = smoothstep(2.6, 3.6, rel_y)
			* (1.0 - smoothstep(3.6, 4.4, rel_y));
		col *= 1.0 - 0.12 * eave;
		rough += dirt * 0.12;
		// Hairline cracks: long cooled joints plus short branches.
		float crack_a = abs(sin(L.x * 3.3 + L.z * 2.1 + L.y * 0.31
				+ sin(L.y * 1.7) * 0.9));
		float crack_b = abs(sin(L.z * 4.7 - L.x * 1.4 + L.y * 0.23));
		float crack = smoothstep(0.972, 0.992, crack_a)
				+ smoothstep(0.985, 0.998, crack_b) * 0.8;
		crack *= 1.0 - patch * 0.9;
		col *= 1.0 - clamp(crack, 0.0, 1.0) * 0.38;
	} else if (surface_kind == 1) {
		// Timber: board-to-board tone, lengthwise grain, worn arrises and
		// darker end grain.  COLOR.r is baked per connected board.
		float board = 1.0 + (COLOR.r - 0.5) * 0.55 * (1.0 - smoothstep(0.45, 0.90, roof));
		board = mix(board, 1.0, roof);
		float u = L.x + L.z;
		// Axis selection must use the object-space normal: the building is
		// yawed, so a world normal would rotate the grain 90 degrees and leave
		// house_b's beams looking flat.
		float across = mix(L.x, L.z, step(0.5, abs(NORMAL.x)));
		if (abs(NORMAL.y) > 0.5) { across = u; }
		float grain = 0.5 + 0.5 * sin(across * 4.6 + sin(L.y * 1.7) * 2.4);
		float ring = 0.5 + 0.5 * sin(across * 1.9 + L.y * 0.75);
		float pore = 0.5 + 0.5 * sin(across * 18.0 + L.y * 5.0);
		col *= board * (1.0 + (grain - 0.5) * 2.2
				+ (ring - 0.5) * 1.05 + (pore - 0.5) * 0.28);
		// A second, always-visible grain pass across both plan axes.  This
		// guarantees the grain reads on beams whose face normal is parallel
		// to one object axis.
		float grain2 = 0.5 + 0.5 * sin((L.x * 1.7 + L.z * 0.9) * 9.0
				+ L.y * 2.0 + sin(L.y * 1.1) * 1.5);
		col *= 1.0 + (grain2 - 0.5) * 1.1;
		rough = 0.90 + (grain - 0.5) * 0.10;
		// Knots: tight dark cores surrounded by a compressed ring.
		float knot_a = sin(across * 11.0 + L.y * 3.3 + 1.4)
				* sin(L.y * 9.0 - across * 2.1 + 0.6);
		float knot = smoothstep(0.82, 0.97, knot_a);
		col *= 1.0 - knot * 0.40;
		rough += knot * 0.06;

		float edge = min(min(COLOR.b, 1.0 - COLOR.b), min(COLOR.a, 1.0 - COLOR.a));
		float edge_wear = smoothstep(0.0, 0.10, edge);
		col *= mix(1.02, 1.0, edge_wear);
		float end_grain = smoothstep(0.78, 0.95, abs(Nw.y)) * (1.0 - edge_wear);
		col *= mix(0.82, 1.0, end_grain);

		// Thatch courses on the roof slab: course shadow, per-course tone and
		// fine straw streaks.  The slab itself is one flat polygon.
		if (roof > 0.01) {
			// The roof planks are broad; at 5 m the grain read as painted black
			// bands.  Flatten the plank texture toward the board tone on the
			// roof and keep only a gentle straw modulation.
			float row_h = 0.17;
			float row = floor(P.y / row_h);
			float row_phase = fract(P.y / row_h);
			float row_ao = 1.0 - smoothstep(0.0, 0.20, row_phase);
			float col_w = 0.52;
			float xcell = floor((u + mod(row, 2.0) * col_w * 0.5) / col_w);
			float rh = 0.5 + 0.5 * sin(row * 2.17 + 1.3);
			float xh = 0.5 + 0.5 * sin(xcell * 1.71 + row * 0.9);
			float straw = 0.5 + 0.5 * sin(u * 16.0 + P.y * 5.0
					+ sin(P.y * 11.0) * 1.1);
			float course = 0.5 + 0.5 * sin(P.y * 27.0 + u * 1.5);
			col *= 1.0 + (straw - 0.5) * 0.12 * roof;
			col *= 1.0 + (course - 0.5) * 0.18 * roof;
			col *= 1.0 + ((rh - 0.5) * 0.12 + (xh - 0.5) * 0.10) * roof;
			col *= mix(1.0, 0.82, row_ao * roof);
			float eye = min(COLOR.b, 1.0 - COLOR.b) * 0.22;
			float ex = min(COLOR.a, 1.0 - COLOR.a) * 0.45;
			float cj = 1.0 - smoothstep(0.0, 0.045, min(eye, ex));
			col *= mix(1.0, 0.84, cj * roof);
			float roof_flat = 0.92 + 0.10 * straw;
			col = mix(col, base_col * roof_flat, roof);
		}
	} else if (surface_kind == 2) {
		// Iron: fine pitting, per-part tone, worn edges.
		float part = 1.0 + (COLOR.r - 0.5) * 0.18;
		float pit = 0.5 + 0.5 * sin(P.x * 310.0) * sin(P.y * 370.0) * sin(P.z * 290.0);
		float broad = 0.5 + 0.5 * sin(P.x * 42.0 + P.z * 37.0);
		col *= part * (0.92 + (pit - 0.5) * 0.20 + (broad - 0.5) * 0.10);
		float pit_hi = smoothstep(0.58, 0.86, pit);
		col = mix(col, col * 2.9 + vec3(0.035), pit_hi * 0.38);
		rough += (pit - 0.5) * 0.16 + (broad - 0.5) * 0.08;
		float edge = min(min(COLOR.b, 1.0 - COLOR.b), min(COLOR.a, 1.0 - COLOR.a));
		col *= mix(0.84, 1.0, smoothstep(0.0, 0.10, edge));

		if (roof > 0.01) {
			// Staggered metal tile courses with per-tile tone and shadowed
			// lower/leading edges.
			float u = P.x + P.z;
			float row_h = 0.18;
			float col_w = 0.31;
			float row = floor(P.y / row_h);
			float row_phase = fract(P.y / row_h);
			float row_ao = 1.0 - smoothstep(0.0, 0.12, row_phase);
			float xcell = floor((u + mod(row, 2.0) * col_w * 0.5) / col_w);
			float xfrac = fract((u + mod(row, 2.0) * col_w * 0.5) / col_w);
			float x_ao = 1.0 - smoothstep(0.0, 0.16, xfrac);
			float th = hash31(vec3(xcell, row, 11.0));
			float tile = 0.5 + 0.5 * sin(u * 19.0 + P.y * 24.0);
			col *= 1.0 + ((tile - 0.5) * 0.16 + (th - 0.5) * 0.30) * roof;
			col *= mix(1.0, 0.76, row_ao * roof);
			col *= mix(1.0, 0.84, x_ao * roof);
			float ey = min(COLOR.b, 1.0 - COLOR.b) * 0.22;
			float ex = min(COLOR.a, 1.0 - COLOR.a) * 0.45;
			float cj = 1.0 - smoothstep(0.0, 0.050, min(ey, ex));
			col *= mix(1.0, 0.58, cj * roof);
			// Moss collects in the broad shallow channels between tile
			// courses, especially on the north/rear slope.
			float valley = smoothstep(0.72, 0.94,
					0.5 + 0.5 * sin(P.x * 4.2 + P.z * 2.8 + row * 0.9));
			float moss = smoothstep(0.62, 0.95, valley) * roof * 0.55;
			// Damp green in the shallow V between courses and along the lower
			// eave; most of the tile stays blue-grey.
			col = mix(col, vec3(0.050, 0.100, 0.038), moss * 0.72);
			rough += moss * 0.10;
		}
	} else if (surface_kind == 5) {
		// Cloth: plain weave, broad folds, dirt along the hanging hem.
		float u = P.x + P.z;
		float weave = sin(P.x * 105.0) * sin((P.z + P.y) * 105.0);
		float fine = sin(P.x * 260.0 + P.z * 170.0 + P.y * 90.0);
		float folds = 0.5 + 0.5 * sin(u * 3.6 + sin(P.y * 1.9) * 1.6)
				* cos(P.y * 2.3 + P.x * 1.2);
		float mott = 0.5 + 0.5 * sin(P.x * 2.4 - P.z * 1.8 + 1.1);
		col *= 1.0 + (folds - 0.5) * 0.34 + (mott - 0.5) * 0.10
				+ weave * 0.100 + fine * 0.025;
		rough = 0.95 + (folds - 0.5) * 0.05;
		float low = 1.0 - smoothstep(1.30, 1.85, P.y);
		float dirt = low * smoothstep(0.25, 0.75,
				0.5 + 0.5 * sin(P.x * 2.1 + P.z * 1.6));
		col = mix(col, col * vec3(0.74, 0.70, 0.62), dirt * 0.50);
	} else {
		float fine = fbm3(P * 80.0);
		col *= 1.0 + (fine - 0.5) * 0.06;
		rough += (fine - 0.5) * 0.06;
	}

	// Timber must not crush to black: negative grain lobes were reading as
	// painted black bands on the roof.  Keep a floor of the board base tone.
	if (surface_kind == 1) {
		col = max(col, base_col * 0.42);
	}
	// Broad 8:1 weathering streaks on walls and timber, not on cloth.
	if (surface_kind == 2) {
		float streak = 0.5 + 0.5 * sin((P.x + P.z) * 1.1 + P.y * 0.14);
		float low = 1.0 - smoothstep(0.2, 2.2, rel_y);
		float weather = (streak - 0.45) * (0.35 + 0.65 * up) * (0.45 + 0.55 * low);
		col = mix(col, col * vec3(1.08, 1.03, 0.88), clamp(weather * 0.42, 0.0, 0.24));
	}

	// Keep distant silhouettes on the flat palette; the detail is for close-up
	// inspection.  This also keeps the square frame from gaining noise.
	float view_dist = length((VIEW_MATRIX * vec4(P, 1.0)).xyz);
	// close-up detail stays on; no distance fade for surface classes

	// Top-down RPG roof read.  The roof is the building from above, so every
	// building gets a terracotta clay roof with tile courses, a ridge cap and
	// an eave shadow.  Per-building tone comes from the object origin.
	if (roof > 0.55) {
		float bseed = hash31(vec3(floor(MODEL_MATRIX[3].xz * 0.31 + vec2(3.7, -1.9)), 1.7));
		// Deep terracotta base.  The previous clay was already low-luminance
		// in isolation, but the 2.8-energy sun + 1.53 exposure + ACES lifted
		// the sunlit planes to linear 0.55-0.61 and desaturated them to a
		// salmon/pink.  These values are compensated for that lighting path:
		// hue ~12 deg so the warm sun lands on 15-25 deg, and lower value so
		// the sunlit result sits near linear luminance 0.25-0.33.
		vec3 clay = mix(vec3(0.105, 0.042, 0.030),
			vec3(0.170, 0.072, 0.048), bseed);
		float row = fract(rel_y / 0.27);
		float course = 1.0 - smoothstep(0.02, 0.13, row);
		float u = fract((P.x + P.z) * 1.35);
		float joint = 1.0 - smoothstep(0.02, 0.10, u);
		float eave = 1.0 - smoothstep(3.15, 3.55, rel_y);
		float ridge = smoothstep(4.45, 4.80, rel_y);
		float tile = hash31(floor(vec3(P.x, rel_y, P.z) * 3.2 + vec3(4.7)));
		col = clay * (0.86 + 0.28 * tile);
		col *= 1.0 - 0.28 * course - 0.12 * joint;
		col *= 1.0 - 0.20 * eave;
		col = mix(col, vec3(0.105, 0.055, 0.032), ridge * 0.60);
		col = max(col, vec3(0.072, 0.028, 0.019));
		rough = 0.96;
		// Kill the broadband sun specular on the roof.  At 0.90 roughness it
		// added a near-white lobe to the sunlit planes, which is what pushed
		// their HSV saturation down to 0.28-0.34 even after the clay itself
		// was deep red.
		SPECULAR = 0.0;
	}

	// A few roof quads carry the plaster slot.  At roof height and facing up
	// they read as black rectangular holes; force them to the timber tone.
	if (surface_kind == 0 && rel_y > 3.15 && Nw.y > 0.18) {
		float rg = fract(sin(dot(P.xz, vec2(12.9898, 78.233))) * 43758.5453);
		col = vec3(0.130, 0.090, 0.060) * (0.92 + 0.10 * rg);
		rough = 0.96;
	}
	ALBEDO = (surface_kind == 1) ? col * 0.35 : col;
	ROUGHNESS = clamp(rough, 0.42, 1.0);
	METALLIC = metallic_value;
	if (surface_kind == 5) {
		EMISSION = cloth_base_color.rgb * 0.14 + shadow_sky.rgb * 0.025;
	} else if (surface_kind == 1) {
		// Modulate the (small) emissive term by the shaded colour so grain
		// survives in the shaded door reveals without flattening the timber.
		EMISSION = col * ((1.55 + 0.10 * roof) * wood_gain) + vec3(0.022, 0.012, 0.004) + extra_fill + shadow_sky.rgb * 0.03;
	} else if (surface_kind == 0) {
		EMISSION = col * 0.62 + vec3(0.035, 0.030, 0.022);
	} else {
		EMISSION = base_color.rgb * 0.28 + shadow_sky.rgb * 0.08;
	}
	if (roof > 0.55) {
		// A little roof-only fill keeps the shaded slope readable without
		// desaturating the sunlit clay.  Do not raise this back to 0.30:
		// emission is added before ACES and was a large part of the pink wash.
		EMISSION = col * 0.95 + vec3(0.015, 0.0062, 0.0036);
	}
	if (roughness_debug) {
		ALBEDO = vec3(ROUGHNESS);
		EMISSION = vec3(0.0);
	}
}
