shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_opaque;

uniform vec4 body_color : source_color = vec4(0.030, 0.050, 0.062, 1.0);
uniform vec4 edge_color : source_color = vec4(0.25, 0.38, 0.45, 1.0);

varying float height;

void vertex() {
	height = clamp(VERTEX.y * 1.2, 0.0, 1.0);
}

void fragment() {
	// The shard mesh is a set of flat planes, so use the face normal itself as
	// the facet term.  This keeps every plane visible from both sides and gives
	// smoked-glass variation without a lighting term that can crush to black.
	float facing = FRONT_FACING ? 1.0 : 0.68;
	float facet = clamp(NORMAL.y * 0.5 + 0.5, 0.0, 1.0);
	float fres = pow(1.0 - abs(dot(NORMAL, VIEW)), 2.0);
	vec3 c = mix(body_color.rgb * 0.60, edge_color.rgb,
			0.16 + 0.26 * height + 0.24 * facet + 0.30 * fres);
	c *= mix(1.0, 0.82, facing);
	ALBEDO = c;
}
