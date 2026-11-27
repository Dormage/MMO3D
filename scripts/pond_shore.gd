extends Node3D
## Replace the hard water/bank tear with a continuous four-band shore ribbon.
## Uses the emitted pond contours (assets/water_ponds.json), so terrain.glb is
## untouched.  Also scatters grounded shingle along the same contour.

const DATA := "res://assets/water_ponds.json"
const BAND_IN := 0.55     # bury the inner edge inside the water
const BAND_SHALLOW := 0.30
const BAND_WET := 1.05     # past the raw cell edge, on the actual bank slope
const BAND_BANK := 1.60    # 0.5 m into the visible grass/bank

var _space: PhysicsDirectSpaceState3D

func build(map: Node3D) -> void:
	_space = get_world_3d().direct_space_state
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	if d.is_empty() or not d.has("ponds"):
		push_error("PondShore: missing pond contours")
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pebbles: Array = []
	for pond in d["ponds"]:
		var P: Array = pond.get("P", [])
		if P.size() < 3:
			continue
		var level: float = float(pond.get("level", 0.0))
		var c := Vector2.ZERO
		for q in P:
			c += Vector2(q[0], -q[1])
		c /= float(P.size())
		var area2 := 0.0
		for i in P.size():
			var q0: Array = P[i]
			var q1: Array = P[(i + 1) % P.size()]
			area2 += float(q0[0]) * float(q1[1]) - float(q1[0]) * float(q0[1])
		var ccw := area2 > 0.0
		var n := P.size()
		var rings: Array = []
		for k in 4:
			var off: float = [ -BAND_IN, BAND_SHALLOW, BAND_WET, BAND_BANK ][k]
			var ring: Array = []
			for i in n:
				var q: Array = P[i]
				var p := Vector2(q[0], -q[1])
				var qp: Array = P[(i - 1 + n) % n]
				var qn: Array = P[(i + 1) % n]
				var tx: float = float(qn[0]) - float(qp[0])
				var tz: float = float(qn[1]) - float(qp[1])
				var out := Vector2(tz, -tx)
				if not ccw:
					out = -out
				if out.length() < 1e-5:
					out = Vector2.RIGHT
				out = out.normalized()
				var x: float = p.x + out.x * off
				var z: float = p.y + out.y * off
				var y: float = [level - 0.180, level - 0.080][k] if k < 2 else maxf(_height_at(x, z, level), level + 0.06)
				ring.append(Vector3(x, y, z))
			rings.append(ring)
		for r in 3:
			var a: Array = rings[r]
			var b: Array = rings[r + 1]
			for i in n:
				var j := (i + 1) % n
				_quad(st, a[i], a[j], b[j], b[i], [0.0, 0.42, 0.70, 0.88][r], [0.42, 0.70, 0.88, 1.0][r])
		# Mirror band: some concave contour sections have the edge normal
		# pointing into the pond.  A second, oppositely offset ribbon covers
		# those banks too, so the water edge is never left as a bare terrain
		# hole.  The two bands overlap under the water where both are correct.
		var rings2: Array = []
		for k in 4:
			var off2: float = [ -BAND_IN, BAND_SHALLOW, BAND_WET, BAND_BANK ][k]
			var ring2: Array = []
			for i in n:
				var q: Array = P[i]
				var p := Vector2(q[0], -q[1])
				var qp: Array = P[(i - 1 + n) % n]
				var qn: Array = P[(i + 1) % n]
				var tx2: float = float(qn[0]) - float(qp[0])
				var tz2: float = float(qn[1]) - float(qp[1])
				var out := Vector2(-tz2, tx2)
				if not ccw: out = -out
				if out.length() < 1e-5: out = Vector2.RIGHT
				out = out.normalized()
				var x: float = p.x + out.x * off2
				var z: float = p.y + out.y * off2
				var y: float = [level - 0.180, level - 0.080][k] if k < 2 else maxf(_height_at(x, z, level), level + 0.06)
				ring2.append(Vector3(x, y, z))
			rings2.append(ring2)
		for r in 3:
			var a2: Array = rings2[r]
			var b2: Array = rings2[r + 1]
			for i in n:
				var j := (i + 1) % n
				_quad(st, a2[i], a2[j], b2[j], b2[i], [0.0, 0.42, 0.70, 0.88][r], [0.42, 0.70, 0.88, 1.0][r])
		# Shingle: a few dozen grounded, varied stones along the water edge.
		var step := maxi(1, n / 7)
		for i in range(0, n, step):
			var q: Array = P[i]
			var p := Vector2(q[0], -q[1])
			var qp: Array = P[(i - 1 + n) % n]
			var qn: Array = P[(i + 1) % n]
			var tx2: float = float(qn[0]) - float(qp[0])
			var tz2: float = float(qn[1]) - float(qp[1])
			var out := Vector2(tz2, -tx2)
			if not ccw: out = -out
			if out.length() < 1e-5: out = Vector2.RIGHT
			out = out.normalized()
			for s in 2:
				var dist: float = 0.55 + 0.26 * float((i + s) % 5) / 4.0
				var x: float = p.x + out.x * dist
				var z: float = p.y + out.y * dist
				var y: float = _height_at(x, z, level)
				pebbles.append([x, y, z, 0.12 + 0.060 * float((i * 3 + s) % 4), i * 1.7 + s])
	var mesh := st.commit()
	if mesh == null:
		push_error("PondShore: mesh commit failed")
		return
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/pond_shore.gdshader")
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "PondShoreMesh"
	mi.visible = false
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The broad four-band sheet is hidden: its offset rings self-intersect on
	# concave banks.  A narrow contour-following lip is built below instead.
	mi.visible = false
	add_child(mi)
	var arr := mesh.surface_get_arrays(0)
	var idx = arr[Mesh.ARRAY_INDEX]
	var tri_count: int = idx.size() / 3 if idx != null else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	print("pond shore: %d ponds, %d tris, %d pebbles" % [d["ponds"].size(), tri_count, pebbles.size()])
	_build_pebbles(pebbles)
	_build_lip(d["ponds"])

