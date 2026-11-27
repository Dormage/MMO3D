extends CharacterBody3D
## Third-person controller rebuilt around three invariants:
##   1. gravity is integrated every physics frame, even while idle;
##   2. when not jumping, a downward ray from the capsule centre glues the
##      capsule bottom to the surface it hits (terrain, bridge, prop or building);
##   3. horizontal velocity is exactly zero when there is no input.
## All island-rim / land-mask / step-assist heuristics from the previous pass are
## deliberately gone: they were the source of the slow push and the odd climbing.

const WALK_STRIDE_M := 0.9552  # long-leg stride; right is the longer step
const WALK_CYCLE := 1.0       # authored Walk clip length
const WALK_BASE_SPEED := 2.0 * WALK_STRIDE_M / WALK_CYCLE  # 1.9104 m/s
## Long-leg rig: 0.821 m thigh+shin, 0.9552 m right stride, 1.0 s cycle.
## WALK_SPEED_MULT scales body speed and WALK_RATE_MULT scales playback by the
## same 2.0, so the authored plant is preserved at 3.8208 m/s.  Keep these two
## equal unless deliberately testing a cadence mismatch.
const WALK_SPEED_MULT := 2.0
const SPEED := WALK_BASE_SPEED * WALK_SPEED_MULT  # 3.8208 m/s
const WALK_RATE_MULT := 2.0                     # matched to WALK_SPEED_MULT
const SPRINT := SPEED
const JUMP := 4.5
const GRAVITY := 20.0
const JUMP_BUFFER := 0.18
const MOUSE_SENS := 0.0032
const CAM_DIST := 4.4
const CAM_HEIGHT := 1.45
const ATTACK_CYCLE := 0.75
const CAPSULE_HALF := 0.85
const GLUE_EXTRA := 0.60
const FLOOR_SNAP := 0.55
## Keep the capsule origin a few millimetres above the sampled surface so the
## reported feet gap can never be microscopically negative on flat turf.
const FEET_CLEARANCE := 0.006
## Extra lift of the visible model above the capsule bottom.  The capsule stays
## glued to the terrain; this only raises the mesh so the boots read clear of
## the ground instead of intersecting it.
const FEET_LIFT := 0.10
const SelectionMarker := preload("res://scripts/selection_marker.gd")
const WeaponHolder := preload("res://scripts/weapon_holder.gd")
const WeaponTrail := preload("res://scripts/weapon_trail.gd")
## Equipped classes.  The animation clips are the ones already authored in the
## player GLB; no new skeleton animation is fabricated here.  Bows are absent
## because the rig has no bow-shot clip (see report).
const LOADOUTS := [
	{"id": "sword", "label": "Arming sword", "weapon": "weapon_arming_sword",
		"clip": "1H_Slash", "duration": 0.95, "tip": 0.84, "grip": Vector3.ZERO,
		"offhand": "", "shield_grip": Vector3.ZERO},
	{"id": "longsword", "label": "Longsword", "weapon": "weapon_longsword",
		"clip": "2H_Slash", "duration": 1.15, "tip": 1.00, "grip": Vector3.ZERO,
		"idle_grip": Vector3(0, 0, 20), "offhand": "", "shield_grip": Vector3.ZERO},
	{"id": "spear", "label": "Long spear", "weapon": "weapon_long_spear",
		"clip": "Thrust", "duration": 1.05, "tip": 1.68, "grip": Vector3.ZERO,
		"attack_grip": Vector3(-45, 0, -45), "offhand": "", "shield_grip": Vector3.ZERO},
	{"id": "staff", "label": "Curse staff", "weapon": "weapon_curse_staff",
		"clip": "2H_Slash", "duration": 1.10, "tip": 1.33, "grip": Vector3.ZERO,
		"offhand": "", "shield_grip": Vector3.ZERO},
	{"id": "sword_shield", "label": "Sword & shield", "weapon": "weapon_arming_sword",
		"clip": "SwordShield", "duration": 1.10, "tip": 0.84, "grip": Vector3.ZERO,
		"offhand": "shield_round", "shield_grip": Vector3(0, 180, 0)},
	{"id": "bow_great", "label": "Great bow", "weapon": "weapon_great_bow",
		"clip": "BowShot", "duration": 1.00, "tip": 0.85, "grip": Vector3.ZERO,
		"idle_grip": Vector3(-35, 0, 55), "bow": true, "trail_style": "bow",
		"offhand": "", "shield_grip": Vector3.ZERO},
	{"id": "bow_recurve", "label": "Recurve bow", "weapon": "weapon_recurve_bow",
		"clip": "BowShot", "duration": 1.00, "tip": 0.725, "grip": Vector3.ZERO,
		"idle_grip": Vector3(0, 0, 0), "bow": true, "trail_style": "bow",
		"offhand": "", "shield_grip": Vector3.ZERO},
]

