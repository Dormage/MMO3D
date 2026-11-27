shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// A four-band shoreline ribbon: shallow turquoise water -> wet sand -> damp
// bank -> dry bank.  It sits on top of the water edge and the terrain hole,
// so there is no dark gap between the two meshes.  Vertex COLOR.r is the band
// parameter (0 inner water, 1 outer bank).
varying float band;
varying vec3 world;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i), b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0)), d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	band = COLOR.r;
	// The outer band is a flat ribbon over the bank.  Bury it just below the
	// terrain so it cannot read as a pale floating polygon; the water-side
	// bands still sit at the waterline.
	if (band > 0.80) {
		VERTEX.y -= 0.22;
	}
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world.xz;
	float n1 = vnoise(p * 2.3 + vec2(3.1, -1.7));
	float n2 = vnoise(p * 5.1 + vec2(-2.4, 4.9));
	float grain = 0.90 + 0.14 * n1 + 0.06 * n2;

	// Low-depth water colour, matching water.gdshader's shallow tone but a
	// little lighter so the first centimetres read as water over sand.
	vec3 shallow = vec3(0.105, 0.460, 0.400);
	vec3 wet = vec3(0.250, 0.205, 0.135);
	vec3 damp = vec3(0.265, 0.215, 0.145);
	vec3 bank = vec3(0.335, 0.270, 0.175);

	// A is wet sand (matches the water-edge tan); B is the turquoise shallow
	// band; C returns to wet sand and D to the dry bank.  The tan-cyan-tan
	// sequence removes the hard value step at the waterline.
	vec3 c = mix(wet, shallow, smoothstep(0.0, 0.44, band));
	c = mix(c, wet, smoothstep(0.44, 0.70, band));
	c = mix(c, damp, smoothstep(0.70, 0.86, band));
	c = mix(c, bank, smoothstep(0.86, 1.0, band));
	c *= grain;
	// A touch of sky bounce keeps the wet band from going black under the
	// bridge deck; no hard shadow term is used here.
	c += vec3(0.010, 0.014, 0.012) * (1.0 - smoothstep(0.0, 0.5, band));
	// Keep only the narrow water-to-wet-sand lip.  The outer bank bands are a
	// flat ribbon over concave terrain and read as floating shards up close.
	if (band < 0.30 || band > 0.62) {
		discard;
	}
	ALBEDO = c;
	ROUGHNESS = mix(0.72, 0.98, smoothstep(0.1, 0.6, band));
	SPECULAR = 0.10;
	// Fade the outermost 10 cm into the grass/bank instead of ending on a
	// hard opaque rim.  The water side stays fully opaque.
	ALPHA = 1.0 - smoothstep(0.90, 1.0, band);
}
