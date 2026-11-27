shader_type spatial;
// Trees: horizontal sway driven by the baked COLOR_0.a weight, on top of the
// exact material Agent A shipped (albedo + normal + roughness textures, UV1
// transform, vertex-colour albedo). Do not turn COLOR.a into alpha: it is the
// sway weight, and the trees are opaque.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_albedo = false;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform float normal_scale = 1.0;
uniform sampler2D roughness_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_roughness = false;
uniform float roughness_value = 1.0;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform bool use_vertex_color = true;
// foliage cards carry their cutout in the albedo texture's alpha; COLOR.a is
// never alpha, it is the sway weight
uniform float alpha_cut = 0.45;
uniform float backlight_strength = 0.28;
// Under-canopy fill: lifts leaf cards and canopy surfaces that face away from
// the sun.  Exposed tops still depend on direct light, so the crown still reads
// as shadowed rather than self-lit.
uniform float leaf_fill = 1.0;

uniform float wind_strength = 0.12;   // metres at weight 1
uniform float wind_speed = 1.35;
uniform vec2 wind_dir = vec2(0.906, 0.423);
uniform float wind_scale = 0.35;      // spatial phase per metre
uniform float sway_weight = 1.0;      // canopy = 1, trunk = lower
// Runtime leaf cards use per-instance custom data for two-tone shading.
uniform bool is_card = false;
uniform float card_saturation = 1.0;
uniform float card_emission = 1.0;
uniform float distance_cutoff = 120.0;
uniform float distance_fade = 25.0;

varying vec2 v_uv;
varying vec3 v_card;
varying float v_view_depth;
varying float v_card_code;

// Updated every frame by vegetation.gd: player head projected into the RPG
// camera.  Cards/canopy surfaces closer to the camera than the player and in
// his screen-space silhouette are ordered-dithered out; trunks never are.
uniform vec2 player_screen = vec2(-1.0, -1.0);
uniform float player_depth = 0.0;
uniform float player_active = 0.0;

float bayer4(vec2 p) {
	int x = int(mod(p.x, 4.0));
	int y = int(mod(p.y, 4.0));
	float m[16] = float[16](0.0, 8.0, 2.0, 10.0,
			12.0, 4.0, 14.0, 6.0,
			3.0, 11.0, 1.0, 9.0,
			15.0, 7.0, 13.0, 5.0);
	return (m[y * 4 + x] + 0.5) / 16.0;
}

