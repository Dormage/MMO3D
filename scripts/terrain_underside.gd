extends MeshInstance3D
class_name TerrainUnderside
## Solid underside for the flying islands.
##
## The baked solidify copy in terrain.glb is not a closed shell: from below it
## leaves the island interiors open and its rim quads read as detached blades.
## This node adds one opaque soil/rock sheet per land cell under the island
## footprint, plus a short outer skirt. It does not touch terrain.glb, so the
## 734,480-triangle mesh and its topology invariants are unchanged.
##
## World mapping: map_layout.json was authored on a 163 x 163 grid, and the
## terrain GLB is mirrored in Z (map.gd negates layout Z for props/buildings).
##   x = cell_x - 81.5
##   z = -(cell_y - 81.5)

const LAYOUT := "res://map_layout.json"
const GRID := 163.0
const HALF := GRID * 0.5
## Bottom of the keel. Main island tops are around +4 m; this gives a
## 28-30 m deep solid body, within the 12-41 m solidify range.
const BOTTOM_Y := -25.0
const SKIRT_TOP_Y := -1.0
## Bottom ring shrinks toward each island centroid; this is the taper.
const TAPER := 0.68
const CAP_Y := -25.35

const ROCK := Color(0.235, 0.165, 0.115, 1.0)

var _mesh: ArrayMesh
var _top2: PackedInt32Array = PackedInt32Array()
var _top2_before_above := 0
var _top2_before_worst := -99.0
var _top2_after_above := 0
var _top2_after_worst := -99.0


func _ready() -> void:
	build()


