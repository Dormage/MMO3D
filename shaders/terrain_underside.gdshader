shader_type spatial;
// Solid soil/rock keel under the flying islands. Unlit: the fixed sun never
// reaches it, and a lit material turned black in sky ambient (the old void).
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;




// Grey-brown sediment with warm ochre light beds and cool grey dark beds.
uniform vec3 rock_dark = vec3(0.078, 0.075, 0.071);
uniform vec3 rock_mid = vec3(0.125, 0.121, 0.115);
uniform vec3 ochre_bed = vec3(0.145, 0.140, 0.132);
uniform vec3 cool_grey = vec3(0.085, 0.065, 0.050);
uniform vec3 seam_dark = vec3(0.002, 0.002, 0.002);
uniform vec3 damp_col = vec3(0.060, 0.040, 0.026);
uniform vec3 moss_col = vec3(0.028, 0.042, 0.020);
// Cool sky/water bounce reaching the unlit keel; seams get less of it.
uniform vec3 ambient_lift = vec3(0.030, 0.022, 0.014);

varying vec3 v_w;
varying vec3 v_n;

float h21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vn(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x),
		mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y);
}

vec2 hash22(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(vec2(p.x * p.y, p.x + p.y));
}

float facet_edge(vec2 q, float seed) {
	vec2 i = floor(q);
	vec2 f = fract(q);
	float d1 = 9.0;
	float d2 = 9.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = hash22(i + g + seed);
			vec2 r = g + o - f;
			float d = dot(r, r);
			if (d < d1) { d2 = d1; d1 = d; } else { d2 = min(d2, d); }
		}
	}
	return sqrt(d2) - sqrt(d1);
}

void vertex() {
	v_w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_n = NORMAL;
}

