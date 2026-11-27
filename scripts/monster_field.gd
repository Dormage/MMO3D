extends Node3D
## Spawns the converted monster roster into a region and lets each one wander.
##
## Attached as a child of a region scene.  region_map builds its collision in
## _ready() and only finds a spawn point after a few physics frames, so this node
## waits for the ground to answer a raycast before placing anything.
##
## The roster is data: data/monsters.json lists model, height, speed, wander
## radius, scale and instance count, so adding a monster is a JSON edit.

@export_file("*.json") var roster_path := "res://data/monsters.json"
@export var spawn_radius := 18.0
@export var min_separation := 2.6
@export var keep_clear_radius := 6.0
@export var ground_mask := 1
@export var enabled := true
@export var spawn_center := Vector2(0.0, 0.0)

var _spawned: Array[MonsterActor] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	if Engine.is_editor_hint() or not enabled:
		return
	_rng.randomize()
	await _wait_for_ground()
	_spawn_roster()
	_report()
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	if args.has("--monster-report"):
		_start_debug_report()
	if args.has("--monster-trace"):
		_start_trace()


func _wait_for_ground() -> void:
	# region_map adds its collision bodies in _ready() (which runs after this
	# node's), then waits three physics frames itself.  Poll until a downward ray
	# finds layer 1, with a hard cap so a broken map cannot hang the load.
	for _i in 120:
		await get_tree().physics_frame
		var centre := _map_spawn_point()
		if not _ground_at(centre.x, centre.z).is_empty():
			return


func _map_spawn_point() -> Vector3:
	var parent := get_parent()
	if parent != null and parent.has_method("spawn_point"):
		var p: Variant = parent.call("spawn_point")
		if p is Vector3:
			var v: Vector3 = p
			if v.length() > 0.01:
				return v
	return Vector3(spawn_center.x, 0.0, spawn_center.y)


func _ground_at(x: float, z: float, from_y := 80.0, to_y := -40.0) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var from := Vector3(x, from_y, z)
	var to := Vector3(x, to_y, z)
	var query := PhysicsRayQueryParameters3D.create(from, to, ground_mask)
	return space.intersect_ray(query)


func _clear_at(pos: Vector3, radius: float) -> bool:
	var space := get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = radius
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis(), pos + Vector3.UP * maxf(radius, 0.4))
	params.collision_mask = 2
	return space.intersect_shape(params, 1).is_empty()


func _load_roster() -> Array:
	if not FileAccess.file_exists(roster_path):
		push_error("monster_field: missing roster %s" % roster_path)
		return []
	var text := FileAccess.get_file_as_string(roster_path)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Array:
		return parsed
	if parsed is Dictionary and parsed.has("monsters"):
		return parsed["monsters"]
	push_error("monster_field: roster is not a JSON array")
	return []


func _spawn_roster() -> void:
	var roster := _load_roster()
	if roster.is_empty():
		return
	var centre := _map_spawn_point()
	var placed: Array[Vector3] = []

	for entry in roster:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var key := String(e.get("key", "monster"))
		var count := int(e.get("count", 1))
		for i in count:
			var spot := _find_spot(centre, placed)
			if spot == Vector3.INF:
				push_warning("monster_field: no free ground for %s" % key)
				continue
			var actor := MonsterActor.new()
			actor.name = "%s_%d" % [key, i]
			actor.model_path = String(e.get("glb", ""))
			actor.display_name = String(e.get("name", key))
			actor.model_height = float(e.get("height", 1.8))
			actor.body_radius = float(e.get("radius", 0.5))
			actor.move_speed = float(e.get("speed", 1.2))
			actor.wander_radius = float(e.get("wander", 5.0))
			actor.model_scale = float(e.get("scale", 1.0))
			actor.yaw_offset = float(e.get("yaw_offset", 0.0))
			actor.ground_mask = ground_mask
			actor.position = spot + Vector3.UP * 0.05
			actor.rotation.y = _rng.randf() * TAU
			add_child(actor)
			_spawned.append(actor)
			placed.append(spot)


func _find_spot(centre: Vector3, placed: Array[Vector3]) -> Vector3:
	for _attempt in 40:
		var angle := _rng.randf() * TAU
		var dist := lerpf(keep_clear_radius, spawn_radius, sqrt(_rng.randf()))
		if dist < keep_clear_radius:
			continue
		var x := centre.x + cos(angle) * dist
		var z := centre.z + sin(angle) * dist
		var hit := _ground_at(x, z)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit.get("normal", Vector3.UP)
		if normal.y < 0.72:
			continue
		var point: Vector3 = hit.get("position", Vector3.ZERO)
		if absf(point.y - centre.y) > 6.0:
			continue
		var too_close := false
		for p in placed:
			if p.distance_to(point) < min_separation:
				too_close = true
				break
		if too_close:
			continue
		if not _clear_at(point, 1.0):
			continue
		return point
	return Vector3.INF


func _report() -> void:
	var clip_info := []
	for a in _spawned:
		clip_info.append("%s@%s" % [a.name, a.debug_clips()])
	print("MONSTERS spawned=%d centre=%s %s" % [_spawned.size(), _map_spawn_point(), ", ".join(PackedStringArray(clip_info))])


func _start_debug_report() -> void:
	var timer := Timer.new()
	timer.wait_time = 3.0
	timer.autostart = true
	timer.timeout.connect(func() -> void:
		for a in _spawned:
			print("MONSTER_STATE ", a.debug_state()))
	add_child(timer)


func _start_trace() -> void:
	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(func() -> void:
		for a in _spawned:
			if a.name.begins_with("monster02") or a.name.begins_with("wolf") or a.name.begins_with("catfish"):
				print("TRACE ", a.debug_anim(), " pos=", a.global_position.snapped(Vector3(0.1, 0.1, 0.1))))
	add_child(timer)


func monster_count() -> int:
	return _spawned.size()