var _pivot: Node3D
var _model: Node3D
var _holder: Node3D
var _shield_holder: Node3D
var _bow_holder: Node3D
var _weapon: Node3D
var _shield: Node3D
var _is_bow := false
var _trail_style := "slash"
var _trail: Node3D
var _selection_marker: Node3D
var inspection_freeze := false
var _frozen_anim_speed := 1.0
var _loadout_index := 0
var _attack_clip := "1H_Slash"
var _attack_duration := 0.95
var _weapon_tip := 0.84
var _arc_base := PackedVector3Array()
var _arc_tip := PackedVector3Array()
var _arc_ready := false
var _arc_gen := 0
var _camera: Camera3D
var _ap: AnimationPlayer
var _sk: Skeleton3D
var _attacking := false
var _settle_timer := 0.0
const ATTACK_SETTLE := 0.16
var _cam_yaw := 0.0
var _cam_pitch := -0.18
var _scripted := Vector2.ZERO
var _jump_requested := false
var _jump_buffer := 0.0
var _spawn_y := 0.0
var _current_clip := ""
var _grounded := false
var _jump_glue_skip := 0.0
var _model_low := 0.0
var _foot_bones: Array[int] = []
var _marker: Node3D
var _rim_meshes: Array[MeshInstance3D] = []
var _rim_material: ShaderMaterial
## Click-to-move.  The agent owns the path; the controller still performs the
## actual move_and_slide so terrain slope, bridges and building collision apply.
var _nav_agent: NavigationAgent3D
## Cached nav_world, found by group, used to veto steps into water.
var _water_nav: Node = null
var _prof_move_us := 0
var _prof_water_us := 0
var _path_calls := 0
var _guard_tick := 0
var _nav_active := false
var _walk_latch := 0.0
var _nav_wait := 0.0
var _nav_target := Vector3.ZERO
var _nav_started_ms := 0
var _nav_path := PackedVector3Array()
var _nav_index := 0
var _nav_stuck := 0.0
var _blocked_time := 0.0
var _stuck_total := 0.0
var _repaths := 0
var _steps := 0
var _attacks := 0
var _step_cooldown := 0.0


func _ready() -> void:
	collision_layer = 4
	collision_mask = 3
	up_direction = Vector3.UP
	floor_snap_length = 0.75
	floor_max_angle = deg_to_rad(60.0)
	floor_stop_on_slope = true
	floor_constant_speed = true
	_build_visual()
	_build_selection()
	_build_camera()
	_build_nav_agent()
	for i in 3:
		await get_tree().physics_frame
	_snap_to_ground()
	_fit_model_to_capsule()
	_play("Idle")
	if DisplayServer.get_name() != "headless":
		# Click-to-move RPG: cursor stays free for world clicks.
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await get_tree().process_frame
	_fit_model_to_capsule()


func _snap_to_ground() -> void:
	# Ask the map where to stand.  The previous world hardcoded (-2, 26); an
	# authored world must supply its own spawn or the player drops into a roof.
	var sp := Vector3(-2.0, 0.0, 26.0)
	var mp := get_parent().get_node_or_null("Map")
	if mp != null and mp.has_method("spawn_point"):
		sp = mp.call("spawn_point")
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(sp.x, sp.y + 50.0, sp.z), Vector3(sp.x, sp.y - 50.0, sp.z), 3)
	# The world's collision is created in Map._ready().  A single ray here can
	# land before those bodies reach the physics server, miss, and drop the
	# player at y=0 -- which buries his legs in an authored terrain that sits
	# metres higher.  Retry across physics frames until the ground answers.
	var gy := NAN
	for _attempt in 16:
		if mp != null and mp.has_method("spawn_point"):
			var fresh: Vector3 = mp.call("spawn_point")
			sp = fresh
			q = PhysicsRayQueryParameters3D.create(
					Vector3(sp.x, sp.y + 50.0, sp.z), Vector3(sp.x, sp.y - 50.0, sp.z), 3)
		var h := get_world_3d().direct_space_state.intersect_ray(q)
		if not h.is_empty():
			gy = float(h["position"].y)
			break
		await get_tree().physics_frame
	if is_nan(gy):
		push_warning("player: ground ray missed at %s; using spawn height" % str(sp))
		gy = sp.y
	global_position = Vector3(sp.x, gy + FEET_CLEARANCE, sp.z)
	velocity = Vector3.ZERO
	_spawn_y = global_position.y
	if _pivot != null:
		_pivot.rotation.y = PI
	print("PLAYER_SPAWN pos=%s ground=%.4f capsule_bottom=%.4f" % [
		global_position, gy, global_position.y])


