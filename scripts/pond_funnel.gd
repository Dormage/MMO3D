extends Node3D
## Pond funnel collars built from the real water-mask shoreline contour.
##
## The first attempt chained raw terrain boundary edges, but non-manifold
## branches split the loop and left the left shelf exposed. This version takes
## the actual water-mask polygon, dilates it to the outer hole rim, smooths the
## contour with Chaikin, samples the terrain rim height at every contour point,
## and extrudes three inward/downward rings ending below the waterline.

const LAYOUT := "res://map_layout.json"
const CAPS := "res://assets/terrain_void_caps.json"
const GRID := 163
const HALF := 81.5
const PAD := 2
const OFFSETS := [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 5.8]
const DEPTH := 0.32
const SMOOTH := 3

var verts := 0
var tris := 0
var _report: Array = []

func build(map: Node3D) -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	if d.is_empty():
		push_error("PondFunnel: layout missing")
		return
	var water := {}
	for i in d["water_mask"]:
		water[int(i)] = true
	var comps := _components(water)
	var info := _components_info(comps, map)
	var hgrid := _build_height_grid(map)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for id in info.keys():
		_shelf_lid(st, comps[id], float(info[id]["level"]), hgrid)
	# Blossom-tree slot, from its own 24-edge boundary chain.	# Blossom-tree slot, from its own 24-edge boundary chain.
	var cd: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CAPS))
	if not cd.is_empty():
		for cap in cd["caps"]:
			if absf(float(cap["centroid"][0]) - 5.32) < 0.2 \
					and absf(float(cap["centroid"][2]) + 9.62) < 0.2:
				_slot(st, cap["verts"])
				print("slot funnel: centroid=%s area=%.3f bbox=%s" % [
					str(cap["centroid"]), float(cap["area"]), str(cap["bbox"])])
	st.generate_normals()
	var mesh := st.commit()
	if mesh == null:
		return
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/ground_earth.gdshader")
	m.set_shader_parameter("dirt_albedo", load("res://assets/textures/dirt_soil/albedo.jpg"))
	m.set_shader_parameter("tint", Color(0.66, 0.59, 0.49))
	mesh.surface_set_material(0, m)
	var mi := MeshInstance3D.new()
	mi.name = "PondFunnels"
	mi.mesh = mesh
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var arrays := mesh.surface_get_arrays(0)
	verts = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var ia = arrays[Mesh.ARRAY_INDEX]
	tris = ia.size() / 3 if ia != null else verts / 3
	for line in _report:
		print("funnel ", line)
	print("pond funnels: %d verts, %d tris" % [verts, tris])


func _mask_contour(cells: Array, pad: int) -> Array:
	var set := {}
	for i in cells:
		var x: int = i % GRID
		var y: int = i / GRID
		for dx in range(-pad, pad + 1):
			for dy in range(-pad, pad + 1):
				var nx := x + dx
				var ny := y + dy
				if nx < 0 or ny < 0 or nx >= GRID or ny >= GRID:
					continue
				set[ny * GRID + nx] = true
	var adj := {}
	var edges := {}
	for i in set.keys():
		var x: int = i % GRID
		var y: int = i / GRID
		var dirs := [
			[1, 0, Vector2i(x + 1, y), Vector2i(x + 1, y + 1)],
			[-1, 0, Vector2i(x, y), Vector2i(x, y + 1)],
			[0, 1, Vector2i(x, y + 1), Vector2i(x + 1, y + 1)],
			[0, -1, Vector2i(x, y), Vector2i(x + 1, y)],
		]
		for d in dirs:
			var nx: int = x + int(d[0])
			var ny: int = y + int(d[1])
			if set.has(ny * GRID + nx):
				continue
			var a: Vector2i = d[2]
			var b: Vector2i = d[3]
			var ka := _ikey(a)
			var kb := _ikey(b)
			var k := ka + "|" + kb if ka < kb else kb + "|" + ka
			edges[k] = [a, b]
			if not adj.has(ka): adj[ka] = []
			if not adj.has(kb): adj[kb] = []
			adj[ka].append(kb)
			adj[kb].append(ka)
	var used := {}
	var best: Array = []
	for start in adj.keys():
		if used.has(start):
			continue
		var chain: Array = [start]
		used[start] = true
		var cur: String = start
		var prev := ""
		var guard := 0
		while true:
			var nxt := ""
			for cand in adj[cur]:
				if cand != prev and not used.has(cand):
					nxt = cand
					break
			if nxt == "":
				break
			used[nxt] = true
			chain.append(nxt)
			prev = cur
			cur = nxt
			guard += 1
			if cur == start or guard > 50000:
				break
		if chain.size() > best.size():
			best = chain
	var out: Array = []
	for key in best:
		var parts: PackedStringArray = key.split("_")
		var gx := float(parts[0])
		var gy := float(parts[1])
		out.append(Vector2(gx - HALF, -(gy - HALF)))
	return out


