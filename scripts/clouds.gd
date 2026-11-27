extends Node
## Clouds - a billboard cloud field far below the archipelago.
##
## Camera-facing cards between -55 and -140 m, biased toward island footprints.
## Cards are soft radial/noise sprites, depth sorted by the transparent pass,
## depth-write off.  They fade into the horizon colour, so there is no field
## edge and no plane.

const CLOUD_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;

uniform sampler2D cloud_tex : source_color, filter_linear_mipmap;
uniform vec3 sun_dir = vec3(0.35, 0.55, 0.75);
uniform vec3 horizon_color = vec3(0.48, 0.52, 0.58);
uniform vec3 top_color = vec3(0.96, 0.98, 1.0);
uniform vec3 shadow_color = vec3(0.58, 0.67, 0.80);
uniform vec3 sun_color = vec3(1.0, 0.91, 0.78);
uniform float card_alpha = 1.0;
uniform float roll = 0.0;
uniform float fade_start = 600.0;
uniform float fade_end = 720.0;

varying vec3 v_world;
varying vec3 v_center;
varying float v_half_h;
varying vec2 v_uv;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_center = MODEL_MATRIX[3].xyz;
	v_half_h = max(0.5, abs(VERTEX.y));
	vec2 uv = UV - vec2(0.5);
	float c = cos(roll);
	float s = sin(roll);
	v_uv = vec2(c * uv.x - s * uv.y, s * uv.x + c * uv.y) + vec2(0.5);

	// Camera-facing billboard while keeping the per-card quad scale.  This is
	// what makes cards at different depths overlap and occlude instead of
	// lying down into one sheet.
	// Build the card in world space from the camera's right/up axes, then let
	// the regular view transform project it.  This avoids the scale/translation
	// pitfalls of constructing MODELVIEW_MATRIX directly.
	vec3 cam_right = vec3(VIEW_MATRIX[0][0], VIEW_MATRIX[1][0], VIEW_MATRIX[2][0]);
	vec3 cam_up = vec3(VIEW_MATRIX[0][1], VIEW_MATRIX[1][1], VIEW_MATRIX[2][1]);
	vec3 center = MODEL_MATRIX[3].xyz;
	VERTEX = center + cam_right * VERTEX.x + cam_up * VERTEX.y;
	v_world = VERTEX; // billboard position, not the original card centre
	MODELVIEW_MATRIX = VIEW_MATRIX;
}

