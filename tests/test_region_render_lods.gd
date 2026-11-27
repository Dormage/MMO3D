extends SceneTree
## godot --headless --path . --script res://tests/test_region_render_lods.gd
## Uses synthetic geometry; no GLBs or imported assets are needed.

const RenderLods := preload("res://scripts/region_render_lods.gd")
var _checks := 0
var _failures := 0
var _completed := false
var _deadline_ms := 0


func _init() -> void:
	_deadline_ms = Time.get_ticks_msec() + 10000
	_run.call_deferred()


func _process(_delta: float) -> bool:
	if not _completed and Time.get_ticks_msec() > _deadline_ms:
		push_error("render-LOD regression stopped before completing its assertions")
		quit(1)
	return false


func _check(ok: bool, description: String) -> void:
	_checks += 1
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
	for surface in source.get_surface_count():
		shadow.add_surface_from_arrays(source.surface_get_primitive_type(surface),
			_shadow_arrays(source.surface_get_arrays(surface)))
	source.shadow_mesh = shadow
	_check(_shadow_layout_issues(source).is_empty(), "source main/shadow surfaces agree before regenerating LODs")
	_check(ImporterMesh.from_mesh(shadow).get_surface_lod_count(0) == 0,
		"imported zero-LOD shadow fixture starts with no reduced index buffers")
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
	var minimal := MeshInstance3D.new()
	var minimal_mesh := ArrayMesh.new()
	var minimal_arrays := unindexed_arrays.duplicate()
	minimal_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	minimal_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, minimal_arrays)
	var minimal_shadow := ArrayMesh.new()
	minimal_shadow.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _shadow_arrays(minimal_arrays))
	minimal_mesh.shadow_mesh = minimal_shadow
	minimal.mesh = minimal_mesh
	world.add_child(minimal)
	var before_transform := a.transform
	var result := RenderLods.generate(world)
	_check(result.meshes == 1, "one shared mesh is generated once")
	_check(result.surfaces == 2 and result.levels > 0, "both simplifiable surfaces get LOD index buffers")
	_check(result.lowest_triangles < result.base_triangles, "LOD reduces rendered triangle count")
	_check(a.mesh == b.mesh, "shared instances retain shared geometry")
	_check(skinned.mesh == source, "skinned geometry is left untouched")
	_check(unindexed.mesh == unindexed_mesh, "unindexed geometry safely retains its source mesh")
	_check(no_normals.mesh == no_normals_mesh, "geometry without normals safely retains its source mesh")
	_check(minimal.mesh == minimal_mesh, "a single triangle with no generated LOD retains its original mesh")
	_check((minimal.mesh as ArrayMesh).shadow_mesh == minimal_shadow
		and _shadow_layout_issues(minimal_mesh).is_empty(),
		"a mesh with no new LOD keeps its compatible original shadow reference")
	_check(a.transform == before_transform, "instance transform is unchanged")
	_check(a.mesh.surface_get_material(0) == material, "material resource is preserved")
	_check((a.mesh as ArrayMesh).surface_get_name(0) == "ground", "surface name is preserved")
	_check(a.mesh.resource_name == source.resource_name, "mesh name is preserved")
	_check((a.mesh as ArrayMesh).custom_aabb == source.custom_aabb, "custom bounds are preserved")
	_check(a.mesh.lightmap_size_hint == source.lightmap_size_hint, "lightmap hint is preserved")
	_check((a.mesh as ArrayMesh).shadow_mesh == null,
		"regenerated geometry uses its main LOD buffers for shadows")
	_check(a.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"safe main-mesh fallback keeps ordinary shadows enabled")
	_check(_shadow_layout_issues(a.mesh as ArrayMesh).is_empty(),
		"every selected main surface/LOD has matching effective shadow geometry")
	_check(source.shadow_mesh == shadow, "the source shadow mesh is never mutated")
	_check((skinned.mesh as ArrayMesh).shadow_mesh == shadow,
		"skipped skinned geometry keeps its compatible original shadow mesh")
	var legacy_copy := (a.mesh as ArrayMesh).duplicate() as ArrayMesh
	legacy_copy.shadow_mesh = shadow
	_check(not _shadow_layout_issues(legacy_copy).is_empty(),
		"copying the zero-LOD source shadow onto regenerated main LODs reproduces the unsafe layout")
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
	var saved_path := "user://test_region_render_lods_%d.res" % OS.get_process_id()
	_check(ResourceSaver.save(a.mesh, saved_path) == OK, "generated LOD mesh saves")
	var saved := ResourceLoader.load(saved_path, "", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
	_check(saved != null, "generated LOD mesh reloads")
	if saved != null:
		var importer := ImporterMesh.from_mesh(saved)
		_check(importer.get_surface_lod_count(0) + importer.get_surface_lod_count(1) == result.levels,
			"LOD levels survive the region cache round trip")
		_check(saved.get_faces() == source.get_faces(), "cached LOD0 faces remain unchanged")
		_check(saved.shadow_mesh == null and _shadow_layout_issues(saved).is_empty(),
			"region cache round trip keeps every main/shadow LOD selection valid")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(saved_path))
	world.free()
	_check_fewer_shadow_lods()
	_completed = true
	print("REGION_RENDER_LODS_TEST failures=%d checks=%d levels=%d base_tris=%d lowest_tris=%d complete=%s" % [
		_failures, _checks, result.levels, result.base_triangles, result.lowest_triangles, _completed])
	quit(0 if _failures == 0 else 1)


