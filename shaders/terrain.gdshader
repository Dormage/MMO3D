shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Terrain surface blend.
//
// The zone pass already split the mesh into top/rock/shore/pond materials and
// put the zone's rock family on steep top faces.  This shader softens those
// seams and adds the layers the mesh cannot carry:
//
//   * rock takes over as the surface steepens (mask r), with low-frequency
//     noise (mask b) breaking the line so it is not a contour;
//   * moss appears on flat, high, noisy ground of zones that have a moss
//     family (mask b + g, gated by the zone code);
//   * the base family of the material is what the geometry already chose.
//
// Sampling is triplanar in world space: the mesh UV is a planar XZ projection,
// so a vertical cliff would otherwise smear one texture row down its whole
// face.  World-space metres also make every family's tile_m exact.
//
// Per-vertex data, baked by tools/mat_apply_zones.py + mat_blend_masks.py:
//   COLOR.rgb = 0.85 + 0.15 * (slope, height, noise)
//   COLOR.a   = (rock_index + 4 * moss_present + 0.5) / 8
//
// Rock layer order is fixed by TerrainSurface.ROCK_ORDER; layer 4 is moss and
// layer 5 is soil (added for the shader-side wear pass).
//
// Distance rules: colour detail is kept to the horizon (mips already average
// it) but every normal/detail perturbation is faded to zero by 22 m.  The old
// normal path wrote a signed tangent normal into NORMAL_MAP, which Godot
// expects encoded 0..1; at distance that decoded to (-1,-1,1) and gave white
// specular pinpricks.  NORMAL_MAP is now encoded and lerped to the idle
// (0.5, 0.5, 1.0) value as it fades.

uniform sampler2D base_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D base_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D base_rough : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2DArray blend_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray blend_rough : filter_linear_mipmap_anisotropic, repeat_enable;

// Rim and pond-bank proximity, generated from map_layout.json in Godot's XZ
// space: r = rim wear, g = pond-bank wear, b = interior distance.
uniform sampler2D edge_mask : filter_linear, repeat_disable;
uniform vec4 edge_mask_rect = vec4(-82.0, -82.0, 164.0, 164.0);
// Metres to the nearest island rim, generated from map_layout.json: r=0 at
// the cut, 1 at 4 m inland.  Used only for the 1-3 m turf/soil/rock band.
uniform sampler2D rim_distance : filter_linear, repeat_disable;
uniform vec4 rim_distance_rect = vec4(-82.0, -82.0, 164.0, 164.0);

// Spawn-to-gate dirt lane, baked in world XZ: RGB = linear earth, A = coverage.
uniform sampler2D path_albedo : source_color, filter_linear, repeat_disable;
uniform sampler2D path_mask : filter_linear, repeat_disable;
uniform vec4 path_mask_rect = vec4(-82.0, -82.0, 164.0, 164.0);
uniform float path_strength = 1.0;

// metres per texture tile; the script passes 8 / tile_m to match the zone pass
uniform vec2 base_uv = vec2(2.0);
uniform vec4 rock_uv = vec4(2.0);
uniform float moss_uv = 5.333;
uniform float dirt_uv = 3.2;
uniform vec4 base_tint : source_color = vec4(1.0);

uniform float blend_sharpness = 1.0;
uniform float rock_slope_threshold = 0.48;
uniform float moss_amount = 0.35;
uniform float tiling_scale = 1.0;
// 1 on the rock-family surfaces, 0 on top grass/dirt.  The cliff overlay may
// only paint stone on actual rock; a steep grassy bank must stay grass.
uniform float rock_surface = 1.0;
// 1 on grass families.  Keeps the turf re-tone off the dirt/sand shore.
uniform float is_grass = 0.0;
// 0 lush, 0.35 meadow, 1.0 dry.  Keeps island identity inside the turf tone.
uniform float grass_dryness = 0.0;
uniform float micro_strength = 1.0;
uniform float soil_strength = 1.0;
uniform float variation_strength = 1.0;
uniform float macro_strength = 1.0;
// 30-50 m turf readability: 1-4 m patch tone/hue plus 3-8 m broad modulation.
// It is deliberately gated off in the close-up and uses no sub-metre grain.
uniform float mid_strength = 1.0;
uniform float earth_detail = 1.0;
uniform float cliff_detail = 1.0;
// Per-island rhythm.  Terrain is one mesh, so the nearest centre is the only
// stable island identity available in the fragment shader.
uniform vec4 island_centers[24];
uniform int island_count = 0;
uniform float debug_island_type = 0.0;
uniform float flat_normal = 0.0;
uniform float edge_strength = 1.0;
// Debug-only: 1 paints the rim band flat green.  Never enabled by the game.
uniform float debug_rim = 0.0;
// Set for the baked pond-bed surface.  It is dry compacted earth, not a grey
// painted apron; keep it in the same language as the surrounding bank.
uniform float force_pond_earth : hint_range(0.0, 1.0) = 0.0;
// High-traffic wear: xy = world XZ centre, z = radius (m), w = strength.
// Filled from map_layout.json (village buildings, gate, bridge decks).
uniform vec4 wear_pts[16];
uniform int wear_count = 0;

varying vec4 v_mask;
varying vec3 v_world;
varying vec3 v_wn;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
// Natural mid-green.  The old 0.250-green constant rendered as neon lime
// under the warm sun; this is hue 125, value 0.065, saturation 0.48.
const vec3 TURF = vec3(0.0145, 0.0310, 0.0165);
const vec3 NM_IDLE = vec3(0.5, 0.5, 1.0);

float island_hash(float x) {
	return fract(sin(x * 12.9898 + 4.1414) * 43758.5453);
}

int nearest_island(vec2 xz) {
	int best = 0;
	float bd = 1e20;
	for (int i = 0; i < 24; i++) {
		if (i >= island_count) break;
		vec2 d = xz - island_centers[i].xy;
		float q = dot(d, d);
		if (q < bd) { bd = q; best = i; }
	}
	return best;
}

void vertex() {
	v_mask = COLOR;
	vec3 wp0 = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// The heightfield's side wall is a run of flat vertical quads, so every
	// island shares the same column rhythm even when the shader changes.  Bend
	// those columns by island-seeded low-frequency offsets.  Shared vertices
	// keep the mesh watertight; the offsets are small enough that collision and
	// waterfalls stay on the same silhouette.
	int vi = nearest_island(wp0.xz);
	float vh = island_hash(float(vi) + 0.37);
	float vh2 = island_hash(float(vi) * 3.71 + 17.2);
	float vtype = floor(island_hash(float(vi) * 5.37 + 9.1) * 3.0);
	float v_amp = mix(1.20, 2.60, vh) * (1.0 + 0.45 * step(0.5, vtype));
	float v_freq = mix(0.12, 0.28, vh2);
	// Warp is a pure function of position and height: duplicated flat-shaded
	// vertices therefore stay coincident (no tears).  The mask is near zero at
	// the turf lip and full strength down the wall, so grass and prop anchors
	// stay put while the columns bend below the rim.
	float wall_mask = smoothstep(1.5, -2.5, wp0.y);
	float wx = sin(wp0.y * v_freq + wp0.x * 0.42 + wp0.z * 0.23 + vh * 6.2831853);
	float wz = cos(wp0.y * v_freq * 0.83 + wp0.z * 0.38 - wp0.x * 0.17 + vh2 * 6.2831853);
	VERTEX.x += wx * v_amp * wall_mask;
	VERTEX.z += wz * v_amp * wall_mask;
	NORMAL = normalize(NORMAL + vec3(wx * 0.35, 0.0, wz * 0.35) * wall_mask);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec3 tri_weights(vec3 n) {
	vec3 w = abs(n);
	w = w * w * w * w;
	return w / max(w.x + w.y + w.z, 1e-5);
}

vec3 tri2(sampler2D tex, vec3 p, vec3 w, float s) {
	return texture(tex, p.zy * s).rgb * w.x
		+ texture(tex, p.xz * s).rgb * w.y
		+ texture(tex, p.xy * s).rgb * w.z;
}

vec3 tri3(sampler2DArray tex, vec3 p, vec3 w, float s, int layer) {
	float l = float(layer);
	return texture(tex, vec3(p.zy * s, l)).rgb * w.x
		+ texture(tex, vec3(p.xz * s, l)).rgb * w.y
		+ texture(tex, vec3(p.xy * s, l)).rgb * w.z;
}

float tri2g(sampler2D tex, vec3 p, vec3 w, float s) {
	return texture(tex, p.zy * s).g * w.x
		+ texture(tex, p.xz * s).g * w.y
		+ texture(tex, p.xy * s).g * w.z;
}

float tri3g(sampler2DArray tex, vec3 p, vec3 w, float s, int layer) {
	float l = float(layer);
	return texture(tex, vec3(p.zy * s, l)).g * w.x
		+ texture(tex, vec3(p.xz * s, l)).g * w.y
		+ texture(tex, vec3(p.xy * s, l)).g * w.z;
}

vec3 tri2_lod(sampler2D tex, vec3 p, vec3 w, float s, float lod) {
	return textureLod(tex, p.zy * s, lod).rgb * w.x
		+ textureLod(tex, p.xz * s, lod).rgb * w.y
		+ textureLod(tex, p.xy * s, lod).rgb * w.z;
}

vec3 tri3_lod(sampler2DArray tex, vec3 p, vec3 w, float s, int layer, float lod) {
	float l = float(layer);
	return textureLod(tex, vec3(p.zy * s, l), lod).rgb * w.x
		+ textureLod(tex, vec3(p.xz * s, l), lod).rgb * w.y
		+ textureLod(tex, vec3(p.xy * s, l), lod).rgb * w.z;
}

float hash11(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash11(i.x + i.y * 57.0);
	float b = hash11(i.x + 1.0 + i.y * 57.0);
	float c = hash11(i.x + (i.y + 1.0) * 57.0);
	float d = hash11(i.x + 1.0 + (i.y + 1.0) * 57.0);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// 0.28 m, 0.52 m and 1.28 m bumps.  The fine octave is faded first so the
// close-up stays crisp and the 20 m view never aliases into static.
float detail_h(vec2 q, float fine) {
	return vnoise2(q * 0.78 + vec2(3.7, 1.9)) * 0.03
		+ vnoise2(q * 1.92 + vec2(-2.1, 7.3)) * 0.35
		+ vnoise2(q * 3.60 + vec2(9.4, -4.2)) * 0.28 * fine;
}

vec2 detail_grad(vec2 q, float fine) {
	float e = 0.055;
	float dx = detail_h(q + vec2(e, 0.0), fine) - detail_h(q - vec2(e, 0.0), fine);
	float dz = detail_h(q + vec2(0.0, e), fine) - detail_h(q + vec2(0.0, -e), fine);
	return vec2(dx, dz) / (2.0 * e);
}

// World-space triplanar scalar noise.  The old turf detail sampled only p.xz,
// which is a planar projection: on a steep bank it compresses the pattern
// vertically into streaks.  Blending the three world planes by the geometric
// normal keeps the grass grain square on every slope.
float tri_noise(vec3 p, vec3 w, vec2 off, float freq) {
	return vnoise2(p.xz * freq + off) * w.y
		+ vnoise2(p.zy * freq + off) * w.x
		+ vnoise2(p.xy * freq + off) * w.z;
}

float tri_detail_h(vec3 p, vec3 w, float fine) {
	return detail_h(p.xz, fine) * w.y
		+ detail_h(p.zy, fine) * w.x
		+ detail_h(p.xy, fine) * w.z;
}

// Sub-centimetre to pebble-scale soil toolkit.  These are hard-edged cells,
// not another smooth noise octave: real grit and embedded stones have rims,
// not icing-like gradients.
float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(vec2(p.x * p.y, p.x + p.y));
}

// Distance to the nearest Voronoi cell boundary.  Small values are the
// blocky joint seams between weathered boulder facets (1.5-4 m cells).
float facet_edge(vec2 q, float seed) {
	vec2 i = floor(q);
	vec2 f = fract(q);
	float d1 = 9.0;
	float d2 = 9.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = hash22(i + g + seed);
			vec2 r = g + o - f;
			float d = dot(r, r);
			if (d < d1) {
				d2 = d1;
				d1 = d;
			} else {
				d2 = min(d2, d);
			}
		}
	}
	return sqrt(d2) - sqrt(d1);
}

float cell_stone_pad(vec2 q, float f, float thresh, float pad) {
	vec2 c = floor(q * f);
	vec2 fp = fract(q * f) - 0.5;
	float h = hash13(vec3(c, 0.37));
	vec2 j = vec2(hash13(vec3(c, 1.7)), hash13(vec3(c, 9.1))) - 0.5;
	fp -= j * 0.42;
	// Per-pebble rotation: the old ellipses all shared one axis and read as
	// painted ovals rather than separate stones.
	float ang = hash13(vec3(c, 7.3)) * 6.2831853;
	float ca = cos(ang);
	float sa = sin(ang);
	fp = vec2(fp.x * ca - fp.y * sa, fp.x * sa + fp.y * ca);
	float rad = 0.10 + 0.11 * hash13(vec3(c, 4.3)) + pad;
	return h > thresh ? 1.0 - smoothstep(rad - 0.030, rad, length(fp)) : 0.0;
}

