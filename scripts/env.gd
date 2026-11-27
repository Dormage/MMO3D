extends Node
## Sky - world environment, sun, atmosphere and post-processing.
##
## Autoload. It owns exactly one Environment and two directional lights:
##
##   * a warm, low sun with real-time shadows, and
##   * a very faint cool bounce from the cloud sea below, so the island
##     undersides do not go to black.
##
## Every magic number is an export. Nothing here touches materials: the
## "washed out and blue" look is fixed by the light colour, exposure, ACES and
## the measured fog, not by tinting albedo.
##
## map.gd still builds its own WorldEnvironment and sun. This autoload adopts
## those nodes when they enter the tree (sets their environment to ours and
## mutes the duplicate light) so the brain does not have to edit map.gd to see
## this rig. That integration is deliberately runtime-only; the scene builder
## stays the brain's file.

@export_group("Sun")
## Degrees above the horizon. 28 is the measured pick: long enough shadows to
## read the hills, high enough that the island keeps its colour.
@export_range(1.0, 89.0, 0.1) var sun_elevation_deg: float = 28.0
## Compass direction the sun sits in: 0 = +Z (south), +90 = +X (east).
## 65 puts it east-southeast, so shadows run west-north across the map.
@export_range(-180.0, 180.0, 0.1) var sun_azimuth_deg: float = 45.0
## The shipped key colour: the measured warm white from LIGHTING.md (~3800 K).
## It is not Color.WHITE; that is the point.
@export var sun_color: Color = Color(0.95, 0.88, 0.78)
## Optional physical control. Off by default because the brain measured
## sun_color directly against the Blender sun sweep and that is the target;
## turn it on to drive light_color from `sun_temperature_k` instead.
@export var use_temperature: bool = false
@export_range(1000.0, 12000.0, 50.0) var sun_temperature_k: float = 3800.0
## 0 = white, 1 = the full temperature colour. Only used with use_temperature.
@export_range(0.0, 1.0, 0.01) var sun_tint_strength: float = 0.92
@export_range(0.0, 16.0, 0.01) var sun_energy: float = 1.70
## Angular diameter in degrees. Real sun is ~0.53; a bit more gives softer
## penumbrae without turning the shadow into mush.
@export_range(0.0, 5.0, 0.01) var sun_angular_distance_deg: float = 0.7
@export var sun_shadows: bool = true
@export_range(20.0, 600.0, 1.0) var shadow_max_distance: float = 300.0
@export_range(0.0, 4.0, 0.01) var shadow_blur: float = 2.0
@export_range(0.0, 1.0, 0.01) var shadow_opacity: float = 0.80
## The subdivided cliff is a large near-horizontal receiver lit at a grazing
## angle; the default normal bias produced black shadow-acne pepper on the
## plateau face.  These biases only affect shadow lookup, not terrain geometry.
@export_range(0.0, 0.5, 0.001) var shadow_bias: float = 0.22
@export_range(0.0, 4.0, 0.01) var shadow_normal_bias: float = 4.0

@export_group("Sky")
@export var sky_top_color: Color = Color(0.176, 0.148, 0.200)
@export var sky_horizon_color: Color = Color(0.263, 0.234, 0.300)
@export var sky_curve: float = 0.55
@export var sky_energy: float = 1.0
@export_group("Cloud sky")
## Lower hemisphere is a direction-space cloud sea; the procedural ground is
## only the fallback if the sky shader cannot be loaded.
@export_range(0.0, 1.0, 0.01) var cloud_sky_coverage: float = 0.38
@export_range(0.001, 0.10, 0.001) var cloud_sky_scale: float = 0.022
@export_range(20.0, 160.0, 1.0) var cloud_sky_height: float = 70.0
@export_range(0.0, 0.05, 0.0005) var cloud_sky_drift_speed: float = 0.010
@export_group("Sky fallback")
@export var ground_bottom_color: Color = Color(0.38, 0.41, 0.45)
@export var ground_horizon_color: Color = Color(0.355, 0.335, 0.315)
@export var ground_curve: float = 0.06
@export var ground_energy: float = 1.0
## Size of the sun disc drawn by the procedural sky, in degrees.
@export_range(1.0, 30.0, 0.5) var sky_sun_angle_max: float = 6.0
@export_range(0.0, 1.0, 0.01) var sky_sun_curve: float = 0.12
## 1.0 = ambient is entirely the sky; 0.0 would be a flat colour. This is the
## "ambient from the sky, not a flat colour" control.
@export_range(0.0, 1.0, 0.01) var ambient_sky_contribution: float = 0.0
## Cool skylight fill mixed under the sky probe.  Shadowed stone should read as
## blue-violet shade, never neutral grey paint.
@export var ambient_color: Color = Color(0.38, 0.42, 0.52)
@export_range(0.0, 4.0, 0.01) var ambient_energy: float = 1.00
@export var use_sky_reflections: bool = true

