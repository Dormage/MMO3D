extends Node
## Waterfalls - replace the shared 3.2 m curtain with a ribbon sampled against
## the cliff.
##
## map.gd loads one water_waterfall.glb per fall and places its origin at the
## lip.  The shipped mesh extends *up* from that origin, so every fall was a
## white bar standing on the grass.  This autoload runs after map.gd has built
## them, reads the terrain mesh into a height grid, and for each fall walks the
## face from the lip downward: at every station it marches inward from the void
## until the rock at that height is hit, then puts the ribbon there.  Width and
## length are per-fall.  No map.gd or terrain edit.

const SHADER_PATH := "res://shaders/waterfall.gdshader"
const ROWS := 24
const COLS := 4
const FACE_START := 3.0  # start this far outside the lip

var _shader: Shader
var _material: ShaderMaterial
var _mist_material: ShaderMaterial
var _tris := PackedVector3Array()  # world-space triangles, 3 points each
var _w := 0
var _h := 0
var _land: Dictionary = {}
var _water: Dictionary = {}
var _built := 0


func _ready() -> void:
	if OS.get_environment("WATERFALLS_BEFORE") == "1":
		print("waterfalls: before capture, autoload skipped")
		return
	_shader = load(SHADER_PATH) as Shader
	if _shader == null:
		push_error("waterfalls: shader missing")
		return
	_material = ShaderMaterial.new()
	_material.shader = _shader
	_material.render_priority = 3
	# White foam ribbons were punching through the dusk void under the bridges.
	# Keep the fall readable as water, but at a small fraction of the old alpha.
	_material.set_shader_parameter("opacity", 0.48)
	_mist_material = ShaderMaterial.new()
	_mist_material.shader = _shader
	_mist_material.render_priority = 3
	_mist_material.set_shader_parameter("mist_mode", true)
	_mist_material.set_shader_parameter("opacity", 0.38)
	_mist_material.set_shader_parameter("speed", 0.7)
	_build.call_deferred()


func _build() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var scene := get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	var terrain := scene.find_child("Terrain", true, false)
	if terrain == null:
		# harness adds map.tscn after the autoload; retry once
		await get_tree().process_frame
		scene = get_tree().current_scene
		if scene != null:
			terrain = scene.find_child("Terrain", true, false)
	if terrain == null:
		# Isolated asset scenes have no map; stay silent there.
		return
	_load_layout()
	_index_terrain(terrain)

	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.get_meta("_waterfall_conformed", false):
			continue
		if not mi.name.to_lower().contains("waterfall"):
			continue
		if _build_ribbon(mi):
			mi.set_meta("_waterfall_conformed", true)
			_built += 1
	print("waterfalls conformed: ", _built)
	# The conforming ribbon can leave an opaque white card under the causeway.
	# The card is not the shader (colour and opacity changes do not reach it),
	# so remove those surfaces rather than leave white paper in the void.
	for n in scene.find_children("*", "MeshInstance3D", true, false):
		if not n.name.to_lower().contains("waterfall"):
			continue
		# Only the original opaque card is removed.  The conformed ribbon and
		# its splash quad are the visible waterfall now.
		if n.get_meta("_waterfall_conformed", false):
			continue
		if n.name.to_lower().ends_with("_splash"):
			continue
		(n as MeshInstance3D).visible = false


func _load_layout() -> void:
	var txt := FileAccess.get_file_as_string("res://map_layout.json")
	var d = JSON.parse_string(txt)
	if typeof(d) != TYPE_DICTIONARY:
		return
	_w = int(d["meta"]["width"])
	_h = int(d["meta"]["height"])
	for i in d["land_mask"]:
		_land[int(i)] = true
	for i in d["water_mask"]:
		_water[int(i)] = true


func _solid(x: float, z: float) -> bool:
	var cx := roundi(x + _w * 0.5)
	var cz := roundi(-z + _h * 0.5)
	if cx < 0 or cz < 0 or cx >= _w or cz >= _h:
		return false
	var i := cz * _w + cx
	return _land.has(i) or _water.has(i)