func _build_visual() -> void:
	_pivot = Node3D.new()
	_pivot.name = "ModelPivot"
	add_child(_pivot)
	# GlbUtil falls back to a raw GLTF parse when there is no .import cache,
	# which is always the case in a freshly created project.
	_model = preload("res://scripts/glb_util.gd").instantiate("res://assets/models/player/player_animated.glb")
	if _model == null:
		push_error("player: model could not be loaded")
		return
	_pivot.add_child(_model)
	_sk = _model.find_child("Skeleton3D", true, false) as Skeleton3D
	if _sk != null:
		for i in _sk.get_bone_count():
			var bn := String(_sk.get_bone_name(i)).to_lower()
			if bn.contains("foot") or bn.contains("toe"):
				_foot_bones.append(i)
	_ap = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _ap != null:
		# Imported clips must not translate the visible model independently of
		# the capsule.  Root motion was a candidate for the slow drift.
		_ap.root_motion_track = NodePath()
	var fix: Node = load("res://scripts/idle_pose_fix.gd").new()
	fix.set("clips", PackedStringArray(["Idle"]))
	fix.set("enabled", true)
	_sk.add_child(fix)
	var grip: Node = load("res://scripts/grip_pose.gd").new()
	_sk.add_child(grip)
	# Right-hand weapon holder and left-hand shield holder.  Both are custom
	# pose followers, not BoneAttachment3D: the holder runs after the animation
	# and after the skeleton modifiers, so the grip is never one frame late.
	_holder = WeaponHolder.new()
	_holder.name = "WeaponHolder"
	_holder.set("bone", "RightHand")
	_sk.add_child(_holder)
	_shield_holder = WeaponHolder.new()
	_shield_holder.name = "ShieldHolder"
	_shield_holder.set("bone", "LeftHand")
	_sk.add_child(_shield_holder)
	_bow_holder = WeaponHolder.new()
	_bow_holder.name = "BowHolder"
	_bow_holder.set("bone", "LeftHand")
	_sk.add_child(_bow_holder)
	for gi in _model.find_children("*", "MeshInstance3D", true, false):
		(gi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_equip_loadout(0)
	_trail = WeaponTrail.new()
	_trail.name = "WeaponTrail"
	add_child(_trail)
	_trail.setup(_holder, _weapon_tip)
	_trail.set_anchor(_pivot)
	_selection_marker = _marker
	if _ap != null:
		for nm: String in ["Idle", "Walk"]:
			var a := _ap.get_animation(nm)
			if a != null:
				a.loop_mode = Animation.LOOP_LINEAR
		# The authored Idle clip translates the Hips vertically by ~7 cm.  The
		# skeleton is rotated -90 deg about X, so that world-vertical bob lives
		# on the Hips' LOCAL Z channel (local Y maps to world Z).  Flatten only
		# that channel; head/chest breathing and all rotations remain untouched.
		var idle := _ap.get_animation("Idle")
		if idle != null:
			var hips_track := idle.find_track(NodePath("Armature/Skeleton3D:Hips"), Animation.TYPE_POSITION_3D)
			if hips_track >= 0:
				var keys := idle.track_get_key_count(hips_track)
				var mean_x := 0.0
				var mean_y := 0.0
				var max_z := -1.0e20
				for k in keys:
					var v: Vector3 = idle.track_get_key_value(hips_track, k)
					mean_x += v.x
					mean_y += v.y
					max_z = maxf(max_z, v.z)
				mean_x /= float(keys)
				mean_y /= float(keys)
				# The skeleton is rotated -90 deg about X: local X is world side
				# sway, local Z is world vertical.  The authored Idle translates
				# the whole root on ALL THREE channels; that is what reads as
				# sliding/levitating.  Keep only rotations and a fixed root.
				for k in keys:
					var v: Vector3 = idle.track_get_key_value(hips_track, k)
					v.x = mean_x
					v.y = mean_y
					v.z = max_z
					idle.track_set_key_value(hips_track, k, v)
				print("PLAYER_IDLE_FLAT root=(%.4f,%.4f,%.4f) keys=%d" % [mean_x, mean_y, max_z, keys])
		# Walk was never flattened.  Its Hips position track drifts 0.318 m
		# forward in armature space (about 1.7 m after the model scale of 5.3),
		# so the visible skeleton snaps back every 0.75 s loop while the
		# capsule keeps walking.  That is the "teleport every few metres" and
		# the ring appears to lag because it tracks the capsule, not the Hips.
		# Pin the Hips root translation on every locomotion clip; rotations and
		# all breathing/stride motion below the Hips stay untouched.
		for nm: String in ["Walk", "StartWalk"]:
			if OS.get_environment("WALK_NO_FLAT") == "1":
				break
			var loc := _ap.get_animation(nm)
			if loc == null:
				continue
			for t in loc.get_track_count():
				if loc.track_get_type(t) != Animation.TYPE_POSITION_3D:
					continue
				if not String(loc.track_get_path(t)).ends_with(":Hips"):
					continue
				var keys := loc.track_get_key_count(t)
				if keys <= 1:
					continue
				var first: Vector3 = loc.track_get_key_value(t, 0)
				for k in keys:
					loc.track_set_key_value(t, k, first)
				print("PLAYER_LOCO_FLAT clip=%s track=%s keys=%d fixed=%s" % [
					nm, str(loc.track_get_path(t)), keys, str(first)])
		_flatten_attack_roots()
		_ap.animation_finished.connect(_on_anim_finished)


func _equip_loadout(index: int) -> void:
	if index < 0 or index >= LOADOUTS.size():
		return
	if _attacking:
		_attacking = false
		_show_weapon(false)
		_current_clip = ""
		if _ap != null:
			_ap.play("Idle", 0.10)
	_loadout_index = index
	var data: Dictionary = LOADOUTS[index]
	_attack_clip = String(data["clip"])
	_attack_duration = float(data["duration"])
	_weapon_tip = float(data["tip"])
	if _holder == null:
		return
	for c in _holder.get_children():
		c.free()
	for c in _shield_holder.get_children():
		c.free()
	for c in _bow_holder.get_children():
		c.free()
	_is_bow = bool(data.get("bow", false))
	_trail_style = String(data.get("trail_style", "slash"))
	var target_holder := _bow_holder if _is_bow else _holder
	_weapon = preload("res://scripts/glb_util.gd").instantiate("res://assets/models/weapons/%s.glb" % String(data["weapon"]))
	_weapon.name = "Weapon_" + String(data["id"])
	target_holder.add_child(_weapon)
	var idle_grip: Vector3 = data.get("idle_grip", data["grip"] if _is_bow else Vector3(0, 0, 90))
	target_holder.grip_rotation_by_clip = {
		"default": data["grip"], "Idle": idle_grip, "Walk": idle_grip,
		"StartWalk": idle_grip,
	}
	if data.has("attack_grip"):
		target_holder.grip_rotation_by_clip[_attack_clip] = data["attack_grip"]
	if _is_bow:
		target_holder.grip_rotation_by_clip[_attack_clip] = data["grip"]
	_holder.visible = not _is_bow
	_bow_holder.visible = _is_bow
	_shield = null
	if String(data.get("offhand", "")) != "" and not _is_bow:
		_shield = preload("res://scripts/glb_util.gd").instantiate("res://assets/models/weapons/%s.glb" % String(data["offhand"]))
		_shield.name = "Shield_" + String(data["id"])
		_shield_holder.add_child(_shield)
		_shield_holder.grip_rotation_by_clip = {"default": data.get("shield_grip", Vector3.ZERO)}
	_shield_holder.visible = _shield != null
	for gi in _weapon.find_children("*", "MeshInstance3D", true, false):
		(gi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if _trail != null:
		_trail.setup(target_holder, _weapon_tip)
		_trail.set_anchor(_pivot)
		_trail.set_active(false)
	print("WEAPON_EQUIPPED slot=%d id=%s weapon=%s clip=%s duration=%.2f tip=%.2f" % [
		index, String(data["id"]), String(data["weapon"]), _attack_clip,
		_attack_duration, _weapon_tip])


func _show_weapon(on: bool, trail := false) -> void:
	if _holder != null:
		_holder.visible = on and not _is_bow
	if _bow_holder != null:
		_bow_holder.visible = on and _is_bow
	if _shield_holder != null:
		_shield_holder.visible = on and _shield != null
	if _trail != null and _trail.has_method("set_active"):
		_trail.set_active(on and trail)


func _flatten_attack_roots() -> void:
	if _ap == null:
		return
	for clip in ["1H_Slash", "2H_Slash", "SwordShield", "Thrust", "BowShot"]:
		var a := _ap.get_animation(clip)
		if a == null:
			continue
		for t in a.get_track_count():
			if a.track_get_type(t) != Animation.TYPE_POSITION_3D:
				continue
			if not String(a.track_get_path(t)).ends_with(":Hips"):
				continue
			var keys := a.track_get_key_count(t)
			if keys <= 1:
				continue
			var first: Vector3 = a.track_get_key_value(t, 0)
			for k in keys:
				a.track_set_key_value(t, k, first)
			print("ATTACK_ROOT_FLAT clip=%s track=%s keys=%d fixed=%s" % [
				clip, str(a.track_get_path(t)), keys, str(first)])


## Sample the real weapon-tip path out of the current attack clip, in
## ModelPivot space.  The trail then draws a smooth arc regardless of frame rate.
## AnimationPlayer seek only refreshes bone poses on the next process frame, so
## this is an async deferred pass, never a synchronous loop inside _ready.
func _precompute_attack_arc() -> void:
	_arc_gen += 1
	_arc_ready = false
	_arc_base.clear()
	_arc_tip.clear()
	call_deferred("_precompute_attack_arc_async", _arc_gen)


func _precompute_attack_arc_async(gen: int) -> void:
	if gen != _arc_gen:
		return
	if _ap == null or _holder == null or _weapon == null or _attack_clip.is_empty():
		return
	var anim := _ap.get_animation(_attack_clip)
	if anim == null or anim.length <= 0.001:
		return
	var old := _ap.current_animation
	var old_speed := _ap.speed_scale
	_show_weapon(true)
	_ap.play(_attack_clip, 0.0)
	for i in 97:
		if gen != _arc_gen:
			return
		var t := anim.length * float(i) / 96.0
		_ap.seek(t, true)
		await get_tree().process_frame
		if gen != _arc_gen:
			return
		if _holder.has_method("_update"):
			_holder.call("_update")
		var b := _holder.global_transform * Vector3(0.0, _weapon_tip * 0.72, 0.0)
		var tip := _holder.global_transform * Vector3(0.0, _weapon_tip, 0.0)
		_arc_base.append(_pivot.global_transform.affine_inverse() * b)
		_arc_tip.append(_pivot.global_transform.affine_inverse() * tip)
	if gen != _arc_gen:
		return
	_ap.play(old if not old.is_empty() else "Idle", 0.0)
	_ap.speed_scale = old_speed
	_show_weapon(true, false)
	# The authored wrist flips produce a few 90-degree steps in the raw tip
	# samples.  Three light passes keep the real arc but remove the wire-loop
	# corners that read as a broken prop at 22 m.
	for _pass in range(3):
		var sb := _arc_base.duplicate()
		var st := _arc_tip.duplicate()
		for i in range(1, _arc_tip.size() - 1):
			sb[i] = (_arc_base[i - 1] + _arc_base[i] * 2.0 + _arc_base[i + 1]) * 0.25
			st[i] = (_arc_tip[i - 1] + _arc_tip[i] * 2.0 + _arc_tip[i + 1]) * 0.25
		_arc_base = sb
		_arc_tip = st
	if _trail != null:
		_trail.set_arc(_arc_base, _arc_tip, _pivot)
	_arc_ready = true
	var path_len := 0.0
	for i in range(1, _arc_tip.size()):
		path_len += _arc_tip[i].distance_to(_arc_tip[i - 1])
	print("ATTACK_ARC clip=%s samples=%d path=%.3f m" % [
		_attack_clip, _arc_tip.size(), path_len])


func _is_weapon_part(n: Node) -> bool:
	var p := n
	while p != null and p != _model:
		var pn := String(p.name)
		if pn == "WeaponHolder" or pn == "ShieldHolder":
			return true
		if pn.to_lower().contains("sword") or pn.to_lower().contains("weapon"):
			return true
		p = p.get_parent()
	return false


func _build_selection() -> void:
	_marker = SelectionMarker.new()
	_marker.name = "SelectionMarker"
	add_child(_marker)
	_selection_marker = _marker
	var rim := ShaderMaterial.new()
	rim.shader = load("res://shaders/player_rim.gdshader")
	_rim_material = rim
	for n in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null:
			continue
		mi.material_overlay = rim
		_rim_meshes.append(mi)


func set_selection_enabled(on: bool) -> void:
	if _marker != null:
		_marker.visible = on
	for mi in _rim_meshes:
		mi.material_overlay = _rim_material if on else null


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "PlayerCamera"
	_camera.near = 0.05
	_camera.far = 500.0
	_camera.fov = 65.0
	add_child(_camera)
	# Not current: the RPG camera in game_controller.gd is the game camera.
	_camera.current = false
	_camera.global_position = global_position + Vector3(0, CAM_HEIGHT + 1.0, CAM_DIST)


func _lowest_mesh_point() -> float:
	if _model == null:
		return 1.0e20
	var low := 1.0e20
	for n in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or _is_weapon_part(mi):
			continue
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			for v in vs:
				low = minf(low, (mi.global_transform * v).y)
	return low


func _fit_model_to_capsule() -> void:
	if _model == null or _pivot == null:
		return
	var low := _lowest_mesh_point()
	if low > 1.0e19:
		return
	# The capsule's bottom sits at the CharacterBody origin because its
	# CollisionShape3D is at local y=+0.85 for a 1.7 m capsule.  Therefore the
	# sole target is global_position.y, NOT global_position.y+half_height.
	# Measure the deformed sole vertices, not the long tunic hem: using the
	# absolute mesh minimum made the boots hang ~0.08 m above the ground.
	var sole := _sole_lowest_world()
	if sole > 1.0e19:
		sole = low
	_pivot.position.y += global_position.y - sole + FEET_LIFT
	_model_low = _lowest_mesh_point()
	print("PLAYER_MODEL_FIT sole=%.4f mesh_low=%.4f capsule_bottom=%.4f pivot_offset=%.4f" % [
		_sole_lowest_world(), _model_low, global_position.y, _pivot.position.y])


func _sole_lowest_world() -> float:
	# Skinned sole height: transform each foot-weighted vertex by
	#   skeleton_global * bone_pose * bind_pose^-1
	# so the value follows the Idle/Walk animation instead of the bind mesh.
	if _sk == null or _foot_bones.is_empty():
		return 1.0e20
	var low := 1.0e20
	for n in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or _is_weapon_part(mi) or mi.skin == null:
			continue
		var arr := mi.mesh.surface_get_arrays(0)
		if arr.is_empty() or arr[Mesh.ARRAY_BONES] == null:
			continue
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		for i in vs.size():
			for k in 4:
				var bi := bones[i * 4 + k]
				var w := weights[i * 4 + k]
				if w < 0.25 or not (bi in _foot_bones):
					continue
				var live := _sk.get_bone_global_pose(bi)
				var bind := mi.skin.get_bind_pose(bi)
				var p := _sk.global_transform * (live * bind.affine_inverse() * vs[i])
				low = minf(low, p.y)
	return low


func _fit_model_sole_only() -> void:
	if _pivot == null or _sk == null:
		return
	var sole := _sole_lowest_world()
	if sole > 1.0e19:
		return
	_pivot.position.y += global_position.y - sole + FEET_LIFT


func _glue_to_surface() -> void:
	if _jump_glue_skip > 0.0:
		_jump_glue_skip -= get_physics_process_delta_time()
		return
	if velocity.y > 0.05:
		_grounded = false
		return
	# Ray from the capsule centre, length half-height + 0.6.  The bottom of the
	# capsule is at the CharacterBody origin, so setting global_position.y to the
	# hit point puts the capsule bottom exactly on the surface.
	var origin := global_position + Vector3(0.0, CAPSULE_HALF, 0.0)
	var q := PhysicsRayQueryParameters3D.create(
			origin, origin + Vector3(0.0, -(CAPSULE_HALF + GLUE_EXTRA), 0.0), 3)
	q.exclude = [get_rid()]
	var h := get_world_3d().direct_space_state.intersect_ray(q)
	if not h.is_empty():
		global_position.y = float(h["position"].y) + FEET_CLEARANCE
		velocity.y = 0.0
		_grounded = true
	else:
		_grounded = false


func set_inspection_freeze(on: bool) -> void:
	if inspection_freeze == on:
		return
	inspection_freeze = on
	if _ap != null:
		if on:
			_frozen_anim_speed = _ap.speed_scale
			_ap.speed_scale = 0.0
		else:
			_ap.speed_scale = _frozen_anim_speed


func _unhandled_input(event: InputEvent) -> void:
	if inspection_freeze:
		return
	# Camera-relative mouse look is disabled in the RPG camera mode.  WASD still
	# works and cancels any active click path.
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		cancel_path()
	elif event is InputEventKey and event.pressed and not event.echo:
		var slot := int(event.keycode) - int(KEY_1)
		if slot >= 0 and slot < LOADOUTS.size():
			_equip_loadout(slot)
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		_attacks += 1
		play_attack()


func _physics_process(delta: float) -> void:
	if inspection_freeze:
		# Inspection camera holds the player at the exact transform, velocity
		# and animation state.  Do not gravity-step, cancel a path or re-ground.
		velocity = Vector3.ZERO
		return
	if _settle_timer > 0.0:
		_settle_timer = maxf(0.0, _settle_timer - delta)
		if _settle_timer <= 0.0 and not _attacking:
			_play("Idle")
	if _attacking or _settle_timer > 0.0:
		_scripted = Vector2.ZERO
	var input := _scripted
	if input == Vector2.ZERO:
		input = Vector2(
			float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
			float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S)))
	# Any manual input immediately cancels a click path.
	if input.length() > 0.01 and _nav_active:
		cancel_path()
	if _attacking or _settle_timer > 0.0:
		input = Vector2.ZERO
		_nav_active = false
	var sprint := Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_CTRL)
	var speed := SPRINT if sprint else SPEED
	if OS.get_environment("WALK_SPEED_TEST") != "":
		speed = float(OS.get_environment("WALK_SPEED_TEST"))
	var basis := Basis(Vector3.UP, _cam_yaw)
	var dir := basis.x * input.x - basis.z * input.y
	var has_input := dir.length() > 0.01
	var nav_dir := Vector3.ZERO
	if _nav_active:
		if _nav_wait > 0.0:
			_nav_wait -= delta
		elif _nav_path.size() > 1:
			# The game supplies the exact NavigationServer path so the agent's
			# internal query cannot disagree about the destination island.
			while _nav_index < _nav_path.size() - 1:
				var d := _nav_path[_nav_index] - global_position
				d.y = 0.0
				if d.length() > 0.45:
					break
				_nav_index += 1
			var next := _nav_path[_nav_index]
			nav_dir = next - global_position
			nav_dir.y = 0.0
			if _nav_index >= _nav_path.size() - 1 and nav_dir.length() < 0.26:
				_nav_active = false
				nav_dir = Vector3.ZERO
				if OS.get_environment("NAV_DEBUG") == "1":
					print("NAV_STOP final dist=%.2f idx=%d/%d pos=%s" % [nav_dir.length(), _nav_index, _nav_path.size(), global_position])
			elif nav_dir.length() < 0.05:
				_nav_active = false
				nav_dir = Vector3.ZERO
				if OS.get_environment("NAV_DEBUG") == "1":
					print("NAV_STOP zero idx=%d/%d pos=%s" % [_nav_index, _nav_path.size(), global_position])
			else:
				nav_dir = nav_dir.normalized()
				has_input = true
				dir = nav_dir
				input = Vector2(0.0, 1.0)
		elif _nav_agent != null:
			var next := _nav_agent.get_next_path_position()
			nav_dir = next - global_position
			nav_dir.y = 0.0
			if _nav_agent.is_navigation_finished() or nav_dir.length() < 0.22:
				_nav_active = false
				nav_dir = Vector3.ZERO
			else:
				nav_dir = nav_dir.normalized()
				has_input = true
				dir = nav_dir
				input = Vector2(0.0, 1.0)
	if has_input:
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		var _t_w := Time.get_ticks_usec()
		_water_guard(delta)
		_prof_water_us += Time.get_ticks_usec() - _t_w
	else:
		# No residual horizontal velocity, ever.  Do not clear the jump
		# request here: it must be consumed before any no-input bookkeeping,
		# otherwise a jump from rest is silently dropped.
		velocity.x = 0.0
		velocity.z = 0.0

	# Consume the request before gravity/early-outs.  Keep it buffered briefly
	# so a press that arrives just before landing fires as the capsule lands.
	var jump_now := _jump_requested or Input.is_key_pressed(KEY_SPACE)
	_jump_requested = false
	if jump_now:
		_jump_buffer = JUMP_BUFFER

	# Gravity is integrated on every physics frame, grounded or not.
	velocity.y -= GRAVITY * delta
	if _jump_buffer > 0.0 and _grounded:
		velocity.y = JUMP
		_grounded = false
		_jump_glue_skip = 0.18
		_jump_buffer = 0.0
	else:
		_jump_buffer = maxf(0.0, _jump_buffer - delta)

	var was_navating := _nav_active
	var before := global_position
	var _t_move := Time.get_ticks_usec()
	move_and_slide()
	_prof_move_us += Time.get_ticks_usec() - _t_move
	if not has_input and not was_navating:
		# Collision resolution must not accumulate into visible drift when no
		# key is held.  This is the no-input proof at the end of the frame.
		# Never do it on a frame that began in path-following: consuming the
		# last segment makes has_input false in that same frame, and restoring
		# the pre-move position produced the visible backward snap.
		global_position.x = before.x
		global_position.z = before.z
		velocity.x = 0.0
		velocity.z = 0.0
	_glue_to_surface()
	_step_cooldown = maxf(0.0, _step_cooldown - delta)
	if _nav_active and has_input:
		# `velocity` is the desired velocity, not the achieved one.  A step lip
		# can stop the capsule while move_and_slide leaves velocity at full
		# walk speed, so the old test never fired a step-up at low speed.
		# Use actual horizontal displacement and scale the threshold by the
		# distance this frame could have covered; this is speed-independent.
		var moved_xz := Vector2(global_position.x - before.x, global_position.z - before.z).length()
		var intended_xz := speed * delta
		var blocked := moved_xz < maxf(0.0025, intended_xz * 0.20)
		if blocked and _step_cooldown <= 0.0 and _try_step_up(dir):
			blocked = false
			_blocked_time = 0.0
			_stuck_total = 0.0
		if blocked:
			_nav_stuck += delta
			_blocked_time += delta
			_stuck_total += delta
			if _blocked_time > 0.30:
				_repath()
				_blocked_time = 0.0
			if _stuck_total > 5.0:
				_nav_active = false
				_nav_stuck = 0.0
				_stuck_total = 0.0
		else:
			_nav_stuck = 0.0
			_blocked_time = 0.0
			_stuck_total = 0.0
	if has_input:
		_pivot.rotation.y = lerp_angle(_pivot.rotation.y, atan2(dir.x, dir.z), 0.22)
	# The RPG camera in game_controller.gd follows the player; do not move the
	# old orbit camera every frame.
	if _camera != null and _camera.current:
		_update_camera()
	_update_animation(input, sprint)
	if _attacking and _trail != null and _ap != null:
		var attack_anim := _ap.get_animation(_attack_clip)
		if attack_anim != null and attack_anim.length > 0.001:
			_trail.set_progress(_ap.current_animation_position / attack_anim.length)
	if has_input:
		# Keep the planted sole on the surface while walking.  Idle is frozen:
		# a per-frame Idle fit made the visible model bob 6 cm in place.
		_fit_model_sole_only()


