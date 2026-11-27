extends Node3D
## Local soil caps for the 29 top-surface apertures (terrain GLB untouched).
##
## Each hole is covered by a shallow dish, not a flat lid:
##   * the dish top meets the terrain lip and covers the hole;
##   * a 0.15 m skirt runs outward and 0.15 m down under the real terrain lip,
##     so no cap edge is visible from a player angle;
##   * the mesh is subdivided at 0.25 m so the rim follows the local terrain;
##   * the material samples the same world-space lane albedo/mask as the
##     terrain path, with low-frequency compacted soil elsewhere.

const CAPS := "res://assets/terrain_void_caps.json"
const PATH_ALBEDO := "res://assets/textures/terrain_path_albedo.png"
const PATH_MASK := "res://assets/textures/terrain_path_mask.png"
const PATH_RECT := Vector4(-82.0, -82.0, 164.0, 164.0)
const OVERLAP := 0.15
## The cap top must sit at least this far below the terrain at its centroid.
const MIN_BELOW := 0.12
const SINK := 0.15
const EDGE_STEP := 0.25

# Height field over the rendered terrain top, used only to tuck the cap skirt
# under the real lip.  0.5 m is enough for a 0.6 m overlap.
const HG_HALF := 82.0
const HG_STEP := 0.5
const HG_N := 329

var verts := 0
var tris := 0
var cap_tri_counts: Array[int] = []
## Per-cap vertex start (3 vertices per triangle, caps are contiguous).
var cap_vert_starts: Array[int] = []
## Per-cap measured top protrusion after lowering, in metres (height field).
var cap_max_protrusion: Array[float] = []
var cap_top_below: Array[float] = []
var lane_caps := 0
var _heights: PackedFloat32Array
var _covered: PackedByteArray
var _cur_tris := 0


func build() -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CAPS))
	if d.is_empty() or not d.has("caps"):
		push_error("ApertureCaps: no caps data")
		return
	var terrain := get_parent().get_node_or_null("Terrain") as Node3D
	_build_height_field(terrain)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var made := 0
	for cap in d["caps"]:
		var raw: Array = cap.get("verts", [])
		if raw.size() < 3:
			continue
		var pts: Array = []
		for v in raw:
			pts.append(Vector2(float(v[0]), float(v[2])))
		var hull := _hull(pts)
		if hull.size() < 3:
			continue
		var ys: Array[float] = []
		for p in hull:
			ys.append(_nearest_y(p, raw))
		var c := Vector2.ZERO
		for p in hull:
			c += p
		c /= float(hull.size())
		var lane := _is_lane(c)
		if lane:
			lane_caps += 1
		var step := EDGE_STEP
		var inner := _subdiv(hull, ys, step)
		if inner.size() < 3:
			continue
		var outer := _outer_ring(inner, c)
		var top := -1e9
		for y in ys:
			top = maxf(top, y)
		var center := Vector3(c.x, top + 0.045, c.y)
		# Raycast straight down at the cap centroid. This is the local terrain
		# datum for this cap, never a global constant.
		var centroid_y := _ray_terrain_y(c.x, c.y)
		if is_nan(centroid_y):
			centroid_y = _terrain_height(c.x, c.y)
		if is_nan(centroid_y):
			var ymin := 1.0e20
			for y in ys:
				ymin = minf(ymin, y)
			centroid_y = ymin
		# Start with the centroid rule: top at least 0.12 m below the surface.
		var drop := (top + 0.045) - (centroid_y - MIN_BELOW)
		# Then check every existing cap vertex against the local height field and
		# lower further if any edge would still protrude. Per-cap, not global.
		var max_prot := center.y - centroid_y
		for p in inner:
			var pv: Vector3 = p
			var th := _terrain_height(pv.x, pv.z)
			if not is_nan(th):
				max_prot = maxf(max_prot, pv.y - th)
		for p in outer:
			var pv: Vector3 = p
			var th := _terrain_height(pv.x, pv.z)
			if not is_nan(th):
				max_prot = maxf(max_prot, pv.y - th)
		drop = maxf(drop, max_prot + MIN_BELOW)
		drop = maxf(drop, 0.0)
		for p in inner:
			p.y -= drop
		for p in outer:
			p.y -= drop
		center.y -= drop
		var top_after := center.y - 0.045
		cap_top_below.append(centroid_y - top_after)
		cap_vert_starts.append(tris * 3)
		_cur_tris = 0
		_cap_surface(st, center, inner, outer)
		cap_tri_counts.append(_cur_tris)
		# Build-time max protrusion against the same height field (final verify
		# re-checks every vertex with physics raycasts).
		var prot_after := -1.0e20
		for p in inner:
			var pv: Vector3 = p
			var th := _terrain_height(pv.x, pv.z)
			if not is_nan(th):
				prot_after = maxf(prot_after, pv.y - th)
		for p in outer:
			var pv: Vector3 = p
			var th := _terrain_height(pv.x, pv.z)
			if not is_nan(th):
				prot_after = maxf(prot_after, pv.y - th)
		cap_max_protrusion.append(prot_after)
		made += 1
	var mesh := st.commit()
	if mesh == null:
		return
	# Final safety pass: the 0.5 m height field can smooth across a 1 m terrain
	# triangle and miss a lip by a few centimetres. Re-check every cap vertex
	# with a real downward physics ray and lower that whole cap until every
	# vertex is at least 2 cm below the actual collision surface.
	mesh.surface_set_material(0, _material())
	var mi := MeshInstance3D.new()
	mi.name = "ApertureCaps"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	# Physics raycasts are not valid until TerrainCollision has been through a
	# physics step. Defer the final per-vertex pass by two physics frames.
	_deferred_ray_lower.call_deferred(mi)
	var arrays := mesh.surface_get_arrays(0)
	verts = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var ia = arrays[Mesh.ARRAY_INDEX]
	tris = ia.size() / 3 if ia != null else verts / 3
	print("aperture caps: %d caps, %d lane caps, %d verts, %d tris" % [
		made, lane_caps, verts, tris])
	print("aperture caps per-cap tris: " + JSON.stringify(cap_tri_counts))


