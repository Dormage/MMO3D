extends RefCounted
## Rebuild render LOD index buffers after the region's geometry repairs.
##
## Import settings cannot help meshes replaced with a new ArrayMesh at runtime:
## those replacements carry only LOD0. ImporterMesh generates alternative index
## buffers against the SAME vertices; physics and navigation still read LOD0.
## Run once before the conditioned region is cached, never in a frame callback.


static func generate(root: Node) -> Dictionary:
	var started := Time.get_ticks_msec()
	var result := {"meshes": 0, "surfaces": 0, "levels": 0, "base_triangles": 0,
		"lowest_triangles": 0, "elapsed_ms": 0}
	var meshes: Dictionary = {}
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var instance := node as MeshInstance3D
		if instance.skin != null or not (instance.mesh is ArrayMesh):
			continue
		var source := instance.mesh as ArrayMesh
		# Regions are static. Do not apply static simplification to a future
		# animated model accidentally nested under RegionWorld.
		if source.get_blend_shape_count() > 0:
			continue
		var key := source.get_instance_id()
		if meshes.has(key):
			instance.mesh = meshes[key]
			continue
		var importer := ImporterMesh.from_mesh(source)
		var can_generate := false
		for surface in importer.get_surface_count():
			if importer.get_surface_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays := importer.get_surface_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			# The engine simplifier needs indexed triangles and vertex normals.
			# Leave unusual meshes alone instead of changing their shading.
			if indices.is_empty() or indices.size() % 3 != 0 \
					or normals.size() != vertices.size():
				can_generate = false
				break
			can_generate = true
		if not can_generate:
			meshes[key] = source
			continue
		importer.generate_lods(60.0, 25.0, [])
		var levels := 0
		for surface in importer.get_surface_count():
			if importer.get_surface_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays := importer.get_surface_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var count := importer.get_surface_lod_count(surface)
			result.base_triangles += indices.size() / 3
			result.lowest_triangles += (importer.get_surface_lod_indices(surface, count - 1).size()
					if count > 0 else indices.size()) / 3
			if count > 0:
				result.surfaces += 1
				levels += count
		if levels == 0:
			# Custom engine builds may omit meshoptimizer. Keep valid original
			# geometry and any imported shadow mesh in that case.
			meshes[key] = source
			continue
		var rebuilt := importer.get_mesh()
		rebuilt.custom_aabb = source.custom_aabb
		rebuilt.lightmap_size_hint = source.lightmap_size_hint
		rebuilt.shadow_mesh = source.shadow_mesh
		for meta in source.get_meta_list():
			rebuilt.set_meta(meta, source.get_meta(meta))
		meshes[key] = rebuilt
		instance.mesh = rebuilt
		result.meshes += 1
		result.levels += levels
	result.elapsed_ms = Time.get_ticks_msec() - started
	return result
