extends SceneTree
## godot --headless --path . --script tests/test_nav_stitch_cache.gd
## Small synthetic islands; no world assets, Recast bake, or real-time waits.

const NavWorld := preload("res://scripts/nav_world.gd")
const META := "_mmo3d_stitch_cache"
var _checks := 0
var _failures := 0
var _completed := false
var _deadline_ms := 0


class CacheProbe extends NavWorld:
	var hits := 0
	var misses := 0

	func _load_stitch_cache(signature: String) -> bool:
		var hit := super._load_stitch_cache(signature)
		if hit:
			hits += 1
		else:
			misses += 1
		return hit


func _initialize() -> void:
	_deadline_ms = Time.get_ticks_msec() + 10000
	call_deferred("_run")


func _process(_delta: float) -> bool:
	if not _completed and Time.get_ticks_msec() > _deadline_ms:
		push_error("stitch-cache regression stopped before completing its assertions")
		quit(1)
	return false


func _run() -> void:
	if OS.get_cmdline_user_args().has("--no-stitch-cache"):
		push_error("omit --no-stitch-cache: this regression must exercise cache hits")
		quit(1)
		return
	var first := _probe(_mesh())
	first._stitch_islands()
	var exact := _snapshot(first)
	_check(first.misses == 1 and first.hits == 0, "first build computes links")
	_check(exact.size() == 2, "three synthetic islands need two ordered links")
	if exact.size() == 2:
		_check(exact[0].start == Vector3(2.5, 0, 0) and exact[0].end == Vector3(2, 0, 0),
				"first cold endpoint pair matches the independent fixture geometry")
		_check(exact[1].start == Vector3(5, 0, 0) and exact[1].end == Vector3(4.5, 0, 0),
				"second cold endpoint pair follows the newly connected island")
		_check(exact[0].name == "NavStitch0" and exact[1].name == "NavStitch1",
				"link names preserve creation order")
		_check(exact[0].bidirectional and exact[1].bidirectional, "links remain bidirectional")
	var metadata: Dictionary = first.navmesh.get_meta(META).duplicate(true)
	var signature: String = first._stitch_signature(first.navmesh.get_vertices())
	_check(metadata.endpoints is PackedVector3Array and metadata.endpoints.size() == 4,
			"only ordered endpoint pairs are stored")
	_check(first._stitch_cache_dirty, "fresh computed metadata is marked for persistence")
	var serialized := "user://test_nav_stitch_%d.res" % OS.get_process_id()
	_check(ResourceSaver.save(first.navmesh, serialized) == OK, "NavigationMesh with link metadata saves")
	var original_resource := first.navmesh
	first.free()
	var loaded := ResourceLoader.load(serialized, "NavigationMesh", ResourceLoader.CACHE_MODE_IGNORE) as NavigationMesh
	_check(loaded != null and loaded != original_resource, "round trip creates a separately deserialized resource")
	if loaded == null:
		_finish()
		return
	_check(loaded.get_meta(META) == metadata, "serialized metadata preserves exact endpoint sequence")
	var warm := _probe(loaded)
	warm._stitch_islands()
	_check(warm.hits == 1 and warm.misses == 0, "deserialized endpoints are reused")
	_check(_snapshot(warm) == exact, "cached links preserve order, names, endpoints and all link flags exactly")
	_check(not warm._stitch_cache_dirty, "cache reuse does not request a rewrite")
	warm.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(serialized))

	# Same counts are insufficient: vertex contents and polygon indices both
	# influence the exact ordered output of the connectivity search.
	var moved_mesh := _with_metadata(_mesh(), metadata)
	var moved_vertices := moved_mesh.get_vertices()
	moved_vertices[6].x += 0.125
	moved_mesh.set_vertices(moved_vertices)
	var moved := _probe(moved_mesh)
	_check(moved.navmesh.get_polygon_count() == 4 and moved.navmesh.get_vertices().size() == 13,
			"changed-position fixture keeps polygon/vertex counts")
	_check(moved._stitch_signature(moved_vertices) != signature, "vertex coordinates invalidate the signature")
	moved._stitch_islands()
	_check(moved.misses == 1 and moved.hits == 0, "changed coordinates reject cached endpoints")
	_check(_snapshot(moved) != exact, "recomputed endpoints use the changed geometry")
	moved.free()
	var indexed_mesh := _with_metadata(_mesh(), metadata)
	var altered := _polygons(indexed_mesh)
	altered[3] = PackedInt32Array([7, 11, 12])
	_replace_polygons(indexed_mesh, altered)
	var indexed := _probe(indexed_mesh)
	_check(indexed._stitch_signature(indexed.navmesh.get_vertices()) != signature,
			"polygon indices invalidate the signature even with identical vertices/counts")
	indexed._stitch_islands()
	_check(indexed.misses == 1 and _snapshot(indexed) != exact, "changed polygon connectivity recomputes links")
	indexed.free()
	var boundaries := _mesh()
	var repartitioned := _polygons(boundaries)
	repartitioned[0] = PackedInt32Array([0, 1, 4])
	repartitioned[1] = PackedInt32Array([3, 1, 2, 5, 4])
	_replace_polygons(boundaries, repartitioned)
	var partition_probe := _probe(boundaries)
	_check(partition_probe._stitch_signature(boundaries.get_vertices()) != signature,
			"polygon boundaries are encoded, not only concatenated indices")
	partition_probe.free()

	var water := PackedByteArray()
	water.resize(NavWorld.GRID * NavWorld.GRID)
	water.fill(0)
	water[int(round(NavWorld.HALF)) * NavWorld.GRID + int(round(2.25 + NavWorld.HALF))] = 1
	var wet := _probe(_with_metadata(_mesh(), metadata), water)
	wet._stitch_islands()
	_check(wet.misses == 1 and wet.hits == 0, "water-mask contents invalidate dry-land endpoints")
	_check(_snapshot(wet).is_empty(), "water veto removes the first link and disconnected continuation")
	var wet_metadata: Dictionary = wet.navmesh.get_meta(META).duplicate(true)
	wet.free()
	var wet_again := _probe(_with_metadata(_mesh(), wet_metadata), water)
	wet_again._stitch_islands()
	_check(wet_again.hits == 1 and _snapshot(wet_again).is_empty(), "a computed empty link set is a valid cache hit")
	wet_again.free()
	var bridged := _probe(_with_metadata(_mesh(), wet_metadata), water)
	bridged._bridge_segs = [[Vector2(2, 0), Vector2(3, 0)]]
	bridged._stitch_islands()
	_check(bridged.misses == 1 and bridged.hits == 0, "bridge bypass segments invalidate water-veto results")
	_check(_snapshot(bridged) == exact, "bridge bypass restores the original exact links over water")
	var bridge_metadata: Dictionary = bridged.navmesh.get_meta(META).duplicate(true)
	bridged.free()
	var remote_bridge := _probe(_with_metadata(_mesh(), bridge_metadata), water)
	remote_bridge._bridge_segs = [[Vector2(100, 100), Vector2(101, 100)]]
	remote_bridge._stitch_islands()
	_check(remote_bridge.misses == 1 and _snapshot(remote_bridge).is_empty(), "moving bridge segments cannot reuse a stale bypass")
	remote_bridge.free()

	var short_gap := _probe(_with_metadata(_mesh(), metadata))
	short_gap.stitch_max_gap = 0.4
	short_gap._stitch_islands()
	_check(short_gap.misses == 1 and _snapshot(short_gap).is_empty(), "gap limit invalidates endpoints and changes allowed links")
	short_gap.free()
	var raised := _probe(_mesh(0.4))
	raised._stitch_islands()
	_check(_snapshot(raised).size() == 2, "raised fixture is connected at the default rise limit")
	var raised_mesh := raised.navmesh
	raised.free()
	var low_rise := _probe(raised_mesh)
	low_rise.stitch_max_rise = 0.1
	low_rise._stitch_islands()
	_check(low_rise.misses == 1 and _snapshot(low_rise).is_empty(), "rise limit invalidates cached elevated links")
	low_rise.free()
	var precise := _probe(_mesh())
	precise.stitch_max_gap += 0.000001
	_check(precise._stitch_signature(precise.navmesh.get_vertices()) != signature,
			"small gap changes are not lost to formatted/rounded signatures")
	precise.stitch_max_gap = 1.3
	precise.stitch_max_rise += 0.000001
	_check(precise._stitch_signature(precise.navmesh.get_vertices()) != signature,
			"small rise changes are not lost to formatted/rounded signatures")
	precise.free()

	# Invalid entries must be rejected before ANY nodes are added. A valid first
	# pair followed by an invalid pair catches partial-application regressions.
	var malformed: Array = [[], {}, {"signature": "old-algorithm"}]
	for kind in ["missing_endpoints", "wrong_endpoint_type", "odd_endpoint_count", "nonfinite", "bad_parts",
			"zero_parts", "excess_parts", "bad_unreached", "wrong_unreached_type", "excess_unreached", "excess_links"]:
		var bad := metadata.duplicate(true)
		match kind:
			"missing_endpoints": bad.erase("endpoints")
			"wrong_endpoint_type": bad.endpoints = [Vector3.ZERO, Vector3.ONE]
			"odd_endpoint_count": bad.endpoints = PackedVector3Array([Vector3.ZERO])
			"nonfinite": bad.endpoints = PackedVector3Array([Vector3.ZERO, Vector3.ONE, Vector3.ZERO, Vector3(INF, 0, 0)])
			"bad_parts": bad.parts = "3"
			"zero_parts": bad.parts = 0
			"excess_parts": bad.parts = 5
			"bad_unreached": bad.unreached = -1
			"wrong_unreached_type": bad.unreached = "0"
			"excess_unreached": bad.unreached = 1
			"excess_links": bad.endpoints = metadata.endpoints + metadata.endpoints
		malformed.append(bad)
	for bad in malformed:
		var damaged := _probe(_mesh())
		damaged.navmesh.set_meta(META, bad)
		_check(not damaged._load_stitch_cache(signature), "malformed cache is rejected")
		_check(_snapshot(damaged).is_empty(), "malformed cache never leaves partially created links")
		damaged._stitch_islands()
		_check(_snapshot(damaged) == exact and damaged._stitch_cache_dirty,
				"malformed cache falls back to exact computation and replaces metadata")
		damaged.free()
	var single_mesh := NavigationMesh.new()
	single_mesh.set_vertices(PackedVector3Array([Vector3.ZERO, Vector3(1, 0, 0), Vector3(0, 0, 1)]))
	single_mesh.add_polygon(PackedInt32Array([0, 1, 2]))
	var single := _probe(single_mesh)
	single._stitch_islands()
	_check(single.misses == 1 and _snapshot(single).is_empty(), "single-island result is stored")
	single.free()
	var single_again := _probe(single_mesh)
	single_again._stitch_islands()
	_check(single_again.hits == 1 and _snapshot(single_again).is_empty(), "single island reuses its empty link set")
	single_again.free()
	_completed = true
	_finish()


