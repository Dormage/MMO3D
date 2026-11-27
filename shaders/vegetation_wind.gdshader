shader_type spatial;

// Wind for vegetation: trees, bushes, grass, reeds.
//
// Vertex-colour driven, because that is how the island's foliage is authored --
// the palette lives in COLOR rather than in a texture.  An albedo texture is
// multiplied on top when one exists (bark, grass blades) and a detail texture is
// supplied where it does not (canopies), so leaves stop reading as flat blobs.
//
// Motion is deliberately not one sine.  A tree that sways at exactly one rate
// reads as a pendulum, so this is a slow sway plus a slower gust envelope plus a
// fast small flutter.  Phase is taken from world position, which keeps
// neighbouring plants from moving in lockstep.
//
// The bend mask is quadratic in height above the surface base: a trunk should be
// rigid at the root and flexible at the crown, and squaring gives that falloff
// without needing a weight painted into the mesh.

render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool use_texture = true;
uniform bool use_vertex_color = true;

// Object-space height range of this surface.  Supplied per surface at load time
// from the surface's own AABB, so a grass blade and a tree canopy both get a
// sensible 0..1 bend mask from the same shader.
uniform float base_y = 0.0;
uniform float top_y = 1.0;

uniform float sway_strength = 0.075;
uniform float sway_speed = 1.10;
uniform vec2 wind_dir = vec2(1.0, 0.32);
// Extra movement from slow gusting, as a fraction of sway_strength.
uniform float gust_strength = 0.55;
uniform float gust_speed = 0.29;
// Small high-frequency shiver of individual leaves.
uniform float flutter = 0.016;
uniform float flutter_speed = 4.1;
// Metres of world position over which the phase advances.  Larger = neighbours
// drift further out of sync.
uniform float phase_scale = 0.21;

// Path clearing.  Plants inside these spheres are pushed radially outwards so a
// tree standing on a bridge landing does not block the way through.  Done here
// rather than by editing the mesh because the vegetation is one merged
// million-triangle surface; rebuilding it on the CPU to move one tree would cost
// seconds of load time, while this costs a length() per vertex.
uniform vec3 clear_a = vec3(0.0, -9999.0, 0.0);
uniform vec3 clear_b = vec3(0.0, -9999.0, 0.0);
uniform vec3 clear_c = vec3(0.0, -9999.0, 0.0);
uniform vec3 clear_d = vec3(0.0, -9999.0, 0.0);
uniform float clear_radius = 3.0;
uniform float clear_push = 2.6;

// Explicit relocation of individual plants, used when one tree sits somewhere it
// should not.  The pines are six stacked cone tiers sharing one merged surface,
// so moving a whole trunk has to move every tier: a radius test on the XZ centre
// does that automatically, where an index-based edit would need to find all six.
uniform vec3 move_a_center = vec3(0.0, 0.0, 0.0);
uniform vec3 move_a_offset = vec3(0.0, 0.0, 0.0);
uniform float move_a_radius = 0.0;
uniform vec3 move_b_center = vec3(0.0, 0.0, 0.0);
uniform vec3 move_b_offset = vec3(0.0, 0.0, 0.0);
uniform float move_b_radius = 0.0;

varying vec3 world_pos;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// 0 at the base, 1 at the top, squared so the root barely moves.
	float h = clamp((VERTEX.y - base_y) / max(top_y - base_y, 0.001), 0.0, 1.0);
	float bend = h * h;

	float t = TIME * sway_speed;
	float phase = wp.x * phase_scale + wp.z * phase_scale * 0.83;

	// Slow sway, with a second harmonic at an irrational-ish ratio so it never
	// settles into a repeat.
	float sway = sin(t + phase) * 0.62 + sin(t * 1.73 + phase * 2.3) * 0.38;

	// Gust: a much slower envelope that swells and eases the whole plant.
	float gust = sin(TIME * gust_speed + wp.x * 0.031 + wp.z * 0.017) * 0.5 + 0.5;

	vec2 dir = normalize(wind_dir);
	float amount = sway * sway_strength * bend * (1.0 + gust * gust_strength);
	vec3 offset = vec3(dir.x, 0.0, dir.y) * amount;

	// Fine flutter, strongest at the tips, breaking up the rigid silhouette.
	vec3 flutter_off = vec3(
			sin(TIME * flutter_speed + wp.z * 3.1 + wp.y * 1.7),
			0.0,
			cos(TIME * flutter_speed * 0.91 + wp.x * 2.7 + wp.y * 1.3));
	offset += flutter_off * flutter * bend;

	wp += offset;

	// Push vegetation clear of the bridge landings.  Weighted by height too, so
	// the root stays put and the crown leans away instead of the whole plant
	// sliding sideways like a decal.
	for (int i = 0; i < 4; i++) {
		vec3 c = i == 0 ? clear_a : (i == 1 ? clear_b : (i == 2 ? clear_c : clear_d));
		if (c.y < -9000.0) continue;
		vec2 d = wp.xz - c.xz;
		float dist = length(d);
		if (dist < clear_radius && dist > 0.001) {
			float w = 1.0 - smoothstep(0.0, clear_radius, dist);
			float lift = 0.35 + 0.65 * bend;
			wp.xz += (d / dist) * clear_push * w * lift;
		}
	}

	// Relocate whole plants.  No height weighting here: the trunk and every tier
	// must shift by the same amount or the tree shears apart.
	for (int i = 0; i < 2; i++) {
		vec3 mc = i == 0 ? move_a_center : move_b_center;
		vec3 mo = i == 0 ? move_a_offset : move_b_offset;
		float mr = i == 0 ? move_a_radius : move_b_radius;
		if (mr <= 0.0) continue;
		float md = length(wp.xz - mc.xz);
		if (md < mr) {
			wp += mo * (1.0 - smoothstep(mr * 0.72, mr, md));
		}
	}

	world_pos = wp;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
}

void fragment() {
	vec3 albedo = tint.rgb;
	if (use_vertex_color) {
		albedo *= COLOR.rgb;
	}
	if (use_texture) {
		albedo *= texture(albedo_tex, UV).rgb;
	}

	// A little normal break-up from the same texture, so foliage is not lit as a
	// perfectly smooth blob.  Cheaper and steadier than deriving it from geometry.
	if (use_texture) {
		vec3 n = texture(albedo_tex, UV + vec2(0.007, 0.011)).rgb;
		NORMAL = normalize(NORMAL + (n - vec3(0.5)) * 0.35);
	}

	ALBEDO = albedo;
	ROUGHNESS = 0.88;
	SPECULAR = 0.18;
	METALLIC = 0.0;
	// Slight translucency stand-in: canopies backlit by the sun lift a little
	// instead of going flat black, which is what makes foliage read as leaves.
	BACKLIGHT = albedo * 0.22;
}