@export_group("Bounce")
## A single faint light from below the horizon standing in for the light the
## cloud sea bounces onto the cliff undersides. It is a light, not an ambient
## colour, and it is deliberately weak.
@export_range(0.0, 2.0, 0.01) var bounce_energy: float = 0.25
@export var bounce_color: Color = Color(0.55, 0.68, 0.90)
@export_range(-80.0, 80.0, 0.5) var bounce_elevation_deg: float = 35.0

@export_group("Fog")
@export var fog_enabled: bool = true
## Exponential by default, matching the f = 1 - exp(-density * dist) curve
## LIGHTING.md measured (18% at 40 m, 36% at 90 m). Set fog_depth_mode for the
## begin/end variant instead.
@export var fog_depth_mode: bool = true
@export var fog_light_color: Color = Color(0.245, 0.220, 0.300)
@export_range(0.0, 4.0, 0.01) var fog_light_energy: float = 1.00
@export_range(0.0, 1.0, 0.0001) var fog_density: float = 0.0018
@export_range(0.0, 400.0, 1.0) var fog_depth_begin: float = 80.0
@export_range(0.0, 1200.0, 1.0) var fog_depth_end: float = 480.0
@export_range(0.1, 8.0, 0.01) var fog_depth_curve: float = 0.60
## How much the fog gives the sky a horizon instead of a hard skyline.
@export_range(0.0, 1.0, 0.01) var fog_sky_affect: float = 0.0
@export_range(0.0, 1.0, 0.01) var fog_aerial_perspective: float = 0.12
@export_range(0.0, 1.0, 0.01) var fog_sun_scatter: float = 0.16
## Height fog, in world metres: the cloud sea below the islands.
@export_range(-120.0, 100.0, 0.5) var fog_height: float = -15.0
@export_range(0.0, 1.0, 0.01) var fog_height_density: float = 0.00035

@export_group("Volumetric fog")
## Forward+ only. Low density so it reads as air, not smoke.
@export var volumetric_fog_enabled: bool = true
@export_range(0.0, 0.2, 0.001) var volumetric_fog_density: float = 0.00035
@export var volumetric_fog_albedo: Color = Color(0.160, 0.210, 0.280)
@export_range(0.0, 1.0, 0.01) var volumetric_fog_anisotropy: float = 0.45
@export_range(0.0, 400.0, 1.0) var volumetric_fog_length: float = 120.0
@export_range(0.0, 1.0, 0.01) var volumetric_fog_ambient_inject: float = 0.22
@export_range(0.0, 1.0, 0.01) var volumetric_fog_sky_affect: float = 0.0
@export_range(0.0, 2.0, 0.01) var sun_volumetric_energy: float = 1.0

@export_group("Post")
## 0 Linear, 1 Reinhard, 2 Filmic, 3 ACES, 4 AgX. ACES by default: it holds the
## warm highlights instead of clipping them to white.
@export_enum("Linear", "Reinhard", "Filmic", "ACES", "AgX") var tonemap_mode: int = 3
@export_range(0.1, 4.0, 0.01) var exposure: float = 1.22
@export_range(0.0, 16.0, 0.1) var tonemap_white: float = 4.2

