extends Node3D
## Spawns a JSON roster of ambient actors into a region.
##
## Attached as a child of a region scene.  It waits for region_map to finish
## building collision, scans the walkable ground into a candidate grid, then
## places each roster entry either scattered across the map or in clusters
## around a handful of district anchors (towns).
##
## The roster is data: glb path, display name, height, radius, speed, wander
## radius, visual scale and foot offset all come from JSON.

@export_file("*.json") var roster_path := "res://data/island_monsters.json"
@export var enabled := true
@export var ground_mask := 1
## Override the JSON values when > 0.
@export var max_actors := 0
@export var min_separation_override := 0.0
@export var keep_clear_override := 0.0
@export var candidate_step_override := 0.0

var _actors: Array[PopulationActor] = []
var _map: Node
var _rng := RandomNumberGenerator.new()
var _data: Dictionary = {}
var _candidates: Array[Vector3] = []


func _ready() -> void:
	if Engine.is_editor_hint() or not enabled:
		return
	# Population waits for collision asynchronously. A one-shot hide in the
	# controller can run before these actors exist, so skip generation here.
	if OS.get_cmdline_user_args().has("--nopop"):
		print("NOPOP skipped_spawner=%s" % name)
		return
	_rng.randomize()
	_map = get_parent()
	await _wait_for_ground()
	_data = _load_roster()
	if _data.is_empty():
		return
	var entries: Array = _data.get("actors", [])
	if entries.is_empty():
		push_error("population_field: roster has no actors")
		return
	_candidates = _collect_candidates()
	if _candidates.is_empty():
		push_error("population_field: no walkable candidates in %s" % roster_path)
		return
	_spawn(entries)
	_report()
	_add_credit_label()
	_handle_debug_args()


func _wait_for_ground() -> void:
	for _i in 240:
		await get_tree().physics_frame
		var centre := _map_spawn_point()
		if not _ground_at(centre.x, centre.z).is_empty():
			return


func _map_spawn_point() -> Vector3:
	if _map != null and _map.has_method("spawn_point"):
		var p: Variant = _map.call("spawn_point")
		if p is Vector3:
			return p
	return Vector3.ZERO


func _load_roster() -> Dictionary:
	if not FileAccess.file_exists(roster_path):
		push_error("population_field: missing roster %s" % roster_path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(roster_path))
	if parsed is Array:
		return {"actors": parsed}
	if parsed is Dictionary:
		return parsed
	push_error("population_field: roster is not JSON")
	return {}


func _ground_at(x: float, z: float, from_y := 90.0, to_y := -70.0) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
			Vector3(x, from_y, z), Vector3(x, to_y, z), ground_mask)
	return space.intersect_ray(query)


func _map_bounds(district: bool = false) -> AABB:
	# Towns use the building footprint, not the terrain plane: the desert map
	# ships a 500 m sand plane around a ~100 m bazaar, and anchoring districts
	# to the terrain bounds would scatter the townsfolk into empty dunes.
	var source: Variant = _map.get("_solids") if district else _map.get("_grounds")
	var out := AABB()
	var first := true
	if source is Array:
		for mi in source:
			if not (mi is MeshInstance3D):
				continue
			var aabb := (mi as MeshInstance3D).get_aabb()
			var xf := (mi as MeshInstance3D).global_transform
			for i in 8:
				var corner := aabb.position + Vector3(
						aabb.size.x if (i & 1) else 0.0,
						aabb.size.y if (i & 2) else 0.0,
						aabb.size.z if (i & 4) else 0.0)
				var w := xf * corner
				if first:
					out = AABB(w, Vector3.ZERO)
					first = false
				else:
					out = out.expand(w)
	if first:
		var s := _map_spawn_point()
		out = AABB(s + Vector3(-40, -20, -40), Vector3(80, 40, 80))
	elif district:
		# The rampart is the real town boundary.  Building AABBs alone can
		# include a gate road or a distant landmark, which is how a few
		# bazaar NPCs ended up outside the gate.
		var wall := _wall_bounds()
		if wall.size != Vector3.ZERO:
			out = wall.grow(-2.0)
		else:
			out = out.grow(float(_data.get("district_padding", 0.0)))
		out = out.expand(_map_spawn_point())
	return out