func build() -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	if d.is_empty():
		push_error("TerrainUnderside: layout missing")
		return
	var land := {}
	for i in d["land_mask"]:
		land[int(i)] = true
	var center_of := _island_centers(land)
	var hgrid := _build_height_grid()
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	# One blunt, convex keel per island.  The bottom radius scales with the
	# island footprint; the upper third stays near-vertical, then the profile
	# curves inward to a broad flat cap instead of a stalactite point.
	var keel_no := 0
	for comp in _components(land):
		var loop: Array = _component_outer_loop(comp)
		if loop.size() < 4:
			continue
		# Keep the top row on the authored cell contour; smooth only below the
		# turf lip so the walkable edge does not move.
		var pts: Array = loop.duplicate()
		if pts.size() < 4:
			continue
		# A land mask with diagonal-only contacts can produce an open chain or
		# two chains that share a vertex.  Closing such a chain with %n throws
		# a single quad across the whole map: that was the huge vertical curtain.
		var p0: Vector2 = pts[0]
		var pn: Vector2 = pts[pts.size() - 1]
		if p0.distance_to(pn) > 2.5:
			continue
		var bad_edge := false
		for i in pts.size():
			var pa: Vector2 = pts[i]
			var pb: Vector2 = pts[(i + 1) % pts.size()]
			if pa.distance_to(pb) > 3.0:
				bad_edge = true
				break
		if bad_edge:
			continue
		var c := Vector2.ZERO
		for p in pts:
			c += p
		c /= float(pts.size())
		var n: int = pts.size()
		var hw := _halfwidth(pts)
		# Per-island silhouette.  h0 depth, h1 bottom width, h2 overhang,
		# h3 slope and lobe phase.  Adjacent islands no longer share a profile.
		var h0 := _hash01(c)
		var h1 := _hash01(c + Vector2(17.3, -9.1))
		var h2 := _hash01(c + Vector2(-4.7, 12.9))
		var h3 := _hash01(c + Vector2(8.2, 5.5))
		var top_y := 0.0
		for i in n:
			var a: Vector2 = pts[i]
			top_y += minf(_rim_y(hgrid, a.x, a.y, -0.15), 1.55)
		top_y /= float(n)
		# Mostly 5-18 m thick; the deepest ~27 m.  A 30 m wall on every island
		# was what still read as a slab despite the taper.
		var depth := lerpf(5.0, 18.0, h0) + 9.0 * pow(h0, 3.0)
		var bottom_y := top_y - depth
		# Some islands are broad and shallow, some are narrow hanging roots.
		var bottom_frac := lerpf(0.12, 0.36, h1)
		var base_r := clampf(bottom_frac * hw, 1.2, 8.5)
		var r_cap := base_r * lerpf(0.26, 0.54, h2)
		var overhang := lerpf(-0.55, 1.9, h2 * h2)
		var slope := lerpf(0.02, 0.22, h1)
		var stretch_x := lerpf(0.86, 1.14, h3)
		var stretch_z := lerpf(1.14, 0.86, h3)
		var lobe_phase := h0 * TAU
		# Immediate taper: the old profile held ~95% of the top width for half
		# the depth, which is why the side read as a vertical slab.
		var levels := [0.0, 0.06, 0.16, 0.30, 0.50, 0.75, 1.0]
		# Deep roots start tapering just under the lip; shallow wide islands
		# hold their lip longer.  This is the per-island "vertical vs 10-20 deg"
		# control, not a single shared profile.
		# Deep islands become hanging roots: taper immediately under a thin lip.
		# Shallow islands keep a near-vertical side for a metre or two.  This is
		# the main silhouette split the old shared profile was missing.
		var root_mode := smoothstep(0.42, 0.78, h0)
		var taper_start := lerpf(0.24, 0.0, root_mode)
		var taper_pow := lerpf(1.35, 0.34, root_mode)
		var rows: Array = []
		var top := PackedVector3Array()
		for i in n:
			var a: Vector2 = pts[i]
			top.append(Vector3(a.x, minf(_rim_y(hgrid, a.x, a.y, -0.15), 1.55), a.y))
		rows.append(top)
		for k in range(1, levels.size()):
			var t: float = levels[k]
			var row := PackedVector3Array()
			for i in n:
				var a: Vector2 = pts[i]
				var dx := (a.x - c.x) * stretch_x
				var dz := (a.y - c.y) * stretch_z
				var dist := sqrt(dx * dx + dz * dz)
				var ang := atan2(dz, dx)
				# Low-frequency horizontal displacement so the outline is not a
				# scaled copy of the cell contour at every height.
				var lobe := sin(ang * 3.0 + lobe_phase) * 0.105
				lobe += sin(ang * 5.0 - lobe_phase * 1.7) * 0.045
				lobe += sin(ang * 9.0 + lobe_phase * 2.3) * 0.018
				var tt := clampf((t - taper_start) / maxf(1.0 - taper_start, 0.05), 0.0, 1.0)
				var taper_bl := pow(tt, taper_pow)
				var rad := lerpf(dist * (1.0 - slope * t), base_r, taper_bl)
				var brim := overhang * (1.0 - smoothstep(0.0, 0.16, t))
				rad += brim
				rad *= 1.0 + lobe * (0.30 + 0.70 * t)
				# Irregular bottom edge: bottom rows wander by up to ~1.4 m.
				var yy := lerpf(top[i].y, bottom_y, t)
				yy += sin(ang * 5.0 + lobe_phase) * 1.25 * t * t
				row.append(Vector3(c.x + cos(ang) * rad * stretch_x,
						yy, c.y + sin(ang) * rad * stretch_z))
			rows.append(row)
		for k in range(rows.size() - 1):
			var ra: PackedVector3Array = rows[k]
			var rb: PackedVector3Array = rows[k + 1]
			for i in n:
				var start := verts.size()
				_quad(verts, idx, ra[i], ra[(i + 1) % n],
					rb[(i + 1) % n], rb[i])
				if k == 0:
					_top2.append_array(PackedInt32Array([start, start + 1, start + 2, start + 3]))
		var cap_ring := PackedVector3Array()
		for i in n:
			var pp: Vector2 = pts[i]
			var ang := atan2((pp.y - c.y) * stretch_z, (pp.x - c.x) * stretch_x)
			var rr := r_cap * (1.0 + sin(ang * 4.0 + lobe_phase) * 0.18)
			var cy := bottom_y + sin(ang * 3.0 - lobe_phase) * 0.9
			cap_ring.append(Vector3(c.x + cos(ang) * rr * stretch_x, cy,
				c.y + sin(ang) * rr * stretch_z))
		var last: PackedVector3Array = rows[rows.size() - 1]
		for i in n:
			_quad(verts, idx, last[i], last[(i + 1) % n],
				cap_ring[(i + 1) % n], cap_ring[i])
		var center_i := verts.size()
		verts.append(Vector3(c.x, bottom_y - 1.1, c.y))
		var ring_i := verts.size()
		for p in cap_ring:
			verts.append(p)
		for i in n:
			idx.append_array([center_i, ring_i + i, ring_i + (i + 1) % n])
		print("keel %d: c=(%.1f,%.1f) hw=%.1f deep=%.1f bottom_r=%.2f cap_r=%.2f brim=%.2f slope=%.2f" % [
			keel_no, c.x, c.y, hw, depth, base_r, r_cap, overhang, slope])
		keel_no += 1
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am
	_mesh = am
	var sh := load("res://shaders/terrain_underside.gdshader") as Shader
	var mat := ShaderMaterial.new()
	mat.shader = sh
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	print("terrain underside: %d verts, %d tris" % [
		verts.size(), idx.size() / 3])
	print("terrain underside top2 vertices: %d" % _top2.size())
	# Physics rays are invalid until TerrainCollision has stepped.
	# _deferred_clamp_top2.call_deferred()


