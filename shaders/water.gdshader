shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

#include "res://shaders/depth_compat.gdshaderinc"

// Minimal pond water.  One view-dependent fresnel term, one uniform sky colour,
// one scene-depth body blend, one sun specular, two rotated value-noise octaves
// that only perturb NORMAL, and a thin depth-based foam line.  Opaque.

uniform vec4 shallow_color : source_color = vec4(0.170, 0.480, 0.445, 1.0);
uniform vec4 deep_color : source_color = vec4(0.003, 0.022, 0.060, 1.0);
uniform vec4 sky_reflect_color : source_color = vec4(0.10, 0.17, 0.30, 1.0);
uniform vec4 foam_color : source_color = vec4(0.72, 0.78, 0.86, 1.0);
uniform vec3 sun_dir = vec3(0.624, 0.469, 0.624);
uniform float depth_scale = 0.55;
uniform float spec_strength = 1.20;
uniform int debug_channel = 0;
uniform vec2 pond_center = vec2(0.0);
uniform float pond_radius = 8.0;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
// Screen colour is a backbuffer copy in Godot Forward+.  It is used for a
// short screen-space reflection march; if the reflected ray misses, the
// analytic sky colour remains as the fallback.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

varying vec3 world_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

mat2 rot2(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat2(vec2(c, s), vec2(-s, c));
}