func _try_step_up(dir: Vector3) -> bool:
	# A click-RPG must walk small ledges.  Probe ahead at two distances: a short
	# probe lands on the face of a bridge deck once the lip is taller than the
	# capsule can slide over, which reads as a wall, so a longer probe is needed
	# to find the deck top.
	var f := Vector3(dir.x, 0.0, dir.z)
	if f.length_squared() < 0.01:
		return false
	f = f.normalized()
	var space := get_world_3d().direct_space_state
	for reach in [0.32, 0.62]:
		var fwd := global_position + f * float(reach)
		var q := PhysicsRayQueryParameters3D.create(
			fwd + Vector3(0, 1.05, 0), fwd + Vector3(0, -1.4, 0), 3)
		q.exclude = [get_rid()]
		var h := space.intersect_ray(q)
		if h.is_empty():
			continue
		var n: Vector3 = h["normal"]
		if n.y < cos(deg_to_rad(60.0)):
			continue
		var hp: Vector3 = h["position"]
		var rise := hp.y + FEET_CLEARANCE - global_position.y
		# The map is built from chunky blocks whose risers run 0.5-0.6 m, taller
		# than the old 0.45 m limit, so every stone staircase was a wall: the player
		# could neither walk them nor path them.  Match the art instead of the art
		# matching the controller.
		# Bridge decks sit higher again (~0.9 m lip), and being unable to climb one
		# meant the ramp was unreachable from the bank even with WASD.
		if rise <= 0.04 or rise > 0.95:
			continue
		# Keep the step local: do not snap forward more than the probe distance.
		global_position = Vector3(hp.x, hp.y + FEET_CLEARANCE, hp.z)
		velocity.y = 0.0
		velocity.x = f.x * SPEED
		velocity.z = f.z * SPEED
		_grounded = true
		_steps += 1
		_step_cooldown = 0.12
		return true
	return false


