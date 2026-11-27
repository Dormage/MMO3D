extends SceneTree
## godot --headless --path . --script res://tests/test_nav_marker_cache.gd
## Uses a synthetic marker mesh; no world GLBs or import cache are needed.

const NavWorld := preload("res://scripts/nav_world.gd")
var _failures := 0


class CacheProbe extends NavWorld:
	var cache_hits := 0
	var stitch_cache_hits := 0

	func _nav_cache_load() -> bool:
		var hit := super._nav_cache_load()
		if hit:
			cache_hits += 1
		return hit

	func _load_stitch_cache(signature: String) -> bool:
		var hit := super._load_stitch_cache(signature)
		if hit:
			stitch_cache_hits += 1
		return hit


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	if not ok:
		push_error("FAIL: " + description)
		_failures += 1


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "fixture file can be written")
	if file != null:
		file.store_string(text)
		file.close()


func _build(map: Node3D, cache_id: String, marker_path: String) -> CacheProbe:
	var nav := CacheProbe.new()
	nav.cache_id = cache_id
	nav.marker_file = marker_path
	root.add_child(nav)
	nav.build(map)
	return nav


func _polygons(mesh: NavigationMesh) -> Array[PackedInt32Array]:
	var result: Array[PackedInt32Array] = []
	for index in mesh.get_polygon_count():
		result.append(mesh.get_polygon(index))
	return result


func _run() -> void:
	var cache_id := "test_nav_marker_%d" % OS.get_process_id()
	var marker_path := "user://%s.marker" % cache_id
	var alternate_path := "user://%s_alternate.marker" % cache_id
	# The marker file is used for cache identity. The synthetic mesh below is
	# what a parsed GLB would supply to NavWorld.build().
	_write(marker_path, "marker export one")
	_write(alternate_path, "marker export one")
	var map := Node3D.new()
	root.add_child(map)
	var marker := MeshInstance3D.new()
	marker.name = "NAV_TestGround"
	var plane := PlaneMesh.new()
	plane.size = Vector2(8.0, 8.0)
	marker.mesh = plane
	map.add_child(marker)

	var first := _build(map, cache_id, marker_path)
	_check(first.cache_hits == 0, "first build misses the cache")
	_check(first.polygons > 0, "first build creates walkable polygons")
	_check(first.source_faces > 0, "first build scans source triangles")
	var vertices := first.navmesh.get_vertices()
	var polygons := _polygons(first.navmesh)
	var paths: Array = first.call("_nav_cache_paths")
	_check(FileAccess.file_exists(paths[0]) and FileAccess.file_exists(paths[1]),
		"first build persists mesh and cache signature")
	first.free()

	var second := _build(map, cache_id, marker_path)
	_check(second.cache_hits == 1, "second build loads the cache before scanning marker triangles")
	_check(second.stitch_cache_hits == 1, "second build also restores serialized stitch metadata")
	_check(second.source_faces == 0, "cache reuse does not require source_faces from a previous scene")
	_check(second.navmesh.get_vertices() == vertices, "cached vertices exactly match the original bake")
	_check(_polygons(second.navmesh) == polygons, "cached polygons exactly match the original bake")
	var same_file_key: String = second.call("_nav_signature")
	second.marker_file = alternate_path
	_check(second.call("_nav_signature") != same_file_key,
		"another source path cannot reuse the first file's cache")
	# An existing nav bake from before endpoint caching must be upgraded once,
	# including when the navmesh itself was loaded successfully from disk.
	second.marker_file = marker_path
	second.navmesh.remove_meta(NavWorld.STITCH_CACHE_META)
	second.call("_nav_cache_save")
	second.free()
	var backfill := _build(map, cache_id, marker_path)
	_check(backfill.cache_hits == 1 and backfill.stitch_cache_hits == 0,
		"legacy nav bake is reused while missing stitch metadata is computed")
	_check(backfill.navmesh.get_vertices() == vertices and _polygons(backfill.navmesh) == polygons,
		"backfilling stitch metadata does not alter navigation geometry")
	var persisted := ResourceLoader.load(paths[0], "NavigationMesh", ResourceLoader.CACHE_MODE_IGNORE) as NavigationMesh
	_check(persisted != null and persisted.has_meta(NavWorld.STITCH_CACHE_META),
		"cache-hit backfill persists metadata to the navigation resource")
	persisted = null
	backfill.free()
	var upgraded := _build(map, cache_id, marker_path)
	_check(upgraded.cache_hits == 1 and upgraded.stitch_cache_hits == 1,
		"the next load reuses both the legacy bake and its newly saved stitch cache")
	upgraded.free()

	# Change size as well as content so invalidation does not depend on the
	# filesystem's timestamp resolution. Re-export a larger walkable surface.
	_write(marker_path, "marker export two with updated geometry")
	plane.size = Vector2(12.0, 12.0)
	var third := _build(map, cache_id, marker_path)
	_check(third.cache_hits == 0, "changed marker export invalidates the saved bake")
	_check(third.source_faces > 0 and third.polygons > 0, "changed source is baked again")
	_check(third.navmesh.get_vertices() != vertices, "rebake uses the updated marker geometry")
	third.free()
	map.free()
	for path in paths + [marker_path, alternate_path]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("NAV_MARKER_CACHE_TEST %s failures=%d" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)