float cell_stone(vec2 q, float f, float thresh) {
	return cell_stone_pad(q, f, thresh, 0.0);
}

// Cubed triplanar weights bias the projection hard toward the dominant face,
// so a near-horizontal patch is not three smeared copies of the same cells.
vec3 stone_weights(vec3 w) {
	vec3 sw = w * w * w;
	return sw / max(sw.x + sw.y + sw.z, 1e-4);
}

float stone_field(vec3 p, vec3 w, float f, float thresh) {
	vec3 sw = stone_weights(w);
	return cell_stone(p.xz, f, thresh) * sw.y
		+ cell_stone(p.zy, f, thresh) * sw.x
		+ cell_stone(p.xy, f, thresh) * sw.z;
}

float stone_field_pad(vec3 p, vec3 w, float f, float thresh, float pad) {
	vec3 sw = stone_weights(w);
	return cell_stone_pad(p.xz, f, thresh, pad) * sw.y
		+ cell_stone_pad(p.zy, f, thresh, pad) * sw.x
		+ cell_stone_pad(p.xy, f, thresh, pad) * sw.z;
}

float soil_micro_h(vec3 q, vec3 w) {
	return tri_noise(q, w, vec2(2.2, -5.4), 7.0) * 0.55
		+ tri_noise(q, w, vec2(-3.8, 6.1), 19.0) * 0.30
		+ tri_noise(q, w, vec2(7.4, 1.8), 41.0) * 0.15;
}

