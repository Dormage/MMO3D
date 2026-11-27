extends Node3D
## Thin smooth shoreline lip around the ten pond holes. The terrain already has
## a broad dirt shelf; this only replaces the ragged 1 m cell edge at the water
## line with a small smooth ellipse, leaving terrain.glb untouched.

const LAYOUT := "res://map_layout.json"
const GRID := 163
const HALF := 81.5
const SEGMENTS := 40
const RINGS := 3
const OUT_PAD := 0.2
const IN_PAD := 0.2

func build(map: Node3D) -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	if d.is_empty():
		return
	var cells := {}
	for i in d["water_mask"]:
		cells[int(i)] = true
	var comps := _components(cells)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var beds := SurfaceTool.new()
	beds.begin(Mesh.PRIMITIVE_TRIANGLES)
	for id in comps.keys():
		var comp: Array = comps[id]
		if comp.size() < 3:
			continue
		var minx := 1e9
		var maxx := -1e9
		var minz := 1e9
		var maxz := -1e9
		for i in comp:
			var x := float(i % GRID) - HALF
			var z := -(float(i / GRID) - HALF)
			minx = minf(minx, x - 0.5); maxx = maxf(maxx, x + 0.5)
			minz = minf(minz, z - 0.5); maxz = maxf(maxz, z + 0.5)
		var cx := (minx + maxx) * 0.5
		var cz := (minz + maxz) * 0.5
		var hx := (maxx - minx) * 0.5 + OUT_PAD
		var hz := (maxz - minz) * 0.5 + OUT_PAD
		var level := _level_for(id, map, Vector2(cx, cz))
		var rings: Array = []
		for r in RINGS:
			var t := float(r) / float(RINGS - 1)
			var sx := lerpf(hx - IN_PAD * 2.0, hx, t)
			var sz := lerpf(hz - IN_PAD * 2.0, hz, t)
			var y := lerpf(level - 0.15, level + 0.10, t)
			var ring: Array = []
			for j in SEGMENTS:
				var th := TAU * float(j) / float(SEGMENTS)
				ring.append(Vector3(cx + cos(th) * sx, y, cz + sin(th) * sz))
			rings.append(ring)
		for r in range(RINGS - 1):
			var a: Array = rings[r]
			var b: Array = rings[r + 1]
			for j in SEGMENTS:
				var n := (j + 1) % SEGMENTS
				_quad(st, a[j], a[n], b[n], b[j])
		# Exact cell-union bed at the waterline: fills only the actual square
		# terrain holes, so no rectangle shows outside the bank ring.
		for ci in comp:
			var gx := float(int(ci) % GRID) - HALF
			var gz := -(float(int(ci) / GRID) - HALF)
			# Keep the bed at the original flat shelf.  Carving it exposed the
			# unclosed shore ribbon as a torn tan ring; the depth read is now
			# produced by the water shader's per-pond radial basin term.
			var y := level - 0.006
			var a0 := Vector3(gx - 0.5, y, gz - 0.5)
			var a1 := Vector3(gx + 0.5, y, gz - 0.5)
			var a2 := Vector3(gx + 0.5, y, gz + 0.5)
			var a3 := Vector3(gx - 0.5, y, gz + 0.5)
			_quad(beds, a0, a1, a2, a3)
	st.generate_normals()
	beds.generate_normals()
	var mesh := st.commit()
	if mesh == null:
		return
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/ground_earth.gdshader")
	m.set_shader_parameter("dirt_albedo", load("res://assets/textures/dirt_soil/albedo.jpg"))
	m.set_shader_parameter("tint", Color(0.72, 0.65, 0.55))
	mesh.surface_set_material(0, m)
	var bed_mesh := beds.commit()
	if bed_mesh != null:
		var bm := StandardMaterial3D.new()
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bm.albedo_color = Color(0.075, 0.135, 0.125)
		bm.cull_mode = BaseMaterial3D.CULL_DISABLED
		bed_mesh.surface_set_material(0, bm)
		var bmi := MeshInstance3D.new()
		bmi.name = "PondBeds"
		bmi.mesh = bed_mesh
		bmi.material_override = bm
		bmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(bmi)
	var mi := MeshInstance3D.new()
	mi.name = "PondBanks"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The 3-ring lip is not watertight against the terrain rim: from the bank
	# camera it reads as torn tan paper strips.  The baked bank + pond funnel
	# already cover this transition.
	mi.visible = false
	add_child(mi)
	var arrays := mesh.surface_get_arrays(0)
	var verts := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var ia = arrays[Mesh.ARRAY_INDEX]
	print("pond banks: %d ponds, %d verts, %d tris" % [
		comps.size(), verts, ia.size() / 3 if ia != null else verts / 3])

func _bed_y(gx: float, gz: float, cx: float, cz: float,
		hx: float, hz: float, level: float) -> float:
	var rr := clampf(Vector2((gx - cx) / maxf(hx, 0.8),
			(gz - cz) / maxf(hz, 0.8)).length(), 0.0, 1.0)
	var bowl := 0.58 * (1.0 - smoothstep(0.0, 0.94, rr))
	return level - 0.006 - bowl


func _level_for(id: int, map: Node3D, center: Vector2) -> float:
	var water := map.get_node_or_null("Water")
	if water == null:
		return 0.0
	var best := 1e20
	var lev := 0.0
	for node in water.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var ab: AABB = mi.global_transform * mi.get_aabb()
		var d: float = Vector2(ab.get_center().x, ab.get_center().z).distance_to(center)
		if d < best:
			best = d
			lev = ab.end.y - 0.01
	return lev

func _components(cells: Dictionary) -> Dictionary:
	var seen := {}
	var out := {}
	var id := 0
	for start in cells.keys():
		if seen.has(start):
			continue
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
				if nx < 0 or ny < 0 or nx >= GRID or ny >= GRID:
					continue
				var j := ny * GRID + nx
				if cells.has(j) and not seen.has(j):
					seen[j] = true
					stack.append(j)
		out[id] = comp
		id += 1
	return out

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)