func _deferred_ray_lower(mi: MeshInstance3D) -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	var lowered := _ray_lower_caps(mi.mesh as ArrayMesh)
	if lowered == null:
		return
	lowered.surface_set_material(0, _material())
	mi.mesh = lowered
	var arrays := lowered.surface_get_arrays(0)
	var vv := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	print("aperture caps ray-lowered: verts=%d worst=%.4f" % [
		vv.size(), cap_max_protrusion.max() if not cap_max_protrusion.is_empty() else 0.0])


func _ray_lower_caps(mesh: ArrayMesh) -> ArrayMesh:
	var arrays := mesh.surface_get_arrays(0)
	var vv := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var space := get_world_3d().direct_space_state
	var changed := false
	for i in cap_vert_starts.size():
		var v0 := cap_vert_starts[i]
		var n := cap_tri_counts[i] * 3
		var maxp := -1.0e20
		for k in range(v0, mini(v0 + n, vv.size())):
			var v := vv[k]
			var q := PhysicsRayQueryParameters3D.create(
				Vector3(v.x, 250.0, v.z), Vector3(v.x, -80.0, v.z), 1)
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			maxp = maxf(maxp, v.y - (hit["position"] as Vector3).y)
		if maxp <= -0.02:
			cap_max_protrusion[i] = maxp
			continue
		var drop := maxp + 0.02
		for k in range(v0, mini(v0 + n, vv.size())):
			vv[k].y -= drop
		cap_max_protrusion[i] = maxp - drop
		cap_top_below[i] += drop
		changed = true
	if not changed:
		return mesh
	arrays[Mesh.ARRAY_VERTEX] = vv
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = out
	return mesh