func _chaikin(pts: Array, iterations: int) -> Array:
	var cur := pts.duplicate()
	for it in iterations:
		var nxt: Array = []
		var n := cur.size()
		for i in n:
			var p: Vector2 = cur[i]
			var q: Vector2 = cur[(i + 1) % n]
			nxt.append(p.lerp(q, 0.25))
			nxt.append(p.lerp(q, 0.75))
		cur = nxt
	return cur


func _build_height_grid(map: Node3D) -> Dictionary:
	var grid := {}
	var terrain := map.find_child("Terrain", true, false) as Node3D
	if terrain == null:
		return grid
	for node in terrain.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.name == "TerrainUnderside":
			continue
		for s in range(mi.mesh.get_surface_count()):
			var a: Array = mi.mesh.surface_get_arrays(s)
			var vs: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var xf: Transform3D = mi.global_transform
			for v in vs:
				var w: Vector3 = xf * v
				var key := Vector2i(floori(w.x / 2.0), floori(w.z / 2.0))
				if not grid.has(key):
					grid[key] = []
				grid[key].append(w)
	return grid


func _rim_height(grid: Dictionary, x: float, z: float, fallback: float) -> float:
	var k := Vector2i(floori(x / 2.0), floori(z / 2.0))
	var best := 1e9
	var by := fallback
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			var key := k + Vector2i(dx, dz)
			if not grid.has(key):
				continue
			for v in grid[key]:
				var d: float = Vector2(v.x - x, v.z - z).length_squared()
				if d < best and d <= 2.5 * 2.5:
					best = d
					by = v.y
	return by


func _height_max(grid: Dictionary, x: float, z: float, r: float) -> float:
	var k := Vector2i(floori(x / 2.0), floori(z / 2.0))
	var best := -1e9
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var key := k + Vector2i(dx, dz)
			if not grid.has(key):
				continue
			for v in grid[key]:
				if Vector2(v.x - x, v.z - z).length() <= r:
					best = maxf(best, v.y)
	return best


func _shelf_lid(st: SurfaceTool, cells: Array, level: float, hgrid: Dictionary) -> void:
	# Cover only the cells whose terrain actually pokes above the water. Those
	# are the tan terrace tops. Deep-water cells (terrain below the waterline)
	# are left open, and high grass is left uncovered, so the lid cannot become
	# the giant brown apron the unfiltered version produced.
	var water := {}
	for i in cells:
		water[i] = true
	var set := {}
	for i in cells:
		var x: int = i % GRID
		var y: int = i / GRID
		for dx in range(-PAD, PAD + 1):
			for dy in range(-PAD, PAD + 1):
				var nx := x + dx
				var ny := y + dy
				if nx < 0 or ny < 0 or nx >= GRID or ny >= GRID:
					continue
				set[ny * GRID + nx] = true
	var covered := {}
	for i in set.keys():
		var x: int = i % GRID
		var y: int = i / GRID
		var w := _corner_to_world(Vector2i(x, y))
		var h := _height_max(hgrid, w.x + 0.5, w.z - 0.5, 1.1)
		if h > level - 0.05 and h < level + 1.20:
			covered[i] = true
	for i in covered.keys():
		var x: int = i % GRID
		var y: int = i / GRID
		var c := [
			Vector2i(x, y), Vector2i(x + 1, y),
			Vector2i(x + 1, y + 1), Vector2i(x, y + 1),
		]
		var top: Array = []
		for corner in c:
			var w := _corner_to_world(corner)
			var h := _height_max(hgrid, w.x, w.z, 1.2)
			var yy: float = maxf(level + 0.10, h + 0.12)
			top.append(Vector3(w.x, yy, w.z))
		_quad(st, top[0], top[1], top[2], top[3])
		var dirs := [
			[1, 0, 0, 1], [-1, 0, 3, 0],
			[0, 1, 1, 2], [0, -1, 0, 3],
		]
		for d in dirs:
			var nx: int = x + int(d[0])
			var ny: int = y + int(d[1])
			var ni := ny * GRID + nx
			if covered.has(ni):
				continue
			var a: int = d[2]
			var b: int = d[3]
			var nw := _corner_to_world(Vector2i(nx, ny))
			var nh := _height_max(hgrid, nw.x + 0.5, nw.z - 0.5, 1.1)
			var bottom := level - 0.40
			if nh > level + 0.03:
				bottom = minf(top[a].y, top[b].y) - 0.22
			_quad(st, top[a], top[b],
				Vector3(top[b].x, bottom, top[b].z),
				Vector3(top[a].x, bottom, top[a].z))

