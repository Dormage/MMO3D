class_name PopulationActor
extends CharacterBody3D
## One ambient actor (monster or townsperson) that walks a small home radius.
##
## The GLB is loaded through glb_util so it also works headless, before Godot
## has written import sidecars. Movement is steering + gravity, no navmesh:
## a target is probed onto the ground collision inside the home radius, the
## actor walks there, idles/emotes, and repeats.

const GRAVITY := 24.0
const ARRIVE_DISTANCE := 0.35
const TURN_RATE := 5.5
const PROBE_HEIGHT := 40.0
const PROBE_DEPTH := 24.0

@export var model_path: String = ""
@export var display_name: String = ""
@export var move_speed: float = 1.0
@export var wander_radius: float = 4.0
@export var idle_min: float = 1.6
@export var idle_max: float = 4.5
@export var model_height: float = 1.8
@export var body_radius: float = 0.4
@export var model_scale: float = 1.0
## Vertical shift so the model's feet sit on the actor origin.
@export var foot_offset: float = 0.0
@export var yaw_offset: float = 0.0
@export var ground_mask: int = 1
## Probability that an idle pause plays a one-shot emote instead of idling.
@export var emote_chance: float = 0.0
## Role used for the emote: "attack" for monsters, "wave" for townsfolk.
@export var emote_role: String = "attack"
## Filled by the spawner from the region map so actors do not walk into water.
@export var water_level: float = -1.0e9
@export var water_cells: PackedByteArray = PackedByteArray()

var _player: AnimationPlayer
var _clips: Dictionary = {}
var _home := Vector3.ZERO
var _target := Vector3.ZERO
var _has_target := false
var _wait := 0.0
var _emote_time := 0.0
var _stuck := 0.0
var _dead := false
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	var diagnostic_args := OS.get_cmdline_user_args()
	if diagnostic_args.has("--nopop"):
		# Also cover directly authored actors and actors added after the
		# controller's diagnostic pass; do not even load their visual assets.
		visible = false
		collision_layer = 0
		collision_mask = 0
		set_physics_process(false)
		process_mode = Node.PROCESS_MODE_DISABLED
		return
	_rng.randomize()
	add_to_group("population")
	_home = global_position
	if diagnostic_args.has("--minphys"):
		# Keep the model and idle animation so this switch isolates physics.
		collision_layer = 0
		collision_mask = 0
		set_physics_process(false)
	else:
		_build_body()
	_load_model()
	_wait = _rng.randf_range(0.3, idle_max)
	_play_idle()


func _build_body() -> void:
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = maxf(body_radius, 0.18)
	capsule.height = maxf(model_height, capsule.radius * 2.0 + 0.1)
	shape.shape = capsule
	shape.position.y = capsule.height * 0.5
	add_child(shape)
	collision_layer = 4
	collision_mask = ground_mask | 2
	floor_max_angle = deg_to_rad(55.0)
	floor_snap_length = 0.9


func _load_model() -> void:
	var node: Node = preload("res://scripts/glb_util.gd").instantiate(model_path)
	if node == null:
		push_warning("PopulationActor: could not load %s" % model_path)
		return
	node.name = "Model"
	if not is_equal_approx(model_scale, 1.0):
		node.scale = Vector3.ONE * model_scale
	node.position.y = foot_offset
	add_child(node)

	for n in node.find_children("*", "AnimationPlayer", true, false):
		_player = n as AnimationPlayer
		break
	if _player == null:
		push_warning("PopulationActor: no AnimationPlayer in %s" % model_path)
		return

	var names := _player.get_animation_list()
	_clips = {
		"walk": _pick(names, ["walk"]),
		"run": _pick(names, ["run"]),
		"idle": _pick(names, ["idle", "idle_neutral"]),
		"attack": _pick(names, ["attack", "sword_slash", "punch", "shoot_small", "gun_shoot"]),
		"hit": _pick(names, ["hit", "hitreact", "hitrecieve", "hit_reaction"]),
		"die": _pick(names, ["die", "death", "dead"]),
		"wave": _pick(names, ["wave", "yes", "hello", "no"]),
	}
	# Character Soldier only ships a run take; use it as locomotion.
	if _clips["walk"] == "":
		_clips["walk"] = _clips["run"]
	_loop(_clips["walk"])
	_loop(_clips["run"])
	_loop(_clips["idle"])


func _pick(names: PackedStringArray, wanted: Array) -> String:
	for want in wanted:
		for n in names:
			if n.to_lower() == String(want).to_lower():
				return n
	return ""


func _loop(clip: String) -> void:
	if clip.is_empty() or _player == null:
		return
	var anim := _player.get_animation(clip)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR


func _play(clip: String, blend: float = 0.12) -> void:
	if _player == null or clip.is_empty():
		return
	if _player.current_animation != clip or not _player.is_playing():
		_player.play(clip, blend)


func _play_idle() -> void:
	_play(String(_clips.get("idle", "")))


