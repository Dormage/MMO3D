shader_type canvas_item;
render_mode unshaded;

// Final lens/grade pass.  The 3D Environment already does exposure, glow, fog
// and SSAO; this pass only adds the photographic bits Environment cannot:
// split-tone grade, a small S-curve, radial chromatic fringing, and film grain.
// The existing map vignette is deliberately not duplicated here.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float grain_amount : hint_range(0.0, 0.06) = 0.025;
uniform float ca_amount : hint_range(0.0, 0.01) = 0.0012;
uniform float shadow_tint : hint_range(0.0, 0.9) = 0.10;
uniform float highlight_tint : hint_range(0.0, 0.6) = 0.10;
uniform float contrast : hint_range(-0.2, 0.4) = 0.040;
// Global saturation pull. Everything in the scene sits at high saturation
// (purple cliffs, cyan ponds, green grass), which reads as garish rather than
// photographic. Muted base with warm accents is the intended look.
uniform float saturation : hint_range(0.0, 1.4) = 1.00;
uniform float shadow_lift : hint_range(0.0, 0.05) = 0.018;
// Photographic highlight shoulder: keeps the top 5% inside the approved
// luminance gate without lowering the whole exposure into night.
uniform float highlight_ceiling : hint_range(0.0, 1.0) = 0.92;
uniform float highlight_saturation : hint_range(1.0, 1.6) = 1.00;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 d = uv - vec2(0.5);
	float r2 = dot(d, d);
	vec2 off = d * ca_amount * (0.35 + r2);
	vec3 c;
	c.r = texture(screen_tex, uv + off).r;
	c.g = texture(screen_tex, uv - off * 0.35).g;
	c.b = texture(screen_tex, uv - off).b;

	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));

	// Blue-violet shadows, golden highlights; both are weak enough to keep
	// skin and grass recognisable.
	float sh = 1.0 - smoothstep(0.04, 0.58, l);
	float hi = smoothstep(0.42, 0.95, l);
	// Keep deep, nearly-black water out of the shadow tint, otherwise the
	// multiply turns the pond into a black hole.  Real shadowed grass sits
	// above this threshold and still gets the blue-violet cast.
	float deep = smoothstep(0.03, 0.10, l);
	c = mix(c, c * vec3(0.56, 0.40, 1.68), sh * shadow_tint * deep);
	c += vec3(0.0, 0.0, 0.030) * sh * shadow_tint;
	c = mix(c, c * vec3(1.20, 1.02, 0.78), hi * highlight_tint);

	// Global saturation pull, applied after the split-tone so the tint cannot
	// re-saturate what this removes.
	{
		float sg = dot(c, vec3(0.2126, 0.7152, 0.0722));
		c = mix(vec3(sg), c, saturation);
	}

	// Gentle S-curve; lift instead of crushing the bottom.
	c = (c - 0.5) * (1.0 + contrast) + 0.5;
	c = max(c, vec3(0.0));
	c += shadow_lift * (1.0 - c);

	// Soft shoulder so the post pass cannot create new clipped whites.
	// Per-channel shoulder: the pink blossom is the first thing to reach 1.0,
	// so compress each channel independently instead of only the luma.
	c = c / (1.0 + max(c - 0.90, vec3(0.0)) * 1.2);
	if (highlight_ceiling < 0.999) {
		float lc = dot(c, vec3(0.2126, 0.7152, 0.0722));
		float knee = max(highlight_ceiling - 0.08, 0.01);
		if (lc > knee) {
			float head = max(highlight_ceiling - knee, 0.001);
			float mapped = knee + head * (1.0 - exp(-(lc - knee) / head));
			c *= mapped / max(lc, 0.001);
			// Keep the blossom and banner hues from washing grey when the
			// shoulder compresses their brightest pixels.
			float l2 = dot(c, vec3(0.2126, 0.7152, 0.0722));
			c = mix(vec3(l2), c, highlight_saturation);
		}
	}

	// Luma-only grain, animated but very fine.  2.5% is enough to break a
	// sky gradient without looking like video noise.
	float n = hash12(uv * vec2(1920.0, 1080.0) + vec2(TIME * 37.0, TIME * 19.0));
	c += (n - 0.5) * grain_amount;
	COLOR = vec4(clamp(c, vec3(0.0), vec3(1.0)), 1.0);
}
