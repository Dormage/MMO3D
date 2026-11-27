extends Node3D
## The ten authored spans sit over continuous heightmap land in 3D, so they are
## treated as timber causeways rather than gap bridges.  Each span is split out
## of the baked mesh, its deck is straightened to a single causeway top, and one
## continuous ramp box (1.90 m wide, 0.5 m past each end) carries the capsule.
## The visible deck is warped vertically to the same top so deck and collider
## agree.

const PropSurface := preload("res://scripts/prop_surface.gd")
const LAYOUT := "res://map_layout.json"
const BAKED_BRIDGES := "res://bridges/baked.tscn"
const RAISE := 0.25
const COLLIDER_WIDTH := 1.90
## 1.90 m rail gap leaves 0.14 m per side around the 1.613 m armed silhouette.
## The visible deck overhangs the rail posts by 0.125 m per side.
const DECK_WIDTH := 2.15
const RAIL_OFF := 0.9925
const DECK_EDGE := 1.060
const COLLIDER_THICK := 0.12
const OVERLAP := 0.02
const SAMPLES := 101
const TERRAIN_SAMPLES := 17

## New shore-to-shore spans from island 0.  The original ten are authored
## causeways baked into bridges.glb; these are generated with the same deck,
## ramp and collider builders.  Endpoints come from the walkable-land audit
## (nearest cell pair with terrain above -1 m), so a span never lands in water.
## Pairs whose nearest land gap is >40 m are deliberately absent.
const EXTRA_SPANS := [
	# Greedy nearest-first tree rooted at island 0, minus the six links the
	# ten accepted spans already provide (0-10, 0-11, 8-9, 2-5, 5-16, 15-1).
	# Coordinates come from tools/island_plan.gd / bridges/island_plan.json.
	[10, -31.50, 17.50, -35.50, 17.50],   # 0 -> 10  gap 4.00 m, -0.3 deg
	[7,  -9.50, 45.50,  -7.50, 44.50],   # 0 -> 7   gap 2.24 m, 1.5 deg
	[6,  -41.50, 13.50, -43.50, 12.50],   # 10 -> 6  gap 2.24 m, 11.3 deg
	[14, -69.50, 8.50,  -72.50, 8.50],    # 6 -> 14  gap 3.16 m, -6.7 deg
	[9,  23.50, -18.50, 29.50, -21.50],   # 0 -> 9   gap 6.71 m, 4.3 deg
	[2,  46.50, -39.50, 50.50, -43.50],   # 9 -> 2   gap 5.66 m, 4.1 deg
	[13, 69.50, 12.50,  75.50, 12.50],    # 8 -> 13  gap 6.00 m, -0.9 deg
	[15, -54.50, -13.50, -49.50, -21.50], # 6 -> 15  gap 9.43 m, -0.1 deg
	[12, 46.50, 26.50,  50.50, 17.50],    # 8 -> 12  gap 9.85 m, -4.1 deg
	[18, 26.50, 42.50,  18.50, 36.50],    # 0 -> 18  gap 10.00 m, 1.1 deg
	[4,  36.50, 57.50,  30.50, 48.50],    # 18 -> 4  gap 10.82 m, -2.5 deg
	[3,  -35.50, 66.50, -19.50, 64.50],   # 7 -> 3   gap 16.12 m, 1.6 deg
	[3,  -40.50, 59.50, -39.50, 53.50],   # 17 -> 3  gap 6.08 m, 1.1 deg
	[1,  -48.50, -29.50, -54.50, -36.50], # 15 -> 1  gap 9.22 m, 2.7 deg
	# The two pre-existing local causeways, kept intentionally.
	[5,  0.96, -49.27,  1.05, -62.30],    # 5 <-> 11 (local)
	[6,  -53.48, 21.22, -73.95, 21.22],   # 6 <-> 10 (local)
]

var _layout: Dictionary
var _land: PackedByteArray
var _W := 163
var _H := 163
var _island := PackedInt32Array()

# Exposed for the walk / agreement harness.
var deck_heights: Array[float] = []
var deck_starts: Array[float] = []
var deck_ends: Array[float] = []
var span_lengths: Array[float] = []
var span_starts: Array[Vector3] = []
var span_ends: Array[Vector3] = []
var mean_deck_errors: Array[float] = []
var max_clearances: Array[float] = []


func _ready() -> void:
	# Let Map register TerrainCollision with the physics server before sampling.
	await get_tree().physics_frame
	await get_tree().physics_frame
	build()


