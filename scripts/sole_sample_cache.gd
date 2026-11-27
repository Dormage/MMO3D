extends RefCounted
## Cache the player's existing sole-fitting samples independently of animation.
## Finding foot vertices and inverting skin bind transforms belongs at model
## load time, not in every walking physics tick. Queries only read the poses of
## the relevant bones and evaluate their cached points.

const NO_HEIGHT := 1.0e20

var sample_count := 0
var source_vertex_count := 0
var _bone_ids: Array[int] = []
var _points: Array[PackedVector3Array] = []


func build(model: Node3D, skeleton: Skeleton3D, foot_bones: Array[int],
		exclude_mesh: Callable = Callable()) -> void:
	sample_count = 0
	source_vertex_count = 0
	_bone_ids.clear()
	_points.clear()
	if model == null or skeleton == null or foot_bones.is_empty():
		return
	var by_bone := {}
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.skin == null or mi.mesh.get_surface_count() == 0:
			continue
		if exclude_mesh.is_valid() and bool(exclude_mesh.call(mi)):
			continue
		# Preserve the surface and >= 0.25 influence selection used by the
		# controller's sole fit. This is a cache, not a new foot-placement model.
		var arrays := mi.mesh.surface_get_arrays(0)
		if arrays.is_empty() or arrays[Mesh.ARRAY_BONES] == null \
				or arrays[Mesh.ARRAY_WEIGHTS] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if vertices.is_empty() or bones.size() != weights.size():
			continue
		var influences := bones.size() / vertices.size()
		if (influences != 4 and influences != 8) \
				or bones.size() != vertices.size() * influences:
			continue
		source_vertex_count += vertices.size()
		var bind_bones := {}
		var inverse_binds := {}
		for bind_index in mi.skin.get_bind_count():
			var bind_name := mi.skin.get_bind_name(bind_index)
			var bone := skeleton.find_bone(bind_name) if not bind_name.is_empty() \
					else mi.skin.get_bind_bone(bind_index)
			if bone not in foot_bones:
				continue
			bind_bones[bind_index] = bone
			# Keep the controller's original bind-space calculation exactly.
			inverse_binds[bind_index] = mi.skin.get_bind_pose(bind_index).affine_inverse()
		for i in vertices.size():
			for k in influences:
				var influence := i * influences + k
				var bind_index := bones[influence]
				if weights[influence] < 0.25 or not bind_bones.has(bind_index):
					continue
				var bone: int = bind_bones[bind_index]
				if not by_bone.has(bone):
					by_bone[bone] = PackedVector3Array()
				var inverse_bind: Transform3D = inverse_binds[bind_index]
				by_bone[bone].append(inverse_bind * vertices[i])
				sample_count += 1
	for bone: int in by_bone:
		_bone_ids.append(bone)
		_points.append(by_bone[bone])


func bone_count() -> int:
	return _bone_ids.size()


func lowest_world(skeleton: Skeleton3D) -> float:
	if skeleton == null:
		return NO_HEIGHT
	var low := NO_HEIGHT
	var world := skeleton.global_transform
	for i in _bone_ids.size():
		var pose := world * skeleton.get_bone_global_pose(_bone_ids[i])
		# Only Y is needed. Hoist the transform out of the vertex loop and avoid
		# constructing a transformed Vector3 for each cached sample.
		var row_y := Vector3(pose.basis.x.y, pose.basis.y.y, pose.basis.z.y)
		var origin_y := pose.origin.y
		for point in _points[i]:
			low = minf(low, row_y.dot(point) + origin_y)
	return low