func _start_idle() -> void:
	_has_target = false
	_wait = _rng.randf_range(idle_min, idle_max)
	_emote_time = 0.0
	var emote := String(_clips.get("wave", "")) if emote_role == "wave" else String(_clips.get("attack", ""))
	if not emote.is_empty() and _rng.randf() < emote_chance:
		var a := _player.get_animation(emote)
		_emote_time = a.length if a != null else 1.0
		_play(emote, 0.10)
	else:
		_play_idle()


func _physics_process(delta: float) -> void:
	if _dead:
		move_and_slide()
		return

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif velocity.y < 0.0:
		velocity.y = -0.5

	if _emote_time > 0.0:
		_emote_time -= delta
		_slow_to_stop(delta)
		move_and_slide()
		if _emote_time <= 0.0:
			_play_idle()
		return

	if _wait > 0.0:
		_wait -= delta
		_slow_to_stop(delta)
		if String(_clips.get("idle", "")) != "":
			_play_idle()
		move_and_slide()
		return

	if not _has_target:
		if not _choose_target():
			_start_idle()
			move_and_slide()
			return

	var to_target := _target - global_position
	to_target.y = 0.0
	var distance := to_target.length()
	if distance <= ARRIVE_DISTANCE:
		_slow_to_stop(delta)
		_start_idle()
		move_and_slide()
		return

	var dir := to_target / distance
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed
	rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z) + yaw_offset,
			minf(1.0, TURN_RATE * delta))
	_play(String(_clips.get("walk", "")))
	var before := global_position
	move_and_slide()
	# If we are pressed into a wall, or slid almost nowhere, pick another spot.
	if global_position.distance_to(before) < move_speed * delta * 0.25:
		_stuck += delta
		if _stuck > 1.4:
			_stuck = 0.0
			_has_target = false
	else:
		_stuck = 0.0

	if global_position.y < _home.y - 12.0:
		global_position = _home + Vector3.UP * 0.1
		velocity = Vector3.ZERO


func _slow_to_stop(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, delta * 7.0)
	velocity.z = move_toward(velocity.z, 0.0, delta * 7.0)


## Pick a random reachable spot inside the home radius.
func _choose_target() -> bool:
	var space := get_world_3d().direct_space_state
	for _attempt in 18:
		var angle := _rng.randf() * TAU
		var dist := lerpf(wander_radius * 0.35, wander_radius, sqrt(_rng.randf()))
		var x := _home.x + cos(angle) * dist
		var z := _home.z + sin(angle) * dist
		var from := Vector3(x, _home.y + PROBE_HEIGHT, z)
		var to := Vector3(x, _home.y - PROBE_DEPTH, z)
		var query := PhysicsRayQueryParameters3D.create(from, to, ground_mask)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit.get("normal", Vector3.UP)
		if normal.y < 0.70:
			continue
		var point: Vector3 = hit.get("position", Vector3.ZERO)
		if absf(point.y - _home.y) > 2.8:
			continue
		if _is_water(point):
			continue
		if _blocked_at(point, 0.45):
			continue
		_target = point
		_has_target = true
		return true
	_has_target = false
	return false


func _blocked_at(point: Vector3, radius: float) -> bool:
	var space := get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = radius
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis(), point + Vector3.UP * 0.55)
	params.collision_mask = 2
	return not space.intersect_shape(params, 1).is_empty()


func _is_water(point: Vector3) -> bool:
	if water_cells.size() != 163 * 163:
		return false
	if point.y > water_level + 0.10:
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
					and water_cells[jj * 163 + ii] != 0:
				return true
	return false


## --- diagnostics ---------------------------------------------------------

func debug_clips() -> String:
	return "walk=%s idle=%s attack=%s die=%s" % [
		String(_clips.get("walk", "-")), String(_clips.get("idle", "-")),
		String(_clips.get("attack", "-")), String(_clips.get("die", "-"))]


func anim_check() -> String:
	if _player == null:
		return "no-animation-player"
	var parts: Array[String] = []
	for role in ["walk", "run", "idle", "attack", "hit", "die"]:
		var clip := String(_clips.get(role, ""))
		if clip.is_empty():
			parts.append("%s=MISSING" % role)
		elif _player.has_animation(clip):
			parts.append("%s=%s" % [role, clip])
		else:
			parts.append("%s=BROKEN(%s)" % [role, clip])
	return " ".join(parts)


func debug_state() -> String:
	var anim := "none"
	if _player != null:
		anim = _player.current_animation if _player.is_playing() else _player.current_animation + "(paused)"
	var offset := global_position - _home
	offset.y = 0.0
	return "%s pos=%s home_dist=%.2f anim=%s floor=%s" % [
		name, global_position.snapped(Vector3(0.1, 0.1, 0.1)), offset.length(), anim,
		is_on_floor()]


func kill() -> void:
	var die := String(_clips.get("die", ""))
	if die.is_empty() or _player == null:
		return
	_dead = true
	velocity = Vector3.ZERO
	_player.play(die, 0.1)
