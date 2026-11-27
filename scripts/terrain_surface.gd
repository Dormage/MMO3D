extends Node
class_name TerrainSurface
## Applies the zone-aware blend shader to the terrain MeshInstance3D.
##
##     var surf := TerrainSurface.new()
##     add_child(surf)
##     surf.apply(terrain)          # terrain = the "Terrain" node from map.gd
##
## The shader needs one shared texture array (4 rock families + moss) and, per
## surface, that surface's own base maps.  Everything else comes from
## assets/zones.json + assets/textures/manifest.json, so a zone or tile change is
## data, not code.  Idempotent: calling apply() again just replaces the
## overrides.

const SHADER_PATH := "res://shaders/terrain.gdshader"
const ZONES_PATH := "res://assets/zones.json"
const MANIFEST_PATH := "res://assets/textures/manifest.json"
const LAYOUT := "res://map_layout.json"

# Layer order of blend_albedo/normal/rough.  Must match ROCK_ORDER in
# tools/mat_apply_zones.py (the zone code in COLOR_0.a stores this index).
const ROCK_ORDER := ["stone_slate", "stone_sandstone", "stone_basalt", "stone_marble"]
const MOSS := "moss_carpet"
const MOSS_LAYER := 4
# Added after ROCK_ORDER + MOSS; consumed only by the shader's ground-wear
# pass.  It is not a zone code, so tools/mat_apply_zones.py stays unchanged.
const DIRT := "dirt_soil"
const DIRT_LAYER := 5
const EDGE_MASK := "res://assets/textures/terrain_edge_mask.png"
const RIM_DISTANCE := "res://assets/textures/terrain_rim_distance.png"
const PATH_ALBEDO := "res://assets/textures/terrain_path_albedo.png"
const PATH_MASK := "res://assets/textures/terrain_path_mask.png"
# The mask was generated in Godot world XZ: x/z from -82 to +82.
const EDGE_MASK_RECT := Vector4(-82.0, -82.0, 164.0, 164.0)

@export_group("Blend")
## Higher = tighter grass/rock edge. 0.5 is soft, 2.0 is crisp.
@export_range(0.05, 8.0, 0.05) var blend_sharpness: float = 1.0
## Slope mask where rock starts winning. 0.28 is the value the zone pass used.
@export_range(0.0, 0.9, 0.01) var rock_slope_threshold: float = 0.48
## Multiplier on the moss layer (0 disables it even on moss zones).
@export_range(0.0, 1.0, 0.01) var moss_amount: float = 0.35
## Global UV multiplier on top of each family's 8 m / tile_m scale.
@export_range(0.5, 3.0, 0.01) var tiling_scale: float = 1.0

@export_group("Ground detail")
## Strength of the 0.3-1.3 m procedural normal.  0 disables it.
@export_range(0.0, 2.0, 0.01) var micro_normal_strength: float = 1.0
## How much bare soil shows on steep turf, the island rim and pond banks.
@export_range(0.0, 1.0, 0.01) var soil_wear: float = 0.0
## Multiplier on the rim/pond edge-wear mask alone. 0 = no edge wear.
@export_range(0.0, 1.0, 0.01) var edge_wear: float = 0.0

var _albedo: Texture2DArray
var _rough: Texture2DArray
var _edge_mask: Texture2D
var _rim_distance: Texture2D
var _path_tex: Texture2D
var _path_mask: Texture2D
var _tiles := {}
var _files := {}
var _built := false
var _mask_built := false
var _wear_pts := PackedVector4Array()
var _island_centers := PackedVector4Array()
var _island_count := 0