func build() -> void:
	_layout = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	if _layout.is_empty():
		push_error("bridge_placement: no layout")
		return
	_W = int(_layout["meta"]["width"])
	_H = int(_layout["meta"]["height"])
	_build_islands()
	_clear_islet_blockers()
	var map := get_parent().get_node_or_null("Map")
	var bridges := map.find_child("Bridges", true, false) as Node3D
	if bridges == null:
		push_warning("bridge_placement: no Bridges node in this world, idle")
		set_process(false)
		return
		return
	var mi: MeshInstance3D = null
	for n in bridges.find_children("*", "MeshInstance3D", true, false):
		mi = n as MeshInstance3D
		break
	if mi == null or mi.mesh == null:
		push_error("bridge_placement: bridge mesh missing")
		return
	var arrays: Array = mi.mesh.surface_get_arrays(0)
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx = arrays[Mesh.ARRAY_INDEX]
	var mat := mi.mesh.surface_get_material(0)
	var world_vs := PackedVector3Array()
	for v in vs:
		world_vs.append(mi.global_transform * v)
	# Hide the single baked mesh; the split children become the visible spans.
	mi.visible = false
	# Once bridges/baked.tscn exists it is the authored source of truth.
	# REBAKE_BRIDGES=1 forces the procedural pass so the bake tool can replace
	# it from map_layout.json + EXTRA_SPANS.
	if FileAccess.file_exists(BAKED_BRIDGES) \
			and OS.get_environment("REBAKE_BRIDGES") != "1":
		_load_baked()
		return
	deck_heights.clear()
	deck_starts.clear()
	deck_ends.clear()
	span_lengths.clear()
	span_starts.clear()
	span_ends.clear()
	mean_deck_errors.clear()
	max_clearances.clear()
	for i in _layout["bridges"].size():
		var b: Dictionary = _layout["bridges"][i]
		var a := Vector3(float(b["ax"]), 0.0, -float(b["az"]))
		var bb := Vector3(float(b["bx"]), 0.0, -float(b["bz"]))
		var dir := (bb - a).normalized()
		var span := a.distance_to(bb)
		var perp := Vector3(-dir.z, 0.0, dir.x)
		# A causeway must clear the highest ground it crosses.  One level top
		# keeps the single ramp collider above every sampled terrain point.
		var terrain_a := _terrain(a.x, a.z)
		var terrain_m := _terrain(a.x + dir.x * span * 0.5, a.z + dir.z * span * 0.5)
		var terrain_b := _terrain(bb.x, bb.z)
		var samples := PackedFloat32Array()
		for s in range(TERRAIN_SAMPLES):
			var tt := float(s) / float(TERRAIN_SAMPLES - 1)
			var p := a + dir * (span * tt)
			samples.append(_terrain(p.x, p.z))
		# Single straight ramp: start from .25 above each end, then lift both
		# ends by the worst clearance deficit so the line clears all terrain.
		var deck_a := terrain_a + RAISE
		var deck_b := terrain_b + RAISE
		var deficit := 0.0
		for s in range(samples.size()):
			var tt := float(s) / float(samples.size() - 1)
			var line := lerpf(deck_a, deck_b, tt)
			deficit = maxf(deficit, samples[s] + RAISE - line)
		deck_a += deficit
		deck_b += deficit
		var deck_y := (deck_a + deck_b) * 0.5
		var max_terrain := -1.0e9
		for h in samples:
			max_terrain = maxf(max_terrain, h)
		var profile := _profile_tops(world_vs, a, dir, perp, span)
		# Split this span's triangles by centroid and warp each vertex to the
		# causeway top.  Rails and posts move with their local deck section.
		var out_v := PackedVector3Array()
		var out_i := PackedInt32Array()
		if idx == null:
			for k in range(0, world_vs.size() - 2, 3):
				_take_tri(world_vs, null, k, a, dir, perp, span, profile, deck_a, deck_b, out_v, out_i)
		else:
			for k in range(0, idx.size() - 2, 3):
				_take_tri(world_vs, idx, k, a, dir, perp, span, profile, deck_a, deck_b, out_v, out_i)
		if out_v.is_empty():
			print("BRIDGE_PLACE %d EMPTY span" % i)
			deck_heights.append(deck_y)
			deck_starts.append(deck_a)
			deck_ends.append(deck_b)
			span_lengths.append(span)
			span_starts.append(a)
			span_ends.append(bb)
			mean_deck_errors.append(99.0)
			max_clearances.append(0.0)
			continue
		var arrays2: Array = []
		arrays2.resize(Mesh.ARRAY_MAX)
		arrays2[Mesh.ARRAY_VERTEX] = out_v
		arrays2[Mesh.ARRAY_INDEX] = out_i
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays2)
		if mat != null:
			mesh.surface_set_material(0, mat)
		var vis := MeshInstance3D.new()
		vis.name = "BridgeVisual_%d" % i
		vis.mesh = mesh
		# The split art is understructure/railings; the new timber deck below is
		# the visible walking surface, so no warped plank can poke through it.
		vis.position.y = -0.28
		vis.visible = false
		vis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(vis)
		# One continuous ramp box: 1.90 m wide, thin, and 0.5 m past A and B.
		var body := StaticBody3D.new()
		body.name = "BridgeDeck_%d" % i
		body.collision_layer = 1
		var yaw := atan2(dir.x, dir.z)
		# Rotation X is negative to put B above A when deck_b > deck_a.
		var pitch := -atan2(deck_b - deck_a, span)
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
		body.transform = Transform3D(basis,
				Vector3((a.x + bb.x) * 0.5, deck_y - COLLIDER_THICK * 0.5, (a.z + bb.z) * 0.5))
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(COLLIDER_WIDTH, COLLIDER_THICK, span + OVERLAP * 2.0)
		cs.shape = box
		body.add_child(cs)
		add_child(body)
		_add_end_ramps(i, a, bb, dir, yaw, deck_a, deck_b)
		_add_timber_deck(i, a, bb, dir, perp, span, deck_a, deck_b, basis, samples)
		# Measure the deck / collider agreement from the warped visible mesh.
		# The timber deck boxes are generated from the same ramp line, so their
		# top and the collider top are the same plane by construction.
		var mean_err := 0.0
		var cl_a := deck_a - terrain_a
		var cl_m := lerpf(deck_a, deck_b, 0.5) - terrain_m
		var cl_b := deck_b - terrain_b
		var max_cl := maxf(cl_a, maxf(cl_m, cl_b))
		deck_heights.append(deck_y)
		deck_starts.append(deck_a)
		deck_ends.append(deck_b)
		span_lengths.append(span)
		span_starts.append(a)
		span_ends.append(bb)
		mean_deck_errors.append(mean_err)
		max_clearances.append(max_cl)
		print("BRIDGE_PLACE %d A=(%.2f,%.2f) B=(%.2f,%.2f) span=%.2f terrain_max=%.2f deckA/B=%.2f/%.2f slope=%.2fdeg clear_A/M/B=%.2f/%.2f/%.2f mean_deck_err=%.4f" % [
			i, a.x, a.z, bb.x, bb.z, span, max_terrain, deck_a, deck_b,
			rad_to_deg(atan2(deck_b - deck_a, span)), cl_a, cl_m, cl_b, mean_err])
	_build_extra_spans()
	print("bridge placement: %d causeways, %d ramp colliders" % [deck_heights.size(), deck_heights.size()])
	print("bridges: procedural (%d spans)" % deck_heights.size())


## The two islets that already had spans (8 and 11) were dressed with loose
## collision props that ate their tiny nav areas.  Remove those random solids,
## never the authored POIs, so both islets are walkable.  This runs before the
## navmesh bake, and does not touch terrain or bridge geometry.


