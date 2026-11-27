shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

// A narrow skirt generated from the same contour as the pond mesh.  It has
// one band across its 18 cm width, so it cannot cross the bank as a floating
// sheet the way the old four-band ribbon did.
varying float band;
varying vec3 world;

void vertex() {
	band = COLOR.r;
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 shallow = vec3(0.105, 0.480, 0.420);
	vec3 wet_sand = vec3(0.380, 0.315, 0.215);
	vec3 c = mix(shallow, wet_sand, smoothstep(0.10, 0.78, band));
	float lip = 1.0 - smoothstep(0.12, 0.50, abs(band - 0.42));
	c = mix(c, vec3(0.62, 0.70, 0.68), lip * 0.42);
	ALBEDO = c;
	ALPHA = clamp(mix(0.34, 0.92, smoothstep(0.0, 0.72, band)), 0.0, 1.0);
}
