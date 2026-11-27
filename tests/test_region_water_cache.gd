extends SceneTree
## godot --headless --path . --script res://tests/test_region_water_cache.gd
## Exercises the real conditioned-region load/save branches with tiny meshes.
## No map GLBs, navigation bake, or imported textures are needed.

const RegionMap := preload("res://scripts/region_map.gd")
const NavWorld := preload("res://scripts/nav_world.gd")
const META := "_mmo3d_water_state"
const GRID_CELLS := 163 * 163

var _checks := 0
var _failures := 0
var _completed := false
var _deadline_ms := 0
var _cleanup_paths: Array[String] = []


class RegionProbe extends RegionMap:
	var measurements := 0
	var bakes := 0
	var measured_level := 0.0
	var generated_before: Dictionary = {}

	func _ready() -> void:
		# The regression explicitly invokes only the actual region load path.
		pass

	func _measure_water(node: Node) -> void:
		super._measure_water(node)
		measurements += 1
		measured_level = _water_level

	func _bake(node: Node3D, paths: Array[String]) -> void:
		bakes += 1
		super._bake(node, paths)

	func _prepare_water_cache(node: Node3D) -> void:
		var extension := get_node_or_null("WaterExtension") as MeshInstance3D
		var barrier := get_node_or_null("WaterBarrier") as StaticBody3D
		if extension != null and barrier != null:
			var shape := barrier.get_child(0) as CollisionShape3D
			generated_before = {"extension_transform": extension.global_transform,
				"barrier_transform": barrier.global_transform, "shape_transform": shape.global_transform,
				"extension_faces": extension.mesh.get_faces(),
				"barrier_faces": (shape.shape as ConcavePolygonShape3D).get_faces()}
		super._prepare_water_cache(node)


func _init() -> void:
	_deadline_ms = Time.get_ticks_msec() + 15000
	_run.call_deferred()


func _process(_delta: float) -> bool:
	if not _completed and Time.get_ticks_msec() > _deadline_ms:
		push_error("water-cache regression stopped before completing its assertions")
		_cleanup()
		quit(1)
	return false


func _check(ok: bool, description: String) -> void:
	_checks += 1
	if not ok:
		push_error("FAIL: " + description)
		_failures += 1


func _run() -> void:
	if OS.get_cmdline_user_args().has("--rebake"):
		push_error("omit --rebake: this regression must exercise real cache hits")
		quit(1)
		return
	var stamp := str(OS.get_process_id())
	_test_wet_region("test_water_wet_" + stamp)
	_test_dry_region("test_water_dry_" + stamp)
	_test_invalid_metadata()
	_cleanup()
	_completed = true
	print("REGION_WATER_CACHE_TEST failures=%d checks=%d complete=%s" % [
		_failures, _checks, _completed])
	quit(0 if _failures == 0 else 1)


func _region(source_path: String, id: String) -> RegionProbe:
	var region := RegionProbe.new()
	region.name = "WaterCacheProbe"
	region.region_id = id
	region.glb_path = source_path
	region.generate_render_lods = false
	region.wind_enabled = false
	region.shorten_fences_at_stone = false
	region.bridge_rules = []
	region.outlier_limit = 0.0
	region.water_extend_enabled = true
	region.water_extend_scale = 4.0
	region.water_extend_cells = 0
	region.water_wall_enabled = true
	# Nonidentity ancestors catch reparenting that changes world geometry.
	region.transform = Transform3D(Basis(Vector3.UP, 0.23), Vector3(3, 0, -5))
	root.add_child(region)
	return region