func _build_lip(ponds: Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for pond in ponds:
		var P: Array = pond.get("P", [])
		if P.size() < 3:
			continue
		var level: float = float(pond.get("level", 0.0))
		var area2 := 0.0
		for i in P.size():
			var q0: Array = P[i]
			var q1: Array = P[(i + 1) % P.size()]
			area2 += float(q0[0]) * float(q1[1]) - float(q1[0]) * float(q0[1])
		var ccw := area2 > 0.0
		var n := P.size()
		for i in n:
			var q: Array = P[i]
			var qn: Array = P[(i + 1) % n]
			var qp: Array = P[(i - 1 + n) % n]
			var p := Vector2(float(q[0]), -float(q[1]))
			var tx: float = float(qn[0]) - float(qp[0])
			var tz: float = float(qn[1]) - float(qp[1])
			var out := Vector2(tz, -tx)
			if not ccw:
				out = -out
			if out.length() < 1e-5:
				out = Vector2.RIGHT
			out = out.normalized()
			var a := Vector3(p.x, level + 0.012, p.y)
			var x2 := p.x + out.x * 0.18
			var z2 := p.y + out.y * 0.18
			var b := Vector3(x2, level + 0.006, z2)
			var q2: Array = P[(i + 1) % n]
			var p2 := Vector2(float(q2[0]), -float(q2[1]))
			var qn2: Array = P[(i + 2) % n]
			var tx2: float = float(qn2[0]) - float(q[0])
			var tz2: float = float(qn2[1]) - float(q[1])
			var out2 := Vector2(tz2, -tx2)
			if not ccw:
				out2 = -out2
			if out2.length() < 1e-5:
				out2 = Vector2.RIGHT
			out2 = out2.normalized()
			var c2 := Vector3(p2.x, level + 0.012, p2.y)
			var x3 := p2.x + out2.x * 0.18
			var z3 := p2.y + out2.y * 0.18
			var d2 := Vector3(x3, level + 0.006, z3)
			st.set_color(Color(0, 0, 0, 1)); st.add_vertex(a)
			st.set_color(Color(0, 0, 0, 1)); st.add_vertex(c2)
			st.set_color(Color(1, 0, 0, 1)); st.add_vertex(d2)
			st.set_color(Color(0, 0, 0, 1)); st.add_vertex(a)
			st.set_color(Color(1, 0, 0, 1)); st.add_vertex(d2)
			st.set_color(Color(1, 0, 0, 1)); st.add_vertex(b)
	var mesh := st.commit()
	if mesh == null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/pond_lip.gdshader")
	mesh.surface_set_material(0, mat)
	var li := MeshInstance3D.new()
	li.name = "PondLipMesh"
	li.visible = false
	li.mesh = mesh
	li.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(li)

func _height_at(x: float, z: float, level: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, level + 3.0, z), Vector3(x, level - 1.0, z), 1)
	var h: Dictionary = _space.intersect_ray(q)
	if h.is_empty():
		return level + 0.10
	return float(h["position"].y)

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, t0: float, t1: float) -> void:
	st.set_color(Color(t0, 0, 0, 1)); st.add_vertex(a)
	st.set_color(Color(t0, 0, 0, 1)); st.add_vertex(b)
	st.set_color(Color(t1, 0, 0, 1)); st.add_vertex(c)
	st.set_color(Color(t0, 0, 0, 1)); st.add_vertex(a)
	st.set_color(Color(t1, 0, 0, 1)); st.add_vertex(c)
	st.set_color(Color(t1, 0, 0, 1)); st.add_vertex(d)

func _build_pebbles(pebbles: Array) -> void:
	# Shore shingle used to be a SphereMesh, which read as a row of identical
	# brown balls at distance.  Use the authored irregular boulder instead:
	# varied scale/yaw/tilt and 2-8 cm of sink so every stone sits in the bank.
	var packed := load("res://assets/models/rocks_boulder_s.glb") as PackedScene
	if packed == null:
		push_warning("PondShore: boulder asset missing")
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.33, 0.31, 0.27)
	mat.albedo_texture = load("res://assets/models/rocks_boulder_s_color.jpg")
	mat.roughness = 0.97
	mat.metallic = 0.0
	for i in pebbles.size():
		var p: Array = pebbles[i]
		var inst := packed.instantiate() as Node3D
		if inst == null:
			continue
		inst.name = "Shingle_%d" % i
		var s: float = 0.42 + 0.50 * float((i * 7) % 11) / 10.0
		var sink: float = 0.025 + 0.055 * float((i * 5) % 7) / 6.0
		var low := 0.0
		var meshes := inst.find_children("*", "MeshInstance3D", true, false)
		if meshes.size() > 0:
			var mi0 := meshes[0] as MeshInstance3D
			low = mi0.mesh.get_aabb().position.y if mi0.mesh != null else 0.0
		for n in meshes:
			(n as MeshInstance3D).material_override = mat
		inst.scale = Vector3(s, s * (0.78 + 0.18 * float((i * 3) % 5) / 4.0), s)
		inst.rotation = Vector3(
			0.06 * float((i * 2) % 5) / 4.0 - 0.03,
			float(p[4]) + 0.31 * float(i % 7),
			0.05 * float((i * 3) % 5) / 4.0 - 0.025)
		inst.position = Vector3(p[0], float(p[1]) - low * s - sink, p[2])
		add_child(inst)