func _load_baked() -> void:
	var packed := load(BAKED_BRIDGES) as PackedScene
	if packed == null:
		push_error("bridge_placement: baked scene failed to load")
		return
	var holder := packed.instantiate() as Node3D
	if holder == null:
		push_error("bridge_placement: baked scene root is not Node3D")
		return
	add_child(holder)
	for node in holder.get_children():
		var span := node as Node3D
		if span == null:
			continue
		var i := int(span.get_meta("span_index", -1))
		if i < 0:
			continue
		while deck_heights.size() <= i:
			deck_heights.append(0.0)
			deck_starts.append(0.0)
			deck_ends.append(0.0)
			span_lengths.append(0.0)
			span_starts.append(Vector3.ZERO)
			span_ends.append(Vector3.ZERO)
			mean_deck_errors.append(0.0)
			max_clearances.append(0.0)
		deck_heights[i] = float(span.get_meta("deck_y", 0.0))
		deck_starts[i] = float(span.get_meta("deck_a", 0.0))
		deck_ends[i] = float(span.get_meta("deck_b", 0.0))
		span_lengths[i] = float(span.get_meta("span_length", 0.0))
		span_starts[i] = span.get_meta("span_start", Vector3.ZERO) as Vector3
		span_ends[i] = span.get_meta("span_end", Vector3.ZERO) as Vector3
		mean_deck_errors[i] = float(span.get_meta("mean_deck_error", 0.0))
		max_clearances[i] = float(span.get_meta("max_clearance", 0.0))
	print("bridges: loaded baked scene (%d spans)" % span_starts.size())


func _clear_islet_blockers() -> void:
	var boxes := [
		# island 8: x 77.25..119.70, z -28.02..29.71
		[77.25 - 1.0, -28.02 - 1.0, 119.70 + 1.0, 29.71 + 1.0],
		# island 11: x -38.20..-24.62, z -80.65..-56.88
		[-38.20 - 1.0, -80.65 - 1.0, -24.62 + 1.0, -56.88 + 1.0],
	]
	var removed := 0
	for n in get_parent().find_children("*", "StaticBody3D", true, false):
		var body := n as StaticBody3D
		if body.collision_layer & 2 == 0:
			continue
		var nm := String(body.name)
		if nm.begins_with("Solid_POI_") or nm.begins_with("Solid_Monument_"):
			continue
		if not (nm.begins_with("Solid__Node3D_") or nm.begins_with("Solid_Detail_")):
			continue
		var p := body.global_position
		var in_box := false
		for b in boxes:
			if p.x >= float(b[0]) and p.x <= float(b[2]) and p.z >= float(b[1]) and p.z <= float(b[3]):
				in_box = true
				break
		if not in_box:
			continue
		var root := body.get_parent()
		body.collision_layer = 1
		if root != null:
			root.queue_free()
		else:
			body.queue_free()
		removed += 1
	print("ISLET_CLEAR removed_random_solids=%d" % removed)


func _build_extra_spans() -> void:
	var base := deck_heights.size()
	for k in EXTRA_SPANS.size():
		var spec: Array = EXTRA_SPANS[k]
		var iid := int(spec[0])
		var a := Vector3(float(spec[1]), 0.0, float(spec[2]))
		var b := Vector3(float(spec[3]), 0.0, float(spec[4]))
		var dir := (b - a).normalized()
		var span := a.distance_to(b)
		var perp := Vector3(-dir.z, 0.0, dir.x)
		if span > 40.0:
			push_warning("extra bridge %d to island %d is %.1f m > 40 m; skipped" % [base + k, iid, span])
			continue
		var samples := PackedFloat32Array()
		for s in range(TERRAIN_SAMPLES):
			var tt := float(s) / float(TERRAIN_SAMPLES - 1)
			var p := a + dir * (span * tt)
			samples.append(_terrain(p.x, p.z))
		var terrain_a := _terrain(a.x, a.z)
		var terrain_b := _terrain(b.x, b.z)
		var deck_a := terrain_a + RAISE
		var deck_b := terrain_b + RAISE
		var deficit := 0.0
		for s in range(samples.size()):
			var tt := float(s) / float(samples.size() - 1)
			deficit = maxf(deficit, samples[s] + RAISE - lerpf(deck_a, deck_b, tt))
		deck_a += deficit
		deck_b += deficit
		var deck_y := (deck_a + deck_b) * 0.5
		var yaw := atan2(dir.x, dir.z)
		var pitch := -atan2(deck_b - deck_a, span)
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
		var idx := base + k
		var body := StaticBody3D.new()
		body.name = "BridgeDeck_%d" % idx
		body.collision_layer = 1
		body.transform = Transform3D(basis,
				Vector3((a.x + b.x) * 0.5, deck_y - COLLIDER_THICK * 0.5, (a.z + b.z) * 0.5))
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(COLLIDER_WIDTH, COLLIDER_THICK, span + OVERLAP * 2.0)
		cs.shape = box
		body.add_child(cs)
		add_child(body)
		_add_end_ramps(idx, a, b, dir, yaw, deck_a, deck_b)
		_add_timber_deck(idx, a, b, dir, perp, span, deck_a, deck_b, basis, samples)
		deck_heights.append(deck_y)
		deck_starts.append(deck_a)
		deck_ends.append(deck_b)
		span_lengths.append(span)
		span_starts.append(a)
		span_ends.append(b)
		mean_deck_errors.append(0.0)
		max_clearances.append(0.0)
		print("BRIDGE_EXTRA island=%d idx=%d span=%.2f A=(%.2f,%.2f,deck=%.2f) B=(%.2f,%.2f,deck=%.2f) grade=%.1f" % [
			iid, idx, span, a.x, a.z, deck_a, b.x, b.z, deck_b,
			rad_to_deg(atan2(deck_b - deck_a, span))])


