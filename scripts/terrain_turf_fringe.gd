extends MeshInstance3D
class_name TerrainTurfFringe
## Decorative turf/rock shelf outside the authored walkable edge.
##
## The collision mesh, navmesh and Terrain top are untouched.  This mesh only
## occupies the strip from the exact authored rim to a smoothed, low-frequency
## outer curve, so the silhouette reads organic instead of a cell staircase.

const LAYOUT := "res://map_layout.json"
const GRID := 163.0
const HALF := GRID * 0.5


func _ready() -> void:
	build()


func build() -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	if d.is_empty():
		return
	var land := {}
	for i in d["land_mask"]:
		land[int(i)] = true
	var map := get_parent()
	if map != null and String(map.name) == "TerrainUnderside":
		map = map.get_parent()
	var rock_mat: Material = null
	var under: MeshInstance3D = null
	if map != null:
		under = map.get_node_or_null("TerrainUnderside") as MeshInstance3D
	if under != null:
		rock_mat = under.material_override
	var grass_mat: Material = null
	var tnode := map.get_node_or_null("Terrain") if map != null else null
	if tnode != null:
		for n in tnode.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
				grass_mat = mi.get_surface_override_material(0)
				if grass_mat == null:
					grass_mat = mi.mesh.surface_get_material(0)
				break
	if grass_mat == null:
		push_warning("turf fringe: no grass material")
		return
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var turf_idx := PackedInt32Array()
	var rock_idx := PackedInt32Array()
	var water := {}
	for i in d.get("water_mask", []):
		water[int(i)] = true
	var covered: Array = []
	for loop in _turf_loops(water):
		if loop.size() < 5:
			continue
		_build_island(loop, verts, norms, turf_idx, rock_idx)
		var aa := 0.0
		for ii in loop.size():
			var p0: Vector2 = loop[ii]
			var p1: Vector2 = loop[(ii + 1) % loop.size()]
			aa += p0.x * p1.y - p1.x * p0.y
		if absf(aa) > 500.0:
			covered.append(loop)
	# A few turf boundaries are open chains at waterfalls/apertures and cannot
	# be offset.  Cover only components that no turf loop reaches, using the
	# land-mask rim pushed further out so it clears the visible turf.
	var fallback := 0
	for comp in _components(land):
		var cc := Vector2.ZERO
		for i in comp:
			var cx: int = int(i) % int(GRID)
			var cy: int = int(i) / int(GRID)
			cc += Vector2(float(cx) - HALF, -(float(cy) - HALF))
		cc /= float(comp.size())
		var near := false
		for q in covered:
			if _point_in_loop(cc, q):
				near = true
				break
		if near:
			continue
		var loop: Array = _component_outer_loop(comp)
		if loop.size() >= 5:
			_build_island(loop, verts, norms, turf_idx, rock_idx, 4.0)
			fallback += 1
	print("TURF_FALLBACK %d" % fallback)

	if turf_idx.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	var am := ArrayMesh.new()
	arrays[Mesh.ARRAY_INDEX] = turf_idx
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(0, grass_mat)
	arrays[Mesh.ARRAY_INDEX] = rock_idx
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(1, rock_mat)
	mesh = am
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	print("TURF_FRINGE verts=%d turf_tris=%d rock_tris=%d islands=%d" % [
		verts.size(), turf_idx.size() / 3, rock_idx.size() / 3, _islands])


var _islands := 0