func _probe(mesh: NavigationMesh, water := PackedByteArray()) -> CacheProbe:
	var nav := CacheProbe.new()
	nav.navmesh = mesh
	nav.polygons = mesh.get_polygon_count()
	nav.vertices = mesh.get_vertices().size()
	nav.supplied_water = water
	root.add_child(nav)
	return nav


func _mesh(rise := 0.0) -> NavigationMesh:
	# Six-vertex mainland, four-vertex second island, three-vertex third island.
	# Unequal component sizes avoid relying on tie-breaking between equal parts.
	var mesh := NavigationMesh.new()
	mesh.set_vertices(PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(2, 0, 0),
		Vector3(0, 0, 2), Vector3(1, 0, 2), Vector3(2, 0, 2),
		Vector3(2.5, rise, 0), Vector3(4.5, rise, 0), Vector3(4.5, rise, 2), Vector3(2.5, rise, 2),
		Vector3(5, rise, 0), Vector3(6, rise, 0), Vector3(5, rise, 1)]))
	mesh.add_polygon(PackedInt32Array([0, 1, 4, 3]))
	mesh.add_polygon(PackedInt32Array([1, 2, 5, 4]))
	mesh.add_polygon(PackedInt32Array([6, 7, 8, 9]))
	mesh.add_polygon(PackedInt32Array([10, 11, 12]))
	return mesh


