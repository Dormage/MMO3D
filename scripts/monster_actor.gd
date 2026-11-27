class_name MonsterActor
extends CharacterBody3D
## A wandering monster: loads one converted GLB, picks a random point inside a
## small home radius, walks there, idles, repeats.
##
## Movement is plain steering + gravity so it works on any collision surface;
## no navmesh is required.  The GLB is loaded through glb_util so it also works
## headless, before Godot has written import sidecars.

const GRAVITY := 24.0
const ARRIVE_DISTANCE := 0.35
const TURN_RATE := 6.0
const PROBE_HEIGHT := 40.0
const PROBE_DEPTH := 30.0

@export var model_path: String = ""
@export var display_name: String = ""
@export var move_speed: float = 1.2
@export var wander_radius: float = 5.0
@export var idle_min: float = 1.2
@export var idle_max: float = 3.0
@export var model_height: float = 1.8
@export var body_radius: float = 0.5
@export var model_scale: float = 1.0
## 0 when the model faces +Z after conversion, PI when it faces -Z.
@export var yaw_offset: float = 0.0
@export var ground_mask: int = 1

var _player: AnimationPlayer
var _walk_clip := ""
var _idle_clip := ""
var _home := Vector3.ZERO
var _target := Vector3.ZERO
var _has_target := false
var _wait := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_home = global_position
	_build_body()
	_load_model()
	_wait = _rng.randf_range(0.2, idle_max)


func _build_body() -> void:
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = maxf(body_radius, 0.2)
	capsule.height = maxf(model_height, capsule.radius * 2.0 + 0.1)
	shape.shape = capsule
	shape.position.y = capsule.height * 0.5
	add_child(shape)
	collision_layer = 4
	collision_mask = ground_mask | 2
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.8


func _load_model() -> void:
	var node: Node = preload("res://scripts/glb_util.gd").instantiate(model_path)
	if node == null:
		push_warning("MonsterActor: could not load %s" % model_path)
		return
	node.name = "Model"
	if not is_equal_approx(model_scale, 1.0):
		node.scale = Vector3.ONE * model_scale
	add_child(node)

	for n in node.find_children("*", "AnimationPlayer", true, false):
		_player = n as AnimationPlayer
		break
	if _player == null:
		push_warning("MonsterActor: no AnimationPlayer in %s" % model_path)
		return

	var names := _player.get_animation_list()
	_walk_clip = _pick(names, ["walk", "movefwd", "move_fwd", "run"])
	_idle_clip = _pick(names, ["idle"])
	_loop(_walk_clip)
	_loop(_idle_clip)
	_play(_idle_clip)


func _pick(names: PackedStringArray, wanted: Array) -> String:
	for want in wanted:
		for n in names:
			if n == want:
				return n
	for want in wanted:
		for n in names:
			if n.contains(want) and not n.contains("back") and not n.contains("left") \
					and not n.contains("right"):
				return n
	return ""


func _loop(clip: String) -> void:
	if clip.is_empty() or _player == null:
		return
	var anim := _player.get_animation(clip)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR


func _play(clip: String) -> void:
	if _player == null:
		return
	if clip.is_empty():
		_player.pause()
		return
	if _player.current_animation != clip or not _player.is_playing():
		_player.play(clip)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif velocity.y < 0.0:
		velocity.y = -0.5

	if _wait > 0.0:
		_wait -= delta
		velocity.x = move_toward(velocity.x, 0.0, delta * 6.0)
		velocity.z = move_toward(velocity.z, 0.0, delta * 6.0)
		_play(_idle_clip)
		move_and_slide()
		return

	if not _has_target:
		if not _choose_target():
			_wait = _rng.randf_range(idle_min, idle_max)
			move_and_slide()
			return

	var to_target := _target - global_position
	to_target.y = 0.0
	if to_target.length() <= ARRIVE_DISTANCE:
		_has_target = false
		_wait = _rng.randf_range(idle_min, idle_max)
		velocity.x = 0.0
		velocity.z = 0.0
		_play(_idle_clip)
		move_and_slide()
		return

	var dir := to_target.normalized()
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed
	rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z) + yaw_offset, minf(1.0, TURN_RATE * delta))
	_play(_walk_clip)
	move_and_slide()


## Detailed animation trace for debugging playback/looping.
func debug_anim() -> String:
	if _player == null:
		return "no-anim"
	var a := _player.current_animation
	var len := _player.current_animation_length
	var loop := -1
	var anim := _player.get_animation(a) if not a.is_empty() else null
	if anim != null:
		loop = int(anim.loop_mode)
	return "%s clip=%s t=%.2f/%.2f loop=%d playing=%s speed=%.2f" % [
		name, a, _player.current_animation_position, len, loop,
		str(_player.is_playing()), _player.speed_scale]


## One-line runtime state, used by the spawner's headless diagnostics.
func debug_state() -> String:
	var anim := "none"
	if _player != null:
		anim = _player.current_animation if _player.is_playing() else _player.current_animation + "(paused)"
	return "%s pos=%s anim=%s floor=%s" % [name, global_position.snapped(Vector3(0.1, 0.1, 0.1)), anim, is_on_floor()]


## Short "walk/idle" summary used by the spawner's headless report.
func debug_clips() -> String:
	if _player == null:
		return "no-anim"
	return "%s/%s" % [_walk_clip if not _walk_clip.is_empty() else "-",
			_idle_clip if not _idle_clip.is_empty() else "-"]


## Pick a random reachable spot inside the home radius.  Returns false when
## every probe missed the ground (spawned against a wall or off the map).
func _choose_target() -> bool:
	var space := get_world_3d().direct_space_state
	for _attempt in 14:
		var angle := _rng.randf() * TAU
		# stay away from tiny shuffles: a trip should show a few walk cycles
		var dist := lerpf(wander_radius * 0.45, wander_radius, sqrt(_rng.randf()))
		var x := _home.x + cos(angle) * dist
		var z := _home.z + sin(angle) * dist
		var from := Vector3(x, _home.y + PROBE_HEIGHT, z)
		var to := Vector3(x, _home.y - PROBE_DEPTH, z)
		var query := PhysicsRayQueryParameters3D.create(from, to, ground_mask)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit.get("normal", Vector3.UP)
		if normal.y < 0.7:
			continue
		var point: Vector3 = hit.get("position", Vector3.ZERO)
		if absf(point.y - _home.y) > 3.0:
			continue
		_target = point
		_has_target = true
		return true
	_has_target = false
	return false