@export_subgroup("SSAO")
@export var ssao_enabled: bool = true
@export_range(0.0, 8.0, 0.01) var ssao_radius: float = 2.40
@export_range(0.0, 8.0, 0.01) var ssao_intensity: float = 1.60
@export_range(0.0, 4.0, 0.01) var ssao_power: float = 1.45
@export_range(0.0, 1.0, 0.01) var ssao_detail: float = 0.70
@export_range(0.0, 1.0, 0.01) var ssao_horizon: float = 0.28
@export_range(0.0, 1.0, 0.01) var ssao_sharpness: float = 0.98
@export_range(0.0, 1.0, 0.01) var ssao_light_affect: float = 0.28

@export_subgroup("SSIL")
@export var ssil_enabled: bool = true
@export_range(0.0, 16.0, 0.01) var ssil_radius: float = 2.6
@export_range(0.0, 8.0, 0.01) var ssil_intensity: float = 1.50
@export_range(0.0, 1.0, 0.01) var ssil_sharpness: float = 0.98

@export_subgroup("SDFGI")
## Real-time sky/sun GI. This is the stand-in for a lightmap: it needs no UV2,
## no bake and no editor, and it works on terrain the pipeline rebuilds.
@export var sdfgi_enabled: bool = true
@export_range(1, 6, 1) var sdfgi_cascades: int = 4
@export_range(0.05, 2.0, 0.05) var sdfgi_min_cell_size: float = 0.35
@export_range(4.0, 100.0, 0.5) var sdfgi_cascade0_distance: float = 24.0
@export_range(20.0, 600.0, 1.0) var sdfgi_max_distance: float = 200.0
@export_range(0.0, 4.0, 0.01) var sdfgi_energy: float = 1.00
@export var sdfgi_use_occlusion: bool = true
@export var sdfgi_read_sky_light: bool = true
@export_range(0.0, 1.0, 0.01) var sdfgi_bounce_feedback: float = 0.5

@export_subgroup("Glow")
@export var glow_enabled: bool = true
@export_range(0.0, 4.0, 0.01) var glow_intensity: float = 0.10
@export_range(0.0, 4.0, 0.01) var glow_strength: float = 1.0
@export_range(0.0, 1.0, 0.01) var glow_bloom: float = 0.006
@export_range(0.0, 8.0, 0.01) var glow_hdr_threshold: float = 1.20
@export_range(0.0, 16.0, 0.1) var glow_hdr_luminance_cap: float = 8.0
@export_enum("Additive", "Screen", "Softlight", "Replace", "Mix") var glow_blend_mode: int = 2
@export var glow_normalized: bool = true

@export_subgroup("Grade")
## A restrained scalar grade only. If the scene builder supplies a colour LUT,
## env.gd adopts it and neutralises these three so the image is not graded twice.
@export var grade_enabled: bool = true
@export_range(0.0, 2.0, 0.01) var grade_brightness: float = 1.0
@export_range(0.0, 2.0, 0.01) var grade_contrast: float = 1.0
@export_range(0.0, 2.0, 0.01) var grade_saturation: float = 1.0

var _env: Environment
var _world_env: WorldEnvironment
var _sun: DirectionalLight3D
var _bounce: DirectionalLight3D
var _adopted: int = 0
var _muted: int = 0
var _post_layer: CanvasLayer


func _ready() -> void:
	_build()
	get_tree().node_added.connect(_on_node_added)
	# In case something was already in the tree before the autoload connected.
	for node in get_tree().root.get_children():
		_consider(node)
	# map.tscn builds a fallback sun before this autoload sees it; defer one
	# frame so the scene is complete, then mute every duplicate key light.
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
		_consider(node)


