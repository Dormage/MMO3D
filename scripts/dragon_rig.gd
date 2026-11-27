extends SkeletonModifier3D
## Procedural flight layers, applied AFTER the baked Hover clip.
##
## The clip only really moves the wings (36 deg) and the tail (10 deg); the neck,
## head and jaw are keyed but flat (measured: head 0.00 deg, jaw 0.02 deg, hips
## 0.00 deg across the whole cycle).  Rather than re-author five clips in Blender
## for seven dragons, this adds the missing secondary motion at runtime:
##
##   * head/neck look-at, split across three bones with limits, so a dragon can
##     watch the player, look down at the islands, or look back over its shoulder
##   * a travelling tail wave with per-segment lag, whose direction slowly flips
##   * breathing on the spine, a jaw that opens when climbing
##
## SkeletonModifier3D runs after the AnimationPlayer, so this composes with the
## clip instead of fighting it.

@export var look_enabled := true
@export var look_target := Vector3.ZERO
@export_range(0.0, 1.0) var look_weight := 1.0
@export_range(0.5, 12.0) var look_speed := 3.0
@export_range(20.0, 180.0) var look_yaw_limit_deg := 128.0
@export_range(-90.0, 0.0) var look_pitch_min_deg := -62.0
@export_range(0.0, 90.0) var look_pitch_max_deg := 54.0
## Below this distance the look-at is faded out, so a dragon does not try to
## stare at a target inside its own chest.
@export_range(0.0, 40.0) var look_near_fade := 7.0

@export_range(0.0, 40.0) var tail_amp_deg := 11.0
@export_range(0.05, 4.0) var tail_speed := 0.55
@export_range(0.0, 2.0) var tail_lag := 0.62
@export_range(0.0, 0.5) var tail_flip_speed := 0.045

@export_range(0.0, 10.0) var breathe_amp_deg := 1.8
@export_range(0.0, 3.0) var breathe_speed := 0.42
@export_range(0.0, 40.0) var jaw_open_deg := 0.0
@export_range(0.0, 45.0) var climb_pitch_deg := 0.0
## Extra wing amplitude on top of the baked clip, driven by speed: a dragon
## beating harder as it accelerates, not just faster.
@export_range(0.0, 30.0) var flap_boost_deg := 0.0
@export_range(0.2, 3.0) var flap_rate := 1.0

const TAIL_BONES := 6

var _t := 0.0
var _yaw := 0.0
var _pitch := 0.0
var _phase := 0.0
var _flap_phase := 0.0
var _bones := {}


func _ready() -> void:
	# a stable per-instance phase so seven dragons do not wave in unison
	_phase = float(absi(hash(str(get_path()))) % 1000) / 1000.0 * TAU


func _lookup(skel: Skeleton3D) -> void:
	_bones.clear()
	for name in ["spine", "neck1", "neck2", "head", "jaw"]:
		_bones[name] = skel.find_bone(name)
	for i in range(TAIL_BONES):
		_bones["tail%d" % (i + 1)] = skel.find_bone("tail%d" % (i + 1))


func _rotate_axis(skel: Skeleton3D, idx: int, axis: Vector3, angle: float) -> void:
	if idx < 0 or absf(angle) < 0.000001:
		return
	var basis := skel.get_bone_global_rest(idx).basis
	var local_axis := (basis.inverse() * axis).normalized()
	skel.set_bone_pose_rotation(idx,
			skel.get_bone_pose_rotation(idx) * Quaternion(local_axis, angle))


func _rotate(skel: Skeleton3D, idx: int, yaw: float, pitch: float) -> void:
	if idx < 0:
		return
	# convert world up/right into this bone's local frame using its rest basis:
	# stable, and the clip barely rotates these bones anyway
	var basis := skel.get_bone_global_rest(idx).basis
	var inv := basis.inverse()
	var up := (inv * Vector3.UP).normalized()
	var right := (inv * Vector3.RIGHT).normalized()
	var q := Quaternion(up, yaw) * Quaternion(right, pitch)
	skel.set_bone_pose_rotation(idx, skel.get_bone_pose_rotation(idx) * q)