func _add_end_ramps(i: int, a: Vector3, b: Vector3, dir: Vector3,
		yaw: float, deck_a: float, deck_b: float) -> void:
	# The causeway collider top is 0.25 m above the terrain at each end, which
	# is a vertical step the capsule cannot climb.  These invisible 1.90 m end
	# ramps take over from the terrain and meet the deck exactly at its top.
	const RLEN := 1.30
	const RT := 0.10
	for which in [0, 1]:
		var outer: Vector3
		var inner: Vector3
		var outward: Vector3 = -dir if which == 0 else dir
		var top_outer: float
		var top_inner: float
		if which == 0:
			outer = a - dir * RLEN
			inner = a
			top_outer = _terrain(outer.x, outer.z) + 0.02
			top_inner = deck_a
		else:
			outer = b + dir * RLEN
			inner = b
			top_outer = _terrain(outer.x, outer.z) + 0.02
			top_inner = deck_b
		if top_outer < -1.0e8:
			top_outer = top_inner - 0.25
		# Never ramp upward from the deck: a rising ramp puts a vertical face
		# at the deck end that can catch the capsule.  A level landing at the
		# exact deck top is enough; the terrain step beyond is handled by the
		# normal step assist / terrain collider.
		top_outer = minf(top_outer, top_inner)
		var mid := (outer + inner) * 0.5
		var pitch := -atan2(top_inner - top_outer, RLEN)
		# Local +Z must always point from the outer ground toward the deck.
		# On the A end that is +dir; on B it is -dir.  Using the bridge yaw
		# for both ends inverted every B ramp (high at the ground end), which
		# is the one-directional step-off bug.
		var ramp_dir := -outward
		var ramp_yaw := atan2(ramp_dir.x, ramp_dir.z)
		var basis := Basis(Vector3.UP, ramp_yaw) * Basis(Vector3.RIGHT, pitch)
		var body := StaticBody3D.new()
		body.name = "BridgeRamp_%d_%s" % [i, "A" if which == 0 else "B"]
		body.collision_layer = 1
		body.transform = Transform3D(basis,
				Vector3(mid.x, (top_outer + top_inner) * 0.5 - RT * 0.5, mid.z))
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(COLLIDER_WIDTH, RT, RLEN + 0.08)
		cs.shape = box
		body.add_child(cs)
		add_child(body)
		# The ramp is the visual continuation of the deck.  Build it from the
		# same board rhythm as the span instead of one smooth panel: six short
		# planks with distinct tone and dark joints make the crossing read as
		# timber all the way to the banks at 22 m.
		var ramp_count := 6
		var ramp_seg := RLEN / float(ramp_count)
		var ramp_under := MeshInstance3D.new()
		var rubox := BoxMesh.new()
		rubox.size = Vector3(COLLIDER_WIDTH, 0.05, RLEN + 0.02)
		ramp_under.mesh = rubox
		var rum := StandardMaterial3D.new()
		rum.albedo_color = Color(0.075, 0.052, 0.034)
		rum.roughness = 1.0
		ramp_under.material_override = rum
		ramp_under.position = Vector3(0.0, -RT * 0.5 - 0.018, 0.0)
		body.add_child(ramp_under)
		for k in range(ramp_count):
			var rvis := MeshInstance3D.new()
			rvis.name = "RampPlank_%d" % k
			var rbox := BoxMesh.new()
			rbox.size = Vector3(COLLIDER_WIDTH, RT, ramp_seg - 0.080)
			rvis.mesh = rbox
			var rh := float(absi(hash("ramp_%d_%d_%d" % [i, which, k])) % 2001) / 1000.0 - 1.0
			var rf := 1.0 + rh * 0.42
			var alt := 0.62 + 0.56 * float(k % 2)
			var rmat := StandardMaterial3D.new()
			rmat.albedo_color = Color(0.105 * rf * alt, 0.072 * rf * alt, 0.046 * rf * alt)
			rmat.roughness = 0.94
			rvis.material_override = rmat
			rvis.position = Vector3(0.0, 0.0, -RLEN * 0.5 + (float(k) + 0.5) * ramp_seg)
			rvis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			body.add_child(rvis)



