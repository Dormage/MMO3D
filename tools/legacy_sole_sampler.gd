extends "res://scripts/sole_sample_cache.gd"
## Benchmark-only baseline. This preserves the original expensive implementation
## so --bench-legacy-sole can compare the same game/route/renderer with and without
## the cache. Ordinary gameplay never loads this script.

var _model: Node3D
var _feet: Array[int] = []
var _exclude_mesh: Callable


func build(model: Node3D, skeleton: Skeleton3D, foot_bones: Array[int],
		exclude_mesh: Callable = Callable()) -> void:
	# Keep metadata and initial load work identical to the optimized sampler.
	super.build(model, skeleton, foot_bones, exclude_mesh)
	_model = model
	_feet.assign(foot_bones)
	_exclude_mesh = exclude_mesh


func lowest_world(skeleton: Skeleton3D) -> float:
	if skeleton == null or _model == null or _feet.is_empty():
		return NO_HEIGHT
	var low := NO_HEIGHT
	for n in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.skin == null:
			continue
		if _exclude_mesh.is_valid() and bool(_exclude_mesh.call(mi)):
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
				if weights[i * 4 + k] < 0.25 or bone not in _feet:
					continue
				var live := skeleton.get_bone_global_pose(bone)
				var bind := mi.skin.get_bind_pose(bone)
				var p := skeleton.global_transform * (live * bind.affine_inverse() * vertices[i])
				low = minf(low, p.y)
	return low