void fragment() {
	vec3 p = v_w;
	float fp_u = max(fwidth(p.x), max(fwidth(p.y), fwidth(p.z)));
	float u_aa = 1.0 - smoothstep(0.010, 0.042, fp_u);
	u_aa *= 1.0 - smoothstep(14.0, 20.0, distance(CAMERA_POSITION_WORLD, p));
	float n = vn(p.xz * 0.070) * 0.50
		+ vn(p.xz * 0.19 + vec2(9.1, -3.7)) * 0.32
		+ vn(p.xz * 0.62 + vec2(-4.3, 6.2)) * 0.18;

	// Low-frequency warp: +/-1.5 m over roughly 37 m, so no contact is level.
	float warp = (vn(p.xz * 0.027 + vec2(2.3, -1.2)) - 0.5) * 3.0;
	float yb = p.y + warp;

	// Each bed boundary wanders independently by up to +/-1.5 m.  Thickness
	// therefore changes along the face instead of every band being parallel.
	float b1 = -0.5 + (vn(p.xz * 0.030 + vec2(1.1, 4.2)) - 0.5) * 3.0;
	float b2 = -2.0 + (vn(p.xz * 0.028 + vec2(7.3, -2.1)) - 0.5) * 3.0;
	float b3 = -6.0 + (vn(p.xz * 0.025 + vec2(-3.7, 5.4)) - 0.5) * 3.0;
	float b4 = -9.5 + (vn(p.xz * 0.033 + vec2(4.8, -6.2)) - 0.5) * 2.6;
	float b5 = -13.0 + (vn(p.xz * 0.026 + vec2(-6.4, 1.8)) - 0.5) * 3.0;
	float b6 = -18.0 + (vn(p.xz * 0.031 + vec2(2.7, 7.9)) - 0.5) * 2.6;
	float b7 = -22.0 + (vn(p.xz * 0.024 + vec2(-1.5, -4.6)) - 0.5) * 2.4;

	// Three beds pinch out where their mask falls to zero; the others thin.
	float w1 = smoothstep(0.18, 0.44, vn(p.xz * 0.045 + vec2(3.3, 1.7)));
	float w2 = smoothstep(0.42, 0.66, vn(p.xz * 0.041 + vec2(-4.1, 8.2)));
	float w3 = smoothstep(0.20, 0.48, vn(p.xz * 0.037 + vec2(6.2, -3.4)));
	float w4 = smoothstep(0.46, 0.70, vn(p.xz * 0.043 + vec2(-7.6, 2.8)));
	float w5 = smoothstep(0.22, 0.50, vn(p.xz * 0.039 + vec2(1.8, -8.1)));
	float w6 = smoothstep(0.44, 0.68, vn(p.xz * 0.035 + vec2(8.4, 4.4)));
	float w7 = smoothstep(0.24, 0.52, vn(p.xz * 0.042 + vec2(-2.9, 6.6)));

	float s1 = step(b1, yb) * w1;
	float s2 = step(b2, yb) * w2;
	float s3 = step(b3, yb) * w3;
	float s4 = step(b4, yb) * w4;
	float s5 = step(b5, yb) * w5;
	float s6 = step(b6, yb) * w6;
	float s7 = step(b7, yb) * w7;
	float strata = 0.070 * s1 + 0.052 * s2 + 0.082 * s3
		+ 0.030 * s4 + 0.026 * s5 + 0.032 * s6 + 0.022 * s7;

	float seam = (1.0 - smoothstep(0.0, 0.045, abs(yb - b1))) * w1
		+ (1.0 - smoothstep(0.0, 0.050, abs(yb - b2))) * w2
		+ (1.0 - smoothstep(0.0, 0.060, abs(yb - b3))) * w3
		+ 0.7 * (1.0 - smoothstep(0.0, 0.050, abs(yb - b4))) * w4
		+ 0.6 * (1.0 - smoothstep(0.0, 0.050, abs(yb - b5))) * w5
		+ 0.7 * (1.0 - smoothstep(0.0, 0.055, abs(yb - b6))) * w6
		+ 0.5 * (1.0 - smoothstep(0.0, 0.055, abs(yb - b7))) * w7;
	seam = clamp(seam, 0.0, 1.0) * u_aa;


	// 1 m macro beds, each with its own value, so the keel is not one flat wall.
	float bed_id = floor(yb);
	float bed_rand = fract(sin(bed_id * 12.9898) * 43758.5453);
	float bed_tone = fract(sin(floor(yb * 0.65) * 21.113) * 43758.5453);

	// Sparse vertical fracture lines, fading in and out along the face.
	float fr = abs(sin(p.x * 0.63 + p.z * 0.47 + n * 2.8));
	float fracture = 1.0 - smoothstep(0.012, 0.075, fr);
	fracture *= smoothstep(0.30, 0.72,
		vn(p.xz * 0.13 + vec2(5.1, 1.7)));
	float fr2 = abs(sin(p.x * 0.31 - p.z * 0.22 + n * 1.7));
	float fracture2 = 1.0 - smoothstep(0.018, 0.060, fr2);
	fracture2 *= smoothstep(0.40, 0.80,
		vn(p.xz * 0.09 + vec2(-2.3, 7.1)));

	// Broad recesses / concavities read darker; no normals required.
	float recess = smoothstep(0.58, 0.86,
		vn(p.xz * 0.17 + vec2(-7.3, 2.1)));

	vec3 c = mix(rock_dark, rock_mid,
		clamp(0.22 + 0.55 * n + strata, 0.0, 1.0));
	c = mix(c, ochre_bed, smoothstep(0.55, 0.92, bed_tone) * 0.34);
	c = mix(c, cool_grey, smoothstep(0.58, 0.94, fract(bed_tone * 2.1)) * 0.24);
	c = mix(c, seam_dark, 0.88 * seam);
	c *= 0.86 + 0.30 * bed_rand;
	c *= 1.0 - (0.55 * fracture + 0.36 * fracture2) * u_aa;
	c *= 1.0 - 0.55 * recess;
	c += ambient_lift * (1.0 - 0.45 * seam);

	// 6-20 m tonal fields and a screen-lateral warm/cool split.  The causeway
	// cut is mostly this keel, so the fine 0.05-1 m grain alone averages to a
	// flat tan card at 10-60 m.
	float u_large = vn(p.xz * 0.052 + vec2(5.7, -1.9)) * 0.42
		+ vn(p.xz * 0.095 + vec2(8.4, 1.3)) * 0.26
		+ vn(p.xz * 0.155 + vec2(-2.8, 4.6)) * 0.32;
	vec3 cam_right_u = INV_VIEW_MATRIX[0].xyz;
	float u_lateral = dot(p - CAMERA_POSITION_WORLD, cam_right_u);
	float u_side = smoothstep(-9.0, 9.0, u_lateral);
	float u_hue = clamp(mix(0.12, 0.88, u_side) + (u_large - 0.5) * 0.55, 0.0, 1.0);
	float u_luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
	vec3 u_cool = vec3(u_luma) * vec3(0.72, 0.88, 1.30);
	vec3 u_warm = vec3(u_luma) * vec3(1.32, 1.03, 0.70);
	c = mix(c, mix(u_cool, u_warm, u_hue), 0.62);
	c *= mix(0.42, 1.58, u_large);

	// 5-20 m bed interior.  The u_large field gives the big tone, but each
	// bed still reads as one painted band at 5-20 m.  Static world-space
	// mottling, lamination, pitting, fractures, per-bed drift and scree.
	float u_dist = distance(CAMERA_POSITION_WORLD, p);
	float u_band = smoothstep(8.0, 12.0, u_dist)
		* (1.0 - smoothstep(50.0, 75.0, u_dist));
	float u_sub_a = vn(vec2(p.x * 0.72 + p.z * 0.55, p.y * 1.45) + vec2(3.2, -7.1));
	float u_sub_b = vn(vec2(p.x * 1.90 - p.z * 1.30, p.y * 3.10) + vec2(-4.6, 5.8));
	float u_sub_c = vn(vec2(p.x * 4.80 + p.z * 3.00, p.y * 6.20) + vec2(7.3, -2.4));
	float u_fine_bed = 1.0 - smoothstep(28.0, 48.0, u_dist);
	float u_sub_a_c = smoothstep(0.28, 0.72, u_sub_a);
	c *= mix(1.0, mix(0.46, 1.54, u_sub_a_c), 1.40 * u_band);
	c *= mix(1.0, mix(0.74, 1.26, u_sub_b), 0.78 * u_band * u_fine_bed * u_aa);
	float u_lam_phase = abs(fract(yb / 0.34 + (u_sub_a - 0.5) * 0.08) - 0.5);
	float u_lam = 1.0 - smoothstep(0.0, 0.070, u_lam_phase);
	u_lam *= smoothstep(0.32, 0.64, u_sub_b);
	c *= 1.0 - 0.006 * u_lam * u_band * u_fine_bed * u_aa;
	float u_pit = smoothstep(0.70, 0.86, u_sub_c);
	c *= 1.0 - 0.58 * u_pit * u_band * u_fine_bed * u_aa;
	float u_bed_id = floor(yb / 1.5);
	float u_bed_hash = fract(sin(u_bed_id * 12.9898
		+ floor(yb / 5.0) * 78.233) * 43758.5453);
	vec3 u_drift = mix(vec3(0.86, 0.92, 1.10),
		vec3(1.12, 1.04, 0.82), u_bed_hash);
	c *= mix(vec3(1.0), u_drift, 0.68 * u_band);
	c *= mix(1.0, 0.55 + 0.90 * u_bed_hash, 0.72 * u_band);
	float u_vf_coord = atan(p.z, p.x) * 3.4 + (u_sub_a - 0.5) * 0.30;
	float u_vf = 1.0 - smoothstep(0.0, 0.040,
		abs(sin(u_vf_coord * 7.0 + p.y * 0.010)));
	u_vf *= smoothstep(0.40, 0.72, u_sub_b) * u_band * u_fine_bed;
	c *= 1.0 - 1.12 * u_vf * u_aa;

	// Sharp horizontal beds replace the marbled texture flow.  Fixed ~0.55 m
	// beds, hard 2-3 cm seams, one tone per bed, horizontal lamination and a
	// faulted vertical fracture every ~2.2 m.  Only +/-0.15 m horizontal warp.
	float ub_warp = (vn(p.xz * 0.055) - 0.5) * 0.30;
	float ub_lat = p.x * 0.42 + p.z * 0.31;
	float ub_cell = floor(ub_lat / 2.2);
	float ub_fpos = fract(ub_lat / 2.2);
	float ub_fseed = fract(sin(ub_cell * 12.9898) * 43758.5453);
	float ub_fcentre = 0.12 + 0.76 * ub_fseed;
	float ub_fault = (fract(sin((ub_cell + 7.0) * 78.233) * 43758.5453)
		- 0.5) * 0.16 * step(ub_fcentre, ub_fpos);
	float ub_dip = p.x * 0.040 + p.z * 0.026
		+ (vn(p.xz * 0.045 + vec2(-7.0, 3.0)) - 0.5) * 0.10;
	float ub_y = p.y + ub_warp + ub_fault + ub_dip;
	float ub_pinch = smoothstep(0.58, 0.86,
		vn(p.xz * 0.07 + vec2(11.0, -3.0)));
	float ub_acc = 0.0;
	float ub_bi = 0.0;
	float ub_thick_i = 1.0;
	float ub_pos = 0.5;
	for (int bi = 0; bi < 32; bi++) {
		float fi = float(bi);
		ub_thick_i = 0.30 + 1.70 * fract(fi * 0.754877666 + 0.31);
		ub_thick_i = mix(ub_thick_i, 1.95, step(mod(fi, 7.0), 0.5));
		float pin = step(fract(fi * 0.6180339 + 0.17), 0.16) * ub_pinch;
		ub_thick_i = max(0.025, ub_thick_i * (1.0 - 0.96 * pin));
		float uby = ub_y + 12.0;
		if (uby < ub_acc + ub_thick_i) {
			ub_bi = fi;
			ub_pos = clamp((uby - ub_acc) / ub_thick_i, 0.0, 1.0);
			break;
		}
		ub_acc += ub_thick_i;
	}
	float ub_hash = fract(sin(ub_bi * 12.9898 + 13.782
		+ ub_dip * 3.0) * 43758.5453);
	float ub_base = mix(0.045, 0.195, ub_hash);
	ub_base *= 0.94 + 0.12 * fract(ub_hash * 7.7);
	float ub_anom = fract(ub_hash * 13.71);
	if (ub_anom > 0.90) {
		ub_base *= 0.56;
	} else if (ub_anom < 0.08) {
		ub_base *= 1.45;
	}
	float ub_thin = 1.0 - smoothstep(0.0, 0.035, abs(ub_pos - 0.5));
	ub_base *= mix(1.0, 0.62, step(0.94, ub_anom) * ub_thin);
	vec3 ub_col = vec3(ub_base);
	ub_col *= mix(vec3(0.86, 0.92, 1.08), vec3(1.10, 1.02, 0.86),
		fract(ub_hash * 5.73));
	float ub_seam = 1.0 - smoothstep(0.0, 0.040,
		min(ub_pos, 1.0 - ub_pos));
	ub_col *= 1.0 - 0.78 * ub_seam * u_aa;
	float ub_lam_warp = (vn(p.xz * 0.16) - 0.5) * 0.20;
	float ub_lam = 1.0 - smoothstep(0.0, 0.018,
		abs(fract((ub_y + ub_lam_warp) / 0.36) - 0.5));
	ub_lam *= smoothstep(0.35, 0.65, u_sub_b);
	ub_col *= 1.0 - 0.010 * ub_lam * u_aa;
	ub_col *= mix(1.0, mix(0.86, 1.14, u_sub_a), 1.00 * u_band);
	ub_col *= 1.0 - 0.20 * u_pit * u_band;
	float ub_vf = 1.0 - smoothstep(0.0, 0.035,
		abs(ub_fpos - ub_fcentre));
	ub_col *= 1.0 - 0.58 * ub_vf * u_aa;
	c = ub_col;
	// Far keel: broad bed blocks, a 10 m value field and a few wide vertical
	// faults replace the sub-4 cm lamination that aliases at 20-40 m.
	float u_far_w = smoothstep(14.0, 24.0, distance(CAMERA_POSITION_WORLD, p));
	{
		float cu_y = p.y + (vn(p.xz * 0.033 + vec2(1.3, -4.2)) - 0.5) * 0.80;
		float cu_id = floor(cu_y / 3.8);
		float cu_hash = fract(sin(cu_id * 12.9898 + 7.3) * 43758.5453);
		float cu_tone = mix(0.80, 1.17, cu_hash);
		float cu_var = vn(p.xz * 0.055 + p.y * 0.030 + vec2(-3.1, 5.6));
		c *= mix(1.0, cu_tone * mix(0.84, 1.16, cu_var), u_far_w * 0.88);
		float cu_ch = p.x * 0.73 + p.z * 0.68;
		float cu_warp = (vn(p.xz * 0.050 + vec2(3.7, -8.2)) - 0.5) * 1.8;
		float cu_line = 1.0 - smoothstep(0.0, 0.018,
			abs(fract((cu_ch + cu_warp) / 12.0) - 0.5));
		cu_line *= smoothstep(0.40, 0.65,
			vn(p.xz * 0.060 + vec2(6.1, 1.4)));
		c *= 1.0 - 0.38 * cu_line * u_far_w;
	}

	// 1.4-1.8 m shadow under the b2/b3 ledges, broken along the face.
	float u_ledge = smoothstep(b3 - 1.8, b3, yb)
		* (1.0 - smoothstep(b3, b3 + 0.04, yb)) * w3
		+ smoothstep(b2 - 1.4, b2, yb)
		* (1.0 - smoothstep(b2, b2 + 0.04, yb)) * w2
		+ smoothstep(b4 - 1.6, b4, yb)
		* (1.0 - smoothstep(b4, b4 + 0.04, yb)) * w4
		+ smoothstep(b5 - 1.5, b5, yb)
		* (1.0 - smoothstep(b5, b5 + 0.04, yb)) * w5;
	c *= 1.0 - 0.62 * clamp(u_ledge, 0.0, 1.0);
	// Scree aprons along the ledges and at the lower keel.
	float u_scree = clamp(u_ledge * 0.85
		+ (1.0 - smoothstep(-4.0, -1.2, p.y)) * 0.25, 0.0, 1.0);
	float u_stones = smoothstep(0.66, 0.84, u_sub_c);
	c *= 1.0 - 0.72 * u_scree * u_band * (0.45 + 0.55 * u_stones);
	c = mix(c, vec3(0.030, 0.025, 0.020), u_scree * u_band * 0.28);
	float u_chips = smoothstep(0.84, 0.94, u_sub_c);
	// Pale flecks were an even paint-splatter layer.  Keep only 20% of them
	// and only inside rare veined clusters.
	float u_vein = smoothstep(0.62, 0.90, vn(vec2(p.x * 0.33 + p.z * 0.21,
		p.y * 0.045) + vec2(2.7, -1.4)));
	c = mix(c, vec3(0.285, 0.250, 0.205), u_chips * 0.00 * u_vein * u_band);

	// 0.05-1 m surface breakup.  The keel is unlit, so this is albedo-only:
	// soil grit, pebbles, hairline cracks and vertical damp runs.  It is what
	// stops a thirty-metre tall cliff reading as smooth chocolate.
	float u_near = 1.0 - smoothstep(28.0, 75.0,
		distance(CAMERA_POSITION_WORLD, p));
	float u1 = vn(vec2(p.x * 1.35 + p.z * 0.95, p.y * 0.72) * 2.2);
	float u2 = vn(vec2(p.x * 3.7 - p.z * 2.4, p.y * 1.75) * 4.6);
	float u3 = vn(vec2(p.x * 8.1 + p.z * 4.4, p.y * 3.2) * 9.0);
	// At 3-8 m the keel is the largest surface in frame: push the near-field
	// grain and cracks harder here, while the 6-20 m field carries distance.
	float u_close = 1.0 - smoothstep(10.0, 34.0,
		distance(CAMERA_POSITION_WORLD, p));
	// Fine keel grain removed: it read as granite static / pale vein crazing
	// on the hanging underside.  Keep only the low-frequency bed tone.
	c *= 1.0;
	// 1-3 m branching cracks on the exposed keel, visible at 3 m.
	float u_crack_big = 1.0 - smoothstep(0.006, 0.030,
		abs(vn(vec2(p.x * 0.28 + p.z * 0.22, p.y * 0.60) + vec2(3.7, 1.2)) - 0.5));
	u_crack_big *= smoothstep(0.30, 0.70,
		vn(vec2(p.x * 0.11 + 5.3, p.z * 0.11 - 2.1)));
	c *= 1.0 - 0.60 * u_crack_big * u_close * u_aa;
	float u_stone = smoothstep(0.82, 0.94,
		vn(vec2(p.x * 5.2 + p.z * 1.8, p.y * 3.1) * 6.0));
	c = mix(c, vec3(0.150, 0.120, 0.090), u_stone * 0.00);
	float u_stone2 = smoothstep(0.90, 0.98,
		vn(vec2(p.x * 9.6 - p.z * 4.1, p.y * 5.5) * 12.0));
	c = mix(c, vec3(0.235, 0.205, 0.170), u_stone2 * 0.00);
	float u_crack = abs(sin(p.x * 2.2 + p.z * 1.7
		+ vn(vec2(p.x * 0.6, p.y * 2.1)) * 3.0));
	u_crack = 1.0 - smoothstep(0.012, 0.062, u_crack);
	c *= 1.0 - 0.42 * u_crack * u_near * u_aa;
	float u4 = vn(vec2(p.x * 13.1 - p.z * 7.3, p.y * 6.2) * 14.0);
	float u5 = vn(vec2(p.x * 24.0 + p.z * 11.0, p.y * 9.0) * 24.0);
	c *= 1.0;
	float u_peb = smoothstep(0.78, 0.90,
		vn(vec2(p.x * 7.7 + p.z * 3.1, p.y * 4.6) * 8.0));
	c = mix(c, vec3(0.210, 0.175, 0.135), u_peb * 0.0);
	float u_dark = smoothstep(0.84, 0.94,
		vn(vec2(p.x * 11.0 - p.z * 6.0, p.y * 7.0) * 16.0));
	c = mix(c, c * 0.55, u_dark * 0.45);
	float u_streak = smoothstep(0.42, 0.68,
		vn(vec2(p.x * 1.6 + p.z * 1.1, p.y * 0.24)));
	c = mix(c, c * vec3(0.55, 0.53, 0.48), u_streak * 0.22);
	float u_fe = facet_edge(p.xz * 0.55 + p.y * 0.04, 7.7);
	float u_joint = 1.0 - smoothstep(0.0, 0.090, u_fe);
	u_joint *= smoothstep(0.66, 0.82,
		vn(p.xz * 0.115 + vec2(11.3, -5.7)));
	float u_facet_n = vn(p.xz * 0.20 + vec2(-4.2, 7.1));
	float u_facet_pit = smoothstep(0.74, 0.90,
		vn(vec2(p.x * 4.1 + p.z * 2.7, p.y * 3.3)));
	vec3 u_facet = mix(rock_dark, vec3(0.118, 0.114, 0.109),
		0.32 + 0.30 * u_facet_n);
	u_facet *= 0.88 + 0.20 * u_facet_n;
	u_facet *= 1.0 - 0.72 * u_joint;
	u_facet *= 1.0 - 0.12 * u_facet_pit;
	u_facet *= 0.58;
	c = u_facet;
	// Restore the 0.05-1 m keel surface.  This is real rock grain and pitting,
	// not the removed calcite veins; the facet joints provide the large form.
	c *= mix(1.0, mix(0.82, 1.18, u1), 0.15 + 0.85 * u_close);
	c *= mix(1.0, mix(0.82, 1.18, u2), 0.20 + 0.80 * u_close);
	c *= mix(1.0, mix(0.85, 1.15, u3), 0.25 + 0.75 * u_close);
	c *= mix(1.0, mix(0.82, 1.18, u4), u_aa);
	c *= mix(1.0, mix(0.88, 1.12, u5), u_aa);
	float u6 = vn(vec2(p.x * 31.0 + p.z * 17.0, p.y * 12.0) * 30.0);
	c *= mix(1.0, mix(0.64, 1.36, u6), u_aa);
	// Vertical faces keep a little tooth and cross-fractures; horizontal
	// rounded masses let the Voronoi joints dominate.  The extra high-frequency
	// octave is weighted toward distance so the 5 m panel stays in its band
	// while the 20 m spire keeps the same screen-space energy.
	float u_d = distance(CAMERA_POSITION_WORLD, p);
	float u_far = smoothstep(7.0, 30.0, u_d);
	float u_vert = 1.0 - smoothstep(0.45, 0.75, abs(v_n.y));
	float u_vgrain = vn(vec2(p.x * 7.1 + p.z * 5.3, p.y * 12.0) * 16.0);
	c *= mix(1.0, mix(0.88, 1.12, u_vgrain), 0.13 * u_vert * u_aa);
	float u_cross = 1.0 - smoothstep(0.0, 0.050,
		abs(fract((p.y * 0.95 + p.x * 0.62 + p.z * 0.34) / 1.15) - 0.5));
	c *= 1.0 - 0.07 * u_cross * u_vert * u_aa;

	// Damp band under the waterline: darker and desaturated, never green.
	float wet = 1.0 - smoothstep(-1.8, -0.05, p.y);
	c = mix(c, damp_col, wet * 0.62);
	c *= 1.0 - 0.16 * wet;

	// Moss only in the top metre tucked under the grass lip.
	float lip = smoothstep(-1.05, -0.82, p.y) * (1.0 - smoothstep(-0.12, 0.08, p.y));
	float moss = lip * smoothstep(0.55, 0.80,
		vn(p.xz * 0.42 + vec2(4.6, -2.2)));
	c = mix(c, moss_col, moss * 0.34);

	float bottom = smoothstep(-18.0, -24.5, p.y);
	c *= 1.0 - 0.65 * bottom;

	// Neutral lifted stone; no warm ochre cast.
	float c_lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = mix(vec3(c_lum), c, 0.28) * 1.12 * vec3(1.02, 1.015, 1.00);
	// The unlit keel is tone-mapped up hard by ACES; without this it reads as
	// pale poured concrete from the 60-degree RPG camera.
	float slab_var = vn(p.xz * 0.95 + p.y * 0.21 + vec2(6.2, -3.1));
	c *= 0.58;
	c *= vec3(1.08, 1.02, 0.93);
	c *= 0.62 + 0.85 * slab_var;
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	METALLIC = 0.0;
}
