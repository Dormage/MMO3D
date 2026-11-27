extends SceneTree
## Exercise the ordinary game scene, camera and player controller.
##
## godot --path . --script res://tools/perf_benchmark.gd -- --region=island
## Add --headless before --path for CPU/movement checks only. A headless run
## cannot measure rendering throughput or predict the user's GPU frame rate.
## Optional user args: --bench-warmup=3 --bench-idle=5 --bench-walk=12
##                     --bench-timeout=180 --bench-label=after
## --bench-legacy-sole restores only the old sole scan for a controlled baseline;
## it is a benchmark diagnostic and never changes ordinary gameplay.
## Existing region/graphics switches work unchanged, e.g. --nopop or --noveg.

var _game: Node3D
var _player: CharacterBody3D
var _nav: Node3D
var _started_us := 0
var _deadline_us := 0
var _phase := ""
var _phase_started_us := 0
var _last_frame_us := 0
var _phase_ticks := 0
var _frame_ms := PackedFloat64Array()
var _results: Array[Dictionary] = []
var _last_health_us := 0
var _unsupported_since_us := 0
var _floor_min := -1000.0
var _failure := ""
var _warmup_seconds := 3.0
var _idle_seconds := 5.0
var _walk_seconds := 12.0
var _timeout_seconds := 180.0
var _label := ""
var _legacy_sole := false


func _initialize() -> void:
	# Timing is opt-in for normal play. The benchmark owns the sampling window
	# and disables the game's periodic consumer before the scene enters the tree.
	OS.set_environment("PERF_LOG", "1")
	call_deferred("_run")


func _process(_delta: float) -> bool:
	if not _phase.is_empty():
		var now := Time.get_ticks_usec()
		if _last_frame_us > 0:
			_frame_ms.append(float(now - _last_frame_us) / 1000.0)
		_last_frame_us = now
	return false


