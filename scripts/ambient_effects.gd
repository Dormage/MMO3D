extends Node3D
## Cheap dusk ambience: pollen motes over the village, a few distant birds,
## and wind-borne spray at selected waterfall feet.

var _birds: Array[MeshInstance3D] = []
var _bird_phase: Array[float] = []
var _t := 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.seed = 7321
	_make_dust()
	_make_birds()
	_make_fall_spray()

func _particle_material(box: Vector3, up: float, color: Color, size: float,
		amount: int, lifetime: float, velocity: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.preprocess = 3.0
	p.emitting = true
	p.visibility_aabb = AABB(-box * 2.2, box * 4.4)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = box
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = velocity * 0.4
	pm.initial_velocity_max = velocity
	pm.gravity = Vector3(0, up, 0)
	pm.scale_min = 0.55
	pm.scale_max = 1.35
	pm.color = color
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.8
	quad.material = mat
	p.draw_pass_1 = quad
	add_child(p)
	return p

func _make_dust() -> void:
	var p := _particle_material(Vector3(15, 2.0, 15), 0.015,
		Color(1.0, 0.86, 0.58, 0.34), 0.014, 240, 16.0, 0.22)
	p.position = Vector3(-12.0, 2.4, 20.0)

func _make_fall_spray() -> void:
	var made := 0
	for n in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or not mi.name.to_lower().contains("waterfall"):
			continue
		if mi.mesh == null:
			continue
		var base := mi.global_transform.origin
		base.y -= 4.0
		var p := _particle_material(Vector3(0.8, 0.5, 0.8), 0.12,
			Color(0.72, 0.86, 1.0, 0.28), 0.30, 28, 2.2, 0.35)
		p.position = base
		made += 1
		if made >= 6:
			break

func _make_birds() -> void:
	# Six two-triangle silhouettes, cheap enough to be invisible in the budget.
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array([
		Vector3(-0.55, 0.0, 0.0), Vector3(0.0, 0.0, 0.18),
		Vector3(0.55, 0.0, 0.0)])
	var idx := PackedInt32Array([0, 1, 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.18, 0.15, 0.16, 1.0)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in 6:
		var b := MeshInstance3D.new()
		b.mesh = mesh
		b.material_override = mat
		b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(b)
		_birds.append(b)
		_bird_phase.append(_rng.randf() * TAU)

func _process(delta: float) -> void:
	_t += delta
	for i in _birds.size():
		var a := _t * (0.07 + 0.01 * i) + _bird_phase[i]
		var r := 34.0 + 7.0 * i
		var c := Vector3(-8.0, 20.0 + 2.5 * sin(a * 0.7 + i), 10.0)
		_birds[i].position = c + Vector3(cos(a) * r, 0.0, sin(a) * r)
		_birds[i].rotation = Vector3(0.0, -a + PI * 0.5, 0.10 * sin(a * 2.0))
