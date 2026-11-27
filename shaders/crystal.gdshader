shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 body_color : source_color = vec4(0.10, 0.30, 0.52, 1.0);
uniform vec4 edge_color : source_color = vec4(0.38, 0.82, 1.0, 1.0);
uniform float emission_scale = 2.4;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	float h = clamp(local_pos.y * 1.15, 0.0, 1.0);
	vec3 body = mix(body_color.rgb * 0.55, body_color.rgb * 1.65, h);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.4);
	vec3 c = mix(body, edge_color.rgb, fres * 0.62);
	ALBEDO = c;
	EMISSION = (edge_color.rgb * (fres * 0.42)
		+ body_color.rgb * (0.06 + 0.10 * h)) * emission_scale;
	ROUGHNESS = mix(0.36, 0.12, h);
	METALLIC = 0.12;
	SPECULAR = 0.32;
}
