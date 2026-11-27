extends SkeletonModifier3D
## Closes the fingers around a weapon grip.
##
## The Mixamo locomotion/combat clips barely animate fingers, so the rest pose's
## open hand leaves a sword sitting in a flat palm. This runs AFTER the
## AnimationPlayer (which is the point of a SkeletonModifier3D) and adds a fixed
## curl to each finger joint, so every clip holds the weapon rather than
## balancing it. Disable it for unarmed or gesture clips.

## Overall curl multiplier. 0 = open hand, 1 = the tuned fist below.
@export_range(0.0, 1.5) var strength := 1.0
## Flip if the fingers curl backwards on a differently-oriented rig.
@export var invert := false
## Degrees of curl per joint for the four main fingers (proximal -> distal).
@export var finger_curl := [-22.0, -42.0, -52.0, -34.0]
## Degrees of curl per joint for the thumb.
@export var thumb_curl := [-12.0, -26.0, -30.0]

const FINGERS := ["Index", "Middle", "Ring", "Pinky"]
const SIDES := ["Left", "Right"]


func _process_modification_with_delta(_delta: float) -> void:
	var skel := get_skeleton()
	if skel == null or is_zero_approx(strength):
		return
	var sign := -1.0 if invert else 1.0
	for side in SIDES:
		for f in FINGERS:
			for joint in range(1, finger_curl.size() + 1):
				var name := "%sHand%s%d" % [side, f, joint]
				_curl(skel, name, deg_to_rad(float(finger_curl[joint - 1]) * strength * sign))
		for joint in range(1, thumb_curl.size() + 1):
			_curl(skel, "%sHandThumb%d" % [side, joint],
					deg_to_rad(float(thumb_curl[joint - 1]) * strength * sign))


func _curl(skel: Skeleton3D, bone_name: String, angle: float) -> void:
	var idx := skel.find_bone(bone_name)
	if idx < 0:
		return
	# rotate about the bone's own X, which is perpendicular to the finger
	var basis := skel.get_bone_global_rest(idx).basis
	var axis := (basis.inverse() * Vector3.RIGHT).normalized()
	skel.set_bone_pose_rotation(idx,
			skel.get_bone_pose_rotation(idx) * Quaternion(axis, angle))
