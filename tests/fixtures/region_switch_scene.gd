extends "res://scripts/game_controller.gd"
## A tiny replacement scene that keeps the real Game input/selection guards.
## Startup deliberately spans frames, like the real navigation/camera setup.

var mounted_index := -1
var created_frame := 0


func _ready() -> void:
	set_meta("region_switch_fixture", true)
	created_frame = Engine.get_process_frames()
	mounted_index = RegionState.current
	player = CharacterBody3D.new()
	player.name = "Player"
	add_child(player)
	map = Node3D.new()
	map.name = "Map"
	add_child(map)
	camera = Camera3D.new()
	camera.name = "FixtureCamera"
	add_child(camera)
	camera.clear_current()
	set_process(false)
	set_physics_process(false)
	for _i in 4:
		await get_tree().process_frame
	nav = Node3D.new()
	nav.name = "FixtureNavigation"
	add_child(nav)
	links_ready = true
	camera.make_current()


func _reload_for_region() -> void:
	RegionState.reload_game_scene("res://tests/fixtures/region_switch_scene.tscn")


func _exit_tree() -> void:
	RegionState.set_meta("fixture_exit_frame", Engine.get_process_frames())


func _process(_delta: float) -> void:
	pass
