extends SkeletonModifier3D
## Idle-only additive pose correction.
##
## Why this exists:
##  - The chibi torso is wide relative to the relaxed-arm pose, so the Idle hand
##    sits inside the tunic (right hand x - tunic.min.x = -0.018 m at t=0.6).
##  - The Idle Hips drop without enough knee flexion, so the boot soles go below
##    y=0: -0.115 m at t=0.6 and -0.191 m at the worst of a 20-frame sweep.
##
## Measured with this modifier (20-frame Idle sweep, t=0.05..8.30):
##  - right hand clearance 0.0950 m at t=0.6, minimum 0.0868 m;
##    left  hand clearance 0.0742 m at t=0.6, minimum 0.0704 m
##  - sole, knee/foot rotation only: -0.1876 m (the 3 deg knee + 2 deg foot
##    only recover ~3 mm; the shin/foot levers are too short)
##  - sole with `foot_lift`: +0.0032 m worst; vertical lift 0.058..0.209 m
##  - Idle blade tip minimum 0.0580 m (t=6.56) with the 37 deg Idle grip; 1H_Slash and Walk measure
##    identical to a player without this node.
##
## It changes only the current pose; it never edits the GLB. It is inert in
## every clip except the ones listed in `clips`, so Walk and the attacks stay
## untouched, and unarmed Idle can disable or remove this node.
##
## The rotation-only result cannot meet the sole target: a 0.26 m shin rotated
## 3 deg raises the ankle 0.4 mm and a 0.15 m foot pitched 2 deg raises the sole
## ~5 mm. The residual `foot_lift` is therefore the part that actually grounds
## the boots; it shortens the visible leg at the ankle, so the boot shaft slides
## up by that amount at the deepest bob. Set `foot_lift = false` to inspect the
## rotation-only compromise.

@export var enabled := true
## Clip names this correction applies to. Default: Idle only.
@export var clips: PackedStringArray = ["Idle"]

## Upper-arm abduction (degrees). Left arm is +, right arm is - about world +Z.
@export_range(0.0, 30.0) var arm_out_deg := 12.0
## Upper-arm forward swing (degrees) about world X.
@export_range(0.0, 20.0) var arm_forward_deg := 4.0
## Extra forearm abduction (degrees) about world +Z.
@export_range(0.0, 20.0) var forearm_out_deg := 6.0

## Knee flexion (degrees) about world X. Small angles barely change the ankle
## height; this is kept because it is the natural direction and it moves the
## foot clear of the shin when the foot lift is applied.
@export_range(0.0, 15.0) var knee_bend_deg := 3.0
## Toe-up foot pitch (degrees) about world X.
@export_range(0.0, 15.0) var foot_pitch_deg := 2.0

## Residual vertical foot lift. Disable to see rotation-only behaviour.
## DELIBERATE COMPROMISE: this pins the boots to the floor while the Hips bob,
## so at the deepest frame (t=6.56) the boot shaft rides up the shin by up to
## 0.209 m. That was accepted: a planted boot reads better than a floating
## character, and a dynamic Hips lift would undo the grounded Idle root. Do not
## "fix" this by lifting the Hips without re-verifying the head height.
@export var foot_lift := true
## Distance from the foot bone (ankle) to the lowest boot-sole vertex. The
## worst frame over the Idle sweep is 0.141 m; 0.142 leaves ~3 mm clearance.
@export var sole_offset := 0.142
## Desired sole height ABOVE THE PLAYER ROOT (character feet), in metres.
## This is a relative offset, not a world Y: the 2026-11 world-Y target lifted
## an ankle 1.1 m up a shin on low ground and folded both knees into the torso.
@export var sole_clearance := 0.005
## Hard cap on the residual vertical foot translation. A target error must
## never be able to collapse the leg again.
@export_range(0.0, 0.20, 0.005) var max_foot_lift := 0.06

## Yaw of the character in world space.  The abduction/swing axes below are
## body axes: 0 means the character faces +Z (the pose this fix was tuned on).
## Turn the character and set this to the same yaw, otherwise the world-space
## arm corrections fold the arm the wrong way across the chest.
@export_range(-6.283, 6.283, 0.001) var facing_yaw := 0.0

## Optional explicit AnimationPlayer; empty = first one above the skeleton.
@export var animation_player_path: NodePath

var _ap: AnimationPlayer
var _base_pos := {}
var _body: CharacterBody3D
var _target_y := 0.0


func _ready() -> void:
	_ap = _find_ap()
	# The skeleton's SkeletonModifier3D pass runs before the AnimationPlayer in
	# this player scene. Run the same correction from _process at a high priority
	# so it lands after the clip, exactly like weapon_holder.gd does.
	process_priority = 900
	set_process(true)
	set_physics_process(true)
	_body = _find_body()
	var skel := get_skeleton()
	var root_y := _body.global_position.y if _body != null else (skel.global_transform.origin.y if skel != null else 0.0)
	_target_y = root_y + sole_clearance
	if skel != null:
		for side in ["Left", "Right"]:
			var idx := skel.find_bone(side + "Foot")
			if idx >= 0:
				_base_pos[idx] = skel.get_bone_pose_position(idx)


