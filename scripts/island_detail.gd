extends RefCounted
## Clustered detail for the thin outer islands.  Nothing here is scattered:
## each outcrop, fern shelf, driftwood landing and ruin run is one deliberate
## cluster keyed to a cliff lip, a POI approach or an empty plateau.
##
## Placement rules:
##   * terrain raycast, then the instance is seated by its own lowest vertex
##     (same rule as the village props), so clearance is ~0.001 m;
##   * solid collision only for boulders >= 1.15 scale and ruin slabs;
##   * every solid is rejected within 1.0 m of the navmesh, every decorative
##     item within 0.45 m, and everything is rejected within 1.2 m of a
##     POI-to-village route;
##   * no POI is touched and nothing lands inside a POI footprint.

const S := 1.6979
const CELL := 81.5
const SPAWN_GATE := Vector3(-2.0, 0.0, 26.0)

## id, whether it has POIs (drives the fern shelves), whether it gets a wall.
const TARGETS := [
	{"id": 1, "pois": 0, "wall": false},
	{"id": 2, "pois": 0, "wall": false},
	{"id": 10, "pois": 0, "wall": false},
	{"id": 17, "pois": 0, "wall": false},
	{"id": 18, "pois": 0, "wall": false},
	{"id": 6, "pois": 1, "wall": false},
	{"id": 8, "pois": 1, "wall": false},
	{"id": 7, "pois": 0, "wall": false},
	{"id": 5, "pois": 0, "wall": false},
	{"id": 3, "pois": 0, "wall": true},
	{"id": 4, "pois": 0, "wall": true},
	{"id": 11, "pois": 0, "wall": false},
	{"id": 12, "pois": 0, "wall": false},
	{"id": 13, "pois": 0, "wall": false},
	{"id": 15, "pois": 0, "wall": false},
	{"id": 16, "pois": 0, "wall": false},
]

var map: Node3D
var nav: Node
var layout: Dictionary
var poi_centers: Array[Vector3] = []
var routes: Array[PackedVector3Array] = []
var added := 0
var solids := 0
var per_island := {}

func build(p_map: Node3D, p_nav: Node) -> Dictionary:
	map = p_map
	nav = p_nav
	layout = JSON.parse_string(FileAccess.get_file_as_string("res://map_layout.json"))
	for c in map.find_children("Prop_POI_*", "Node3D", true, false):
		poi_centers.append((c as Node3D).global_position)
	for p in poi_centers:
		var path: PackedVector3Array = nav.call("path", SPAWN_GATE, p)
		if path.size() >= 2:
			routes.append(path)
	var by_id := {}
	for i in layout["islands"]:
		by_id[int(i["id"])] = i
	for t in TARGETS:
		var isl: Dictionary = by_id[int(t["id"])]
		var b: Array = isl["bbox"]
		var cx := (float(b[0]) + float(b[2])) * 0.5
		var cz := (float(b[1]) + float(b[3])) * 0.5
		var c := Vector3((cx - CELL) * S, 0.0, -(cz - CELL) * S)
		var rx := (float(b[2]) - float(b[0])) * S * 0.5
		var rz := (float(b[3]) - float(b[1])) * S * 0.5
		var before := added
		_outcrops(c, rx, rz, 2)
		_driftwood(c, rx, rz)
		if int(t["pois"]) > 0:
			_poi_shelves(c, rx, rz)
		else:
			_fern_fields(c, rx, rz, 3)
		if bool(t["wall"]):
			_low_wall(c, rx, rz)
		if int(t["id"]) == 2 or bool(t["wall"]):
			_plateau_detail(c)
		per_island[int(t["id"])] = added - before
	_pond_shore()
	print("ISLAND_DETAIL added=%d solids=%d per_island=%s" % [added, solids, str(per_island)])
	return {"added": added, "solids": solids, "per_island": per_island}

# ---------------------------------------------------------------- helpers

func _ground(x: float, z: float) -> float:
	# Use the collision heightfield the player and floaters audit actually
	# walk on; a raw terrain ray can differ by ~0.15 m on a steep lip.
	var tc := map.get_node_or_null("TerrainCollision")
	if tc != null:
		var wy := float(tc.call("walkable_height", x, z))
		if not is_nan(wy) and wy > -50.0:
			return wy
	return float(map.call("_terrain_y", x, z))

