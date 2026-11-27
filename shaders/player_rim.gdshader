shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, fog_disabled;

uniform vec4 rim_color = vec4(1.0, 0.72, 0.32, 0.75);

void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	float f = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 2.0);
	ALBEDO = rim_color.rgb * f * rim_color.a;
	ALPHA = 1.0;
}