func _build() -> void:
	var shader := load("res://shaders/sky_cloud_sea.gdshader") as Shader
	var sky_mat: Material
	var sky := Sky.new()
	if shader != null:
		var sm := ShaderMaterial.new()
		sm.shader = shader
		sm.set_shader_parameter("sky_top_color", sky_top_color)
		sm.set_shader_parameter("sky_horizon_color", sky_horizon_color)
		sm.set_shader_parameter("horizon_haze", sky_horizon_color)
		sm.set_shader_parameter("cloud_top_color", Color(0.86, 0.89, 0.91))
		sm.set_shader_parameter("cloud_under_color", Color(0.255, 0.345, 0.475))
		sm.set_shader_parameter("cloud_deep_color", Color(0.025, 0.040, 0.070))
		sm.set_shader_parameter("sun_color", sun_color)
		sm.set_shader_parameter("sky_curve", sky_curve)
		sm.set_shader_parameter("sky_energy", sky_energy)
		sm.set_shader_parameter("coverage", cloud_sky_coverage)
		sm.set_shader_parameter("cloud_scale", cloud_sky_scale)
		sm.set_shader_parameter("cloud_height", cloud_sky_height)
		sm.set_shader_parameter("drift_speed", cloud_sky_drift_speed)
		sm.set_shader_parameter("silver_strength", 0.30)
		sm.set_shader_parameter("horizon_glow_strength", 0.40)
		sky_mat = sm
		sky.radiance_size = Sky.RADIANCE_SIZE_256
		print("sky: cloud-sea shader active")
	else:
		var pm := ProceduralSkyMaterial.new()
		pm.sky_top_color = sky_top_color
		pm.sky_horizon_color = sky_horizon_color
		pm.sky_curve = sky_curve
		pm.sky_energy_multiplier = sky_energy
		pm.ground_bottom_color = ground_bottom_color
		pm.ground_horizon_color = ground_horizon_color
		pm.ground_curve = ground_curve
		pm.ground_energy_multiplier = ground_energy
		pm.sun_angle_max = sky_sun_angle_max
		pm.sun_curve = sky_sun_curve
		pm.use_debanding = true
		sky_mat = pm
		push_warning("sky_cloud_sea.gdshader missing; using procedural sky")
	sky.sky_material = sky_mat

	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.background_energy_multiplier = 1.0
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_sky_contribution = ambient_sky_contribution
	_env.ambient_light_color = ambient_color
	_env.ambient_light_energy = ambient_energy
	_env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY if use_sky_reflections \
			else Environment.REFLECTION_SOURCE_DISABLED

	_env.tonemap_mode = tonemap_mode
	_env.tonemap_exposure = exposure
	_env.tonemap_white = tonemap_white

	_env.ssao_enabled = ssao_enabled
	_env.ssao_radius = ssao_radius
	_env.ssao_intensity = ssao_intensity
	_env.ssao_power = ssao_power
	_env.ssao_detail = ssao_detail
	_env.ssao_horizon = ssao_horizon
	_env.ssao_sharpness = ssao_sharpness
	_env.ssao_light_affect = ssao_light_affect

	_env.ssil_enabled = ssil_enabled
	_env.ssil_radius = ssil_radius
	_env.ssil_intensity = ssil_intensity
	_env.ssil_sharpness = ssil_sharpness

	_env.sdfgi_enabled = sdfgi_enabled
	_env.sdfgi_cascades = sdfgi_cascades
	_env.sdfgi_min_cell_size = sdfgi_min_cell_size
	_env.sdfgi_cascade0_distance = sdfgi_cascade0_distance
	_env.sdfgi_max_distance = sdfgi_max_distance
	_env.sdfgi_energy = sdfgi_energy
	_env.sdfgi_use_occlusion = sdfgi_use_occlusion
	_env.sdfgi_read_sky_light = sdfgi_read_sky_light
	_env.sdfgi_bounce_feedback = sdfgi_bounce_feedback

	_env.glow_enabled = glow_enabled
	_env.glow_intensity = glow_intensity
	_env.glow_strength = glow_strength
	_env.glow_bloom = glow_bloom
	_env.glow_hdr_threshold = glow_hdr_threshold
	_env.glow_hdr_luminance_cap = glow_hdr_luminance_cap
	_env.glow_blend_mode = glow_blend_mode
	_env.glow_normalized = glow_normalized
	# Levels 1..7: broad soft, then tight core. Kept low on purpose.
	var levels := [0.0, 0.22, 0.44, 0.30, 0.10, 0.0, 0.0]
	for i in range(levels.size()):
		_env.set_glow_level(i, float(levels[i]))

	_env.fog_enabled = fog_enabled
	_env.fog_mode = Environment.FOG_MODE_DEPTH if fog_depth_mode \
			else Environment.FOG_MODE_EXPONENTIAL
	_env.fog_light_color = fog_light_color
	_env.fog_light_energy = fog_light_energy
	_env.fog_density = fog_density
	_env.fog_depth_begin = fog_depth_begin
	_env.fog_depth_end = fog_depth_end
	_env.fog_depth_curve = fog_depth_curve
	_env.fog_sky_affect = fog_sky_affect
	_env.fog_aerial_perspective = fog_aerial_perspective
	_env.fog_sun_scatter = fog_sun_scatter
	_env.fog_height = fog_height
	_env.fog_height_density = fog_height_density

	_env.volumetric_fog_enabled = volumetric_fog_enabled
	_env.volumetric_fog_density = volumetric_fog_density
	_env.volumetric_fog_albedo = volumetric_fog_albedo
	_env.volumetric_fog_anisotropy = volumetric_fog_anisotropy
	_env.volumetric_fog_length = volumetric_fog_length
	_env.volumetric_fog_ambient_inject = volumetric_fog_ambient_inject
	_env.volumetric_fog_sky_affect = volumetric_fog_sky_affect

	_env.adjustment_enabled = grade_enabled
	_env.adjustment_brightness = grade_brightness
	_env.adjustment_contrast = grade_contrast
	_env.adjustment_saturation = grade_saturation

	_world_env = WorldEnvironment.new()
	_world_env.name = "SkyWorldEnvironment"
	_world_env.environment = _env
	add_child(_world_env)

	_build_post_layer()

	_sun = DirectionalLight3D.new()
	_sun.name = "SkySun"
	_sun.rotation = Vector3(deg_to_rad(-sun_elevation_deg),
			deg_to_rad(sun_azimuth_deg), 0.0)
	_sun.light_color = _temperature_color(sun_temperature_k, sun_tint_strength) \
			if use_temperature else sun_color
	_sun.light_energy = sun_energy
	_sun.light_angular_distance = sun_angular_distance_deg
	_sun.light_volumetric_fog_energy = sun_volumetric_energy
	_sun.light_specular = 0.65
	_sun.shadow_enabled = sun_shadows
	_sun.shadow_blur = shadow_blur
	_sun.shadow_opacity = shadow_opacity
	_sun.shadow_bias = shadow_bias
	_sun.shadow_normal_bias = shadow_normal_bias
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun.directional_shadow_max_distance = shadow_max_distance
	_sun.directional_shadow_split_1 = 0.08
	_sun.directional_shadow_split_2 = 0.24
	_sun.directional_shadow_split_3 = 0.52
	_sun.directional_shadow_blend_splits = true
	_sun.directional_shadow_fade_start = 0.9
	_sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	add_child(_sun)

	_bounce = DirectionalLight3D.new()
	_bounce.name = "SkyBounce"
	_bounce.rotation = Vector3(deg_to_rad(-bounce_elevation_deg),
			deg_to_rad(sun_azimuth_deg + 180.0), 0.0)
	_bounce.light_color = bounce_color
	_bounce.light_energy = bounce_energy
	_bounce.light_specular = 0.0
	_bounce.shadow_enabled = false
	_bounce.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	add_child(_bounce)



