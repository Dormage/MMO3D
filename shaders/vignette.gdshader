shader_type canvas_item;

// Screen-space vignette. Only multiplies luminance, so it is safe in any
// colour space: it cannot shift hue, which is exactly why it is separate from
// the LUT grade (that one lives in Environment.adjustment_color_correction).

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float strength : hint_range(0.0, 1.5) = 0.55;
uniform float edge_start : hint_range(0.0, 1.5) = 0.45;
uniform float edge_end : hint_range(0.0, 2.0) = 1.05;
uniform float aspect : hint_range(0.5, 3.0) = 1.78;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	vec2 d = SCREEN_UV - vec2(0.5);
	d.x *= aspect;
	float v = smoothstep(edge_start, edge_end, length(d));
	c *= 1.0 - strength * v;
	COLOR = vec4(c, 1.0);
}
