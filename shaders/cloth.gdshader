shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Cloth family for camp banners and tent canvas.
// UV space is used deliberately: BoxMesh/PrismMesh both carry a 0..1 face UV
// even though their world-space dimensions differ, so the weave and hem stay
// attached to the fabric instead of swimming when the prop is moved.
uniform vec4 cloth_color : source_color = vec4(0.55, 0.34, 0.30, 1.0);
uniform float sway_amount = 0.0;
uniform float hem_amount = 1.0;
uniform float seed = 0.0;
uniform float weave_strength = 1.0;
varying vec3 v_world;
varying vec3 v_local;

float h12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_local = VERTEX;
	// The pole edge stays fixed; the free edge and lower hem travel.  Two
	// frequencies keep it from reading as a rigid pendulum.
	float hang = clamp(1.0 - UV.y, 0.0, 1.0);
	float ph = TIME * 1.25 + seed * 6.2831
			+ MODEL_MATRIX[3].x * 0.23 + MODEL_MATRIX[3].z * 0.17;
	float w1 = sin(ph + UV.x * 2.1 + UV.y * 1.3);
	float w2 = sin(ph * 1.73 + UV.x * 5.2 - UV.y * 2.4);
	VERTEX.x += w1 * sway_amount * hang * hang;
	VERTEX.z += w2 * sway_amount * 0.42 * hang;
	// A fixed, asymmetric scallop in the lower free edge.  This is visible at
	// 22 m even when the wind phase happens to be near zero.
	VERTEX.x += sin(UV.x * 6.2831 * 2.8 + seed * 1.7) * 0.130 * hang * hang;
	// A shallow 3D wave across the banner so the 20 m silhouette is not a
	// rectangle; tents pass sway=0 and keep their tailored planes.
	if (sway_amount > 0.001) {
		VERTEX.z += sin(UV.x * 6.2831 * 2.35 + seed) * 0.120
				* sin(UV.y * 3.14159);
	}
}

void fragment() {
	vec2 uv = UV;
	float fw = max(fwidth(uv.x), fwidth(uv.y));
	float cam_dist = length((VIEW_MATRIX * vec4(v_world, 1.0)).xyz);

	// Coarse drape: 2-3 broad folds across a banner.  This is what survives
	// the 20 m silhouette; the fine weave is faded by its own footprint.
	// World-space drape so the folds stay physically scaled on the 2.6 m tent
	// and the 1.35 m banner, independent of each mesh's UV parameterisation.
	vec3 pw = v_world;
	float fold_a = sin(pw.x * 4.2 + pw.z * 1.3 + pw.y * 1.0 + seed);
	float fold_b = sin(pw.x * 2.1 - pw.z * 0.8 - pw.y * 1.7 + seed * 2.0);
	float drape = fold_a * 0.70 + fold_b * 0.30;

	// Plain weave: two crossed thread sets.  At 3 m this resolves; at 20 m
	// fwidth pushes it below the pixel and only the coarse drape remains.
	float wx = uv.x * 150.0 + seed * 17.0;
	float wy = uv.y * 230.0;
	float warp = sin(wx * 6.2831);
	float weft = sin(wy * 6.2831 + warp * 0.22);
	float weave = (warp * weft) * 0.5 + 0.5;
	float weave_fade = 1.0 - smoothstep(0.0025, 0.0090, fw);
	weave_fade *= 1.0 - smoothstep(4.0, 13.0, cam_dist);
	float micro = sin((uv.x * 0.80 + uv.y * 1.20) * 6.2831 * 7.0);
	float mott = h12(floor(uv * 96.0));
	mott = mix(mott, 0.5, 0.65);

	// Visible border: a darker sewn hem around the rectangle plus one lighter
	// stitch line just inside it.  Tents pass hem_amount = 0.
	// Use the banner's local metres rather than UV: both PlaneMesh and
	// BoxMesh agree on VERTEX, while their UV orientation differs.
	float edge = min(0.675 - abs(v_local.x), 0.360 - abs(v_local.y));
	edge = clamp(edge, 0.0, 1.0);
	float hem = 1.0 - smoothstep(0.070, 0.092, edge);
	float stitch = smoothstep(0.050, 0.056, edge) * (1.0 - smoothstep(0.062, 0.070, edge));
	hem *= hem_amount;
	stitch *= hem_amount;

	vec3 col = cloth_color.rgb;
	col *= 0.660 + 0.600 * (drape * 0.5 + 0.5);
	// Two authored vertical creases.  They read at 3 m even when the sun is
	// nearly frontal and the broad drape would otherwise wash out.
	float crease = (1.0 - smoothstep(0.018, 0.070, abs(uv.x - 0.27)))
			+ (1.0 - smoothstep(0.018, 0.070, abs(uv.x - 0.62)));
	crease *= smoothstep(0.03, 0.16, uv.y) * (1.0 - smoothstep(0.86, 0.99, uv.y));
	col *= 1.0 - crease * 0.52;
	col *= 1.0 + (weave - 0.5) * 0.280 * weave_fade * weave_strength;
	col *= 1.0 + micro * 0.018 * weave_fade;
	col *= 0.965 + mott * 0.070;
	col *= 1.0 - hem * 0.78;
	col = mix(col, col * 1.22, stitch * 0.55);

	// Tangent-space normal from the same fields.  Broad folds dominate the
	// lighting; the weave adds the close-up grain only.
	vec3 n = vec3(drape * 0.58 + (weave - 0.5) * 0.20 * weave_fade * weave_strength,
			fold_b * 0.16, 1.0);
	NORMAL_MAP = normalize(n);
	NORMAL_MAP_DEPTH = 0.85;

	ALBEDO = col;
	ROUGHNESS = 0.97;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	// A small emissive floor keeps the shaded side from crushing to black at
	// the dark end of the frame; it is much lower than the old unshaded slab.
	EMISSION = col * (0.55 + drape * 0.22 + (weave - 0.5) * 0.20 * weave_fade * weave_strength);
}