func apply(terrain: Node3D) -> int:
	if terrain == null:
		push_error("TerrainSurface.apply: terrain is null")
		return 0
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_error("TerrainSurface: could not load %s" % SHADER_PATH)
		return 0
	_load_data()
	_build_wear_points()
	_build_island_centers()
	if not _built:
		_build_arrays()
	if not _mask_built:
		_build_edge_mask()
	if _rim_distance == null:
		_build_rim_distance()
	if _path_tex == null:
		_path_tex = load(PATH_ALBEDO) as Texture2D
	if _path_mask == null:
		_path_mask = load(PATH_MASK) as Texture2D
	if _albedo == null:
		push_error("TerrainSurface: texture arrays failed to build")
		return 0

	var applied := 0
	for node in terrain.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(i) as StandardMaterial3D
			if src == null:
				src = mi.get_active_material(i) as StandardMaterial3D
			var mname := src.resource_name if src != null else ""
			var is_pond := mname.contains("pond")
			var fam := DIRT if is_pond else _family_of(mname)
			if fam == "" and mname == "mat_stone":
				fam = "stone_slate"
			# `mat_grass` carries no tile-family suffix, so _family_of() cannot
			# resolve it and the surface silently fell back to its baked
			# material - flat olive speckle instead of the lush grass shader.
			# `mat_stone` always had this fallback; grass never did.
			if fam == "" and mname == "mat_grass":
				fam = "grass_lush"
			if fam == "":
				push_warning("TerrainSurface: unknown family on %s" % mname)
				continue
			var mat := ShaderMaterial.new()
			if mname == "mat_stone":
				# The baked cliff surface has the only columnar texture in the
				# project.  Keep that texture and overlay island rhythm rather
				# than replacing it with the grass terrain shader.
				mat.shader = load("res://shaders/cliff_stone.gdshader")
				# The baked mat_stone albedo is terrain_color_4.jpg, a
				# columnar atlas that is what produced metre-wide white
				# vertical stripes on every cliff.  Use the real stone tile.
				mat.set_shader_parameter("albedo_tex",
					_base_texture(null, "stone_slate", "albedo"))
				var nt := _base_texture(null, "stone_slate", "normal")
				if nt != null:
					mat.set_shader_parameter("normal_tex", nt)
				mat.set_shader_parameter("island_centers", _island_centers)
				mat.set_shader_parameter("island_count", _island_count)
				mat.set_shader_parameter("debug", 1.0 if OS.get_environment("CLIFF_DEBUG") == "1" else 0.0)
				mi.set_surface_override_material(i, mat)
				applied += 1
				continue
			# Flat village shelf: dedicated turf shader.  The shared shader's
			# stacked dry/meadow/soil passes turned the lawn into tan earth.
			if mname == "mat_grass":
				var gm := ShaderMaterial.new()
				gm.shader = load("res://shaders/terrain_grass.gdshader")
				gm.set_shader_parameter("base_albedo", _base_texture(null, "grass_lush", "albedo"))
				gm.set_shader_parameter("base_normal", _base_texture(null, "grass_lush", "normal"))
				gm.set_shader_parameter("base_rough", _base_texture(null, "grass_lush", "roughness"))
				gm.set_shader_parameter("base_uv", Vector2(_scale("grass_lush"), _scale("grass_lush")))
				gm.set_shader_parameter("base_tint", Color(0.74, 0.82, 0.66))
				gm.set_shader_parameter("path_albedo", _path_tex)
				gm.set_shader_parameter("path_mask", _path_mask)
				gm.set_shader_parameter("path_rect", EDGE_MASK_RECT)
				mi.set_surface_override_material(i, gm)
				applied += 1
				continue
			mat.shader = shader
			# mat_grass is the baked terrain atlas (terrain_color.jpg), not a
			# grass tile: its brown/ochre cells are what made the meadow read as
			# dry dirt.  mat_grass has an explicit family, so use that family's
			# real albedo/normal/rough maps instead of the baked atlas.
			var force_family := mname == "mat_grass"
			mat.set_shader_parameter("base_albedo",
				_base_texture(null if force_family else src, fam, "albedo"))
			mat.set_shader_parameter("base_normal",
				_base_texture(null if force_family else src, fam, "normal"))
			mat.set_shader_parameter("base_rough",
				_base_texture(null if force_family else src, fam, "roughness"))
			mat.set_shader_parameter("blend_albedo", _albedo)
			mat.set_shader_parameter("blend_rough", _rough)
			mat.set_shader_parameter("base_uv", Vector2(_scale(fam), _scale(fam)))
			mat.set_shader_parameter("rock_uv", _rock_scales())
			mat.set_shader_parameter("moss_uv", _scale(MOSS))
			mat.set_shader_parameter("dirt_uv", _scale(DIRT))
			mat.set_shader_parameter("edge_mask", _edge_mask)
			mat.set_shader_parameter("edge_mask_rect", EDGE_MASK_RECT)
			mat.set_shader_parameter("rim_distance", _rim_distance)
			mat.set_shader_parameter("rim_distance_rect", EDGE_MASK_RECT)
			mat.set_shader_parameter("path_albedo", _path_tex)
			mat.set_shader_parameter("path_mask", _path_mask)
			mat.set_shader_parameter("path_mask_rect", EDGE_MASK_RECT)
			mat.set_shader_parameter("base_tint",
				Color.WHITE if (is_pond or force_family) else (src.albedo_color if src != null else Color.WHITE))
			mat.set_shader_parameter("blend_sharpness", blend_sharpness)
			mat.set_shader_parameter("rock_slope_threshold", rock_slope_threshold)
			mat.set_shader_parameter("moss_amount", moss_amount)
			mat.set_shader_parameter("tiling_scale", tiling_scale)
			mat.set_shader_parameter("rock_surface",
				0.0 if is_pond else (1.0 if (mname == "mat_stone" or mname.begins_with("mat_rock_")) else 0.0))
			mat.set_shader_parameter("is_grass",
				0.0 if is_pond else (1.0 if fam.begins_with("grass") else 0.0))
			mat.set_shader_parameter("grass_dryness",
				_dryness(fam))
			mat.set_shader_parameter("micro_strength", micro_normal_strength)
			# Test hook only: MID_STRENGTH=0 renders the pre-mid-scale baseline
			# with the same camera/ROI.  Production default is 1.
			mat.set_shader_parameter("mid_strength",
				0.0 if OS.get_environment("MID_STRENGTH") == "0" else 1.0)
			mat.set_shader_parameter("soil_strength", soil_wear)
			mat.set_shader_parameter("edge_strength", edge_wear)
			mat.set_shader_parameter("force_pond_earth", 1.0 if is_pond else 0.0)
			mat.set_shader_parameter("island_centers", _island_centers)
			mat.set_shader_parameter("island_count", _island_count)
			mat.set_shader_parameter("debug_island_type",
				1.0 if OS.get_environment("CLIFF_DEBUG") == "1" else 0.0)
			if is_pond:
				# The baked pond/shore surface is a flat ground plane.  A simple
				# procedural earth shader guarantees it cannot fall back to the
				# old grey material when the full blend compiles differently.
				var gm := ShaderMaterial.new()
				gm.shader = load("res://shaders/ground_earth.gdshader")
				mi.set_surface_override_material(i, gm)
			else:
				mi.set_surface_override_material(i, mat)
			applied += 1
	print("terrain surface: %d surfaces, rock layers %s, moss layer %d"
		% [applied, str(ROCK_ORDER), MOSS_LAYER])
	return applied


