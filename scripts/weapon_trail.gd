extends Node3D
## Attack arc from the actual animation, not from frame history.
##
## At 22 m the game often renders at 20-40 fps; a history ribbon then becomes a
## chain of rectangular cards or disappears.  The player controller samples the
## real weapon-tip path out of each attack clip once (in ModelPivot space), and
## this node draws the recent slice of that path.  The fallback history remains
## for diagnostics but is not normally used.

const MAX_AGE := 0.13
const MAX_POINTS := 18
const ARC_WINDOW := 0.15

var _holder: Node3D
var _tip_len := 0.9
var _tint := Color(1.0, 0.68, 0.22)
var _active := false
var _progress := 0.0
var _arc_base := PackedVector3Array()
var _arc_tip := PackedVector3Array()
var _anchor: Node3D
var _style := "slash"
var _points: Array[Dictionary] = []
var _mesh := ImmediateMesh.new()
var _mi := MeshInstance3D.new()
var _mat: StandardMaterial3D
var _clock := 0.0


func _ready() -> void:
	process_priority = 1001
	_mi.mesh = _mesh
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mi.top_level = true
	_mi.visible = false
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.albedo_color = Color(1, 1, 1, 1)
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.no_depth_test = true
	_mat.disable_receive_shadows = true
	add_child(_mi)


func setup(holder: Node3D, tip_len: float, tint: Color = Color(1.0, 0.56, 0.10)) -> void:
	_holder = holder
	_tip_len = tip_len
	_tint = tint
	_active = false
	_points.clear()
	_arc_base.clear()
	_arc_tip.clear()
	_mi.visible = false
	_mesh.clear_surfaces()


func set_tip(tip_len: float, tint: Color = Color(1.0, 0.56, 0.10)) -> void:
	_tip_len = tip_len
	_tint = tint


## Arrays are weapon-tip positions in ModelPivot local space.
func set_arc(base: PackedVector3Array, tip: PackedVector3Array, anchor: Node3D) -> void:
	_arc_base = base
	_arc_tip = tip
	_anchor = anchor


func set_anchor(anchor: Node3D) -> void:
	_anchor = anchor


func set_style(style: String) -> void:
	_style = style


func set_active(on: bool) -> void:
	_active = on
	_points.clear()
	_progress = 0.0
	_mi.visible = false
	_mesh.clear_surfaces()


func set_progress(p: float) -> void:
	_progress = clampf(p, 0.0, 1.0)


func _process(delta: float) -> void:
	if not _active or _holder == null or not _holder.is_visible_in_tree():
		if _mi.visible:
			_mi.visible = false
			_mesh.clear_surfaces()
		return
	if _anchor != null:
		_draw_weapon_arc()
		return
	# Fallback: frame-history ribbon.
	_clock += delta
	var base := _holder.global_transform * Vector3(0.0, _tip_len * 0.72, 0.0)
	var tip := _holder.global_transform * Vector3(0.0, _tip_len, 0.0)
	_points.append({"b": base, "t": tip, "time": _clock})
	while _points.size() > 2 and _clock - float(_points[0]["time"]) > MAX_AGE:
		_points.pop_front()
	while _points.size() > MAX_POINTS:
		_points.pop_front()
	if _points.size() < 2:
		_mi.visible = false
		return
	_mi.visible = true
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _mat)
	for i in range(1, _points.size()):
		var a: Dictionary = _points[i - 1]
		var b: Dictionary = _points[i]
		var age := _clock - float(a["time"])
		var fade := clampf(1.0 - age / MAX_AGE, 0.0, 1.0)
		_seg(a["b"], a["t"], b["t"], b["b"], fade)
	_mesh.surface_end()


## Clean, camera-readable trail tied to the current weapon tip.
##
## The authored attack clips contain a few very fast wrist flips; sampling their
## raw tip path produces 90-degree wire loops.  A constant-width crescent whose
## leading edge is the real current tip keeps the end attached to the weapon and
## gives a readable swing at 22 m.
func _draw_weapon_arc() -> void:
	if _holder == null or not _holder.is_visible_in_tree():
		_mi.visible = false
		return
	if _style == "bow":
		_draw_bow_streak()
		return
	var tip := _holder.global_transform * Vector3(0.0, _tip_len, 0.0)
	# Put the crescent in the weapon tip's own horizontal plane: the arc then
	# ends exactly at the blade tip instead of lying on the ground under it.
	var origin := Vector3(_anchor.global_transform.origin.x, tip.y, _anchor.global_transform.origin.z)
	var d := Vector2(tip.x - origin.x, tip.z - origin.z)
	if d.length() < 0.20:
		_mi.visible = false
		return
	var r := clampf(d.length(), 0.55, 1.65)
	var a_end := atan2(d.y, d.x)
	_mi.visible = true
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _mat)
	if _style == "thrust":
		# A spear thrust is a straight lance streak, not a crescent.
		var f := d.normalized()
		var side := Vector2(-f.y, f.x) * 0.100
		var a := Vector3(tip.x - f.x * 1.15, origin.y, tip.z - f.y * 1.15)
		var b := Vector3(tip.x, origin.y, tip.z)
		var a0 := Vector3(a.x - side.x, a.y, a.z - side.y)
		var a1 := Vector3(a.x + side.x, a.y, a.z + side.y)
		var b0 := Vector3(b.x - side.x * 0.35, b.y, b.z - side.y * 0.35)
		var b1 := Vector3(b.x + side.x * 0.35, b.y, b.z + side.y * 0.35)
		_v(a0, 0.0); _v(a1, 0.10); _v(b1, 0.55)
		_v(a0, 0.0); _v(b1, 0.55); _v(b0, 0.35)
	else:
		var span := 1.45
		var a_start := a_end - span
		var steps := 12
		var inner := r - 0.080
		var outer := r + 0.100
		for i in range(0, steps):
			var f0 := float(i) / float(steps)
			var f1 := float(i + 1) / float(steps)
			var q0 := a_start + span * f0
			var q1 := a_start + span * f1
			var i0 := Vector3(origin.x + cos(q0) * inner, origin.y, origin.z + sin(q0) * inner)
			var o0 := Vector3(origin.x + cos(q0) * outer, origin.y, origin.z + sin(q0) * outer)
			var i1 := Vector3(origin.x + cos(q1) * inner, origin.y, origin.z + sin(q1) * inner)
			var o1 := Vector3(origin.x + cos(q1) * outer, origin.y, origin.z + sin(q1) * outer)
			var fade0 := 0.08 + 0.50 * f0
			var fade1 := 0.08 + 0.50 * f1
			_v(i0, fade0 * 0.25); _v(o0, fade0); _v(o1, fade1)
			_v(i0, fade0 * 0.25); _v(o1, fade1); _v(i1, fade1 * 0.25)
	_mesh.surface_end()


