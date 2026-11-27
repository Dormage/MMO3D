extends "res://tools/perf_benchmark.gd"
## Exercise real Tab input, full scene replacement, rendering, and movement.
## Run after the normal editor import; LFS assets must be present.
##   godot --path . --script tools/region_switch_benchmark.gd -- --region=town --nopop
##   godot --headless --path . --script tools/region_switch_benchmark.gd -- --region=town --nopop
## Optional: --switch-steps=-1,1 (Tab, then Shift+Tab), --switch-timeout=180,
##           --switch-settle-frames=8, --switch-move=1.0 (metres per new map).
## A live process or surviving sky is not a pass: every requested replacement
## must have a new Game, the right region, camera, navmesh, support and movement.
## This persistent SceneTree runner reuses only the existing route-probe helpers.

var _state: Node
var _steps: Array[int] = [-1, 1]
var _settle_frames := 8
var _move_metres := 1.0
var _done := false
var _stage := "starting"
var _startup_probes := 0
var _gap_frames := 0
var _records: Array[Dictionary] = []
var _scene_started_us := 0
var _ready_seconds := 0.0
var _movement_seconds := 0.0
var _movement_ticks := 0


func _initialize() -> void:
	_deadline_us = Time.get_ticks_usec() + 180000000
	call_deferred("_run")


func _process(_delta: float) -> bool:
	# A script error must not leave a blank window running indefinitely.
	if not _done and Time.get_ticks_usec() > _deadline_us:
		_fail("Timed out during %s; no verified replacement became playable" % _stage)
	return false