## One XZ centre per island, padded to the shader's fixed array size.  The
## fragment shader picks the nearest centre; this is what gives each rim its
## own cliff type and rhythm without splitting the terrain mesh.
func _build_island_centers() -> void:
	if not _island_centers.is_empty():
		return
	var txt := FileAccess.get_file_as_string(LAYOUT)
	var m: Dictionary = JSON.parse_string(txt) if txt != "" else {}
	var islands: Array = m.get("islands", [])
	_island_count = islands.size()
	for isl in islands:
		# map_layout stores cell coordinates; the terrain/world uses the same
		# 81.5-cell, 1.6979 m transform as IslandDetail.  Bbox centre matches the
		# mesh better than the cell centroid on the irregular islands.
		var b: Array = isl.get("bbox", [0.0, 0.0, 0.0, 0.0])
		var cx := (float(b[0]) + float(b[2])) * 0.5
		var cz := (float(b[1]) + float(b[3])) * 0.5
		_island_centers.append(Vector4((cx - 81.5) * 1.6979,
			-(cz - 81.5) * 1.6979, 0.0, 0.0))
	while _island_centers.size() < 24:
		_island_centers.append(Vector4(99999.0, 99999.0, 0.0, 0.0))

func _build_wear_points() -> void:
	if not _wear_pts.is_empty():
		return
	var txt := FileAccess.get_file_as_string(LAYOUT)
	var m: Dictionary = JSON.parse_string(txt) if txt != "" else {}
	if m.is_empty():
		return
	# Gate first: the strongest node, then village houses, then bridge decks.
	for b in m.get("buildings", []):
		if String(b.get("id", "")) == "village_gate":
			_wear_pts.append(Vector4(float(b["x"]), float(b["z"]), 3.2, 0.50))
	for b in m.get("buildings", []):
		var bid := String(b.get("id", ""))
		if bid.contains("village") and bid != "village_gate":
			_wear_pts.append(Vector4(float(b["x"]), float(b["z"]), 2.0, 0.22))
	for b in m.get("bridges", []):
		_wear_pts.append(Vector4(float(b["x"]), float(b["z"]), 1.8, 0.30))
		if _wear_pts.size() >= 16:
			break
	_wear_pts.resize(mini(_wear_pts.size(), 16))