func _build_post_layer() -> void:
	var shader := load("res://shaders/lens_post.gdshader") as Shader
	if shader == null:
		push_warning("lens_post shader missing")
		return
	_post_layer = CanvasLayer.new()
	_post_layer.name = "AtmospherePost"
	_post_layer.layer = 110
	var copy := BackBufferCopy.new()
	copy.name = "ScreenCopy"
	copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_post_layer.add_child(copy)
	var rect := ColorRect.new()
	rect.name = "LensPost"
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.offset_right = 0.0
	rect.offset_bottom = 0.0
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("grain_amount", 0.025)
	mat.set_shader_parameter("ca_amount", 0.0012)
	mat.set_shader_parameter("shadow_tint", 0.16)
	mat.set_shader_parameter("highlight_tint", 0.14)
	mat.set_shader_parameter("contrast", 0.06)
	mat.set_shader_parameter("shadow_lift", 0.014)
	rect.material = mat
	_post_layer.add_child(rect)
	add_child(_post_layer)

## The evidence harness renders into its own SubViewport, which does not
## inherit root CanvasLayers. Call this to add the same lens pass there.
func attach_post_to_viewport(vp: Node) -> void:
	if _post_layer == null or vp == null:
		return
	var dup := _post_layer.duplicate() as CanvasLayer
	vp.add_child(dup)


