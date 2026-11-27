shader_type spatial;

// River water: three sine waves drive the motion, screen-space reflection gives
// it a real surface.
//
// The plane is flat, at the waterline, and intersects the terrain, so there are
// no UVs and no tangents to work from.  Everything is world-space.  Ground above
// the waterline hides the plane, ground below shows it, and scene depth is
// therefore the depth of the water column.
//
// The three waves are a long swell, a mid chop and a fine ripple.  Each has its
// own direction, wavelength, amplitude and speed, so they never stay in phase
// and the surface never visibly repeats.  The normal is the exact analytic
// derivative of those same sines rather than a finite difference, so shading and
// displacement cannot disagree.
//
// Reflection is a screen-space march against the depth buffer: the reflected
// view ray is stepped forward and the first point that lands behind already
// rendered geometry is sampled from the screen copy.  An analytic sky tint
// remains as the fallback wherever the ray leaves the screen or hits nothing,
// which matters because a river is mostly seen looking along its length, where
// the reflected bank is often off-screen.
//
// cull_back on purpose: this must not be visible from underneath the island.

render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.24, 0.62, 0.62, 1.0);
uniform vec4 deep_color : source_color = vec4(0.015, 0.115, 0.20, 1.0);
uniform vec4 foam_color : source_color = vec4(0.74, 0.84, 0.87, 1.0);
uniform vec4 sky_color : source_color = vec4(0.42, 0.56, 0.78, 1.0);

// wave = (dir_x, dir_z, wavelength_metres, amplitude_metres)
uniform vec4 wave_a = vec4(0.82, 0.57, 21.0, 0.045);
uniform vec4 wave_b = vec4(-0.42, 0.91, 8.5, 0.022);
uniform vec4 wave_c = vec4(0.96, -0.28, 3.2, 0.010);
// How fast each wave travels, in phase radians per second.
uniform vec3 wave_speed = vec3(0.55, 0.95, 1.60);
// Phase offsets so the three never start aligned.
uniform vec3 wave_phase = vec3(0.0, 2.1, 4.3);

// Metres of water over which the colour reaches full depth.
uniform float depth_scale = 1.6;
// Water depth over which shoreline foam fades out.
uniform float foam_depth = 0.22;
uniform float sun_energy = 1.35;
uniform float alpha_shallow = 0.86;
// Poison-water glow.  Kept separate from the reflection path so the mirror
// still reads as water; this only lifts the emissive floor.
uniform vec4 glow_color : source_color = vec4(0.16, 1.0, 0.34, 1.0);
// Poison-stew bubbles.  Each grid cell rolls its own bubble event on its own
// clock, and only some cells ever fire, so the surface pops here and there
// instead of boiling everywhere at once.
uniform float bubble_strength = 0.0;
uniform float bubble_scale = 3.2;      // metres per cell
uniform float bubble_density = 0.16;   // fraction of cells that ever bubble
uniform float bubble_speed = 0.30;
uniform vec4 bubble_color : source_color = vec4(0.55, 1.0, 0.62, 1.0);
uniform float glow_strength = 0.0;
uniform float alpha_deep = 0.97;

// Ambient occlusion.  The scene's SSAO never reaches this surface: it is
// transparent, and Godot's SSAO only shades opaque geometry.  So the water
// computes its own, from the same depth buffer.
uniform float ao_strength = 0.55;
// World radius of the occlusion search, in metres.
uniform float ao_radius = 1.4;

// How strongly the reflected image is mixed in.
uniform float reflection_strength = 1.0;
// Blur applied to the reflected sample; more on rough/far water.
uniform float reflection_blur = 0.010;
// How bumpy the reflected image is.  Ripples distort the mirror.
uniform float reflection_distort = 0.035;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
// Screen-space reflection cannot work at arm's length -- the reflected geometry
// is behind the viewer -- so close-up water (fountain basins) needs the engine's
// reflection probe.  Raising this hands the reflection to the PBR path, which
// samples the environment cubemap at any distance.
uniform float env_reflect = 0.0;