func _process_modification_with_delta(delta: float) -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	if _bones.is_empty():
		_lookup(skel)
	_t += delta

	var breathe := deg_to_rad(breathe_amp_deg) * sin(_t * breathe_speed * TAU + _phase)
	var climb := deg_to_rad(climb_pitch_deg)

	# ---- look-at: the whole point of a head ----
	if look_enabled and look_weight > 0.0:
		var xf := skel.global_transform
		var to := look_target - xf.origin
		var dist := to.length()
		if dist > 0.01:
			var local := xf.basis.inverse() * to
			# new dragon meshes face local +Z (not the old +X)
			var yaw := atan2(local.x, local.z)
			var horizontal := sqrt(local.x * local.x + local.z * local.z)
			var pitch := atan2(local.y, maxf(horizontal, 0.001))
			yaw = clampf(yaw, -deg_to_rad(look_yaw_limit_deg), deg_to_rad(look_yaw_limit_deg))
			pitch = clampf(pitch, deg_to_rad(look_pitch_min_deg), deg_to_rad(look_pitch_max_deg))
			# fade in with distance so a target at the origin cannot twist the neck
			var fade := clampf(dist / maxf(look_near_fade, 0.01), 0.0, 1.0)
			var k := clampf(delta * look_speed, 0.0, 1.0)
			_yaw = lerp_angle(_yaw, yaw * look_weight * fade, k)
			_pitch = lerpf(_pitch, pitch * look_weight * fade, k)
			# lerp_angle takes the short path through +-180, so a target that
			# flips sides can drag the accumulated angle past the limit and
			# wrap the neck around. Clamp the result, not just the target.
			var yaw_lim := deg_to_rad(look_yaw_limit_deg)
			_yaw = clampf(_yaw, -yaw_lim, yaw_lim)
			_pitch = clampf(_pitch, deg_to_rad(look_pitch_min_deg),
					deg_to_rad(look_pitch_max_deg))

	# the neck takes the first third, the head carries the rest; the spine
	# counter-rotates slightly so the body twists with the look
	_rotate(skel, _bones.get("spine", -1), -_yaw * 0.16, breathe * 0.5 - climb * 0.25)
	_rotate(skel, _bones.get("neck1", -1), _yaw * 0.28, _pitch * 0.24 - climb * 0.35)
	_rotate(skel, _bones.get("neck2", -1), _yaw * 0.30, _pitch * 0.26 - climb * 0.30)
	_rotate(skel, _bones.get("head", -1), _yaw * 0.42, _pitch * 0.50 + climb * 0.45)
	_rotate(skel, _bones.get("jaw", -1), 0.0, deg_to_rad(jaw_open_deg) * 0.9 + breathe * 0.3)

	# ---- wings: extra amplitude with speed ----
	# The clip gives the beat; this makes the beat *harder* as the dragon
	# accelerates, which is the cue that it is putting effort in.
	if flap_boost_deg > 0.05:
		_flap_phase += delta * flap_rate * TAU
		var boost := deg_to_rad(flap_boost_deg) * sin(_flap_phase)
		var wl: int = _bones.get("wingA.L", -1)
		var wr: int = _bones.get("wingA.R", -1)
		_rotate_axis(skel, wl, Vector3.RIGHT, boost)
		_rotate_axis(skel, wr, Vector3.RIGHT, -boost)

	# ---- tail: a travelling wave, direction slowly inverting ----
	var flip := sin(_t * tail_flip_speed * TAU + _phase * 1.7)
	var phase := _t * tail_speed * TAU + _phase
	for i in range(TAIL_BONES):
		var idx: int = _bones.get("tail%d" % (i + 1), -1)
		if idx < 0:
			continue
		var f := float(i) / float(TAIL_BONES - 1)
		var amp := deg_to_rad(tail_amp_deg) * (0.18 + 0.82 * f) * flip
		var wave := sin(phase - float(i) * tail_lag)
		_rotate(skel, idx, amp * wave, amp * wave * 0.28 + breathe * (0.2 + 0.5 * f))
