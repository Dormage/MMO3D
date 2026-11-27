shader_type sky;

// Lower hemisphere is a cloud sea, not a ground plane.
// Direction-space fbm is projected onto a virtual layer at cloud_height below
// the eye; the projection gives near clouds larger structure and the horizon
// smaller, faster-receding structure.  The layer is banded by altitude, so
// looking straight down reaches dark depth instead of a hard floor.
//
// Palette deliberately matches the CloudSea autoload sheets at -80 m:
// top_color 0.94,0.92,0.88 / under_color 0.38,0.48,0.64 / fog 0.66,0.73,0.84.

uniform vec4 sky_top_color : source_color = vec4(0.300, 0.340, 0.400, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.300, 0.340, 0.400, 1.0);
uniform vec4 horizon_haze : source_color = vec4(0.300, 0.340, 0.400, 1.0);
uniform vec4 cloud_top_color : source_color = vec4(0.86, 0.89, 0.91, 1.0);
uniform vec4 cloud_under_color : source_color = vec4(0.255, 0.345, 0.475, 1.0);
uniform vec4 cloud_deep_color : source_color = vec4(0.025, 0.040, 0.070, 1.0);
uniform vec4 sun_color : source_color = vec4(1.0, 0.93, 0.82, 1.0);

uniform float sky_curve = 0.12;
uniform float sky_energy = 1.0;
uniform float coverage = 0.38;
uniform float cloud_scale = 0.030;
uniform float cloud_height = 70.0;
uniform float drift_speed = 0.010;
uniform float drift_dir_x = 0.82;
uniform float drift_dir_z = 0.34;
uniform float silver_strength = 0.30;
uniform float horizon_glow_strength = 0.40;
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
			mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(7.1, 3.7);
		a *= 0.5;
	}
	return v;
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