varying vec3 world_pos;
// The plane's own waterline, so reflection hits can be rejected if they are
// below it.  Everything under the surface is the bed, not something to mirror.
varying float base_y;

vec3 wave_phase_at(vec2 p, float t) {
	vec2 dir_a = normalize(wave_a.xy);
	vec2 dir_b = normalize(wave_b.xy);
	vec2 dir_c = normalize(wave_c.xy);
	return vec3(
			dot(dir_a, p) * (6.2831853 / wave_a.z) + t * wave_speed.x + wave_phase.x,
			dot(dir_b, p) * (6.2831853 / wave_b.z) + t * wave_speed.y + wave_phase.y,
			dot(dir_c, p) * (6.2831853 / wave_c.z) + t * wave_speed.z + wave_phase.z);
}

float wave_height(vec2 p, float t) {
	vec3 ph = wave_phase_at(p, t);
	return sin(ph.x) * wave_a.w + sin(ph.y) * wave_b.w + sin(ph.z) * wave_c.w;
}

// Analytic gradient: d/dp of A*sin(k*dot(dir,p) + ...) = A*k*dir*cos(phase).
vec2 wave_gradient(vec2 p, float t) {
	vec3 ph = wave_phase_at(p, t);
	vec2 dir_a = normalize(wave_a.xy);
	vec2 dir_b = normalize(wave_b.xy);
	vec2 dir_c = normalize(wave_c.xy);
	vec3 k = vec3(6.2831853 / wave_a.z, 6.2831853 / wave_b.z, 6.2831853 / wave_c.z);
	vec3 amp = vec3(wave_a.w, wave_b.w, wave_c.w);
	vec3 c = cos(ph) * k * amp;
	return dir_a * c.x + dir_b * c.y + dir_c * c.z;
}

float bubble_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Accumulates every bubble overlapping this point.
//   xy = surface slope, z = dome body, w = bright ring / highlight
vec4 bubble_field(vec2 p, float t) {
	vec4 acc = vec4(0.0);
	vec2 cellp = p / bubble_scale;
	vec2 base = floor(cellp);
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 cell = base + vec2(float(i), float(j));
			float h = bubble_hash(cell);
			if (h > bubble_density) continue;
			float h2 = bubble_hash(cell + 17.0);
			float h3 = bubble_hash(cell + 43.0);
			float speed = bubble_speed * (0.7 + h2 * 0.8);
			float phase = fract(t * speed + h3);
			if (phase > 0.45) continue;
			float life = phase / 0.45;
			vec2 centre = cell + vec2(h2, h3) * 0.7 + 0.15;
			vec2 d = (cellp - centre) * bubble_scale;
			float r = length(d);
			// A bubble grows, holds, then bursts into a wider thin ring.
			float grow = smoothstep(0.0, 0.45, life);
			float radius = mix(0.04, 0.42, grow);
			float burst = smoothstep(0.80, 1.0, life);
			radius *= 1.0 + burst * 1.35;
			float nt = clamp(r / max(radius, 0.001), 0.0, 1.0);
			// Spherical profile: slope steepens toward the rim of the dome.
			float sphere = sqrt(max(0.0, 1.0 - nt * nt));
			float slope = nt / max(sphere, 0.35);
			// Solid while whole, hollow once it bursts into a ring.
			float body = (1.0 - nt) * (1.0 - burst);
			// Thin bright rim, plus a specular highlight up and left of centre.
			float rim = smoothstep(0.62, 0.93, nt) * (1.0 - smoothstep(0.93, 1.0, nt));
			rim *= 0.5 + burst * 0.8;
			vec2 hi = d - vec2(-radius * 0.34, radius * 0.34);
			float speck = 1.0 - smoothstep(0.0, radius * 0.22, length(hi));
			float fade = sin(life * 3.14159265);
			float amp = fade;
			if (r > 0.0001) {
				acc.xy += (d / r) * slope * body * amp * 0.55;
			}
			acc.z += body * amp;
			acc.w += clamp(rim + speck, 0.0, 1.5) * amp;
		}
	}
	return acc;
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	base_y = wp.y;
	wp.y += wave_height(wp.xz, TIME);
	world_pos = wp;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
}