func _wall_bounds() -> AABB:
	var out := AABB()
	var first := true
	for n in _map.find_children("*", "MeshInstance3D", true, false):
		if not String(n.name).to_lower().contains("rampart"):
			continue
		var mi := n as MeshInstance3D
		var aabb := mi.get_aabb()
		var xf := mi.global_transform
		for i in 8:
			var corner := aabb.position + Vector3(
					aabb.size.x if (i & 1) else 0.0,
					aabb.size.y if (i & 2) else 0.0,
					aabb.size.z if (i & 4) else 0.0)
			var w := xf * corner
			if first:
				out = AABB(w, Vector3.ZERO)
				first = false
			else:
				out = out.expand(w)
	return out


func _collect_candidates() -> Array[Vector3]:
	var district := String(_data.get("placement", "scatter")) == "districts"
	var bounds := _map_bounds(district)
	var step := float(_data.get("candidate_step", 2.0))
	if candidate_step_override > 0.0:
		step = candidate_step_override
	step = maxf(step, 0.8)
	var margin := float(_data.get("spawn_margin", 3.0))
	var top := bounds.end.y + 60.0
	var bottom := bounds.position.y - 40.0
	# In towns, do not accept a floor high above the street: a few roofs are
	# merged into the ground collision and would otherwise strand NPCs on top
	# of buildings.  Scatter placement (the island) keeps its real terrain.
	var street_y := _map_spawn_point().y
	var max_rise := float(_data.get("max_floor_rise", 3.5))
	var out: Array[Vector3] = []
	var z := bounds.position.z + margin
	while z <= bounds.end.z - margin:
		var x := bounds.position.x + margin
		while x <= bounds.end.x - margin:
			var hit := _ground_at(x, z, top, bottom)
			if not hit.is_empty():
				var n: Vector3 = hit.get("normal", Vector3.UP)
				var p: Vector3 = hit.get("position", Vector3.ZERO)
				if n.y >= 0.74 and not _is_water(p) and not _blocked_at(p, 0.55) and _flat_enough(p):
					var too_high := district and p.y > street_y + max_rise
					if not too_high:
						out.append(p)
			x += step
		z += step
	print("POP_CANDIDATES region=%s count=%d bounds=%s step=%.2f" % [
		String(_map.get("region_id")), out.size(), str(bounds), step])
	return out


func _flat_enough(point: Vector3) -> bool:
	# A single centre ray can land on a rock lip or a one-metre ledge.  Sample
	# a small disc so the capsule has a real pad under it; otherwise a tall,
	# narrow monster can wedge itself and report floor=false forever.
	for off in [Vector2(0.75, 0.0), Vector2(-0.75, 0.0), Vector2(0.0, 0.75), Vector2(0.0, -0.75)]:
		var hit := _ground_at(point.x + off.x, point.z + off.y, point.y + 2.0, point.y - 2.5)
		if hit.is_empty():
			return false
		if absf(float(hit.get("position", Vector3.ZERO).y) - point.y) > 0.45:
			return false
		if float(hit.get("normal", Vector3.UP).y) < 0.78:
			return false
	return true


func _blocked_at(point: Vector3, radius: float) -> bool:
	var space := get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = radius
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis(), point + Vector3.UP * 0.60)
	params.collision_mask = 2
	if not space.intersect_shape(params, 1).is_empty():
		return true
	# A low roof/awning over the spot still makes it a bad home.
	var q := PhysicsRayQueryParameters3D.create(
			point + Vector3.UP * 0.1, point + Vector3.UP * 5.0, 2)
	return not space.intersect_ray(q).is_empty()


func _is_water(point: Vector3) -> bool:
	if _map.get("_has_water") != true:
		return false
	var level := float(_map.get("_water_level"))
	if point.y > level + 0.10:
		return false
	var cells: Variant = _map.get("_water_cells")
	if not (cells is PackedByteArray):
		return false
	var arr: PackedByteArray = cells
	if arr.size() != 163 * 163:
		return false
	var i := int(round(point.x + 81.5))
	var j := int(round(point.z + 81.5))
	if i < 0 or j < 0 or i >= 163 or j >= 163:
		return false
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var ii: int = i + dx
			var jj: int = j + dz
			if ii >= 0 and jj >= 0 and ii < 163 and jj < 163 \
					and arr[jj * 163 + ii] != 0:
				return true
	return false


