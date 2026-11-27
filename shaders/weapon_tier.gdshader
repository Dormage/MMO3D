// One shader for the six-slot weapon/shield tier vocabulary.
//
// The six slots are materials, not UV masks:
//   0 metal      1 metal_dark   2 wood    3 grip    4 trim    5 gem
//
// A tier is a set of six ShaderMaterials (one per slot) pointing at this
// shader with different parameters.  Wood always takes the wood path, so a
// tier never turns a haft into steel.  The placeholder and C's GLBs both use
// material slot names metal/metal_dark/wood/grip/trim/gem.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform int surface_kind = 0;

// Semantic slot colours.  Only the active slot's colour is used; a per-slot
// material sets the matching one (see manifest.json).
uniform vec3 metal_color : source_color = vec3(0.42, 0.44, 0.47);
uniform vec3 metal_dark_color : source_color = vec3(0.16, 0.17, 0.19);
uniform vec3 wood_color : source_color = vec3(0.42, 0.27, 0.15);
uniform vec3 grip_color : source_color = vec3(0.28, 0.18, 0.12);
uniform vec3 trim_color : source_color = vec3(0.38, 0.40, 0.42);
uniform vec3 gem_color : source_color = vec3(0.12, 0.13, 0.15);

uniform float metallic = 0.85;
uniform float roughness = 0.60;
uniform float specular = 0.35;

uniform vec3 patina_color : source_color = vec3(0.0);
uniform float patina_amount = 0.0;
uniform float wear = 0.0;

uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_strength = 0.0;

// Engraving: procedural bands along the local grain axis, optionally gated by
// UV2.x.  T5 uses clean gold bands; T6 uses broken runes/cracks.
uniform bool use_uv2_engraving = false;
uniform int engraving_style = 0; // 0 none, 1 gilded sparse, 2 cracks
uniform vec3 engraving_color : source_color = vec3(0.0);
uniform float engraving_strength = 0.0;
uniform float engraving_emission = 0.0;
uniform float engraving_scale = 18.0;
// The blade's broad face and its across-the-blade axis, in mesh-local space.
// The delivered blades have flats facing local X and width along local Z.
uniform vec3 engraving_plane_normal = vec3(1.0, 0.0, 0.0);
uniform vec3 engraving_width_axis = vec3(0.0, 0.0, 1.0);
uniform float engraving_full_width = 0.012;

uniform vec3 rim_color : source_color = vec3(0.0);
uniform float rim_strength = 0.0;
uniform float rim_power = 3.0;

// Wood / grip grain.  grain_axis is in mesh-local space; +Y is the weapon
// long axis in Godot, +Z in the Blender source (the exporter maps it).
uniform vec3 grain_axis = vec3(0.0, 1.0, 0.0);
uniform float grain_scale = 22.0;
uniform float grain_contrast = 0.0;
uniform vec3 grain_emission_color : source_color = vec3(0.0);
uniform float grain_emission = 0.0;

// T5 gilded joint banding on wooden shafts; also works as a wood inlay.
uniform vec3 band_color : source_color = vec3(0.0);
uniform float band_strength = 0.0;
uniform float band_freq = 9.0;

varying vec3 v_local;
varying vec3 v_local_normal;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	float x00 = mix(n000, n100, f.x);
	float x10 = mix(n010, n110, f.x);
	float x01 = mix(n001, n101, f.x);
	float x11 = mix(n011, n111, f.x);
	return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

float fbm(vec3 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec3(7.1, 3.7, 5.3);
		a *= 0.5;
	}
	return s;
}

void vertex() {
	v_local = VERTEX;
	v_local_normal = NORMAL;
}