func _repath() -> void:
	if not _nav_active:
		return
	_path_calls += 1
	var path: PackedVector3Array = NavigationServer3D.map_get_path(
		get_world_3d().navigation_map, global_position, _nav_target, true)
	if path.size() >= 2:
		_nav_path = path
		_nav_index = 0
		_nav_wait = 0.04
		_nav_stuck = 0.0
		_repaths += 1
	else:
		# No alternate component: hold still rather than grind forever.
		_nav_active = false


func movement_debug() -> Dictionary:
	return {"repaths": _repaths, "steps": _steps, "attacks": _attacks,
		"blocked": _blocked_time, "stuck_total": _stuck_total,
		"floor_max_angle": floor_max_angle, "floor_snap": floor_snap_length}


func _update_animation(input: Vector2, sprint: bool) -> void:
	if _ap == null or _attacking or _settle_timer > 0.0:
		return
	# Do not derive the locomotion state from instantaneous velocity.  State
	# comes from intent/path, with a short latch so a single frame where the
	# nav segment is consumed/reactivated cannot restart the Walk clip at t=0.
	var moving := _nav_active or input.length() > 0.10
	if moving:
		_walk_latch = 0.18
	else:
		_walk_latch = maxf(0.0, _walk_latch - get_physics_process_delta_time())
	if _walk_latch > 0.0:
		_play("Walk")
	else:
		_play("Idle")


