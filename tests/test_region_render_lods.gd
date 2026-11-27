extends SceneTree
## godot --headless --path . --script res://tests/test_region_render_lods.gd
## Uses synthetic geometry; no GLBs or imported assets are needed.

const RenderLods := preload("res://scripts/region_render_lods.gd")
var _failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	if not ok:
		push_error("FAIL: " + description)
		_failures += 1


func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var source := _grid_mesh()
	var original := source.surface_get_arrays(0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.7, 0.4)
	source.surface_set_material(0, material)
	source.surface_set_name(0, "ground")
	source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, original)
	var other_material := StandardMaterial3D.new()
	other_material.albedo_color = Color(0.8, 0.3, 0.1)
	source.surface_set_material(1, other_material)
	source.surface_set_name(1, "other_surface")
	var line_arrays := []
	line_arrays.resize(Mesh.ARRAY_MAX)
	line_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.ONE])
	source.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, line_arrays)
	source.surface_set_name(2, "debug_lines")
	var originals := [source.surface_get_arrays(0), source.surface_get_arrays(1), source.surface_get_arrays(2)]
	source.resource_name = "SyntheticTerrain"
	source.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(40, 6, 40))
	source.lightmap_size_hint = Vector2i(64, 32)
	source.set_meta("test_tag", "retained")
	var shadow := ArrayMesh.new()
	shadow.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, original)
	source.shadow_mesh = shadow
	var a := MeshInstance3D.new()
	a.mesh = source
	a.transform = Transform3D(Basis(Vector3.UP, 0.7).scaled(Vector3(2, 1, 3)), Vector3(4, 2, -6))
	world.add_child(a)
	var b := MeshInstance3D.new()
	b.mesh = source
	world.add_child(b)
	var skinned := MeshInstance3D.new()
	skinned.mesh = source
	skinned.skin = Skin.new()
	world.add_child(skinned)
	var unindexed := MeshInstance3D.new()
	var unindexed_mesh := ArrayMesh.new()
	var unindexed_arrays := []
	unindexed_arrays.resize(Mesh.ARRAY_MAX)
	unindexed_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.BACK])
	unindexed_arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	unindexed_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, unindexed_arrays)
	unindexed.mesh = unindexed_mesh
	world.add_child(unindexed)
	var no_normals := MeshInstance3D.new()
	var no_normals_mesh := ArrayMesh.new()
	var no_normal_arrays := unindexed_arrays.duplicate()
	no_normal_arrays[Mesh.ARRAY_NORMAL] = null
	no_normal_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	no_normals_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, no_normal_arrays)
	no_normals.mesh = no_normals_mesh
	world.add_child(no_normals)
	var before_transform := a.transform
	var result := RenderLods.generate(world)
	_check(result.meshes == 1, "one shared mesh is generated once")
	_check(result.surfaces == 2 and result.levels > 0, "both simplifiable surfaces get LOD index buffers")
	_check(result.lowest_triangles < result.base_triangles, "LOD reduces rendered triangle count")
	_check(a.mesh == b.mesh, "shared instances retain shared geometry")
	_check(skinned.mesh == source, "skinned geometry is left untouched")
	_check(unindexed.mesh == unindexed_mesh, "unindexed geometry safely retains its source mesh")
	_check(no_normals.mesh == no_normals_mesh, "geometry without normals safely retains its source mesh")
	_check(a.transform == before_transform, "instance transform is unchanged")
	_check(a.mesh.surface_get_material(0) == material, "material resource is preserved")
	_check((a.mesh as ArrayMesh).surface_get_name(0) == "ground", "surface name is preserved")
	_check(a.mesh.resource_name == source.resource_name, "mesh name is preserved")
	_check((a.mesh as ArrayMesh).custom_aabb == source.custom_aabb, "custom bounds are preserved")
	_check(a.mesh.lightmap_size_hint == source.lightmap_size_hint, "lightmap hint is preserved")
	_check((a.mesh as ArrayMesh).shadow_mesh == shadow, "imported shadow geometry is preserved")
	_check(a.mesh.get_meta("test_tag") == "retained", "mesh metadata is preserved")
	_check(a.mesh.get_surface_count() == source.get_surface_count(), "all surfaces remain present")
	for surface in source.get_surface_count():
		var rebuilt := a.mesh.surface_get_arrays(surface)
		_check(a.mesh.surface_get_material(surface) == source.surface_get_material(surface),
			"surface %d material is unchanged" % surface)
		_check((a.mesh as ArrayMesh).surface_get_name(surface) == source.surface_get_name(surface),
			"surface %d name is unchanged" % surface)
		_check(a.mesh.surface_get_primitive_type(surface) == source.surface_get_primitive_type(surface),
			"surface %d primitive type is unchanged" % surface)
		for attribute in Mesh.ARRAY_MAX:
			_check(rebuilt[attribute] == originals[surface][attribute],
				"surface %d LOD0 attribute %d is unchanged" % [surface, attribute])
	_check(source.surface_get_arrays(0) == original, "source mesh is never mutated")
	_check(source.get_faces() == a.mesh.get_faces(), "collision and navigation faces are identical")
	var saved_path := "user://test_region_render_lods.res"
	_check(ResourceSaver.save(a.mesh, saved_path) == OK, "generated LOD mesh saves")
	var saved := ResourceLoader.load(saved_path, "", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
	_check(saved != null, "generated LOD mesh reloads")
	if saved != null:
		var importer := ImporterMesh.from_mesh(saved)
		_check(importer.get_surface_lod_count(0) + importer.get_surface_lod_count(1) == result.levels,
			"LOD levels survive the region cache round trip")
		_check(saved.get_faces() == source.get_faces(), "cached LOD0 faces remain unchanged")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(saved_path))
	world.free()
	print("REGION_RENDER_LODS_TEST failures=%d levels=%d base_tris=%d lowest_tris=%d" % [
		_failures, result.levels, result.base_triangles, result.lowest_triangles])
	quit(0 if _failures == 0 else 1)


func _grid_mesh() -> ArrayMesh:
	var size := 32
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for z in size + 1:
		for x in size + 1:
			vertices.append(Vector3(x, 0.2 * sin(x * 0.2) * cos(z * 0.2), z))
			normals.append(Vector3.UP)
			uv.append(Vector2(x, z) / float(size))
			colors.append(Color(0.3, 0.7, 0.4, 1.0))
	for z in size:
		for x in size:
			var i := z * (size + 1) + x
			indices.append_array(PackedInt32Array([i, i + 1, i + size + 1,
				i + 1, i + size + 2, i + size + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