func _deferred_clamp_top2() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	var arrays := _mesh.surface_get_arrays(0)
	var vv := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var space := get_world_3d().direct_space_state
	var before := _audit_indices(space, vv, _top2)
	_top2_before_above = before[0]
	_top2_before_worst = before[1]
	var changed := false
	# The first-ring clamp below only protected the rim quad strip.  A keel
	# face can still rise through the turf a little further down-slope, which
	# appeared as a hard black patch on the grass at (-27, 14).  Clamp every
	# near-top keel vertex, not just the rim strip.
	for i in vv.size():
		var v := vv[i]
		if v.y < -2.0:
			continue
		var q := PhysicsRayQueryParameters3D.create(
			Vector3(v.x, 250.0, v.z), Vector3(v.x, -80.0, v.z), 1)
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var limit := (hit["position"] as Vector3).y - 0.25
		# Over the void there is no heightfield, and a far-below hit would
		# yank the top row down into a 100 m vertical curtain.  Only clamp
		# against real walkable ground near the turf.
		if limit < -2.0:
			continue
		if v.y > limit:
			vv[i].y = limit
			changed = true
	if changed:
		arrays[Mesh.ARRAY_VERTEX] = vv
		var out := ArrayMesh.new()
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(0, material_override)
		_mesh = out
		mesh = out
	var after := _audit_indices(space, vv, _top2)
	_top2_after_above = after[0]
	_top2_after_worst = after[1]
	print("terrain underside top2 clamp: before_above=%d before_worst=%.4f after_above=%d after_worst=%.4f changed=%s" % [
		_top2_before_above, _top2_before_worst, _top2_after_above, _top2_after_worst, changed])


func _audit_indices(space: PhysicsDirectSpaceState3D, vv: PackedVector3Array,
		ids: PackedInt32Array) -> Array:
	var above := 0
	var worst := -99.0
	for i in ids:
		var v := vv[i]
		var q := PhysicsRayQueryParameters3D.create(
			Vector3(v.x, 250.0, v.z), Vector3(v.x, -80.0, v.z), 1)
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var d := v.y - (hit["position"] as Vector3).y
		worst = maxf(worst, d)
		if d > 0.0:
			above += 1
	return [above, worst]


func _build_height_grid() -> Dictionary:
	var out := {}
	var parent := get_parent()
	if parent == null:
		return out
	var terrain := parent.find_child("Terrain", true, false) as Node3D
	if terrain == null:
		return out
	for node in terrain.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in range(mini(5, mi.mesh.get_surface_count())):
			var a: Array = mi.mesh.surface_get_arrays(s)
			var vs: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			for v in vs:
				var wp: Vector3 = mi.global_transform * v
				var k := Vector2i(floori(wp.x / 2.0), floori(wp.z / 2.0))
				if not out.has(k):
					out[k] = []
				out[k].append(wp)
	return out


