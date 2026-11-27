extends Node3D
## Cheap read-at-distance marker: ground ring + hovering diamond + warm fill.

var _ring: MeshInstance3D
var _indicator: MeshInstance3D
var _light: OmniLight3D
var _t := 0.0

func _ready() -> void:
	_build_ring()
	_build_indicator()
	_light = OmniLight3D.new()
	_light.name = "SelectionFill"
	_light.position = Vector3(0, 1.15, 0)
	_light.omni_range = 3.0
	_light.omni_attenuation = 1.8
	_light.light_energy = 0.55
	_light.light_color = Color(1.0, 0.78, 0.46)
	_light.shadow_enabled = false
	add_child(_light)

func _ring_texture() -> ImageTexture:
	var n := 256
	var im := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var p := Vector2((x + 0.5) / n * 2.0 - 1.0, (y + 0.5) / n * 2.0 - 1.0)
			var r := p.length()
			var core := smoothstep(0.78, 0.815, r) * (1.0 - smoothstep(0.855, 0.89, r))
			var glow := exp(-pow((r - 0.83) / 0.085, 2.0)) * 0.26
			var a := clampf(core * 0.92 + glow, 0.0, 0.95)
			im.set_pixel(x, y, Color(1.0, 0.80, 0.34, a))
	return ImageTexture.create_from_image(im)

func _indicator_texture() -> ImageTexture:
	var n := 64
	var im := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var p := Vector2((x + 0.5) / n * 2.0 - 1.0, (y + 0.5) / n * 2.0 - 1.0)
			# Downward chevron: two thick diagonal strokes meeting at the tip.
			var ay := absf(p.y + 0.18)
			var band := absf(absf(p.x) * 1.15 + ay - 0.62)
			var chev := (1.0 - smoothstep(0.10, 0.17, band)) * smoothstep(1.05, 0.70, p.y)
			var diamond := (1.0 - smoothstep(0.10, 0.14, absf(p.x) + absf(p.y) * 0.9 - 0.34))
			var a := clampf(chev + diamond * 0.25, 0.0, 1.0)
			im.set_pixel(x, y, Color(1.0, 0.84, 0.38, a))
	return ImageTexture.create_from_image(im)

func _build_ring() -> void:
	_ring = MeshInstance3D.new()
	_ring.name = "GroundRing"
	var q := QuadMesh.new()
	q.size = Vector2(2.25, 2.25)
	_ring.mesh = q
	_ring.rotation.x = -PI * 0.5
	_ring.position.y = 0.015
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.albedo_texture = _ring_texture()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.no_depth_test = false
	m.render_priority = 1
	_ring.material_override = m
	add_child(_ring)

func _build_indicator() -> void:
	_indicator = MeshInstance3D.new()
	_indicator.name = "SelectionDiamond"
	var q := QuadMesh.new()
	q.size = Vector2(0.46, 0.46)
	_indicator.mesh = q
	_indicator.position = Vector3(0, 2.20, 0)
	_indicator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.albedo_texture = _indicator_texture()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.render_priority = 2
	_indicator.material_override = m
	add_child(_indicator)

func _physics_process(_delta: float) -> void:
	# Follow in the same phase as CharacterBody3D motion.  Updating the ring
	# transform in _process while the capsule was moved in _physics_process
	# left the visual one render frame behind at movement start.
	if _ring == null:
		return
	var p := get_parent() as CharacterBody3D
	var n := Vector3.UP
	if p != null:
		n = p.get_floor_normal()
		_ring.global_position = p.global_position + Vector3(0, 0.015, 0)
	if n.length_squared() < 0.1:
		n = Vector3.UP
	n = n.normalized()
	var tilt := Basis(Quaternion(Vector3.UP, n))
	_ring.transform.basis = tilt * Basis(Vector3.RIGHT, -PI * 0.5)
	var s := 1.0 + 0.035 * sin(_t * 3.1)
	_ring.scale = Vector3(s, s, s)


func _process(delta: float) -> void:
	_t += delta
	if _ring != null:
		var m := _ring.material_override as StandardMaterial3D
		if m != null:
			m.albedo_color = Color(1, 1, 1, 0.86 + 0.10 * sin(_t * 3.1))
	if _indicator != null:
		_indicator.position.y = 2.20 + 0.015 * sin(_t * 2.4)
		_indicator.rotation.y = _t * 0.8