func _load_data() -> void:
	if not _tiles.is_empty():
		return
	var mf: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	for e in mf.get("entries", []):
		_tiles[e["name"]] = float(e["tile_m"])
		_files[e["name"]] = e.get("files", {})


func _scale(fam: String) -> float:
	# the mesh UV is an 8 m cube projection
	return 8.0 / float(_tiles.get(fam, 2.5))


func _rock_scales() -> Vector4:
	var out := Vector4.ZERO
	for i in ROCK_ORDER.size():
		out[i] = _scale(ROCK_ORDER[i])
	return out


func _family_of(mname: String) -> String:
	if mname == "":
		return ""
	var best := ""
	for fam in _tiles.keys():
		if mname.ends_with(fam) and String(fam).length() > best.length():
			best = fam
	return best


func _dryness(fam: String) -> float:
	if fam == "grass_dry":
		return 1.0
	if fam == "grass_meadow":
		return 0.35
	if fam == "grass_lush":
		return 0.0
	return 0.0


func _base_texture(src: StandardMaterial3D, fam: String, kind: String) -> Texture2D:
	if src != null:
		if kind == "albedo" and src.albedo_texture != null:
			return src.albedo_texture
		if kind == "normal" and src.normal_texture != null:
			return src.normal_texture
		if kind == "roughness" and src.roughness_texture != null:
			return src.roughness_texture
	return load("res://" + String(_files.get(fam, {}).get(kind, "")))


func _build_arrays() -> void:
	_built = true
	var fams: Array = ROCK_ORDER.duplicate()
	fams.append(MOSS)
	fams.append(DIRT)
	var albedo_images: Array[Image] = []
	var rough_images: Array[Image] = []
	for fam in fams:
		albedo_images.append(_image(fam, "albedo"))
		rough_images.append(_image(fam, "roughness"))
	_albedo = _make_array(albedo_images)
	_rough = _make_array(rough_images)


func _build_edge_mask() -> void:
	_mask_built = true
	# Load the PNG directly: it is a runtime control map, not a sampled art
	# texture, and loading the source keeps this working without an .import.
	var img := Image.new()
	var err := img.load(EDGE_MASK)
	if err != OK or img.is_empty():
		push_warning("TerrainSurface: %s missing; edge wear disabled" % EDGE_MASK)
		img = Image.create(1, 1, false, Image.FORMAT_RGB8)
		img.fill(Color(0.0, 0.0, 0.0))
	else:
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGB8)
	_edge_mask = ImageTexture.create_from_image(img)


func _build_rim_distance() -> void:
	var img := Image.new()
	var err := img.load(RIM_DISTANCE)
	if err != OK or img.is_empty():
		# Neutral fallback: 2 m everywhere means the band is coherent but flat.
		img = Image.create(512, 512, false, Image.FORMAT_L8)
		img.fill(Color(0.5, 0.5, 0.5))
	elif img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_L8:
		img.convert(Image.FORMAT_L8)
	img.generate_mipmaps()
	_rim_distance = ImageTexture.create_from_image(img)


func _image(fam: String, kind: String) -> Image:
	var tex := load("res://" + String(_files.get(fam, {}).get(kind, ""))) as Texture2D
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGB8)
	if img.get_width() != 896:
		img.resize(896, 896, Image.INTERPOLATE_LANCZOS)
	img.generate_mipmaps()
	return img


func _make_array(images: Array[Image]) -> Texture2DArray:
	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	return arr
