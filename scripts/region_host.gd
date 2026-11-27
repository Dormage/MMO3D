@tool
extends Node3D
## Hosts exactly one region and forwards the small API the rest of the game
## expects from the Map node.
##
## game_controller binds to "Map" in _ready(), so this node has to exist and
## already contain the region's meshes by then.  Child _ready() runs before the
## parent's, and region_map._load_region() is synchronous, so the terrain is in
## the tree in time for the navmesh bake.
##
## In the editor this instantiates the region too, which is what makes the map
## visible without pressing Play.

var region: Node3D


func _ready() -> void:
	_spawn_region()


func _spawn_region() -> void:
	for old in get_children():
		if old is Node3D:
			old.free()
	region = null
	var scene_path := ""
	if Engine.is_editor_hint():
		# Autoloads are live in the editor, but fall back so a class-name clash
		# during a reload does not leave the viewport blank.
		scene_path = _editor_scene_path()
	else:
		scene_path = RegionState.current_scene()
	if scene_path.is_empty():
		push_warning("region_host: no region scene selected")
		return
	var ps := load(scene_path) as PackedScene
	if ps == null:
		push_error("region_host: cannot load %s" % scene_path)
		return
	region = ps.instantiate() as Node3D
	region.name = "Region"
	add_child(region)
	if not Engine.is_editor_hint():
		print("REGION_HOST mounted %s" % scene_path.get_file())


func _editor_scene_path() -> String:
	# Prefer whatever the registry points at; the first entry is the town.
	if Engine.has_singleton("RegionState"):
		pass
	var reg := get_node_or_null("/root/RegionState")
	if reg != null and reg.has_method("current_scene"):
		var p := String(reg.call("current_scene"))
		if not p.is_empty():
			return p
	return "res://scenes/region_town.tscn"


## --- Forwarded region API ------------------------------------------------

func spawn_point() -> Vector3:
	if region != null and region.has_method("spawn_point"):
		return region.call("spawn_point")
	return Vector3.ZERO


func nav_layout_path() -> String:
	if region != null and region.has_method("nav_layout_path"):
		return region.call("nav_layout_path")
	return ""


func region_id() -> String:
	if region != null and region.has_method("region_id"):
		return String(region.get("region_id"))
	return ""


func region_label() -> String:
	if region != null and region.has_method("region_label"):
		return String(region.call("region_label"))
	return "Region"
