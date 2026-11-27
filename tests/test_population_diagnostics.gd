extends SceneTree
## Run this lightweight fixture in three modes (no GLB assets are loaded):
##   godot --headless --path . --script tests/test_population_diagnostics.gd
##   godot --headless --path . --script tests/test_population_diagnostics.gd -- --nopop
##   godot --headless --path . --script tests/test_population_diagnostics.gd -- --minphys

var _failures := 0


class PopulationFixture extends "res://scripts/population_actor.gd":
	var ticks := 0

	func _load_model() -> void:
		var model := Node3D.new()
		model.name = "Model"
		add_child(model)
		_player = AnimationPlayer.new()
		model.add_child(_player)
		var library := AnimationLibrary.new()
		var clip := Animation.new()
		clip.length = 1.0
		clip.loop_mode = Animation.LOOP_LINEAR
		library.add_animation("Idle", clip)
		_player.add_animation_library("", library)
		_clips = {"idle": "Idle"}

	func _physics_process(_delta: float) -> void:
		ticks += 1


class MonsterFixture extends "res://scripts/monster_actor.gd":
	var ticks := 0

	func _load_model() -> void:
		var model := Node3D.new()
		model.name = "Model"
		add_child(model)
		_player = AnimationPlayer.new()
		model.add_child(_player)
		var library := AnimationLibrary.new()
		var clip := Animation.new()
		clip.length = 1.0
		clip.loop_mode = Animation.LOOP_LINEAR
		library.add_animation("Idle", clip)
		_player.add_animation_library("", library)
		_idle_clip = "Idle"
		_play(_idle_clip)

	func _physics_process(_delta: float) -> void:
		ticks += 1


class PopulationSpawner extends "res://scripts/population_field.gd":
	var waits := 0
	var spawns := 0

	func _wait_for_ground() -> void:
		waits += 1
		await get_tree().process_frame

	func _load_roster() -> Dictionary:
		return {"actors": [{}]}

	func _collect_candidates() -> Array[Vector3]:
		return [Vector3.ZERO]

	func _spawn(_entries: Array) -> void:
		spawns += 1

	func _report() -> void:
		pass

	func _add_credit_label() -> void:
		pass

	func _handle_debug_args() -> void:
		pass


class MonsterSpawner extends "res://scripts/monster_field.gd":
	var waits := 0
	var spawns := 0

	func _wait_for_ground() -> void:
		waits += 1
		await get_tree().process_frame

	func _spawn_roster() -> void:
		spawns += 1

	func _report() -> void:
		pass


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var nopop := OS.get_cmdline_user_args().has("--nopop")
	var minphys := OS.get_cmdline_user_args().has("--minphys")
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var player := CharacterBody3D.new()
	player.collision_layer = 4
	player.collision_mask = 3
	player.set_physics_process(true)
	world.add_child(player)
	# Load after autoload initialization; game_controller uses RegionState.
	var controller: Node3D = load("res://tests/fixtures/diagnostic_controller.gd").new()
	controller.player = player
	world.add_child(controller)
	var ground := StaticBody3D.new()
	ground.name = "GroundCollision_fixture"
	ground.collision_layer = 1
	world.add_child(ground)
	var prop := StaticBody3D.new()
	prop.name = "Solid_fixture"
	prop.collision_layer = 2
	world.add_child(prop)
	var statue := Node3D.new()
	statue.name = "MonsterStatueDecoration"
	world.add_child(statue)
	# Existing authored group members must also be disabled, without depending
	# on their node names or membership in the two runtime actor script classes.
	var authored := CharacterBody3D.new()
	authored.collision_layer = 4
	authored.collision_mask = 3
	authored.set_physics_process(true)
	authored.add_to_group("population")
	world.add_child(authored)
	controller._apply_nopop()
	controller._apply_minphys()
	_check(player.collision_layer == 4 and player.collision_mask == 3, "diagnostics preserve player collision")
	_check(player.is_physics_processing(), "diagnostics preserve player movement")
	_check(ground.collision_layer == 1, "minphys preserves ground collision")
	_check(prop.collision_layer == (0 if minphys else 2), "only minphys removes static prop collision")
	_check(statue.visible, "nopop preserves unrelated monster-named decoration")
	_check(authored.visible == (not nopop), "authored population visibility follows nopop")
	_check(authored.is_physics_processing() == (not nopop and not minphys), "authored population simulation follows diagnostic flags")
	# These actors arrive AFTER the controller's one-shot diagnostic pass.
	await process_frame
	var late_population := PopulationFixture.new()
	world.add_child(late_population)
	var late_monster := MonsterFixture.new()
	world.add_child(late_monster)
	var population_spawner := PopulationSpawner.new()
	world.add_child(population_spawner)
	var monster_spawner := MonsterSpawner.new()
	world.add_child(monster_spawner)
	for _i in 3:
		await process_frame
	_check(population_spawner.spawns == (0 if nopop else 1), "population spawner honors nopop before async work")
	_check(monster_spawner.spawns == (0 if nopop else 1), "monster spawner honors nopop before async work")
	_check(population_spawner.waits == (0 if nopop else 1), "nopop skips population ground scans")
	_check(monster_spawner.waits == (0 if nopop else 1), "nopop skips monster ground scans")
	for actor in [late_population, late_monster]:
		_check(actor.visible == (not nopop), "late actor visibility follows nopop")
		_check(actor.collision_layer == (0 if nopop or minphys else 4), "late actor collision follows flags")
		_check(actor.is_physics_processing() == (not nopop and not minphys), "late actor physics follows flags")
		var model: Node = actor.get_node_or_null("Model")
		_check((model == null) == nopop, "nopop avoids loading models; minphys keeps them")
		if model != null:
			var animation := model.get_child(0) as AnimationPlayer
			_check(animation.is_playing() and animation.can_process(), "minphys preserves idle animation playback")
		actor.position = Vector3(100, 0, 0)
	controller._throttle_actors(0.6)
	_check(not late_population.is_physics_processing() and not late_monster.is_physics_processing(), "distant actors remain asleep")
	late_population.position = Vector3.ZERO
	late_monster.position = Vector3.ZERO
	controller._throttle_actors(0.6)
	_check(late_population.is_physics_processing() == (not nopop and not minphys), "throttle never resurrects disabled population")
	_check(late_monster.is_physics_processing() == (not nopop and not minphys), "throttle never resurrects disabled monsters")
	world.free()
	print("POPULATION_DIAGNOSTICS_TEST nopop=%s minphys=%s failures=%d" % [nopop, minphys, _failures])
	quit(0 if _failures == 0 else 1)


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)