func _play(clip: String) -> void:
	if _ap == null or _current_clip == clip:
		return
	if not _ap.has_animation(clip):
		return
	_current_clip = clip
	var anim := _ap.get_animation(clip)
	var rate := 1.0
	if anim != null and anim.length > 0.001:
		if clip == "Walk":
			# Play at 1.0x: the leg rotations now carry the authored stride.
			rate = WALK_RATE_MULT
		elif clip == _attack_clip:
			rate = anim.length / _attack_duration
	_ap.play(clip, 0.18)
	_ap.speed_scale = rate


func _on_anim_finished(name: StringName) -> void:
	if String(name) == _attack_clip:
		_attacking = false
		# Hold the authored follow-through pose before blending back to Idle.
		# Without this the character snaps to Idle on the last attack frame.
		_settle_timer = ATTACK_SETTLE
		if _selection_marker != null:
			_selection_marker.visible = true
		_show_weapon(true, false)


func _update_camera() -> void:
	if _camera == null:
		return
	var target := global_position + Vector3(0, CAM_HEIGHT, 0)
	var rot := Basis(Vector3.UP, _cam_yaw) * Basis(Vector3.RIGHT, _cam_pitch)
	var offset := rot * Vector3(0, 0, CAM_DIST)
	var desired := target + offset
	var q := PhysicsRayQueryParameters3D.create(target, desired, 3)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		var hp: Vector3 = hit["position"]
		desired = hp + (target - hp).normalized() * 0.22
	_camera.global_position = desired
	_camera.look_at(target + Vector3(0, 0.15, 0), Vector3.UP)


