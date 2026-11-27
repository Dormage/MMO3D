extends RefCounted
## One-off landmarks for five small islands that previously read as
## "crystal cluster + optional blossom".  Everything reuses existing art.
## Decorative only: no collision, so no navmesh route changes.

const TARGETS := {
	1: {"kind": "crystal", "c": Vector2(-58.0, 68.7)},
	2: {"kind": "arch", "c": Vector2(60.3, 62.7)},
	5: {"kind": "crystal", "c": Vector2(13.4, 68.9)},
	7: {"kind": "fallen_statue", "c": Vector2(-29.7, -77.3)},
	8: {"kind": "blind", "c": Vector2(81.0, 10.6)},
}

var map: Node3D
var built := 0

func build(m: Node3D) -> void:
	map = m
	for id in TARGETS.keys():
		var t: Dictionary = TARGETS[id]
		var c: Vector2 = t["c"]
		var spot := _clear_spot(c, id)
		if spot.y < -2.0:
			continue
		match String(t["kind"]):
			"cairn": _cairn(spot, id)
			"arch": _arch(spot, id)
			"well": _well(spot, id)
			"fallen_statue": _fallen(spot, id)
			"blind": _blind(spot, id)
		built += 1
	print("ISLAND_SIGNATURES built=%d %s" % [built, str(TARGETS.keys())])

func _clear_spot(c: Vector2, id: int) -> Vector3:
	# Pick a tree-free patch around the island centroid so the landmark and its
	# crystal are not buried inside a trunk.
	var trees: Array[Vector2] = []
	for n in map.find_children("*", "Node3D", true, false):
		var nm := String(n.name).to_lower()
		if nm.contains("tree") and not nm.contains("foliage"):
			var gp: Vector3 = (n as Node3D).global_position
			if Vector2(gp.x - c.x, gp.z - c.y).length() < 16.0:
				trees.append(Vector2(gp.x, gp.z))
	var best := Vector3.ZERO
	var best_score := -1.0
	for r in [4.0, 5.0, 6.0, 7.0, 8.5]:
		for a in 24:
			var ang := TAU * float(a) / 24.0 + float(id) * 0.31
			var p := Vector3(c.x + cos(ang) * r, 0.0, c.y + sin(ang) * r)
			var clear := 99.0
			for tp in trees:
				clear = minf(clear, Vector2(p.x, p.z).distance_to(tp))
			var score: float = clear - float(r) * 0.08
			if score > best_score:
				best_score = score
				best = p
	best.y = float(map.call("_terrain_y", best.x, best.z))
	return best

func _signature_crystal(p: Vector3, id: int) -> void:
	var tones := {
		1: [Color(0.16, 0.10, 0.30), Color(0.55, 0.35, 0.85)],
		2: [Color(0.24, 0.14, 0.05), Color(0.85, 0.55, 0.18)],
		5: [Color(0.10, 0.22, 0.10), Color(0.35, 0.65, 0.28)],
		7: [Color(0.25, 0.08, 0.06), Color(0.80, 0.28, 0.18)],
		8: [Color(0.22, 0.24, 0.28), Color(0.75, 0.80, 0.88)],
	}
	if not tones.has(id):
		return
	p.y = float(map.call("_terrain_y", p.x, p.z))
	var n := _add("crystal_cluster_crystal_large", p, 0.4, 1.45)
	if n == null:
		return
	_seat(n)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/crystal.gdshader") as Shader
	mat.set_shader_parameter("body_color", tones[id][0])
	mat.set_shader_parameter("edge_color", tones[id][1])
	for ch in n.find_children("*", "MeshInstance3D", true, false):
		(ch as MeshInstance3D).material_override = mat

func _add(model: String, pos: Vector3, yaw: float, scl: float, rot := Vector3.ZERO) -> Node3D:
	var packed := load("res://assets/models/%s.glb" % model) as PackedScene
	if packed == null:
		return null
	var n := packed.instantiate() as Node3D
	if n == null:
		return null
	n.position = pos
	n.rotation = Vector3(rot.x, yaw, rot.z)
	n.scale = Vector3(scl, scl, scl)
	map.add_child(n)
	return n

func _seat(n: Node3D) -> void:
	if n == null:
		return
	var low := float(map.call("_lowest_world_mesh_y", n))
	var gy := float(map.call("_terrain_y", n.global_position.x, n.global_position.z))
	if low < 1.0e29 and gy > -10.0:
		n.position.y -= low - gy - 0.01

func _stone(n: Node3D, id: int) -> void:
	if n == null:
		return
	# Reuse the island's stone/basalt palette; no new hue.
	for ch in n.find_children("*", "MeshInstance3D", true, false):
		var mi := ch as MeshInstance3D
		var mat := ShaderMaterial.new()
		mat.shader = load("res://shaders/bank_rock.gdshader") as Shader
		mat.set_shader_parameter("rock_albedo", load("res://assets/textures/stone_basalt/albedo.jpg"))
		mat.set_shader_parameter("rock_rough", load("res://assets/textures/stone_basalt/rough.jpg"))
		mat.set_shader_parameter("rock_tone", Vector3(0.78, 0.74, 0.68) if id % 2 == 0 else Vector3(1.08, 1.04, 0.96))
		mi.material_override = mat

func _cairn(p: Vector3, id: int) -> void:
	var y := p.y + 0.02
	var heights := [1.15, 0.85, 0.55]
	for k in 3:
		var s: float = [1.15, 0.82, 0.55][k]
		var n := _add("rocks_boulder_s", Vector3(p.x + k * 0.08, y, p.z - k * 0.05), float(k) * 1.3, s, Vector3(0.0, 0.0, float(k) * 0.12))
		if n == null:
			continue
		_stone(n, id + k)
		y += float(heights[k]) * s

func _arch(p: Vector3, id: int) -> void:
	var n := _add("ruins_arch_marble_s", p, 0.35, 2.0)
	_seat(n)
	_stone(n, id)

func _well(p: Vector3, id: int) -> void:
	var n := _add("buildings/building_well", p, -0.6, 0.42)
	_seat(n)
	# Weathered stone ring, not a new colour.
	_stone(n, id)

func _fallen(p: Vector3, id: int) -> void:
	var n := _add("statues_statue_votive", p, 1.1, 1.15, Vector3(PI * 0.5, 0.0, 0.08))
	_seat(n)
	_stone(n, id)

func _blind(p: Vector3, id: int) -> void:
	for k in 3:
		var n := _add("ruins_slab_mossy_l", p + Vector3(k * 0.9 - 0.9, 0.0, k * 0.15), 0.2 + k * 0.1, 0.9, Vector3(0.0, 0.0, PI * 0.5))
		_seat(n)
		_stone(n, id + k)