func _cap_surface(st: SurfaceTool, center: Vector3, inner: Array,
		outer: Array) -> void:
	var radius := 0.0
	for p in inner:
		var pv: Vector3 = p
		radius = maxf(radius, Vector2(pv.x - center.x, pv.z - center.z).length())
	var steps := clampi(int(ceil(radius / EDGE_STEP)), 1, 40)
	var rings: Array = []
	for r in range(1, steps + 1):
		var t := float(r) / float(steps)
		var ring: Array = []
		for p in inner:
			var pv: Vector3 = p
			ring.append(Vector3(
				lerpf(center.x, pv.x, t),
				lerpf(center.y, pv.y, t),
				lerpf(center.z, pv.z, t)))
		rings.append(ring)

	# Centre fan.  The centre is only 3 cm above the rim, so the dish is shallow.
	var first: Array = rings[0]
	for i in first.size():
		var f0: Vector3 = first[i]
		var f1: Vector3 = first[(i + 1) % first.size()]
		_tri(st, center, f0, f1)
	for r in range(1, rings.size()):
		var a: Array = rings[r - 1]
		var b: Array = rings[r]
		for i in a.size():
			var n := (i + 1) % a.size()
			var a0: Vector3 = a[i]
			var a1: Vector3 = a[n]
			var b0: Vector3 = b[i]
			var b1: Vector3 = b[n]
			_tri(st, a0, b0, b1)
			_tri(st, a0, b1, a1)

	# Tuck the rim under the terrain lip: outward 0.15 m, down 0.15 m.
	var rim: Array = rings[rings.size() - 1]
	for i in rim.size():
		var n := (i + 1) % rim.size()
		var r0: Vector3 = rim[i]
		var r1: Vector3 = rim[n]
		var o0: Vector3 = outer[i]
		var o1: Vector3 = outer[n]
		_tri(st, r0, o0, o1)
		_tri(st, r0, o1, r1)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	if (b - a).cross(c - a).length() < 1.0e-8:
		return
	st.set_normal(Vector3.UP)
	st.add_vertex(a)
	st.set_normal(Vector3.UP)
	st.add_vertex(b)
	st.set_normal(Vector3.UP)
	st.add_vertex(c)
	tris += 1
	_cur_tris += 1


func _subdiv(hull: Array, ys: Array[float], step: float) -> Array:
	var out: Array = []
	for i in hull.size():
		var a: Vector2 = hull[i]
		var b: Vector2 = hull[(i + 1) % hull.size()]
		var ya := ys[i]
		var yb := ys[(i + 1) % hull.size()]
		var n := maxi(1, int(ceil(a.distance_to(b) / step)))
		for k in n:
			var t := float(k) / float(n)
			var p := a.lerp(b, t)
			out.append(Vector3(p.x, lerpf(ya, yb, t) - 0.045, p.y))
	return out


func _outer_ring(inner: Array, c: Vector2) -> Array:
	var out: Array = []
	for p in inner:
		var pv: Vector3 = p
		var dir := Vector2(pv.x - c.x, pv.z - c.y)
		if dir.length() < 0.02:
			dir = Vector2(1.0, 0.0)
		var o := Vector2(pv.x, pv.z) + dir.normalized() * OVERLAP
		var th := _terrain_height(o.x, o.y)
		var oy: float = pv.y - SINK
		if not is_nan(th):
			oy = minf(th - SINK, pv.y - 0.02)
		out.append(Vector3(o.x, oy, o.y))
	return out


func _nearest_y(p: Vector2, raw: Array) -> float:
	var best := 1.0e20
	var y := 0.0
	for v in raw:
		var dx := float(v[0]) - p.x
		var dz := float(v[2]) - p.y
		var d := dx * dx + dz * dz
		if d < best:
			best = d
			y = float(v[1])
	return y


func _is_lane(c: Vector2) -> bool:
	return c.x > -7.5 and c.x < 2.5 and c.y > 9.0 and c.y < 38.0


func _material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/ground_earth.gdshader")
	m.set_shader_parameter("path_albedo", load(PATH_ALBEDO))
	m.set_shader_parameter("path_mask", load(PATH_MASK))
	m.set_shader_parameter("path_rect", PATH_RECT)
	m.set_shader_parameter("path_strength", 1.0)
	return m


# ---------------------------------------------------------------- height field

func _build_height_field(terrain: Node3D) -> void:
	_heights = PackedFloat32Array()
	_heights.resize(HG_N * HG_N)
	_heights.fill(-1.0e20)
	_covered = PackedByteArray()
	_covered.resize(HG_N * HG_N)
	_covered.fill(0)
	if terrain == null:
		return
	for node in terrain.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := mi.global_transform
		for s in range(mi.mesh.get_surface_count()):
			var arrays := mi.mesh.surface_get_arrays(s)
			if arrays.is_empty():
				continue
			var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx = arrays[Mesh.ARRAY_INDEX]
			if idx == null or idx.size() == 0:
				for k in range(0, vs.size() - 2, 3):
					_raster_tri(xf * vs[k], xf * vs[k + 1], xf * vs[k + 2])
			else:
				for k in range(0, idx.size() - 2, 3):
					_raster_tri(xf * vs[idx[k]], xf * vs[idx[k + 1]],
							xf * vs[idx[k + 2]])
	for pass_i in range(3):
		var added := 0
		for j in range(1, HG_N - 1):
			for i in range(1, HG_N - 1):
				var n := j * HG_N + i
				if _covered[n] == 1:
					continue
				var sum := 0.0
				var cnt := 0
				for o: int in [-1, 1, -HG_N, HG_N]:
					var m := n + o
					if _covered[m] == 1:
						sum += _heights[m]
						cnt += 1
				if cnt > 0:
					_heights[n] = sum / float(cnt)
					_covered[n] = 2
					added += 1
		if added == 0:
			break