func _build_island(loop: Array, verts: PackedVector3Array,
		norms: PackedVector3Array, turf_idx: PackedInt32Array,
		rock_idx: PackedInt32Array, widen: float = 0.0) -> void:
	# Work with a closed, duplicate-free loop.
	var src: Array = loop.duplicate()
	if src.size() > 1 and (src[0] as Vector2).distance_to(src[src.size() - 1]) < 0.01:
		src.pop_back()
	var nsrc: int = src.size()
	if nsrc < 5:
		return
	var c := Vector2.ZERO
	for p in src:
		c += p
	c /= float(nsrc)
	var area := 0.0
	for i in nsrc:
		var a: Vector2 = src[i]
		var b: Vector2 = src[(i + 1) % nsrc]
		area += a.x * b.y - b.x * a.y
	var ccw := area > 0.0
	# Resample the exact authored edge at ~0.65 m so the inner ring stays on
	# the collision/nav boundary but has enough vertices for a smooth outer.
	var seglen: Array[float] = []
	var total := 0.0
	for i in nsrc:
		var a: Vector2 = src[i]
		var b: Vector2 = src[(i + 1) % nsrc]
		var l := a.distance_to(b)
		seglen.append(l)
		total += l
	if total < 8.0:
		return
	var n := clampi(int(round(total / 0.65)), 48, 720)
	var inner: Array = []
	var si := 0
	var acc := 0.0
	for k in n:
		var target := total * float(k) / float(n)
		while si < nsrc - 1 and acc + seglen[si] < target:
			acc += seglen[si]
			si += 1
		var a: Vector2 = src[si]
		var b: Vector2 = src[(si + 1) % nsrc]
		var t := clampf((target - acc) / maxf(seglen[si], 0.0001), 0.0, 1.0)
		inner.append(a.lerp(b, t))
	# Smooth a copy for the outer curve.  Chaikin removes the 90-degree cell
	# steps; the offset then rides a 3/5/9-lobe low-frequency wave.
	var smooth: Array = inner.duplicate()
	for pass_i in 5:
		var out: Array = []
		for i in smooth.size():
			var p: Vector2 = smooth[i]
			var q: Vector2 = smooth[(i + 1) % smooth.size()]
			out.append(p * 0.72 + q * 0.28)
			out.append(p * 0.28 + q * 0.72)
		smooth = out
	var ns: int = smooth.size()
	var outer: Array = []
	var seed := _hash01(c)
	for i in ns:
		var p: Vector2 = smooth[i]
		var a: Vector2 = smooth[(i + ns - 1) % ns]
		var b: Vector2 = smooth[(i + 1) % ns]
		var tan := (b - a).normalized()
		var outn := Vector2(tan.y, -tan.x) if ccw else Vector2(-tan.y, tan.x)
		var ang := atan2(p.y - c.y, p.x - c.x)
		# The land-mask rim sits inside the visible turf mesh by roughly a
		# metre, so the visible overhang is this offset minus that inset.
		var d := 1.55 + widen
		d += 0.50 * sin(ang * 3.0 + seed * 6.2831853)
		d += 0.28 * sin(ang * 5.0 - seed * 4.1 + 1.3)
		d += 0.14 * sin(ang * 9.0 + seed * 9.7 + 0.7)
		d += 0.06 * sin(ang * 13.0 + seed * 2.3)
		d = clampf(d, 0.50 + widen, 2.00 + widen)
		outer.append(p + outn * d)
	# Sample inner y from the same rim function used by the keel, then let the
	# turf band dip slightly and the rock face continue down under it.
	var ytop: Array[float] = []
	for p in inner:
		var q: Vector2 = p
		ytop.append(_rim_y(q.x, q.y, -0.15))
	# Keep the turf band almost level with the authored lip.  A deep dip here
	# hid the whole fringe below the top sheet from the 170 m camera.
	var ylo: Array[float] = []
	for i in ns:
		ylo.append(ytop[int(float(i) * float(n) / float(ns)) % n] + 0.005)
	# Pull the inner ring ~0.65 m inside the authored turf edge and lift it
	# 6 cm.  Both sides are the same grass material, so the old straight edge
	# is covered instead of leaving a visible seam next to the fringe.
	var i0 := verts.size()
	for i in n:
		var p: Vector2 = inner[i]
		var inward := (c - p).normalized() * 1.45
		var q := p + inward
		verts.append(Vector3(q.x, _rim_y(q.x, q.y, ytop[i]) + 0.080, q.y))
		norms.append(Vector3.UP)
	var i1 := verts.size()
	for i in ns:
		var p: Vector2 = outer[i]
		verts.append(Vector3(p.x, ylo[i], p.y))
		norms.append(Vector3.UP)
	# Re-map the outer ring to the inner ring count (both are periodic; nearest
	# arc position is enough because the curve is low-frequency).
	var map_o: Array[int] = []
	for i in n:
		map_o.append(int(round(float(i) * float(ns) / float(n))) % ns)
	for i in n:
		var j := (i + 1) % n
		var a := i0 + i
		var b := i0 + j
		var oa := i1 + map_o[i]
		var ob := i1 + map_o[j]
		turf_idx.append_array([a, b, ob, a, ob, oa])
	# Rock face: outer top ring down to a tapered under-ring, 2.0-3.5 m.
	# Use the same n-ring as the turf band; the cubic Chaikin copy is only an
	# interpolation scaffold for the curve, not extra draw geometry.
	var i2 := verts.size()
	for i in n:
		var p: Vector2 = outer[map_o[i]]
		var ang := atan2(p.y - c.y, p.x - c.x)
		var deep := 2.0 + 1.5 * (0.5 + 0.5 * sin(ang * 3.0 + seed * 5.0))
		verts.append(Vector3(p.x - (p.x - c.x) * 0.035,
			ylo[map_o[i]] - deep, p.y - (p.y - c.y) * 0.035))
		norms.append(Vector3.UP)
	for i in n:
		var j := (i + 1) % n
		var a := i1 + map_o[i]
		var b := i1 + map_o[j]
		var ua := i2 + i
		var ub := i2 + j
		rock_idx.append_array([a, b, ub, a, ub, ua])
	_islands += 1