## Tanner Helland's Planckian approximation, then sRGB -> linear because
## Godot's Light3D colour is linear. Returns a colour at the given Kelvin.
static func _temperature_color(kelvin: float, strength: float) -> Color:
	var t := clampf(kelvin, 1000.0, 40000.0) / 100.0
	var r := 0.0
	var g := 0.0
	var b := 0.0
	if t <= 66.0:
		r = 255.0
		g = 99.4708025861 * log(t) - 161.1195681661
	else:
		r = 329.698727446 * pow(t - 60.0, -0.1332047592)
		g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
	if t >= 66.0:
		b = 255.0
	elif t <= 19.0:
		b = 0.0
	else:
		b = 138.5177312231 * log(t - 10.0) - 305.0447927307
	var srgb := Color(clampf(r / 255.0, 0.0, 1.0),
			clampf(g / 255.0, 0.0, 1.0), clampf(b / 255.0, 0.0, 1.0))
	return Color.WHITE.lerp(srgb.srgb_to_linear(), clampf(strength, 0.0, 1.0))


func _on_node_added(node: Node) -> void:
	# The sky fallback is a deep void.  Map cloud puffs are low-poly discs and
	# read as ice floes against it, so hide them at runtime rather than editing
	# the map's prop builder.
	if String(node.name).begins_with("clouds_clouds"):
		if node is CanvasItem:
			(node as CanvasItem).visible = false
		elif node is Node3D:
			(node as Node3D).visible = false
	_consider(node)


func _consider(node: Node) -> void:
	if node is WorldEnvironment:
		var we := node as WorldEnvironment
		if we == _world_env:
			return
		# The scene builder builds its own environment. Adopt the node rather
		# than freeing it: map.gd keeps its own reference. Carry over a grade
		# LUT if the builder supplied one, so the sky rig does not silently
		# throw away the brain's whole-frame grade.
		var incoming := we.environment
		if incoming != null and incoming != _env:
			var lut: Texture2D = incoming.adjustment_color_correction
			if lut != null and _env.adjustment_color_correction == null:
				_env.adjustment_color_correction = lut
				_env.adjustment_brightness = 1.0
				_env.adjustment_contrast = 1.0
				_env.adjustment_saturation = 1.0
				print("sky: adopted grade LUT '%s'; scalars neutral b %.2f c %.2f s %.2f" % [
						lut.resource_path, _env.adjustment_brightness,
						_env.adjustment_contrast, _env.adjustment_saturation])
		we.environment = _env
		_adopted += 1
		print("sky: adopted WorldEnvironment '%s'" % we.name)
	elif node is DirectionalLight3D:
		var light := node as DirectionalLight3D
		if light == _sun or light == _bounce:
			return
		# A second sun from the scene builder doubles the key and the shadows.
		# Mute it; keep the node so nothing that holds a reference breaks.
		if light.visible or light.light_energy > 0.0:
			light.visible = false
			light.light_energy = 0.0
			light.shadow_enabled = false
			_muted += 1
			print("sky: muted duplicate light '%s'" % light.name)