// Two octaves: 0.15 m and 1.2 m.  Each octave has its own rotation and offset
// so the value-noise cells are not aligned to world X/Z (or to each other).
float ripple(vec2 p) {
	vec2 a = rot2(0.61) * p * (1.0 / 0.15) + vec2(13.1, 7.7);
	vec2 b = rot2(1.97) * p * (1.0 / 1.20) + vec2(41.3, 19.9);
	return vnoise(a) * 0.86 + vnoise(b) * 0.14;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Ripples only perturb NORMAL.  World XZ, no UV, no colour modulation.
	vec2 q = world_pos.xz + vec2(TIME * 0.035, -TIME * 0.021);
	float e = 0.020;
	float h0 = ripple(q);
	float hx = ripple(q + vec2(e, 0.0));
	float hz = ripple(q + vec2(0.0, e));
	// A third, finer layer drifts at a different speed and direction.  It
	// breaks the value-noise cells so the surface never looks like one tiled
	// ripple texture, without adding a second specular highlight.
	vec2 qf = rot2(-0.93) * q * 2.7 + vec2(-TIME * 0.061, TIME * 0.044);
	float f0 = vnoise(qf);
	float fx = vnoise(qf + vec2(e * 2.7, 0.0));
	float fz = vnoise(qf + vec2(0.0, e * 2.7));
	vec3 n_world = normalize(vec3(
			(h0 - hx) * 2.2 + (f0 - fx) * 0.12,
			1.0,
			(h0 - hz) * 2.2 + (f0 - fz) * 0.12));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// Direct scene depth.  Reconstruct view-space position from the depth texture.
	float raw_depth = texture(depth_tex, SCREEN_UV).r;
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(depth_to_ndc(SCREEN_UV, raw_depth), 1.0);
	view_pos.xyz /= view_pos.w;
	float scene_z = -view_pos.z;
	float frag_z = -VERTEX.z;
	float thickness = max(scene_z - frag_z, 0.0);
	float depth_term = clamp(thickness / depth_scale, 0.0, 1.0);
	// A real bowl, expressed as a radial basin term.  The baked bed is a flat
	// shelf only 6 mm under the waterline, so scene depth alone is constant.
	float rr = clamp(length(world_pos.xz - pond_center) / pond_radius, 0.0, 1.0);
	float basin = 1.0 - smoothstep(0.10, 0.96, rr);
	depth_term = max(depth_term, basin * 0.90);

	// Fresnel from the unperturbed geometric up normal and the true
	// vertex-to-camera direction.  The ripple NORMAL is deliberately excluded.
	vec3 N_geom = vec3(0.0, 1.0, 0.0);
	// Use the render camera's real world position, not a CPU-pushed uniform.
	// SubViewports and evidence cameras otherwise keep a stale position and
	// the fresnel is computed from the wrong side/angle.
	vec3 V_world = normalize(CAMERA_POSITION_WORLD - world_pos);
	float ndv = clamp(dot(N_geom, V_world), 0.0, 1.0);
	float fresnel = mix(0.05, 0.85, 1.0 - smoothstep(0.28, 0.62, ndv));

	// Body colour is the see-the-bed read; alpha stays 1.
	vec3 body = mix(shallow_color.rgb, deep_color.rgb, depth_term);

	// Real screen-space reflection.  March the reflected view ray through the
	// depth buffer, then sample scene colour at the hit.  The old analytic sky
	// wash is retained only as the miss fallback.
	vec3 R_world = reflect(-V_world, n_world);
	float refl_up = clamp(R_world.y, 0.0, 1.0);
	vec3 sky_fallback = sky_reflect_color.rgb * mix(0.65, 1.85, refl_up);
	vec3 view_origin = (VIEW_MATRIX * vec4(world_pos, 1.0)).xyz;
	vec3 view_R = normalize((VIEW_MATRIX * vec4(R_world, 0.0)).xyz);
	vec3 screen_col = sky_fallback;
	float view_dist = distance(CAMERA_POSITION_WORLD, world_pos);
	float refl_rough = smoothstep(3.0, 38.0, view_dist);
	float refl_lod = mix(4.0, 6.0, refl_rough);
	float refl_spread = mix(0.0120, 0.0220, refl_rough);
	float hit = 0.0;
	float edge_fade = 0.0;
	float t = 0.65;
	for (int i = 0; i < 18; i++) {
		vec3 p = view_origin + view_R * t;
		if (p.z > -0.05) break;
		vec4 clip = PROJECTION_MATRIX * vec4(p, 1.0);
		vec2 ruv = clip.xy / max(clip.w, 0.0001) * 0.5 + 0.5;
		if (ruv.x < 0.01 || ruv.x > 0.99 || ruv.y < 0.01 || ruv.y > 0.99) break;
		// Do not reflect the water pixel back into itself.
		if (distance(ruv, SCREEN_UV) < 0.012) { t += 0.55 + t * 0.16; continue; }
		float sd = texture(depth_tex, ruv).r;
		vec4 vp = INV_PROJECTION_MATRIX * vec4(depth_to_ndc(ruv, sd), 1.0);
		vp.xyz /= vp.w;
		float scene_z = -vp.z;
		float ray_z = -p.z;
		// Reject the water surface itself (and its immediate depth slice).  The
		// screen copy can contain this pond; without this guard every pixel
		// reflects its own speckles back into the pond.
		if (abs(scene_z - frag_z) < 0.45) { t += 0.55 + t * 0.16; continue; }
		if (scene_z < ray_z - 0.035) {
			// Reject hits below the waterline.  A transparent surface does not
			// write depth, so without this test the screen copy can feed the
			// pond's own ripple colour back into itself as rings.
			vec3 hit_world = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;
			if (hit_world.y < world_pos.y + 0.15) { t += 0.55 + t * 0.16; continue; }
			vec2 duv = clamp(ruv + n_world.xz * 0.002, vec2(0.01), vec2(0.99));
			// Five taps + a ceiling: a raw screen sample turns white flowers,
			// sheep and cloud edges into single-pixel white dots on the pond.
			vec3 sc = vec3(0.0);
			sc += textureLod(screen_tex, clamp(duv + vec2(refl_spread, 0.0), vec2(0.01), vec2(0.99)), refl_lod).rgb;
			sc += textureLod(screen_tex, clamp(duv + vec2(-refl_spread, 0.0), vec2(0.01), vec2(0.99)), refl_lod).rgb;
			sc += textureLod(screen_tex, clamp(duv + vec2(0.0, refl_spread), vec2(0.01), vec2(0.99)), refl_lod).rgb;
			sc += textureLod(screen_tex, clamp(duv + vec2(0.0, -refl_spread), vec2(0.01), vec2(0.99)), refl_lod).rgb;
			sc += textureLod(screen_tex, duv, refl_lod).rgb;
			sc *= 0.2;
			screen_col = min(sc, vec3(0.75));
			screen_col = mix(sky_fallback, screen_col, 0.45);
			hit = 1.0;
			float ex = smoothstep(0.01, 0.13, ruv.x) * smoothstep(0.99, 0.87, ruv.x);
			float ey = smoothstep(0.01, 0.13, ruv.y) * smoothstep(0.99, 0.87, ruv.y);
			edge_fade = ex * ey;
			break;
		}
		t += 0.55 + t * 0.16;
	}
	// A 1.0 hit is scene colour; miss stays analytic sky.  Edge fade keeps the
	// offscreen case from turning into a hard strip at the pond rim.
	// Screen-space reflection is a wide-view effect.  At a 3 m shoreline view it
	// produces ring-shaped self-samples around every ripple crest, so fade it
	// out close to the camera and keep the analytic sky there.
	float ssr_fade = mix(0.35, 1.0, smoothstep(7.0, 18.0, view_dist));
	vec3 reflection = mix(sky_fallback, screen_col, hit * edge_fade * ssr_fade);
	reflection *= 0.82 + 0.36 * h0;
	vec3 col = body + reflection * (0.006 + fresnel * 0.045);

	// Broad, distance-attenuated sun lobe only.  The old pow-3000 glint and the
	// pow-220 pinpoint were the single-pixel white-speckle source.
	float dist = distance(CAMERA_POSITION_WORLD, world_pos);
	float atten = 1.0 / (1.0 + dist * dist * 0.0015);
	float shininess = mix(150.0, 65.0, h0);
	float sun_spec = pow(max(dot(n_world, normalize(V_world + sun_dir)), 0.0), shininess)
			* 0.045 * atten * spec_strength;
	float sun_wide = pow(max(dot(n_world, normalize(V_world + sun_dir)), 0.0), 18.0)
			* 0.018 * atten;
	col += vec3(0.82, 0.86, 1.0) * (sun_spec + sun_wide);

	// Very gentle directional lift: keeps shaded ponds from going black while
	// staying independent of the scene shadow map (water is opaque/unshaded).
	float sun_lift = 0.54 + 0.30 * clamp(dot(n_world, normalize(sun_dir)), 0.0, 1.0);
	col *= sun_lift;

	// Low-depth water lifts toward the turquoise shallow colour before the
	// foam; this is the visible transition into the shore ribbon.
	// Use the basin radius, not the flat baked shelf thickness, for the
	// shallow ribbon; otherwise every pixel is "shallow" and the pond is one
	// flat cyan sheet even when depth_term reaches the deep colour.
	float shallow_band = smoothstep(0.52, 0.97, rr);
	col = mix(col, shallow_color.rgb * 1.20, shallow_band * 0.55);
	// Shallow rim stays in the water colour family.  The old tan wet-sand mix
	// turned the two 8 m2 ponds entirely mud-brown because they are shallower
	// than 10 cm across their whole bowl.
	float wet_edge = smoothstep(0.86, 1.0, rr);
	col = mix(col, shallow_color.rgb * 1.08, wet_edge * 0.55);
	// Thin foam only where the water is less than 15 cm deep, broken by the
	// same two-octave field.  Subtle, not a painted ring.
	float foam_band = smoothstep(0.88, 1.0, rr);
	float foam = foam_band * smoothstep(0.28, 0.76, h0) * 0.045;
	// A broken bright wet lip exactly at the boulder waterline.
	float lip = smoothstep(0.94, 1.0, rr);
	foam += lip * smoothstep(0.55, 0.92, f0) * 0.10;
	col = mix(col, foam_color.rgb, clamp(foam, 0.0, 0.42));
	// Very low-contrast albedo modulation from the same drifting field.  It
	// keeps the surface alive in the top-down 22 m view where normal-only
	// ripples otherwise disappear against the deep body.
	// No albedo modulation from the 15 cm ripple field: at this camera that
	// is what read as a regular square dot screen across the whole pond.
	// The 1.2 m octave only nudges the body very slightly.
	col *= 0.975 + 0.035 * f0;
	// Hard ceiling on water emission keeps reflected white cloth/petals from
	// becoming near-white pixels; p95 stays below the 0.40 luminance target.
	col = min(col, vec3(0.34));

	if (debug_channel == 1) {
		ALBEDO = vec3(fresnel, ndv, depth_term);
	} else if (debug_channel == 2) {
		ALBEDO = body;
	} else if (debug_channel == 3) {
		ALBEDO = reflection;
	} else if (debug_channel == 4) {
		ALBEDO = col;
	} else if (debug_channel == 5) {
		// hit, edge fade, fresnel: lets the harness measure reflection blend.
		ALBEDO = vec3(hit, edge_fade, fresnel);
	} else {
		// The normal path must use the lit/reflected colour.  A flat debug
		// placeholder here made every pond read as one solid teal slab.
		ALBEDO = col;
	}
	// Transparent shallow water reveals the pale sand bed; the deeper body is
	// almost opaque.  Transparent rendering is also what lets the depth texture
	// see the bed instead of this surface's own depth.
	// Shallow water is semi-transparent over the sand; the deep centre stays
	// nearly opaque.  The centroid-fan mesh and narrow shore lip keep the
	// underlying terrain boundaries from showing as straight seams.
	ALPHA = clamp(mix(0.54, 0.94, depth_term), 0.0, 1.0);
}
