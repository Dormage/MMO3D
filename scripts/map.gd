extends Node3D
## Builds the flying-islands map in 3D from map_layout.json + terrain.glb.
## Islands float with nothing between them; bridges span the gaps and
## waterfalls pour off the rims.

const LAYOUT := "res://map_layout.json"
const VillagePalette := preload("res://scripts/village_palette.gd")
const PropSurface := preload("res://scripts/prop_surface.gd")
const DistantIslands := preload("res://scripts/distant_islands.gd")
const IslandPOI := preload("res://scripts/island_poi_builder.gd")
const TERRAIN := "res://assets/terrain.glb"
const MODEL_DIR := "res://assets/models/"
const W := 96
const H := 96

var _cache: Dictionary = {}
var _land: Dictionary = {}
var _island_of: Dictionary = {}
var _islands: Array = []
var _water_mat: ShaderMaterial = null


func _ready() -> void:
	_build_environment()
	_load_layout()
	_build_terrain()
	# DistantIslands were vertical unshaded sheets; at the 170 m inspection
	# camera they read as purple curtains through the void.  Removed.
	_build_terrain_collision()
	_build_slope_stones()
	_build_water()
	_build_pond_shore()
	_build_pond_banks()
	_build_island_shores()
	_build_aperture_caps()
	_build_props()
	_build_bank_props()
	_build_buildings()
	_build_building_collision()
	_build_village_props()
	_build_island_content()
	_build_island_signatures()
	_build_bridges()
	_ground_placed_content()
	_build_waterfalls()
	_build_mist()
	_build_dragons()
	_build_crystal_lights()
	_build_ambient_effects()
	_build_clouds()
	_build_camera()
	_build_hud()




## The terrain was lowered by ~1.7 m while layout Y values stayed baked.  Move
## every placed prop/building to the walkable heightfield, preserving each
## model's own base offset by fitting its lowest visible vertex to the ground.
## Intentional floaters (shards, waterfalls), bank rocks (half-submerged) and
## world structure nodes are skipped.
func _ground_placed_content() -> void:
	var tc := get_node_or_null("TerrainCollision")
	if tc == null:
		push_warning("grounding: TerrainCollision missing")
		return
	var moved := 0
	var max_corr := 0.0
	var missing := 0
	var counts := {"building": 0, "prop": 0, "tree": 0, "crystal": 0, "statue": 0}
	for n in get_children():
		if not (n is Node3D):
			continue
		var nm := String(n.name)
		if nm.begins_with("Pad_") or nm.begins_with("BankRock_") or nm.begins_with("Dragon"):
			continue
		if nm == "BuildingCollision" or nm == "Bridges" or nm == "SlopeStones":
			continue
		var is_building := nm.begins_with("Building_")
		var is_prop := nm.begins_with("Prop_") or nm.begins_with("plants_") \
			or nm.begins_with("trees_") or nm.begins_with("Monument_") \
			or nm.begins_with("@Node3D")
		var is_crystal := nm.to_lower().contains("crystal")
		if not (is_building or is_prop or is_crystal):
			continue
		var root := n as Node3D
		if _is_waterfall_root(root):
			continue
		var low := _lowest_world_mesh_y(root)
		if low > 1.0e29:
			missing += 1
			continue
		var gp := root.global_position
		var g: float = tc.call("walkable_height", gp.x, gp.z)
		if is_nan(g):
			missing += 1
			continue
		var delta := g + 0.01 - low
		if absf(delta) < 0.001:
			continue
		root.position.y += delta
		if is_building:
			counts["building"] += 1
			var pad := get_node_or_null("Pad_%s" % nm.substr(9))
			if pad is Node3D:
				(pad as Node3D).position.y += delta
		elif is_crystal:
			counts["crystal"] += 1
		elif nm.to_lower().contains("tree"):
			counts["tree"] += 1
		elif nm.to_lower().contains("statue") or nm.begins_with("Monument_"):
			counts["statue"] += 1
		else:
			counts["prop"] += 1
		moved += 1
		max_corr = maxf(max_corr, absf(delta))
	print("GROUNDED moved=%d max_correction=%.3f missing=%d buildings=%d props=%d trees=%d crystals=%d statues=%d" % [
		moved, max_corr, missing, counts["building"], counts["prop"], counts["tree"],
		counts["crystal"], counts["statue"]])


func _is_waterfall_root(root: Node3D) -> bool:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if String(node.name).to_lower().contains("waterfall"):
			return true
	return false


func _lowest_world_mesh_y(root: Node3D) -> float:
	var low := 1.0e30
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var xf := mi.global_transform
			for v in vs:
				low = minf(low, (xf * v).y)
	if low < 1.0e29:
		return low
	return 0.0


func _build_island_content() -> void:
	var b := IslandPOI.new()
	b.name = "IslandPOIs"
	add_child(b)
	b.call("build", self, get_node_or_null("TerrainCollision"))


func _build_crystal_lights() -> void:
	# One cool OmniLight at the 20 largest crystal clusters.  Range is kept at
	# 2-4 m so they read as self-lit gems, not lamps.
	var groups: Dictionary = {}
	for n in find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if not mi.name.to_lower().contains("crystal"):
			continue
		var parent := mi.get_parent() as Node3D
		if parent == null:
			continue
		var extent := mi.get_aabb().size.length()
		var key := str(parent.get_path())
		if not groups.has(key) or extent > float(groups[key]["extent"]):
			groups[key] = {"node": parent, "pos": mi.global_transform.origin, "extent": extent}
	var list := groups.values()
	list.sort_custom(func(a, b): return float(a["extent"]) > float(b["extent"]))
	var made := 0
	for g in list:
		if made >= 20:
			break
		var parent: Node3D = g["node"]
		var light := OmniLight3D.new()
		light.name = "CrystalGlow"
		light.light_color = Color(0.34, 0.66, 1.0)
		light.light_energy = 0.95
		light.omni_range = 3.8
		light.omni_attenuation = 1.6
		light.shadow_enabled = false
		light.distance_fade_enabled = true
		light.distance_fade_begin = 45.0
		light.distance_fade_length = 15.0
		parent.add_child(light)
		light.global_position = g["pos"] + Vector3(0, 0.45, 0)
		made += 1
	print("crystal glow lights: ", made)

func _build_ambient_effects() -> void:
	var fx: Node = load("res://scripts/ambient_effects.gd").new()
	fx.name = "AmbientEffects"
	add_child(fx)

func _build_distant_islands() -> void:
	var d := DistantIslands.new()
	d.name = "DistantIslands"
	add_child(d)
	var hc := Color(0.330, 0.323, 0.410)
	var atmo := get_node_or_null("/root/Atmosphere")
	if atmo != null and atmo.get("sky_horizon_color") != null:
		hc = atmo.get("sky_horizon_color")
	d.build(hc)


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.22, 0.36, 0.55)
	sm.sky_horizon_color = Color(0.62, 0.70, 0.80)
	sm.ground_bottom_color = Color(0.30, 0.36, 0.44)
	sm.ground_horizon_color = Color(0.52, 0.60, 0.70)
	var sky := Sky.new()
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	env.fog_enabled = true
	env.fog_light_color = Color(0.62, 0.70, 0.80)
	env.fog_density = 0.0016
	# A coherent grade without a LUT. The 512x512 colour-correction texture was
	# removed after it rendered the entire scene red: the blue axis sampled
	# wrong, so every pixel landed in slice 0 and the image lost all blue. A
	# scalar grade cannot fail that way, and the difference at this strength is
	# not worth the risk. tools/make_lut.py is kept for when we can verify a LUT
	# against a real render.
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.04
	# The Atmosphere autoload owns the sky and post grade.  Map's pale
	# ProceduralSky used to remain the active WorldEnvironment and turned the
	# chasm into flat blue fog; keep `env` for the sun setup, but do not add a
	# second environment to the tree.
	# add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-42), deg_to_rad(35), 0)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 200.0
	add_child(sun)
	_build_vignette()


func _load_layout() -> void:
	var f := FileAccess.open(LAYOUT, FileAccess.READ)
	if f == null:
		push_error("cannot open layout")
		return
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	_land.clear()
	for i in d["land_mask"]:
		_land[int(i)] = true
	# island id per cell
	for k in range(d["islands"].size()):
		var b = d["islands"][k]["bbox"]
		_islands.append(d["islands"][k])
	_layout = d
	print("layout: %d land, %d islands, %d props, %d spawns" % [
		_land.size(), _islands.size(), d["props"].size(), d["monsters"].size()])

var _layout: Dictionary = {}


func _model(name: String) -> PackedScene:
	if _cache.has(name):
		return _cache[name]
	var p := MODEL_DIR + name.replace("/", "_") + ".glb"
	var packed := load(p) as PackedScene
	if packed == null:
		push_warning("missing model " + p)
	_cache[name] = packed
	return packed


func _spawn(name: String, pos: Vector3, yaw: float, scl: float) -> Node3D:
	# Keep blossom on the main island and the one StoneCircle islet only; the
	# other islets swap to an ordinary green crown so pink does not repeat.
	if name.find("blossom") >= 0:
		var near_main := Vector2(pos.x + 3.0, pos.z - 14.5).length() < 30.0
		var near_17 := Vector2(pos.x + 37.0, pos.z + 50.0).length() < 22.0
		if not near_main and not near_17:
			name = "trees/tree_green_l"
	var packed := _model(name)
	if packed == null:
		return null
	var inst := packed.instantiate() as Node3D
	inst.position = pos
	inst.rotation.y = yaw
	inst.scale = Vector3(scl, scl, scl)
	add_child(inst)
	if name.find("flower") >= 0 or name.find("tulip") >= 0:
		_tint_flower(inst, name)
	elif name.find("shards_floating") >= 0:
		_tint_floating_shards(inst)
	elif name.find("crystal_cluster") >= 0 or name.find("crystal_flame") >= 0 \
			or name.find("crystal_tree") >= 0:
		_tint_crystal_pins(inst)
	return inst