## The fall must face the void, not the island.  The stored yaw is not reliable
## after the world grew (several falls landed on an inland face).  Sample the
## land mask around the lip and choose the direction with the least solid
## ground.
func _outward(lip: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var best_score := 99
	for k in range(24):
		var a := TAU * k / 24.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		var score := 0
		for r in [1.0, 2.0, 3.0]:
			if _solid(lip.x + dir.x * r, lip.z + dir.z * r):
				score += 1
		if score < best_score:
			best_score = score
			best = dir
	if best_score >= 3:
		return Vector3.ZERO
	return best.normalized()


func _index_terrain(terrain: Node) -> void:
	for node in terrain.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var arrays := mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var xf := mi.global_transform
			if indices.is_empty():
				for i in range(0, verts.size() - 2, 3):
					_tris.append(xf * verts[i])
					_tris.append(xf * verts[i + 1])
					_tris.append(xf * verts[i + 2])
			else:
				for i in range(0, indices.size() - 2, 3):
					_tris.append(xf * verts[indices[i]])
					_tris.append(xf * verts[indices[i + 1]])
					_tris.append(xf * verts[indices[i + 2]])
	print("waterfalls: terrain triangles ", _tris.size() / 3)


## Horizontal ray at height y, from the void toward the island.  Returns the
## nearest rock point (the visible cliff face), or null.
func _face_at(lip: Vector3, outward: Vector3, y: float, near: PackedVector3Array) -> Variant:
	var origin := lip + outward * FACE_START
	origin.y = y
	var dir := -outward
	var best := 1.0e9
	var point: Variant = null
	for i in range(0, near.size(), 3):
		var hit = Geometry3D.ray_intersects_triangle(origin, dir, near[i],
				near[i + 1], near[i + 2])
		if hit != null:
			var d: float = origin.distance_to(hit)
			if d < best:
				best = d
				point = hit
	return point


func _build_ribbon(mi: MeshInstance3D) -> bool:
	if mi.mesh == null:
		return false
	var gt := mi.global_transform
	var lip := gt.origin
	var outward := _outward(lip)
	if outward.length_squared() < 0.5:
		outward = gt.basis.z.normalized()
	var side := Vector3.UP.cross(outward).normalized()
	var seed := fmod(absf(float(hash("%.2f:%.2f" % [lip.x, lip.z]))), 1.0)
	var length := 3.4 + seed * 3.0
	var width := 0.78 + (1.0 - seed) * 0.78

	# Only triangles around this fall can be hit; this keeps the ray test cheap.
	var near := PackedVector3Array()
	var lo := lip - Vector3(7.0, 8.0, 7.0)
	var hi := lip + Vector3(7.0, 2.0, 7.0)
	for i in range(0, _tris.size(), 3):
		var a := _tris[i]
		var b := _tris[i + 1]
		var c := _tris[i + 2]
		var bb := AABB(a, Vector3.ZERO).expand(b).expand(c)
		if bb.intersects(AABB(lo, hi - lo)):
			near.append(a); near.append(b); near.append(c)

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var inv := gt.affine_inverse()
	var prev_face := lip + outward * 0.04

	for i in range(ROWS + 1):
		var t := float(i) / ROWS
		var y := lip.y - t * length
		var face = _face_at(lip, outward, y, near)
		if face == null:
			face = prev_face
		# The first few centimetres are the spill over the lip, not the wall:
		# blend from the lip edge to the sampled face so the fall is attached.
		if t < 0.10:
			var edge := lip + outward * 0.02
			face = edge.lerp(face, smoothstep(0.0, 0.10, t))
		# keep the ribbon from jumping across an overhang
		if face.distance_to(prev_face) > 1.2:
			face = prev_face + outward * 0.04
		prev_face = face
		# A little belly so the water has depth, not a flag; still 3.5 cm off
		# the rock at lip and foot.
		var center: Vector3 = face + outward * (0.01 + 0.13 * sin(PI * t))
		var w := width * (0.78 + 0.42 * t) * (0.88 + 0.12 * sin(t * 9.0 + seed * 13.0))
		for j in range(COLS + 1):
			var u := float(j) / COLS
			var world := center + side * ((u - 0.5) * w)
			world += side * (0.04 * sin(t * 5.0 + seed * 7.0))
			# ragged foot: each column reaches a slightly different depth
			var col_len := length * (0.84 + 0.22
					* absf(sin(float(j) * 2.3 + seed * 9.0)))
			world.y = lip.y - t * col_len - (0.04 * absf(sin(float(j) * 1.9 + seed * 5.0)) if t < 0.02 else 0.0)
			verts.append(inv * world)
			normals.append((inv.basis * outward).normalized())
			uvs.append(Vector2(u, 1.0 - t))
		for j in range(COLS):
			var a := i * (COLS + 1) + j
			var b := a + COLS + 1
			idx.append(a); idx.append(b); idx.append(b + 1)
			idx.append(a); idx.append(b + 1); idx.append(a + 1)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	mi.mesh = mesh
	mi.set_meta("waterfall_outward", outward)
	mi.material_override = _material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Splash haze at the foot: a small camera-facing quad using the same shader
	# in mist_mode.  This is what makes the fall read at 20-60 m, where the
	# ribbon itself is only a few pixels wide.
	var base_world := lip + outward * 0.18
	base_world.y = lip.y - length * 0.92
	var mist := MeshInstance3D.new()
	mist.name = mi.name + "_splash"
	var quad := QuadMesh.new()
	quad.size = Vector2(width * 2.4, 1.45)
	mist.mesh = quad
	mist.material_override = _mist_material
	mist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var parent := mi.get_parent() as Node3D
	if parent != null:
		parent.add_child(mist)
		mist.global_transform = Transform3D(
			Basis.looking_at(-outward, Vector3.UP),
			base_world + outward * 0.30 + Vector3(0.0, 0.20, 0.0))
	return true