func _physics_process(_delta: float) -> bool:
	if not _phase.is_empty():
		_phase_ticks += 1
	return false


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg in ["--naptest", "--pathtest", "--navheight", "--navpatch", "--navdump", "--screenshot"]:
			_fail("%s exits normal startup; omit it when running this benchmark" % arg)
			return
		if arg.begins_with("--bench-warmup="):
			_warmup_seconds = float(arg.get_slice("=", 1))
		elif arg.begins_with("--bench-idle="):
			_idle_seconds = float(arg.get_slice("=", 1))
		elif arg.begins_with("--bench-walk="):
			_walk_seconds = float(arg.get_slice("=", 1))
		elif arg.begins_with("--bench-timeout="):
			_timeout_seconds = float(arg.get_slice("=", 1))
		elif arg.begins_with("--bench-label="):
			_label = arg.trim_prefix("--bench-label=")
		elif arg == "--bench-legacy-sole":
			_legacy_sole = true
	if _warmup_seconds < 0.0 or _idle_seconds <= 0.0 or _walk_seconds <= 0.0 \
			or _timeout_seconds <= _warmup_seconds + _idle_seconds + _walk_seconds:
		_fail("Invalid benchmark durations or timeout")
		return
	_started_us = Time.get_ticks_usec()
	_deadline_us = _started_us + int(_timeout_seconds * 1000000.0)
	print("BENCH_START " + JSON.stringify({"label": _label, "legacy_sole": _legacy_sole,
		"engine": Engine.get_version_info().string,
		"display": DisplayServer.get_name(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"headless": DisplayServer.get_name() == "headless",
		"physics_hz_target": Engine.physics_ticks_per_second,
		"max_physics_steps_per_frame": Engine.max_physics_steps_per_frame,
		"user_args": OS.get_cmdline_user_args()}))
	var packed := load("res://game.tscn") as PackedScene
	if packed == null:
		_fail("game.tscn failed to load")
		return
	_game = packed.instantiate() as Node3D
	_game.set("_perf_external_sampling", true)
	_player = _game.get_node_or_null("Player") as CharacterBody3D
	if _player == null:
		_fail("Normal game has no player")
		return
	if _legacy_sole:
		# The subtype receives the normal cache build during Player._ready().
		# This does not alter model poses, movement, collision, or telemetry.
		_player.set("_sole_cache", load("res://tools/legacy_sole_sampler.gd").new())
	root.add_child(_game)
	current_scene = _game
	while not _normal_game_ready():
		await process_frame
		if Time.get_ticks_usec() >= _deadline_us:
			_fail("Timed out waiting for normal RPG camera and navigation links")
			return
	_nav = _game.get("nav") as Node3D
	_floor_min = _player.global_position.y - 1.0
	print("BENCH_READY " + JSON.stringify({"load_s":
		float(Time.get_ticks_usec() - _started_us) / 1000000.0,
		"camera": String((_game.get("camera") as Camera3D).name),
		"player_position": _vector(_player.global_position)}))
	if not await _wait_seconds(_warmup_seconds):
		_fail(_failure)
		return
	_player.call("cancel_path")
	_player.call("set_scripted_input", Vector2.ZERO)
	_begin_phase("idle")
	if not await _wait_seconds(_idle_seconds):
		_fail(_failure)
		return
	var idle := _end_phase()
	if float(idle.get("distance_xz_m", 0.0)) > 0.25:
		_fail("Idle player drifted more than 0.25 m; do not press movement keys during the benchmark")
		return
	var route := _choose_route()
	if route.size() < 2:
		_fail("No supported local navigation route of at least 5 m was found")
		return
	var start := route[0]
	var finish := route[route.size() - 1]
	for point in route:
		_floor_min = minf(_floor_min, point.y)
	print("BENCH_ROUTE " + JSON.stringify({"start": _vector(start),
		"end": _vector(finish), "points": route.size(), "length_m": _path_length(route)}))
	_begin_phase("walk")
	_player.call("move_along", route)
	var walk_deadline := Time.get_ticks_usec() + int(_walk_seconds * 1000000.0)
	var target := finish
	var turnarounds := 0
	var leg_started_us := Time.get_ticks_usec()
	while Time.get_ticks_usec() < walk_deadline:
		await process_frame
		if not _healthy():
			_fail(_failure)
			return
		if not bool(_player.call("is_path_active")):
			var gap := _horizontal_distance(_player.global_position, target)
			if gap > 0.9:
				_fail("Player stopped %.2f m from the route target" % gap)
				return
			target = start if target == finish else finish
			var back: PackedVector3Array = _nav.call("path", _player.global_position, target)
			if back.size() < 2 or back[back.size() - 1].distance_to(target) > 0.8:
				_fail("No reachable return route")
				return
			_player.call("move_along", back)
			turnarounds += 1
			leg_started_us = Time.get_ticks_usec()
		elif Time.get_ticks_usec() - leg_started_us > 12000000:
			_fail("Player failed to finish a local route within 12 seconds")
			return
	var walking := _end_phase()
	_player.call("cancel_path")
	if float(walking.get("distance_xz_m", 0.0)) < minf(4.0, _walk_seconds):
		_fail("Walking covered too little real distance")
		return
	print("BENCH_PASS " + JSON.stringify({"label": _label, "turnarounds": turnarounds,
		"elapsed_s": float(Time.get_ticks_usec() - _started_us) / 1000000.0,
		"headless": DisplayServer.get_name() == "headless",
		"results": _results}))
	quit(0)


func _normal_game_ready() -> bool:
	var camera := _game.get("camera") as Camera3D
	return bool(_game.get("links_ready")) and camera != null and camera.current \
			and _game.get("nav") != null


func _wait_seconds(seconds: float) -> bool:
	var until := Time.get_ticks_usec() + int(seconds * 1000000.0)
	while Time.get_ticks_usec() < until:
		await process_frame
		if not _healthy():
			return false
	return true


func _healthy() -> bool:
	var now := Time.get_ticks_usec()
	if now >= _deadline_us:
		_failure = "Benchmark timed out"
		return false
	var p := _player.global_position
	if not p.is_finite() or p.y < _floor_min - 3.0:
		_failure = "Player fell below the tested terrain or has an invalid position"
		return false
	if now - _last_health_us < 250000:
		return true
	_last_health_us = now
	if _player.call("get_support_point") == null:
		if _unsupported_since_us == 0:
			_unsupported_since_us = now
		elif now - _unsupported_since_us > 1500000:
			_failure = "Player has had no nearby supporting surface for 1.5 seconds"
			return false
	else:
		_unsupported_since_us = 0
	return true


func _choose_route() -> PackedVector3Array:
	var origin := _player.global_position
	# Fixed radius/direction order makes before/after runs select the same path.
	# Keep the route close to spawn and reject steep excursions and disconnected
	# goals. Surface probes also reject navmesh paths across missing collision.
	for radius: float in [8.0, 12.0, 6.0]:
		for direction in 16:
			var angle := TAU * float(direction) / 16.0
			var guess := origin + Vector3(cos(angle), 0.0, sin(angle)) * radius
			var target: Vector3 = _nav.call("closest", guess)
			if _horizontal_distance(target, guess) > 2.0 \
					or _horizontal_distance(target, origin) < 5.0:
				continue
			var path: PackedVector3Array = _nav.call("path", origin, target)
			if path.size() < 2 or path[path.size() - 1].distance_to(target) > 0.8:
				continue
			var length := _path_length(path)
			if length < 5.0 or length > radius * 1.75:
				continue
			if _route_supported(path, origin.y):
				return path
	return PackedVector3Array()


func _route_supported(path: PackedVector3Array, start_y: float) -> bool:
	var space := _player.get_world_3d().direct_space_state
	for i in range(1, path.size()):
		var steps := maxi(1, ceili(path[i - 1].distance_to(path[i]) / 0.5))
		for step in range(steps + 1):
			var p := path[i - 1].lerp(path[i], float(step) / steps)
			if absf(p.y - start_y) > 1.25:
				return false
			var ray := PhysicsRayQueryParameters3D.create(p + Vector3(0, 1.0, 0),
					p - Vector3(0, 1.0, 0), 3, [_player.get_rid()])
			var hit := space.intersect_ray(ray)
			if hit.is_empty() or (hit.normal as Vector3).y < 0.55 \
					or absf(float(hit.position.y) - p.y) > 0.6:
				return false
	return true


func _begin_phase(name: String) -> void:
	_player.call("perf_take")
	_phase_ticks = 0
	_frame_ms.clear()
	_phase_started_us = Time.get_ticks_usec()
	_last_frame_us = _phase_started_us
	_phase = name
	print("BENCH_PHASE " + name)


func _end_phase() -> Dictionary:
	var elapsed := Time.get_ticks_usec() - _phase_started_us
	var counters: Dictionary = _player.call("perf_take")
	var metrics: Dictionary = _game.call("_perf_window_metrics",
			_frame_ms, elapsed, _phase_ticks, counters)
	metrics["phase"] = _phase
	metrics["label"] = _label
	metrics["legacy_sole"] = _legacy_sole
	metrics["wall_s"] = float(elapsed) / 1000000.0
	metrics["frames"] = _frame_ms.size()
	metrics["player_ticks"] = int(counters.get("ticks", 0))
	metrics["physics_ticks"] = _phase_ticks
	metrics["distance_xz_m"] = float(counters.get("distance_xz", 0.0))
	metrics["path_calls"] = int(counters.get("path_calls", 0))
	metrics["sole_calls"] = int(counters.get("sole_calls", 0))
	metrics["sole_samples"] = int(counters.get("sole_samples", 0))
	metrics["sole_bones"] = int(counters.get("sole_bones", 0))
	metrics["headless"] = DisplayServer.get_name() == "headless"
	metrics["renderer"] = RenderingServer.get_current_rendering_method()
	if DisplayServer.get_name() == "headless":
		# Explicitly label loop throughput so this cannot be mistaken for GPU FPS.
		metrics["headless_loop_hz"] = metrics.get("fps", 0.0)
		metrics.erase("fps")
	else:
		metrics["draw_calls_last_frame"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		metrics["render_objects_last_frame"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		metrics["render_primitives_last_frame"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_results.append(metrics)
	print("BENCH_RESULT " + JSON.stringify(metrics))
	_phase = ""
	return metrics


func _fail(reason: String) -> void:
	if not _phase.is_empty() and is_instance_valid(_player):
		_end_phase()
	print("BENCH_FAIL " + reason)
	quit(1)


func _path_length(path: PackedVector3Array) -> float:
	var length := 0.0
	for i in range(1, path.size()):
		length += path[i - 1].distance_to(path[i])
	return length


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _vector(v: Vector3) -> Array:
	return [v.x, v.y, v.z]
