shader_type spatial;
// Distant archipelago silhouettes.  Unshaded and deliberately simple: these
// are background landforms, not playable terrain.  Aerial perspective is
// computed here so the near/far layering is predictable and fog-independent.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled;

uniform vec3 horizon_color = vec3(0.330, 0.323, 0.410);
uniform vec3 top_color = vec3(0.050, 0.082, 0.032);
uniform vec3 side_color = vec3(0.080, 0.050, 0.028);
uniform vec3 base_color = vec3(0.014, 0.010, 0.008);
uniform float haze = 0.45;
uniform float near_haze = 0.12;
uniform float phase = 0.0;
uniform float alpha_mul = 0.92;

varying vec3 world_pos;
varying vec3 world_normal;
varying vec2 sheet_uv;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	sheet_uv = UV;
}

void fragment() {
	// Height bands give the simple silhouette its green crown, brown cliff
	// and dark base without relying on vertex colours (which were washed out
	// by the material override in the first pass).
	vec3 base = mix(base_color, side_color, smoothstep(-14.0, -5.0, world_pos.y));
	base = mix(base, top_color, smoothstep(-1.5, 0.30, world_pos.y));
	float mottling = 0.84 + 0.16 * sin(world_pos.x * 0.11 + phase)
		* sin(world_pos.z * 0.093 - phase * 0.7);
	base *= mottling;
	// Faceted sun/shade breaks the silhouette into planes without a second
	// light or a full lit material.
	float ndl = clamp(dot(normalize(world_normal),
		normalize(vec3(-0.45, 0.82, 0.35))), 0.0, 1.0);
	base *= mix(0.62, 1.35, ndl);
	// Fade the body upward into the horizon, so the green crown does not end
	// on a hard horizontal colour line at the island base.
	base = mix(base, horizon_color, smoothstep(-16.0, -1.0, world_pos.y) * 0.45);
	float h = clamp((world_pos.y + 18.0) / 22.0, 0.0, 1.0);
	float aerial = clamp(haze + (1.0 - h) * near_haze, 0.0, 0.94);
	vec3 col = mix(base, horizon_color, aerial);
	col += vec3(0.010, 0.012, 0.016) * (1.0 - h);
	ALBEDO = col;
	// The sheet has no side/back walls: fade the base and both ends into the
	// horizon colour so the silhouette never terminates on a hard straight line.
	// Fade in local sheet space, not world height: the deep layer sits at
	// y=-60..-110 and must not be alpha-zeroed by an absolute height test.
	float base_fade = smoothstep(0.0, 0.42, sheet_uv.y);
	float end_fade = smoothstep(0.0, 0.40, sheet_uv.x)
		* (1.0 - smoothstep(0.60, 1.0, sheet_uv.x));
	ALPHA = clamp(base_fade * end_fade * alpha_mul, 0.0, 1.0);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