func _build_nav_agent() -> void:
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.name = "NavAgent"
	_nav_agent.path_desired_distance = 0.45
	_nav_agent.target_desired_distance = 0.40
	_nav_agent.radius = 0.32
	_nav_agent.height = 1.7
	_nav_agent.avoidance_enabled = false
	add_child(_nav_agent)

## Click-to-move entry point.  The NavigationAgent3D performs the path query on
## the game's NavigationRegion3D map; the controller walks the returned corner
## list with move_and_slide.
func move_to(target: Vector3) -> bool:
	if _nav_agent == null:
		_build_nav_agent()
	_nav_target = target
	_nav_path = PackedVector3Array()
	_nav_index = 0
	_nav_agent.target_position = target
	_nav_active = true
	_nav_wait = 0.25
	_nav_started_ms = Time.get_ticks_msec()
	_nav_stuck = 0.0
	velocity.x = 0.0
	velocity.z = 0.0
	return true


## Follow an exact path produced by NavigationServer3D.map_get_path.  The
## NavigationAgent3D is still given the same final target (avoidance/debug),
## but movement uses the authoritative corner list.
func move_along(path: PackedVector3Array) -> bool:
	if path.size() < 2:
		return false
	if _nav_agent == null:
		_build_nav_agent()
	_nav_path = path
	_nav_index = 1
	_nav_target = path[path.size() - 1]
	if OS.get_environment("NAV_DEBUG") == "1":
		print("NAV_MOVE path=%d start=%s end=%s" % [path.size(), path[0], path[path.size()-1]])
	_nav_agent.target_position = _nav_target
	_nav_active = true
	_nav_wait = 0.15
	_nav_started_ms = Time.get_ticks_msec()
	_nav_stuck = 0.0
	velocity.x = 0.0
	velocity.z = 0.0
	return true

