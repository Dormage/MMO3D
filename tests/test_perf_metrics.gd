extends SceneTree
## Run: godot --headless --path . --script tests/test_perf_metrics.gd
## No GLB imports or timing-sensitive waits are required.

var _failed := false


class PerfPlayer extends CharacterBody3D:
	var counters: Dictionary = {}
	var reads := 0

	func perf_take() -> Dictionary:
		reads += 1
		var result := counters
		counters = {}
		return result


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var controller: GDScript = load("res://scripts/game_controller.gd")
	if not controller.can_instantiate():
		push_error("game_controller failed to compile")
		quit(1)
		return
	var steady := PackedFloat64Array()
	steady.resize(120)
	steady.fill(1000.0 / 60.0)
	var counters := {
		"ticks": 120, "player_us": 240000, "move_us": 120000,
		"water_us": 6000, "glue_us": 12000,
		"sole_us": 9000, "sole_calls": 90, "distance_xz": 7.64,
	}
	var m: Dictionary = controller._perf_window_metrics(steady, 2000000, 120, counters)
	_check(is_equal_approx(m.move_ms_tick, 1.0), "120 ms over 120 ticks is 1 ms/tick, not 60 ms/tick")
	_check(is_equal_approx(m.player_ms_tick, 2.0), "total controller time uses actual player ticks")
	_check(is_equal_approx(m.sole_ms_call, 0.1), "sole time uses actual calls, not player ticks")
	_check(is_equal_approx(m.physics_hz, 60.0), "physics Hz uses elapsed wall time")
	_check(is_equal_approx(m.physics_per_frame, 1.0), "steady state has one physics tick per frame")
	_check(is_equal_approx(m.achieved_mps, 3.82), "movement speed uses distance per real second")
	_check(is_equal_approx(m.fps, 60.0), "FPS uses exactly this sampling window")
	_check(is_equal_approx(m.frame_ms_mean, 1000.0 / 60.0), "frame mean uses wall-clock frame intervals")
	# At 10 FPS and a four-step cap, only 80 of the intended 120 ticks run.
	# A synthetic two-second window must reveal the slowdown rather than hide it
	# behind the physics delta or a fixed denominator.
	var slow := PackedFloat64Array()
	slow.resize(20)
	slow.fill(100.0)
	counters.ticks = 80
	counters.move_us = 80000
	counters.distance_xz = 3.82 * 80.0 / 60.0
	m = controller._perf_window_metrics(slow, 2000000, 80, counters)
	_check(is_equal_approx(m.move_ms_tick, 1.0), "per-tick timing stays correct when physics falls behind")
	_check(is_equal_approx(m.physics_hz, 40.0), "step cap slowdown appears as 40 Hz")
	_check(is_equal_approx(m.physics_per_frame, 4.0), "four physics ticks per frame reach the cap")
	_check(is_equal_approx(m.achieved_mps, 3.82 * 2.0 / 3.0), "slow simulation has reduced real movement speed")
	_check(is_equal_approx(m.frame_ms_p95, 100.0), "slow frames appear in percentiles")
	# Nonuniform frames and an overshooting window exercise percentile sorting
	# and the actual elapsed-time divisor; caller data must remain unmodified.
	var irregular := PackedFloat64Array([100.0, 20.0, 80.0, 10.0])
	m = controller._perf_window_metrics(irregular, 210000, 12, {"ticks": 12, "move_us": 12000})
	_check(is_equal_approx(m.frame_ms_p50, 20.0), "p50 uses nearest rank on sorted samples")
	_check(is_equal_approx(m.frame_ms_p95, 100.0), "p95 includes long frames")
	_check(is_equal_approx(m.frame_ms_max, 100.0), "maximum frame interval")
	_check(is_equal_approx(m.frame_ms_mean, 52.5), "nonuniform frame mean")
	_check(is_equal_approx(m.physics_hz, 12.0 / 0.21), "window overshoot is not truncated to two seconds")
	_check(is_equal_approx(irregular[0], 100.0), "metric calculation leaves caller samples untouched")
	m = controller._perf_window_metrics(PackedFloat64Array(), 0, 0, {})
	for key in ["fps", "frame_ms_mean", "frame_ms_p50", "frame_ms_p95", "frame_ms_p99", "frame_ms_max", "physics_hz", "physics_per_frame", "player_ms_tick", "move_ms_tick", "sole_ms_call", "achieved_mps"]:
		_check(is_finite(float(m[key])) and is_zero_approx(float(m[key])), "empty window is finite and zero: %s" % key)
	# Exercise the live sampler as well: its first frame discards startup work,
	# and the next complete window consumes the Dictionary without GLB assets.
	var sampler: Node3D = controller.new()
	var mock := PerfPlayer.new()
	sampler.player = mock
	sampler._perf_enabled = true
	mock.counters = {"ticks": 1000, "player_us": 1000000}
	sampler._perf_sample_at(10000000)
	_check(mock.reads == 1, "sampler discards counters collected before the window")
	mock.counters = {"ticks": 120, "move_us": 120000, "sole_calls": 90, "sole_us": 9000}
	sampler._perf_previous_us = 12100000 - 17500
	sampler._perf_start_physics = Engine.get_physics_frames() - 120
	var smoke_frames := PackedFloat64Array()
	smoke_frames.resize(119)
	smoke_frames.fill(17.5)
	sampler._perf_frame_ms = smoke_frames
	sampler._perf_sample_at(12100000)
	_check(mock.reads == 2, "sampler consumes counters exactly once per completed window")
	_check(sampler._perf_frame_ms.is_empty(), "sampler clears completed frame samples")
	sampler._perf_external_sampling = true
	sampler._perf_sample(0.0)
	_check(mock.reads == 2, "standalone benchmark keeps exclusive ownership of counters")
	sampler._perf_external_sampling = false
	sampler._perf_enabled = false
	sampler._perf_sample(0.0)
	_check(sampler._perf_frame_ms.is_empty(), "profiling off collects no frame samples")
	sampler.free()
	mock.free()
	if not _failed:
		print("PASS: profiler units, stalled physics, frame percentiles, and empty windows")
	quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		_failed = true
		push_error(description)