void fragment() {
	vec4 tex = texture(cloud_tex, v_uv);
	float edge = smoothstep(0.015, 0.20,
			min(min(v_uv.x, 1.0 - v_uv.x), min(v_uv.y, 1.0 - v_uv.y)));
	float a = tex.a * card_alpha * edge;
	if (a < 0.004) {
		discard;
	}
	float dist = distance(v_world, CAMERA_POSITION_WORLD);
	a *= 1.0 - smoothstep(fade_start, fade_end, dist);
	// Cards live below eye level, but a billboard near the camera can put its
	// top far above the horizon and read as a white hole punched in the sky.
	// Fade only the above-horizon part; the cloud sea below is untouched.
	// Screen-space horizon guard: cloud cards are a sea below the island, so
	// anything that projects into the upper half of the frame must not paint
	// the sky.  This is independent of camera pitch and card centre height.
	a *= smoothstep(0.46, 0.58, SCREEN_UV.y);
	if (a < 0.004) {
		discard;
	}

	// Cool cloud body: blue-white tops, lifted blue shadow, and only a narrow
	// warm graze where the low sun clips the sunward shoulder of a card.
	vec3 flat_sun = normalize(vec3(sun_dir.x, 0.0, sun_dir.z) + vec3(0.001, 0.0, 0.0));
	vec3 flat_card = normalize(vec3(v_world.x, 0.0, v_world.z) + vec3(0.001, 0.0, 0.0));
	float side = clamp(dot(flat_card, flat_sun) * 0.5 + 0.5, 0.0, 1.0);
	float top = clamp((v_world.y - v_center.y) / (v_half_h * 2.0) + 0.5, 0.0, 1.0);
	top = smoothstep(0.15, 0.85, top);
	vec3 col = mix(shadow_color, top_color, pow(top, 1.65));
	float graze = smoothstep(0.55, 1.0, side) * smoothstep(0.25, 0.95, top);
	col = mix(col, sun_color, graze * 0.22);
	col *= tex.rgb;
	float grain = smoothstep(0.18, 0.80, tex.a);
	col *= mix(0.80, 1.06, grain);

	float lum = max(dot(col, vec3(0.2126, 0.7152, 0.0722)), 0.0001);
	float cap = max(dot(horizon_color, vec3(0.2126, 0.7152, 0.0722)), 0.0001);
	col *= min(1.0, cap / lum);

	float hf = smoothstep(fade_start * 0.65, fade_end, dist);
	col = mix(col, horizon_color, hf * 0.65);

	ALBEDO = col;
	ALPHA = a;
}
"""

@export_group("Field")
@export_range(80, 140, 1) var card_count: int = 140
@export_range(300.0, 900.0, 10.0) var field_radius: float = 700.0
@export_range(-160.0, -40.0, 1.0) var altitude_low: float = -140.0
@export_range(-160.0, -40.0, 1.0) var altitude_high: float = -65.0
@export_range(20.0, 140.0, 1.0) var card_scale_low: float = 25.0
@export_range(20.0, 140.0, 1.0) var card_scale_high: float = 70.0
@export var top_color: Color = Color(0.320, 0.340, 0.400)
@export var shadow_color: Color = Color(0.220, 0.250, 0.300)
@export var sun_color: Color = Color(0.50, 0.48, 0.44)
@export var horizon_color: Color = Color(0.48, 0.52, 0.58)
@export var fade_start: float = 600.0
@export var fade_end: float = 720.0
@export var drift_speed: float = 0.035
@export var bob_amplitude: float = 2.4

var _root: Node3D
var _cards: Array = []
var _materials: Array[ShaderMaterial] = []
var _time: float = 0.0
var _frames: int = 0

func _ready() -> void:
	_build()
	_attach_to_scene()

func _attach_to_scene() -> void:
	# Wait for the evidence harness / game viewport to exist, then parent the
	# field into that viewport's world.  A Node3D under the autoload alone does
	# not share the SubViewport world in the harness.
	var host: Node = null
	var vps: Array = []
	# Wait long enough for an evidence harness to create its render SubViewport,
	# then take the newest one.  The map's own viewport may have a different
	# camera, and that would leave the field in the wrong world.
	for i in range(40):
		await get_tree().process_frame
		var found := get_tree().root.find_children("*", "SubViewport", true, false)
		if not found.is_empty():
			vps = found
	if not vps.is_empty():
		host = vps[vps.size() - 1]
	if host == null:
		host = get_tree().current_scene
	if host == null:
		host = get_tree().root
	if _root != null and _root.get_parent() != host:
		if _root.get_parent() != null:
			_root.get_parent().remove_child(_root)
		host.add_child(_root)
		_root.global_position = Vector3.ZERO
		print("clouds: field attached to '%s'" % host.name)
		print("clouds: root in_tree=", _root.is_inside_tree(), " visible=", _root.visible,
				" in_tree_visible=", _root.is_visible_in_tree(), " cards=", _cards.size())
		if not _cards.is_empty():
			var c0: MeshInstance3D = _cards[0]["node"]
			print("clouds: card0 parent=", c0.get_parent().name, " pos=", c0.global_position,
					" visible=", c0.visible, " tree=", c0.is_visible_in_tree())

func _process(delta: float) -> void:
	if _root == null:
		return
	_time += delta
	for c in _cards:
		var node: MeshInstance3D = c["node"]
		var base: Vector3 = c["base"]
		var phase: float = c["phase"]
		var bob: float = c["bob"]
		var drift: Vector2 = c["drift"]
		if c.get("debug", false):
			var camd := _root.get_viewport().get_camera_3d()
			if camd != null:
				node.global_position = camd.global_position - camd.global_basis.z * 60.0
			continue
		node.position = base + Vector3(drift.x * _time,
				sin(_time * 0.09 + phase) * bob, drift.y * _time)

	var cam := _root.get_viewport().get_camera_3d()
	if cam != null:
		var p := cam.global_position
		_root.global_position = Vector3(p.x, 0.0, p.z)

	_frames += 1
	if _frames % 30 == 1:
		_sync_rig()

func _build() -> void:
	_root = Node3D.new()
	_root.name = "CloudSea"
	add_child(_root)
	# The pale card field read as flat studio fog at the RPG camera.  The
	# chasm is now authored in sky_cloud_sea.gdshader, which gives a stable
	# deep-purple gradient with no view-dependent card overlaps.
	if OS.get_environment("CLOUD_CARDS") != "1":
		_root.visible = false
		return

	var tex_paths := [
		"res://assets/cloud_cards/card_00.png",
		"res://assets/cloud_cards/card_01.png",
		"res://assets/cloud_cards/card_02.png",
	]
	var textures: Array[Texture2D] = []
	for p in tex_paths:
		var t := load(p) as Texture2D
		if t != null:
			textures.append(t)
	if textures.is_empty():
		push_error("clouds: no cloud card textures")
		return

	var centers := _island_centers()
	var rng := RandomNumberGenerator.new()
	rng.seed = 92731
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)

	for i in range(card_count):
		var mat: Material
		var shader_mat: ShaderMaterial
		if OS.get_environment("CARD_STD") == "1":
			var std := StandardMaterial3D.new()
			std.albedo_texture = textures[i % textures.size()]
			std.albedo_color = Color(1.0, 0.9, 0.8, 1.0)
			std.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			std.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			std.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			std.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			mat = std
			shader_mat = null
		else:
			shader_mat = ShaderMaterial.new()
			var shader := Shader.new()
			shader.code = CLOUD_SHADER
			shader_mat.shader = shader
			shader_mat.set_shader_parameter("cloud_tex", textures[i % textures.size()])
			shader_mat.set_shader_parameter("top_color", top_color)
			shader_mat.set_shader_parameter("shadow_color", shadow_color)
			shader_mat.set_shader_parameter("horizon_color", horizon_color)
			shader_mat.set_shader_parameter("fade_start", fade_start)
			shader_mat.set_shader_parameter("fade_end", fade_end)
			shader_mat.set_shader_parameter("card_alpha", rng.randf_range(0.12, 0.22))
			shader_mat.set_shader_parameter("roll", rng.randf_range(-0.55, 0.55))
			mat = shader_mat

		var center := Vector3.ZERO
		if not centers.is_empty() and rng.randf() < 0.72:
			center = centers[rng.randi_range(0, centers.size() - 1)]
		# bias toward the island footprints, while still reaching the 700 m rim
		var ang := rng.randf() * TAU
		var r := field_radius * pow(rng.randf(), 1.55)
		if not centers.is_empty() and rng.randf() < 0.72:
			r = min(r, 190.0)
		var pos := center + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		pos.y = rng.randf_range(altitude_low, altitude_high)

		var sx := rng.randf_range(card_scale_low, card_scale_high)
		var sy := sx * rng.randf_range(0.48, 0.92)
		var mi := MeshInstance3D.new()
		mi.name = "CloudCard%03d" % i
		# StandardMaterial billboards ignore the node's non-uniform scale in
		# this Godot build, so bake the card size into the quad itself.
		var card_quad := QuadMesh.new()
		card_quad.size = Vector2(sx, sy)
		mi.mesh = card_quad
		mi.material_override = mat
		mi.scale = Vector3.ONE
		mi.position = pos
		mi.rotation.y = rng.randf() * TAU
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_root.add_child(mi)

		_cards.append({
			"node": mi,
			"base": pos,
			"phase": rng.randf() * TAU,
			"bob": rng.randf_range(0.8, bob_amplitude),
			"drift": Vector2(rng.randf_range(-drift_speed, drift_speed),
					rng.randf_range(-drift_speed, drift_speed)),
		})
		if shader_mat != null:
			_materials.append(shader_mat)

	# debug probe: opaque box 60 m in front of the camera
	if OS.get_environment("CARD_DEBUG") == "1":
		var dbg := MeshInstance3D.new()
		dbg.name = "CardDebug"
		var bm := BoxMesh.new()
		bm.size = Vector3(18.0, 18.0, 1.0)
		dbg.mesh = bm
		var dm := StandardMaterial3D.new()
		dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dm.albedo_color = Color(1.0, 0.0, 0.0)
		dbg.material_override = dm
		dbg.position = Vector3(0.0, -60.0, 0.0)
		_root.add_child(dbg)
		_cards.append({"node": dbg, "base": Vector3.ZERO, "phase": 0.0, "bob": 0.0,
				"drift": Vector2.ZERO, "debug": true})

	_sync_rig()
	print("clouds: %d cards, y %.0f..%.0f, radius %.0f, variants %d" % [
			card_count, altitude_low, altitude_high, field_radius, textures.size()])

func _island_centers() -> Array[Vector3]:
	var out: Array[Vector3] = []
	var f := FileAccess.open("res://map_layout.json", FileAccess.READ)
	if f == null:
		return out
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	var islands: Array = data.get("islands", [])
	for isl in islands:
		var c: Array = isl.get("center", [])
		if c.size() >= 2:
			out.append(Vector3(float(c[0]), 0.0, float(c[1])))
	return out

func _sync_rig() -> void:
	var sun_dir := Vector3(0.35, 0.55, 0.75)
	var horizon := horizon_color
	var top := top_color
	var shadow := shadow_color
	var atmo := get_node_or_null("/root/Atmosphere")
	if atmo != null:
		var elev: float = atmo.sun_elevation_deg
		var az: float = atmo.sun_azimuth_deg
		sun_dir = Vector3(cos(deg_to_rad(elev)) * sin(deg_to_rad(az)),
				sin(deg_to_rad(elev)),
				cos(deg_to_rad(elev)) * cos(deg_to_rad(az)))
		horizon = atmo.sky_horizon_color
	for mat in _materials:
		mat.set_shader_parameter("sun_dir", sun_dir)
		mat.set_shader_parameter("horizon_color", horizon)
		mat.set_shader_parameter("top_color", top)
		mat.set_shader_parameter("shadow_color", shadow)
		mat.set_shader_parameter("sun_color", sun_color)