func _find_body() -> CharacterBody3D:
	var n: Node = get_parent()
	while n != null:
		if n is CharacterBody3D:
			return n as CharacterBody3D
		n = n.get_parent()
	return null


func _physics_process(_delta: float) -> void:
	var root_y := 0.0
	if _body != null:
		root_y = _body.global_position.y
	else:
		var skel := get_skeleton()
		if skel != null:
			root_y = skel.global_transform.origin.y
	_target_y = root_y + sole_clearance


func _find_ap() -> AnimationPlayer:
	var n: Node = get_skeleton()
	while n != null:
		var ap := n.get_node_or_null("AnimationPlayer") as AnimationPlayer
		if ap != null:
			return ap
		n = n.get_parent()
	return null


func _current_clip() -> String:
	if _ap == null:
		return ""
	var name := _ap.current_animation
	if name.is_empty():
		name = _ap.assigned_animation
	return name


func _process(delta: float) -> void:
	_process_modification_with_delta(delta)


func _process_modification_with_delta(_delta: float) -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	if not enabled:
		_clear_feet(skel)
		return
	if _ap == null:
		_ap = _find_ap()
	if _ap == null:
		return
	if not clips.has(_current_clip()):
		# The Idle lift writes the (unanimated) foot position; without this it
		# would leak into the next clip. Walk/attacks are otherwise untouched.
		_clear_feet(skel)
		return
	_arms(skel)
	_legs(skel)


func _arms(skel: Skeleton3D) -> void:
	_arm(skel, "LeftArm", "LeftForeArm", 1.0)
	_arm(skel, "RightArm", "RightForeArm", -1.0)


func _body_forward() -> Vector3:
	return Basis(Vector3.UP, facing_yaw) * Vector3(0, 0, 1)


func _body_right() -> Vector3:
	return Basis(Vector3.UP, facing_yaw) * Vector3(1, 0, 0)


func _arm(skel: Skeleton3D, arm_name: String, fore_name: String, sign: float) -> void:
	var arm := skel.find_bone(arm_name)
	if arm >= 0:
		# Abduct about body forward, then swing slightly forward.
		_rotate_world(skel, arm, _body_forward(), sign * deg_to_rad(arm_out_deg))
		_rotate_world(skel, arm, _body_right(), -deg_to_rad(arm_forward_deg))
	var fore := skel.find_bone(fore_name)
	if fore >= 0:
		_rotate_world(skel, fore, _body_forward(), sign * deg_to_rad(forearm_out_deg))


func _legs(skel: Skeleton3D) -> void:
	for side in ["Left", "Right"]:
		var leg := skel.find_bone(side + "Leg")
		if leg >= 0:
			_rotate_world(skel, leg, _body_right(), deg_to_rad(knee_bend_deg))
		var foot := skel.find_bone(side + "Foot")
		if foot >= 0:
			_rotate_world(skel, foot, _body_right(), -deg_to_rad(foot_pitch_deg))
			if foot_lift:
				_lift_foot(skel, foot)
			else:
				_set_foot_base(skel, foot)


## Rotate a bone about a world-space axis through its own head. The axis is
## converted through the bone's current global basis, so it works regardless of
## the parent's animated orientation.
func _rotate_world(skel: Skeleton3D, idx: int, axis_world: Vector3, angle: float) -> void:
	if absf(angle) < 1e-7:
		return
	var g := skel.global_transform * skel.get_bone_global_pose(idx)
	var axis_local := (g.basis.inverse() * axis_world).normalized()
	skel.set_bone_pose_rotation(idx,
			skel.get_bone_pose_rotation(idx) * Quaternion(axis_local, angle))


## Raise the foot bone vertically until the measured sole is at the player-root
## relative target. The translation is in the parent bone's current space, so
## it is a pure world-Y shift independent of the animated leg orientation.
## The target is refreshed every physics frame and the residual is hard-clamped
## so a bad ground/root value can never turn into a metre-scale shin collapse.
func _lift_foot(skel: Skeleton3D, idx: int) -> void:
	# The Idle clip does not animate the foot translation, so the previous
	# frame's lift is still in the pose. Reset to the rest base first, otherwise
	# the lift alternates between "already lifted" and "dropped".
	var base: Vector3 = _base_pos.get(idx, skel.get_bone_pose_position(idx))
	skel.set_bone_pose_position(idx, base)
	var g := skel.global_transform * skel.get_bone_global_pose(idx)
	var lift := _target_y - (g.origin.y - sole_offset)
	lift = clampf(lift, 0.0, max_foot_lift)
	if lift <= 0.0:
		return
	var pidx := skel.get_bone_parent(idx)
	var p := skel.global_transform * skel.get_bone_global_pose(pidx)
	var up := (p.basis.inverse() * Vector3(0, 1, 0)).normalized()
	skel.set_bone_pose_position(idx, base + up * lift)


## Remove any previously applied lift (the position channel is not animated by
## the Idle clip, so it must be reset explicitly).
func _set_foot_base(skel: Skeleton3D, idx: int) -> void:
	if _base_pos.has(idx):
		skel.set_bone_pose_position(idx, _base_pos[idx])


func _clear_feet(skel: Skeleton3D) -> void:
	for side in ["Left", "Right"]:
		var idx := skel.find_bone(side + "Foot")
		if idx >= 0:
			_set_foot_base(skel, idx)
