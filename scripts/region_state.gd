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

var regions: Array = []
var current := 0


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
	if index < 0 or index >= regions.size() or index == current:
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
