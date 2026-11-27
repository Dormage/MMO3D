extends Node3D
## Builds the inspection scene at runtime: environment, ground, the rigged
## dragon with its animations, a few props, and the fly camera.

const DRAGON := "res://assets/dragon.glb"
const PROPS := {
	"boulder": "res://assets/boulder.glb",
	"column": "res://assets/column.glb",
	"statue": "res://assets/statue.glb",
	"tree": "res://assets/tree.glb",
}

var anim_player: AnimationPlayer
var anim_names: Array[String] = []
var current_anim: String = ""
var anim_label: Label


func _ready() -> void:
	_build_environment()
	_build_ground()
	_build_props()
	_build_dragon()
	_build_camera()
	_build_hud()


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.16, 0.24, 0.38)
	sky_mat.sky_horizon_color = Color(0.52, 0.55, 0.60)
	sky_mat.ground_bottom_color = Color(0.10, 0.09, 0.08)
	sky_mat.ground_horizon_color = Color(0.34, 0.33, 0.31)
	sky_mat.sun_angle_max = 12.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.ssao_enabled = true
	env.ssao_radius = 1.6
	env.ssao_intensity = 1.4
	env.glow_enabled = true
	env.glow_intensity = 0.25
	env.fog_enabled = false

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-46), deg_to_rad(38), 0)
	sun.light_energy = 1.7
	sun.light_color = Color(1.0, 0.96, 0.90)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.rotation = Vector3(deg_to_rad(-18), deg_to_rad(220), 0)
	fill.light_energy = 0.35
	fill.light_color = Color(0.72, 0.80, 1.0)
	fill.shadow_enabled = false
	add_child(fill)


func _build_ground() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(240, 240)

	var body := StaticBody3D.new()
	body.name = "Ground"
	var mi := MeshInstance3D.new()
	mi.name = "GroundMesh"
	mi.mesh = plane
	mi.material_override = _checker_material()
	body.add_child(mi)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(240, 0.2, 240)
	col.shape = shape
	col.position = Vector3(0, -0.1, 0)
	body.add_child(col)
	add_child(body)


func _checker_material() -> StandardMaterial3D:
	# procedural checker so motion and scale read clearly while inspecting
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in n:
		for x in n:
			var on := ((x / 8) + (y / 8)) % 2 == 0
			img.set_pixel(x, y, Color(0.30, 0.31, 0.30) if on else Color(0.24, 0.25, 0.24))
	var tex := ImageTexture.create_from_image(img)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.uv1_scale = Vector3(24, 24, 1)
	mat.roughness = 0.95
	return mat


func _build_props() -> void:
	var placements := {
		"boulder": [Vector3(-9.0, 0.0, -7.0), 0.0, 1.0],
		"column": [Vector3(9.5, 0.0, -8.5), 0.5, 1.0],
		"statue": [Vector3(-11.5, 0.0, 6.0), -0.6, 1.0],
		"tree": [Vector3(12.0, 0.0, 7.5), 0.0, 1.0],
	}
	for key in PROPS.keys():
		var packed := load(PROPS[key]) as PackedScene
		if packed == null:
			push_warning("could not load %s" % PROPS[key])
			continue
		var inst := packed.instantiate() as Node3D
		var p = placements[key]
		inst.position = p[0]
		inst.rotation.y = p[1]
		inst.name = key.capitalize()
		add_child(inst)


func _build_dragon() -> void:
	var packed := load(DRAGON) as PackedScene
	if packed == null:
		push_error("dragon.glb failed to load")
		return
	var dragon := packed.instantiate() as Node3D
	dragon.name = "Dragon"
	add_child(dragon)

	anim_player = _find_anim_player(dragon)
	if anim_player == null:
		push_warning("no AnimationPlayer found in dragon.glb")
		return

	anim_names.assign(anim_player.get_animation_list())
	# loop everything so the rig keeps moving
	for n in anim_names:
		var a := anim_player.get_animation(n)
		if a:
			a.loop_mode = Animation.LOOP_LINEAR

	print("dragon animations: ", anim_names)
	_play_matching("idle")


func _find_anim_player(root: Node) -> AnimationPlayer:
	var direct := root.find_child("AnimationPlayer", true, false)
	if direct is AnimationPlayer:
		return direct
	return _recurse_anim(root)


func _recurse_anim(n: Node) -> AnimationPlayer:
	for c in n.get_children():
		if c is AnimationPlayer:
			return c
		var found := _recurse_anim(c)
		if found:
			return found
	return null


func _play_matching(needle: String) -> void:
	if anim_player == null:
		return
	for n in anim_names:
		if n.to_lower().contains(needle):
			anim_player.play(n)
			current_anim = n
			_update_hud()
			return


func _build_camera() -> void:
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	pivot.set_script(load("res://scripts/fly_camera.gd"))
	pivot.position = Vector3(14.0, 7.0, 16.0)
	# yaw chosen so the view starts aimed at the origin
	pivot.rotation.y = 0.72

	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 70.0
	cam.near = 0.05
	cam.far = 500.0
	pivot.add_child(cam)
	add_child(pivot)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.55)
	style.set_corner_radius_all(6)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)

	var label := Label.new()
	label.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
	label.add_theme_font_size_override("font_size", 14)
	label.text = _hud_text()
	panel.add_child(label)
	anim_label = label


func _hud_text() -> String:
	var current := current_anim if current_anim != "" else "(none)"
	return "\n".join([
		"WASD move    Space/Ctrl up-down    Shift fast    Wheel speed",
		"Mouse look    Esc release cursor    click to recapture",
		"1 Idle   2 Walk   3 Attack   4 Fly",
		"",
		"Animation: %s" % current,
	])


func _update_hud() -> void:
	if anim_label:
		anim_label.text = _hud_text()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				_play_matching("idle")
			KEY_2:
				_play_matching("walk")
			KEY_3:
				_play_matching("attack")
			KEY_4:
				_play_matching("fly")
