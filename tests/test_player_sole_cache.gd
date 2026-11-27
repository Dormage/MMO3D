extends SceneTree
## Run: godot --headless --path . --script tests/test_player_sole_cache.gd
## Adds -- --real-player to compare against the original calculation on the
## fetched player GLB too. No terrain, textures or other LFS assets are needed.

const SoleCache := preload("res://scripts/sole_sample_cache.gd")
const NO_HEIGHT := 1.0e20
var _failures := 0
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _excluded(n: Node) -> bool:
	return String(n.name).contains("weapon")


func _run() -> void:
	var fixture := _fixture(12000, false, false)
	var model: Node3D = fixture.model
	var skeleton: Skeleton3D = fixture.skeleton
	var feet: Array[int] = [1, 2]
	var cache := SoleCache.new()
	cache.build(model, skeleton, feet, _excluded)
	_check(cache.sample_count > 0 and cache.sample_count < 1000,
			"Cache must retain only eligible foot samples")
	_check(cache.source_vertex_count == 12000, "Weapon mesh must be excluded")
	_check(cache.bone_count() == 2, "Both foot bones must be cached")
	for pose in 36:
		var t := float(pose) / 7.0
		model.transform = Transform3D(Basis.from_euler(Vector3(t * 0.1, t, -t * 0.07))
				.scaled(Vector3(-1.25 if pose % 2 else 1.1, 0.8, 1.3)),
				Vector3(t * 13.0, t - 2.0, -t * 5.0))
		skeleton.set_bone_pose_rotation(1, Quaternion(Vector3.FORWARD, t * 0.3))
		skeleton.set_bone_pose_position(1, Vector3(0.03, sin(t) * 0.25, 0.0))
		skeleton.set_bone_pose_rotation(2, Quaternion(Vector3.RIGHT, -t * 0.2))
		skeleton.set_bone_pose_position(2, Vector3(-0.03, cos(t) * 0.25, 0.1))
		var expected := _original_lowest(model, skeleton, feet)
		var actual := cache.lowest_world(skeleton)
		_check(absf(actual - expected) < 0.00002,
				"Pose %d sole mismatch: original=%.8f cached=%.8f" % [pose, expected, actual])
	_benchmark(model, skeleton, feet, cache, "synthetic")
	cache.build(null, skeleton, feet)
	_check(cache.sample_count == 0 and cache.bone_count() == 0,
			"Rebuilding must clear old points")
	_check(cache.lowest_world(skeleton) == NO_HEIGHT, "Empty cache has no sole")
	model.free()

	# Skin vertex indices refer to bind slots, which need not be skeleton indices.
	# Eight-weight meshes also must not accidentally read the preceding vertex.
	for named in [false, true]:
		var reordered := _fixture(300, true, named)
		var reordered_model: Node3D = reordered.model
		var reordered_skeleton: Skeleton3D = reordered.skeleton
		cache.build(reordered_model, reordered_skeleton, feet, _excluded)
		_check(cache.sample_count > 0, "8-weight/reordered skin foot samples missing")
		var expected := _reference_lowest(reordered_model, reordered_skeleton, feet)
		_check(absf(cache.lowest_world(reordered_skeleton) - expected) < 0.00002,
				"8-weight %s skin binding mismatch" % ("named" if named else "indexed"))
		reordered_model.free()
	if OS.get_cmdline_user_args().has("--real-player"):
		_test_real_player()
	print("SOLE_CACHE_TEST checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _fixture(vertex_count: int, eight_weights: bool, named: bool) -> Dictionary:
	var model := Node3D.new()
	root.add_child(model)
	var skeleton := Skeleton3D.new()
	model.add_child(skeleton)
	for name in ["Torso", "LeftFoot", "RightFoot"]:
		skeleton.add_bone(name)
	for bone in [1, 2]:
		skeleton.set_bone_parent(bone, 0)
		skeleton.set_bone_rest(bone, Transform3D(Basis.IDENTITY,
				Vector3(float(bone) * 0.1, -1.0, 0.02)))
	var skin := Skin.new()
	skin.set_bind_count(3)
	for bind in 3:
		var bone: int = [2, 0, 1][bind] if eight_weights else bind
		if named:
			skin.set_bind_name(bind, skeleton.get_bone_name(bone))
		else:
			skin.set_bind_bone(bind, bone)
		skin.set_bind_pose(bind, Transform3D(Basis.from_euler(Vector3(0.1, 0.03, -0.02)),
				Vector3(float(bone) * 0.02, 0.13, -0.01)))
	var vertices := PackedVector3Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var influences := 8 if eight_weights else 4
	for i in vertex_count:
		vertices.append(Vector3(float(i % 13) * 0.01, float(i % 17) * 0.03,
				float(i % 7) * 0.02))
		for k in influences:
			# Give most vertices no foot influence to exercise the original
			# expensive whole-mesh scan, with eligible feet in both slots.
			var foot := i % 50 == 0
			var index := 0
			var weight := 1.0 if k == 0 else 0.0
			if eight_weights:
				index = 1
				if foot:
					index = 0 if k == 6 else 2
					weight = 0.5 if k == 6 or k == 7 else 0.0
			elif foot:
				index = 1 if k == 0 else 2
				weight = 0.5 if k < 2 else 0.0
			bones.append(index)
			weights.append(weight)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var mesh := ArrayMesh.new()
	var flags := Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if eight_weights else 0
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.skin = skin
	skeleton.add_child(instance)
	var weapon := MeshInstance3D.new()
	weapon.name = "weapon_test"
	weapon.mesh = mesh
	weapon.skin = skin
	weapon.position.y = -100.0
	skeleton.add_child(weapon)
	return {"model": model, "skeleton": skeleton}


func _original_lowest(model: Node3D, skeleton: Skeleton3D, feet: Array[int]) -> float:
	# Preserve the old implementation as an independent comparison, including
	# its full vertex scan and per-sample bind inversion and pose lookup.
	var low := NO_HEIGHT
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.skin == null or _excluded(mi):
			continue
		var arrays := mi.mesh.surface_get_arrays(0)
		if arrays.is_empty() or arrays[Mesh.ARRAY_BONES] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		for i in vertices.size():
			for k in 4:
				var bone := bones[i * 4 + k]
				if weights[i * 4 + k] < 0.25 or bone not in feet:
					continue
				var p := skeleton.global_transform * (skeleton.get_bone_global_pose(bone)
						* mi.skin.get_bind_pose(bone).affine_inverse() * vertices[i])
				low = minf(low, p.y)
	return low


func _reference_lowest(model: Node3D, skeleton: Skeleton3D, feet: Array[int]) -> float:
	var low := NO_HEIGHT
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if _excluded(mi):
			continue
		var arrays := mi.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var influences := bones.size() / vertices.size()
		for i in vertices.size():
			for k in influences:
				var slot := i * influences + k
				var bind := bones[slot]
				var name := mi.skin.get_bind_name(bind)
				var bone := skeleton.find_bone(name) if not name.is_empty() else mi.skin.get_bind_bone(bind)
				if weights[slot] < 0.25 or bone not in feet:
					continue
				var p := skeleton.global_transform * (skeleton.get_bone_global_pose(bone)
						* mi.skin.get_bind_pose(bind).affine_inverse() * vertices[i])
				low = minf(low, p.y)
	return low


func _benchmark(model: Node3D, skeleton: Skeleton3D, feet: Array[int],
		cache: RefCounted, label: String) -> void:
	var rounds := 30
	var started := Time.get_ticks_usec()
	for i in rounds:
		_original_lowest(model, skeleton, feet)
	var original_us := Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	for i in rounds:
		cache.lowest_world(skeleton)
	var cached_us := Time.get_ticks_usec() - started
	print("SOLE_BENCH %s vertices=%d samples=%d bones=%d original=%.3fms cached=%.3fms speedup=%.1fx" % [
		label, cache.source_vertex_count, cache.sample_count, cache.bone_count(),
		float(original_us) / rounds / 1000.0, float(cached_us) / rounds / 1000.0,
		float(original_us) / maxi(1, cached_us)])


func _test_real_player() -> void:
	var path := "res://assets/models/player/player_animated.glb"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_32() != 0x46546C67:
		_check(false, "Fetch the real player GLB with Git LFS before --real-player")
		return
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	_check(doc.append_from_file(path, state) == OK, "Real player GLB parse failed")
	var model := doc.generate_scene(state) as Node3D
	if model == null:
		_check(false, "Real player GLB scene generation failed")
		return
	root.add_child(model)
	var skeleton := model.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null:
		_check(false, "Real player skeleton missing")
		model.free()
		return
	var feet: Array[int] = []
	for i in skeleton.get_bone_count():
		var name := String(skeleton.get_bone_name(i)).to_lower()
		if name.contains("foot") or name.contains("toe"):
			feet.append(i)
	var cache := SoleCache.new()
	cache.build(model, skeleton, feet, _excluded)
	var ap := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap != null:
		for clip in ["Idle", "Walk", "StartWalk"]:
			if not ap.has_animation(clip):
				continue
			ap.play(clip)
			for sample in 13:
				ap.seek(ap.get_animation(clip).length * float(sample) / 12.0, true)
				var expected := _original_lowest(model, skeleton, feet)
				var actual: float = cache.lowest_world(skeleton)
				_check(absf(expected - actual) < 0.0001,
						"Real player %s sample %d mismatch: %.8f / %.8f" % [clip, sample, expected, actual])
	_benchmark(model, skeleton, feet, cache, "player GLB")
	model.free()