func _waterline_curtain(st: SurfaceTool, cells: Array, level: float, hgrid: Dictionary) -> void:
	# Stand the curtain outside the tan shelf, not at the water edge: from the
	# player camera the shelf sits between the pond and the bank, so a wall at
	# the water edge leaves it visible. A wall at the shelf's outer rim is in
	# front of the shelf and hides it completely.
	var set := {}
	for i in cells:
		var x: int = i % GRID
		var y: int = i / GRID
		for dx in range(-4, 5):
			for dy in range(-4, 5):
				var nx := x + dx
				var ny := y + dy
				if nx < 0 or ny < 0 or nx >= GRID or ny >= GRID:
					continue
				set[ny * GRID + nx] = true
	for i in set.keys():
		var x: int = i % GRID
		var y: int = i / GRID
		var dirs := [
			[1, 0, Vector2i(x + 1, y), Vector2i(x + 1, y + 1)],
			[-1, 0, Vector2i(x, y), Vector2i(x, y + 1)],
			[0, 1, Vector2i(x, y + 1), Vector2i(x + 1, y + 1)],
			[0, -1, Vector2i(x, y), Vector2i(x + 1, y)],
		]
		for d in dirs:
			var nx: int = x + int(d[0])
			var ny: int = y + int(d[1])
			if set.has(ny * GRID + nx):
				continue
			var a := _corner_to_world(d[2])
			var b := _corner_to_world(d[3])
			var ta := maxf(_height_max(hgrid, a.x, a.z, 1.5) + 0.12, level + 0.25)
			var tb := maxf(_height_max(hgrid, b.x, b.z, 1.5) + 0.12, level + 0.25)
			var bot := level - 0.40
			_quad(st,
				Vector3(a.x, ta, a.z), Vector3(b.x, tb, b.z),
				Vector3(b.x, bot, b.z), Vector3(a.x, bot, a.z))

func _corner_to_world(p: Vector2i) -> Vector3:
	return Vector3(float(p.x) - HALF, 0.0, -(float(p.y) - HALF))


func _slot(st: SurfaceTool, raw: Array) -> void:
	var pts: Array = []
	var top := -1e9
	for v in raw:
		var p := Vector3(float(v[0]), float(v[1]), float(v[2]))
		pts.append(p)
		top = maxf(top, p.y)
	if pts.size() < 3:
		return
	var bot := top - 1.5
	var n := pts.size()
	var center := Vector3.ZERO
	for p in pts:
		center += p
	center /= float(n)
	var low: Array = []
	for p in pts:
		var d := Vector2(p.x - center.x, p.z - center.z)
		low.append(Vector3(center.x + d.x * 0.55, bot, center.z + d.y * 0.55))
	for i in n:
		var j := (i + 1) % n
		_quad(st, pts[i], pts[j], low[j], low[i])
	var cap_c := Vector3(center.x, bot, center.z)
	for i in n:
		var j := (i + 1) % n
		st.add_vertex(cap_c); st.add_vertex(low[j]); st.add_vertex(low[i])


func _components(cells: Dictionary) -> Dictionary:
	var seen := {}
	var out := {}
	var id := 0
	for start in cells.keys():
		if seen.has(start): continue
		var stack: Array = [start]
		seen[start] = true
		var comp: Array = []
		while not stack.is_empty():
			var i: int = stack.pop_back()
			comp.append(i)
			var x: int = i % GRID
			var y: int = i / GRID
			for n in [[1,0],[-1,0],[0,1],[0,-1]]:
				var nx: int = x + n[0]
				var ny: int = y + n[1]
				if nx < 0 or ny < 0 or nx >= GRID or ny >= GRID: continue
				var j := ny * GRID + nx
				if cells.has(j) and not seen.has(j):
					seen[j] = true
					stack.append(j)
		out[id] = comp
		id += 1
	return out


func _components_info(comps: Dictionary, map: Node3D) -> Dictionary:
	var out := {}
	var water := map.get_node_or_null("Water")
	for id in comps.keys():
		var c := Vector2.ZERO
		for i in comps[id]:
			c += Vector2(float(i % GRID) - HALF, -(float(i / GRID) - HALF))
		c /= float(comps[id].size())
		var lev := 0.0
		var best := 1e20
		if water != null:
			for node in water.find_children("*", "MeshInstance3D", true, false):
				var mi := node as MeshInstance3D
				if mi.mesh == null: continue
				var ab: AABB = mi.global_transform * mi.get_aabb()
				var dd := Vector2(ab.get_center().x, ab.get_center().z).distance_to(c)
				if dd < best:
					best = dd
					lev = ab.end.y - 0.01
		out[id] = {"center": c, "level": lev}
	return out


func _ikey(p: Vector2i) -> String:
	return "%d_%d" % [p.x, p.y]

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)
