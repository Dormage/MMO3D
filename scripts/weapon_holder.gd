extends Node3D
## Attaches a weapon to an animated bone.
##
## Godot 4.6 contract: Skeleton3D.get_bone_global_pose(idx) is the bone's global
## pose *in skeleton space* (the same space BoneAttachment3D consumes). The world
## transform is therefore
##
##     skeleton.global_transform * skeleton.get_bone_global_pose(idx) * grip
##
## and both factors are required. Dropping the skeleton transform puts the hand
## at y=0.063 instead of y=1.179 in the rest pose; dropping the bone pose puts it
## at the skeleton origin. player_animated.glb carries the glTF Z-up -> Y-up
## conversion on the Skeleton3D node (basis.y = +Z, basis.z = -Y), which is why
## the raw bone pose is in a Z-up frame.
##
## Rig convention: the RightHand bone's +Y continues the forearm and exits the
## fist. Weapon GLBs have the grip at (0,0,0) and the blade along +Y, so
## grip_rotation_deg = (0,0,0) already seats the blade along the hand's outward
## axis. grip_offset is in bone space and is not rotated by the grip rotation.

@export var bone := "RightHand"
## Euler rotation (Godot's default YXZ order) in bone space. Zero = blade along
## the hand's +Y, i.e. continuing the forearm. Used only when the clip map below
## has neither the current clip nor a "default" entry.
@export var grip_rotation_deg := Vector3.ZERO
## Per-clip bone-space grip overrides, keyed by the AnimationPlayer's current
## clip name. "default" applies to any clip without its own entry.
##
## Identity is right for the attack clips: the RightHand +Y continues the
## forearm (dot 0.974) and the blade is +Y. Idle is the exception: the arm hangs
## down, so a point-down 0.92 m blade reaches 0.20 m below the ground. The Idle
## entry pitches the blade forward and to the character's right at 37 deg below
## horizontal (22 deg right of forward). The Idle arm modifier rotates the hand,
## so this Euler is solved with that modifier active; measured tip y is 0.1516 m
## at t=0.6 and >= 0.0580 m over the whole 8.35 s clip.
@export var grip_rotation_by_clip: Dictionary = {
	"Idle": Vector3(-11.247, 4.229, -41.112),
	"default": Vector3.ZERO,
}
## Translation in bone space. The weapon GLBs already put the grip centre at
## (0,0,0), so 0 is correct for them; a model whose grip origin is not the hand
## point can be slid along +Y (wrist -> knuckles) or across the palm here.
@export var grip_offset := Vector3.ZERO
## Run after the AnimationPlayer so the pose read here is the pose drawn this frame.
@export var process_after_animation := true
## Optional explicit AnimationPlayer; empty = the first one above the skeleton.
@export var animation_player_path: NodePath

var _sk: Skeleton3D
var _idx := -1
var _ap: AnimationPlayer


func _ready() -> void:
	var p := get_parent()
	while p != null and _sk == null:
		if p is Skeleton3D:
			_sk = p as Skeleton3D
		p = p.get_parent()
	if _sk == null:
		push_warning("weapon_holder: no Skeleton3D ancestor")
		set_process(false)
		return
	_idx = _sk.find_bone(bone)
	if _idx < 0:
		push_warning("weapon_holder: bone %s not found" % bone)
		set_process(false)
		return
	_ap = _find_animation_player()
	if _ap == null:
		push_warning("weapon_holder: no AnimationPlayer found; clip overrides disabled")
	if process_after_animation:
		# AnimationPlayer defaults to 0; higher priorities process later.
		process_priority = 1000
	_update()


func _find_animation_player() -> AnimationPlayer:
	if not animation_player_path.is_empty():
		return get_node_or_null(animation_player_path) as AnimationPlayer
	var n: Node = _sk
	while n != null:
		var ap := n.get_node_or_null("AnimationPlayer") as AnimationPlayer
		if ap != null:
			return ap
		n = n.get_parent()
	return null


## Clip name currently driving the skeleton, or "" if none.
func current_clip() -> String:
	if _ap == null:
		return ""
	var name := _ap.current_animation
	if name.is_empty():
		name = _ap.assigned_animation
	return name


## Bone-space grip rotation for the clip that is playing now.
func active_grip_rotation_deg() -> Vector3:
	var clip := current_clip()
	if not clip.is_empty() and grip_rotation_by_clip.has(clip):
		return grip_rotation_by_clip[clip]
	if grip_rotation_by_clip.has("default"):
		return grip_rotation_by_clip["default"]
	return grip_rotation_deg


func _process(_delta: float) -> void:
	_update()


## World transform the weapon should use. Public so tests can compare against
## the node's actual global_transform.
func bone_world_transform() -> Transform3D:
	if _sk == null or _idx < 0:
		return Transform3D()
	return _sk.global_transform * _sk.get_bone_global_pose(_idx)


func grip_basis() -> Basis:
	var r := active_grip_rotation_deg()
	return Basis.from_euler(Vector3(
			deg_to_rad(r.x),
			deg_to_rad(r.y),
			deg_to_rad(r.z)))


func _update() -> void:
	if _sk == null or _idx < 0:
		return
	if _ap == null:
		_ap = _find_animation_player()
	# get_bone_global_pose() recomputes a dirty chain, so this is never a frame
	# behind the skinned mesh after process_after_animation has ordered us last.
	global_transform = bone_world_transform() * Transform3D(grip_basis(), grip_offset)