func _turf_loops(water: Dictionary) -> Array:
	# The visible turf edge is the boundary of surface 0, not the land-mask
	# cell rectangle (the two differ by up to ~3 m on the big islands).
	var map := get_parent()
	if map != null and String(map.name) == "TerrainUnderside":
		map = map.get_parent()
	var tnode := map.get_node_or_null("Terrain") if map != null else null
	if tnode == null:
		return []
	var mi: MeshInstance3D = null
	for n in tnode.find_children("*", "MeshInstance3D", true, false):
		mi = n as MeshInstance3D
		if mi != null and mi.mesh != null:
			break
	if mi == null:
		return []
	var arr := mi.mesh.surface_get_arrays(0)
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var xf := mi.global_transform
	var edges := {}
	var ntri := idx.size() / 3
	for t in ntri:
		var a: Vector3 = xf * vs[idx[t * 3]]
		var b: Vector3 = xf * vs[idx[t * 3 + 1]]
		var c: Vector3 = xf * vs[idx[t * 3 + 2]]
		# Only the top sheet; the solidified side has a separate perimeter.
		if a.y < -1.2 or b.y < -1.2 or c.y < -1.2:
			continue
		var n := (b - a).cross(c - a)
		if absf(n.normalized().y) < 0.55:
			continue
		_add_edge(edges, a, b)
		_add_edge(edges, b, c)
		_add_edge(edges, c, a)
	var boundary_n := 0
	for k in edges.keys():
		if int((edges[k] as Array)[2]) == 1:
			boundary_n += 1
	print("TURF_EDGES all=%d boundary=%d" % [edges.size(), boundary_n])
	var next := {}
	for k in edges.keys():
		var e: Array = edges[k]
		if int(e[2]) == 1:
			next[_ptkey(Vector2((e[0] as Vector3).x, (e[0] as Vector3).z))] = e[1]
	# The dictionary above is keyed by start; follow one outgoing edge per
	# start point.  A boundary vertex generally has one.
	var out: Array = []
	var tried := 0
	var seen := {}
	for k in edges.keys():
		var e: Array = edges[k]
		if int(e[2]) != 1:
			continue
		var sk := _ptkey(Vector2((e[0] as Vector3).x, (e[0] as Vector3).z))
		if seen.has(sk):
			continue
		var pts: Array = []
		var cur: Vector3 = e[0]
		var guard := 0
		while true:
			var ck := _ptkey(Vector2(cur.x, cur.z))
			if seen.has(ck):
				break
			seen[ck] = true
			pts.append(Vector2(cur.x, cur.z))
			var nx: Variant = next.get(ck, null)
			if nx == null:
				break
			cur = nx as Vector3
			guard += 1
			if guard > 200000:
				break
		if pts.size() < 8:
			continue
		var gap := (pts[0] as Vector2).distance_to(pts[pts.size() - 1])
		if gap > 2.5:
			# Open chains are coast edges cut by a steep triangle or by the map
			# border.  Close them with an outward bulging arc rather than a
			# straight chord, so the fringe that follows is low-frequency and
			# not another straight cut.
			var a0: Vector2 = pts[0]
			var b0: Vector2 = pts[pts.size() - 1]
			var c0 := Vector2.ZERO
			for pp in pts:
				c0 += pp
			c0 /= float(pts.size())
			var dir := (b0 - a0).normalized()
			var nrm := Vector2(dir.y, -dir.x)
			if nrm.dot((a0 + b0) * 0.5 - c0) < 0.0:
				nrm = -nrm
			var steps := 10
			for j in range(1, steps):
				var t := float(j) / float(steps)
				var bulge := 2.2 + 0.5 * sin(t * 6.2831853 + float(pts.size()))
				pts.append(a0.lerp(b0, t) + nrm * sin(t * 3.14159265) * bulge)
			pts.append(b0)
		var area := 0.0
		var cx := 0.0
		var cz := 0.0
		for i in pts.size():
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[(i + 1) % pts.size()]
			area += a.x * b.y - b.x * a.y
			cx += a.x
			cz += a.y
		cx /= float(pts.size())
		cz /= float(pts.size())
		tried += 1
		if absf(area) < 60.0:
			continue
		if _is_water(water, cx, cz):
			continue
		out.append(pts)
	print("TURF_LOOPS tried=%d kept=%d" % [tried, out.size()])
	return out