func cancel_path() -> void:
	_nav_active = false
	_nav_wait = 0.0
	_nav_path = PackedVector3Array()
	_nav_index = 0
	if _nav_agent != null:
		_nav_agent.target_position = global_position

func is_path_active() -> bool:
	return _nav_active

func nav_debug() -> Dictionary:
	return {"active": _nav_active, "index": _nav_index, "size": _nav_path.size(),
		"pos": global_position, "vel": velocity, "target": _nav_target,
		"next": _nav_path[_nav_index] if _nav_index < _nav_path.size() else Vector3.ZERO}

func get_nav_target() -> Vector3:
	return _nav_target

func get_nav_agent() -> NavigationAgent3D:
	if _nav_agent == null:
		_build_nav_agent()
	return _nav_agent


func set_scripted_input(v: Vector2) -> void:
	_scripted = v


func request_jump() -> void:
	_jump_requested = true


func debug_equip(index: int) -> void:
	_equip_loadout(index)


func debug_set_attack_grip(g: Vector3) -> void:
	if _holder == null:
		return
	_holder.grip_rotation_by_clip[_attack_clip] = g
	_holder.call("_update")


func debug_set_idle_grip(g: Vector3) -> void:
	if _holder == null:
		return
	_holder.grip_rotation_by_clip["Idle"] = g
	_holder.grip_rotation_by_clip["Walk"] = g
	_holder.grip_rotation_by_clip["StartWalk"] = g
	_holder.call("_update")


func get_arc_samples() -> int:
	return _arc_tip.size()


func get_arc_ready() -> bool:
	return _arc_ready


func set_attack_arc_progress(p: float) -> void:
	if _trail != null:
		_trail.set_progress(p)


func get_loadout_info() -> Dictionary:
	var data: Dictionary = LOADOUTS[_loadout_index]
	return {"slot": _loadout_index, "id": data["id"], "weapon": data["weapon"],
		"clip": _attack_clip, "duration": _attack_duration, "tip": _weapon_tip,
		"offhand": data.get("offhand", ""), "bow": _is_bow,
		"visible": (_bow_holder.visible if _is_bow else _holder.visible) if _holder != null else false}


func play_attack() -> void:
	if _ap == null or _attacking:
		return
	# Attacks are planted: stop a click path, drop scripted/key movement and
	# show the weapon only for the swing.
	cancel_path()
	_scripted = Vector2.ZERO
	velocity.x = 0.0
	velocity.z = 0.0
	_attacking = true
	_settle_timer = 0.0
	if _selection_marker != null:
		_selection_marker.visible = false
	if _trail != null:
		_trail.set_style(_trail_style)
	_show_weapon(true, true)
	_play(_attack_clip)


func get_camera() -> Camera3D:
	return _camera


func get_anim_name() -> String:
	if _ap == null:
		return ""
	return _ap.current_animation


func get_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func get_model() -> Node3D:
	return _model


func get_spawn_y() -> float:
	return _spawn_y


func get_capsule_bottom() -> float:
	return global_position.y


func get_model_lowest() -> float:
	return _lowest_mesh_point()


func get_sole_lowest() -> float:
	return _sole_lowest_world()


func get_support_point() -> Variant:
	var origin := global_position + Vector3(0.0, CAPSULE_HALF, 0.0)
	var q := PhysicsRayQueryParameters3D.create(
			origin, origin + Vector3(0.0, -(CAPSULE_HALF + GLUE_EXTRA), 0.0), 3)
	q.exclude = [get_rid()]
	var h := get_world_3d().direct_space_state.intersect_ray(q)
	return null if h.is_empty() else h["position"]


func set_cam_yaw(yaw: float) -> void:
	_cam_yaw = yaw


func set_cam_pitch(pitch: float) -> void:
	_cam_pitch = clampf(pitch, -1.10, 0.40)


## Refuse to step off dry ground into water.
##
## The navmesh already avoids the river, but a click can target a point on the
## bank and the last few centimetres of steering were enough to slide the
## character under a bridge.  Being already wet is allowed, so the player can
## always climb back out.
func _water_guard(delta: float) -> void:
	if _water_nav == null:
		_water_nav = get_tree().get_first_node_in_group("nav_world")
	if _water_nav == null:
		return
	# Sample every other physics frame: the guard only needs to catch a step of
	# a few centimetres, and two mask lookups per frame is wasteful at 60 Hz.
	_guard_tick += 1
	if _guard_tick & 1:
		return
	var feet := global_position + Vector3(0.0, 0.1, 0.0)
	if bool(_water_nav.call("is_water", feet)):
		return
	var step := Vector3(velocity.x, 0.0, velocity.z) * maxf(delta, 0.016) * 2.0
	if bool(_water_nav.call("is_water", feet + step)):
		velocity.x = 0.0
		velocity.z = 0.0


## Consume the movement counters for the perf log (call once per sample).
func perf_take() -> Array:
	var r := [_prof_move_us, _prof_water_us, _path_calls]
	_prof_move_us = 0
	_prof_water_us = 0
	_path_calls = 0
	return r