void fragment() {
	vec3 axis = normalize(grain_axis);
	float along = dot(v_local, axis);
	vec3 perp = v_local - axis * along;

	vec3 col;
	float m = metallic;
	float r = roughness;
	float spec = specular;
	vec3 emit = vec3(0.0);

	if (surface_kind == 2) {
		// WOOD: grain runs along the shaft/bow limb.  It must stay wood at
		// every tier; tiers change stain, finish, gilding and the T6 grain
		// glow, never the identity.
		// Low frequency across the shaft, very low along it: the grain is a
		// set of long lines, not a blotch.  The sin term gives the fine
		// longitudinal figure; fbm makes it wander.
		float g = fbm(vec3(perp.x, perp.z, along * 0.04) * grain_scale);
		g = smoothstep(0.28, 0.78, g);
		float line = 0.5 + 0.5 * sin((perp.x + perp.z) * grain_scale * 1.6
				+ (g - 0.5) * 6.0);
		float grain = mix(g, line, 0.55);
		col = wood_color * mix(1.0 - grain_contrast, 1.0 + grain_contrast, grain);
		float grain_line = smoothstep(0.60, 0.96, grain);
		col *= 0.90 + 0.20 * grain_line;

		float band = smoothstep(0.86, 1.0, abs(sin(along * band_freq + 0.7)));
		band *= band_strength;
		col = mix(col, band_color, band);
		m = mix(0.0, 0.88, band);
		r = mix(clamp(roughness + (g - 0.5) * 0.08, 0.55, 0.80), 0.30, band);
		spec = mix(0.24, 0.62, band);

		// T6: near-black wood with a hot grain running the length.  Keep it
		// in the grain, not a whole-shaft glow.
		float hot_grain = smoothstep(0.58, 0.90, grain_line);
		emit += grain_emission_color * hot_grain * hot_grain * grain_emission;
	} else if (surface_kind == 3) {
		// GRIP: leather/cord.  Kept rough and non-metallic.
		float n = fbm(v_local * 34.0);
		col = grip_color * (0.86 + 0.28 * n);
		m = 0.0;
		r = clamp(roughness + (n - 0.5) * 0.06, 0.58, 0.90);
		spec = 0.18;
	} else if (surface_kind == 5) {
		// GEM: the only slot that glows by itself at T3/T4.  T4's larger read
		// comes from a stronger emissive core, not a different mesh.
		col = gem_color;
		m = 0.0;
		// The gem stays glossy only when its tier says so.  T1/T2 carry a
		// dull, dark socket (roughness 1.0, specular 0) instead of a
		// clipped white highlight on a gem they should not have yet.
		r = clamp(roughness, 0.04, 1.0);
		spec = specular;
		emit = emission_color * emission_strength;
		ALBEDO = col * 0.55;
		METALLIC = m;
		ROUGHNESS = r;
		SPECULAR = spec;
		EMISSION = emit;
	} else {
		// METAL / METAL_DARK / TRIM share the metal path.
		if (surface_kind == 0) {
			col = metal_color;
		} else if (surface_kind == 1) {
			col = metal_dark_color;
		} else {
			col = trim_color;
		}

		float wear_n = fbm(v_local * 7.0 + vec3(2.3, 1.7, 4.1));
		col *= mix(1.0 - wear * 0.35, 1.0, wear_n);

		// T2 patina blooms out of the worn recesses.
		float pat = smoothstep(0.30, 0.72, wear_n) * patina_amount;
		col = mix(col, patina_color, pat);

		// T5/T6 engraving.  Sparse, irregular and form-following: a central
		// fuller channel plus domain-warped noise runes (or thin cracks).
		// No repeating sine bands: a cone or a blade must not grow washers.
		float authored = use_uv2_engraving ? UV2.x : 0.0;
		float flat_mask = smoothstep(0.35, 0.72,
				abs(dot(normalize(v_local_normal), normalize(engraving_plane_normal))));
		float lateral = dot(v_local, normalize(engraving_width_axis));
		vec3 wp = v_local * engraving_scale;
		float w1 = fbm(wp * 0.47 + vec3(1.7, 3.1, 5.2));
		float w2 = fbm(wp * 0.73 + vec3(8.2, 2.3, 1.4));
		float w3 = fbm(wp * 1.21 + vec3(4.4, 7.7, 2.9));
		vec3 warp = vec3(w1, w2, w3) * 1.8;
		float n = fbm(wp * 0.85 + warp);
		float fuller = smoothstep(engraving_full_width,
				engraving_full_width * 0.22, abs(lateral)) * flat_mask;
		float rune = smoothstep(0.70, 0.76, n) * mix(0.35, 1.0, flat_mask);
		float filigree = smoothstep(0.74, 0.80,
				fbm(wp * 1.55 + warp * 1.7)) * mix(0.45, 1.0, flat_mask);
		float mask = 0.0;
		if (engraving_style == 1) {
			// Gilded: a fuller line and a few scroll/leaf marks, 10-18%.
			mask = max(fuller * 0.55, max(rune * 0.42, filigree * 0.30));
		} else if (engraving_style == 2) {
			// Cracked: a thin ridge where light shows through, plus the
			// fuller as a longer structural line.
			float ridge = 1.0 - smoothstep(0.0, 0.012, abs(n - 0.52));
			mask = max(fuller * 0.30, ridge * 0.75);
		}
		mask = max(mask, authored);
		mask = clamp(mask * engraving_strength, 0.0, 1.0);
		col = mix(col, engraving_color, mask * 0.90);
		emit += engraving_color * mask * engraving_emission;

		// Trim and legendary/primordial metal carry a view-facing rim term.
		float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), rim_power);
		emit += rim_color * fres * rim_strength;
		emit += emission_color * emission_strength;

		ALBEDO = col;
		METALLIC = m;
		ROUGHNESS = r;
		SPECULAR = spec;
		EMISSION = emit;
	}

	if (surface_kind != 5) {
		ALBEDO = col;
		METALLIC = m;
		ROUGHNESS = r;
		SPECULAR = spec;
		EMISSION = emit;
	}
}