func _tint_flower(root: Node3D, kind: String) -> void:
	# The imported flower models share one white-albedo material and ignore
	# their stored vertex colours in this render path, so every species renders
	# as unshaded white pins.  Recolour by local height: green stem below the
	# bloom line, species-coloured petals above it, with a soft emission.
	var petal := Color(0.34, 0.285, 0.48)
	var stem := Color(0.055, 0.16, 0.070)
	var glow := 0.10
	if kind.find("tulip") >= 0:
		petal = Color(0.30, 0.12, 0.42)
		stem = Color(0.05, 0.14, 0.060)
		glow = 0.06
	elif kind.find("tinyblue") >= 0:
		petal = Color(0.16, 0.26, 0.52)
		stem = Color(0.045, 0.15, 0.060)
		glow = 0.07
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform vec3 petal_color;
uniform vec3 stem_color;
uniform float glow;
varying float local_y;
void vertex() { local_y = VERTEX.y; }
void fragment() {
	float bloom = smoothstep(0.155, 0.235, local_y);
	ALBEDO = mix(stem_color, petal_color, bloom);
	EMISSION = petal_color * bloom * glow;
	ROUGHNESS = 0.88;
	SPECULAR = 0.10;
}
"""
	mat.shader = sh
	mat.set_shader_parameter("petal_color", Vector3(petal.r, petal.g, petal.b))
	mat.set_shader_parameter("stem_color", Vector3(stem.r, stem.g, stem.b))
	mat.set_shader_parameter("glow", glow)
	var meshes: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		meshes.append(root)
	for n in root.find_children("*", "MeshInstance3D", true, false):
		meshes.append(n as MeshInstance3D)
	for mi in meshes:
		if mi.mesh == null:
			continue
		mi.material_override = mat


func _tint_crystal_pins(root: Node3D) -> void:
	# Signature crystals: five small islands get a distinct existing-palette
	# hue, so the blue cluster no longer repeats everywhere.
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/crystal.gdshader")
	var gp := root.global_position
	var palettes := {
		"violet": [Color(0.16, 0.10, 0.30), Color(0.55, 0.35, 0.85)],
		"amber": [Color(0.24, 0.14, 0.05), Color(0.85, 0.55, 0.18)],
		"moss": [Color(0.10, 0.22, 0.10), Color(0.35, 0.65, 0.28)],
		"rust": [Color(0.25, 0.08, 0.06), Color(0.80, 0.28, 0.18)],
		"pale": [Color(0.22, 0.24, 0.28), Color(0.75, 0.80, 0.88)],
	}
	var which := ""
	if Vector2(gp.x + 58, gp.z - 69).length() < 24: which = "violet"
	elif Vector2(gp.x - 60, gp.z - 63).length() < 24: which = "amber"
	elif Vector2(gp.x - 13, gp.z - 69).length() < 18: which = "moss"
	elif Vector2(gp.x + 30, gp.z + 77).length() < 18: which = "rust"
	elif Vector2(gp.x - 81, gp.z - 11).length() < 18: which = "pale"
	if which != "":
		var bc: Color = palettes[which][0]
		var ec: Color = palettes[which][1]
		mat.set_shader_parameter("body_color", bc)
		mat.set_shader_parameter("edge_color", ec)
	var meshes: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		meshes.append(root)
	for n in root.find_children("*", "MeshInstance3D", true, false):
		meshes.append(n as MeshInstance3D)
	for mi in meshes:
		mi.material_override = mat
		# A flat plate lying on the turf must not cast a hard black shadow over
		# the grass it is sitting on; the shard is decoration, not an occluder.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _tint_floating_shards(root: Node3D) -> void:
	# The 79 floating shards inherited a stale near-black StandardMaterial3D.
	# Use the same shaded crystal shader with a smoked body and cool facet
	# edges so they read as dark crystal, not black cut-outs.
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/shards.gdshader")
	# These shards are flat ground plates: the old smoked body (0.055, 0.085,
	# 0.105) rendered as a pure-black hole under the unshaded shard shader.
	# Lift the body and edges so the facets stay visibly dark blue, not void.
	mat.set_shader_parameter("body_color", Color(0.145, 0.200, 0.235, 1.0))
	mat.set_shader_parameter("edge_color", Color(0.40, 0.56, 0.64, 1.0))
	var meshes: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		meshes.append(root)
	for n in root.find_children("*", "MeshInstance3D", true, false):
		meshes.append(n as MeshInstance3D)
	for mi in meshes:
		mi.material_override = mat


func _build_terrain() -> void:
	var packed := load(TERRAIN) as PackedScene
	if packed == null:
		push_error("terrain missing")
		return
	var t := packed.instantiate() as Node3D
	t.name = "Terrain"
	add_child(t)
	# slope/height/moss blending from the masks baked into COLOR_0 and the
	# per-surface vertex data; the shader refines the zone pass, it does not
	# replace it.
	var surf: Node = TerrainSurface.new()
	surf.name = "TerrainSurface"
	add_child(surf)
	surf.call("apply", t)
	_strip_terrain_skirts(t)
	# The baked solidify underside is open and its rim quads read as detached
	# blades. Hide those four surfaces and replace them with one solid sheet.
	# terrain.glb itself is untouched (734,480 tris, 18 shells remain).
	# Remove the detached north-west flake whose underside read as a void grid.
	if OS.get_environment("TERRAIN_FLAKE_KEEP") != "1":
		var flake := load("res://scripts/terrain_flake_hide.gd").new() as Node
		flake.name = "TerrainFlakeHide"
		add_child(flake)
	_hide_broken_underside(t)
	var under_script := load("res://scripts/terrain_underside.gd") as GDScript
	var under := under_script.new() as MeshInstance3D
	under.name = "TerrainUnderside"
	add_child(under)
	if OS.get_environment("NO_FRINGE") != "1":
		var fringe_script := load("res://scripts/terrain_turf_fringe.gd") as GDScript
		var fringe := fringe_script.new() as MeshInstance3D
		fringe.name = "TerrainTurfFringe"
		under.add_child(fringe)
		if OS.get_environment("FRINGE_HIDE") == "1":
			fringe.visible = false
	# The top sheet has 1,746 single-face boundary edges (59 open chains,
	# 29 up-facing apertures).  They used to be invisible; with detailed ground
	# shading they read as black void slits at eye level.  A dark soil sheet
	# 0.5 m under the surface fills them without touching the GLB.  See
	# tools/terrain_void_caps.py / tools/terrain_void_underlay.py.
	# The detached north-west flake is removed at runtime, so the flat soil
	# underlay is no longer needed for the eye-level hole.  Opt in only for
	# inspection with TERRAIN_VOID_CAP=1.
	if OS.get_environment("TERRAIN_VOID_CAP") == "1":
		var cap_script := load("res://scripts/terrain_void_cap.gd") as GDScript
		var cap := cap_script.new() as MeshInstance3D
		cap.name = "TerrainVoidCap"
		add_child(cap)


func _strip_terrain_skirts(t: Node3D) -> void:
	# The GLB carries a baked vertical side wall and a shared bottom slab in
	# mat_stone (surface 1).  It is the square "cut plate" silhouette.  Keep
	# every top triangle exactly as authored; delete only the tall side/bottom
	# triangles.  TerrainUnderside then supplies per-island keels.
	var mi: MeshInstance3D = null
	for n in t.find_children("*", "MeshInstance3D", true, false):
		mi = n as MeshInstance3D
		if mi != null and mi.mesh != null:
			break
	if mi == null:
		return
	var overrides: Array = []
	for s in mi.mesh.get_surface_count():
		overrides.append(mi.get_surface_override_material(s))
	# Keep the authored mesh for TerrainCollision.  Removing the rendered side
	# wall must not change the heightfield: the old collider used those side
	# triangles to cover apertures at the rim, and stripping them shifted every
	# arrival by ~0.8 m.
	mi.set_meta("collision_mesh", mi.mesh)
	var out := ArrayMesh.new()
	var removed_total := 0
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var vv := arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var idx := arr[Mesh.ARRAY_INDEX] as PackedInt32Array
		if s == 1 and idx != null:
			var keep := PackedInt32Array()
			keep.resize(idx.size())
			var w := 0
			for k in range(0, idx.size(), 3):
				var a := vv[idx[k]]
				var b := vv[idx[k + 1]]
				var c := vv[idx[k + 2]]
				var lo := minf(a.y, minf(b.y, c.y))
				var hi := maxf(a.y, maxf(b.y, c.y))
				# Top stone is all within ~1.5 m of the turf and <1 m thick.
				# A tall vertical wall or a bottom slab is neither.
				if hi < -1.8 or (hi - lo) > 2.0:
					removed_total += 1
					continue
				keep[w] = idx[k]; keep[w + 1] = idx[k + 1]; keep[w + 2] = idx[k + 2]
				w += 3
			keep.resize(w)
			arr[Mesh.ARRAY_INDEX] = keep
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(s, mi.mesh.surface_get_material(s))
	mi.mesh = out
	for s in out.get_surface_count():
		mi.set_surface_override_material(s, overrides[s] if s < overrides.size() else null)
	print("terrain skirt stripped: removed=%d tris, surfaces=%d, aabb=%s" % [
		removed_total, out.get_surface_count(), str(mi.get_aabb())])


func _hide_broken_underside(t: Node3D) -> void:
	var meshes := t.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		return
	var mi := meshes[0] as MeshInstance3D
	var hide := StandardMaterial3D.new()
	hide.resource_name = "HiddenBrokenUnderside"
	hide.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hide.albedo_color = Color(0, 0, 0, 0)
	hide.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hide.cull_mode = BaseMaterial3D.CULL_DISABLED
	hide.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var n := 0
	for s in range(6, mi.mesh.get_surface_count()):
		mi.set_surface_override_material(s, hide)
		n += 1
	print("hidden broken underside surfaces: ", n)


func _water_depth_texture() -> Texture2D:
	var f := FileAccess.open("res://assets/water_depth.bin", FileAccess.READ)
	if f == null:
		push_warning("water_depth.bin missing")
		return null
	if f.get_buffer(4).get_string_from_ascii() != "WDP2":
		push_warning("water_depth.bin bad magic")
		return null
	var res := f.get_32()
	var max_depth := f.get_float()
	var data := f.get_buffer(res * res * 4)
	f.close()
	var img := Image.create_from_data(res, res, false, Image.FORMAT_RGBA8, data)
	var tex := ImageTexture.create_from_image(img)
	tex.set_meta("depth_max", max_depth)
	return tex


func _build_terrain_collision() -> void:
	var tc := StaticBody3D.new()
	tc.name = "TerrainCollision"
	tc.set_script(load("res://scripts/terrain_collision.gd"))
	add_child(tc)


func _build_building_collision() -> void:
	var bc := Node3D.new()
	bc.name = "BuildingCollision"
	bc.set_script(load("res://scripts/building_collision.gd"))
	add_child(bc)
	bc.call("build")


func _build_slope_stones() -> void:
	var ss := Node3D.new()
	ss.name = "SlopeStones"
	ss.set_script(load("res://scripts/slope_stones.gd"))
	add_child(ss)
	ss.call("build")


func _build_island_signatures() -> void:
	var sig = load("res://scripts/island_signatures.gd").new()
	sig.build(self)

func _build_water() -> void:
	# Build each water surface from the organic pond contour emitted alongside
	# water_ponds.json.  The old water.glb surface was cell-aligned and showed
	# four straight cuts through the village pond; the contour is already the
	# sampled waterline used by the shore ribbon, so the two meet with no gap.
	var data: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://assets/water_ponds.json"))
	if data.is_empty() or not data.has("ponds"):
		push_warning("water_ponds.json missing")
		return
	var shader := load("res://shaders/water.gdshader") as Shader
	var mat := ShaderMaterial.new()
	if shader != null:
		mat.shader = shader
		_water_mat = mat
		var zenith := Color(0.18, 0.26, 0.54)
		var atmo := get_node_or_null("/root/Atmosphere")
		if atmo != null:
			var z: Variant = atmo.get("sky_top_color")
			if z is Color:
				zenith = z
		mat.set_shader_parameter("sky_reflect_color", zenith)
		mat.set_shader_parameter("sun_dir",
				Vector3(cos(deg_to_rad(28.0)) * sin(deg_to_rad(45.0)),
						sin(deg_to_rad(28.0)),
						cos(deg_to_rad(28.0)) * cos(deg_to_rad(45.0))).normalized())
		print("WATER sky_reflect_color runtime=",
				mat.get_shader_parameter("sky_reflect_color"), " atmo=", atmo != null)
	var w := Node3D.new()
	w.name = "Water"
	var bodies := 0
	var boundary_total := 0
	var max_straight := 0.0
	for pond in data["ponds"]:
		var P: Array = pond.get("P", [])
		if P.size() < 3:
			continue
		var level: float = float(pond.get("level", 0.0))
		var poly := PackedVector2Array()
		for q in P:
			poly.append(Vector2(float(q[0]), float(q[1])))
		# Fan from the contour centroid, not a boundary vertex: this keeps the
		# long triangle edges out of the water interior, where the shader's
		# depth/reflection march showed them as thin straight lines.
		var cx := 0.0
		var cz := 0.0
		for q in P:
			cx += float(q[0])
			cz -= float(q[1])
		cx /= float(P.size())
		cz /= float(P.size())
		# Ear-clip the real contour.  The old centroid fan put one vertex on
		# the rim and spread spokes across the whole pond, which is exactly the
		# fan triangulation visible in the top-down capture.
		var idx := _triangulate_contour(poly)
		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		for q in P:
			verts.append(Vector3(float(q[0]), level + 0.010, -float(q[1])))
			norms.append(Vector3.UP)
		var max_edge := 0.0
		for i in range(P.size()):
			var q0 := Vector2(float(P[i][0]), float(P[i][1]))
			var q1 := Vector2(float(P[(i + 1) % P.size()][0]),
					float(P[(i + 1) % P.size()][1]))
			max_edge = maxf(max_edge, q0.distance_to(q1))
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.name = "Pond_%d" % int(pond.get("pond", bodies))
		mi.mesh = mesh
		if shader != null:
			# Per-pond copy carries the basin centre/radius so the water shader
			# can give a shallow-to-deep read without a carved bed.
			var pm := mat.duplicate() as ShaderMaterial
			var pr := 0.0
			for q in P:
				pr = maxf(pr, Vector2(float(q[0]) - cx, -float(q[1]) - cz).length())
			pm.set_shader_parameter("pond_center", Vector2(cx, cz))
			pm.set_shader_parameter("pond_radius", maxf(pr, 1.0))
			mi.material_override = pm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		w.add_child(mi)
		bodies += 1
		boundary_total += P.size()
		print("WATER_POND %s verts=%d tris=%d max_edge=%.3f m" % [
			mi.name, P.size(), idx.size() / 3, max_edge])
		max_straight = maxf(max_straight, float(pond.get("max_straight_run_m", 0.0)))
	add_child(w)
	print("water bodies: %d contour surfaces, %d boundary verts, max_straight=%.2f m" % [
			bodies, boundary_total, max_straight])


func _triangulate_contour(poly: PackedVector2Array) -> PackedInt32Array:
	# Ear clipping for a simple contour.  Concave ponds are exactly where a
	# centroid fan produces long spokes, so never fall back to a centre fan
	# unless the contour is degenerate.
	var n := poly.size()
	var idx := PackedInt32Array()
	if n < 3:
		return idx
	var area := 0.0
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	for i in n:
		idx.append(i if area > 0.0 else n - 1 - i)
	var out := PackedInt32Array()
	var guard := 0
	while idx.size() > 3 and guard < n * n:
		guard += 1
		var clipped := false
		for i in idx.size():
			var ia := idx[(i - 1 + idx.size()) % idx.size()]
			var ib := idx[i]
			var ic := idx[(i + 1) % idx.size()]
			var a := poly[ia]
			var b := poly[ib]
			var c := poly[ic]
			if (b - a).cross(c - a) <= 0.0000001:
				continue
			var contains := false
			for j in idx:
				if j == ia or j == ib or j == ic:
					continue
				var p := poly[j]
				var d1 := (b - a).cross(p - a)
				var d2 := (c - b).cross(p - b)
				var d3 := (a - c).cross(p - c)
				if d1 >= 0.0 and d2 >= 0.0 and d3 >= 0.0:
					contains = true
					break
			if contains:
				continue
			out.append(ia); out.append(ib); out.append(ic)
			idx.remove_at(i)
			clipped = true
			break
		if not clipped:
			break
	if idx.size() == 3:
		out.append(idx[0]); out.append(idx[1]); out.append(idx[2])
	elif idx.size() > 3:
		# Degenerate/self-intersecting contour: fan only the remainder.
		for i in range(1, idx.size() - 1):
			out.append(idx[0]); out.append(idx[i]); out.append(idx[i + 1])
	return out


func _build_pond_shore() -> void:
	var ps := Node3D.new()
	ps.name = "PondShore"
	ps.set_script(load("res://scripts/pond_shore.gd"))
	add_child(ps)
	ps.call("build", self)

func _build_island_shores() -> void:
	var shore := Node3D.new()
	shore.name = "IslandShore"
	shore.set_script(load("res://scripts/island_shore.gd"))
	add_child(shore)
	shore.call("build", self)

func _build_pond_banks() -> void:
	var pb := Node3D.new()
	pb.name = "PondBanks"
	pb.set_script(load("res://scripts/pond_banks.gd"))
	add_child(pb)
	pb.call("build", self)


func _build_pond_funnels() -> void:
	var pf := Node3D.new()
	pf.name = "PondFunnels"
	pf.set_script(load("res://scripts/pond_funnel.gd"))
	add_child(pf)
	pf.call("build", self)


func _build_aperture_caps() -> void:
	var ac := Node3D.new()
	ac.name = "ApertureCaps"
	ac.set_script(load("res://scripts/aperture_caps.gd"))
	add_child(ac)
	ac.call("build")



func _is_solid_prop(model: String) -> bool:
	var m := model.to_lower()
	# Vegetation and floating shards stay non-solid; every built/placed object
	# that a player can collide with gets a generated box.
	for skip: String in ["plants/", "trees/", "shards/"]:
		if m.begins_with(skip):
			return false
	for key: String in ["statue", "ruin", "column", "rubble", "slab", "boulder", "crystal"]:
		if m.contains(key):
			return true
	return false


func _local_mesh_aabb(root: Node3D) -> AABB:
	var mn := Vector3(1.0e20, 1.0e20, 1.0e20)
	var mx := Vector3(-1.0e20, -1.0e20, -1.0e20)
	var inv := root.global_transform.affine_inverse()
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := inv * mi.global_transform
		for surf in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(surf)
			if arr.is_empty():
				continue
			for v in (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				var p: Vector3 = xf * v
				mn = mn.min(p)
				mx = mx.max(p)
	if mn.x > 1.0e19:
		return AABB()
	return AABB(mn, mx - mn)


func _add_prop_collision(root: Node3D, model: String) -> void:
	if root == null:
		return
	var ab := _local_mesh_aabb(root)
	if ab.size.length() < 0.01:
		return
	var body := StaticBody3D.new()
	body.name = "Solid_%s" % String(root.name).replace("Prop_", "")
	body.collision_layer = 2
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(ab.size.x, 0.04), maxf(ab.size.y, 0.04),
			maxf(ab.size.z, 0.04))
	cs.shape = box
	cs.position = ab.get_center()
	body.add_child(cs)
	root.add_child(body)


func _build_props() -> void:
	var n := 0
	for p in _layout["props"]:
		var x: float = p["x"]
		# Blender exports +Y as glTF -Z, so terrain.glb arrives mirrored in z
		# relative to map_layout.json. Layout-driven placement must negate z or
		# every prop lands on the wrong side of its island (~1.2 m off).
		var z: float = -float(p["z"])
		var y: float = float(p.get("y", 0.0))
		# base = metres to raise the instance so its lowest vertex rests on the
		# ground. Many assets have their origin above or below the mesh, which
		# left them visibly hovering (or buried) even at y = 0.
		var base: float = float(p.get("base", 0.0))
		var scl := float(p.get("scale", 0.85 + float(absi(hash(p["model"])) % 35) / 100.0))
		var yaw := float(p.get("yaw", float(absi(hash(str(x) + str(z))) % 628) / 100.0))
		var m: String = p["model"]
		# This one fern sat at the angel-statue overlook and, at its world
		# scale, read as a silver wire birdcage against the sky: its thin black
		# petiole cards dominate the silhouette.  Replace that single instance
		# with a small broadleaf tree; it is still decoration, still non-solid,
		# and matches the green canopy palette of the nearby trees.
		if m == "plants/fern_teal_l" and absf(x + 59.427) < 0.05 and absf(z + 40.75) < 0.05:
			m = "trees/tree_green_s"
			scl *= 0.55
		# Two floating-shard props shared that exact overlook and supplied the
		# black vertical cards around the fern.  With a leafy tree in the same
		# spot they read as a burnt wire cage under the trunk; drop only this
		# pair.  Shards elsewhere are untouched.
		if m == "shards/shards_floating" and absf(z + 40.75) < 0.05 				and x > -61.5 and x < -59.0:
			continue
		# structures and trees need to read at island scale
		# Trees at 1.7x read as a forest wall: canopies 8-10 m wide on a 20 m
		# island. Structures keep some extra height, trees do not.
		if m.find("crystal") >= 0:
			# Crystals are landmarks, not mountains: half scale keeps the
			# tallest crystal tree below house height.
			scl *= 0.50
		elif m.find("tree") >= 0:
			# Big tree silhouettes are part of the island read. 1.7x was
			# removed in an earlier pass and made the forests disappear at
			# spawn; restore the authored scale.
			scl *= 1.7
		elif m.find("statue") >= 0 or m.find("ruin") >= 0 or m.find("arch") >= 0 \
				or m.find("column") >= 0 or m.find("rubble") >= 0 \
				or m.find("slab") >= 0:
			scl *= 1.45
		elif m.find("grass") >= 0 or m.find("fern") >= 0 or m.find("shrub") >= 0 \
				or m.find("flower") >= 0 or m.find("tulip") >= 0 or m.find("reed") >= 0:
			scl *= 1.25
		var spawned := _spawn(m, Vector3(x, y + base * scl, z), yaw, scl)
		if spawned != null:
			# Raw model roots (not renamed Prop_*) are skipped by the named
			# grounding pass.  One bank boulder at (-8.5,-71.3) was 0.82 m
			# clear of the ground; seat only that loose-boulder root here.
			if m.ends_with("rocks/boulder_s") or m.ends_with("boulder_s"):
				var bl := _lowest_world_mesh_y(spawned)
				var bg := _terrain_y(spawned.global_position.x, spawned.global_position.z)
				var bt := get_node_or_null("TerrainCollision")
				if bt != null:
					var bw := float(bt.call("walkable_height", spawned.global_position.x, spawned.global_position.z))
					if not is_nan(bw) and bw > -6.0: bg = bw
				if bl < 1.0e29 and bg > -10.0 and bl > bg + 0.01:
					spawned.position.y -= bl - bg - 0.01
			n += 1
			# Ruin slabs/columns/rubble are authored mat_stone props and never
			# went through the building palette.  Give them the procedural
			# stone treatment; crystals/plants/trees are deliberately untouched.
			if m.begins_with("ruins/"):
				PropSurface.apply_ruins(spawned, OS.get_environment("PROP_DEBUG") == "1")
			if m.find("statue") >= 0 or m.find("ruin") >= 0:
				spawned.name = "Monument_%s_%02d" % [m.get_file().get_basename(), n]
			if p.has("tilt"):
				spawned.rotate_object_local(Vector3.RIGHT, deg_to_rad(float(p["tilt"])))
			if _is_solid_prop(m):
				_add_prop_collision(spawned, m)
			# a soft dark patch under each prop: cheaper and more convincing
			# than any shadow map at this scale, and it kills the "hovering"
			# look that a 1 m shadow texel leaves behind
			var r := scl * 0.62
			if m.find("tree") >= 0 or m.find("statue") >= 0 or m.find("ruin") >= 0 \
					or m.find("arch") >= 0 or m.find("column") >= 0:
				r = scl * 1.15
			_shadow_specs.append([Vector3(x, y + 0.05, z), r])
	_build_prop_shadows()
	print("props spawned: ", n)


func _build_buildings() -> void:
	var interior_jobs: Array = []
	# Layout-driven modular buildings.  Positions/yaw/y live in map_layout.json
	# so the placement tool and the runtime agree; no coordinates here.
	if not _layout.has("buildings"):
		print("buildings placed: 0")
		return
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.31, 0.29, 0.265)
	stone.roughness = 0.92
	stone.metallic = 0.0
	stone.cull_mode = BaseMaterial3D.CULL_BACK
	var n := 0
	for b in _layout["buildings"]:
		var model: String = b["model"]
		var path := "res://assets/models/%s.glb" % model
		var packed := load(path) as PackedScene
		if packed == null:
			push_warning("missing building model " + path)
			continue
		var inst := packed.instantiate() as Node3D
		if inst == null:
			continue
		var x := float(b["x"])
		var z := -float(b["z"])
		var y := float(b["y"])
		var yaw := float(b["yaw"])
		var scl := float(b.get("scale", 1.0))
		inst.name = "Building_%s" % String(b["id"])
		inst.position = Vector3(x, y, z)
		inst.rotation.y = yaw
		inst.scale = Vector3(scl, scl, scl)
		add_child(inst)
		VillagePalette.apply(inst)
		# b2 is the shaded house on the north side of the green; its timber
		# reads red-purple at distance because the blue ambient dominates the
		# shadowed boards.  Give only this building a warmer yellow-brown wood
		# material so it sits in the same hue band as b1 without lifting the
		# whole village's wood luminance.
		if String(b["id"]) == "village_house_b2":
			var b2wood := VillagePalette.material("wood").duplicate() as ShaderMaterial
			b2wood.set_shader_parameter("base_color", Color(0.205, 0.160, 0.085, 1.0))
			b2wood.set_shader_parameter("wood_gain", 0.32)
			b2wood.set_shader_parameter("extra_fill", Vector3(0.0, 0.008, 0.0))
			for b2mi0 in inst.find_children("*", "MeshInstance3D", true, false):
				var b2mi := b2mi0 as MeshInstance3D
				if b2mi.mesh == null: continue
				for b2s in b2mi.mesh.get_surface_count():
					var b2ov := b2mi.get_surface_override_material(b2s)
					if b2ov is ShaderMaterial and String((b2ov as ShaderMaterial).resource_name) == "wood":
						b2mi.set_surface_override_material(b2s, b2wood)
		# Cheap room liner for the house modules: a raised floor, four inner
		# walls and a dark ceiling.  No footprint, origin or material-slot
		# changes; the original GLB stays the source of the exterior.  Floor
		# height needs terrain collision, which is not in the physics space
		# until the first physics frame, so collect and dress after that.
		if String(model).ends_with("building_house_a") or String(model).ends_with("building_house_b"):
			interior_jobs.append([inst, String(model), String(b["id"])])
		# A flat stone terrace under each modular base: the terrain relief is
		# filled to the highest footprint sample, so no piece floats or is
		# half-buried.  The pad is part of the building, not a terrain edit.
		var pad_h := float(b.get("pad_h", 0.0))
		if pad_h > 0.02:
			var fp: Array = b.get("footprint", [0.0, 0.0])
			var pad := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(float(fp[0]) * 0.98, pad_h, float(fp[1]) * 0.98)
			pad.mesh = box
			pad.name = "Pad_%s" % String(b["id"])
			pad.position = Vector3(x, y - pad_h * 0.5 + 0.01, z)
			pad.rotation.y = yaw
			var earth_mat := ShaderMaterial.new()
			earth_mat.shader = load("res://shaders/ground_earth.gdshader")
			pad.material_override = earth_mat
			pad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			add_child(pad)
		n += 1
	print("buildings placed: ", n)
	if not interior_jobs.is_empty():
		call_deferred("_dress_interiors", interior_jobs)


func _bank_rock_mat(tone: Color) -> ShaderMaterial:
	var rock := ShaderMaterial.new()
	rock.shader = load("res://shaders/bank_rock.gdshader") as Shader
	rock.set_shader_parameter("rock_albedo", load("res://assets/textures/stone_basalt/albedo.jpg"))
	rock.set_shader_parameter("rock_rough", load("res://assets/textures/stone_basalt/rough.jpg"))
	rock.set_shader_parameter("rock_tone", Vector3(tone.r, tone.g, tone.b))
	return rock

func _seat_bank_rock(inst: Node3D) -> void:
	var low := _lowest_world_mesh_y(inst)
	var gy := _terrain_y(inst.global_position.x, inst.global_position.z)
	var tcol := get_node_or_null("TerrainCollision")
	if tcol != null:
		var wh := float(tcol.call("walkable_height", inst.global_position.x, inst.global_position.z))
		if not is_nan(wh) and wh > -6.0:
			gy = wh
	if low < 1.0e29 and gy > -10.0 and low > gy + 0.01:
		inst.position.y -= low - gy - 0.01

func _build_bank_props() -> void:
	# Bank boulders are layout data.  Around the village pond the authored
	# spacing was an even ring of one rounded model, so that ring is re-dressed:
	# gaps, doubles, 5 models, 3-axis rotation, varied sink and per-rock tone.
	if not _layout.has("props_bank"):
		print("bank boulders placed: 0")
		return
	var pond_c := Vector2(-2.1, -14.2)
	var near_pts: Array[Vector2] = []
	var n := 0
	var extra := 0
	for p in _layout["props_bank"]:
		var model: String = p["model"]
		var path := "res://assets/models/%s.glb" % model
		var packed := load(path) as PackedScene
		if packed == null:
			push_warning("missing bank rock model " + path)
			continue
		var inst := packed.instantiate() as Node3D
		if inst == null:
			continue
		var wx := float(p["x"])
		var wz := -float(p["z"])
		var near := Vector2(wx, wz).distance_to(pond_c) < 12.5
		var h := absi(hash("%s_%d" % [model, n]))
		if near and h % 10 < 4:
			continue  # open gaps in the even ring
		var scl := float(p.get("scale", 1.0))
		var base := float(p.get("base", 0.0))
		var sink := float(p.get("sink", 0.0))
		var yaw := float(p.get("yaw", 0.0))
		if near:
			scl *= 0.55 + float(h % 100) / 100.0 * 0.80
			scl = minf(scl, 1.65)
			sink += 0.02 + float((h / 7) % 23) / 100.0
			yaw += float((h / 13) % 628) / 100.0
			wx += (float((h / 17) % 21) / 20.0 - 0.5) * 0.7
			wz += (float((h / 23) % 21) / 20.0 - 0.5) * 0.7
		inst.name = "BankRock_%d" % n
		inst.position = Vector3(wx, float(p["y"]) + base * scl - sink, wz)
		inst.rotation = Vector3(
				float((h / 29) % 15 - 7) * 0.012 if near else 0.0,
				yaw,
				float((h / 31) % 15 - 7) * 0.012 if near else 0.0)
		inst.scale = Vector3(scl, scl, scl)
		var tone := Color(1.0, 1.0, 1.0)
		if near:
			var tv := 0.48 + float(h % 48) / 100.0
			tone = Color(tv * (1.04 + float(h % 7) * 0.012), tv * 0.97, tv * (0.88 + float(h % 5) * 0.015))
		var rock := _bank_rock_mat(tone)
		for child in inst.find_children("*", "MeshInstance3D", true, false):
			(child as MeshInstance3D).material_override = rock
		add_child(inst)
		_seat_bank_rock(inst)
		n += 1
		if near:
			near_pts.append(Vector2(inst.global_position.x, inst.global_position.z))
		# Doubles: a smaller companion tight against the parent.
		if near and h % 9 == 0:
			var dup := packed.instantiate() as Node3D
			if dup != null:
				dup.name = "BankRockPair_%d" % n
				dup.position = inst.position + Vector3(0.34, -0.03, 0.18)
				dup.rotation = Vector3(0.04, yaw + 1.1, -0.03)
				dup.scale = Vector3(scl * 0.58, scl * 0.52, scl * 0.62)
				var dmat := _bank_rock_mat(tone * 1.08)
				for child in dup.find_children("*", "MeshInstance3D", true, false):
					(child as MeshInstance3D).material_override = dmat
				add_child(dup)
				_seat_bank_rock(dup)
				near_pts.append(Vector2(dup.global_position.x, dup.global_position.z))
				extra += 1
	# Flat slabs, small cobbles and a second boulder model in the gaps.
	var cont: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/water_ponds.json"))
	var P: Array = []
	for pd in cont.get("ponds", []):
		if int(pd.get("pond", -1)) == 6:
			P = pd.get("P", [])
			break
	var extra_models := ["props/prop_bank_rock_s", "rocks_boulder_s", "ruins_slab_mossy_s"]
	var extra_indices: Array[int] = []
	for frac: float in [0.18, 0.52, 0.78]:
		for sub in 3:
			extra_indices.append(int(P.size() * frac) + sub * 2)
	for k in extra_indices:
		if k >= P.size():
			continue
		var q: Array = P[k]
		var px := float(q[0])
		var pz := -float(q[1])
		var out := (Vector2(px, pz) - pond_c).normalized()
		var ex := px + out.x * (0.45 + (k % 3) * 0.34)
		var ez := pz + out.y * (0.45 + (k % 3) * 0.34)
		if Vector2(ex, ez).distance_to(pond_c) < 2.0:
			continue
		var model: String = extra_models[(k / 7) % extra_models.size()]
		var packed := load("res://assets/models/%s.glb" % model) as PackedScene
		if packed == null:
			continue
		var inst := packed.instantiate() as Node3D
		if inst == null:
			continue
		var h := absi(hash("extra_%d" % k))
		var s := (0.50 + float(h % 65) / 100.0) if model.contains("slab") == false else (0.80 + float(h % 45) / 100.0)
		inst.name = "BankDetail_%d" % k
		inst.position = Vector3(ex, _terrain_y(ex, ez) + 0.02, ez)
		inst.rotation = Vector3(
				float(h % 13 - 6) * 0.025 if model.contains("slab") else float(h % 9 - 4) * 0.02,
				float(h % 628) / 100.0,
				float(h % 11 - 5) * 0.025 if model.contains("slab") else float(h % 7 - 3) * 0.02)
		inst.scale = Vector3(s, s * (0.45 if model.contains("slab") else 1.0), s)
		var tone := Color(0.52 + float(h % 9) * 0.03, 0.49 + float(h % 7) * 0.03, 0.44 + float(h % 5) * 0.03)
		var mat := _bank_rock_mat(tone)
		for child in inst.find_children("*", "MeshInstance3D", true, false):
			(child as MeshInstance3D).material_override = mat
		add_child(inst)
		_seat_bank_rock(inst)
		near_pts.append(Vector2(ex, ez))
		n += 1
		extra += 1
	# Spacing along the contour = nearest-neighbour gap after sorting by angle.
	var gaps: Array[float] = []
	if near_pts.size() > 3:
		near_pts.sort_custom(func(a, b): return atan2(a.y - pond_c.y, a.x - pond_c.x) < atan2(b.y - pond_c.y, b.x - pond_c.x))
		for i in near_pts.size():
			gaps.append(near_pts[i].distance_to(near_pts[(i + 1) % near_pts.size()]))
		gaps.sort()
	print("bank boulders placed: %d (pond extras=%d, models=5, gap min=%.2f max=%.2f mean=%.2f)" % [
			n, extra, gaps[0] if gaps.size() > 0 else 0.0,
			gaps[-1] if gaps.size() > 0 else 0.0,
			(gaps.reduce(func(a, b): return a + b, 0.0) / gaps.size()) if gaps.size() > 0 else 0.0])


func _dress_interiors(jobs: Array) -> void:
	# Two physics frames: one to insert the terrain body, one to sync the
	# direct-space state before the ray queries in _terrain_y.
	await get_tree().physics_frame
	await get_tree().physics_frame
	for job in jobs:
		var inst: Node3D = job[0]
		if not is_instance_valid(inst): continue
		var liner = load("res://scripts/building_interior.gd").new()
		var added: int = liner.dress(inst, String(job[1]))
		print("INTERIOR %s tris_added=%d" % [String(job[2]), added])

func _terrain_y(x: float, z: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(x, 60.0, z), Vector3(x, -60.0, z), 1)
	var h := get_world_3d().direct_space_state.intersect_ray(q)
	return float(h["position"].y) if not h.is_empty() else 0.0


func _pad_top(c: Vector3, yaw: float, w: float, d: float) -> float:
	var lo := 1.0e30
	for sx in [-0.5, 0.5]:
		for sz in [-0.5, 0.5]:
			var l := Vector3(sx * w, 0.0, sz * d).rotated(Vector3.UP, yaw)
			lo = minf(lo, _terrain_y(c.x + l.x, c.z + l.z))
	return lo


func _pad_high(c: Vector3, yaw: float, w: float, d: float) -> float:
	var hi := -1.0e30
	for sx in [-0.5, 0.5]:
		for sz in [-0.5, 0.5]:
			var l := Vector3(sx * w, 0.0, sz * d).rotated(Vector3.UP, yaw)
			hi = maxf(hi, _terrain_y(c.x + l.x, c.z + l.z))
	return hi


func _build_roof_backers() -> void:
	# Some house roof meshes have rectangular gaps at the ridge (missing tile
	# quads).  Through them the dark plaster interior reads as black holes.
	# A brown horizontal backer just under the ridge fills the sightline with
	# roof-coloured material instead.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.170, 0.120, 0.078)
	mat.roughness = 0.95
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for n in find_children("Building_*", "Node3D", true, false):
		var root := n as Node3D
		var mi: MeshInstance3D = null
		for c in root.find_children("*", "MeshInstance3D", true, false):
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
				mi = c as MeshInstance3D
				break
		if mi == null:
			continue
		var box := mi.get_aabb()
		var gt := mi.global_transform
		var c0 := gt * box.get_center()
		var top := gt * Vector3(box.get_center().x, box.end.y, box.get_center().z)
		var q := QuadMesh.new()
		q.size = Vector2(box.size.x * 0.98, box.size.z * 0.98)
		var backer := MeshInstance3D.new()
		backer.name = "RoofBacker"
		backer.mesh = q
		backer.material_override = mat
		backer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(backer)
		backer.global_position = Vector3(top.x, top.y - 1.85, top.z)

func _build_roof_caps() -> void:
	# Top-down read: one flat terracotta cap per building guarantees a readable
	# roof even where the imported mesh has a black/cream unnamed material.
	var sh := load("res://shaders/roof_overlay.gdshader") as Shader
	var mat := ShaderMaterial.new()
	mat.shader = sh
	for n in find_children("Building_*", "Node3D", true, false):
		var root := n as Node3D
		var mi: MeshInstance3D = null
		for c in root.find_children("*", "MeshInstance3D", true, false):
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
				mi = c as MeshInstance3D
				break
		if mi == null:
			continue
		var box := mi.get_aabb()
		var gt := mi.global_transform
		var c0 := gt * box.get_center()
		var top := gt * Vector3(box.get_center().x, box.end.y, box.get_center().z)
		var cap := MeshInstance3D.new()
		cap.name = "RoofCap"
		var bm := BoxMesh.new()
		bm.size = Vector3(box.size.x * 1.03, 0.08, box.size.z * 1.03)
		cap.mesh = bm
		cap.material_override = mat
		cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(cap)
		cap.global_position = Vector3(c0.x, top.y + 0.10, c0.z)

func _build_village_props() -> void:
	# Small dressed props (barrels, cart, fences, lanterns, woodpiles) are
	# layout data too: no coordinates here.  The models are base-centre origin,
	# so y is the terrain contact height from tools/place_village_props.py.
	if not _layout.has("props_placed"):
		print("village props placed: 0")
		return
	var n := 0
	for p in _layout["props_placed"]:
		var model: String = p["model"]
		var path := "res://assets/models/%s.glb" % model
		var packed := load(path) as PackedScene
		if packed == null:
			push_warning("missing village prop model " + path)
			continue
		var inst := packed.instantiate() as Node3D
		if inst == null:
			continue
		inst.name = "Prop_%s" % String(p["id"])
		inst.position = Vector3(float(p["x"]), float(p["y"]), -float(p["z"]))
		if model == "props/prop_market_stall":
			# Market stalls are level: yaw only.  Tilt-onto-terrain skews the
			# frame (splayed posts, parallelogram awning) and is wrong here.
			inst.rotation.y = float(p.get("yaw", 0.0))
		elif p.has("basis"):
			var b: Array = p["basis"]
			inst.basis = Basis(
				Vector3(float(b[0]), float(b[1]), float(b[2])),
				Vector3(float(b[3]), float(b[4]), float(b[5])),
				Vector3(float(b[6]), float(b[7]), float(b[8])))
		else:
			inst.rotation.y = float(p.get("yaw", 0.0))
		var scl := float(p.get("scale", 1.0))
		if model == "props/prop_woodpile":
			scl *= 0.60
		inst.scale = Vector3(scl, scl, scl)
		if model == "props/prop_market_stall":
			# The imported stall frame has no collider.  Add the interaction
			# proxy here, where the already-mirrored world position is known.
			var sb := StaticBody3D.new()
			sb.name = "Solid_village_market_stall"
			sb.collision_layer = 2
			var scs := CollisionShape3D.new()
			var sbox := BoxShape3D.new()
			sbox.size = Vector3(2.35, 1.05, 1.55)
			scs.shape = sbox
			sb.add_child(scs)
			sb.position = inst.position + Vector3(0.0, 0.85, 0.0)
			sb.rotation.y = inst.rotation.y
			add_child(sb)
			# The collision stream is not queryable during _ready, so final
			# pad/ground contact is deferred until one physics frame has run.
			var local_min := 1.0e30
			for mi0 in inst.find_children("*", "MeshInstance3D", true, false):
				var mi := mi0 as MeshInstance3D
				if mi.mesh == null: continue
				for surf in mi.mesh.get_surface_count():
					for v in (mi.mesh.surface_get_arrays(surf)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
						local_min = minf(local_min, v.y)
			if local_min > 1.0e29: local_min = 0.0
			call_deferred("_finalize_market_stall", inst,
					Vector3(float(p["x"]), 0.0, -float(p["z"])),
					float(p["y"]), float(p.get("yaw", 0.0)), scl, local_min)
		add_child(inst)
		if not model.to_lower().contains("banner"):
			_add_prop_collision(inst, model)
		# The market stall's awning is cloth, not plaster: keep its original
		# blue/gold material.  Its frame is timber, so map iron to wood there.
		if model == "props/prop_market_stall":
			VillagePalette.apply(inst, {
				"map": {"metal_dark": "wood"},
				"skip": ["plaster", "trim"],
			})
			VillagePalette.apply_cloth(inst)
		else:
			VillagePalette.apply(inst)
		# Barrels/crates/carts/fences: timber-only procedural overlay.  Cloth
		# and iron keep their existing palette treatment.
		PropSurface.apply_village(inst, model, OS.get_environment("PROP_DEBUG") == "1")
		n += 1
	print("village props placed: ", n)


func _finalize_market_stall(stall: Node3D, c: Vector3, y: float, yaw: float,
		scl: float, local_min: float) -> void:
	await get_tree().physics_frame
	# 0.12 m stone pad at the layout contact height, plus a stone footing down
	# to the lowest terrain corner so the low side is seated, not floating.
	# Thin earth lip: 0.03 m proud of the grass at the stall centre, with the
	# 0.12 m slab sunk into the bank. No footing, so no tall unlit face.
	var pad_top := _terrain_y(c.x, c.z) + 0.03
	stall.position.y = pad_top - local_min * scl
	var pad := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2.6, 0.12, 1.8)
	pad.mesh = box
	pad.name = "Pad_village_market_stall"
	pad.position = Vector3(c.x, pad_top - 0.06, c.z)
	pad.rotation.y = yaw
	var earth_mat := ShaderMaterial.new()
	earth_mat.shader = load("res://shaders/ground_earth.gdshader")
	pad.material_override = earth_mat
	pad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(pad)
	# The stone pad is a solid prop too: walk up onto it, not through/under it.
	var pad_body := StaticBody3D.new()
	pad_body.name = "Solid_village_market_stall_pad"
	pad_body.collision_layer = 2
	var pcs := CollisionShape3D.new()
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(2.6, 0.12, 1.8)
	pcs.shape = pbox
	pad_body.add_child(pcs)
	# Assign local transform while detached.  global_position requires the
	# node to be inside the tree and used to emit a boot-time
	# "Condition !is_inside_tree()" engine error here.
	pad_body.position = Vector3(c.x, pad_top - 0.06, c.z)
	pad_body.rotation.y = yaw
	add_child(pad_body)
	print("STALL_PAD x=%.3f z=%.3f top=%.4f (0.03 above centre grass)" % [c.x, c.z, pad_top])


func _build_prop_shadows() -> void:
	if _shadow_specs.is_empty():
		return
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for py in range(64):
		for px in range(64):
			var d := Vector2(px - 31.5, py - 31.5).length() / 31.5
			var a := clampf(1.0 - d * d, 0.0, 1.0)
			img.set_pixel(px, py, Color(0.0, 0.0, 0.0, a * a * 0.55))
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.render_priority = -1

	var plane := PlaneMesh.new()
	plane.size = Vector2(1.0, 1.0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = plane
	mm.instance_count = _shadow_specs.size()
	for i in range(_shadow_specs.size()):
		var spec: Array = _shadow_specs[i]
		var pos: Vector3 = spec[0]
		var r: float = spec[1]
		mm.set_instance_transform(i, Transform3D(
				Basis.from_scale(Vector3(r * 2.0, 1.0, r * 2.0)), pos))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "PropShadows"
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	print("contact shadows: ", _shadow_specs.size())


func _build_vignette() -> void:
	# Multiply a radial gradient over the frame. This replaced a shader that
	# sampled hint_screen_texture from a CanvasLayer: in 2D that needs a
	# BackBufferCopy, and without one it samples an undefined buffer and paints
	# the screen a solid colour. A gradient texture cannot fail that way.
	var tex := load("res://assets/ui/vignette.png") as Texture2D
	if tex == null:
		push_warning("vignette texture missing")
		return
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	var rect := TextureRect.new()
	rect.name = "Grade"
	rect.texture = tex
	rect.material = mat
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var layer := CanvasLayer.new()
	layer.name = "PostLayer"
	layer.layer = 100
	layer.add_child(rect)
	add_child(layer)


func _is_land(x: int, z: int) -> bool:
	if x < 0 or z < 0 or x >= W or z >= H:
		return false
	return _land.has(z * W + x)


func _compute_islands() -> void:
	# island id per land cell, so bridges only ever span DIFFERENT islands
	_island_of.clear()
	var next_id := 0
	for start in _land.keys():
		if _island_of.has(start):
			continue
		var q: Array = [start]
		_island_of[start] = next_id
		while q.size() > 0:
			var c: int = q.pop_back()
			var x: int = c % W
			var z: int = c / W
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + d.x
				var nz: int = z + d.y
				if nx < 0 or nz < 0 or nx >= W or nz >= H:
					continue
				var n: int = nz * W + nx
				if _land.has(n) and not _island_of.has(n):
					_island_of[n] = next_id
					q.append(n)
		next_id += 1


func _build_bridges() -> void:
	# bridges.glb is baked from map_layout.json by tools/bridges_to_blender.py:
	# each span runs rim-to-rim between two different islands and sags under its
	# own weight.  The engine used to drop a scaled walkway model at the gap
	# midpoint, which is why the bridges lay about on the grass.
	var packed := load("res://assets/bridges.glb") as PackedScene
	if packed == null:
		push_warning("bridges.glb missing")
		return
	var b := packed.instantiate() as Node3D
	b.name = "Bridges"
	add_child(b)
	var n := 0
	if _layout.has("bridges"):
		n = _layout["bridges"].size()
	print("bridges: ", n)


func _build_waterfalls() -> void:
	# falling water is a static ribbon with a scrolling shader: the mesh does
	# not move, the noise field travels down it
	var wsh := load("res://shaders/waterfall.gdshader") as Shader
	var wmat: ShaderMaterial = null
	if wsh != null:
		wmat = ShaderMaterial.new()
		wmat.shader = wsh
	if _layout.has("waterfalls") and not _layout["waterfalls"].is_empty():
		var nf := 0
		for f in _layout["waterfalls"]:
			# the sheet is 3.2 m tall with its origin at the base; hang it so
			# the top edge sits on the turf and the water pours DOWN the cliff
			# the lip follows the terrain relief, so the sheet's top has to as
			# well or it floats under (or sinks into) the island edge
			var fy: float = float(f.get("y", -3.2))
			var node := _spawn("water_waterfall",
					Vector3(f["x"], fy, -float(f["z"])), float(f["yaw"]), 1.0)
			if node != null:
				nf += 1
				if wmat != null:
					for m in node.find_children("*", "MeshInstance3D", true, false):
						var mi := m as MeshInstance3D
						mi.material_override = wmat
						mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		print("waterfalls: ", nf)
		return
	var placed := 0
	for i in _land.keys():
		if placed >= 14:
			break
		var x: int = i % W
		var z: int = i / W
		# pour off the rim, and only well inside the map
		if x < 6 or z < 6 or x > W - 6 or z > H - 6:
			continue
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if not _is_land(x + d.x, z + d.y):
				if absi(hash(Vector2i(x, z))) % 9 != 0:
					break
				var yaw: float = atan2(float(d.x), float(d.y))
				var pos := Vector3(x + d.x * 0.5 - W * 0.5, -0.6, z + d.y * 0.5 - H * 0.5)
				if _spawn("water_waterfall", pos, yaw, 0.8) != null:
					placed += 1
				break
	print("waterfalls: ", placed)


var _dragons: Array = []
var _dragon_mat: StandardMaterial3D = null
var _shadow_specs: Array = []
var _dragon_time := 0.0


func _dragon_shader_material(src: StandardMaterial3D) -> ShaderMaterial:
	# The detailed dragon is one textured material.  Keep the authored
	# texture and normal/roughness maps, but drive value with a shader so the
	# dorsal, belly and wing membrane read as different surfaces at 40-60 m.
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/dragon_stone.gdshader")
	if src != null:
		sm.set_shader_parameter("albedo_tex", src.albedo_texture)
		sm.set_shader_parameter("roughness_tex", src.roughness_texture)
	return sm


func _dragon_material() -> StandardMaterial3D:
	# The GLB's stone texture is a near-white marble with dark crevices; at map
	# distance the pale parts win and the flock reads as paper cut-outs.  A flat
	# slate albedo keeps the silhouette and loses the glare.
	if _dragon_mat != null:
		return _dragon_mat
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.30, 0.28, 0.26)
	m.roughness = 0.88
	# a back-lit edge separates the flock from the sky; without it a dark
	# silhouette against a bright sky reads as a hole
	m.rim_enabled = true
	m.rim = 0.55
	m.rim_tint = 0.65
	m.metallic = 0.0
	m.cull_mode = BaseMaterial3D.CULL_BACK
	_dragon_mat = m
	return m


func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t
			+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


func _loop_point(pts: Array, u: float) -> Vector3:
	# closed Catmull-Rom through the waypoints: continuous position and
	# direction, so the dragons bank smoothly instead of snapping at corners
	var n := pts.size()
	var uu := fposmod(u, float(n))
	var i := int(floor(uu))
	var t := uu - float(i)
	var p0: Vector3 = pts[(i - 1 + n) % n]
	var p1: Vector3 = pts[i % n]
	var p2: Vector3 = pts[(i + 1) % n]
	var p3: Vector3 = pts[(i + 2) % n]
	return _catmull(p0, p1, p2, p3, t)


func _build_mist() -> void:
	var m := Node3D.new()
	m.name = "MistVolumes"
	m.set_script(load("res://scripts/mist_volumes.gd"))
	add_child(m)

func _build_dragons() -> void:
	# Seven rigged stone dragons on closed flight loops between islands.  Each
	# loop climbs from just above the tree line to well above the archipelago
	# and comes back down, so the flock reads as traffic through the islands
	# rather than a row of kites parked over them.
	# Three distinct silhouettes, seven instances.  All three share the same
	# 36-joint skeleton and the same five clips, so the flight layers and the
	# bird-brain look-at code work on every variant.
	var variant_paths := [
		"res://assets/models/dragon_stone_flap.glb",
	]
	# Restore the detailed stone dragon for the whole flock.  The previous
	# three low-poly silhouettes are kept on disk for reference but are no
	# longer used by the map.
	var variant_of := [0, 0, 0, 0, 0, 0, 0]
	var variant_scale := [0.97, 1.00, 0.96, 1.02, 1.00, 0.95, 1.02]
	var islands: Array = _layout.get("islands", [])
	islands.sort_custom(func(a, b): return int(a["cells"]) > int(b["cells"]))
	# the biggest islands are the only waypoints: a loop through three of them
	# crosses open air, which is the point
	var anchors: Array = []
	for i in range(mini(12, islands.size())):
		var c = islands[i]["center"]
		anchors.append(Vector3(float(c[0]), 0.0, -float(c[1])))
	if anchors.size() < 3:
		return

	var want := 7
	var placed := 0
	for i in range(want):
		var seed := absi(hash(i * 97 + 13))
		var n := 3 + seed % 2                       # 3 or 4 legs
		var start_i := seed % anchors.size()
		var step := 2 + (seed / 3) % 3
		# Most of the circuit runs above the islands so the flock is seen
		# against the sky, with one dip down to canopy height - that low point
		# is the pass that comes at you out of nowhere.
		var lo := 13.0 + float((seed / 7) % 5)       # 13-17 m
		var hi := 30.0 + float((seed / 11) % 9)      # 30-38 m
		var pts: Array = []
		for k in range(n):
			var a: Vector3 = anchors[(start_i + k * step) % anchors.size()]
			var t := float(k) / float(n)
			# low -> high -> low, so the loop closes without a teleport
			var alt := lo + (hi - lo) * (0.5 - 0.5 * cos(TAU * t))
			# shove each waypoint off the island centre so the legs cross water
			var jx := float((seed / (k + 2)) % 200 - 100) * 0.14
			var jz := float((seed / (k + 5)) % 200 - 100) * 0.14
			pts.append(Vector3(a.x + jx, alt, a.z + jz))

		var pivot := Node3D.new()
		pivot.name = "Dragon%d" % i
		pivot.position = _loop_point(pts, 0.0)
		add_child(pivot)

		var vi: int = variant_of[i]
		var packed := load(variant_paths[vi]) as PackedScene
		if packed == null:
			push_error("dragon variant missing: " + variant_paths[vi])
			continue
		var d := packed.instantiate() as Node3D
		# 5-7 m wingspan: a flock animal, not a landmark.  The elder is
		# deliberately the largest and broadest silhouette.
		# Detailed model is ~11.8 m nose-to-tail and ~9.3 m wingspan at scale
		# 1.  The map wants a 5-7 m wingspan, so use 0.58-0.70 here rather
		# than the old low-poly 0.82.
		var scl: float = (0.96 + float((seed / 17) % 24) / 100.0) * 0.60 * variant_scale[i]
		d.scale = Vector3(scl, scl, scl)
		# The detailed source faces +X; map flight/look-at assumes local +Z.
		d.rotation.y = -PI / 2.0
		# head up, tail hanging: the hovering pose from the reference art
		# climbing attitude: nose up, but not the near-vertical hover stall
		# pitch now lives on the pivot: with Euler YXZ that composes
		# yaw -> bank -> pitch like an aircraft, instead of a fixed tilt
		d.rotation.z = 0.0
		pivot.add_child(d)
		# Keep the detailed dragon's authored texture, but apply the
		# stone-value shader (countershaded body, deeper membrane, dark wing
		# leading edge).  This only changes colour; geometry and Flap are
		# untouched.
		for mi0 in d.find_children("*", "MeshInstance3D", true, false):
			var dmi := mi0 as MeshInstance3D
			if dmi.mesh == null:
				continue
			for si in dmi.mesh.get_surface_count():
				var src_mat := dmi.get_active_material(si) as StandardMaterial3D
				if src_mat != null:
					dmi.set_surface_override_material(si, _dragon_shader_material(src_mat))

		var ap: AnimationPlayer = null
		for node in d.find_children("*", "AnimationPlayer", true, false):
			ap = node as AnimationPlayer
			break
		if ap == null:
			push_warning("dragon has no AnimationPlayer")
		else:
			# Measured wingspan across each cycle: Hover holds the wings spread
			# on 16 of 24 frames (min span 3.9 of a max 8.4), Fly folds them on
			# two thirds of frames (min 2.8 of 7.9).  Fly is the better cycle on
			# paper and the worse one on screen.
			var anim_name := "Flap"
			if not ap.has_animation(anim_name):
				anim_name = "Hover"
			if not ap.has_animation(anim_name):
				anim_name = "Fly"
			if not ap.has_animation(anim_name):
				var names := ap.get_animation_list()
				if names.size() == 0:
					push_warning("dragon has no animations")
				else:
					anim_name = names[0]
			var anim := ap.get_animation(anim_name)
			if anim != null:
				anim.loop_mode = Animation.LOOP_LINEAR
			ap.play(anim_name)
			# One wingbeat every 2.1-2.5 s at cruise.  Derive this from the clip
			# length instead of a random multiplier, so a corrected wing clip
			# gets the intended beat without another tuning pass.
			var beat_cycle := 2.3
			ap.speed_scale = anim.length / beat_cycle if anim != null and anim.length > 0.0 else 1.0
			# desync the wingbeats so the flock does not beat in lockstep
			ap.seek(float(seed % 100) / 100.0
					* maxf(0.1, anim.length if anim != null else 1.0), true)
			if i == 0:
				print("dragon rig: player=%s anims=%s clip=%s len=%.2fs playing=%s"
						% [ap.name, ap.get_animation_list(), anim_name,
						anim.length if anim != null else -1.0, ap.is_playing()])

		var skel: Skeleton3D = null
		for node in d.find_children("*", "Skeleton3D", true, false):
			skel = node as Skeleton3D
			break
		var rig: SkeletonModifier3D = null
		if skel != null:
			rig = SkeletonModifier3D.new()
			rig.set_script(load("res://scripts/dragon_rig.gd"))
			rig.name = "FlightLayers"
			skel.add_child(rig)
			rig.set("tail_amp_deg", 7.0 + float((seed / 13) % 30) / 2.0)
			rig.set("tail_speed", 0.32 + float((seed / 19) % 28) / 100.0)
			rig.set("look_weight", 0.72 + float((seed / 23) % 26) / 100.0)

		# dumped so the offline renders can place the flock exactly where the
		# engine will: the paths come from Godot's hash, not from Python
		print("DPATH %d %s %.4f" % [i, var_to_str(pts), 0.030 + float((seed / 29) % 20) / 1000.0])
		_dragons.append({
			"pivot": pivot,
			"pts": pts,
			"phase": float(seed % 100) / 100.0 * float(n),
			# one loop per 60-110 s: a 200 m path at 2-3 m/s
			"speed": 0.030 + float((seed / 29) % 20) / 1000.0,
			"idx": i,
			"rig": rig,
			"ap": ap,
			"base_speed": ap.speed_scale if ap != null else 1.0,
			"mode": 0,
			"mode_t": 1.5 + float(i) * 1.3,
			"climb_w": 0.0,
			"circ_w": 0.0,
			"bank": 0.0,
			"pitch": deg_to_rad(12.0),
			"last_yaw": 0.0,
			"u": float(seed % 100) / 100.0 * float(n),
			"speed_mult": 1.0,
			"vel": Vector3(1.0, 0.0, 0.0),
			"last_pos": _loop_point(pts, float(seed % 100) / 100.0 * float(n)),
			"yaw": 0.0,
			"gaze": i % 2 == 0,
			"gaze_t": 2.0 + float(i) * 0.9,
		})
		placed += 1
	print("dragons placed: ", placed, " flying between islands")


func _process(delta: float) -> void:
	# Water fresnel uses CAMERA_POSITION_WORLD directly; no CPU camera upload.
	if _dragons.is_empty():
		return
	_dragon_time += delta
	for e in _dragons:
		var idx: int = e["idx"]
		var pts: Array = e["pts"]
		var n := float(pts.size())

		# behaviour: cruise, weave/circle, or burst upward from below the islands
		e["mode_t"] = float(e["mode_t"]) - delta
		if float(e["mode_t"]) <= 0.0:
			var r := fposmod(_dragon_time * 0.31 + float(idx) * 0.618, 1.0)
			if r < 0.52:
				e["mode"] = 0
			elif r < 0.84:
				e["mode"] = 1
			else:
				e["mode"] = 2
			e["mode_t"] = 3.5 + fposmod(_dragon_time * 0.9 + float(idx) * 1.7, 7.0)
		var mode: int = e["mode"]
		# slower ramps than before: a 40 tonne animal does not teleport to top
		# speed. climb weight 0.45/s and speed 0.5/s give roughly 2 s of build-up.
		var cw := move_toward(float(e["climb_w"]), 1.0 if mode == 2 else 0.0, delta * 0.45)
		var ow := move_toward(float(e["circ_w"]), 1.0 if mode == 1 else 0.0, delta * 0.5)
		e["climb_w"] = cw
		e["circ_w"] = ow

		# integrate the path parameter instead of computing it from elapsed time,
		# so a change of speed changes acceleration rather than position
		var speed_t := 1.0
		if mode == 2:
			speed_t = 1.45
		elif mode == 1:
			speed_t = 0.62
		e["speed_mult"] = move_toward(float(e["speed_mult"]), speed_t, delta * 0.5)
		var sm := float(e["speed_mult"])
		e["u"] = fposmod(float(e["u"]) + delta * float(e["speed"]) * sm, n)
		var u: float = float(e["u"])

		var pos := _loop_point(pts, u)
		var ahead := _loop_point(pts, u + 0.05)
		var dir := ahead - pos
		dir.y = 0.0
		if dir.length_squared() < 0.000001:
			dir = Vector3(1.0, 0.0, 0.0)
		dir = dir.normalized()
		var right := Vector3(-dir.z, 0.0, dir.x)

		# both manoeuvres are offsets on top of the path, so the dragon always
		# returns to its circuit instead of accumulating drift
		pos.y += cw * 11.0
		var weave := _dragon_time * 0.45 + float(idx) * 1.7
		pos += right * (ow * 9.0 * sin(weave))
		pos.y += ow * 3.5 * cos(weave)
		pos.y += sin(_dragon_time * 0.8 + u * 2.0) * 0.25

		var p: Node3D = e["pivot"]
		p.position = pos

		# Face the ACTUAL velocity, not the spline tangent. The climb and weave
		# offsets used to move the dragon somewhere its nose was not pointing,
		# which is what read as flying backwards during a burst.
		var vel: Vector3 = (pos - Vector3(e["last_pos"])) / maxf(delta, 0.0001)
		e["last_pos"] = pos
		var v: Vector3 = Vector3(e["vel"]).lerp(vel, clampf(delta * 4.0, 0.0, 1.0))
		e["vel"] = v
		var flat := Vector3(v.x, 0.0, v.z)
		var yaw := float(e["yaw"])
		if flat.length() > 0.05:
			# The new dragons face local +Z.  atan2(x, z) makes that +Z nose
			# point along the actual velocity; the old model faced +X.
			yaw = atan2(v.x, v.z)
		var pitch := deg_to_rad(12.0) + atan2(v.y, maxf(flat.length(), 0.05))
		e["yaw"] = lerp_angle(float(e["yaw"]), yaw, clampf(delta * 5.0, 0.0, 1.0))
		e["pitch"] = lerpf(float(e["pitch"]),
				clampf(pitch, deg_to_rad(-45.0), deg_to_rad(72.0)),
				clampf(delta * 3.0, 0.0, 1.0))
		var dyaw := wrapf(float(e["yaw"]) - float(e["last_yaw"]), -PI, PI)
		e["last_yaw"] = float(e["yaw"])
		var bank_t := clampf(-(dyaw / maxf(delta, 0.0001)) * 0.22, -0.6, 0.6)
		e["bank"] = lerpf(float(e["bank"]), bank_t, clampf(delta * 2.0, 0.0, 1.0))
		# The restored detailed dragon faces local +Z.  For a +Z-forward
		# model, nose-up is -X and roll is Z; the old +X-forward mapping put
		# pitch on Z and bank on X, which rolled the dragon onto its back.
		p.rotation = Vector3(-float(e["pitch"]), float(e["yaw"]), float(e["bank"]))

		# wings: slow surge, faster in the climb, slower while weaving
		var ap = e.get("ap")
		var flap_mult := 1.0 + 1.09 * (sm - 1.0)
		if ap != null:
			var surge := sin(_dragon_time * 0.7 + float(idx) * 2.1) * 0.10
			(ap as AnimationPlayer).speed_scale = float(e["base_speed"]) \
					* clampf(flap_mult + surge, 0.90, 1.10)

		# head: watch the player most of the time, otherwise scan the islands
		var rig = e.get("rig")
		var cam := get_viewport().get_camera_3d()
		if rig != null:
			# Gaze is a state, not a constant: a creature that stares at the
			# camera forever ends up pinned against its neck limit, which looks
			# as wrong as not looking at all. Look, then look away.
			var gaze: bool = e["gaze"]
			e["gaze_t"] = float(e["gaze_t"]) - delta
			if cam != null and gaze:
				# break the gaze if holding it would need a neck-breaking turn
				var to_cam: Vector3 = (cam.global_position - p.global_position).normalized()
				if to_cam.dot(dir) < -0.15:
					gaze = false
			if float(e["gaze_t"]) <= 0.0 or (gaze == false and e["gaze"] == true):
				if float(e["gaze_t"]) <= 0.0:
					gaze = not gaze
				e["gaze"] = gaze
				e["gaze_t"] = (3.0 + fposmod(_dragon_time * 1.3 + float(idx) * 2.3, 5.0)) \
						if gaze else (5.0 + fposmod(_dragon_time * 1.1 + float(idx), 8.0))
		else:
			e["gaze"] = false

		if rig != null:
			var tgt: Vector3
			if e["gaze"]:
				if cam != null:
					tgt = cam.global_position
				else:
					tgt = p.global_position + dir * 30.0
			else:
				# scanning the islands below: a spot ahead and well under the
				# flight path, drifting sideways so it reads as searching
				var scan := _dragon_time * 0.31 + float(idx) * 2.4
				tgt = p.global_position + dir * 26.0 + Vector3(0.0, -10.0, 0.0) \
						+ right * (sin(scan) * 13.0) + Vector3(0.0, sin(scan * 0.7) * 4.0, 0.0)
			rig.set("look_target", tgt)
			rig.set("climb_pitch_deg", cw * 16.0)
			rig.set("jaw_open_deg", cw * 9.0)
			# harder beats: amplitude grows with speed, on top of the clip
			rig.set("flap_boost_deg", clampf((sm - 1.0) * 26.0, 0.0, 14.0))
			rig.set("flap_rate", (ap as AnimationPlayer).speed_scale if ap != null else 1.0)


func _build_clouds() -> void:
	# These used to sit at y = -8..-26, which is exactly the depth of the island
	# undersides, so they filled the gaps between islands and read as snow
	# banks hanging off the rock.  Push them far below and out: a distant cloud
	# sea the islands float above, which is what "nothing between them" means.
	var n := 0  # cloud props read as ice floes on the sky void; sea is disabled
	for i in range(n):
		var a := TAU * float(i) / float(n) + 0.35
		var r := 85.0 + float(i % 3) * 45.0
		var y := -72.0 - float(i % 4) * 10.0
		var scl := 9.0 + float(i % 3) * 3.0
		_spawn("clouds_clouds_background",
				Vector3(cos(a) * r, y, sin(a) * r), a, scl)
	# no near wisps: at this scale they read as snowballs hanging by the islands


func _build_camera() -> void:
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	pivot.set_script(load("res://scripts/fly_camera.gd"))
	pivot.position = Vector3(0, 46, 62)
	pivot.rotation.y = 0.0
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 70.0
	cam.near = 0.1
	cam.far = 900.0
	pivot.add_child(cam)
	add_child(pivot)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	panel.focus_mode = Control.FOCUS_NONE
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0, 0, 0, 0.55)
	st.set_corner_radius_all(6)
	st.content_margin_left = 12
	st.content_margin_right = 12
	st.content_margin_top = 8
	st.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", st)
	layer.add_child(panel)
	var label := Label.new()
	label.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
	label.add_theme_font_size_override("font_size", 14)
	label.focus_mode = Control.FOCUS_NONE
	label.text = "Flying Islands — Left click: move · Right click: attack · 1-7: weapon · Wheel: zoom · MMB/Arrows: pan · R: recentre"
	panel.add_child(label)