func _spawn(entries: Array) -> void:
	var placement := String(_data.get("placement", "scatter"))
	var min_sep := float(_data.get("min_separation", 2.5))
	var keep_clear := float(_data.get("keep_clear", 4.0))
	if min_separation_override > 0.0:
		min_sep = min_separation_override
	if keep_clear_override > 0.0:
		keep_clear = keep_clear_override
	var wanted := 0
	for e in entries:
		if e is Dictionary:
			wanted += int(e.get("count", 1))
	if max_actors > 0:
		wanted = mini(wanted, max_actors)
	var spots: Array[Vector3] = []
	if placement == "districts":
		spots = _pick_districts(wanted, min_sep, keep_clear)
	else:
		spots = _pick_scatter(wanted, min_sep, keep_clear)

	var idx := 0
	for e in entries:
		if not (e is Dictionary):
			continue
		var entry: Dictionary = e
		var count := int(entry.get("count", 1))
		for i in count:
			if max_actors > 0 and _actors.size() >= max_actors:
				break
			if idx >= spots.size():
				push_warning("population_field: ran out of spots at %s" % entry.get("key", "?"))
				break
			var actor := PopulationActor.new()
			var key := String(entry.get("key", "actor"))
			actor.name = "%s_%d" % [key, i]
			actor.model_path = String(entry.get("glb", ""))
			actor.display_name = String(entry.get("name", key))
			actor.model_height = float(entry.get("height", 1.8))
			actor.body_radius = float(entry.get("radius", 0.4))
			actor.model_scale = float(entry.get("scale", 1.0))
			actor.foot_offset = float(entry.get("foot_offset", 0.0))
			actor.move_speed = float(entry.get("speed", 1.0))
			actor.wander_radius = float(entry.get("wander", 4.0))
			actor.idle_min = float(entry.get("idle_min", 1.6))
			actor.idle_max = float(entry.get("idle_max", 4.5))
			actor.yaw_offset = float(entry.get("yaw_offset", 0.0))
			actor.ground_mask = ground_mask
			actor.emote_chance = float(entry.get("emote_chance", entry.get("attack_chance", 0.0)))
			actor.emote_role = "wave" if entry.has("emote_chance") else "attack"
			if _map.get("_has_water") == true:
				actor.water_level = float(_map.get("_water_level"))
				var cells: Variant = _map.get("_water_cells")
				if cells is PackedByteArray:
					actor.water_cells = cells
			actor.position = spots[idx] + Vector3.UP * 0.05
			actor.rotation.y = _rng.randf() * TAU
			add_child(actor)
			_actors.append(actor)
			idx += 1


func _pick_scatter(count: int, min_sep: float, keep_clear: float) -> Array[Vector3]:
	var centre := _map_spawn_point()
	var pool: Array[Vector3] = []
	for p in _candidates:
		if Vector2(p.x - centre.x, p.z - centre.z).length() >= keep_clear:
			pool.append(p)
	if pool.size() < count:
		pool = _candidates.duplicate()
	_shuffle(pool)
	var chosen: Array[Vector3] = []
	var sep := min_sep
	while chosen.size() < count and sep > 0.7:
		for p in pool:
			if chosen.size() >= count:
				break
			if _too_close(p, chosen, sep):
				continue
			var ok := true
			for c in chosen:
				if p.distance_to(c) < sep:
					ok = false
					break
			if ok:
				chosen.append(p)
		if chosen.size() < count:
			sep *= 0.80
	if chosen.size() < count:
		for p in pool:
			if chosen.size() >= count:
				break
			if not _too_close(p, chosen, 0.9):
				chosen.append(p)
	while chosen.size() < count and not pool.is_empty():
		chosen.append(pool[chosen.size() % pool.size()])
	return chosen