## A bow has no swung tip.  Draw the release as a straight, tapered gold
## shaft from the bow hand along the character's facing, with a bright head.
func _draw_bow_streak() -> void:
	var f := Vector3.FORWARD
	if _anchor != null:
		f = _anchor.global_transform.basis.z
	f.y = 0.0
	if f.length_squared() < 0.0001:
		f = Vector3.FORWARD
	f = f.normalized()
	var side := f.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	side = side.normalized()
	# Offset the streak to the spear side so the bow itself stays legible
	# underneath it at 22 m.
	var base := _holder.global_transform.origin + side * 0.50 + Vector3(0.0, 0.20, 0.0)
	var tip := base + f * 2.10
	var w0 := 0.070
	var w1 := 0.012
	var h := Vector3(0.0, 0.10, 0.0)
	_mi.visible = true
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _mat)
	# Shaft: wide and faint at the bow, needle at the head.
	var a0 := base - side * w0
	var a1 := base + side * w0
	var b0 := tip - side * w1
	var b1 := tip + side * w1
	_v(a0, 0.05); _v(a1, 0.05); _v(b1, 0.65)
	_v(a0, 0.05); _v(b1, 0.65); _v(b0, 0.65)
	# Upper face offset a little so the streak reads against the ground.
	var c0 := a0 + h
	var c1 := a1 + h
	var d0 := b0 + h
	var d1 := b1 + h
	_v(c0, 0.10); _v(c1, 0.10); _v(d1, 0.95)
	_v(c0, 0.10); _v(d1, 0.95); _v(d0, 0.95)
	# Bright 4-point head at the leading end.
	var q := side * 0.15
	var u := Vector3(0.0, 0.20, 0.0)
	_v(tip - q, 0.90); _v(tip + q, 0.90); _v(tip + u, 1.0)
	_v(tip - q, 0.90); _v(tip + u, 1.0); _v(tip - u, 0.6)
	_mesh.surface_end()


func _draw_arc() -> void:
	var n := _arc_tip.size()
	# The clip's normalized progress selects the head of the sampled path; the
	# window behind it is the visible smear.
	var head := int(round(_progress * float(n - 1)))
	head = clampi(head, 1, n - 1)
	var tail := maxi(0, head - int(ceil(ARC_WINDOW * float(n - 1))))
	if head - tail < 1:
		_mi.visible = false
		return
	_mi.visible = true
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _mat)
	# Build a narrow ribbon along the tip path.  Connecting the grip and the tip
	# produced large triangular wings when the clip reversed direction; the tip
	# ribbon is a cleaner read at 22 m.
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	var have := false
	for i in range(tail, head + 1):
		var p0: Vector3 = _anchor.global_transform * _arc_tip[maxi(0, i - 1)]
		var p1: Vector3 = _anchor.global_transform * _arc_tip[i]
		var p2: Vector3 = _anchor.global_transform * _arc_tip[mini(n - 1, i + 1)]
		var tangent := (p2 - p0)
		if tangent.length_squared() < 0.000001:
			tangent = (p1 - p0)
		if tangent.length_squared() < 0.000001:
			continue
		tangent = tangent.normalized()
		var side := tangent.cross(Vector3.UP)
		if side.length_squared() < 0.000001:
			side = tangent.cross(Vector3.RIGHT)
		side = side.normalized() * 0.060
		var l := p1 - side
		var r := p1 + side
		if have:
			var fade := clampf(float(i - tail) / float(maxi(1, head - tail)), 0.0, 1.0)
			_v(prev_l, fade * 0.10)
			_v(prev_r, fade * 0.12)
			_v(r, fade * 0.55)
			_v(prev_l, fade * 0.10)
			_v(r, fade * 0.55)
			_v(l, fade * 0.55)
		prev_l = l
		prev_r = r
		have = true
	_mesh.surface_end()


func _seg(b0: Vector3, t0: Vector3, t1: Vector3, b1: Vector3, fade: float) -> void:
	_v(b0, fade * 0.10)
	_v(t0, fade * 0.62)
	_v(t1, fade * 0.62)
	_v(b0, fade * 0.10)
	_v(t1, fade * 0.62)
	_v(b1, fade * 0.10)


func _v(p: Vector3, alpha: float) -> void:
	_mesh.surface_set_color(Color(_tint.r, _tint.g, _tint.b, alpha))
	_mesh.surface_add_vertex(p)