func _rim_y(hgrid: Dictionary, x: float, z: float, fallback: float) -> float:
	var k := Vector2i(floori(x / 2.0), floori(z / 2.0))
	var best := fallback
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			var key := k + Vector2i(dx, dz)
			if not hgrid.has(key):
				continue
			for v in hgrid[key]:
				if Vector2(v.x - x, v.z - z).length_squared() <= 2.5 * 2.5:
					best = maxf(best, v.y)
	return best + 0.02


func _components(land: Dictionary) -> Array:
	var seen := {}
	var out: Array = []
	var g := int(GRID)
	for start in land.keys():
		if seen.has(start):
			continue
		var stack: Array = [start]
		seen[start] = true
		var cells: Array = []
		while not stack.is_empty():
			var i: int = stack.pop_back()
			cells.append(i)
			var cx: int = i % g
			var cy: int = i / g
			for n in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var nx: int = cx + n[0]
				var ny: int = cy + n[1]
				if nx < 0 or ny < 0 or nx >= g or ny >= g:
					continue
				var j := ny * g + nx
				if land.has(j) and not seen.has(j):
					seen[j] = true
					stack.append(j)
		out.append(cells)
	return out


func _component_outer_loop(cells: Array) -> Array:
	# Trace every boundary loop of this 4-connected component and keep the
	# largest by absolute area.  Interior loops are ponds, not island rims.
	var cs := {}
	for i in cells:
		cs[int(i)] = true
	var edges := {}
	for i in cells:
		var cx: int = int(i) % int(GRID)
		var cy: int = int(i) / int(GRID)
		var x0 := float(cx) - HALF
		var x1 := x0 + 1.0
		var z0 := -(float(cy) - HALF)
		var z1 := z0 - 1.0
		if not cs.has((cy - 1) * int(GRID) + cx):
			edges[_ptkey(Vector2(x0, z0))] = Vector2(x1, z0)
		if not cs.has((cy + 1) * int(GRID) + cx):
			edges[_ptkey(Vector2(x1, z1))] = Vector2(x0, z1)
		if cx > 0 and not cs.has(cy * int(GRID) + cx - 1):
			edges[_ptkey(Vector2(x0, z1))] = Vector2(x0, z0)
		if cx + 1 < int(GRID) and not cs.has(cy * int(GRID) + cx + 1):
			edges[_ptkey(Vector2(x1, z0))] = Vector2(x1, z1)
	var best: Array = []
	var best_area := 0.0
	while not edges.is_empty():
		var sk: String = edges.keys()[0]
		var parts := sk.split("_")
		var start := Vector2(float(parts[0]) / 1000.0, float(parts[1]) / 1000.0)
		var pts: Array = [start]
		var cur := start
		var guard := 0
		while true:
			var k := _ptkey(cur)
			if not edges.has(k):
				break
			var nxt: Vector2 = edges[k]
			edges.erase(k)
			pts.append(nxt)
			cur = nxt
			guard += 1
			if cur == start or guard > 300000:
				break
		if pts.size() < 5:
			continue
		var area := 0.0
		for i in pts.size():
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[(i + 1) % pts.size()]
			area += a.x * b.y - b.x * a.y
		if absf(area) > best_area:
			best_area = absf(area)
			best = pts
	if best.size() >= 5 and best[0].distance_to(best[best.size() - 1]) < 2.5:
		return best
	return _hull_loop(cells)


func _hull_loop(cells: Array) -> Array:
	# Fallback for a component whose boundary trace is open (diagonal contacts
	# or a shared vertex).  The hull is intentionally a metre outside the turf
	# so it reads as an overhanging rock shelf, never as a floating cut.
	var pts: Array = []
	for i in cells:
		var cx: int = int(i) % int(GRID)
		var cy: int = int(i) / int(GRID)
		var x0 := float(cx) - HALF - 0.35
		var x1 := float(cx) + 0.5 - HALF + 0.35
		var z0 := -(float(cy) - HALF) + 0.35
		var z1 := -(float(cy) + 0.5 - HALF) - 0.35
		pts.append_array([Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)])
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


