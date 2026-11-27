shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled;
uniform vec4 ring_color : source_color = vec4(0.90, 0.97, 1.0, 0.62);
void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float r = length(uv);
	float ring = smoothstep(0.72, 0.84, r) * (1.0 - smoothstep(0.94, 1.0, r));
	float inner = smoothstep(0.46, 0.52, r) * (1.0 - smoothstep(0.54, 0.60, r));
	ALBEDO = ring_color.rgb;
	ALPHA = (ring * 1.10 + inner * 0.35) * ring_color.a;
}