func _add_edge(edges: Dictionary, a: Vector3, b: Vector3) -> void:
	var ka := _ptkey(Vector2(a.x, a.z))
	var kb := _ptkey(Vector2(b.x, b.z))
	if ka == kb:
		return
	var rev := kb + "|" + ka
	if edges.has(rev):
		var e: Array = edges[rev]
		e[2] = int(e[2]) + 1
		return
	edges[ka + "|" + kb] = [a, b, 1]


func _is_water(water: Dictionary, x: float, z: float) -> bool:
	var cx := int(floor(x + 81.5))
	var cy := int(floor(-z + 81.5))
	if cx < 0 or cy < 0 or cx >= 163 or cy >= 163:
		return true
	return water.has(cy * 163 + cx)


func _point_in_loop(p: Vector2, loop: Array) -> bool:
	var inside := false
	var n: int = loop.size()
	for i in n:
		var a: Vector2 = loop[i]
		var b: Vector2 = loop[(i + 1) % n]
		if ((a.y > p.y) != (b.y > p.y)):
			var x := (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
			if p.x < x:
				inside = not inside
	return inside


func _hash01(p: Vector2) -> float:
	return fposmod(sin(p.x * 12.9898 + p.y * 78.233) * 43758.5453, 1.0)


func _rim_y(x: float, z: float, fallback: float) -> float:
	var map := get_parent()
	if map != null and String(map.name) == "TerrainUnderside":
		map = map.get_parent()
	var terrain := map.get_node_or_null("Terrain") if map != null else null
	if terrain == null:
		return fallback
	var best := fallback
	var found := false
	for n in terrain.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var a := mi.mesh.surface_get_arrays(0)
		var vs: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		for v in vs:
			var wp: Vector3 = mi.global_transform * v
			if absf(wp.x - x) < 5.0 and absf(wp.z - z) < 5.0:
				best = maxf(best, wp.y)
				found = true
		break
	return minf(best, 1.55) if found else fallback


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
	return best


func _ptkey(p: Vector2) -> String:
	return "%d_%d" % [roundi(p.x * 1000.0), roundi(p.y * 1000.0)]