func _test_wet_region(id: String) -> void:
	var source_path := _save_source(id, true)
	var cold := _region(source_path, id)
	var paths: Array[String] = cold._cache_paths()
	_cleanup_paths.append_array(paths)
	cold._load_region()
	_check(cold.measurements == 1 and cold.bakes == 1, "cold load measures and conditions the source once")
	_check(cold._has_water, "authored wet region is recognized")
	_check(is_equal_approx(cold.measured_level, 0.05), "fixture reproduces the original 5 cm measurement")
	_check(is_equal_approx(cold._water_level, 0.0), "conditioning finalizes the existing gameplay waterline at zero")
	_check(_wet_cells(cold._water_cells) > 0 and _wet_cells(cold._water_cells) < 100,
		"authored water has a small nonempty footprint")
	var expected := _snapshot(cold)
	var expected_nav := _nav_signature(cold)
	var world := cold.get_node_or_null("RegionWorld") as Node3D
	_check(world != null and world.has_meta(META), "conditioned subtree carries finalized water metadata")
	_check(FileAccess.file_exists(paths[0]) and FileAccess.file_exists(paths[1]),
		"real region bake writes both scene and identity key")
	_check_generated_children(cold, expected, "cold")
	# Measuring conditioned visuals is specifically the old, incorrect reload.
	var raw_probe := RegionProbe.new()
	raw_probe._measure_water(world)
	_check(is_equal_approx(raw_probe._water_level, 0.05), "remeasuring conditioned visuals would regress to 5 cm")
	_check(raw_probe._water_cells == cold._water_cells,
		"expanded visual plane does not replace the original authored footprint")
	raw_probe.free()
	cold.free()

	var warm := _region(source_path, id)
	warm._load_region()
	_check(warm.measurements == 0 and warm.bakes == 0, "warm load restores metadata without measuring or rebaking")
	_check_state(warm, expected, "warm")
	_check(_nav_signature(warm) == expected_nav, "cold and warm gameplay inputs produce the identical navigation cache key")
	_check_generated_children(warm, expected, "warm")
	warm.free()

	# A cache missing the new state must take the authoritative cold branch.
	_damage_cache(paths[0], null)
	var legacy := _region(source_path, id)
	legacy._load_region()
	_check(legacy.measurements == 1 and legacy.bakes == 1,
		"missing water metadata forces a fresh source load and replaces the stale cache")
	_check_state(legacy, expected, "legacy fallback")
	_check_generated_children(legacy, expected, "legacy fallback")
	legacy.free()

	_damage_cache(paths[0], {"version": 1, "has_water": true, "level": 0.0,
		"cells": PackedByteArray([1])})
	var damaged := _region(source_path, id)
	damaged._load_region()
	_check(damaged.measurements == 1 and damaged.bakes == 1,
		"malformed water metadata also rebuilds from the source")
	_check_state(damaged, expected, "malformed fallback")
	_check_generated_children(damaged, expected, "malformed fallback")
	damaged.free()

	var repaired := _region(source_path, id)
	repaired._load_region()
	_check(repaired.measurements == 0 and repaired.bakes == 0,
		"the corrected cache is reusable after malformed-state recovery")
	_check_state(repaired, expected, "repaired cache")
	repaired.free()


func _test_dry_region(id: String) -> void:
	var source_path := _save_source(id, false)
	var cold := _region(source_path, id)
	_cleanup_paths.append_array(cold._cache_paths())
	cold._load_region()
	var expected := _snapshot(cold)
	_check(not cold._has_water and is_zero_approx(cold._water_level), "dry cold load has no water")
	_check(cold._water_cells.size() == GRID_CELLS and _wet_cells(cold._water_cells) == 0,
		"dry cold load has an initialized empty footprint")
	_check(cold.find_children("WaterExtension", "", true, false).is_empty()
		and cold.find_children("WaterBarrier", "", true, false).is_empty(),
		"dry maps create no generated water plane or wall")
	cold.free()
	var warm := _region(source_path, id)
	# Ensure restoration overwrites all state, including the false/zero case.
	warm._has_water = true
	warm._water_level = 12.0
	warm._water_cells = PackedByteArray([1])
	warm._load_region()
	_check(warm.measurements == 0 and warm.bakes == 0, "dry state also takes the real cache-hit branch")
	_check_state(warm, expected, "dry warm")
	warm.free()


func _test_invalid_metadata() -> void:
	var region := RegionProbe.new()
	var world := Node3D.new()
	var empty := PackedByteArray()
	empty.resize(GRID_CELLS)
	empty.fill(0)
	var valid := {"version": 1, "has_water": false, "level": 0.0, "cells": empty}
	var invalid_cells := empty.duplicate()
	invalid_cells[100] = 2
	var cases: Array = [null, "wrong type", {},
		{"version": 2, "has_water": false, "level": 0.0, "cells": empty},
		{"version": 1, "has_water": "false", "level": 0.0, "cells": empty},
		{"version": 1, "has_water": false, "level": NAN, "cells": empty},
		{"version": 1, "has_water": false, "level": INF, "cells": empty},
		{"version": 1, "has_water": false, "level": "zero", "cells": empty},
		{"version": 1, "has_water": false, "level": 0.0, "cells": []},
		{"version": 1, "has_water": false, "level": 0.0, "cells": invalid_cells},
		{"version": 1, "has_water": false, "level": 0.0, "cells": PackedByteArray([0])}]
	for item in cases:
		if item == null:
			world.remove_meta(META)
		else:
			world.set_meta(META, item)
		region._has_water = true
		region._water_level = 7.5
		region._water_cells = PackedByteArray([1, 0, 1])
		_check(not region._restore_water_state(world), "invalid metadata is rejected")
		_check(region._has_water and region._water_level == 7.5
			and region._water_cells == PackedByteArray([1, 0, 1]),
			"invalid metadata never partially changes gameplay water state")
	world.set_meta(META, valid)
	_check(region._restore_water_state(world), "valid empty state restores successfully")
	_check(not region._has_water and region._water_level == 0.0 and region._water_cells == empty,
		"valid empty state replaces previous wet state completely")
	world.free()
	region.free()