func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)


func _boundary_loops(cells: Dictionary) -> Array:
	var edges := {}
	for i in cells.keys():
		var cx: int = i % int(GRID)
		var cy: int = i / int(GRID)
		var x0 := float(cx) - HALF
		var x1 := x0 + 1.0
		var z0 := -(float(cy) - HALF)
		var z1 := z0 - 1.0
		if not cells.has((cy - 1) * int(GRID) + cx):
			edges[_ptkey(Vector2(x0, z0))] = Vector2(x1, z0)
		if not cells.has((cy + 1) * int(GRID) + cx):
			edges[_ptkey(Vector2(x1, z1))] = Vector2(x0, z1)
		if cx > 0 and not cells.has(cy * int(GRID) + cx - 1):
			edges[_ptkey(Vector2(x0, z1))] = Vector2(x0, z0)
		if cx + 1 < int(GRID) and not cells.has(cy * int(GRID) + cx + 1):
			edges[_ptkey(Vector2(x1, z0))] = Vector2(x1, z1)
	var loops: Array = []
	while not edges.is_empty():
		var sk: String = edges.keys()[0]
		var parts := sk.split("_")
		var start := Vector2(float(parts[0]) / 1000.0, float(parts[1]) / 1000.0)
		var pts: Array = [start]
		var cur := start
		var guard := 0
		while true:
			var k := _ptkey(cur)
			if not edges.has(k):
				break
			var nxt: Vector2 = edges[k]
			edges.erase(k)
			pts.append(nxt)
			cur = nxt
			guard += 1
			if cur == start or guard > 300000:
				break
		if pts.size() > 4:
			loops.append(pts)
	return loops


func _ptkey(p: Vector2) -> String:
	return "%d_%d" % [roundi(p.x * 1000.0), roundi(p.y * 1000.0)]


func _smooth(loop: Array, iterations: int) -> Array:
	var pts := loop.duplicate()
	for it in iterations:
		var out: Array = []
		var n: int = pts.size()
		for i in n:
			var p: Vector2 = pts[i]
			var q: Vector2 = pts[(i + 1) % n]
			out.append(p * 0.75 + q * 0.25)
			out.append(p * 0.25 + q * 0.75)
		pts = out
	return pts


func _halfwidth(pts: Array) -> float:
	var mn := Vector2(1e20, 1e20)
	var mx := Vector2(-1e20, -1e20)
	for p in pts:
		var q: Vector2 = p
		mn.x = minf(mn.x, q.x)
		mn.y = minf(mn.y, q.y)
		mx.x = maxf(mx.x, q.x)
		mx.y = maxf(mx.y, q.y)
	return 0.5 * maxf(mx.x - mn.x, mx.y - mn.y)


func _hash01(p: Vector2) -> float:
	return fposmod(sin(p.x * 12.9898 + p.y * 78.233) * 43758.5453, 1.0)


func _island_centers(land: Dictionary) -> Dictionary:
	var seen := {}
	var out := {}
	var g := int(GRID)
	for start in land.keys():
		if seen.has(start):
			continue
		var stack: Array = [start]
		seen[start] = true
		var cells: Array = []
		while not stack.is_empty():
			var i: int = stack.pop_back()
			cells.append(i)
			var cx: int = i % g
			var cy: int = i / g
			for n in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var nx: int = cx + n[0]
				var ny: int = cy + n[1]
				if nx < 0 or ny < 0 or nx >= g or ny >= g:
					continue
				var j := ny * g + nx
				if land.has(j) and not seen.has(j):
					seen[j] = true
					stack.append(j)
		var sx := 0.0
		var sy := 0.0
		for i in cells:
			sx += float(i % g)
			sy += float(i / g)
		var c := Vector3(
			sx / cells.size() - HALF,
			BOTTOM_Y,
			-(sy / cells.size() - HALF))
		for i in cells:
			out[i] = c
	return out


func _quad(v: PackedVector3Array, idx: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var i := v.size()
	v.append_array([a, b, c, d])
	idx.append_array([i, i + 1, i + 2, i, i + 2, i + 3])
