shader_type spatial;
// Falling water for the conforming ribbons built by scripts/waterfalls.gd.
// The mesh is a real ribbon sampled against the cliff: UV.y = 1 at the lip,
// 0 at the base.  The shader only animates the surface.
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 water_color : source_color = vec4(0.28, 0.40, 0.52, 1.0);
uniform vec4 foam_color : source_color = vec4(0.64, 0.76, 0.86, 1.0);
uniform float speed = 1.9;
uniform float opacity = 1.0;
uniform float distortion = 0.16;
uniform float fresnel_power = 3.2;
uniform float foam_lip = 0.9;
uniform float foam_base = 0.85;
uniform float edge_softness = 0.55;
// How transparent the falling sheet is when seen from above/grazing.  The
// player approaches islands from the air; from that angle a vertical sheet
// is nearly edge-on and must show the rock behind it.
uniform float grazing_alpha = 0.16;
uniform float side_alpha = 0.72;
// Skylight fill: thin water must never be a black bar against shaded rock.
uniform float sky_fill = 0.24;
uniform float flow_scale = 2.8;
uniform float foam_amount = 0.80;
uniform bool mist_mode = false;

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

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// A millimetre-scale breath, not a flag: the ribbon already hugs the rock.
	float breath = sin(TIME * 1.7 + world_pos.y * 4.0 + world_pos.x * 2.0);
	VERTEX += NORMAL * breath * 0.008;
}

void fragment() {
	// The ribbon is cull_disabled; make a backface use the same sky-facing
	// normal instead of inheriting a sunless, black-shaded interior.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	if (mist_mode) {
		vec2 p = (UV - vec2(0.5, 0.42)) * vec2(1.0, 0.8);
		float r = length(p);
		float n = fbm(vec2(UV.x * 6.0, UV.y * 4.0 - TIME * 0.35));
		ALBEDO = foam_color.rgb;
		ROUGHNESS = 1.0;
		METALLIC = 0.0;
		SPECULAR = 0.0;
		ALPHA = opacity * smoothstep(0.52, 0.06, r) * (0.35 + 0.65 * n);
		EMISSION = foam_color.rgb * 0.18;
	} else {
	float t = TIME * speed;
	// Vertical flow plus a horizontal wobble that travels down the sheet.
	float wob = (vnoise(vec2(UV.y * 7.0 - t, UV.x * 3.0)) - 0.5) * distortion;
	float phase = fract(sin(dot(world_pos.xz, vec2(0.13, 0.17))) * 437.0);
	vec2 q = vec2(UV.x * (flow_scale + 0.6) + wob, UV.y * 1.8 - t + phase);

	float streak = fbm(q);
	float fine = fbm(vec2(q.x * 2.1 + 4.0, q.y * 1.7 + t * 0.7));
	float foam = smoothstep(0.34, 0.72, streak * 0.64 + fine * 0.48);

	// Whitewater at the lip and where the fall lands.  The lip is broken by
	// noise so it does not grow a straight white bar.
	float top_n = vnoise(vec2(UV.x * 9.0, t * 0.7));
	float lip = smoothstep(1.0 - 0.07 * foam_lip * top_n, 1.0, UV.y);
	float side_noise = vnoise(vec2(UV.x * 7.0, UV.y * 4.0 - t * 0.6));
	float base = smoothstep(0.07 * foam_base * (0.6 + 0.8 * side_noise), 0.0, UV.y);
	// Whitewater belongs at the lip and the foot, not across the whole sheet;
	// a travelling hint of foam is all the body gets.
	float lip_o = lip * (0.78 + 0.22 * top_n);
	float white = clamp(lip_o * 0.90 + base * 0.95 + foam * 0.06, 0.0, 1.0);

	float backface = FRONT_FACING ? 0.0 : 1.0;
	vec3 col = mix(water_color.rgb, foam_color.rgb, white);
	vec3 sky = vec3(0.46, 0.62, 0.78);
	// A backface is the inside of the ribbon.  Make it sky-lit and opaque
	// enough that it can never read as a black bar against the cliff.
	col = mix(col, sky, backface * 0.55);
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fres = pow(1.0 - facing, fresnel_power);
	// Fresnel/angle opacity: side-on the body is water, from above it is a
	// thin veil with rock readable through it.
	// World-space view elevation.  VIEW is view-space, so its .y is camera-up,
	// not world-up; using it here was why a top-down camera still saw a slab.
	vec3 V_world = normalize(CAMERA_POSITION_WORLD - world_pos);
	float view_up = clamp(V_world.y, 0.0, 1.0);
	float topdown = smoothstep(0.62, 0.84, view_up);
	float body_alpha = mix(grazing_alpha, side_alpha, smoothstep(0.04, 0.82, facing));
	// A high camera looks down even when the ribbon happens to face it; make
	// that view read as a veil too, not only the surface-grazing case.
	body_alpha *= 1.0 - topdown * 0.94;
	// The lip and foot are allowed a wider, softer white edge; without
	// widening them the sheet keeps a hard rectangular silhouette.  This is
	// an alpha widening only, not a rebuild of the conforming ribbon.
	float lip_or_base = max(lip_o, base);
	float edge_w = edge_softness * mix(1.0, 0.34, lip_or_base);
	float edge = smoothstep(0.0, edge_w + 0.16 * side_noise, UV.x)
			* smoothstep(1.0, 1.0 - edge_w - 0.16 * side_noise, UV.x);
	edge = pow(edge, 1.8);
	float foot = smoothstep(0.0, 0.22 + 0.10 * side_noise, UV.y);
	// Foam is opaque enough to read from above; the body is not.
	float foam_alpha = clamp(lip_o * 0.95 + base * 0.90 + foam * 0.06, 0.0, 1.0);
	float top_soft = smoothstep(1.0, 0.965, UV.y);
	float alpha = opacity * max(body_alpha, foam_alpha) * edge * foot
			* mix(0.18, 1.0, top_soft);
	// Never let the backface override the top-down fade with an opaque slab.
	alpha = max(alpha, backface * 0.72 * (1.0 - topdown * 0.96));
	alpha *= 1.0 - topdown * 0.90;

	ALBEDO = col;
	ROUGHNESS = mix(0.06, 0.52, white);
	METALLIC = 0.0;
	SPECULAR = 0.0;
	ALPHA = clamp(alpha, 0.0, 1.0);
	EMISSION = foam_color.rgb * white * 0.22
			+ mix(sky, foam_color.rgb, white * 0.55) * (sky_fill + backface * 0.55);
	}
}