func _near_route(p: Vector3) -> bool:
	for path in routes:
		for i in range(path.size() - 1):
			var a := Vector2(path[i].x, path[i].z)
			var b := Vector2(path[i + 1].x, path[i + 1].z)
			var q := Vector2(p.x, p.z)
			var ab := b - a
			var t := clampf((q - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
			if q.distance_to(a + ab * t) < 1.2:
				return true
	return false

func _near_poi(p: Vector3) -> bool:
	for q in poi_centers:
		if Vector2(p.x - q.x, p.z - q.z).length() < 2.6:
			return true
	return false

func _ok(p: Vector3, solid: bool) -> bool:
	var y := _ground(p.x, p.z)
	if y < -2.0 or y > 40.0:
		return false
	if _near_poi(p) or _near_route(p):
		return false
	var near: Vector3 = nav.call("closest", p)
	var d := Vector2(near.x - p.x, near.z - p.z).length()
	if d < (1.0 if solid else 0.45):
		return false
	return true

func _place(model: String, p: Vector3, yaw: float, scl: float, solid: bool,
		palette: bool = false, tint := Color.WHITE) -> Node3D:
	if not _ok(p, solid):
		return null
	var gy := _ground(p.x, p.z)
	var inst: Node3D = map.call("_spawn", model, Vector3(p.x, gy, p.z), yaw, scl)
	if inst == null:
		return null
	var low := float(map.call("_lowest_world_mesh_y", inst))
	if low > 1.0e29:
		inst.queue_free()
		return null
	inst.position.y += gy - low + 0.001
	inst.name = "Detail_%03d_%s" % [added, model.get_file().replace(".glb", "")]
	if palette:
		load("res://scripts/prop_surface.gd").apply_village(inst, model)
	if solid:
		map.call("_add_prop_collision", inst, model)
		solids += 1
	added += 1
	return inst

func _edge_point(c: Vector3, rx: float, rz: float, ang: float) -> Vector3:
	var prev := -999.0
	var last_ok := Vector3.ZERO
	for t in range(42, 101, 2):
		var f := float(t) / 100.0
		var p := Vector3(c.x + cos(ang) * rx * f, 0.0, c.z + sin(ang) * rz * f)
		var y := _ground(p.x, p.z)
		if y < -2.0:
			return last_ok
		p.y = y
		last_ok = p
		if prev > -900.0 and prev - y > 1.0:
			return p
		prev = y
	return last_ok

# ---------------------------------------------------------------- clusters

func _outcrops(c: Vector3, rx: float, rz: float, count: int) -> void:
	for k in count:
		var ang := 0.55 + TAU * float(k) / float(count) + 0.31
		var e := _edge_point(c, rx, rz, ang)
		if e == Vector3.ZERO:
			continue
		var inward := Vector3(c.x - e.x, 0.0, c.z - e.z).normalized()
		var base := e + inward * 0.7
		# three stones, one larger; the biggest one is the only solid
		for j in 3:
			var off := Vector3(cos(ang + 1.7 + j * 2.1), 0.0, sin(ang + 1.7 + j * 2.1)) * (0.25 + 0.22 * j)
			var s := 1.25 - 0.18 * j
			_place("rocks/boulder_s", base + off, ang + j, s, s >= 1.15, true)
		# tufts where the stone meets grass
		for j in 2:
			var off := Vector3(cos(ang + 0.6 + j * 2.8), 0.0, sin(ang + 0.6 + j * 2.8)) * (0.55 + 0.2 * j)
			_place("plants/fern_teal_s", base + off, ang * 1.7 + j, 0.72 + 0.08 * j, false)
		# pebble spill along the lip
		for j in 2:
			var off := inward * (0.15 + 0.35 * j) + Vector3(cos(ang + j * 2.2), 0.0, sin(ang + j * 2.2)) * 0.28
			_place("rocks/boulder_s", e + off, ang + j * 1.3, 0.20, false, true)
		# grass sprigs soften the contact line
		_place("plants/grass_sprig", base + Vector3(cos(ang + 4.0), 0.0, sin(ang + 4.0)) * 0.7, ang, 0.9, false)

func _driftwood(c: Vector3, rx: float, rz: float) -> void:
	var ang := 2.15
	var e := _edge_point(c, rx, rz, ang)
	if e == Vector3.ZERO:
		return
	var inward := Vector3(c.x - e.x, 0.0, c.z - e.z).normalized()
	var base := e + inward * 1.1
	# two planks read as beached driftwood, not a built walkway
	_place("connectivity/walkway_plank", base + Vector3(0.0, 0, 0.0), ang + 0.42, 0.43, false, true)
	_place("connectivity/walkway_plank", base + Vector3(0.35, 0, 0.22), ang + 1.18, 0.36, false, true)
	# pebbles / small shore stones
	for j in 4:
		var off := Vector3(cos(ang + 0.9 + j * 1.55), 0.0, sin(ang + 0.9 + j * 1.55)) * (0.35 + 0.18 * j)
		_place("rocks/boulder_s", e + inward * 0.55 + off, ang + j, 0.16 + 0.03 * j, false, true)
	_place("plants/reed_agave", base + inward * 0.3, ang, 0.55, false)

func _poi_shelves(c: Vector3, rx: float, rz: float) -> void:
	for q in poi_centers:
		# Only this island's POIs: an ellipse test, not every POI in the map.
		if absf((q.x - c.x) / maxf(rx, 0.1)) > 0.86 or absf((q.z - c.z) / maxf(rz, 0.1)) > 0.86:
			continue
		var placed := 0
		# Keep the shelf off the centre and the approach; walk around the POI.
		for k in 8:
			var ang := float(k) * TAU / 8.0 + 0.4
			var p := q + Vector3(cos(ang), 0.0, sin(ang)) * (3.2 + 0.5 * float(k % 2))
			if not _ok(p, false):
				continue
			for j in 3:
				var off := Vector3(cos(ang + j * 2.1), 0.0, sin(ang + j * 2.1)) * (0.4 + 0.2 * j)
				_place("plants/fern_teal_m" if j == 0 else "plants/fern_teal_s",
						p + off, ang + j, 0.78 + 0.06 * j, false)
			_place("plants/grass_sprig", p + Vector3(0.3, 0, -0.2), ang, 1.0, false)
			_place("rocks/boulder_s", p + Vector3(-0.7, 0, 0.5), ang, 0.45, false, true)
			placed += 1
			break

func _fern_fields(c: Vector3, rx: float, rz: float, count: int) -> void:
	for k in count:
		var ang := 1.1 + TAU * float(k) / float(count)
		var p := Vector3(c.x + cos(ang) * rx * 0.62, 0.0, c.z + sin(ang) * rz * 0.62)
		if not _ok(p, false):
			continue
		for j in 3:
			var off := Vector3(cos(ang + j * 2.0), 0.0, sin(ang + j * 2.0)) * (0.35 + 0.22 * j)
			_place("plants/fern_teal_s", p + off, ang + j, 0.68 + 0.05 * j, false)
		_place("plants/grass_spiky", p + Vector3(-0.5, 0, 0.25), ang, 0.8, false)
		_place("rocks/boulder_s", p + Vector3(0.6, 0, -0.4), ang, 0.32, false, true)

func _plateau_detail(c: Vector3) -> void:
	# Two small mid-plateau clusters: a broken slab, rubble, ferns and pebbles.
	for k in 2:
		var p := c + Vector3(cos(1.2 + k * 3.1), 0.0, sin(1.2 + k * 3.1)) * 6.0
		if not _ok(p, true):
			continue
		for j in 2:
			_place("ruins/slab_mossy_s", p + Vector3(j * 0.7, 0, 0), 1.1 + j, 0.55, true, true)
		_place("ruins/rubble_m", p + Vector3(-0.8, 0, 0.5), 0.7, 0.55, false, true)
		for j in 3:
			_place("plants/fern_teal_s", p + Vector3(cos(j * 2.1), 0, sin(j * 2.1)) * 1.1, j, 0.7, false)
		_place("plants/grass_sprig", p + Vector3(0.3, 0, -0.6), 0.3, 0.8, false)
		_place("rocks/boulder_s", p + Vector3(0.8, 0, 0.2), 0.2, 0.32, false, true)

func _pond_shore() -> void:
	# Reeds/pebbles follow the emitted pond contour, not a guessed ellipse, so
	# they sit on the actual waterline and the shore ribbon has no gap.
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/water_ponds.json"))
	if d.is_empty() or not d.has("ponds"):
		return
	for pond in d["ponds"]:
		if int(pond.get("pond", -1)) != 6:
			continue
		var P: Array = pond.get("P", [])
		if P.size() < 8:
			return
		var step := maxi(1, int(P.size() / 22))
		for i in range(0, P.size(), step):
			var q: Array = P[i]
			var qn: Array = P[(i + min(step, P.size() - 1)) % P.size()]
			var p := Vector3(float(q[0]), 0.0, -float(q[1]))
			var out := Vector3(float(qn[0]) - p.x, 0.0, -float(qn[1]) - p.z).normalized()
			var bank := p + out.cross(Vector3.UP).normalized() * 0.55
			if not _ok(bank, false):
				continue
			_place("plants/reed_agave", bank, float(i) * 0.37, 0.55, false)
			if i % (step * 3) == 0:
				_place("rocks/boulder_s", bank + Vector3(0.35, 0, 0.2), float(i), 0.22, false, true)

func _low_wall(c: Vector3, rx: float, rz: float) -> void:
	# A short run of fallen slabs on the empty plateaus, plus rubble.
	for attempt in 6:
		var ang := 2.7 + float(attempt) * 0.61
		var p := Vector3(c.x + cos(ang) * rx * 0.36, 0.0, c.z + sin(ang) * rz * 0.36)
		if not _ok(p, true):
			continue
		var yaw := ang + 0.2
		for j in 3:
			var off := Vector3(cos(yaw + PI * 0.5), 0.0, sin(yaw + PI * 0.5)) * (1.25 * float(j) - 1.25)
			_place("ruins/slab_mossy_l", p + off, yaw, 0.72, true, true)
		for j in 2:
			var off := Vector3(cos(yaw + 1.1 + j * 0.9), 0.0, sin(yaw + 1.1 + j * 0.9)) * (1.2 + 0.4 * j)
			_place("ruins/rubble_m", p + off, yaw + j, 0.62, false, true)
		return
