extends Node3D
## Single-quad landing marker.  One mesh, one material; show_at only moves it.

var _mi: MeshInstance3D
var _mat: ShaderMaterial

func _ready() -> void:
	var q := QuadMesh.new()
	q.size = Vector2(1.0, 1.0)
	_mi = MeshInstance3D.new()
	_mi.name = "HoverRingQuad"
	_mi.mesh = q
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/hover_ring.gdshader")
	_mi.material_override = _mat
	_mi.rotation.x = -PI * 0.5
	_mi.visible = false
	add_child(_mi)

func show_at(p: Vector3, walkable: bool, radius: float = 0.62) -> void:
	_mi.visible = true
	# Sit the quad on the actual surface normal, not flat at a fixed +3.5 cm.
	# A flat quad on a slope had one side buried by the heightfield, which is
	# what produced the open "C" instead of a closed landing ring.
	var n := Vector3.UP
	var q := PhysicsRayQueryParameters3D.create(
		p + Vector3(0, 0.8, 0), p + Vector3(0, -1.6, 0), 1)
	var h := get_world_3d().direct_space_state.intersect_ray(q)
	if not h.is_empty():
		var hn: Vector3 = h["normal"]
		if hn.length_squared() > 0.1:
			n = hn.normalized()
	var basis := Basis(Quaternion(Vector3.UP, n)) * Basis(Vector3.RIGHT, -PI * 0.5)
	_mi.global_transform = Transform3D(basis, p + n * 0.055)
	_mi.scale = Vector3(radius * 2.0, radius * 2.0, 1.0)
	_mat.set_shader_parameter("ring_color",
		Color(0.88, 0.97, 1.0, 0.72) if walkable else Color(1.0, 0.22, 0.16, 0.78))

func hide_ring() -> void:
	_mi.visible = false