func _pick_districts(count: int, min_sep: float, keep_clear: float) -> Array[Vector3]:
	var bounds := _map_bounds(true)
	var c := bounds.get_center()
	var e := bounds.size * 0.5
	var anchors: Array[Vector3] = [
		c,
		c + Vector3(e.x * 0.45, 0, 0), c + Vector3(-e.x * 0.45, 0, 0),
		c + Vector3(0, 0, e.z * 0.45), c + Vector3(0, 0, -e.z * 0.45),
		c + Vector3(e.x * 0.38, 0, e.z * 0.38), c + Vector3(-e.x * 0.38, 0, e.z * 0.38),
		c + Vector3(e.x * 0.38, 0, -e.z * 0.38), c + Vector3(-e.x * 0.38, 0, -e.z * 0.38),
	]
	var anchor_count := mini(int(_data.get("anchor_count", 8)), anchors.size())
	var spawn := _map_spawn_point()
	var pool: Array[Vector3] = []
	for p in _candidates:
		if Vector2(p.x - spawn.x, p.z - spawn.z).length() >= keep_clear:
			pool.append(p)
	if pool.is_empty():
		pool = _candidates.duplicate()
	var chosen: Array[Vector3] = []
	var per_anchor: Array = []
	for i in anchor_count:
		per_anchor.append([])
	for p in pool:
		for a in anchor_count:
			if Vector2(p.x - anchors[a].x, p.z - anchors[a].z).length() <= maxf(e.x, e.z) * 0.42:
				per_anchor[a].append(p)
	var order: Array[int] = []
	for i in count:
		order.append(i % anchor_count)
	_shuffle(order)
	for a in order:
		if chosen.size() >= count:
			break
		var bucket: Array = per_anchor[a]
		bucket.sort_custom(func(x: Vector3, y: Vector3) -> bool:
			return Vector2(x.x - anchors[a].x, x.z - anchors[a].z).length_squared() \
					< Vector2(y.x - anchors[a].x, y.z - anchors[a].z).length_squared())
		var picked := false
		for p in bucket:
			if not _too_close(p, chosen, min_sep):
				chosen.append(p)
				picked = true
				break
		if not picked:
			# Anchor district is full: fall back to any free candidate.
			for p in pool:
				if not _too_close(p, chosen, min_sep * 0.85):
					chosen.append(p)
					picked = true
					break
		if not picked:
			break
	if chosen.size() < count:
		_shuffle(pool)
		for p in pool:
			if chosen.size() >= count:
				break
			if not _too_close(p, chosen, 1.2):
				chosen.append(p)
	while chosen.size() < count and not pool.is_empty():
		chosen.append(pool[chosen.size() % pool.size()])
	return chosen


func _too_close(p: Vector3, chosen: Array[Vector3], sep: float) -> bool:
	var s2 := sep * sep
	for c in chosen:
		var dx := p.x - c.x
		var dz := p.z - c.z
		if dx * dx + dz * dz < s2:
			return true
	return false


func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func _report() -> void:
	var moved := 0
	var anim_ok := 0
	for a in _actors:
		if a.anim_check().find("MISSING") < 0:
			anim_ok += 1
	print("POPULATION region=%s actors=%d candidates=%d placement=%s anim_ok=%d" % [
		String(_map.get("region_id")), _actors.size(), _candidates.size(),
		String(_data.get("placement", "scatter")), anim_ok])
	for a in _actors:
		print("POP_ACTOR %s | %s" % [a.display_name, a.anim_check()])


func _add_credit_label() -> void:
	# CC BY 3.0 requires visible attribution for the Quaternius and
	# bachosoftdesign rigs.  Small, bottom-right, non-interactive.
	var layer := CanvasLayer.new()
	layer.name = "MobCredits"
	layer.layer = 95
	add_child(layer)
	var label := Label.new()
	label.text = "Mob models: Quaternius, bachosoftdesign \u00b7 CC BY 3.0 \u00b7 poly.pizza"
	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.anchor_top = 1.0
	label.anchor_bottom = 1.0
	label.offset_left = -560.0
	label.offset_right = -14.0
	label.offset_top = -28.0
	label.offset_bottom = -8.0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.88, 0.90, 0.92, 0.62))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.focus_mode = Control.FOCUS_NONE
	layer.add_child(label)


func _handle_debug_args() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	if args.has("--population-report"):
		var timer := Timer.new()
		timer.wait_time = 3.0
		timer.autostart = true
		timer.timeout.connect(func() -> void:
			for a in _actors:
				print("POP_STATE ", a.debug_state()))
		add_child(timer)
	if args.has("--population-check"):
		await get_tree().create_timer(1.0).timeout
		var start: Dictionary = {}
		for a in _actors:
			start[a.name] = a.global_position
		await get_tree().create_timer(8.0).timeout
		var moved := 0
		for a in _actors:
			var d: float = a.global_position.distance_to(start[a.name])
			if d > 0.15:
				moved += 1
			print("POP_MOVE %s dist=%.2f %s" % [a.name, d, a.debug_state()])
		print("POP_CHECK region=%s actors=%d moved=%d anim_ok=%d" % [
			String(_map.get("region_id")), _actors.size(), moved,
			_actors.filter(func(a: PopulationActor) -> bool:
				return a.anim_check().find("MISSING") < 0).size()])
		get_tree().quit()


func actor_count() -> int:
	return _actors.size()