func _check_fewer_shadow_lods() -> void:
	# Imported meshes may already have LODs. They are initially a valid pair,
	# but their old shadow layout becomes stale when the main LODs are replaced.
	var source := ArrayMesh.new()
	var shadow := ArrayMesh.new()
	var original := _grid_mesh().surface_get_arrays(0)
	var coarse := PackedInt32Array()
	for z in range(0, 32, 8):
		for x in range(0, 32, 8):
			var i := z * 33 + x
			coarse.append_array(PackedInt32Array([i, i + 8, i + 8 * 33,
				i + 8, i + 8 * 33 + 8, i + 8 * 33]))
	var old_lods := {8.0: coarse}
	for surface in 2:
		var arrays := original.duplicate(true)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex in vertices.size():
			vertices[vertex] += Vector3(surface * 40, 0, 0)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], old_lods)
		shadow.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _shadow_arrays(arrays), [], old_lods)
	source.shadow_mesh = shadow
	_check(_shadow_layout_issues(source).is_empty(), "multi-surface source with one LOD has compatible shadow buffers")
	var source_importer := ImporterMesh.from_mesh(source)
	var shadow_importer := ImporterMesh.from_mesh(shadow)
	for surface in 2:
		_check(source_importer.get_surface_lod_count(surface) == 1
			and shadow_importer.get_surface_lod_count(surface) == 1,
			"surface %d begins with exactly one matching imported LOD" % surface)
	var world := Node3D.new()
	root.add_child(world)
	var instance := MeshInstance3D.new()
	instance.mesh = source
	world.add_child(instance)
	var result := RenderLods.generate(world)
	var rebuilt := instance.mesh as ArrayMesh
	var rebuilt_importer := ImporterMesh.from_mesh(rebuilt)
	_check(result.meshes == 1 and result.surfaces == 2, "both surfaces regenerate their existing imported LODs")
	for surface in 2:
		_check(rebuilt_importer.get_surface_lod_count(surface) > shadow_importer.get_surface_lod_count(surface),
			"surface %d generated LOD range exceeds the old shadow range" % surface)
		_check(rebuilt.surface_get_arrays(surface) == source.surface_get_arrays(surface),
			"surface %d retains every original LOD0 vertex attribute" % surface)
		_check(ImporterMesh.from_mesh(source).get_surface_lod_count(surface) == 1
			and ImporterMesh.from_mesh(shadow).get_surface_lod_indices(surface, 0) == coarse,
			"surface %d original main/shadow LOD buffers remain unchanged" % surface)
	_check(rebuilt.shadow_mesh == null and _shadow_layout_issues(rebuilt).is_empty(),
		"old one-LOD shadows cannot remain attached to regenerated geometry")
	var legacy_copy := rebuilt.duplicate() as ArrayMesh
	legacy_copy.shadow_mesh = shadow
	_check(not _shadow_layout_issues(legacy_copy).is_empty(),
		"copying a source shadow with fewer LODs reproduces the invalid renderer selection")
	var saved_path := "user://test_region_render_lods_fewer_shadow_lods_%d.res" % OS.get_process_id()
	_check(ResourceSaver.save(rebuilt, saved_path) == OK, "regenerated imported-LOD mesh saves")
	var saved := ResourceLoader.load(saved_path, "", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
	_check(saved != null, "regenerated imported-LOD mesh reloads")
	if saved != null:
		_check(saved.shadow_mesh == null and _shadow_layout_issues(saved).is_empty(),
			"serialized imported-LOD replacement retains a valid shadow fallback")
		var saved_importer := ImporterMesh.from_mesh(saved)
		for surface in 2:
			_check(saved_importer.get_surface_lod_count(surface) == rebuilt_importer.get_surface_lod_count(surface),
				"surface %d retains its generated LOD count after serialization" % surface)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(saved_path))
	world.free()


func _shadow_arrays(arrays: Array) -> Array:
	# A real imported shadow mesh needs only positions and index buffers.
	var result := []
	result.resize(Mesh.ARRAY_MAX)
	result[Mesh.ARRAY_VERTEX] = arrays[Mesh.ARRAY_VERTEX]
	result[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
	return result


func _shadow_layout_issues(mesh: ArrayMesh) -> Array[String]:
	var issues: Array[String] = []
	var main := ImporterMesh.from_mesh(mesh)
	# A null optimized shadow mesh uses the main surface/index buffers in GLES3.
	var effective_shadow := mesh.shadow_mesh if mesh.shadow_mesh != null else mesh
	var shadow := ImporterMesh.from_mesh(effective_shadow)
	if main.get_surface_count() != shadow.get_surface_count():
		issues.append("surface count differs")
	for surface in mini(main.get_surface_count(), shadow.get_surface_count()):
		if main.get_surface_primitive_type(surface) != shadow.get_surface_primitive_type(surface):
			issues.append("surface %d primitive differs" % surface)
		var count := main.get_surface_lod_count(surface)
		if count != shadow.get_surface_lod_count(surface):
			issues.append("surface %d LOD range differs" % surface)
			continue
		var arrays := main.get_surface_arrays(surface)
		var shadow_arrays := shadow.get_surface_arrays(surface)
		if _positions(arrays, arrays[Mesh.ARRAY_INDEX]) != _positions(shadow_arrays, shadow_arrays[Mesh.ARRAY_INDEX]):
			issues.append("surface %d LOD0 positions differ" % surface)
		for lod in count:
			if _positions(arrays, main.get_surface_lod_indices(surface, lod)) != \
					_positions(shadow_arrays, shadow.get_surface_lod_indices(surface, lod)):
				issues.append("surface %d LOD %d positions differ" % [surface, lod])
	return issues


func _positions(arrays: Array, indices: Variant) -> PackedVector3Array:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if indices == null or indices.is_empty():
		return vertices
	var positions := PackedVector3Array()
	for index in indices:
		positions.append(vertices[index])
	return positions


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
