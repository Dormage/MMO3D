extends SceneTree
## godot --headless --path . --script tests/test_region_switch.gd
## Tests real transition ownership and Game key handling without map/GLB assets.

const FIXTURE := "res://tests/fixtures/region_switch_scene.tscn"
var _state: Node
var _checks := 0
var _failures := 0
var _started := 0
var _finished := 0
var _blank_frames := 0
var _early_input_probes := 0
var _completed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_state = root.get_node_or_null("RegionState")
	if not _check(_state != null and _state.has_method("reload_game_scene"),
			"persistent RegionState transition API is available"):
		_finish()
		return
	_state.transition_started.connect(func() -> void: _started += 1)
	_state.transition_finished.connect(func() -> void: _finished += 1)
	var owner_id := _state.get_instance_id()
	_state.select(0)
	var packed := load(FIXTURE) as PackedScene
	if not _check(packed != null, "lightweight scene loads"):
		_finish()
		return
	var initial := packed.instantiate() as Node3D
	if not _check(initial != null and initial.has_method("_region_switch_ready"),
			"fixture compiles with the real Game controller"):
		if initial != null:
			initial.free()
		_finish()
		return
	root.add_child(initial)
	current_scene = initial
	# The new Game receives input while its _ready coroutine is still waiting.
	var selection := int(_state.current)
	_key(KEY_TAB)
	_key(KEY_TAB, true)
	_key(KEY_8)
	_check(int(_state.current) == selection and not _state.transition_in_progress,
			"premature Tab, Shift+Tab and number keys do not mutate selection")
	if not await _wait_ready(selection, 0):
		_finish()
		return
	var original_id := current_scene.get_instance_id()
	# Bad requests must leave the playable scene intact; preflight comes first.
	_check(not _state.reload_game_scene("res://tests/fixtures/missing_switch_scene.tscn"),
			"missing replacement scene is rejected")
	_check(not _state.reload_game_scene("res://scripts/region_state.gd"),
			"a non-PackedScene resource is rejected")
	_check(not _state.transition_in_progress and current_scene.get_instance_id() == original_id,
			"failed preflight leaves the old scene active and clears no state")
	_check(_started == 0, "invalid paths never begin teardown")
	current_scene._jump_region(selection)
	current_scene._jump_region(-1)
	current_scene._jump_region(_state.count())
	_key(KEY_TAB, false, true)
	_check(_started == 0 and int(_state.current) == selection,
			"same/invalid region and key repeat do not start transitions")
	# Request a replacement directly, then hammer the same transition while the
	# old caller still exists. Only the persistent autoload may own the await.
	var old: WeakRef = weakref(current_scene)
	var old_id := current_scene.get_instance_id()
	_check(_state.reload_game_scene(FIXTURE), "valid replacement is accepted")
	_check(_state.transition_in_progress, "busy guard is set synchronously")
	_check(not _state.reload_game_scene(FIXTURE), "duplicate reload is rejected while busy")
	_check(not _state.select((selection + 1) % _state.count()), "selection cannot change while busy")
	_key(KEY_TAB)
	_key(KEY_TAB, true)
	_key(KEY_8)
	_check(int(_state.current) == selection and _started == 1,
			"rapid input cannot mutate the pending destination")
	if not await _wait_ready(selection, old_id):
		_finish()
		return
	_check(old.get_ref() == null, "the old Game instance is actually destroyed")
	_check(_finished == 1 and not _state.transition_in_progress, "replacement completes and unlocks input")
	_check(_blank_frames > 0, "old scene is released across a frame boundary before replacement")
	_check(current_scene.created_frame > int(_state.get_meta("fixture_exit_frame", -1)),
			"replacement is created in a later frame than old scene teardown")
	# Preserve the established controls: ordinary Tab is -1, Shift+Tab is +1.
	for step in [-1, 1, 1]:
		old = weakref(current_scene)
		old_id = current_scene.get_instance_id()
		var expected: int = (int(_state.current) + step + int(_state.count())) % int(_state.count())
		var started_before := _started
		_key(KEY_TAB, step > 0)
		_check(int(_state.current) == expected and _state.transition_in_progress,
				"Tab selects the correct adjacent/wrapped region")
		for _i in 4:
			_key(KEY_TAB, step <= 0)
			_key(KEY_9)
		_check(int(_state.current) == expected and _started == started_before + 1,
				"rapid key bursts produce exactly one transition")
		if not await _wait_ready(expected, old_id):
			_finish()
			return
		_check(old.get_ref() == null, "each retired scene is freed")
		_check(current_scene.mounted_index == expected, "replacement mounts the selected registry entry")
		_check(_state.get_instance_id() == owner_id, "transition owner survives every Game replacement")
	_check(_early_input_probes >= 4, "replacement startup was exercised before camera/navigation readiness")
	_check(_started == 4 and _finished == 4, "all accepted requests finish exactly once")
	_completed = true
	_finish()


func _wait_ready(expected: int, previous_id: int) -> bool:
	var deadline := Time.get_ticks_msec() + 4000
	var probed_id := 0
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene == null:
			_blank_frames += 1
			continue
		if current_scene.get_instance_id() == previous_id:
			continue
		if int(_state.current) != expected:
			_check(false, "selection changed while replacement was loading")
			return false
		var camera: Camera3D = current_scene.get("camera")
		var ready: bool = current_scene.get("links_ready") == true and camera != null and camera.current \
				and current_scene.get("nav") != null and not _state.transition_in_progress
		if ready:
			var live_scenes := 0
			for child in root.get_children():
				if child.has_meta("region_switch_fixture"):
					live_scenes += 1
			_check(live_scenes == 1, "only one Game replacement remains in the scene tree")
			_check(root.get_camera_3d() == camera, "replacement owns the viewport's active camera")
			return true
		if probed_id != current_scene.get_instance_id():
			probed_id = current_scene.get_instance_id()
			_early_input_probes += 1
			_key(KEY_TAB)
			_key(KEY_TAB, true)
			_key(KEY_8)
			if not _check(int(_state.current) == expected, "keys during asynchronous scene startup are ignored"):
				return false
	_check(false, "timed out: replacement scene, camera and navigation never became ready")
	return false


func _key(code: Key, shift := false, echo := false) -> void:
	var press := InputEventKey.new()
	press.keycode = code
	press.physical_keycode = code
	press.pressed = true
	press.shift_pressed = shift
	press.echo = echo
	root.push_input(press)
	var release := InputEventKey.new()
	release.keycode = code
	release.physical_keycode = code
	release.shift_pressed = shift
	root.push_input(release)


func _check(ok: bool, description: String) -> bool:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(description)
	return ok


func _finish() -> void:
	if not _completed and _failures == 0:
		_failures += 1
		push_error("region-switch regression stopped before its final assertions")
	print("REGION_SWITCH_TEST checks=%d failures=%d started=%d finished=%d gap_frames=%d startup_probes=%d" % [
		_checks, _failures, _started, _finished, _blank_frames, _early_input_probes])
	quit(0 if _failures == 0 else 1)
