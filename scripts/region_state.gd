extends Node
## Region registry and current selection, shared across scene reloads.
##
## Lives in autoload so a region switch can be expressed as "set the index,
## reload the game scene".  Everything else -- collision, navmesh, player,
## camera -- then rebuilds from scratch, which is why switching cannot leave
## a stale navigation map behind.
##
## The registry is data: add region 3..9 to data/regions.json and this, the
## HUD and the switch key all pick it up with no code change.

const REGISTRY := "res://data/regions.json"

signal changed(index: int, id: String)
signal transition_started()
signal transition_finished()
signal transition_failed(error: int)

var regions: Array = []
var current := 0
var transition_in_progress := false


func _ready() -> void:
	_load_registry()
	# Allow launching straight into a region: godot -- --region=island
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--region="):
			if not select_by_id(arg.substr("--region=".length())):
				push_warning("RegionState: no region id '%s'" % arg.substr(9))
	print("REGION_STATE regions=%d current=%d(%s)" % [
		regions.size(), current, current_id()])


func _load_registry() -> void:
	if not FileAccess.file_exists(REGISTRY):
		push_error("RegionState: %s missing" % REGISTRY)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(REGISTRY))
	if not (parsed is Dictionary) or not parsed.has("regions"):
		push_error("RegionState: %s is not a valid registry" % REGISTRY)
		return
	regions = parsed["regions"]
	if regions.is_empty():
		push_error("RegionState: registry lists no regions")


func count() -> int:
	return regions.size()


func current_id() -> String:
	if current < 0 or current >= regions.size():
		return ""
	return String(regions[current].get("id", ""))


func current_name() -> String:
	if current < 0 or current >= regions.size():
		return "Unknown Region"
	var r: Dictionary = regions[current]
	return String(r.get("name", r.get("id", "Region")))


func current_scene() -> String:
	if current < 0 or current >= regions.size():
		push_error("RegionState: current index %d out of range" % current)
		return ""
	return String(regions[current].get("scene", ""))


func index_of(id: String) -> int:
	for i in regions.size():
		if String(regions[i].get("id", "")) == id:
			return i
	return -1


func select(index: int) -> bool:
	if transition_in_progress or index < 0 or index >= regions.size() or index == current:
		return false
	current = index
	changed.emit(current, current_id())
	return true


func select_by_id(id: String) -> bool:
	var i := index_of(id)
	return select(i) if i >= 0 else false


## Advance through the registry, wrapping at both ends.
func cycle(step: int = 1) -> bool:
	if regions.size() < 2:
		return false
	var n := regions.size()
	return select(((current + step) % n + n) % n)


## Own the transition here: this autoload survives removal of the Game scene.
## The optional path also lets lightweight fixtures exercise the real lifecycle.
func reload_game_scene(scene_path: String = "res://game.tscn") -> bool:
	if transition_in_progress:
		return false
	# Reject an invalid target before removing the currently playable scene.
	if not ResourceLoader.exists(scene_path, "PackedScene"):
		push_warning("RegionState: transition scene is missing: %s" % scene_path)
		transition_failed.emit(ERR_FILE_NOT_FOUND)
		return false
	var next_scene := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	if next_scene == null:
		push_warning("RegionState: cannot load transition scene: %s" % scene_path)
		transition_failed.emit(ERR_CANT_OPEN)
		return false
	# Set the guard before deferring, so repeated input cannot change the selected
	# region or queue a second teardown during the remainder of this frame.
	transition_in_progress = true
	transition_started.emit()
	_reload_two_step.call_deferred(next_scene)
	return true


func _reload_two_step(next_scene: PackedScene) -> void:
	var tree := get_tree()
	if tree.current_scene != null:
		tree.unload_current_scene()
	# Keep the existing separation between outgoing renderer cleanup and
	# incoming scene creation. The waiting coroutine must outlive the old scene.
	await tree.process_frame
	await tree.process_frame
	var error := tree.change_scene_to_packed(next_scene)
	if error != OK:
		transition_in_progress = false
		transition_failed.emit(error)
		push_error("RegionState: scene transition failed (%d)" % error)
		return
	await tree.scene_changed
	transition_in_progress = false
	transition_finished.emit()
	# Game._ready() continues asynchronously after scene_changed; its own
	# readiness guard blocks further switches until its camera and nav are ready.