func _with_metadata(mesh: NavigationMesh, metadata: Dictionary) -> NavigationMesh:
	mesh.set_meta(META, metadata.duplicate(true))
	return mesh


func _polygons(mesh: NavigationMesh) -> Array[PackedInt32Array]:
	var result: Array[PackedInt32Array] = []
	for i in mesh.get_polygon_count():
		result.append(mesh.get_polygon(i))
	return result


func _replace_polygons(mesh: NavigationMesh, indices: Array[PackedInt32Array]) -> void:
	mesh.clear_polygons()
	for polygon in indices:
		mesh.add_polygon(polygon)


func _snapshot(nav: Node3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for child in nav.get_children():
		if child is NavigationLink3D:
			var link := child as NavigationLink3D
			result.append({"name": String(link.name), "start": link.start_position,
				"end": link.end_position, "bidirectional": link.bidirectional,
				"enabled": link.enabled, "layers": link.navigation_layers,
				"enter_cost": link.enter_cost, "travel_cost": link.travel_cost})
	return result


func _check(ok: bool, description: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(description)


func _finish() -> void:
	if not _completed and _failures == 0:
		_failures += 1
	print("NAV_STITCH_CACHE_TEST checks=%d failures=%d complete=%s" % [_checks, _failures, _completed])
	quit(0 if _completed and _failures == 0 else 1)