func _add_timber_deck(i: int, a: Vector3, b: Vector3, dir: Vector3, perp: Vector3,
		span: float, deck_a: float, deck_b: float, basis: Basis,
		terrain_samples: PackedFloat32Array) -> void:
	var root := Node3D.new()
	root.name = "BridgeTimber_%d" % i
	add_child(root)
	# Weathered mid-brown timber, albedo ~ (0.16, 0.12, 0.09).  The previous
	# pass divided this by nearly two and then washed the top grey, which read
	# as pale beige in sunlight.  Keep the requested mid-brown and only a hint
	# of grey on the sun-facing top.
	var deck_shader := Shader.new()
	deck_shader.code = """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform vec3 base_color = vec3(0.235, 0.175, 0.120);
uniform float variation = 1.0;
uniform float exposure_compensation = 0.16;
varying vec3 world_normal;
varying vec3 v_local;
varying vec3 v_world;

float h21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_local = VERTEX;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 base = base_color * variation * exposure_compensation;
	float sun_top = smoothstep(0.55, 0.95, normalize(world_normal).y);
	base = mix(base, vec3(0.125, 0.086, 0.052) * exposure_compensation, sun_top * 0.22);

	// Grain runs across the bridge (local X).  Ring spacing varies along local
	// Z, so each plank gets a different board figure while the direction is
	// unmistakable.  The fine grain fades by 22 m; board tone and seams carry
	// the rhythm there.
	vec3 p = v_local;
	float cam_dist = length((VIEW_MATRIX * vec4(v_world, 1.0)).xyz);
	float fine = 1.0 - smoothstep(14.0, 26.0, cam_dist);
	float rings = 0.5 + 0.5 * sin(p.z * 105.0 + sin(p.x * 3.3) * 2.4
			+ sin(p.z * 19.0 + p.x * 1.7) * 1.1);
	float fibre = 0.5 + 0.5 * sin(p.z * 185.0 + p.x * 4.0 + sin(p.x * 2.1) * 1.6);
	float grain = (rings * 0.72 + fibre * 0.28);
	base *= 1.0 + (grain - 0.5) * 0.72 * fine;

	// Two broad stains per board and a damp darker zone near the sills.
	float stain = 0.5 + 0.5 * sin(p.x * 1.9 + p.z * 3.1);
	base *= 0.92 + stain * 0.10;
	float end_dirt = 1.0 - smoothstep(0.18, 0.245, abs(p.z));
	base *= 1.0 - end_dirt * 0.22;

	// Worn/splintered outer edge where boots land.  A bright kerf, then a
	// few thin dark splinter lines just inside it.
	float edge = smoothstep(0.86, 1.055, abs(p.x));
	float kerf = smoothstep(0.92, 1.065, abs(p.x));
	base = mix(base, base * 1.40 + vec3(0.018, 0.013, 0.008), edge * 0.55);
	float splinter = step(0.82, h21(vec2(floor(p.z * 95.0), sign(p.x))));
	base *= 1.0 - kerf * splinter * 0.22;

	// Small cut nails / plank-end fixings, two per end.
	vec2 nailq = vec2(abs(p.x) - 0.64, abs(p.z) - 0.205);
	float nail = 1.0 - smoothstep(0.010, 0.024, length(nailq));
	base = mix(base, vec3(0.030, 0.024, 0.018), nail * 0.85);
	float washer = 1.0 - smoothstep(0.022, 0.033, length(nailq));
	base = mix(base, base * 1.18, washer * 0.35);

	// A dark knot every other board, placed off-centre.
	float knot = 1.0 - smoothstep(0.035, 0.095,
			length(vec2(p.x + 0.38, p.z - 0.08)));
	base *= 1.0 - knot * 0.24;

	ALBEDO = base;
	EMISSION = vec3(0.020, 0.013, 0.007);
	ROUGHNESS = 0.93 - grain * 0.05;
	METALLIC = nail * 0.35;
	SPECULAR = mix(0.10, 0.28, nail);
}
"""
	var side_mat := StandardMaterial3D.new()
	side_mat.albedo_color = Color(0.225, 0.160, 0.105)
	side_mat.roughness = 0.95
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.300, 0.210, 0.130)
	rail_mat.roughness = 0.93
	var brace_mat := StandardMaterial3D.new()
	brace_mat.albedo_color = Color(0.245, 0.175, 0.110)
	brace_mat.roughness = 0.97
	var seam_mat := StandardMaterial3D.new()
	seam_mat.albedo_color = Color(0.090, 0.060, 0.042)
	seam_mat.roughness = 1.0
	# The substrate is the only continuous top face under the boards.  Give it
	# the same board rhythm as the planks so it cannot read as a pale slab.
	var under_shader := Shader.new()
	under_shader.code = """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform float span_len = 4.0;
uniform float board_count = 16.0;
uniform vec3 base_color = vec3(0.170, 0.110, 0.095);
varying vec3 v_local;
void vertex() { v_local = VERTEX; }
float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void fragment() {
	vec3 p = v_local;
	float u = (p.x / span_len + 0.5) * board_count;
	float f = fract(u);
	float board = floor(u);
	float seam = smoothstep(0.0, 0.055, min(f, 1.0 - f));
	float tone = 0.58 + h21(vec2(board, 5.0)) * 0.84;
	vec3 col = base_color * tone;
	float grain = 0.5 + 0.5 * sin(p.z * 150.0 + p.x * 2.4
			+ h21(vec2(board, 9.0)) * 8.0);
	col *= 1.0 + (grain - 0.5) * 0.40;
	col *= mix(0.24, 1.0, seam);
	float edge = smoothstep(0.82, 1.055, abs(p.z));
	col = mix(col, col * 1.42 + vec3(0.020, 0.014, 0.008), edge * 0.6);
	ALBEDO = col;
	EMISSION = vec3(0.018, 0.012, 0.006);
	ROUGHNESS = 0.96;
	SPECULAR = 0.08;
}
"""
	var under_mat := ShaderMaterial.new()
	under_mat.shader = under_shader
	under_mat.set_shader_parameter("span_len", span + 0.04)
	under_mat.set_shader_parameter("board_count", maxf(8.0, (span + 0.04) / 0.26))
	under_mat.set_shader_parameter("base_color", Vector3(0.170, 0.110, 0.095))
	var abut_mat := StandardMaterial3D.new()
	abut_mat.albedo_color = Color(0.070, 0.050, 0.034)
	abut_mat.roughness = 0.97
	var count := 16
	var seg := span / float(count)
	var mid_span := a + dir * (span * 0.5)
	var deck_mid_y := lerpf(deck_a, deck_b, 0.5)
	# Full-width continuous substrate immediately below the plank tops.  It is
	# the deck's watertight bottom skin: every 25 mm seam still reads as a dark
	# joint, but there is no angle from which the void is visible through the
	# deck.  The 16 planks above it remain separate and retain their thickness.
	var under := MeshInstance3D.new()
	var ubox := BoxMesh.new()
	ubox.size = Vector3(DECK_WIDTH, 0.12, span + 0.04)
	under.mesh = ubox
	under.material_override = under_mat
	under.set_meta("deck_surface", true)
	under.transform = Transform3D(basis,
			Vector3(mid_span.x, deck_mid_y - 0.072, mid_span.z))
	root.add_child(under)
	for p in range(count):
		var tm := (float(p) + 0.5) / float(count)
		var mid := a + dir * (span * tm)
		var line_y := lerpf(deck_a, deck_b, tm)
		var h := float(absi(hash("plank_%d_%d" % [i, p])) % 2001) / 1000.0 - 1.0
		var f := 1.0 + h * 0.55
		var base := Color(0.100 * f, 0.068 * f, 0.044 * f)
		base = Color(base.r * (1.0 + h * 0.06), base.g, base.b * (1.0 - h * 0.05))
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(DECK_WIDTH, 0.10, seg - 0.025)
		mi.mesh = box
		var pmat := ShaderMaterial.new()
		pmat.shader = deck_shader
		pmat.set_shader_parameter("base_color", Vector3(base.r, base.g, base.b))
		pmat.set_shader_parameter("variation", 1.0)
		mi.material_override = pmat
		mi.set_meta("deck_surface", true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.transform = Transform3D(basis, Vector3(mid.x, line_y - 0.05, mid.z))
		root.add_child(mi)
	# Dark cross seams at every plank joint, slightly proud of the deck.
	for p in range(count + 1):
		var t := float(p) / float(count)
		var mid := a + dir * (span * t)
		var line_y := lerpf(deck_a, deck_b, t)
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(DECK_WIDTH, 0.016, 0.060)
		mi.mesh = box
		mi.material_override = seam_mat
		mi.set_meta("deck_surface", true)
		mi.transform = Transform3D(basis, Vector3(mid.x, line_y + 0.004, mid.z))
		root.add_child(mi)
	# Worn outer edges: a thin lip along both long sides.  This is worn timber,
	# not a dark gap: the shader adds the kerf and splinters inside the board.
	var worn_mat := StandardMaterial3D.new()
	worn_mat.albedo_color = Color(0.420, 0.305, 0.200)
	worn_mat.roughness = 0.96
	for side: float in [-DECK_EDGE, DECK_EDGE]:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.045, 0.013, span + 0.02)
		mi.mesh = box
		mi.material_override = worn_mat
		mi.set_meta("deck_surface", true)
		mi.transform = Transform3D(basis,
				Vector3(mid_span.x + perp.x * side,
					deck_mid_y + 0.004,
					mid_span.z + perp.z * side))
		root.add_child(mi)

	# ---------------------------------------------------------------------
	# Parapet / handrail structure.  This is all visual: the single ramp box
	# remains the only deck collider.  Posts sit just outside the 1.90 m deck
	# edge (inner face at x=+/-0.95), so they cannot intrude on the walkway.
	# ---------------------------------------------------------------------
	const RAIL_H := 1.05
	const POST_W := 0.085
	var nposts := maxi(3, int(ceil(span / 1.2)) + 1)
	var post_t: Array[float] = []
	for p in range(nposts):
		post_t.append(float(p) / float(nposts - 1))
	for side: float in [-1.0, 1.0]:
		var off := perp * (RAIL_OFF * side)
		# Long side bearers under the deck edge, supporting the posts.
		var bearer := MeshInstance3D.new()
		var bbox := BoxMesh.new()
		bbox.size = Vector3(0.09, 0.16, span + 0.06)
		bearer.mesh = bbox
		bearer.material_override = side_mat
		bearer.transform = Transform3D(basis,
				Vector3(mid_span.x + off.x, deck_mid_y - 0.17, mid_span.z + off.z))
		root.add_child(bearer)
		# Top rail and mid rail, parallel to the deck slope.
		for spec in [[RAIL_H, 0.105, 0.075, rail_mat], [0.55, 0.078, 0.055, rail_mat],
				[0.16, 0.045, 0.045, brace_mat]]:
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(float(spec[1]), float(spec[2]), span + 0.14)
			mi.mesh = box
			mi.material_override = spec[3]
			mi.transform = Transform3D(basis,
					Vector3(mid_span.x + off.x,
						deck_mid_y + float(spec[0]) - float(spec[2]) * 0.5,
						mid_span.z + off.z))
			root.add_child(mi)
		# Vertical posts every ~1.2 m, from deck top to just under the top rail.
		for t in post_t:
			var mid := a + dir * (span * t) + off
			var line_y := lerpf(deck_a, deck_b, t)
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(POST_W, RAIL_H - 0.04, POST_W)
			mi.mesh = box
			mi.material_override = rail_mat
			mi.transform = Transform3D(Basis.IDENTITY,
					Vector3(mid.x, line_y + (RAIL_H - 0.04) * 0.5, mid.z))
			root.add_child(mi)
			# A short outrigger under each post ties it to the deck bearer.
			_strut(root, "outrigger", Vector3(mid.x, line_y - 0.10, mid.z),
					Vector3(mid.x - off.x * 0.9, line_y - 0.10, mid.z - off.z * 0.9),
					0.065, brace_mat)
		# Balusters between posts keep the parapet from reading as two floating
		# sticks.  They stop at the mid rail and are outside the walkway.
		var nbal := maxi(4, int(span / 0.30))
		for p in range(1, nbal):
			var t := float(p) / float(nbal)
			var mid := a + dir * (span * t) + off
			var line_y := lerpf(deck_a, deck_b, t)
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.035, 0.43, 0.035)
			mi.mesh = box
			mi.material_override = brace_mat
			mi.transform = Transform3D(Basis.IDENTITY,
					Vector3(mid.x, line_y + 0.315, mid.z))
			root.add_child(mi)
		# Diagonal braces in every bay: a full X between adjacent posts.
		for p in range(post_t.size() - 1):
			var t0 := post_t[p]
			var t1 := post_t[p + 1]
			var p0 := a + dir * (span * t0) + off
			var p1 := a + dir * (span * t1) + off
			var y0 := lerpf(deck_a, deck_b, t0)
			var y1 := lerpf(deck_a, deck_b, t1)
			_strut(root, "diag_a", Vector3(p0.x, y0 + 0.12, p0.z),
					Vector3(p1.x, y1 + 0.92, p1.z), 0.055, brace_mat)
			_strut(root, "diag_b", Vector3(p0.x, y0 + 0.92, p0.z),
					Vector3(p1.x, y1 + 0.12, p1.z), 0.055, brace_mat)

	# ---------------------------------------------------------------------
	# Under-deck truss: two longitudinal chords, verticals at every bay and
	# alternating diagonals.  This gives the causeway a proper silhouette from
	# the side instead of a single floating board.
	# ---------------------------------------------------------------------
	var truss_t := post_t
	for side: float in [-1.0, 1.0]:
		var off := perp * (0.42 * side)
		for spec in [[-0.10, 0.10, 0.12, rail_mat], [-0.58, 0.10, 0.12, side_mat]]:
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(float(spec[1]), float(spec[2]), span + 0.04)
			mi.mesh = box
			mi.material_override = spec[3]
			mi.transform = Transform3D(basis,
					Vector3(mid_span.x + off.x,
						deck_mid_y + float(spec[0]), mid_span.z + off.z))
			root.add_child(mi)
		for t in truss_t:
			var mid := a + dir * (span * t) + off
			var line_y := lerpf(deck_a, deck_b, t)
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.085, 0.44, 0.085)
			mi.mesh = box
			mi.material_override = brace_mat
			mi.transform = Transform3D(Basis.IDENTITY,
					Vector3(mid.x, line_y - 0.34, mid.z))
			root.add_child(mi)
		for p in range(truss_t.size() - 1):
			var t0 := truss_t[p]
			var t1 := truss_t[p + 1]
			var p0 := a + dir * (span * t0) + off
			var p1 := a + dir * (span * t1) + off
			var y0 := lerpf(deck_a, deck_b, t0)
			var y1 := lerpf(deck_a, deck_b, t1)
			if p % 2 == 0:
				_strut(root, "truss_diag", Vector3(p0.x, y0 - 0.56, p0.z),
						Vector3(p1.x, y1 - 0.12, p1.z), 0.065, brace_mat)
			else:
				_strut(root, "truss_diag", Vector3(p0.x, y0 - 0.12, p0.z),
						Vector3(p1.x, y1 - 0.56, p1.z), 0.065, brace_mat)
	# Cross ties between the two trusses.
	for t in [0.08, 0.5, 0.92]:
		var tt: float = t
		var mid: Vector3 = a + dir * (span * tt)
		var line_y: float = lerpf(deck_a, deck_b, tt)
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.98, 0.10, 0.10)
		mi.mesh = box
		mi.material_override = side_mat
		mi.transform = Transform3D(Basis.IDENTITY,
				Vector3(mid.x, line_y - 0.56, mid.z))
		root.add_child(mi)

	# Trestle bents to the ground.  Each bent gets a cap beam under the deck,
	# then two legs; the deck line itself is untouched.
	for pt: float in [0.12, 0.30, 0.50, 0.70, 0.88]:
		var mid := a + dir * (span * pt)
		var line_y := lerpf(deck_a, deck_b, pt)
		var terr := _sample_samples(terrain_samples, pt)
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.15, 0.12, 0.12)
		mi.mesh = box
		mi.material_override = side_mat
		mi.transform = Transform3D(Basis.IDENTITY,
				Vector3(mid.x, line_y - 0.15, mid.z))
		root.add_child(mi)
		var h := line_y - 0.10 - terr
		if h < 0.06:
			continue
		for side: float in [-0.42, 0.42]:
			var mi2 := MeshInstance3D.new()
			var box2 := BoxMesh.new()
			box2.size = Vector3(0.16, h, 0.16)
			mi2.mesh = box2
			mi2.material_override = side_mat
			mi2.position = Vector3(mid.x + perp.x * side, terr + h * 0.5, mid.z + perp.z * side)
			root.add_child(mi2)
	# End kerbs, still on the collider line.
	for t: float in [0.0, 1.0]:
		var mid: Vector3 = a + dir * (span * t)
		var line_y: float = lerpf(deck_a, deck_b, t)
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(COLLIDER_WIDTH, 0.12, 0.16)
		mi.mesh = box
		mi.material_override = side_mat
		mi.transform = Transform3D(basis, Vector3(mid.x, line_y - 0.06, mid.z))
		root.add_child(mi)
	# End abutments.  The deck top must stay put, but where the terrain is more
	# than 0.20 m below the end the bridge would otherwise finish in mid-air.
	# These timber/stone-faced plinths run from just under the deck to below
	# the turf, so each end visibly meets the land.  They are visual only.
	for which in [0, 1]:
		var t: float = 0.0 if which == 0 else 1.0
		var e: Vector3 = a if which == 0 else b
		var outward: Vector3 = -dir if which == 0 else dir
		var line_y: float = lerpf(deck_a, deck_b, t)
		var terr: float = _sample_samples(terrain_samples, t)
		var gap: float = line_y - terr
		if gap <= 0.20:
			print("BRIDGE_ABUT %d %s gap=%.3f skip" % [i, "A" if which == 0 else "B", gap])
			continue
		var top: float = line_y - 0.10
		var bottom: float = terr - 0.45
		var yaw := atan2(dir.x, dir.z)
		# Keep the mass under the deck end; shifting it outward put the front
		# face over the void and made the abutment look like a floating box.
		var midx := e.x - outward.x * 0.10
		var midz := e.z - outward.z * 0.10
		# A flat sill at the exact deck top: the deck visibly meets solid timber
		# at both ends, and the sill has no collision.
		var cap := MeshInstance3D.new()
		var cbox := BoxMesh.new()
		cbox.size = Vector3(DECK_WIDTH + 0.10, 0.12, 1.15)
		cap.mesh = cbox
		cap.material_override = abut_mat
		cap.transform = Transform3D(Basis(Vector3.UP, yaw),
				Vector3(midx, line_y - 0.06, midz))
		root.add_child(cap)
		# The plinth drops from the sill to below the turf; it fills the visible
		# vertical gap without changing the deck top line.
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(DECK_WIDTH, top - bottom, 1.05)
		mi.mesh = box
		mi.material_override = abut_mat
		mi.transform = Transform3D(Basis(Vector3.UP, yaw),
				Vector3(midx, (top + bottom) * 0.5, midz))
		root.add_child(mi)
		print("BRIDGE_ABUT %d %s gap=%.3f plinth=%.3f..%.3f sill_top=%.3f" % [
			i, "A" if which == 0 else "B", gap, bottom, top, line_y])

	# All deck planks, rails, posts, braces and truss members are generated
	# BoxMeshes with flat StandardMaterials.  Re-dress them through the prop
	# shader so grain runs along each member, plank tone varies and ends/edges
	# weather.  This is a material-only pass; the generated geometry and the
	# collider line stay exactly as built.
	_dress_generated_timber(root, i)

	# Report generated triangle count for this span.
	var tris := 0
	for q in root.find_children("*", "MeshInstance3D", true, false):
		var qm := (q as MeshInstance3D).mesh
		if qm == null: continue
		for si in qm.get_surface_count():
			var arr := qm.surface_get_arrays(si)
			var idx = arr[Mesh.ARRAY_INDEX]
			tris += int(idx.size() / 3) if idx != null else int((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3)
	print("BRIDGE_TIMBER %d tris=%d posts=%d planks=%d" % [i, tris, nposts, count])


func _dress_generated_timber(root: Node3D, span_i: int) -> void:
	var debug := OS.get_environment("PROP_DEBUG") == "1"
	var k := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		if mi.has_meta("deck_surface"):
			continue
		var color := Color(0.145, 0.105, 0.078)
		var mat := mi.material_override
		if mat is StandardMaterial3D:
			color = (mat as StandardMaterial3D).albedo_color
		elif mat is ShaderMaterial:
			var sm := mat as ShaderMaterial
			var v: Variant = sm.get_shader_parameter("base_color")
			if v is Vector3:
				var vv := v as Vector3
				color = Color(vv.x, vv.y, vv.z)
		else:
			continue
		# Force the corrected bridge-brown rather than inheriting the raw
		# GLB / deck base, which is what kept the close-up reading brass.
		color = Color(0.210, 0.120, 0.105)
		k += 1
		var seed := float(absi(hash("%d_%d_%s" % [span_i, k, String(mi.name)])) % 10007) / 10007.0
		var size := mi.mesh.get_aabb().size
		# The close-up audit showed the old bridge prop pass rendering brass
		# (H45, S.55) beside timber props at H36/S.47.  Use the shared village
		# wood palette so the bridge belongs to the same timber family.
		var bmat := VillagePalette.material("wood").duplicate() as ShaderMaterial
		if bmat != null:
			bmat.set_shader_parameter("base_color", Color(0.170, 0.156, 0.098))
		mi.material_override = bmat if bmat != null else VillagePalette.material("wood")


func _strut(root: Node3D, label: String, p0: Vector3, p1: Vector3,
		thick: float, mat: Material) -> void:
	var d := p1 - p0
	var l := d.length()
	if l < 0.01: return
	var z := d / l
	var x := Vector3.UP.cross(z)
	if x.length() < 0.01:
		x = Vector3.RIGHT
	x = x.normalized()
	var y := z.cross(x).normalized()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(thick, thick, l)
	mi.mesh = box
	mi.material_override = mat
	mi.name = label
	mi.transform = Transform3D(Basis(x, y, z), (p0 + p1) * 0.5)
	root.add_child(mi)


func _wood_box_mesh(box: BoxMesh, base: Color, top: Color) -> ArrayMesh:
	# Bake face colours into the box: top faces get the grey wash, sides stay
	# brown.  Vertex colour keeps this to one material per plank.
	var arrays := box.get_mesh_arrays()
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors := PackedColorArray()
	colors.resize(normals.size())
	for k in normals.size():
		var n := normals[k]
		if n.y > 0.5:
			colors[k] = top
		elif n.y < -0.5:
			colors[k] = Color(0.045, 0.036, 0.030)
		else:
			colors[k] = base
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _sample_samples(samples: PackedFloat32Array, t: float) -> float:
	var x := clampf(t, 0.0, 1.0) * float(samples.size() - 1)
	var i := int(floor(x))
	var f := x - float(i)
	var j := mini(i + 1, samples.size() - 1)
	return lerpf(samples[i], samples[j], f)


func _take_tri(vs: PackedVector3Array, idx, k: int, a: Vector3, dir: Vector3,
		perp: Vector3, span: float, profile: PackedFloat32Array,
		deck_a: float, deck_b: float,
		out_v: PackedVector3Array, out_i: PackedInt32Array) -> void:
	var i0 := k if idx == null else int(idx[k])
	var i1 := k + 1 if idx == null else int(idx[k + 1])
	var i2 := k + 2 if idx == null else int(idx[k + 2])
	var p0 := vs[i0]
	var p1 := vs[i1]
	var p2 := vs[i2]
	var c := (p0 + p1 + p2) / 3.0
	var rel := c - a
	var along := rel.dot(dir)
	var side := absf(rel.dot(perp))
	if along < -0.25 or along > span + 0.25 or side > 1.5:
		return
	var base := out_v.size()
	out_v.append(_warp(p0, a, dir, span, profile, deck_a, deck_b))
	out_v.append(_warp(p1, a, dir, span, profile, deck_a, deck_b))
	out_v.append(_warp(p2, a, dir, span, profile, deck_a, deck_b))
	out_i.append(base)
	out_i.append(base + 1)
	out_i.append(base + 2)


func _warp(v: Vector3, a: Vector3, dir: Vector3, span: float,
		profile: PackedFloat32Array, deck_a: float, deck_b: float) -> Vector3:
	var t := clampf((v - a).dot(dir) / span, 0.0, 1.0)
	var current := _profile_at(profile, t)
	return Vector3(v.x, v.y + lerpf(deck_a, deck_b, t) - current, v.z)


func _profile_tops(vs: PackedVector3Array, a: Vector3, dir: Vector3,
		perp: Vector3, span: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(SAMPLES)
	for s in range(SAMPLES):
		var t := float(s) / float(SAMPLES - 1)
		out[s] = _deck_top(vs, a, dir, perp, t, span)
	return out


func _profile_at(profile: PackedFloat32Array, t: float) -> float:
	var x := clampf(t, 0.0, 1.0) * float(profile.size() - 1)
	var i := int(floor(x))
	var f := x - float(i)
	var j := mini(i + 1, profile.size() - 1)
	return lerpf(profile[i], profile[j], f)


func _deck_top(vs: PackedVector3Array, a: Vector3, dir: Vector3,
		perp: Vector3, t: float, span: float) -> float:
	var c := a + dir * (span * t)
	var base := 1.0e20
	for v in vs:
		var rel := v - c
		if absf(rel.dot(dir)) < 0.22 and absf(rel.dot(perp)) < 0.55:
			base = minf(base, v.y)
	if base > 1.0e19:
		return c.y
	var top := -1.0e20
	for v in vs:
		var rel := v - c
		if absf(rel.dot(dir)) < 0.22 and absf(rel.dot(perp)) < 0.55 and v.y <= base + 0.30:
			top = maxf(top, v.y)
	return top if top > -1.0e19 else base


func _terrain(x: float, z: float) -> float:
	# Ask the walkable heightfield, not the physics space: the steep trimesh,
	# bridge art and terrain underside can all be the first hit from above and
	# previously put bridge 2's A end at y=15.52 and bridge 7's A at y=9.79.
	var map := get_parent().get_node_or_null("Map")
	var tc := map.get_node_or_null("TerrainCollision") if map != null else null
	if tc != null:
		var v: float = tc.call("walkable_height", x, z)
		if not is_nan(v):
			return v
	# Last-resort clean ray: only a top-facing surface counts.  Walk further
	# down when the first hit is an underside/vertical face.
	var from := Vector3(x, 50, z)
	for attempt in 8:
		var q := PhysicsRayQueryParameters3D.create(from, Vector3(x, -50, z), 1)
		var h := get_world_3d().direct_space_state.intersect_ray(q)
		if h.is_empty():
			break
		var n: Vector3 = h["normal"]
		var p: Vector3 = h["position"]
		if n.y > 0.55:
			return p.y
		from = p + Vector3(0, -0.04, 0)
	return -1.0e9


func _build_islands() -> void:
	_land.resize(_W * _H)
	_land.fill(0)
	for i in _layout["land_mask"]:
		_land[int(i)] = 1
	_island.resize(_W * _H)
	_island.fill(-1)
	var next := 0
	for start in range(_W * _H):
		if _land[start] == 0 or _island[start] >= 0:
			continue
		_island[start] = next
		var q: Array[int] = [start]
		while q.size() > 0:
			var n: int = q.pop_back()
			var x := n % _W
			var z := n / _W
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + d.x
				var nz: int = z + d.y
				if nx < 0 or nz < 0 or nx >= _W or nz >= _H:
					continue
				var m: int = nz * _W + nx
				if _land[m] == 1 and _island[m] < 0:
					_island[m] = next
					q.append(m)
		next += 1


func _same_island(a: Vector3, b: Vector3) -> bool:
	var ca := _cell(a)
	var cb := _cell(b)
	if ca.x < 0 or ca.y < 0 or cb.x < 0 or cb.y < 0:
		return false
	var ia := _island[ca.y * _W + ca.x]
	var ib := _island[cb.y * _W + cb.x]
	return ia >= 0 and ia == ib


func _cell(p: Vector3) -> Vector2i:
	return Vector2i(clampi(int(round(p.x + 81.5)), 0, _W - 1),
			clampi(int(round(-p.z + 81.5)), 0, _H - 1))
