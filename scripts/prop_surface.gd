extends RefCounted
class_name PropSurface
## Runtime-only procedural materials for props.  The GLB meshes and palette
## slot names are untouched; this only replaces the visible prop materials and
## feeds each member's local extents/seed to the shader through instance
## uniforms.

const SHADER := preload("res://shaders/prop_surface.gdshader")

static var _mats: Dictionary = {}
static var _debug_mats: Dictionary = {}

static func _debug_colors() -> Dictionary:
	return {0: Color(1, 0, 1), 1: Color(1, 0, 0), 2: Color(0, 0, 1), 3: Color(1, 1, 0)}

static func material(kind: int, color: Color, debug: bool = false) -> ShaderMaterial:
	var key := "%d|%s|%s" % [kind, color.to_html(), debug]
	if _mats.has(key):
		return _mats[key]
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("prop_kind", kind)
	m.set_shader_parameter("base_color", color)
	m.set_shader_parameter("shadow_sky", Color(0.16, 0.18, 0.21))
	m.set_shader_parameter("roughness_value", 0.93)
	m.set_shader_parameter("debug_mask", debug)
	if debug:
		var dc: Color = _debug_colors().get(kind, Color(0, 1, 0))
		m.set_shader_parameter("debug_color", dc)
	m.resource_name = "prop_%d_%s" % [kind, color.to_html()]
	_mats[key] = m
	return m

static func _seed_for(mi: MeshInstance3D, salt: int) -> float:
	var n := absi(hash("%s_%d_%d" % [String(mi.name), mi.get_instance_id(), salt]))
	return float(n % 10007) / 10007.0

static func _extent(mi: MeshInstance3D) -> Vector3:
	var ab := mi.get_aabb()
	if ab.size.length() < 0.0001:
		return Vector3(0.5, 0.5, 0.5)
	return ab.size * 0.5

static func bind(mi: MeshInstance3D, seed: float) -> void:
	mi.set_instance_shader_parameter("prop_extent", _extent(mi))
	mi.set_instance_shader_parameter("prop_center", mi.get_aabb().get_center())
	mi.set_instance_shader_parameter("prop_seed", seed)

static func dress(mi: MeshInstance3D, kind: int, color: Color, seed: float,
		debug: bool = false) -> void:
	if mi == null or mi.mesh == null:
		return
	var m := material(kind, color, debug)
	mi.material_override = m
	bind(mi, seed)

static func _slot(src: Material) -> String:
	if src == null:
		return ""
	var n := String(src.resource_name).get_slice(".", 0).to_lower()
	# Palette debug materials are named debug_wood / debug_stone; strip the
	# prefix so prop masks can be produced through the same path.
	if n.begins_with("debug_"):
		n = n.substr(6)
	return n

static func apply_slots(root: Node3D, kind: int, color: Color,
		slots: Array, debug: bool = false) -> int:
	if root == null:
		return 0
	var n := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var seed := _seed_for(mi, kind)
		var extent := _extent(mi)
		var applied := false
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s)
			if not slots.has(_slot(src)):
				continue
			if not applied:
				mi.set_instance_shader_parameter("prop_extent", extent)
				mi.set_instance_shader_parameter("prop_center", mi.get_aabb().get_center())
				mi.set_instance_shader_parameter("prop_seed", seed)
				applied = true
			mi.set_surface_override_material(s, material(kind, color, debug))
			if OS.get_environment("PROP_LOG") == "1" and mi.get_parent() != null:
				var mm := mi.get_surface_override_material(s) as ShaderMaterial
				print("PROP_APPLY parent=%s kind=%d debug=%s shader=%s prop_kind=%s" % [
					String(mi.get_parent().name), kind, str(debug),
					String(mm.shader.resource_path) if mm != null and mm.shader != null else "none",
					str(mm.get_shader_parameter("prop_kind")) if mm != null else "none"])
			n += 1
	return n

static func apply_ruins(root: Node3D, debug: bool = false) -> int:
	return apply_slots(root, 1, Color(0.235, 0.220, 0.190, 1.0),
			["mat_stone", "mat_marble", "stone"], debug)

static func apply_village(root: Node3D, model: String, debug: bool = false) -> int:
	var m := String(model).to_lower()
	var kind := 0
	var color := Color(0.20, 0.13, 0.075, 1.0)
	if m.contains("barrel") or m.contains("woodpile"):
		kind = 2
		color = Color(0.155, 0.118, 0.082, 1.0)
	elif m.contains("crate"):
		kind = 3
		color = Color(0.160, 0.122, 0.084, 1.0)
	elif m.contains("cart") or m.contains("fence") or m.contains("sign"):
		kind = 0
		color = Color(0.145, 0.125, 0.095, 1.0)
	elif m.contains("market"):
		kind = 0
		color = Color(0.165, 0.120, 0.082, 1.0)
	else:
		return 0
	# Keep metal hoops/corners/ironwork as the palette metal; only wood is
	# re-dressed.
	return apply_slots(root, kind, color, ["wood"], debug)

## Give a generated bridge BoxMesh member the prop shader and per-instance
## extents/seed.  The caller passes the actual mesh size.
static func bridge_member(mi: MeshInstance3D, kind: int, color: Color,
		size: Vector3, seed: float, debug: bool = false) -> void:
	mi.set_instance_shader_parameter("prop_extent", size * 0.5)
	mi.set_instance_shader_parameter("prop_center", Vector3.ZERO)
	mi.set_instance_shader_parameter("prop_seed", seed)
	mi.material_override = material(kind, color, debug)
