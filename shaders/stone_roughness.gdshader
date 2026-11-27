shader_type spatial;
render_mode unshaded;

uniform vec4 lit_color : source_color = vec4(0.180, 0.200, 0.230, 1.0);
uniform vec4 shadow_color : source_color = vec4(0.110, 0.160, 0.260, 1.0);
uniform vec3 sun_dir = vec3(0.624, 0.469, 0.624);
uniform vec3 sky_bounce = vec3(0.012, 0.016, 0.022);
uniform bool roughness_debug = false;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(i);
	float n100 = hash31(i + vec3(1, 0, 0));
	float n010 = hash31(i + vec3(0, 1, 0));
	float n110 = hash31(i + vec3(1, 1, 0));
	float n001 = hash31(i + vec3(0, 0, 1));
	float n101 = hash31(i + vec3(1, 0, 1));
	float n011 = hash31(i + vec3(0, 1, 1));
	float n111 = hash31(i + vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
			mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float fbm3(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise3(p);
		p = p * 2.03 + vec3(11.3, 7.7, 3.1);
		a *= 0.5;
	}
	return v;
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		vec2 i2 = floor(p);
		vec2 f = fract(p);
		f = f * f * (3.0 - 2.0 * f);
		float n = mix(mix(hash31(vec3(i2, 0.0)), hash31(vec3(i2 + vec2(1, 0), 0.0)), f.x),
				mix(hash31(vec3(i2 + vec2(0, 1), 0.0)), hash31(vec3(i2 + vec2(1, 1), 0.0)), f.x), f.y);
		v += a * n;
		p = p * 2.07 + vec2(5.2, 9.1);
		a *= 0.5;
	}
	return v;
}

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

void fragment() {
	vec3 P = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 Nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float h0 = COLOR.r;
	float g1 = fbm3(P * 23.0);
	float g2 = fbm3(P * 53.0 + vec3(5.0, 2.0, 8.0));
	float g3 = fbm3(P * 125.0 + vec3(13.0, 3.0, 21.0));
	float g4 = fbm3(P * 250.0 + vec3(2.0, 9.0, 4.0));
	float grain = (g1 - 0.5) * 0.70 + (g2 - 0.5) * 0.60
			+ (g3 - 0.5) * 0.85 + (g4 - 0.5) * 0.45;
	float streak = fbm2(vec2((P.x + P.z) * 2.1, P.y * 0.26));
	float rough = clamp(0.80 + grain * 0.35 + (h0 - 0.5) * 0.08
			+ (streak - 0.5) * 0.06, 0.65, 1.0);
	ALBEDO = vec3(rough);
}