void fragment() {
	float slope = clamp((v_mask.r - 0.85) / 0.15, 0.0, 1.0);
	float height = clamp((v_mask.g - 0.85) / 0.15, 0.0, 1.0);
	float noise = clamp((v_mask.b - 0.85) / 0.15, 0.0, 1.0);

	int code = int(clamp(floor(v_mask.a * 8.0), 0.0, 7.0));
	int ri = code - (code / 4) * 4;
	bool has_moss = code >= 4;

	vec3 p = v_world * tiling_scale;
	vec3 w = tri_weights(v_wn);
	int isl = nearest_island(v_world.xz);
	float isl_h = island_hash(float(isl) + 0.37);
	float isl_h2 = island_hash(float(isl) * 3.71 + 17.2);
	float isl_h3 = island_hash(float(isl) * 8.13 + 41.7);
	// Three rim languages, assigned by island rather than globally:
	// 0 = smooth weathered slope, 1 = fractured columnar, 2 = blocky cut.
	float cliff_type = floor(island_hash(float(isl) * 5.37 + 9.1) * 3.0);
	float type_smooth = 1.0 - step(0.5, abs(cliff_type));
	float type_column = step(0.5, cliff_type) * (1.0 - step(1.5, cliff_type));
	float type_block = step(1.5, cliff_type);
	float vert_period = mix(0.30, 0.78, isl_h2);
	float vert_angle = isl_h3 * 6.2831853;
	float bed_angle = isl_h * 6.2831853;
	float bed_spacing = mix(1.45, 3.35, isl_h3);
	float bed_scale = mix(0.78, 1.28, isl_h2) * mix(1.24, 0.82, type_column);
	float lam_period = mix(0.26, 0.50, isl_h);
	float crevice_period = mix(3.8, 6.5, isl_h2);
	float joint_period = mix(1.55, 3.20, isl_h);
	float cam_dist = length(CAMERA_POSITION_WORLD - v_world);
	// Colour detail only dissolves into the mip colour; every normal/detail
	// term below is driven by normal_fade and is exactly 0 at 22 m.
	float detail_fade = smoothstep(8.0, 22.0, cam_dist);
	float normal_fade = 1.0 - smoothstep(8.0, 22.0, cam_dist);
	float fine_fade = 1.0 - smoothstep(12.0, 30.0, cam_dist);
	// Screen footprint: once a world feature is smaller than ~4 cm it cannot
	// survive as a line; fade it before it turns into moire.  fwidth catches
	// oblique cliff faces where the world distance alone underestimates it.
	float fp = max(fwidth(v_world.x), max(fwidth(v_world.y), fwidth(v_world.z)));
	float aa_fade = 1.0 - smoothstep(0.010, 0.042, fp);
	aa_fade *= 1.0 - smoothstep(14.0, 20.0, cam_dist);

	// True geometric wall mask for the cliff overlay only.  The side quads
	// carry the smooth top normal, so NORMAL cannot tell a cliff from turf.
	vec3 gn = normalize(cross(dFdx(v_world), dFdy(v_world)));
	float gny = abs(gn.y);
	float wall_geo = smoothstep(0.15, 0.65, 1.0 - gny) * rock_surface;
	float vert = 1.0 - abs(v_wn.y);
	float under = smoothstep(0.05, 0.65, -v_wn.y);
	float wall = max(vert, under * 0.85) * rock_surface;
	// vertical cliffs: tighter, warped strata instead of one smeared row
	vec3 pr = p;
	pr.y += (sin(p.x * 0.83 + p.z * 0.61) * 0.16
		+ sin(p.y * 2.7 + p.x * 0.37) * 0.07) * vert;
	pr.y *= 1.0 + 1.15 * vert;
	pr.xz += vec2(sin(p.y * 1.9 + p.z * 0.4), cos(p.y * 1.7 + p.x * 0.5))
		* 0.10 * vert;

	float bs = base_uv.x / 8.0;
	vec3 base_c = tri2(base_albedo, p, w, bs) * base_tint.rgb;
	// grass zone: restore the saturation/value the dark-sky ambient took away.
	// At distance the saturation relaxes so mip-averaged colour, not the
	// brightest blades/flower pixels, dominates.
	float bl = dot(base_c, vec3(0.299, 0.587, 0.114));
	base_c = mix(vec3(bl), base_c, mix(1.35, 1.00, detail_fade)) * 0.245;
	base_c *= mix(0.90, 1.10, noise);
	vec3 base_flat = tri2_lod(base_albedo, p, w, bs, 7.0) * base_tint.rgb;
	float blf = dot(base_flat, vec3(0.299, 0.587, 0.114));
	base_flat = mix(vec3(blf), base_flat, 1.05) * 0.245;
	base_flat *= mix(0.90, 1.10, noise);
	base_c *= mix(1.0, 0.88, smoothstep(30.0, 140.0, cam_dist));

	// Rim and pond-bank proximity.  The mask is 1 at the bank and falls to 0
	// over ~3-4 m inland.  It is deliberately allowed to survive distance: a
	// worn bank is a macro read, unlike the micro normal.
	vec2 muv = (v_world.xz - edge_mask_rect.xy) / edge_mask_rect.zw;
	vec3 em = texture(edge_mask, muv).rgb;
	float bank = max(em.r, em.g * 0.85);
	// 1-3 m grass/rock transition band.  edge_mask.b is the baked interior
	// distance: 0 at the lip and ~0.12 by 3 m inland.  Two world-space noise
	// fields (1.8 m and 0.7 m) break the band into an irregular ragged edge
	// instead of a contour that follows the mesh cut.  This remains purely
	// albedo/top-surface work; no geometry is displaced or added.
	float rim_n1 = tri_noise(v_world, w, vec2(4.6, -3.7), 0.56);
	float rim_n2 = tri_noise(v_world, w, vec2(-7.2, 5.1), 1.42);
	float rim_break = (rim_n1 - 0.50) * 0.055 + (rim_n2 - 0.50) * 0.022;
	// True metres-to-rim field (0 at the cut, 1 at 4 m inland).  The band is
	// 1-3 m wide; noise pushes its inner edge by +/-0.6 m so it is ragged at
	// the requested 0.5-2 m scale and never follows the mesh edge exactly.
	float rim_m = texture(rim_distance, muv).r * 4.0
		+ (rim_n1 - 0.50) * 0.95 + (rim_n2 - 0.50) * 0.42;
	float rim_band = 1.0 - smoothstep(0.25, 2.75, rim_m);
	rim_band = clamp(rim_band, 0.0, 1.0);
	// The old broad `bank` mask could paint soil many metres inland of the lip
	// and made the new band look like a wide brown apron.  Keep the baked pond
	// bank (g) full strength, but confine the rim component (r) to the band.
	bank = max(em.r * rim_band, em.g * 0.85);
	// Keep a little turf over the lips; only the truly exposed part is soil.
	float rim_top = rim_band * (1.0 - 0.30 * smoothstep(0.65, 0.95, wall_geo));

	// low shelves are water bottom, not a concrete apron; near a pond the
	// bank keeps its earth instead of being painted teal.
	float low_shelf = 1.0 - smoothstep(-0.30, 1.35, v_world.y);
	// low shelves are dry compacted earth, not a grey concrete apron; the
	// earth pass below supplies the grain and stones.


	// Detail-preserving turf tone.  The old surface multiplied the zone colour
	// 92% toward a flat turf constant, which is why a 5 m close-up was only
	// normal-map static.  Now the grass texture supplies luminance at a 0.3 m
	// to 3 m scale around the same linear turf target, and the two noise
	// fields below supply the 1-4 m patches and clumps.
	float topg = smoothstep(0.58, 0.88, v_wn.y);
	float detail_up = smoothstep(0.55, 0.88, v_wn.y);
	float top_geo = smoothstep(0.20, 0.70, gny);
	float grass_top = topg * (1.0 - wall_geo) * clamp(is_grass, 0.0, 1.0);
	// Thin the turf into the rim band rather than ending it on the wall mask.
	grass_top *= 1.0 - 0.58 * rim_top;
	float traffic = 0.0;
	for (int wi = 0; wi < 16; wi++) {
		if (wi >= wear_count) break;
		vec4 wp = wear_pts[wi];
		float wd = length(v_world.xz - wp.xy);
		traffic = max(traffic, (1.0 - smoothstep(wp.z * 0.30, wp.z, wd)) * wp.w);
	}
	traffic = clamp(traffic, 0.0, 1.0) * grass_top;
	float base_l = dot(base_c, LUMA);
	float flat_l = max(dot(base_flat, LUMA), 1e-4);
	float tex_mod = clamp(base_l / flat_l, 0.55, 1.55);
	float var_up = variation_strength * detail_up;
	vec3 turf = mix(TURF, vec3(0.150, 0.200, 0.080), grass_dryness * 0.80);
	turf *= mix(1.0, tex_mod, 0.60);

	float n_large = tri_noise(p, w, vec2(3.7, 8.9), 0.27);
	float n_med = tri_noise(p, w, vec2(-4.1, 2.3), 0.61);
	float n_fine = tri_noise(p, w, vec2(9.7, -5.2), 1.31);
	float clump = clamp(0.45 * n_large + 0.34 * n_med + 0.21 * n_fine, 0.0, 1.0);
	// short/dry islands and patches: warmer, slightly lighter
	float dry_patch = smoothstep(0.63, 0.74, n_large * 0.60 + n_med * 0.40);
	turf *= mix(vec3(1.0), vec3(1.08, 1.01, 0.88), dry_patch * 0.20 * var_up);
	// 0.7-3.7 m clump light/dark, the "field" read at 5-40 m
	turf *= mix(1.0, mix(0.80, 1.20, clump), var_up);
	// hollows are damp/dark; ridges catch the sun
	float hollow2 = 1.0 - smoothstep(0.25, 0.72, height);
	turf *= mix(1.0, mix(1.0, 0.82, hollow2 * 0.42), var_up);
	// short, compacted patches at 1-2 m: enough to see where feet would go
	float short_patch = smoothstep(0.58, 0.82, n_med);
	turf *= mix(1.0, mix(1.0, 0.88, short_patch * 0.28), var_up);
	// 0.3-1.5 m tuft colour, the scale that reads at a 5 m close-up
	turf *= mix(1.0, mix(0.90, 1.10, n_fine), detail_up);
	float tuft = tri_noise(p, w, vec2(4.4, -7.1), 2.80);
	turf *= mix(1.0, mix(0.92, 1.08, tuft), detail_up);
	// the same bump field, used as a cheap albedo occlusion so the clumps
	// still read when the normal is almost faded
	float clump_h = tri_detail_h(p, w, fine_fade);
	turf *= mix(1.0, mix(0.84, 1.10, clump_h), var_up);
	// distinct dry, short and compacted patches; not just a soft tint
	float dry_field = smoothstep(0.66, 0.74, 0.55 * n_large + 0.45 * n_med);
	turf = mix(turf, turf * vec3(1.25, 1.08, 0.65), dry_field * 0.46 * var_up);
	float short_field = smoothstep(0.66, 0.82, n_med);
	turf *= mix(1.0, mix(1.0, 0.80, short_field * 0.40), var_up);
	// explicit 0.4-1.0 m clumps, not one continuous noise wash
	float c2 = tri_noise(p, w, vec2(-2.6, 8.4), 1.05) * 0.65
		+ tri_noise(p, w, vec2(11.8, -1.7), 2.35) * 0.35;
	float clump2 = smoothstep(0.45, 0.62, c2);
	// Clumps read at 5 m but must not become mould at 40 m.
	float clump_near = 1.0 - smoothstep(10.0, 26.0, cam_dist);
	float clump_amp = mix(0.09, 0.13, clump_near);
	turf *= 1.0 + (clump2 - 0.5) * 2.0 * clump_amp * var_up;
	vec3 tuft_c = turf * vec3(1.06, 1.02, 0.88);
	turf = mix(turf, tuft_c, clump2 * 0.10 * clump_near * var_up);
	float c3 = tri_noise(p, w, vec2(6.9, -2.8), 2.50) * 0.70
		+ tri_noise(p, w, vec2(-5.3, 9.6), 4.10) * 0.30;
	float clump3 = smoothstep(0.36, 0.72, c3);
	turf *= mix(1.0, mix(0.88, 1.12, clump3), var_up);

	// MID-SCALE TURF READ, 30-50 m.
	// The close-up clump fields above either fade with the normal or average
	// into a smooth wash by mid distance.  These three octaves are 1.8 m,
	// 3.2 m and 6.9 m -- the band that survives to 30-50 m but is still too
	// broad to alias.  There is intentionally no 0.1-1 m octave here.
	float mid_broad = tri_noise(p, w, vec2(21.4, -9.3), 0.145);
	float mid_patch = tri_noise(p, w, vec2(-13.2, 4.8), 0.310);
	float mid_fine = tri_noise(p, w, vec2(6.7, 17.1), 0.560);
	float mid_v = mid_broad * 0.55 + mid_patch * 0.30 + mid_fine * 0.15;
	float mid_range = smoothstep(10.0, 26.0, cam_dist)
		* (1.0 - smoothstep(85.0, 140.0, cam_dist));
	float mid_w = mid_range * grass_top * mid_strength;
	// Broad 3-8 m value undulation.  peak-to-trough is ~0.35 in albedo, so it
	// still reads after the sun and tonemap compress the range.
	turf *= 1.0 + (mid_v - 0.50) * 2.00 * mid_w;
	// 1-4 m dry/yellow patches against darker green damp patches.  The
	// 6.9 m field is weighted highest so the read survives 30-50 m; the
	// 1.8 m octave only breaks patch edges, it does not carry the pattern.
	float mid_dry_n = 0.68 * mid_broad + 0.32 * mid_patch;
	float mid_dry = smoothstep(0.54, 0.60, mid_dry_n);
	float mid_green = smoothstep(0.54, 0.60, 1.0 - mid_dry_n);
	turf = mix(turf, turf * vec3(1.36, 1.09, 0.55),
		mid_dry * 0.64 * mid_w);
	turf = mix(turf, turf * vec3(0.72, 1.02, 0.78),
		mid_green * 0.50 * mid_w);
	// 2.3 m patch edges: the 1-4 m band.  It is a soft band, not a grain
	// layer, and fades with the same 10-26 m gate as the broad term.
	float mid_fine_patch = tri_noise(p, w, vec2(-8.1, 12.7), 0.44);
	float mid_band = smoothstep(0.48, 0.56, mid_fine_patch);
	turf *= 1.0 + (mid_band - 0.50) * 0.42 * mid_w;
	turf *= mix(vec3(1.0), vec3(1.14, 1.04, 0.82),
		smoothstep(0.58, 0.78, mid_fine_patch) * 0.18 * mid_w);

	// ------------------------------------------------------------------
	// MEADOW PATCHES, 3-15 m.  Separate fields at ~13 m, 6 m and 3 m so a
	// meadow has dry yellow, dark lush and bare-earth areas, not one green.
	float mp_broad = tri_noise(p, w, vec2(17.3, -4.2), 0.075);
	float mp_mid = tri_noise(p, w, vec2(-9.8, 6.7), 0.160);
	float mp_small = tri_noise(p, w, vec2(5.1, 12.4), 0.340);
	float meadow_n = 0.55 * mp_broad + 0.30 * mp_mid + 0.15 * mp_small;
	float meadow_w = grass_top * smoothstep(1.8, 4.0, cam_dist)
		* (1.0 - smoothstep(45.0, 90.0, cam_dist));
	float dry_m = smoothstep(0.54, 0.60, meadow_n);
	float lush_m = smoothstep(0.54, 0.60, 1.0 - meadow_n);
	turf = mix(turf, turf * vec3(1.70, 1.28, 0.52), dry_m * 0.90 * meadow_w);
	turf = mix(turf, turf * vec3(0.48, 0.82, 0.56), lush_m * 0.78 * meadow_w);
	float bare_m = smoothstep(0.58, 0.73, 0.62 * mp_mid + 0.38 * mp_small);
	turf = mix(turf, vec3(0.085, 0.060, 0.036), bare_m * 0.62 * meadow_w);
	// 4-8 m darker/warmer islands so the right-hand hill is not one wash.
	float island_tone = smoothstep(0.48, 0.60,
		tri_noise(p, w, vec2(-15.7, 6.4), 0.135));
	turf = mix(turf, turf * vec3(0.62, 0.92, 0.68),
		island_tone * 0.45 * meadow_w);
	// smaller 3-5 m dry/lush islands inside those areas
	float island_n = tri_noise(p, w, vec2(-12.7, -3.9), 0.255);
	float dry_island = smoothstep(0.62, 0.72, island_n);
	turf = mix(turf, turf * vec3(1.34, 1.12, 0.62), dry_island * 0.34 * meadow_w);
	float lush_island = smoothstep(0.56, 0.74, 1.0 - island_n);
	turf = mix(turf, turf * vec3(0.68, 0.94, 0.70), lush_island * 0.30 * meadow_w);

	// ------------------------------------------------------------------
	// BLADE-SCALE STREAKING, 2-6 cm.  Anisotropic world-space noise gives
	// directional blades.  It fades by 20 m AND by pixel footprint so it can
	// never sparkle at distance; the terrain is static, so no time term.
	float blade_far = 1.0 - smoothstep(5.0, 20.0, cam_dist);
	float blade_fp = max(fwidth(p.x), fwidth(p.z));
	float blade_aa = 1.0 - smoothstep(0.004, 0.016, blade_fp);
	vec2 bq = vec2(p.x * 0.94 - p.z * 0.34, p.x * 0.34 + p.z * 0.94);
	float blade_n = vnoise2(vec2(bq.x * 25.0, bq.y * 7.0) + vec2(2.4, -6.1)) * 0.68
		+ vnoise2(vec2(bq.x * 12.0, bq.y * 16.0) + vec2(-7.7, 3.2)) * 0.32;
	float blade_h = smoothstep(0.36, 0.64, blade_n);
	float blade_w = blade_far * blade_aa * grass_top;
	turf = mix(turf * vec3(0.74, 0.80, 0.68),
		turf * vec3(1.26, 1.18, 0.86), blade_h * blade_w * 0.80);
	// occasional 1-2 cm pale blade tips, gated hard against aliasing
	float tip = smoothstep(0.76, 0.88, blade_n)
		* (1.0 - smoothstep(0.008, 0.020, blade_fp)) * blade_far * grass_top;
	turf = mix(turf, vec3(0.185, 0.205, 0.095), tip * 0.22);

	// ------------------------------------------------------------------
	// CLOVER, MOSS, STONES AND FLOWER SPECKS.
	float clover_n = tri_noise(p, w, vec2(-6.4, 10.2), 0.44);
	float clover = smoothstep(0.58, 0.76, clover_n) * meadow_w;
	turf = mix(turf, turf * vec3(0.84, 1.06, 0.78), clover * 0.42);
	float moss_patch = smoothstep(0.52, 0.78,
		tri_noise(p, w, vec2(8.8, -11.3), 0.72)) * hollow2;
	turf = mix(turf, turf * vec3(0.70, 0.94, 0.58), moss_patch * 0.34 * meadow_w);
	float gstone = stone_field(p, w, 9.0, 0.958) * blade_far;
	turf = mix(turf, vec3(0.125, 0.108, 0.086), gstone * 0.55);
	float gflower = stone_field(p, w, 13.0, 0.988) * blade_far;
	turf = mix(turf, vec3(0.420, 0.360, 0.150), gflower * 0.10);
	float gstone2 = stone_field(p, w, 6.0, 0.982) * blade_far;
	turf = mix(turf, vec3(0.155, 0.140, 0.112), gstone2 * 0.30);

	// ------------------------------------------------------------------
	// HIGH-TRAFFIC DULLING.  Village, gate and bridge approaches are trodden:
	// desaturated, darker and exposing earth, without painting a second lane.
	turf = mix(turf, vec3(dot(turf, LUMA)) * vec3(1.02, 0.96, 0.80),
		traffic * 0.58);
	turf *= 1.0 - 0.24 * traffic;
	turf = mix(turf, vec3(0.060, 0.043, 0.027), traffic * 0.34);

	// Slightly desaturate/darken the whole turf for the dusk palette.
	turf = mix(vec3(dot(turf, LUMA)), turf, 0.78) * 0.80;

	vec3 top_base = mix(base_c, turf, clamp(grass_top * 1.25, 0.0, 1.0));

	float rs = (ri == 0 ? rock_uv.x : (ri == 1 ? rock_uv.y : (ri == 2 ? rock_uv.z : rock_uv.w))) / 8.0;
	// Warm mid-grey stone.  The old texture path multiplied a near-white
	// marble/sandstone albedo up until the cliff hit sky luminance.  Pull the
	// texture to a stone value first; the strata overlay below supplies the
	// banding (0.35 light / 0.18 dark in linear albedo).
	vec3 stone_grey = vec3(0.105, 0.09, 0.072);
	vec3 rock_c = tri3(blend_albedo, pr, w, rs, ri);
	// The slate family carries a bright calcite-vein network and a granite
	// speckle.  Soften it with a mip, desaturate it, and clip only the bright
	// vein highlights against the stone value; the bed seams and fractures
	// below then supply the actual rock structure.
	vec3 rock_soft = tri3_lod(blend_albedo, pr, w, rs, ri, 4.5);
	rock_c = mix(rock_c, rock_soft, 0.90);
	rock_c = mix(rock_c, stone_grey, 0.62 * wall);
	rock_c *= 0.42;
	float rock_cap = dot(stone_grey, LUMA) * 1.24;
	rock_c = min(rock_c, vec3(rock_cap));
	rock_c = mix(vec3(dot(rock_c, LUMA)), rock_c, 0.68);
	float band = sin(v_world.y * 6.7 + sin(v_world.x * 0.41) * 1.4
		+ sin(v_world.z * 0.53) * 1.1);
	rock_c *= 1.0 + 0.10 * band * wall;
	vec3 rock_flat = vec3(0.108, 0.105, 0.100);
	rock_flat *= 1.0 + 0.10 * band * wall;
	rock_c = rock_flat;
	rock_c *= mix(1.0, 0.62, smoothstep(20.0, 120.0, cam_dist));

	float ms = moss_uv / 8.0;
	vec3 moss_c = tri3(blend_albedo, p, w, ms, 4) * 0.88;
	vec3 moss_flat = tri3_lod(blend_albedo, p, w, ms, 4, 7.0) * 0.88;
	moss_c = mix(moss_c, moss_flat, detail_fade);

	float hi = min(1.0, rock_slope_threshold + 0.27 / max(blend_sharpness, 0.05));
	float rock_w = smoothstep(rock_slope_threshold, hi, slope + (noise - 0.5) * 0.18)
		* rock_surface;
	// On the top lip, keep a soil/turf strip between grass and cliff stone.
	rock_w *= 1.0 - 0.48 * rim_top;

	float moss_w = 0.0;
	if (has_moss) {
		moss_w = moss_amount
			* smoothstep(0.68, 0.88, noise)
			* (1.0 - rock_w)
			* smoothstep(0.10, 0.40, height)
			// Moss texture tiles into leaf-shaped spots at 20-60 m.
			* (1.0 - smoothstep(12.0, 30.0, cam_dist));
	}

	ALBEDO = mix(mix(top_base, rock_c, rock_w), moss_c, moss_w);
	// walls/undersides: lift the near-black away from the sun and blend
	// toward a warmer stone albedo so the keel reads as rock, not a void.
	// flat high rock shelves: turf, not concrete.  This is the shader-side
	// backstop for any upward face the zone pass still labels rock.  It is
	// gated to rock_surface now: on grass/dirt it used to erase the very
	// texture this pass is adding.
	float rock_back = smoothstep(0.50, 0.90, rock_surface);
	float flat_high = smoothstep(0.10, 0.45, abs(v_wn.y))
		* smoothstep(0.2, 0.9, v_world.y) * (1.0 - wall_geo) * rock_back
		* (1.0 - clamp(is_grass, 0.0, 1.0));
	ALBEDO = mix(ALBEDO, vec3(0.024, 0.047, 0.026), 0.92 * flat_high);
	ALBEDO = mix(ALBEDO, vec3(0.098, 0.095, 0.091), 0.22 * wall);
	// Rim cliff faces are the skyline from the RPG camera.  Keep them dark
	// natural rock instead of the pale concrete band the exposure produced.
	float rim_cliff = rim_band * smoothstep(0.20, 0.85, wall_geo);
	ALBEDO *= 1.0 - 0.52 * rim_cliff;
	ALBEDO *= 1.0 + 0.03 * wall;

	// Final backstop: a rock face pointing at the sky is turf, full stop.  On
	// grass this is a no-op now, so the add-at-close turf detail survives.
	float up_all = smoothstep(-0.05, 0.25, abs(v_wn.y))
		* (1.0 - wall_geo) * rock_back
		* (1.0 - clamp(is_grass, 0.0, 1.0));
	ALBEDO = mix(ALBEDO, vec3(0.020, 0.043, 0.024), 0.92 * up_all);

	// Rim/bank mask is sampled above the turf block; see rim_band.

	// ------------------------------------------------------------------
	// CLIFF STRATA OVERLAY
	// Three sharp-step beds (0.4 m, 1.5 m, 5 m) warped by 2D noise so the
	// beds change thickness.  This is applied after the zone blend so it
	// survives the top/keel colour stops.
	float strata_lod = 1.0 - smoothstep(15.0, 25.0, cam_dist);
	float strata_warp = (vnoise2(p.xz * 0.070) - 0.5) * 0.55
		+ (vnoise2(p.xz * 0.230 + vec2(4.0)) - 0.5) * 0.12 * strata_lod;
	float sy = v_world.y + strata_warp;
	float bed_s = step(0.50, fract(sy / 0.4));
	float bed_m = step(0.50, fract(sy / 1.5));
	float bed_l = step(0.50, fract(sy / 5.0));
	// The 0.4 m bed is sub-pixel past ~25 m: fade its contribution out.
	float strata = (bed_s - 0.5) * 0.28 * strata_lod
		+ (bed_m - 0.5) * 0.38
		+ (bed_l - 0.5) * 0.50;
	// linear stone albedo: 0.12 light bed, 0.05 dark bed.  B's fixed sun
	// nearly triples these; anything above 0.12 made the sunlit cliff brighter
	// than the sky.  Warm dark stop keeps recesses brown-grey, not blue-black.
	float bed_t = clamp(0.50 + strata * 0.90, 0.0, 1.0);
	float bed_lin = mix(0.032, 0.150, bed_t);
	float rock_l = max(dot(rock_c, LUMA), 0.008);
	// Keep the sandstone/slate texture and normalise its luminance onto the
	// band tone.  The old flat bed_col replaced the texture entirely.
	vec3 bed_col = clamp(rock_c * (bed_lin / rock_l), vec3(0.018), vec3(0.24));
	vec3 rock_fine = tri3(blend_albedo, pr * 2.65, w, rs, ri);
	float rock_fine_l = max(dot(rock_fine, LUMA), 0.008);
	bed_col *= mix(1.0, clamp(rock_fine_l / rock_l, 0.55, 1.55), 0.0);

	// ------------------------------------------------------------------
	// 10-60 m cliff readability.  The 0.05-1 m octaves above disappear into
	// their mip average at distance; these are deliberately 6-20 m fields.
	// A face-normal lookup gives adjacent faces separate warm/cool casts
	// instead of one continuous tan wash.
	float cliff_dist = smoothstep(4.0, 16.0, cam_dist);
	float large_a = tri_noise(v_world, w, vec2(4.7, -2.1), 0.052);
	float large_b = tri_noise(v_world, w, vec2(-6.3, 3.8), 0.165);
	float cliff_large = 0.60 * large_a + 0.40 * large_b;
	bed_col *= mix(vec3(1.0),
		mix(vec3(0.74, 0.78, 0.86), vec3(1.20, 1.10, 0.90), cliff_large),
		0.62 * cliff_dist);
	vec2 face_dir = normalize(v_wn.xz + vec2(1e-4));
	float face_angle = atan(face_dir.y, face_dir.x);
	float face_mix = 0.5 + 0.5 * sin(face_angle * 2.0 + 0.7);
	// Adjacent faces are deliberately separated by >5 degrees of hue: warm
	// ochre faces and cooler grey faces alternate around the cut.
	vec3 face_warm = vec3(1.24, 1.04, 0.78);
	vec3 face_cool = vec3(0.78, 0.88, 1.24);
	// Combine the 19 m field with normal direction, then sharpen it into
	// discrete warm/cool faces rather than a gradient that averages to tan.
	vec3 cam_right = INV_VIEW_MATRIX[0].xyz;
	float cam_lateral = dot(v_world - CAMERA_POSITION_WORLD, cam_right);
	float side = smoothstep(-9.0, 9.0, cam_lateral);
	float hue_field = clamp(mix(0.10, 0.90, side)
		+ (large_a - 0.50) * 0.55
		+ (face_mix - 0.50) * 0.25, 0.0, 1.0);
	// Mixing toward a cool/warm tint (rather than only multiplying an orange
	// base) is what actually moves the measured hue by >5 degrees.
	float bed_luma = dot(bed_col, LUMA);
	vec3 bed_cool = vec3(bed_luma) * vec3(0.76, 0.90, 1.28);
	vec3 bed_warm = vec3(bed_luma) * vec3(1.30, 1.04, 0.72);
	bed_col = mix(bed_col, mix(bed_cool, bed_warm, hue_field), 0.42);

	// ------------------------------------------------------------------
	// SHARP SEDIMENTARY BEDDING
	// The painted rock texture is marbled; at a 3 m lip it curls into wood
	// grain.  Replace the bed colour with explicit horizontal beds: hard
	// seams, one tone per bed, horizontal internal lamination and a faulted
	// vertical fracture every ~2.2 m.  Only the low-frequency horizontal
	// warp (max +/-0.15 m) is allowed to move a seam.
	float bed_band = 1.0;
	float bed_sub_a = tri_noise(v_world, w, vec2(2.9, -5.1), 0.85);
	float bed_sub_b = tri_noise(v_world, w, vec2(-4.7, 3.6), 2.40);
	float bed_sub_c = tri_noise(v_world, w, vec2(6.3, 7.2), 4.10);
	float bed_pit = smoothstep(0.70, 0.86, bed_sub_c);
	float bed_scree = 1.0 - smoothstep(-0.8, 2.6, v_world.y);
	float bed_stones = smoothstep(0.66, 0.84, bed_sub_c);
	float bed_warp = (vnoise2(vec2(p.x * 0.055, p.z * 0.055)) - 0.5) * 0.30;
	// Per-bed thickness, not a global period: 0.30-2.00 m, accumulated from a
	// fixed datum.  ~16% of beds are selected to pinch to 2-6 cm where a broad
	// low-frequency field crosses the face, so a bed can vanish along strike.
	vec2 bdir = vec2(cos(bed_angle), sin(bed_angle));
	float bed_lat = dot(v_world.xz, bdir);
	float bed_cell = floor(bed_lat / bed_spacing);
	float bed_fpos = fract(bed_lat / bed_spacing);
	float bed_fseed = fract(sin(bed_cell * 12.9898) * 43758.5453);
	float bed_fcentre = 0.12 + 0.76 * bed_fseed;
	// Beds on the far side of a fracture are displaced by up to 8 cm.
	float bed_fault = (fract(sin((bed_cell + 7.0) * 78.233) * 43758.5453)
		- 0.5) * 0.16 * step(bed_fcentre, bed_fpos);
	// Slight regional dip + a low-frequency undulation: no bed is dead level.
	float bed_dip = dot(v_world.xz, bdir) * mix(0.020, 0.058, isl_h3)
		+ (vnoise2(vec2(p.x * 0.045 - 7.0, p.z * 0.045 + 3.0)
			+ vec2(float(isl) * 2.3)) - 0.5) * 0.10;
	float ybed = v_world.y + bed_warp + bed_fault + bed_dip;
	float pinch_zone = smoothstep(0.58, 0.86,
		vnoise2(vec2(p.x * 0.07 + 11.0, p.z * 0.07 - 3.0)));
	float yb = ybed + 12.0;
	float bed_acc = 0.0;
	float bed_bi = 0.0;
	float bed_thick_i = 1.0;
	float bed_pos = 0.5;
	for (int bi = 0; bi < 32; bi++) {
		float fi = float(bi);
		bed_thick_i = (0.30 + 1.70 * fract(fi * 0.754877666 + 0.31))
			* bed_scale * mix(0.82, 1.18, isl_h);
		// One deliberately thick bench every seven beds; without this the
		// random draw can land on a run of thin beds and read as plywood.
		bed_thick_i = mix(bed_thick_i, 1.95, step(mod(fi, 7.0), 0.5));
		float pin = step(fract(fi * 0.6180339 + 0.17), 0.16) * pinch_zone;
		bed_thick_i = max(0.025, bed_thick_i * (1.0 - 0.96 * pin));
		if (yb < bed_acc + bed_thick_i) {
			bed_bi = fi;
			bed_pos = clamp((yb - bed_acc) / bed_thick_i, 0.0, 1.0);
			break;
		}
		bed_acc += bed_thick_i;
	}
	bed_scree = max(bed_scree, (1.0 - smoothstep(0.0, 0.10, bed_pos)) * 0.80);
	float bed_bhash = fract(sin(bed_bi * 12.9898 + 13.782
		+ bed_dip * 3.0) * 43758.5453);
	// Irregular per-bed value.  A hash sequence is allowed to put two
	// neighbours close together; that is what real bedding does, and it is
	// what removes the three-step stripe rhythm.
	float bed_base = mix(0.045, 0.200, bed_bhash);
	bed_base *= 0.94 + 0.12 * fract(bed_bhash * 7.7);
	// Rare dark/light anomalously thin beds.
	float bed_anom = fract(bed_bhash * 13.71);
	if (bed_anom > 0.90) {
		bed_base *= 0.55;
	} else if (bed_anom < 0.08) {
		bed_base *= 1.45;
	}
	float bed_thin = 1.0 - smoothstep(0.0, 0.035, abs(bed_pos - 0.5));
	bed_base *= mix(1.0, 0.62, step(0.94, bed_anom) * bed_thin);
	vec3 bed_tone = vec3(bed_base);
	float bed_hue = fract(bed_bhash * 5.73);
	bed_tone *= mix(vec3(0.95, 0.98, 1.04), vec3(1.04, 1.00, 0.95), bed_hue);
	// Hard seam: 2-3 cm dark line, no ramp between beds.
	float bed_seam = 1.0 - smoothstep(0.0, 0.040,
		min(bed_pos, 1.0 - bed_pos));
	float seam_strength = 0.38 * type_smooth + 0.82 * type_column
		+ 0.66 * type_block;
	bed_tone *= 1.0 - seam_strength * bed_seam * aa_fade;
	// Internal lamination stays horizontal; only +/-0.10 m of low-frequency
	// vertical warp, never a 3D swirl.
	float lam_warp = (vnoise2(vec2(p.x * 0.16, p.z * 0.16)) - 0.5) * 0.20;
	float lam_line = abs(fract((ybed + lam_warp) / lam_period) - 0.5);
	float bed_lam = 1.0 - smoothstep(0.0, 0.018, lam_line);
	bed_lam *= smoothstep(0.35, 0.65, bed_sub_b);
	bed_tone *= 1.0 - 0.008 * bed_lam * aa_fade;
	// 0.3-1.2 m mottling and pitting inside each bed.
	bed_tone *= mix(1.0, mix(0.86, 1.14, bed_sub_a), 1.00 * bed_band);
	bed_tone *= 1.0 - 0.02 * bed_pit * bed_band * aa_fade;
	// Vertical fracture, ~1-3 m apart, dark and a few pixels wide at 10 m.
	float bed_vf = 1.0 - smoothstep(0.0, 0.035,
		abs(bed_fpos - bed_fcentre));
	float vf_strength = 0.12 * type_smooth + 0.34 * type_column
		+ 0.26 * type_block;
	bed_tone *= 1.0 - vf_strength * bed_vf * aa_fade;
	// Blocky cut: one orthogonal joint set turns the face into courses of
	// quarried blocks; smooth and columnar islands leave it off.
	vec2 jdir = vec2(-bdir.y, bdir.x);
	float joint_coord = dot(v_world.xz, jdir)
		+ (vnoise2(v_world.xz * 0.31 + vec2(float(isl) * 1.7)) - 0.5) * 0.18;
	float block_joint = 1.0 - smoothstep(0.0, 0.040,
		abs(fract(joint_coord / joint_period) - 0.5));
	bed_tone *= 1.0 - 0.40 * block_joint * type_block * aa_fade;
	// Scree at bed ledges and the base.
	bed_tone *= 1.0 - 0.50 * bed_scree * (0.45 + 0.55 * bed_stones);
	bed_tone = mix(bed_tone, vec3(0.030, 0.025, 0.020), bed_scree * 0.24);
	// Exposed broken spires: darker at the attachment, lighter at the tip.
	float attach = smoothstep(-1.0, 7.5, v_world.y);
	bed_tone *= mix(1.35, 0.55, attach);
	float spire_bed = 1.0 - smoothstep(0.0, 0.055,
		abs(fract((v_world.y + (vnoise2(v_world.xz * 0.12) - 0.5) * 0.35) / 0.52) - 0.5));
	bed_tone *= 1.0 - 0.16 * spire_bed * wall * aa_fade;
	// Vertical bedding traces run down the length of the broken spires.
	vec2 vdir = vec2(cos(vert_angle), sin(vert_angle));
	float vcoord = dot(v_world.xz, vdir)
		+ (vnoise2(v_world.xz * 0.33 + vec2(float(isl) * 3.1)) - 0.5) * 0.40;
	float spire_vert = 1.0 - smoothstep(0.0, 0.055,
		abs(fract(vcoord / vert_period) - 0.5));
	float vert_strength = 0.006 * type_smooth + 0.075 * type_column
		+ 0.030 * type_block;
	bed_tone *= 1.0 - vert_strength * spire_vert * wall * aa_fade;
	// Cross-fractures break the vertical plank grain into broken rock.
	float spire_cross = 1.0 - smoothstep(0.0, 0.050,
		abs(fract((v_world.y * 0.95 + v_world.x * 0.62 + v_world.z * 0.34
			+ (vnoise2(v_world.xz * 0.31) - 0.5) * 0.35) / 1.10) - 0.5));
	spire_cross *= smoothstep(0.30, 0.60,
		vnoise2(vec2(v_world.y * 0.21 + 4.0, v_world.x * 0.17)));
	float cross_strength = 0.015 * type_smooth + 0.17 * type_column
		+ 0.07 * type_block;
	bed_tone *= 1.0 - cross_strength * spire_cross * wall * aa_fade;
	bed_col = bed_tone;
	// Stone, not timber: strip most of the warm bed hue and lift the value.
	float bed_grey = dot(bed_col, LUMA);
	bed_col = vec3(bed_grey) * 1.46;
	// ------------------------------------------------------------------
	// FAR-FIELD BEDDING.  Once the 2-3 cm seams and 0.36 m lamination have
	// faded, the face still needs readable structure at 20-40 m: broad 3.6 m
	// bed tone blocks, a 10 m value field and a few wide dark vertical faults.
	float far_w = smoothstep(14.0, 24.0, cam_dist);
	{
		float broad_y = v_world.y + (vnoise2(v_world.xz * 0.033) - 0.5) * 0.80;
		float cbed_id = floor(broad_y / mix(2.4, 4.8, isl_h));
		float cbed_hash = fract(sin(cbed_id * 12.9898 + 3.1) * 43758.5453);
		float cbed_tone = mix(0.80, 1.17, cbed_hash);
		float cb1 = tri_noise(v_world, w, vec2(-9.2, 2.7), 0.060);
		float cb2 = tri_noise(v_world, w, vec2(6.4, -5.1), 0.115);
		float broad_val = mix(0.84, 1.16, 0.60 * cb1 + 0.40 * cb2);
		bed_col *= mix(1.0, cbed_tone * broad_val, far_w * 0.90);
		float ch = v_world.x * 0.74 + v_world.z * 0.67;
		float cwarp = (vnoise2(v_world.xz * 0.050 + vec2(3.2, 8.1)) - 0.5) * 1.8;
		float cline = 1.0 - smoothstep(0.0, 0.020,
			abs(fract((ch + cwarp) / mix(7.0, 16.0, isl_h2)) - 0.5));
		cline *= smoothstep(0.38, 0.62,
			tri_noise(v_world, w, vec2(1.7, 9.3), 0.062));
		bed_col *= 1.0 - 0.34 * cline * far_w;
	}
	float bed_rough = mix(0.60, 0.94, fract(bed_bhash * 3.17));
	float cliff_rough = bed_rough;
	float cliff_damp = 0.0;


	// sparse vertical fractures, fading along their length
	float fcoord = atan(v_world.z, v_world.x) * 2.6 + float(isl) * 1.7
		+ (vnoise2(vec2(atan(v_world.z, v_world.x) * 3.0, p.y * 0.055)) - 0.5) * 0.85;
	float fracture = smoothstep(0.972, 0.997,
		abs(sin(fcoord * mix(7.0, 15.0, isl_h2) + p.y * 0.015)));
	fracture *= 0.20 + 0.80 * type_column + 0.45 * type_block;
	fracture *= smoothstep(0.52, 0.78,
		vnoise2(vec2(fcoord * 3.1, p.y * 0.09 + 2.3)));
	// Guarantee that no fracture runs the full height of the cliff: a second
	// low-frequency fade cuts each line into shorter segments.
	fracture *= smoothstep(0.06, 0.28,
		abs(sin(p.y * 0.70 + fcoord * 1.3))) * wall_geo;
	// cavity proxy from the horizontal component, darker in the undercut
	float cavity = wall_geo
		* smoothstep(0.0, 0.8, 1.0 - gny)
		* (0.35 + 0.65 * clamp(0.48 - strata, 0.0, 1.0));
	// Per-band roughness and fine strata grain.
	float cgrain = tri_noise(v_world, w, vec2(7.1, -3.9), 4.2);
	float cgrit = tri_noise(v_world, w, vec2(-2.4, 6.8), 13.0);
	float cfine = tri_noise(v_world, w, vec2(5.6, 9.1), 26.0);
	bed_col *= mix(1.0, mix(0.86, 1.14, cgrain), mix(0.35, 1.0, aa_fade));
	bed_col *= mix(1.0, mix(0.93, 1.07, cgrit), aa_fade);
	bed_col *= mix(1.0, mix(0.965, 1.035, cfine), aa_fade);
	// Dark recessed seams, lighter proud bed edges.
	// Bed seams are supplied by the sharp horizontal bedding above.
	// 1.2-1.4 m shadowed crevice under each 5 m ledge, broken along its
	// length so it reads as an undercut rather than another horizontal line.
	float b5 = fract(sy / crevice_period);
	float crevice = smoothstep(0.0, 0.035, b5)
		* (1.0 - smoothstep(0.035, 0.265, b5));
	crevice *= 0.54 + 0.46 * tri_noise(v_world, w, vec2(3.1, -6.2), 0.85);
	bed_col *= 1.0 - 0.36 * crevice * cliff_detail;
	cliff_rough = mix(cliff_rough, 0.98, crevice * 0.55);
	// Hairline cracks and shorter vertical fractures.
	float c_crack = 1.0 - smoothstep(0.012, 0.055,
		abs(tri_noise(v_world, w, vec2(1.8, -7.4), 1.7) - 0.5));
	bed_col *= 1.0 - 0.00 * c_crack;
	// Real fractures: two long irregular traces, broken by a low-frequency
	// mask so they terminate instead of forming a closed crazing network.
	float fr_a = tri_noise(v_world, w, vec2(9.4, -3.2), 0.44);
	float fr_line_a = 1.0 - smoothstep(0.0, 0.042, abs(fr_a - 0.5));
	fr_line_a *= smoothstep(0.34, 0.62,
		tri_noise(v_world, w, vec2(-2.8, 6.1), 0.115));
	bed_col *= 1.0 - 0.58 * fr_line_a * aa_fade;
	float fr_b = tri_noise(v_world, w, vec2(-7.1, 4.8), 0.73);
	float fr_line_b = 1.0 - smoothstep(0.0, 0.035, abs(fr_b - 0.5));
	fr_line_b *= smoothstep(0.38, 0.66,
		tri_noise(v_world, w, vec2(5.2, -8.4), 0.145));
	bed_col *= 1.0 - 0.46 * fr_line_b * aa_fade;
	// Damp/dirt streaks run down the face; they also change roughness.
	float st1 = vnoise2(vec2(v_world.x * 2.2 + v_world.z * 1.5, v_world.y * 0.16));
	float cliff_st2 = vnoise2(vec2(v_world.x * 6.1 - v_world.z * 3.2, v_world.y * 0.52));
	float damp = smoothstep(0.46, 0.72, st1 * 0.72 + cliff_st2 * 0.28);
	cliff_damp = damp;
	bed_col = mix(bed_col, bed_col * vec3(0.58, 0.56, 0.50), damp * 0.55);
	cliff_rough = mix(cliff_rough, 0.62, damp * 0.45);
	bed_col *= 1.0 - 0.30 * cavity;
	bed_col *= 1.0 - 0.22 * fracture * aa_fade;
	// The smooth top normal can leave a near-vertical cut with wall_geo < 1;
	// use a steep-normal fallback so the sharp beds also replace the marbled
	// base texture on those faces.
	float bed_cover = max(wall_geo, smoothstep(0.55, 0.85, 1.0 - abs(v_wn.y)));
	bed_cover *= rock_surface;
	// Strata belong to walls.  Full strength on |N.y| < 0.45, gone by 0.75 so
	// horizontal rounded masses cannot turn bedding into a topo-map ring.
	float strata_face = 1.0 - smoothstep(0.45, 0.75, abs(v_wn.y));
	bed_cover *= strata_face;
	ALBEDO = mix(ALBEDO, bed_col, 0.98 * bed_cover);
	// Rounded masses: coarse blocky jointing instead of bedding.  Voronoi
	// facets at ~2.6 m with dark seams only on the shared edges, plus pitting
	// and a slight per-facet value shift.
	// Only genuinely steep rock faces get blocky joints.  Near-horizontal
	// ground (meadows, lanes, shelves) must never see this: the old upward
	// mask turned flat turf into grey hexagonal paving.
	float round_w = (1.0 - smoothstep(0.28, 0.52, abs(v_wn.y))) * rock_surface
		* (1.0 - clamp(is_grass, 0.0, 1.0));
	float round_cover = round_w * (1.0 - bed_cover);
	if (round_cover > 0.01) {
		vec2 fq = v_world.xz * 0.32 + v_world.y * 0.05;
		fq += (vec2(vnoise2(v_world.xz * 0.17 + vec2(2.3, -1.1)),
			vnoise2(v_world.xz * 0.13 + vec2(-4.1, 6.7))) - 0.5) * 0.55;
		float fe = facet_edge(fq, 3.1);
		float joint = 1.0 - smoothstep(0.0, 0.070, fe);
		// Break most joints so the facets terminate instead of tiling.
		joint *= smoothstep(0.48, 0.72,
			tri_noise(v_world, w, vec2(11.3, -5.7), 0.115));
		float facet_n = tri_noise(v_world, w, vec2(-7.7, 4.4), 0.22);
		float pit = smoothstep(0.72, 0.88,
			tri_noise(v_world, w, vec2(5.8, -8.9), 4.2));
		vec3 round_c = rock_c * (0.90 + 0.20 * facet_n);
		round_c *= 1.0 - 0.18 * joint;
		round_c *= 1.0 - 0.14 * pit;
		ALBEDO = mix(ALBEDO, round_c, round_cover * 0.94);
	}

	// ------------------------------------------------------------------
	// MACRO GRASS VARIATION
	// 40 m and 17 m value fields plus a 22 m dry field.  The tint is applied
	// only to upward faces so the cliff beds keep their stone colour.
	float m40 = tri_noise(p, w, vec2(0.0), 0.025);
	float m17 = tri_noise(p, w, vec2(13.7, 4.1), 0.060);
	float macro = clamp(0.58 * m40 + 0.42 * m17, 0.0, 1.0);
	float sun_face = clamp(dot(normalize(v_wn.xz + vec2(1e-4)),
		normalize(vec2(-0.55, 0.45))), 0.0, 1.0);
	float hollow = 1.0 - smoothstep(0.25, 0.75, height);
	float dry = smoothstep(0.58, 0.82, tri_noise(p, w, vec2(17.0, 3.0), 0.045));
	vec3 grass_tint = mix(vec3(0.98, 1.01, 0.96), vec3(1.02, 1.00, 0.92),
		0.30 + 0.18 * sun_face + 0.26 * (macro - 0.5));
	grass_tint = mix(grass_tint, vec3(0.91, 1.04, 0.86), hollow * 0.28);
	grass_tint = mix(grass_tint, vec3(1.09, 1.00, 0.72), dry * 0.16);
	ALBEDO *= mix(vec3(1.0), grass_tint,
		topg * (1.0 - wall_geo) * 0.42 * macro_strength);

	// 6-20 m tonal patches that survive the 22 m game camera.  These are
	// intentionally much broader than the 0.3-1.5 m tuft fields: a 22 m view
	// resolves the 6 m and 12 m octaves but averages the blade texture into a
	// single green.  Keep the palette in dry/olive/lush grass, never brown
	// earth or black, so it reads as pasture rather than camouflage.
	float gp20 = tri_noise(p, w, vec2(27.0, -14.0), 0.050);
	float gp12 = tri_noise(p, w, vec2(-16.0, 9.0), 0.082);
	float gp6 = tri_noise(p, w, vec2(7.0, 21.0), 0.165);
	float tonal = 0.48 * gp20 + 0.32 * gp12 + 0.20 * gp6;
	float tonal_dry = smoothstep(0.47, 0.62, tonal);
	float tonal_lush = smoothstep(0.47, 0.62, 1.0 - tonal);
	float tonal_w = grass_top * smoothstep(1.0, 3.0, cam_dist)
		* (1.0 - smoothstep(110.0, 150.0, cam_dist));
	vec3 patch_tint = mix(vec3(1.0), vec3(1.38, 1.18, 0.66),
		tonal_dry * 0.52);
	patch_tint = mix(patch_tint, vec3(0.62, 0.84, 0.58),
		tonal_lush * 0.40);
	patch_tint *= 1.0 + (tonal - 0.5) * 0.62;
	// Large-scale hue drift: one side of an island leans warm olive, the other
	// cooler green.  The field is 50 m across, so it reads as climate rather
	// than as a texture tile.
	float drift = tri_noise(p, w, vec2(0.0), 0.018) - 0.5;
	patch_tint *= vec3(1.0 + 0.17 * drift, 1.0 + 0.03 * drift,
		1.0 - 0.13 * drift);
	float side_bias = clamp(p.x / 70.0, -1.0, 1.0);
	patch_tint *= mix(vec3(1.07, 1.02, 0.92), vec3(0.94, 1.02, 0.88),
		(side_bias + 1.0) * 0.5);
	ALBEDO *= mix(vec3(1.0), patch_tint, tonal_w);
	// A little desaturation at range: the sun/ACES grade otherwise pushes the
	// midtones to a single electric green.
	ALBEDO = mix(vec3(dot(ALBEDO, LUMA)), ALBEDO,
		mix(1.0, 0.91, tonal_w));

	// ------------------------------------------------------------------
	// GROUND WEAR: 1-4 m dry patches are above; here soil shows through on
	// steeper turf, at the island rim and around pond banks.  Layer 5 is the
	// packed dirt_soil albedo.  This sits over the grass tint so a worn patch
	// stays earth-coloured instead of being re-tinted green.
	// slope is the smooth baked vertex mask; (1 - gny) is a per-triangle
	// geometric derivative and would facet the soil patches.
	float steep = slope;
	float slope_soil = smoothstep(0.16, 0.44, steep) * (1.0 - wall_geo);
	float edge_noise = vnoise2(p.xz * 0.90 + vec2(6.1, 2.8));
	float edge_w = bank * mix(0.55, 1.0, edge_noise) * edge_strength;
	// The rim lip is a rounded top, not a cliff: wall_geo is already 0.3-0.7
	// there, so do not gate edge wear as hard as the slope wear.
	// Edge wear is a top-surface band.  It cannot be gated on is_grass: the
	// zone pass often labels the last few metres of the lip as rock and the
	// turf backstop paints it green, which is exactly where earth should show.
	// Gate on the true wall mask instead, and only at the vertical extreme.
	float edge_soil = edge_w * (1.0 - smoothstep(0.94, 1.0, wall_geo));
	float soil_w = max(slope_soil, edge_soil);
	// break the wear line itself so it is not a contour around the rim
	soil_w *= mix(0.68, 1.0, vnoise2(p.xz * 0.33 + vec2(-8.2, 5.4)));
	soil_w = clamp(soil_w, 0.0, 0.62);
	float soil_gate = max(topg, top_geo) * (1.0 - 0.20 * smoothstep(0.94, 1.0, wall_geo));

	vec3 soil_c = tri3(blend_albedo, p, w, dirt_uv / 8.0, 5);
	soil_c = mix(soil_c, vec3(0.072, 0.048, 0.030), 0.30);
	soil_c *= mix(0.70, 1.04, vnoise2(p.xz * 0.65 + vec2(1.3, -8.0)));

	// RIM TRANSITION: turf thins into bare soil over the band, with exposed
	// earth patches and a few rock chips.  The 0.7 m field makes the outer
	// edge ragged at sub-metre scale; the 1.8 m field keeps the band itself
	// from being a smooth painted stripe.
	float rim_face = 1.0 - smoothstep(0.86, 1.00, wall_geo);
	float rim_soil = rim_band * rim_face
		* (0.66 + 0.28 * rim_n2) * (1.0 - 0.24 * smoothstep(0.82, 0.97, rim_n1));
	ALBEDO = mix(ALBEDO, soil_c, rim_soil * 0.94);
	float rim_chip = rim_band * smoothstep(0.62, 0.92, rim_n2) * rim_face;
	ALBEDO = mix(ALBEDO, rock_c * 0.78, rim_chip * 0.46);
	float rim_tuft = rim_band * smoothstep(0.44, 0.78, rim_n2) * rim_face;
	ALBEDO = mix(ALBEDO, turf * 1.06, rim_tuft * 0.36);

	// ------------------------------------------------------------------
	// BARE EARTH SURFACE DETAIL
	// Triplanar at 0.05-1.0 m: a second, finer texture tap plus soil grain,
	// grit, small stones and hairline cracks.  All of it fades before the
	// mip range where it would alias; the 0.3-5 m tone survives.
	vec3 soil_fine = tri3(blend_albedo, v_world * 2.35, w, dirt_uv / 8.0, 5);
	float soil_l0 = max(dot(soil_c, LUMA), 1e-4);
	float soil_lf = dot(soil_fine, LUMA);
	soil_c *= mix(1.0, clamp(soil_lf / soil_l0, 0.58, 1.45),
		0.35 * earth_detail * fine_fade);
	float e_broad = tri_noise(v_world, w, vec2(2.3, -7.1), 0.19);
	float e_mid = tri_noise(v_world, w, vec2(-1.7, 5.6), 0.72);
	float e_fine = tri_noise(v_world, w, vec2(6.2, -3.4), 2.85);
	float e_grit = tri_noise(v_world, w, vec2(-4.8, 8.1), 9.5);
	float e_speck = tri_noise(v_world, w, vec2(3.9, 1.2), 23.0);
	float e_tone = 0.55 * e_broad + 0.30 * e_mid + 0.15 * e_fine;
	soil_c *= mix(vec3(0.90, 0.88, 0.84), vec3(1.10, 1.07, 1.02), e_tone);
	soil_c *= mix(0.78, 1.16, e_grit);
	soil_c *= mix(0.90, 1.08, e_speck);
	float e_crack_n = abs(tri_noise(v_world, w, vec2(4.3, -2.7), 2.2) - 0.5);
	float e_crack = 1.0 - smoothstep(0.012, 0.050, e_crack_n);
	soil_c *= 1.0 - 0.26 * e_crack * fine_fade * earth_detail;
	float e_stone = smoothstep(0.79, 0.92,
		tri_noise(v_world, w, vec2(-6.5, 4.1), 6.8));
	soil_c = mix(soil_c, vec3(0.145, 0.120, 0.092), e_stone * 0.38);
	float e_stone2 = smoothstep(0.88, 0.97,
		tri_noise(v_world, w, vec2(8.7, -4.9), 13.5));
	soil_c = mix(soil_c, vec3(0.240, 0.210, 0.175), e_stone2 * 0.30);
	ALBEDO = mix(ALBEDO, soil_c, soil_w * soil_strength * soil_gate);

	// Cliff-lip overhang character: on the upper wall only, irregular
	// brown-soil roots and a little hanging turf break the stone/grass seam.
	// The vertical noise stretches the patches downward, reading as roots
	// and undercut soil without moving a vertex.
	float lip_root = rim_band * smoothstep(0.38, 0.92, wall_geo);
	float root_v = tri_noise(v_world * vec3(2.8, 0.55, 2.8), w,
		vec2(3.1, -6.4), 2.35);
	float root_w = lip_root * smoothstep(0.54, 0.76, root_v)
		* (0.55 + 0.45 * smoothstep(0.20, 0.70, wall_geo));
	ALBEDO = mix(ALBEDO, mix(soil_c * 0.72, turf * 0.70, 0.34),
		root_w * 0.62);
	float hang_tuft = lip_root * smoothstep(0.62, 0.84, rim_n1)
		* (0.35 + 0.65 * (1.0 - smoothstep(0.55, 0.95, wall_geo)));
	ALBEDO = mix(ALBEDO, turf * 0.78, hang_tuft * 0.26);

	// Dry bank: compacted earth, grain, small stones and a soft noisy edge.
	// The old bank fell through to the rock path and read as flat grey paint.
	float bank_grain = vnoise2(v_world.xz * 1.55 + vec2(5.1, -2.3)) * 0.62
		+ vnoise2(v_world.xz * 4.10 + vec2(-3.7, 8.4)) * 0.38;
	float bank_edge = smoothstep(0.045, 0.38, bank + (bank_grain - 0.5) * 0.14);
	bank_edge *= 1.0 - smoothstep(0.58, 0.92, topg);
	// Keep only the baked waterline bank mask. The old low_shelf term painted
	// every low flat shelf with compacted earth, which made the hard V and
	// trapezoid apron. The bank is now wet grey gravel, not tan.
	float bank_w = bank_edge;
	vec3 bank_c = mix(vec3(0.205, 0.195, 0.175), soil_c, 0.35);
	vec3 bank_tex = tri3(blend_albedo, v_world * 3.10, w, dirt_uv / 8.0, 5);
	bank_c = mix(bank_c, bank_tex, 0.45);
	bank_c = mix(bank_c, vec3(0.080, 0.080, 0.075), 0.38);
	bank_c *= mix(0.66, 1.26, bank_grain);
	bank_c *= mix(0.78, 1.22,
		tri_noise(v_world, w, vec2(-4.2, 7.3), 3.4));
	float bank_crack = 1.0 - smoothstep(0.012, 0.050,
		abs(tri_noise(v_world, w, vec2(2.1, -8.4), 2.0) - 0.5));
	bank_c *= 1.0 - 0.22 * bank_crack * fine_fade;
	float bstone = smoothstep(0.880, 0.950,
		vnoise2(v_world.xz * 4.80 + vec2(2.2, -6.8)));
	bank_c = mix(bank_c, vec3(0.150, 0.120, 0.088), bstone * 0.55);
	float bstone2 = smoothstep(0.930, 0.985,
		vnoise2(v_world.xz * 7.20 + vec2(-4.6, 1.7)));
	bank_c = mix(bank_c, vec3(0.235, 0.205, 0.165), bstone2 * 0.48);
	bank_c *= 1.0 + 0.08 * (vnoise2(v_world.xz * 0.55 + vec2(9.2, -4.1)) - 0.5);
	ALBEDO = mix(ALBEDO, bank_c, bank_w * 0.88 * soil_strength);

	// Soft, noisy earth-to-grass transition.  The old edge was the threshold
	// of bank_edge, which read as a cut line on the rim.
	float fringe_n = vnoise2(v_world.xz * 1.45 + vec2(-3.2, 6.4));
	float fringe = smoothstep(0.0, 0.60,
		max(bank_w, soil_w) + (fringe_n - 0.5) * 0.40)
		* (1.0 - smoothstep(0.35, 0.90, topg));
	ALBEDO = mix(ALBEDO, soil_c, fringe * 0.38 * (1.0 - 0.6 * wall_geo));

	// Sparse bare earth in the driest flat patches, so the field is not a
	// continuous carpet.  Kept low; the rim/bank band above is the main wear.
	float bare = smoothstep(0.80, 0.93, n_large * 0.60 + n_med * 0.40);
	ALBEDO = mix(ALBEDO, soil_c, bare * 0.16 * soil_strength * topg);
	float gap = smoothstep(0.70, 0.90, 1.0 - clump2) * clump_near;
	ALBEDO = mix(ALBEDO, soil_c, gap * 0.14 * soil_strength * topg);

	// A few exposed stones on the hardest-worn rim/bank patches.
	float pebble = smoothstep(0.68, 0.94,
		vnoise2(p.xz * 1.70 + vec2(-7.0, 3.0))) * edge_w;
	ALBEDO = mix(ALBEDO, vec3(0.085, 0.075, 0.060),
		pebble * 0.45 * (1.0 - wall_geo));

	// ------------------------------------------------------------------
	// DIRT LANE: the mask bakes compacted earth, two 0.35 m ruts 1.2 m
	// apart, a lighter scuffed centre, a ragged 0.3 m grass edge, damp and dry
	// patches and sparse embedded stones.  Shading only: geometry untouched.
	vec2 puv = (v_world.xz - path_mask_rect.xy) / path_mask_rect.zw;
	vec4 pa = textureLod(path_albedo, puv, 0.0);
	// The baked map carries the 3 m lane, ruts, pools and dry patches.  Add
	// camera-distance detail on top so the 5 m view stays sharp: fine grain,
	// a ragged 0.3 m edge and sparse 3-8 cm embedded stones.
	float edge_a = vnoise2(v_world.xz * 4.1 + vec2(3.7, -1.9));
	float edge_b = vnoise2(v_world.xz * 9.3 + vec2(-6.2, 2.4));
	float edge_n = (edge_a - 0.5) * 0.20 + (edge_b - 0.5) * 0.08;
	float pcov = smoothstep(0.15, 0.40, pa.a + edge_n);
	float grain = vnoise2(v_world.xz * 2.5 + vec2(1.3, 7.7)) * 0.60
		+ vnoise2(v_world.xz * 5.0 + vec2(-2.1, 4.5)) * 0.40;
	// The baked lane albedo is a light grey pickup; on a sunlit path that read
	// as a white painted road.  Tint it to damp packed earth before the ruts.
	vec3 pc = pa.rgb * vec3(0.36, 0.275, 0.190) * (0.88 + 0.22 * grain);
	// Sharp procedural ruts over the baked base: two 0.35 m grooves 1.2 m
	// apart, with a lightly scuffed centre strip between them.
	vec3 pm = textureLod(path_mask, puv, 0.0).rgb;
	float lat = (pm.g - 0.5) * 2.0;
	float groove = 1.0 - smoothstep(0.0, 0.130, abs(abs(lat) - 0.40));
	pc = mix(pc, vec3(0.072, 0.044, 0.026), groove * 0.90);
	// Raised, drier lips either side of each groove: the ruts stay legible
	// when the lane is in shade at 20-30 m.
	float lip = exp(-pow((abs(lat) - 0.24) / 0.075, 2.0))
		+ exp(-pow((abs(lat) - 0.56) / 0.075, 2.0));
	pc *= 1.0 + 0.16 * lip;
	pc *= 1.0 + 0.12 * exp(-pow(lat / 0.30, 2.0));
	// The lane meets the gate plinth as a worn threshold rather than a cut.
	pc *= 1.0 - 0.18 * (1.0 - smoothstep(15.0, 17.5, v_world.z));
	// 1-4 m damp/dry patches so the lane is not uniform at hero distance.
	pc *= 0.86 + 0.18 * vnoise2(v_world.xz * 0.55 + vec2(9.2, -4.1));
	// A handful of 10-25 cm embedded stones, low enough frequency to stay
	// crisp instead of aliasing at 5 m.
	float st = smoothstep(0.93, 0.975,
		vnoise2(v_world.xz * 5.0 + vec2(2.2, -6.8)));
	pc = mix(pc, vec3(0.130, 0.112, 0.088), st * 0.60);
	float st2_path = smoothstep(0.955, 0.99,
		vnoise2(v_world.xz * 6.5 + vec2(-4.6, 1.7)));
	pc = mix(pc, vec3(0.285, 0.260, 0.218), st2_path * 0.65);
	float path_gate = 1.0 - smoothstep(0.80, 1.0, wall_geo);
	float path = pcov * path_gate * path_strength;
	ALBEDO = mix(ALBEDO, pc, path);
	ROUGHNESS = mix(ROUGHNESS, 0.98, path);
	SPECULAR = mix(SPECULAR, 0.02, path);

	EMISSION = vec3(0.010, 0.007, 0.004) * wall
		+ base_c * 0.090 * topg
		+ turf * 0.30 * topg;

	// ------------------------------------------------------------------
	// DETAIL NORMAL
	// Two scales: the family normal at 0.3-3 m plus a procedural gradient at
	// 0.28-1.3 m.  NORMAL_MAP is encoded 0..1; it lerps to the idle value as
	// it fades so the 20-60 m view cannot break up into specular pinpricks.
	float up_normal = smoothstep(0.62, 0.88, v_wn.y);
	float micro = normal_fade * up_normal * micro_strength;
	vec3 nm_tex = texture(base_normal, p.xz * bs).rgb * 2.0 - 1.0;
	nm_tex.xy *= 0.15;
	vec2 grad = detail_grad(p.xz, fine_fade);
	vec3 nm_tan = normalize(vec3(nm_tex.xy + vec2(-grad.x, -grad.y) * (0.15 * micro),
		max(nm_tex.z, 0.30)));
	vec3 nm_target = nm_tan * 0.5 + 0.5;
	NORMAL_MAP = mix(NM_IDLE, nm_target, normal_fade * up_normal);
	NORMAL_MAP_DEPTH = up_normal * normal_fade * 0.22;
	// The slate normal map carries the calcite-vein network too.  On rock it
	// was lighting those veins into bright crazing lines, so keep the family
	// normal off rock faces entirely; the bedding and fractures provide form.
	float rock_nm_off = clamp(max(rock_w, wall_geo), 0.0, 1.0);
	NORMAL_MAP = mix(NORMAL_MAP, NM_IDLE, rock_nm_off);
	NORMAL_MAP_DEPTH *= 1.0 - rock_nm_off;
	// Cliffs need real shading breakup too: NORMAL_MAP above is gated to
	// upward faces, so previously the walls had zero micro-normal.  Triplanar
	// world-space gradient gives them 5-20 cm relief without a UV seam.
	if (wall_geo > 0.02) {
		float ce = 0.035;
		float ch0 = tri_noise(v_world, w, vec2(4.7, -6.2), 5.2);
		float chx = tri_noise(v_world + vec3(ce, 0.0, 0.0), w, vec2(4.7, -6.2), 5.2);
		float chz = tri_noise(v_world + vec3(0.0, 0.0, ce), w, vec2(4.7, -6.2), 5.2);
		vec3 n_wall = normalize(v_wn
			+ vec3((chx - ch0) / ce, 0.0, (chz - ch0) / ce)
			* 0.11 * wall_geo * clamp(cliff_detail, 0.0, 1.0));
		NORMAL = normalize((VIEW_MATRIX * vec4(v_wn, 0.0)).xyz);
	}
	// Final stone colour: neutral, lifted grey.  Kept off turf/moss so only
	// rock faces lose the warm timber hue.
	float rock_face = clamp(max(max(rock_w, wall_geo),
		max(round_w, rock_surface * (1.0 - clamp(is_grass, 0.0, 1.0)))), 0.0, 1.0);
	float rock_lum = dot(ALBEDO, LUMA);
	ALBEDO = mix(vec3(rock_lum), ALBEDO, mix(1.0, 0.12, rock_face));
	ALBEDO *= mix(vec3(1.0), vec3(1.10, 1.12, 1.14), rock_face);

	// Soften only upward turf normals; cliffs keep their form.
	float flat_amt = flat_normal * topg * (1.0 - wall_geo);
	NORMAL = normalize(mix(NORMAL,
		(VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz, flat_amt));
	// Near-field turf relief: 0.3-1.5 m humps and hollows so mounds read as
	// shaped ground rather than a smooth blob.  This is shading only; the
	// collision heightfield is untouched.
	float near_def = (1.0 - smoothstep(14.0, 28.0, cam_dist))
		* topg * (1.0 - path) * (1.0 - wall_geo);
	if (near_def > 0.01) {
		float ne = 0.055;
		float dh0 = tri_noise(v_world, w, vec2(3.3, -7.7), 0.95) * 0.60
			+ tri_noise(v_world, w, vec2(-9.1, 4.2), 2.6) * 0.30;
		float dhx = tri_noise(v_world + vec3(ne, 0.0, 0.0), w,
			vec2(3.3, -7.7), 0.95) * 0.60
			+ tri_noise(v_world + vec3(ne, 0.0, 0.0), w,
			vec2(-9.1, 4.2), 2.6) * 0.30;
		float dhz = tri_noise(v_world + vec3(0.0, 0.0, ne), w,
			vec2(3.3, -7.7), 0.95) * 0.60
			+ tri_noise(v_world + vec3(0.0, 0.0, ne), w,
			vec2(-9.1, 4.2), 2.6) * 0.30;
		vec3 dh = vec3((dhx - dh0) / ne, 0.0, (dhz - dh0) / ne);
		NORMAL = normalize(NORMAL
			+ (VIEW_MATRIX * vec4(dh, 0.0)).xyz * 1.30 * near_def);
	}

	// The lane is flat compacted earth: keep the high-frequency family normal
	// off it, or the 0.3 m normal grid reads as woven fabric at 5 m.
	NORMAL_MAP = mix(NORMAL_MAP, NM_IDLE, path);
	NORMAL_MAP_DEPTH *= 1.0 - path;

	float rb = tri2g(base_rough, p, w, bs);
	float rr = tri3g(blend_rough, p, w, rs, ri);
	float rm = tri3g(blend_rough, p, w, ms, 4);
	ROUGHNESS = mix(mix(mix(rb, rr, rock_w), rm, moss_w), 0.92, detail_fade);
	ROUGHNESS = max(ROUGHNESS, 0.72);
	// grass is matte: no tight highlight to alias into a white speck at range
	ROUGHNESS = mix(ROUGHNESS, max(ROUGHNESS, 0.84),
		grass_top * normal_fade);
	METALLIC = 0.0;
	SPECULAR = mix(0.35, 0.03, wall_geo);
	SPECULAR = mix(SPECULAR, 0.09, topg * (1.0 - wall_geo));

	// The lane is compacted earth, not a normal-mapped turf surface.  These
	// overrides must come after the general roughness/specular passes: an
	// earlier write was overwritten by the per-family texture lookup, which
	// left the 0.3 m roughness grid reading as woven canvas at 5 m.
	ROUGHNESS = mix(ROUGHNESS, 0.98, path);
	SPECULAR = mix(SPECULAR, 0.02, path);
	ROUGHNESS = mix(ROUGHNESS, cliff_rough,
		0.72 * wall_geo * clamp(cliff_detail, 0.0, 1.0));
	float rock_flat_r = smoothstep(0.50, 0.90, rock_surface);
	ROUGHNESS = mix(ROUGHNESS, 0.94, rock_flat_r * 0.80);
	SPECULAR = mix(SPECULAR, 0.02, rock_flat_r);
	ROUGHNESS = mix(ROUGHNESS, 0.88, cliff_damp * 0.20 * wall_geo);

	// ------------------------------------------------------------------
	// LAST-WORD EXPOSED-SURFACE GRAIN
	// The branch above can be overwritten by backstops and lane/pond passes.
	// This overlay guarantees every non-grass earth/rock pixel carries metre
	// and sub-metre grain: fine soil, grit, embedded stones and hairline cracks.
	float exposed = max(wall_geo, 1.0 - topg);
	exposed *= 1.0 - 0.45 * topg;
	exposed *= 1.0 - 0.55 * low_shelf;
	float m0 = tri_noise(v_world, w, vec2(9.3, -1.7), 0.33);
	float m1 = tri_noise(v_world, w, vec2(7.7, -2.4), 4.8);
	float m2 = tri_noise(v_world, w, vec2(-3.1, 8.8), 13.0);
	float m3 = tri_noise(v_world, w, vec2(5.4, 3.7), 27.0);
	// 2-4 m tonal patches: no two square metres share one earth tone.
	ALBEDO *= mix(vec3(1.0),
		mix(vec3(0.86, 0.84, 0.80), vec3(1.14, 1.10, 1.03), m0),
		exposed);
	ALBEDO *= mix(1.0, mix(0.68, 1.32, m1), 0.36 * exposed * earth_detail);
	ALBEDO *= mix(1.0, mix(0.82, 1.16, m2), 0.12 * exposed * earth_detail);
	ALBEDO *= mix(1.0, mix(0.93, 1.07, m3), 0.06 * exposed * earth_detail);
	float m_grit = smoothstep(0.60, 0.78,
		tri_noise(v_world, w, vec2(4.4, -8.7), 17.0));
	ALBEDO *= 1.0;
	float mstone = smoothstep(0.70, 0.88,
		tri_noise(v_world, w, vec2(-6.2, 4.7), 4.5));
	ALBEDO = mix(ALBEDO, vec3(0.150, 0.125, 0.100),
		mstone * 0.15 * exposed);
	float mcrack = 1.0 - smoothstep(0.012, 0.050,
		abs(tri_noise(v_world, w, vec2(3.6, -6.9), 2.4) - 0.5));
	ALBEDO *= 1.0 - 0.28 * mcrack * exposed * earth_detail;

	// ------------------------------------------------------------------
	// SOIL GRANULAR PASS
	// The tan sheets used to be one smooth triplanar wash: a 0.3 m normal
	// octave and broad tone noise, with no hard grain or stones.  This pass
	// works in actual metres, independently of texture UVs, so the 3 m view
	// gets 5-30 cm grit, pebbles, roots, short dry cracks and 1-3 m damp/dry
	// patches.  It is albedo + normal only; no vertex is moved.
	vec3 pre_soil = ALBEDO;
	float pre_chroma = max(max(pre_soil.r, pre_soil.g), pre_soil.b)
		- min(min(pre_soil.r, pre_soil.g), pre_soil.b);
	// Catch both the explicit soil layer and tan base triangles that soil_w
	// misses, but never paint green turf with grit.
	float tan_soil = smoothstep(0.032, 0.095, pre_chroma)
		* smoothstep(0.010, 0.055, pre_soil.r - pre_soil.b)
		* (1.0 - grass_top);
	float earth_w = max(soil_w * soil_strength, tan_soil * 0.92);
	earth_w *= 1.0 - 0.78 * path;

	// 1-3 m damp/dry patches.  Damp is darker and slightly cooler; dry is
	// paler and warmer.  Two fields keep the patch edges from being blobs.
	float soil_patch_a = tri_noise(v_world, w, vec2(-2.1, 7.7), 0.30);
	float soil_patch_b = tri_noise(v_world, w, vec2(8.4, -3.2), 0.62);
	float damp_patch = smoothstep(0.35, 0.66, soil_patch_a)
		* smoothstep(0.25, 0.58, soil_patch_b);
	float soil_dry_patch = smoothstep(0.45, 0.72, 1.0 - soil_patch_a)
		* smoothstep(0.28, 0.62, 1.0 - soil_patch_b);
	ALBEDO *= mix(vec3(1.0), vec3(0.78, 0.80, 0.82),
		damp_patch * 0.64 * earth_w);
	ALBEDO *= mix(vec3(1.0), vec3(1.18, 1.11, 1.01),
		soil_dry_patch * 0.58 * earth_w);
	float coarse_soil = tri_noise(v_world, w, vec2(5.5, -3.1), 0.62);
	ALBEDO *= mix(1.0, mix(0.70, 1.30, coarse_soil), 0.60 * earth_w);

	// 0.05-0.3 m grain: hard grit speckle, not a smooth brightness swell.
	float grit_h = tri_noise(v_world, w, vec2(4.7, -8.2), 55.0);
	float grit = smoothstep(0.38, 0.62, grit_h);
	ALBEDO *= mix(1.0, mix(0.70, 1.24, grit),
		0.68 * earth_w * fine_fade);
	float grit_fine = tri_noise(v_world, w, vec2(-7.3, 2.6), 96.0);
	ALBEDO *= mix(1.0, mix(0.84, 1.14, smoothstep(0.42, 0.58, grit_fine)),
		0.30 * earth_w * fine_fade);

	// Embedded pebbles: 4-15 cm hard-rimmed cells, some proud and pale, some
	// dark and buried.  stone_field is triplanar so the wall contact gets
	// them too instead of smearing a planar pattern down the face.
	float peb_fp = max(fwidth(v_world.x), fwidth(v_world.z));
	float peb_aa = 1.0 - smoothstep(0.004, 0.015, peb_fp);
	float peb_a = stone_field(v_world, w, 20.0, 0.86);
	float peb_b = stone_field(v_world, w, 34.0, 0.90);
	float peb = max(peb_a, peb_b * 0.55) * peb_aa;
	float peb_a_r = stone_field_pad(v_world, w, 20.0, 0.86, 0.055);
	float peb_b_r = stone_field_pad(v_world, w, 34.0, 0.90, 0.045);
	float peb_rim = clamp(max(peb_a_r, peb_b_r * 0.55) - peb, 0.0, 1.0) * peb_aa;
	float peb_hash = hash13(floor(v_world * 20.0));
	vec3 peb_col = mix(vec3(0.090, 0.074, 0.058),
		vec3(0.215, 0.190, 0.155), peb_hash);
	// Dark wet rim, lit top: each stone reads as a discrete pebble.
	ALBEDO = mix(ALBEDO, peb_col * 0.38, peb_rim * 0.80 * earth_w);
	ALBEDO = mix(ALBEDO, peb_col * 1.22, peb * 0.78 * earth_w);

	// Root fragments: short, broken, dark-warm curls, not long straight lines.
	float root_v2 = tri_noise(v_world * vec3(1.25, 1.65, 1.25), w,
		vec2(3.7, -1.4), 3.2);
	float root_line = 1.0 - smoothstep(0.020, 0.070, abs(root_v2 - 0.5));
	root_line *= smoothstep(0.44, 0.70,
		tri_noise(v_world, w, vec2(-5.2, 8.8), 0.65));
	ALBEDO = mix(ALBEDO, vec3(0.052, 0.036, 0.024),
		root_line * 0.70 * earth_w);

	// Short dry cracks.  A second, finer network than the metre-scale crack
	// above; the mask breaks it into 20-60 cm segments.
	float crack_short = 1.0 - smoothstep(0.015, 0.060,
		abs(tri_noise(v_world, w, vec2(6.3, -4.9), 4.6) - 0.5));
	crack_short *= smoothstep(0.40, 0.68,
		tri_noise(v_world, w, vec2(1.8, 3.4), 2.1));
	ALBEDO *= 1.0 - 0.78 * crack_short * earth_w * fine_fade;

	// Soil/rock contact: uneven undercut shadow, downslope erosion gullies and
	// coarse rubble at the foot.  This is what stops the soil edge from being
	// a soft airbrushed fade into the crisp bedding.
	float contact_band = clamp(
		rim_band * smoothstep(0.18, 0.50, wall_geo)
		* (1.0 - smoothstep(0.70, 0.94, wall_geo))
		+ smoothstep(0.30, 0.55, wall_geo)
		* (1.0 - smoothstep(0.82, 0.98, wall_geo)) * 0.65
		* (0.35 + 0.65 * tan_soil)
		+ bank_w * 0.80 * smoothstep(0.42, 0.78, wall_geo), 0.0, 1.0);
	earth_w = max(earth_w, contact_band * 0.78);

	float soil_edge = clamp(
		max(max(soil_w, bank_w), tan_soil * 0.85) * smoothstep(0.06, 0.32, wall_geo)
		* (1.0 - smoothstep(0.82, 0.99, wall_geo))
		+ contact_band, 0.0, 1.0);

	// Direct soil-lip contact strip: a 10-25 cm band where the soil meets
	// stone, independent of the generated rim-distance map (which is only an
	// approximate layout projection on the far islands).
	float contact_strip = smoothstep(0.06, 0.28, wall_geo)
		* (1.0 - smoothstep(0.50, 0.74, wall_geo))
		* (0.25 + 0.75 * tan_soil);
	// Rim slabs, not a polygonal net.  The old 42%/54% cell coverage left a
	// continuous pale grey honeycomb around every island.  Sparse, darker,
	// per-block varied slabs read as natural broken rock from above.
	float edge_stone = max(stone_field(v_world, w, 2.4, 0.86),
		stone_field(v_world, w, 4.5, 0.90) * 0.70);
	vec3 edge_stone_col = mix(vec3(0.070, 0.060, 0.052),
		vec3(0.205, 0.180, 0.155), hash13(floor(v_world * 3.7)));
	ALBEDO = mix(ALBEDO, edge_stone_col, contact_strip * edge_stone);
	ALBEDO *= 1.0 - 0.28 * contact_strip * (1.0 - edge_stone);

	float gully_n = 1.0 - smoothstep(0.015, 0.085,
		abs(tri_noise(v_world * vec3(1.0, 0.35, 1.0), w,
			vec2(6.1, -4.8), 2.8) - 0.5));
	gully_n *= smoothstep(0.34, 0.66,
		tri_noise(v_world, w, vec2(-6.8, 2.2), 0.90));
	float rim_edge = rim_band * (0.35 + 0.65 * tan_soil);
	float gully = gully_n * max(max(contact_band, rim_edge * 0.85), contact_strip);
	ALBEDO *= 1.0 - 0.55 * gully;

	float ucut = max(contact_band, rim_edge * 0.80)
		* smoothstep(0.22, 0.50, wall_geo)
		* (1.0 - smoothstep(0.70, 0.90, wall_geo));
	ALBEDO *= 1.0 - 0.44 * ucut
		* (0.40 + 0.60 * tri_noise(v_world, w, vec2(2.4, -7.6), 3.5));

	// Coarse rubble at the soil edge.  This was the pale-oval culprit: three
	// stone_fields at 50%/74% occupancy, no footprint LOD, projected flat.
	// Keep only a sparse 5-6% of cells, hard-gated by pixel footprint.
	float rub_fp = max(fwidth(v_world.x), fwidth(v_world.z));
	float rub_aa = 1.0 - smoothstep(0.004, 0.018, rub_fp);
	float rub_core = max(stone_field(v_world, w, 3.2, 0.93),
		stone_field(v_world, w, 6.5, 0.95) * 0.80);
	float rub_outer = max(stone_field_pad(v_world, w, 3.2, 0.93, 0.05),
		stone_field_pad(v_world, w, 6.5, 0.95, 0.04) * 0.80);
	float rub_rim = clamp(rub_outer - rub_core, 0.0, 1.0);
	float rub = max(soil_edge, rim_edge) * rub_core * rub_aa;
	rub_rim *= max(soil_edge, rim_edge) * rub_aa;
	vec3 rub_col = mix(vec3(0.115, 0.095, 0.075),
		vec3(0.255, 0.225, 0.185), hash13(floor(v_world * 6.5)));
	ALBEDO = mix(ALBEDO, rub_col * 0.34, rub_rim * 0.80);
	ALBEDO = mix(ALBEDO, rub_col * 1.18, rub * 0.85);

	// Fine geometric relief: 5-30 cm grain plus the gully/undercut notch.
	float gm0 = soil_micro_h(v_world, w);
	float ge = 0.018;
	float gmx = soil_micro_h(v_world + vec3(ge, 0.0, 0.0), w);
	float gmz = soil_micro_h(v_world + vec3(0.0, 0.0, ge), w);
	float n_grain = (0.24 * earth_w + 0.18 * contact_band) * fine_fade;
	vec3 n_soil = normalize(v_wn + vec3(
		-(gmx - gm0) / ge, 0.0, -(gmz - gm0) / ge) * n_grain);
	NORMAL = normalize((VIEW_MATRIX * vec4(n_soil, 0.0)).xyz);
	// Last-word near-wall pass: the 3-8 m cut face must read as rock, not a
	// smooth tan plane.  These cracks and grain are deliberately final so
	// later soil/backstop mixes cannot wash them out.
	float near_wall = wall_geo * (1.0 - smoothstep(8.0, 20.0, cam_dist));
	float near_crack = 1.0 - smoothstep(0.010, 0.040,
		abs(tri_noise(v_world, w, vec2(-2.7, 5.3), 1.30) - 0.5));
	near_crack *= smoothstep(0.36, 0.72,
		tri_noise(v_world, w, vec2(6.1, -8.2), 0.34));
	float near_grit = tri_noise(v_world, w, vec2(9.8, -4.1), 7.4);
	ALBEDO *= 1.0 - 0.50 * near_crack * near_wall;
	ALBEDO *= mix(1.0, mix(0.82, 1.18, near_grit), near_wall);

	// Near-field 0.3-1.5 m albedo breakup to match the normal relief; without
	// this the mound stays a smooth dough even when its normals are shaped.
	float near_alb = 1.0 - smoothstep(14.0, 28.0, cam_dist);
	if (near_alb > 0.01) {
		float a1 = tri_noise(v_world, w, vec2(4.4, 9.2), 1.35);
		float a2 = tri_noise(v_world, w, vec2(-7.6, 2.8), 3.1);
		ALBEDO *= 1.0 + ((a1 - 0.5) * 0.75 + (a2 - 0.5) * 0.40) * near_alb;
	}

	// Backfaces are what a camera under an island sees through an open rim.
	// They must read as the solid inside of a dirt keel, never as lit turf or
	// a black blade.  This is the last word, after every top-surface pass.
	if (!FRONT_FACING) {
		float bf = vnoise2(v_world.xz * 0.17 + vec2(4.3, -2.1));
		float bf_grain = tri_noise(v_world, w, vec2(3.7, -6.1), 3.6);
		float bf_grit = tri_noise(v_world, w, vec2(-5.2, 8.8), 12.0);
		// Backfaces use the same sharp bedding as front faces.  Keeping the
		// old triplanar dirt/rock texture here is what made the lip read as
		// plywood: its marbled pattern swirled across the bed planes.
		vec3 bfc = bed_col;
		bfc = mix(bfc, vec3(0.095, 0.066, 0.044), 0.18);
		bfc *= mix(0.80, 1.18, bf_grain);
		bfc *= mix(0.92, 1.06, bf_grit);
		bfc *= 0.90 + 0.20 * bf;
		bfc *= 1.0 - 0.30 * crevice;
		// Keel/underside is lit only by the cool sky ambient in shadow, which
		// turned every island's side into a navy-purple slab.  Warm the stone
		// and add a small neutral bounce so it stays grey-brown.
		bfc = mix(bfc, vec3(0.225, 0.180, 0.132), 0.62);
		ALBEDO = bfc * vec3(1.20, 1.06, 0.84);
		ROUGHNESS = bed_rough;
		SPECULAR = 0.0;
		METALLIC = 0.0;
		NORMAL_MAP = NM_IDLE;
		NORMAL_MAP_DEPTH = 0.0;
		EMISSION = vec3(0.340, 0.255, 0.155);
	}
	if (force_pond_earth > 0.5) {
		float e = vnoise2(v_world.xz * 1.35 + vec2(5.1, -2.3)) * 0.60
			+ vnoise2(v_world.xz * 3.80 + vec2(-3.7, 8.4)) * 0.40;
		vec3 eart = mix(vec3(0.085, 0.054, 0.032), vec3(0.155, 0.112, 0.070), e);
		float peb = smoothstep(0.925, 0.978,
			vnoise2(v_world.xz * 4.7 + vec2(2.2, -6.8)));
		eart = mix(eart, vec3(0.180, 0.150, 0.115), peb * 0.55);
		float peb2 = smoothstep(0.958, 0.993,
			vnoise2(v_world.xz * 7.1 + vec2(-4.6, 1.7)));
		eart = mix(eart, vec3(0.255, 0.225, 0.185), peb2 * 0.45);
		eart *= 1.0 + 0.10 * (e - 0.5);
		ALBEDO = eart;
		ROUGHNESS = 0.96;
		SPECULAR = 0.02;
		EMISSION = vec3(0.008, 0.005, 0.003);
	}
	// Debug-only channel: white = rim band, black = no band.  Default 0.
	if (debug_rim > 1.5) {
		ALBEDO = vec3(texture(rim_distance, muv).r);
		EMISSION = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else if (debug_rim > 0.5) {
		ALBEDO = vec3(rim_band);
		EMISSION = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	}
	if (debug_island_type > 0.5) {
		vec3 tc = type_smooth * vec3(0.9, 0.2, 0.2)
			+ type_column * vec3(0.2, 0.9, 0.2)
			+ type_block * vec3(0.2, 0.3, 0.9);
		ALBEDO = tc;
		EMISSION = tc * 0.8;
	}
}