void sky() {
	float y = EYEDIR.y;
	float up = clamp(y, 0.0, 1.0);
	float inv_curve = 1.0 / max(sky_curve, 0.001);

	// Upper hemisphere: a warmer, brighter horizon than the deep top, with
	// three very low-contrast projected cloud layers above it.
	// Exponential angle ramp: continuous derivative all the way into the
	// horizon.  The old pow(1-up, 1/0.12) flattened to a constant strip in the
	// last 10-15 degrees, which read as a horizontal shelf above the haze.
	float sky_ramp = 1.0 - exp(-up * 6.0);
	// Horizon is the brighter violet; the zenith drops toward a deeper,
	// less saturated violet so the top of frame is never a flat bright slab.
	vec3 upper = mix(sky_horizon_color.rgb * 0.85, sky_top_color.rgb * 0.72, sky_ramp);
	// Dusk horizon: violet, lighter and slightly warmer than the top, but with
	// blue still dominant so cloud edges never go brown.
	// A narrow additive dusk tint, not a constant plateau: the old
	// smoothstep(0,0.26) blend held the same colour for the bottom 15 degrees
	// and produced a flat strip above the horizon.  This term decays with
	// altitude and leaves the main zenith-horizon ramp intact.
	vec3 warm_horizon = mix(horizon_haze.rgb, vec3(0.290, 0.265, 0.350), 0.05);
	upper += (warm_horizon - sky_horizon_color.rgb)
		* exp(-up * 14.0) * 0.50;

	// Cloud layers are projected onto a virtual plane: near the horizon they
	// compress into horizontal bands, overhead they open into broad soft
	// structure.  Drift is deliberately slow; TIME is free here.
	vec2 cuv = EYEDIR.xz / max(EYEDIR.y, 0.14);
	float ct = TIME * drift_speed;
	float c1 = fbm(cuv * 0.55 + vec2(ct * 0.80, ct * 0.25));
	float c2 = fbm(cuv * 1.25 + vec2(-ct * 0.35, ct * 0.60) + vec2(7.3, 2.1));
	float c3 = fbm(cuv * 2.60 + vec2(ct * 0.90, -ct * 0.40) + vec2(15.7, 4.4));
	float cloud_field = c1 * 0.55 + c2 * 0.30 + c3 * 0.15;
	float lo = 0.52 - coverage * 0.10;
	float hi = 0.78 - coverage * 0.08;
	float cloud_mask = smoothstep(lo, hi, cloud_field);
	cloud_mask *= smoothstep(0.04, 0.26, up);
	cloud_mask *= 1.0 - smoothstep(0.86, 1.0, up) * 0.45;
	vec3 cloud_warm = vec3(0.195, 0.218, 0.282);
	vec3 cloud_cool = vec3(0.145, 0.170, 0.235);
	vec3 cloud_col = mix(cloud_warm, cloud_cool, smoothstep(0.0, 0.70, up));
	cloud_col *= 0.94 + 0.10 * c2;
	upper = mix(upper, cloud_col, cloud_mask * 0.14);

	// High cloud streaks concentrated just above the horizon.  They are
	// stretched in azimuth and compressed in altitude, so they read as soft
	// horizontal bands behind the treeline rather than as overhead blobs.
	float az = atan(EYEDIR.z, EYEDIR.x);
	float band_h = exp(-pow((up - 0.06) / 0.045, 2.0))
			+ 0.40 * exp(-pow((up - 0.14) / 0.08, 2.0));
	vec2 suv = vec2(az * 2.8 + TIME * 0.006, up * 22.0);
	float s1 = fbm(suv * vec2(1.4, 1.0) + vec2(2.7, 1.1));
	float s2 = fbm(suv * vec2(2.8, 1.8) + vec2(-4.2, TIME * 0.004));
	float streak = smoothstep(0.42, 0.70, s1 * 0.65 + s2 * 0.35);
	float band_mask = band_h * smoothstep(0.012, 0.035, up) * streak;
	vec3 high_cloud = mix(vec3(0.230, 0.207, 0.280),
			vec3(0.300, 0.270, 0.380), smoothstep(0.15, 0.90, s1));
	upper = mix(upper, high_cloud, band_mask * 0.24);

	// Sparse, static dust specks high up.  Thresholded hash cells, not a
	// twinkling star field: a few pinpricks survive at the top of frame.
	vec2 sgrid = floor(EYEDIR.xz * 95.0 + vec2(11.0, 7.0));
	float sr = hash21(sgrid);
	float speck = smoothstep(0.997, 0.9995, sr) * smoothstep(0.60, 0.92, up);
	upper += vec3(0.18, 0.16, 0.24) * speck * 0.75;

	// Gentle warm/cool bias across the frame: +X is a touch warmer, -X a
	// touch cooler.  Small enough to preserve the violet reading.
	float side = clamp(EYEDIR.x * 0.6 + 0.5, 0.0, 1.0);
	upper *= mix(vec3(1.035, 1.000, 0.970), vec3(0.970, 1.000, 1.035), side);

	// A soft sun glow, no hard clipped disc.
	vec3 L = normalize(LIGHT0_DIRECTION);
	float sd = max(dot(L, EYEDIR), 0.0);
	// Void fallback: no broad horizon glow, or the lower hemisphere reads as
	// a pale plane meeting the sea at a hard line.
	upper += sun_color.rgb * sky_energy * 0.0;

	float down = clamp(-y, 0.0, 1.0);
	// The island-wide camera looks down far enough that every background ray
	// is below the horizon.  Continue the same violet sky ramp there instead
	// of a flat grey void, otherwise the wide and lane cameras disagree.
	// Match the upper horizon's darker value.  The old lower hemisphere used
	// the full-bright haze colour while the upper used 0.55x, so the eye-level
	// blend produced the pale flat shelf even after the upper ramp was fixed.
	// The space under the floating islands is a deep chasm, not a backplate.
	// A warm, denser haze hugs the horizon and falls monotonically into near-
	// black; the old exponential saturated by down=0.5 and left a flat shelf.
	// Deep muted purple.  The old horizon shelf was 0.36-0.45 luminance and
	// stayed near-bright out to ~30 degrees below the horizon, so the shallow
	// 5 m camera saw a flat lavender wash.  Keep only a narrow ~1-6 degree
	// transition and drop to the deep chasm by ~12 degrees.
	// Deep violet chasm authored for the 60-degree RPG camera.  Hue ~254 deg,
	// saturation 0.38-0.40, luminance falling with screen depth.  No pale
	// horizon shelf: the upper frame is ~0.10 and the lower is ~0.03.
	vec3 violet_top = hsv2rgb(vec3(0.704, 0.46, 0.052));
	vec3 violet_bot = hsv2rgb(vec3(0.696, 0.28, 0.0080));
	float vframe = smoothstep(0.55, 0.98, down);
	vec3 lower = mix(violet_top, violet_bot, vframe);
	// Soft, non-repeating haze/cloud banks: broad fbm in view space, scaled
	// stable with depth so it does not collapse into flat fog.
	vec2 hz = EYEDIR.xz / max(down, 0.32);
	float h1 = fbm(hz * 1.10 + vec2(TIME * 0.004, 7.3));
	float h2 = fbm(hz * 2.30 + vec2(-3.1, TIME * 0.003));
	float haze = h1 * 0.64 + h2 * 0.36;
	lower *= 0.82 + 0.30 * haze;
	lower += vec3(0.010, 0.003, 0.016) * (haze - 0.5);
	lower += vec3(0.012, 0.004, 0.020) * exp(-down * 4.0);
	vec3 haze_col = hsv2rgb(vec3(0.700, 0.34, 0.170));
	lower = mix(lower, haze_col,
		smoothstep(0.44, 0.76, haze) * 0.24 * (1.0 - 0.30 * vframe));
	// No azimuthal "upward shafts".  The sin(az*17)^12 columns were the hard
	// purple curtains running top-to-bottom through the void in the 170 m view.
	// A faint continuation of the horizon cloud band below the horizon keeps
	// the wide archipelago view from becoming a clean empty gradient.
	float lowband = exp(-pow(down / 0.10, 2.0));
	float lowstreak = smoothstep(0.46, 0.74,
			fbm(vec2(az * 3.0, down * 30.0) + vec2(TIME * 0.004, 3.7)));
	lower = mix(lower, vec3(0.105, 0.085, 0.145), lowband * lowstreak * 0.26);
	// Desaturate more with depth: the top stays violet (S ~0.34) while the
	// near-black bottom does not collapse into a saturated neon purple.
	float desat = mix(0.66, 0.46, vframe);
	lower = mix(vec3(dot(lower, LUMA)), lower, desat);
	// Hold the bottom of the chasm down; shafts live mostly in the upper banks.
	lower *= mix(1.0, 0.62, vframe);
	// Smooth the eye-level seam instead of switching upper/lower on one pixel.
	float hb = smoothstep(-0.10, 0.10, y);
	// 1/255 ordered-ish dither: the dusk ramp is shallow enough to band in
	// 8-bit after ACES; this is invisible contrast but breaks the stair steps.
	float dth = fract(sin(dot(EYEDIR.xz * 1733.0, vec2(12.9898, 78.233))) * 43758.5453);
	COLOR = mix(lower, upper, hb) + vec3((dth - 0.5) / 255.0);
}