func _raster_tri(a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if absf(n.normalized().y) < 0.18:
		return
	var minx := minf(a.x, minf(b.x, c.x))
	var maxx := maxf(a.x, maxf(b.x, c.x))
	var minz := minf(a.z, minf(b.z, c.z))
	var maxz := maxf(a.z, maxf(b.z, c.z))
	var i0 := clampi(int(floor((minx + HG_HALF) / HG_STEP)), 0, HG_N - 1)
	var i1 := clampi(int(ceil((maxx + HG_HALF) / HG_STEP)), 0, HG_N - 1)
	var j0 := clampi(int(floor((minz + HG_HALF) / HG_STEP)), 0, HG_N - 1)
	var j1 := clampi(int(ceil((maxz + HG_HALF) / HG_STEP)), 0, HG_N - 1)
	if i1 < i0 or j1 < j0:
		return
	var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(d) < 1.0e-9:
		return
	var inv := 1.0 / d
	for j in range(j0, j1 + 1):
		var pz := -HG_HALF + float(j) * HG_STEP
		for i in range(i0, i1 + 1):
			var px := -HG_HALF + float(i) * HG_STEP
			var u := ((b.z - c.z) * (px - c.x) + (c.x - b.x) * (pz - c.z)) * inv
			if u < -0.001 or u > 1.001:
				continue
			var v := ((c.z - a.z) * (px - c.x) + (a.x - c.x) * (pz - c.z)) * inv
			if v < -0.001 or v > 1.001:
				continue
			var w := 1.0 - u - v
			if w < -0.001 or w > 1.001:
				continue
			var h := u * a.y + v * b.y + w * c.y
			var k := j * HG_N + i
			if _covered[k] == 0 or h > _heights[k]:
				_heights[k] = h
				_covered[k] = 1


func _ray_terrain_y(x: float, z: float) -> float:
	# Physics raycast against TerrainCollision's heightmap. Returns NAN at a
	# genuine hole (where there is no top surface to hide under).
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		Vector3(x, 250.0, z), Vector3(x, -80.0, z), 1)
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return NAN
	return (hit["position"] as Vector3).y


func _terrain_height(x: float, z: float) -> float:
	if _heights.is_empty():
		return NAN
	var gx := clampf((x + HG_HALF) / HG_STEP, 0.0, float(HG_N - 1))
	var gz := clampf((z + HG_HALF) / HG_STEP, 0.0, float(HG_N - 1))
	var i0 := clampi(int(floor(gx)), 0, HG_N - 2)
	var j0 := clampi(int(floor(gz)), 0, HG_N - 2)
	var tx := gx - float(i0)
	var tz := gz - float(j0)
	var n00 := j0 * HG_N + i0
	var sum := 0.0
	var wsum := 0.0
	for e in [[n00, (1.0 - tx) * (1.0 - tz)], [n00 + 1, tx * (1.0 - tz)],
			[n00 + HG_N, (1.0 - tx) * tz], [n00 + HG_N + 1, tx * tz]]:
		if _covered[e[0]] != 0:
			sum += _heights[e[0]] * float(e[1])
			wsum += float(e[1])
	if wsum <= 0.0:
		return NAN
	return sum / wsum


# ---------------------------------------------------------------- polygon

func _hull(points: Array) -> Array:
	var pts := points.duplicate()
	pts.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and a.y < b.y))
	var lower: Array = []
	for p in pts:
		while lower.size() >= 2 and _cross(lower[-2], lower[-1], p) <= 0.0:
			lower.pop_back()
		lower.append(p)
	var upper: Array = []
	for i in range(pts.size() - 1, -1, -1):
		var p: Vector2 = pts[i]
		while upper.size() >= 2 and _cross(upper[-2], upper[-1], p) <= 0.0:
			upper.pop_back()
		upper.append(p)
	lower.pop_back()
	upper.pop_back()
	return lower + upper


func _cross(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