void vertex() {
	// One phase per instance/position so neighbouring trees never move together.
	vec3 origin = MODEL_MATRIX[3].xyz;
	float phase = dot(origin.xz, vec2(0.73, 1.31)) * wind_scale + origin.y * 0.17;
	float t = TIME * wind_speed;

	float sway = sin(t + phase) * 0.68 + sin(t * 0.41 + phase * 1.7) * 0.22;
	// Slow lateral wander, perpendicular to the wind; a pure 1D sine reads
	// mechanical.
	float wander = cos(t * 0.27 + phase * 1.13) * 0.24;
	float gust = 0.75 + 0.25 * sin(t * 0.19 + dot(origin.xz, vec2(0.11, 0.07)));

	vec2 dir = normalize(wind_dir);
	vec2 perp = vec2(-dir.y, dir.x);
	vec2 offset = (dir * sway + perp * wander) * gust;

	float dist = distance(origin, CAMERA_POSITION_WORLD);
	float fade = 1.0 - smoothstep(distance_cutoff - distance_fade, distance_cutoff, dist);
	// COLOR.a varies within a connected canopy; multiplying the offset by it
	// shears rigid leaf triangles into long straight sticks.  Use one uniform
	// amplitude per tree/material so the crown translates as a body while the
	// per-instance phase still de-synchronises neighbouring trees.
	float amp = sway_weight * wind_strength * fade;

	// Wind is a world-space direction; project it onto the instance's local X/Z
	// so the random yaw of each tree does not rotate the wind with it.
	vec3 world_offset = vec3(offset.x, 0.0, offset.y);
	vec3 axis_x = normalize(MODEL_MATRIX[0].xyz);
	vec3 axis_z = normalize(MODEL_MATRIX[2].xyz);
	VERTEX.x += dot(world_offset, axis_x) * amp;
	VERTEX.z += dot(world_offset, axis_z) * amp;

	v_card = is_card ? INSTANCE_CUSTOM.rgb : vec3(1.0);
	v_card_code = is_card ? floor(INSTANCE_CUSTOM.a * 15.0 + 0.5) : 0.0;
	v_uv = UV * uv_scale + uv_offset;
	if (is_card) {
		// 16 variants: low 2 bits pick one of four leaf-cluster cells, high 2
		// bits rotate the card 0/90/180/270.  Neighbours no longer share the
		// same angular cut-out.
		int code = int(v_card_code);
		int variant = code % 4;
		int rot = code / 4;
		vec2 uv = UV - 0.5;
		float a = float(rot) * 1.5707963;
		uv = mat2(vec2(cos(a), -sin(a)), vec2(sin(a), cos(a))) * uv;
		v_uv = (uv + 0.5) * uv_scale + uv_offset +
				vec2(float(variant % 2), float(variant / 2)) * uv_scale;
	}

	if (is_card) {
		// Screen-facing leaf cards: each quad keeps its instance scale but
		// discards its roll, so cards read as leaf clusters instead of edge-on
		// strips.
		vec3 sc = vec3(length(MODEL_MATRIX[0]), length(MODEL_MATRIX[1]), 1.0);
		// Mostly camera-facing, but blend in 40% of the crown normal so leaves
		// catch different light instead of every card sharing one flat normal.
		vec3 face_n = INV_VIEW_MATRIX[2].xyz;
		vec3 crown_n = normalize(MODEL_MATRIX[2].xyz);
		vec3 n = normalize(mix(face_n, crown_n, 0.40));
		vec3 xa = normalize(cross(INV_VIEW_MATRIX[1].xyz, n));
		vec3 ya = cross(n, xa);
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(xa * sc.x, 0.0),
			vec4(ya * sc.y, 0.0),
			vec4(n, 0.0),
			vec4(MODEL_MATRIX[3].xyz, 1.0));
	}
	v_view_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	vec4 alb = vec4(1.0);
	if (has_albedo) {
		alb = texture(albedo_tex, v_uv);
		ALPHA = alb.a;
		ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	}
	// Depth/screen-space foliage fade.  Only leaf surfaces (sway_weight high)
	// and cards fade; the trunk keeps sway_weight 0.28 and stays solid.
	if (player_active > 0.5 && sway_weight > 0.45) {
		float closer = smoothstep(0.04, 0.55, player_depth - v_view_depth);
		vec2 d = SCREEN_UV - player_screen;
		d.x *= 1.7777;
		float radial = 1.0 - smoothstep(0.018, 0.095, length(d));
		// Remove the leaves in the player's screen disc outright.  A 4x4
		// ordered dither only punched pin-holes through 160 overlapping cards;
		// the nearest card still covered him.  The radial term is smooth, so
		// the cut edge expands continuously as he walks in.
		float cut = closer * radial;
		if (cut > 0.18) {
			discard;
		} else if (cut > 0.05) {
			// Ordered-dither annulus at the cut edge: fully clear in the centre,
			// progressively leafier outward.  No binary edge to pop.
			float edge = smoothstep(0.05, 0.18, cut);
			if (bayer4(FRAGCOORD.xy) < edge) {
				discard;
			}
		}
	}
	vec3 col = alb.rgb * albedo_color.rgb;
	if (is_card) {
		col *= v_card;
		// Cherry blossom is a texture-authored magenta; it dominated the muted
		// green frame.  Desaturate the card only, keeping value and alpha.
		float cl = dot(col, vec3(0.2126, 0.7152, 0.0722));
		col = mix(vec3(cl), col, clamp(card_saturation, 0.0, 1.0));
	}
	if (use_vertex_color) {
		// COLOR_0.rgb is Agent A's dark-tree fix; never drop it.
		col *= COLOR.rgb;
	}
	// Canopy leaves get a minimum albedo floor and an indirect fill.  This is
	// the difference between a readable dark green underside and a black wall
	// when the camera is inside the crown.
	float leaf = smoothstep(0.40, 0.86, sway_weight);
	vec3 floor_col = vec3(0.032, 0.055, 0.022);
	col = mix(col, max(col, floor_col * leaf_fill), leaf * clamp(leaf_fill, 0.0, 1.0));
	ALBEDO = col;
	if (is_card) {
		// A little self-fill so interior cards are not crushed to black.
		EMISSION = col * (0.28 + 0.16 * leaf_fill) * card_emission;
	} else if (leaf_fill > 0.0) {
		// Original canopy surfaces are opaque and can face straight down under
		// the crown; give them a small indirect term without flattening them.
		EMISSION = col * 0.11 * leaf_fill * leaf;
	}

	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, v_uv).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
	if (has_roughness) {
		ROUGHNESS = texture(roughness_tex, v_uv).g * roughness_value;
	} else {
		ROUGHNESS = roughness_value;
	}
	METALLIC = 0.0;
	SPECULAR = 0.16;
	// leaves transmit light: the crown lights up when the sun is behind it,
	// but distant crowns must not turn into white backlit blobs.
	float dist = distance(MODEL_MATRIX[3].xyz, CAMERA_POSITION_WORLD);
	float far = smoothstep(30.0, 120.0, dist);
	float bl = backlight_strength * mix(1.0, 0.55, far);
	BACKLIGHT = col * bl * leaf;
}