func _save_source(id: String, wet: bool) -> String:
	var world := Node3D.new()
	world.name = "SyntheticWaterWorld"
	world.transform = Transform3D(Basis(Vector3.UP, -0.37).scaled(Vector3(1.3, 1, 0.8)),
		Vector3(-2, 0, 4))
	var mesh := MeshInstance3D.new()
	mesh.name = "AuthoredWater" if wet else "DryGround"
	var geometry := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-2, 0.04, -2), Vector3(2, 0.04, -2),
		Vector3(2, 0.04, 2), Vector3(-2, 0.04, 2)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	geometry.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.resource_name = "M_water" if wet else "M_ground"
	geometry.surface_set_material(0, material)
	mesh.mesh = geometry
	world.add_child(mesh)
	mesh.owner = world
	var path := "user://%s_source.scn" % id
	var packed := PackedScene.new()
	_check(packed.pack(world) == OK and ResourceSaver.save(packed, path) == OK,
		"synthetic source scene saves")
	_cleanup_paths.append(path)
	world.free()
	return path


func _snapshot(region: RegionProbe) -> Dictionary:
	var extension := region.find_child("WaterExtension", true, false) as MeshInstance3D
	var barrier := region.find_child("WaterBarrier", true, false) as StaticBody3D
	var result := {"has_water": region._has_water, "level": region._water_level,
		"cells": region._water_cells.duplicate()}
	if extension != null:
		result["extension_transform"] = extension.global_transform
		result["extension_faces"] = extension.mesh.get_faces()
		result["extension_shadows"] = extension.cast_shadow
	if barrier != null:
		result["barrier_transform"] = barrier.global_transform
		result["barrier_layer"] = barrier.collision_layer
		result["barrier_mask"] = barrier.collision_mask
		var shape := barrier.get_child(0) as CollisionShape3D
		result["barrier_faces"] = (shape.shape as ConcavePolygonShape3D).get_faces()
		result["shape_transform"] = shape.global_transform
	return result


func _check_state(region: RegionProbe, expected: Dictionary, label: String) -> void:
	_check(region._has_water == expected.has_water, label + " retains water presence")
	_check(is_equal_approx(region._water_level, expected.level), label + " retains finalized gameplay water level")
	_check(region._water_cells == expected.cells, label + " retains every authored footprint cell")


func _check_generated_children(region: RegionProbe, expected: Dictionary, label: String) -> void:
	var world := region.get_node_or_null("RegionWorld") as Node3D
	var extensions := region.find_children("WaterExtension", "MeshInstance3D", true, false)
	var barriers := region.find_children("WaterBarrier", "StaticBody3D", true, false)
	_check(extensions.size() == 1 and barriers.size() == 1,
		label + " has exactly one generated visual plane and collision wall")
	if extensions.size() != 1 or barriers.size() != 1:
		return
	var extension := extensions[0] as MeshInstance3D
	var barrier := barriers[0] as StaticBody3D
	_check(extension.get_parent() == world and extension.owner == world,
		label + " visual extension belongs to the serialized subtree")
	_check(barrier.get_parent() == world and barrier.owner == world and barrier.get_child(0).owner == world,
		label + " wall and collision shape belong to the serialized subtree")
	_check(not region._others.has(extension) and not region._grounds.has(extension)
		and not region._solids.has(extension), label + " generated plane stays outside authored collision roles")
	var actual := _snapshot(region)
	_check(actual.extension_transform.is_equal_approx(expected.extension_transform)
		and actual.barrier_transform.is_equal_approx(expected.barrier_transform)
		and actual.shape_transform.is_equal_approx(expected.shape_transform),
		label + " generated world transforms survive reparenting and serialization")
	_check(actual.extension_faces == expected.extension_faces and actual.barrier_faces == expected.barrier_faces,
		label + " generated visual and collision geometry is identical")
	_check(actual.extension_shadows == expected.extension_shadows
		and actual.barrier_layer == expected.barrier_layer and actual.barrier_mask == expected.barrier_mask,
		label + " generated rendering and collision roles are unchanged")
	if not region.generated_before.is_empty():
		var before := region.generated_before
		_check(actual.extension_transform.is_equal_approx(before.extension_transform)
			and actual.barrier_transform.is_equal_approx(before.barrier_transform)
			and actual.shape_transform.is_equal_approx(before.shape_transform),
			label + " moving generated children into the cache preserves their original world transforms")
		_check(actual.extension_faces == before.extension_faces and actual.barrier_faces == before.barrier_faces,
			label + " cache preparation preserves the original generated vertex data")


func _nav_signature(region: RegionProbe) -> String:
	var nav := NavWorld.new()
	nav.cache_id = region.region_id
	nav.source_faces = 2
	nav.has_water = region._has_water
	nav.water_level = region._water_level
	nav.supplied_water = region._water_cells
	var signature: String = nav._nav_signature()
	nav.free()
	return signature


func _wet_cells(cells: PackedByteArray) -> int:
	var count := 0
	for cell in cells:
		if cell != 0:
			count += 1
	return count


func _damage_cache(path: String, metadata: Variant) -> void:
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	_check(packed != null, "conditioned scene is available for legacy/corruption fixture")
	if packed == null:
		return
	var world := packed.instantiate()
	if metadata == null:
		world.remove_meta(META)
	else:
		world.set_meta(META, metadata)
	var changed := PackedScene.new()
	_check(changed.pack(world) == OK and ResourceSaver.save(changed, path) == OK,
		"legacy/corrupt cache fixture saves without changing the source identity key")
	world.free()


func _cleanup() -> void:
	for path in _cleanup_paths:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