// World position of whatever opaque geometry is behind this pixel.
// Matrices are passed in: stage built-ins such as INV_VIEW_MATRIX only exist
// inside fragment()/vertex(), not in user-defined functions.
vec3 world_from_depth(vec2 uv, mat4 inv_proj, mat4 inv_view) {
	float raw = texture(depth_tex, uv).r;
	vec4 vp = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	vp.xyz /= vp.w;
	return (inv_view * vec4(vp.xyz, 1.0)).xyz;
}

// View-space depth of whatever opaque geometry is behind this pixel.
//
// The inverse projection matrix is passed in rather than read as a built-in:
// stage built-ins such as INV_PROJECTION_MATRIX only exist inside fragment()
// and vertex(), not inside user-defined functions.
float depth_at(vec2 uv, mat4 inv_proj) {
	float raw = texture(depth_tex, uv).r;
	vec4 vp = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	vp.xyz /= vp.w;
	return -vp.z;
}

void fragment() {
	// --- normal from the same three sines --------------------------------
	vec2 grad = wave_gradient(world_pos.xz, TIME);
	// Bubbles tilt the surface outward, so they refract the reflection too.
	vec4 bub = bubble_field(world_pos.xz, TIME) * bubble_strength;
	grad += bub.xy;
	vec3 n_world = normalize(vec3(-grad.x, 1.0, -grad.y));
	float bub_mask = clamp(bub.z, 0.0, 1.0);
	float bub_bright = clamp(bub.w, 0.0, 1.5);

	// --- water column depth ----------------------------------------------
	float self_z = -VERTEX.z;
	float bed_z = depth_at(SCREEN_UV, INV_PROJECTION_MATRIX);
	float thickness = max(bed_z - self_z, 0.0);
	float depth01 = clamp(thickness / depth_scale, 0.0, 1.0);

	vec3 body = mix(shallow_color.rgb, deep_color.rgb, smoothstep(0.0, 1.0, depth01));

	// --- shoreline foam ---------------------------------------------------
	float crest = sin(wave_phase_at(world_pos.xz, TIME).x) * 0.5 + 0.5;
	float shore = 1.0 - smoothstep(0.0, foam_depth, thickness);
	float foam = shore * smoothstep(0.30, 0.80, crest);
	foam += (1.0 - smoothstep(0.0, foam_depth * 0.30, thickness))
			* smoothstep(0.50, 0.92, crest) * 0.65;
	foam = clamp(foam, 0.0, 1.0);

	// --- view / fresnel ---------------------------------------------------
	vec3 V = normalize(CAMERA_POSITION_WORLD - world_pos);
	float ndv = clamp(dot(vec3(0.0, 1.0, 0.0), V), 0.0, 1.0);
	float fresnel = mix(0.02, 0.72, pow(1.0 - ndv, 4.0));

	// --- ambient occlusion ------------------------------------------------
	// Horizon-based: sample the depth buffer in a ring around this pixel.  Any
	// sample whose geometry stands ABOVE the waterline is an occluder blocking
	// part of the sky hemisphere, so the river in its lee loses ambient light.
	// The ring radius is converted from world metres to screen UV using the
	// projection scale, otherwise the same shader would give tight AO on close
	// water and enormous AO on distant water.
	float ao = 1.0;
	if (ao_strength > 0.0) {
		float view_depth = max(-VERTEX.z, 0.15);
		float uv_radius = ao_radius * PROJECTION_MATRIX[1][1] / (2.0 * view_depth);
		uv_radius = clamp(uv_radius, 0.0015, 0.06);
		float occlusion = 0.0;
		float weight_sum = 0.0;
		// Two rings, eight directions.  The far ring catches a bank further up
		// the shore; the near ring catches rocks and roots at the waterline.
		for (int ring = 1; ring <= 2; ring++) {
			float r = uv_radius * float(ring);
			float ring_weight = ring == 1 ? 1.0 : 0.55;
			for (int i = 0; i < 8; i++) {
				float ang = float(i) * 0.7853982;
				vec2 off = vec2(cos(ang), sin(ang)) * r;
				vec2 uv = SCREEN_UV + off;
				if (uv.x < 0.002 || uv.x > 0.998 || uv.y < 0.002 || uv.y > 0.998) continue;
				vec3 wp = world_from_depth(uv, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
				float rise = wp.y - base_y;
				if (rise > 0.0) {
					// Prominence over distance: a tall near bank occludes far more
					// of the sky than a low one further away.
					float dist = length(wp.xz - world_pos.xz);
					occlusion += clamp(rise / max(dist, 0.25), 0.0, 1.0) * ring_weight;
				}
				weight_sum += ring_weight;
			}
		}
		if (weight_sum > 0.0) {
			occlusion /= weight_sum;
		}
		ao = 1.0 - clamp(occlusion * ao_strength, 0.0, 0.72);
	}

	// --- screen-space reflection -----------------------------------------
	vec3 R_world = reflect(-V, n_world);
	vec3 sky = sky_color.rgb * mix(0.55, 1.25, clamp(R_world.y, 0.0, 1.0));

	vec3 view_origin = (VIEW_MATRIX * vec4(world_pos, 1.0)).xyz;
	vec3 view_R = normalize((VIEW_MATRIX * vec4(R_world, 0.0)).xyz);
	float view_dist = distance(CAMERA_POSITION_WORLD, world_pos);

	// Ripple distortion of the sample UV, in world-normal direction.
	vec2 distort = n_world.xz * reflection_distort;
	float rough = smoothstep(4.0, 42.0, view_dist);
	float lod = mix(2.0, 5.0, rough);
	float spread = mix(reflection_blur * 0.4, reflection_blur * 2.2, rough) + reflection_blur;

	vec3 reflected = sky;
	float hit = 0.0;
	float edge_fade = 0.0;
	float t = 0.6;
	for (int i = 0; i < 20; i++) {
		vec3 p = view_origin + view_R * t;
		if (p.z > -0.05) break;
		vec4 clip = PROJECTION_MATRIX * vec4(p, 1.0);
		vec2 ruv = clip.xy / max(clip.w, 0.0001) * 0.5 + 0.5;
		if (ruv.x < 0.01 || ruv.x > 0.99 || ruv.y < 0.01 || ruv.y > 0.99) break;
		// Never let a pixel reflect its own neighbourhood back into itself.
		if (distance(ruv, SCREEN_UV) < 0.012) { t += 0.6 + t * 0.16; continue; }
		float scene_z = depth_at(ruv, INV_PROJECTION_MATRIX);
		// Reject the water surface and its own depth slice.
		if (abs(scene_z - self_z) < 0.45) { t += 0.6 + t * 0.16; continue; }
		if (scene_z < -p.z - 0.035) {
			// Reject anything below the waterline: that is the bed, and mirroring
			// it produces dark rings instead of a reflection.
			vec3 hit_world = (INV_VIEW_MATRIX * vec4(p, 1.0)).xyz;
			if (hit_world.y < base_y + 0.10) { t += 0.6 + t * 0.16; continue; }
			vec2 duv = clamp(ruv + distort, vec2(0.01), vec2(0.99));
			// Five taps plus a ceiling: single bright pixels (flowers, cloth,
			// cloud edges) otherwise become white specks floating on the river.
			vec3 sc = vec3(0.0);
			sc += textureLod(screen_tex, clamp(duv + vec2(spread, 0.0), vec2(0.01), vec2(0.99)), lod).rgb;
			sc += textureLod(screen_tex, clamp(duv + vec2(-spread, 0.0), vec2(0.01), vec2(0.99)), lod).rgb;
			sc += textureLod(screen_tex, clamp(duv + vec2(0.0, spread), vec2(0.01), vec2(0.99)), lod).rgb;
			sc += textureLod(screen_tex, clamp(duv + vec2(0.0, -spread), vec2(0.01), vec2(0.99)), lod).rgb;
			sc += textureLod(screen_tex, duv, lod).rgb;
			sc *= 0.2;
			reflected = min(sc, vec3(0.80));
			hit = 1.0;
			float ex = smoothstep(0.01, 0.10, ruv.x) * smoothstep(0.99, 0.90, ruv.x);
			float ey = smoothstep(0.01, 0.10, ruv.y) * smoothstep(0.99, 0.90, ruv.y);
			edge_fade = ex * ey;
			break;
		}
		t += 0.6 + t * 0.16;
	}

	// Screen-space reflection is unreliable very close to the camera, where the
	// reflected geometry is behind the viewer.  Fade to the sky tint there.
	float near_fade = smoothstep(2.0, 9.0, view_dist);
	vec3 refl = mix(sky, reflected, hit * edge_fade * near_fade);

	// --- sun glint --------------------------------------------------------
	vec3 L = normalize(vec3(0.55, 0.72, 0.42));
	float spec = pow(max(dot(n_world, normalize(V + L)), 0.0), 220.0);
	float spec_wide = pow(max(dot(n_world, normalize(V + L)), 0.0), 26.0);
	vec3 glint = vec3(1.0, 0.98, 0.92) * (spec * 0.55 + spec_wide * 0.06) * sun_energy;

	// --- combine ----------------------------------------------------------
	// Reflection rides on top of the body colour rather than replacing it, so
	// deep water keeps its colour where the mirror is weak.
	float refl_amount = clamp(0.06 + fresnel * 0.80, 0.0, 0.92) * reflection_strength;
	// AO multiplies the body colour only.  Darkening the reflected image as well
	// would grey out the mirror and make the banks look dirty rather than shaded.
	vec3 col = body * ao;
	col = mix(col, refl, refl_amount);
	col += glint * (0.35 + fresnel);
	col = mix(col, foam_color.rgb, foam * 0.62);
	float h01 = wave_height(world_pos.xz, TIME) * 6.0 + 0.5;
	col *= 0.96 + 0.08 * clamp(h01, 0.0, 1.0);
	col = min(col, vec3(0.80));

	ALBEDO = col;
	ALPHA = mix(alpha_shallow, alpha_deep, depth01);
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	// env_reflect moves the reflection from the screen-space march to the PBR
	// path, which samples the scene cubemap and therefore still works when the
	// viewer is standing right next to the surface.
	float er = clamp(env_reflect, 0.0, 1.0);
	ROUGHNESS = mix(0.06, 0.20, depth01) * (1.0 - er * 0.75) ;
	METALLIC = er * 0.30;
	SPECULAR = mix(0.55, 1.0, er);
	// Glow rides strongest in the shallows and through the wave crests, so the
	// surface pulses instead of reading as a flat slab of light.
	float glow_mod = 0.62 + 0.38 * clamp(h01, 0.0, 1.0);
	// Bubble domes catch the glow and read as pale froth on top of it.
	// Body darkens the film slightly, then the rim and highlight punch through.
	col *= 1.0 - bub_mask * 0.18;
	col += bubble_color.rgb * bub_bright * 0.55;
	EMISSION = body * 0.13 + glow_color.rgb * glow_strength * glow_mod
			+ bubble_color.rgb * (bub_bright * 0.60 + bub_mask * 0.18);
}