func _physics_process(_delta: float) -> bool:
	return false


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg in ["--switchtest", "--naptest", "--pathtest", "--navheight", "--navpatch", "--navdump", "--screenshot"]:
			_fail("%s interferes with the assertion harness; omit it" % arg)
			return
		if arg.begins_with("--switch-steps="):
			_steps.clear()
			for text in arg.trim_prefix("--switch-steps=").split(",", false):
				if text != "-1" and text != "1":
					_fail("switch steps must be comma-separated -1 or 1")
					return
				_steps.append(int(text))
		elif arg.begins_with("--switch-timeout="):
			_timeout_seconds = float(arg.get_slice("=", 1))
		elif arg.begins_with("--switch-settle-frames="):
			_settle_frames = int(arg.get_slice("=", 1))
		elif arg.begins_with("--switch-move="):
			_move_metres = float(arg.get_slice("=", 1))
	if _steps.is_empty() or _timeout_seconds <= 0.0 or _settle_frames < 2 or _move_metres <= 0.0:
		_fail("Invalid switch count, duration, settling frames or movement distance")
		return
	_state = root.get_node_or_null("RegionState")
	if _state == null or int(_state.count()) < 2:
		_fail("RegionState or its region registry is unavailable")
		return
	_started_us = Time.get_ticks_usec()
	_scene_started_us = _started_us
	print("SWITCH_START " + JSON.stringify({"engine": Engine.get_version_info().string,
		"renderer": RenderingServer.get_current_rendering_method(),
		"display": DisplayServer.get_name(), "headless": DisplayServer.get_name() == "headless",
		"steps": _steps, "start_region": _state.current_id(), "move_metres": _move_metres}))
	var packed := load("res://game.tscn") as PackedScene
	if packed == null:
		_fail("game.tscn failed to load")
		return
	_game = packed.instantiate() as Node3D
	root.add_child(_game)
	current_scene = _game
	if not await _await_scene(int(_state.current), 0):
		return
	var owner_id := _state.get_instance_id()
	for step in _steps:
		var old: WeakRef = weakref(_game)
		var old_nav: WeakRef = weakref(_nav)
		var old_id := _game.get_instance_id()
		var expected := (int(_state.current) + step + int(_state.count())) % int(_state.count())
		var from_id: String = _state.current_id()
		_stage = "Tab from " + from_id
		_scene_started_us = Time.get_ticks_usec()
		_deadline_us = Time.get_ticks_usec() + int(_timeout_seconds * 1000000.0)
		_send_key(KEY_TAB, step > 0)
		if int(_state.current) != expected:
			_fail("Tab did not select the expected adjacent region")
			return
		# New code must reject all subsequent input in this same frame. Allow an
		# old revision without the persistent API to reach the blank-scene timeout,
		# making this harness usable to demonstrate the original regression too.
		if _state.has_method("reload_game_scene"):
			if _state.get("transition_in_progress") != true:
				_fail("Transition guard was not set before input dispatch returned")
				return
			for _i in 4:
				_send_key(KEY_TAB, step < 0)
				_send_key(KEY_8)
				_send_key(KEY_9)
			if int(_state.current) != expected:
				_fail("Rapid input changed the pending transition destination")
				return
		if not await _await_scene(expected, old_id):
			return
		if old.get_ref() != null or old_nav.get_ref() != null:
			_fail("The retired Game or navigation node is still alive")
			return
		if _state.get_instance_id() != owner_id:
			_fail("The persistent transition owner was replaced")
			return
		var moved := await _verify_movement()
		if _done or moved < _move_metres:
			return
		var record := {"from": from_id, "to": _state.current_id(), "step": step,
			"old_game_id": old_id, "new_game_id": _game.get_instance_id(), "moved_m": moved,
			"movement_wall_s": _movement_seconds, "movement_physics_ticks": _movement_ticks,
			"ready_s": _ready_seconds,
			"nav_polygons": int(_nav.get("polygons")), "camera": String(_game.get("camera").name)}
		if DisplayServer.get_name() != "headless":
			record["draw_calls_last_frame"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
			record["rendered_objects_last_frame"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		_records.append(record)
		print("SWITCH_OK " + JSON.stringify(record))
	_done = true
	print("SWITCH_PASS " + JSON.stringify({"transitions": _records,
		"gap_frames": _gap_frames, "startup_input_probes": _startup_probes,
		"renderer": RenderingServer.get_current_rendering_method(),
		"headless": DisplayServer.get_name() == "headless",
		"elapsed_s": float(Time.get_ticks_usec() - _started_us) / 1000000.0}))
	quit(0)


func _await_scene(expected: int, previous_id: int) -> bool:
	_stage = "waiting for playable region %d" % expected
	_deadline_us = Time.get_ticks_usec() + int(_timeout_seconds * 1000000.0)
	var probed_id := 0
	while not _done and Time.get_ticks_usec() < _deadline_us:
		await process_frame
		if int(_state.current) != expected:
			_fail("Region selection changed during replacement startup")
			return false
		var candidate := current_scene as Node3D
		if candidate == null:
			_gap_frames += 1
			continue
		if candidate.get_instance_id() == previous_id:
			continue
		if _playable(candidate, expected):
			_ready_seconds = float(Time.get_ticks_usec() - _scene_started_us) / 1000000.0
			_game = candidate
			_player = _game.get("player") as CharacterBody3D
			_nav = _game.get("nav") as Node3D
			for _i in _settle_frames:
				await process_frame
				if not _playable(_game, expected):
					_fail("Replacement lost its scene/camera/navigation during settling")
					return false
			print("SWITCH_READY " + JSON.stringify({"region": _state.current_id(),
				"game_id": _game.get_instance_id(), "nav_polygons": int(_nav.get("polygons")),
				"ready_s": _ready_seconds}))
			return true
		# scene_changed alone is insufficient: camera/nav setup continues across
		# physics-frame awaits. Exercise that window through real key dispatch.
		if probed_id != candidate.get_instance_id() and not _input_ready(candidate):
			probed_id = candidate.get_instance_id()
			_startup_probes += 1
			_send_key(KEY_TAB)
			_send_key(KEY_TAB, true)
			_send_key(KEY_8)
			if int(_state.current) != expected:
				_fail("Input during asynchronous camera/navigation startup was accepted")
				return false
	_fail("Timed out without a new playable Game, active camera and navigation")
	return false


func _input_ready(scene: Node3D) -> bool:
	var camera := scene.get("camera") as Camera3D
	var body := scene.get("player") as CharacterBody3D
	return scene.get("links_ready") == true and is_instance_valid(camera) \
			and camera.current and is_instance_valid(body) \
			and _state.get("transition_in_progress") != true


func _playable(scene: Node3D, expected: int) -> bool:
	if not is_instance_valid(scene) or scene != current_scene or not _input_ready(scene):
		return false
	var camera := scene.get("camera") as Camera3D
	var body := scene.get("player") as CharacterBody3D
	var navigation := scene.get("nav") as Node3D
	var host := scene.get_node_or_null("Map")
	var mounted: Node3D = host.get("region") if host != null else null
	if not is_instance_valid(navigation) or not is_instance_valid(mounted) \
			or String(mounted.get("region_id")) != String(_state.regions[expected].get("id", "")):
		return false
	if root.get_camera_3d() != camera or int(navigation.get("polygons")) <= 0:
		return false
	var nav_region := navigation.get("region") as NavigationRegion3D
	if nav_region == null or nav_region.navigation_mesh == null \
			or nav_region.navigation_mesh.get_polygon_count() == 0:
		return false
	return body.global_position.is_finite() and body.call("get_support_point") != null


func _verify_movement() -> float:
	_stage = "walking after switch to " + String(_state.current_id())
	var route := _choose_route()
	if route.size() < 2:
		_fail("Replacement has no supported local navigation route")
		return -1.0
	var before := _player.global_position
	var previous := before
	var travelled := 0.0
	var started := Time.get_ticks_usec()
	var first_tick := Engine.get_physics_frames()
	# The physics-step cap intentionally slows simulation when rendering is
	# very slow (for example llvmpipe). Eight wall-clock seconds can then allow
	# less than a quarter second of movement. Keep the same simulation budget
	# and distance assertion, with the per-stage wall timeout as a hard bound.
	var tick_limit := int(Engine.physics_ticks_per_second * 8)
	_deadline_us = started + int(_timeout_seconds * 1000000.0)
	_player.call("move_along", route)
	while not _done and travelled < _move_metres \
			and Engine.get_physics_frames() - first_tick < tick_limit \
			and Time.get_ticks_usec() < _deadline_us:
		await process_frame
		if not is_instance_valid(_player) or not _player.global_position.is_finite() \
				or _player.global_position.y < before.y - 3.0:
			_fail("Replacement player disappeared or fell through terrain")
			return -1.0
		travelled += _horizontal_distance(previous, _player.global_position)
		previous = _player.global_position
	if _done:
		return -1.0
	_player.call("cancel_path")
	_movement_seconds = float(Time.get_ticks_usec() - started) / 1000000.0
	_movement_ticks = Engine.get_physics_frames() - first_tick
	if travelled < _move_metres or _player.call("get_support_point") == null:
		_fail("Replacement player could not walk %.2f supported metres" % _move_metres)
		return -1.0
	return travelled


func _send_key(code: Key, shift := false) -> void:
	var press := InputEventKey.new()
	press.keycode = code
	press.physical_keycode = code
	press.pressed = true
	press.shift_pressed = shift
	root.push_input(press)
	var release := InputEventKey.new()
	release.keycode = code
	release.physical_keycode = code
	release.shift_pressed = shift
	root.push_input(release)


func _fail(reason: String) -> void:
	if _done:
		return
	_done = true
	print("SWITCH_FAIL " + JSON.stringify({"stage": _stage, "reason": reason,
		"current_scene": str(current_scene), "region": _state.current_id() if _state != null else ""}))
	quit(1)
