shader_type spatial;
// Ground cover for the 29 top-surface apertures.  These caps are hole covers,
// not the terrain mesh, so they cannot inherit terrain.gdshader.  They sample
// the same world-space lane albedo/mask as the terrain path and otherwise use
// low-frequency compacted soil.  No tiled dirt photograph: at 5 m that read as
// woven canvas, which is exactly what this replaces.
render_mode cull_disabled, depth_draw_opaque, fog_disabled;

uniform sampler2D path_albedo : source_color, filter_linear, repeat_disable;
uniform sampler2D path_mask : filter_linear, repeat_disable;
uniform vec4 path_rect = vec4(-82.0, -82.0, 164.0, 164.0);
uniform float path_strength = 1.0;
uniform vec3 soil_color = vec3(0.195, 0.155, 0.108);

varying vec3 v_w;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	v_w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_w.xz;
	vec2 puv = (p - path_rect.xy) / path_rect.zw;
	vec4 pa = textureLod(path_albedo, puv, 0.0);

	float edge_n = (vnoise2(p * 4.1 + vec2(3.7, -1.9)) - 0.5) * 0.18
		+ (vnoise2(p * 9.3 + vec2(-6.2, 2.4)) - 0.5) * 0.06;
	float cov = smoothstep(0.10, 0.52, pa.a + edge_n) * path_strength;

	// Compacted earth, not a photograph.  Keep the detail coarse enough that a
	// 5 m view does not turn into a moire grid.
	float n1 = vnoise2(p * 1.9 + vec2(1.3, 7.7));
	float n2 = vnoise2(p * 3.8 + vec2(-2.1, 4.5));
	vec3 soil = soil_color * (0.84 + 0.24 * n1 + 0.10 * n2);
	float pebble = smoothstep(0.93, 0.975, vnoise2(p * 5.2 + vec2(2.2, -6.8)));
	soil = mix(soil, vec3(0.125, 0.105, 0.082), pebble * 0.55);

	vec3 pc = pa.rgb;
	float grain = vnoise2(p * 2.5 + vec2(1.3, 7.7)) * 0.60
		+ vnoise2(p * 5.0 + vec2(-2.1, 4.5)) * 0.40;
	pc *= 0.88 + 0.22 * grain;

	vec3 pm = textureLod(path_mask, puv, 0.0).rgb;
	float lat = (pm.g - 0.5) * 2.0;
	float groove = 1.0 - smoothstep(0.0, 0.130, abs(abs(lat) - 0.40));
	pc = mix(pc, vec3(0.072, 0.044, 0.026), groove * 0.90);
	float lip = exp(-pow((abs(lat) - 0.24) / 0.075, 2.0))
		+ exp(-pow((abs(lat) - 0.56) / 0.075, 2.0));
	pc *= 1.0 + 0.16 * lip;
	pc *= 1.0 + 0.12 * exp(-pow(lat / 0.30, 2.0));

	float st = smoothstep(0.94, 0.98, vnoise2(p * 5.6 + vec2(-4.6, 1.7)));
	pc = mix(pc, vec3(0.280, 0.255, 0.212), st * 0.55);

	// Dry bank / cap earth: compacted soil, grain and small stones.  The
	// baked lane map is too grey here, so it is not used as the base.
	float bank_n = vnoise2(p * 1.25 + vec2(5.1, -2.3)) * 0.62
		+ vnoise2(p * 3.40 + vec2(-3.7, 8.4)) * 0.38;
	vec3 out_col = mix(vec3(0.095, 0.062, 0.038), vec3(0.180, 0.132, 0.082), bank_n);
	float bs = smoothstep(0.925, 0.978, vnoise2(p * 4.70 + vec2(2.2, -6.8)));
	out_col = mix(out_col, vec3(0.190, 0.158, 0.120), bs * 0.55);
	float bs2 = smoothstep(0.958, 0.993, vnoise2(p * 7.10 + vec2(-4.6, 1.7)));
	out_col = mix(out_col, vec3(0.265, 0.232, 0.190), bs2 * 0.45);
	out_col *= 0.88 + 0.22 * bank_n;
	ALBEDO = out_col;
	ROUGHNESS = 0.98;
	SPECULAR = 0.02;
}
