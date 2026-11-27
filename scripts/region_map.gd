@tool
extends Node3D
## Generic region loader.
##
## One node per region, configured in the inspector, so adding region 3..9 is
## data rather than code.  It loads one GLB, assigns collision by mesh role,
## finds a clear spawn, and exposes the small API the rest of the game expects
## from the Map node: spawn_point() and nav_layout_path().
##
## Collision roles
##   ground_meshes      collision layer 1 (the walkable surface)
##   solid_meshes       collision layer 2 (walls, props, ramparts)
##   everything else    no collision (vegetation, water, smoke)
##
## Vegetation is non-solid on purpose: it is dense enough that solid bushes and
## grass would fence the player into every verge and planter.

## Region identity, used by the registry and by teleports.
@export var region_id := ""
@export var display_name := ""

@export_file("*.glb") var glb_path := ""
## Extra GLB layers merged into the same region (a town split into terrain,
## architecture and flora by the artist).  They are attached as children of
## RegionWorld before classification, so collision, navmesh and the HUD treat
## the whole stack as one map.
@export var extra_glb_paths: PackedStringArray = PackedStringArray()

@export_group("Collision roles")
@export var ground_meshes: PackedStringArray = PackedStringArray(["SM_Town_Ground"])
@export var solid_meshes: PackedStringArray = PackedStringArray(
		["SM_Town_Buildings", "SM_Town_Props", "SM_Town_Rampart"])
@export var mesh_prefix := "SM_Town_"
## Meshes whose NAME matches one of these are decoration (no collision).
## The name lists (ground_meshes/solid_meshes) only work for maps that merge
## their geometry into a few big meshes; an asset split into 200 objects needs
## the inverse rule instead.
@export var decor_meshes: PackedStringArray = PackedStringArray()
## When true, every mesh that is neither ground nor decoration becomes solid.
@export var default_meshes_solid := false

@export_group("Rendering")
## Repair passes replace imported meshes, discarding their automatic LODs.
## Restore alternative render indices once, before caching the region.
@export var generate_render_lods := true

@export_group("Collision roles by material")
## Materials matching these substrings get NO collision.  Decorative props --
## flowers, grass tufts, reeds, ground cover -- must not fence the player in.
@export var decor_patterns: PackedStringArray = PackedStringArray([
		"flower", "petal", "cream", "foliage", "bloom", "grass_blade",
		"reed", "cattail", "fern", "lily", "mushcap", "bush"])
## Checked before anything else.  Substring matching is blunt -- "ramp" would
## otherwise match M_Rampart and make an entire curtain wall walkable -- so
## structural materials are pinned solid regardless of height.
@export var force_solid_patterns: PackedStringArray = PackedStringArray([
		"palisade", "roof", "wall", "fence", "gate", "door", "window", "tower",
		"timber", "rampart", "railing"])
## Materials matching these become walkable ground (layer 1) and are added to
## the navmesh bake, so the player can walk and route across them.  Keep these
## long and specific: a short pattern like "ramp" matches M_Rampart.
@export var walkable_patterns: PackedStringArray = PackedStringArray([
		"bridge_plank", "stair", "step", "prop_stone.003", "prop_stone_dark.003"])
## The height rule only applies to these materials.  Without this restriction
## sacks, lanterns and roof caps also qualified and became walkable surfaces.
@export var low_walkable_materials: PackedStringArray = PackedStringArray([
		"stone", "plank", "brick", "kerb", "slab", "paving", "step"])
## A solid primitive of those materials shorter than this is a step, not a wall.
## The player's step-up reaches 0.45 m, so this has to stay above that.
@export var low_walkable_height := 0.85

@export_group("Water")
## How far past the authored water sheet the flood plane reaches, in metres.
## The plane passes through the terrain; ground above the waterline hides it and
## ground below shows it, so the visible river is the whole real channel.
@export var water_apron_width := 30.0
## How far apart two navmesh pieces may be and still be stitched at runtime.
## Wide gaps let a path jump a stream, so maps opt in individually.
## Optional standalone navmesh GLB whose NAV_* meshes ARE the walkable surface,
## so pathing can be authored in a modelling tool instead of inferred.
## Remove prop collision that lies on bridge decks.  Opt-in: with the wide mask
## it also softens scenery near bridges, so it stays off until it is narrowed.
## Remove prop collision that lies on bridge decks (narrow mask, island only).
@export var strip_props_on_decks := false
## Skip building collision for decorative prop meshes.  Cheapest physics win
## available: these are trimeshes the player only ever bumps into.
@export var skip_prop_collision := false
## Collision is split into tiles of this size (metres).  0 disables chunking.
@export var collision_tile := 32.0
## Ground collision as a heightfield instead of a concave trimesh.  A trimesh
## makes the capsule resolve contacts against thousands of triangles per tick;
## a heightmap answers the same question with a grid lookup (measured: 20ms -> 2ms).
@export var use_heightmap_ground := false
@export var heightmap_step := 1.0
var _prop_bodies_skipped := 0
@export var nav_glb_path := ""
@export var nav_stitch_gap := 1.3
@export var nav_stitch_rise := 0.9
@export var water_patterns: PackedStringArray = PackedStringArray(["water"])
@export var water_color := Color(0.10, 0.52, 0.58)
## Replace the authored water sheet with one large plane, scaled about the
## sheet's centre.  The island closes its river with the apron below, but the
## graveyard ships water as its own SM_Water mesh with no ground sheet to apron,
## so the lake simply ends in mid-air.  2.0 doubles each side; keep it modest or
## the plane floods every hollow inside the rectangle.
## Surfaces to remove outright, matched against the material name.  The v2
## graveyard keeps the source's leftover grass platforms, which read as green
## belts lying on top of the roads.
## Loose prop fragments left hanging in the air by the export.  The graveyard
## ships 22k bone shard islands, many floating metres above the ground.
@export var snap_fragments := false
@export var snap_material_patterns := PackedStringArray(["bone"])
@export var snap_material_exclude := PackedStringArray(["barkbone"])
@export var snap_meshes := PackedStringArray(["SM_Vegetation", "SM_Props"])
## Islands larger than this are architecture, not debris; never move them.
@export var snap_max_size := 4.0
@export var snap_min_height := 0.25
@export var snap_ground_cell := 1.0

## Whole meshes to remove, matched by node name.  The wetlands package ships an
## SM_ScaleReference proxy standing at the origin that must not be in game.
## Whole meshes whose every surface is walkable.  The wetlands bridges are one
## merged mesh with a single material, so material-pattern classification cannot
## tell deck from rail and the whole thing came out solid.
@export var walkable_meshes := PackedStringArray()

## Build a collision wall around each water body so it cannot be walked over.
@export var water_wall_enabled := false
@export var water_wall_height := 1.15

## Drop triangles larger than this many metres from the named meshes.  The
## wetlands export contains ~13k fronds 4-5 m across whose vertex colour is near
## black, so they read as flat black slabs lying across the river.  0 disables.
@export var max_face_edge := 0.0
@export var max_face_meshes := PackedStringArray()

@export var hide_meshes := PackedStringArray()

@export var hide_material_patterns := PackedStringArray()

## Emissive lift for the water surface.  Zero keeps the island's normal water;
## the graveyard uses this for poison-green water that still reflects.
@export var water_glow_color := Color(0.16, 1.0, 0.34)
@export var water_glow_strength := 0.0
## Sporadic bubble domes on the water surface.  Zero disables them.
@export var water_bubble_strength := 0.0
@export var water_bubble_scale := 3.2
@export var water_bubble_density := 0.16
@export var water_bubble_speed := 0.30

## Apply the runtime water shader to existing water surfaces in place, without
## the flood plane.  Used by fountains, where there is nothing to extend and a
## global plane would submerge the plaza.

## Exact material names given the flowing-jet shader (vertical water: fountain
## streams and spill sheets).  Matched exactly, because a "water" pattern would
## also catch the flat pool surfaces and turn them to glass.

## Fill a modelled basin with a generated water disc.  The desert fountain ships
## no pool surface -- its octagon is ceramic tiles -- so the basin reads as dry
## until something is put in it.
## Surfaces whose horizontal extent defines the basin.
## Surfaces whose centre becomes the pool centre (the fountain's own basin, so
## the disc lands on the plinth rather than the middle of the map).
## Only meshes with these names are searched for the centre, so a second fountain
## in another mesh does not pull the average between the two.
## Explicit radius.  Deriving it from material extents is unreliable: one shared
## material can span every building in the town.
## Fraction of the measured radius actually covered, so the rim stays visible.

@export var water_extend_enabled := false
@export var water_extend_scale := 2.0
@export var water_extend_cells := 64
@export_range(0.0, 2.0, 0.01) var water_emission := 0.35
## Waterfall sheets are vertical and must not get a horizontal apron.
@export var water_exclude_patterns: PackedStringArray = PackedStringArray(["waterfall"])

@export_group("Ground detail")
## Optional tiling texture multiplied over the ground's vertex colours.  Vertex
## colours carry one albedo per face, so a mixed grass/path/dirt surface
## collapses to a single tone; a triplanar detail map puts the variation back.
@export_file("*.png", "*.jpg") var ground_detail_texture := ""
@export var ground_detail_scale := 0.14

@export_group("Spawn")
## Ground/building layers.  player_controller snaps with mask 3, so both.
## Materials whose name matches any of these get the wind shader.  Bark, stone
## and timber are deliberately absent: trunks should not sway.
@export var wind_patterns := PackedStringArray([
	"foliage", "bush", "leaf", "bloom", "flower", "grass", "reed",
	"cattail", "fern", "canopy", "ivy", "vine", "petal",
	# The town ships its whole flora as one mesh called M_Vegetation.
	"vegetation", "tree",
	# Pines matched none of the above, so they neither swayed nor picked up a
	# texture; M_pine_needles is the only conifer material in the package.
	"pine", "needle"])
## Patterns that must never sway even if they match wind_patterns.  Moss is a
## ground and roof cover, not foliage -- the island has M_roof_moss_slate and
## M_prop_moss, and both would otherwise drift.
@export var wind_exclude_patterns := PackedStringArray([
	"moss", "bark", "roof", "stone", "wall", "timber", "plank", "log"])
## Matches that sway hard and fast rather than slowly like a tree canopy.
@export var wind_grass_patterns := PackedStringArray([
	"grass", "reed", "cattail", "fern", "flower"])
## Carve solid geometry out of the navmesh.  On for the island, where each prop
## and wall carries its own material and the carve is precise.  Off by default
## for maps whose solid meshes span the entire layout (see nav_world.gd).
## Material-name -> texture-file overrides, applied after load.
##
## The authored package ships several wood materials textured with stone:
## M_palisade_log, M_barrel_wood and the stump faces all point at tile_stone, so
## logs render with a brick pattern on the bark.  Remapping here keeps the GLB
## untouched and stays editable.
@export var material_texture_overrides := {
	"m_palisade_log": "bark_tile.png",
	"m_palisade_log_dark": "bark_tile.png",
	"m_palisade_log.007": "bark_tile.png",
	"m_barrel_wood": "tile_wood.png",
	"m_stump_ring": "tile_wood.png",
	"m_stump_cut.001": "tile_wood.png",
	"m_stump_char.001": "bark_tile.png",
	# tile_stone is the BRICK tile.  Every rough rock in the package was pointed
	# at it, so boulders, the henge and the ruins all rendered as laid masonry.
	# rock_granite is the plain stone texture.  Worked building masonry
	# (M_house_stone) is deliberately left on tile_stone -- brick is correct there.
	"m_altar_stone": "rock_granite.png",
	"m_altar_stone_dark": "rock_granite.png",
	"m_prop_stone": "rock_granite.png",
	"m_prop_stone_dark": "rock_granite.png",
	"m_prop_stone.003": "rock_granite.png",
	"m_prop_stone_dark.003": "rock_granite.png",
	"m_prop_stone.007": "rock_granite.png",
	"m_ruin_stone": "rock_granite.png",
	"m_ruin_stone_dark": "rock_granite.png",
	# Pines shipped with no albedo at all (vertex colour only).  A generated
	# needle striation texture gives the cones some structure when multiplied by
	# that green.
	"m_pine_needles": "pine_needles.png",
	# M_prop_cut is the fallen cut logs: ~0.8 m diameter pieces scattered across
	# the map.  It carried the brick tile, so every log barrel read as masonry.
	"m_prop_cut": "bark_tile.png",
	"m_prop_char.007": "bark_tile.png",
	# Broken stone, not masonry.
	"m_rubble": "rock_granite.png",
}
## Where those textures live, relative to res://.
@export var material_texture_dir := "res://assets/worlds/island/textures/"

## Drop fence pieces that run through stone.  The authored layout pushes its
## post-and-rail runs straight through the raised rock ridge, so the rails
## visibly pass inside the wall.  Cutting the offending pieces leaves the fence
## ending at the wall instead of spearing it.
## Individual plants to relocate: [{center: Vector3, offset: Vector3, radius: float}].
## Applied in the vegetation shader so the merged mesh is never rebuilt.
@export var vegetation_moves := [
	# Pine beside the north end of the northwest bridge, under the ruins.
	# The deck occupies x -37.7..-32.3, so shifting east clears the approach.
	{"center": Vector3(-30.8, 0.0, -15.8), "offset": Vector3(7.0, 0.0, 0.0), "radius": 5.0},
	# Pine whose trunk sits inside the deck's X span, growing up through the
	# bridge.  Pushed further east so it clears the far side of the walkway.
	{"center": Vector3(-36.7, 0.0, -4.4), "offset": Vector3(9.0, 0.0, 0.0), "radius": 5.0},
]

## Geometry fixes for the bridges, applied before collision is built so that
## collision and the navmesh follow the visual mesh.
##
## {"mesh": mesh name, "scale": stretch along the deck's long axis,
##  "offset": world metres to shift}
##
## The decks are arch bridges built from individual planks, so there is no way to
## extend one without stretching it -- but collision is regenerated from the moved
## geometry, which a shader transform could not do.
## Materials that should glow instead of carrying a stone texture.  The author
## used M_rune_glow for the carved signs on the standing stones and M_prop_glow
## for scattered magical bits, but both shipped with the brick albedo and no
## emissive, so they read as plain stone recesses.
@export var glow_patterns := PackedStringArray(["rune", "prop_glow"])
@export var glow_exclude_patterns := PackedStringArray(["lantern"])
@export var glow_color := Color(0.42, 0.34, 1.0)
@export var glow_energy := 3.0
@export var glow_light_energy := 2.6
@export var glow_light_range := 9.0
## Cap on lights, since each one costs a shadow-less light slot.
@export var glow_max_lights := 24
## Minimum spacing between glow lights.  The author stacks several carvings within
## a couple of metres, and without this the whole light budget was spent on one
## cluster while other signs — including the standing statues — stayed dark.
@export var glow_light_min_separation := 3.0

## Vertices further than this from the origin are export corruption, not
## geometry.  The v2 graveyard ships 2,584 such vertices (worst 17.8 million m)
## scattered through M_SlateDark and the dry-grass materials; left alone they
## blow the map bounds out to 44 million metres and make the nav grid enormous.
@export var outlier_limit := 1000.0
## Triangles longer than this in the sliver-prone meshes are export junk, not
## grass.  The v2 graveyard ships 375 dry-grass and 224 dry-grass-pale triangles
## with edges up to 326 m: they read as golden wheat streaks fanning out across
## the whole map.  Real prop triangles top out near 12-20 m, so this is safe.
@export var sliver_max_edge := 5.0
@export var sliver_meshes := PackedStringArray(["SM_Vegetation", "SM_Props"])

@export var bridge_rules := [
	{"mesh": "SM_Town_Props", "scale": 1.16, "offset": Vector3(0.0, 0.0, 0.0)},
	{"mesh": "SM_Town_Rampart", "scale": 1.0, "offset": Vector3(0.0, 0.0, 6.0)},
]
@export var bridge_patterns := PackedStringArray(["bridge_plank", "bridge_rail"])

@export var shorten_fences_at_stone := true
## How close a fence vertex must be to stone to count as intersecting, in metres.
@export var fence_stone_clearance := 0.22
## Material names treated as fencing for that purpose.  M_bridge_rail is
## deliberately excluded: bridge rails are supposed to meet masonry.
@export var fence_patterns := PackedStringArray(["palisade"])
## Material names treated as stone for the overlap test.
@export var stone_patterns := PackedStringArray([
	"prop_stone", "ruin_stone", "altar_stone", "rubble", "stone_soft", "rock_"])

@export var nav_carve_solids := true
@export var wind_enabled := true
@export var wind_sway_strength := 0.075
@export var wind_grass_sway_strength := 0.16
@export var wind_sway_speed := 1.10
@export var wind_grass_sway_speed := 2.30

@export var layer_ground := 1
@export var layer_solid := 2
## Search centre; the spawner spirals outward from here for clear ground.
@export var spawn_center := Vector2.ZERO
## How far the spiral may reach, in metres.
@export var spawn_search_radius := 50.0

var spawn_xz := Vector2.ZERO
const WATER_CACHE_META := "_mmo3d_water_state"
const WATER_CACHE_VERSION := 1
var _water_level := 0.0
var _has_water := false
var _water_cells := PackedByteArray()
var _ground: MeshInstance3D
## Every mesh named in ground_meshes; all of them become walkable collision.
var _grounds: Array[MeshInstance3D] = []
var _solids: Array[MeshInstance3D] = []
var _others: Array[MeshInstance3D] = []
var _load_perf_enabled := false


func _load_stamp() -> int:
	return Time.get_ticks_usec() if _load_perf_enabled else 0


func _load_phase(phase: String, started: int) -> int:
	var now := _load_stamp()
	if _load_perf_enabled:
		print("LOAD_PHASE region=%s phase=%s ms=%.3f" % [
			region_id, phase, float(now - started) / 1000.0])
	return now


func _ready() -> void:
	if Engine.is_editor_hint():
		_build_editor_preview()
		return
	_load_perf_enabled = OS.get_environment("PERF_LOG") == "1"
	var started := _load_stamp()
	var phase := started
	_build_environment()
	_apply_region_exposure()
	phase = _load_phase("region.environment", phase)
	_load_region()
	phase = _load_phase("region.load_total", phase)
	_build_collision()
	phase = _load_phase("region.collision_total", phase)
	_apply_ground_detail()
	phase = _load_phase("region.ground_detail", phase)
	# Collision reaches the physics server a frame or two after the bodies are
	# added, so probing the ground immediately would miss every ray.
	for _i in 3:
		await get_tree().physics_frame
	phase = _load_phase("region.physics_wait", phase)
	# After the rays work: the apron measures how far the bank is from each
	# water edge, and that measurement is a ground raycast.
	_build_water_apron()
	phase = _load_phase("region.water_apron", phase)
	_find_spawn()
	phase = _load_phase("region.spawn", phase)
	_build_hud()
	_report()
	_load_phase("region.hud_report", phase)
	_load_phase("region.ready_total", started)


func _terrain_y(x: float, z: float) -> float:
	var h := _ground_height(x, z)
	return 0.0 if is_nan(h) else h


## Regions ship no obstacle layout; the nav baker carves from what it can see.
func nav_layout_path() -> String:
	return ""


func spawn_point() -> Vector3:
	var y := _ground_height(spawn_xz.x, spawn_xz.y)
	if is_nan(y):
		y = _ground_height(spawn_center.x, spawn_center.y)
	if is_nan(y):
		y = 0.0
	return Vector3(spawn_xz.x, y, spawn_xz.y)


func region_label() -> String:
	return display_name if not display_name.is_empty() else region_id


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HudLayer"
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	panel.focus_mode = Control.FOCUS_NONE
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = "%s \u2014 Left click: move \u00b7 Right click: attack \u00b7 1-7: weapon \u00b7 Wheel: zoom \u00b7 MMB/Arrows: pan \u00b7 R: recentre \u00b7 F: free camera \u00b7 F11: fullscreen \u00b7 Tab / Shift+Tab: switch map" % region_label()
	panel.add_child(label)


## Per-region exposure correction.
##
## All maps share one sun and one Environment, but the assets were authored at
## very different brightness: measured screen luminance was 0.04 on the wetlands
## and 0.76 on the desert against 0.38 on the town.  One global exposure cannot
## suit all five, so each map carries a multiplier.
static var _base_exposure := -1.0
static var _base_ambient := -1.0

## Shadow fill per region.  A Blender render of the same asset bounces light
## around the courtyard; our single sun plus flat ambient does not, so shadowed
## stone reads far darker than the reference (measured 0.12 vs 0.22 of the
## reference's tonal floor).  Raising ambient here restores that fill without
## blowing the highlights.
const REGION_AMBIENT := {
	"ruins2": 2.60,
}

## Fraction of ambient that comes from the sky rather than a flat colour.  A
## flat ambient brightens every face equally, so it greys the stone; sky light
## keeps the directional variation the artist lit for.
const REGION_SKY_CONTRIB := {
	"ruins2": 0.75,
}

const REGION_EXPOSURE := {
	"town": 1.00,
	"island": 0.38,
	"graveyard": 0.58,
	"wetlands": 7.20,
	"desert": 0.26,
	"ruins2": 1.80,
}

func _apply_region_exposure() -> void:
	var id := ""
	var rs := get_node_or_null("/root/RegionState")
	if rs != null:
		id = String(rs.call("current_id"))
	if id.is_empty():
		return
	var scale := float(REGION_EXPOSURE.get(id, 1.0))
	var w3 := get_viewport().world_3d
	if w3 == null or w3.environment == null:
		return
	var env := w3.environment
	# Capture the authored exposure once; the Environment survives scene reloads,
	# so multiplying repeatedly would compound on every map switch.
	if _base_exposure < 0.0:
		_base_exposure = env.tonemap_exposure if env.tonemap_exposure > 0.0001 else 1.0
	env.tonemap_exposure = clampf(_base_exposure * scale, 0.05, 16.0)
	var amb := float(REGION_AMBIENT.get(id, 1.0))
	if _base_ambient < 0.0:
		_base_ambient = env.ambient_light_energy if env.ambient_light_energy > 0.0001 else 1.0
	env.ambient_light_energy = clampf(_base_ambient * amb, 0.0, 8.0)
	if REGION_SKY_CONTRIB.has(id):
		env.ambient_light_sky_contribution = float(REGION_SKY_CONTRIB[id])
	w3.environment = env
	print("REGION_EXPOSURE id=%s scale=%.2f exposure=%.2f ambient=%.2f" % [
		id, scale, env.tonemap_exposure, env.ambient_light_energy])


func _build_environment() -> void:
	# Atmosphere owns the single sun (SkySun) plus bounce fill and shadows.
	var sky_sun := get_tree().root.find_child("SkySun", true, false)
	if sky_sun != null:
		print("REGION_LIGHT using shared SkySun")
	else:
		var sun := DirectionalLight3D.new()
		sun.name = "RegionSun"
		sun.rotation = Vector3(deg_to_rad(-42), deg_to_rad(35), 0)
		sun.light_energy = 1.70
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = 300.0
		add_child(sun)


## Editor-only: instance the region so it is visible and inspectable without
## running the game.  Collision, nav and the HUD are runtime concerns.
func _build_editor_preview() -> void:
	for old in get_children():
		if String(old.name).begins_with("RegionWorld"):
			old.queue_free()
	if glb_path.is_empty():
		return
	var node := preload("res://scripts/glb_util.gd").instantiate(glb_path)
	if node == null:
		push_warning("region_map: editor preview could not load %s" % glb_path)
		return
	node.name = "RegionWorld"
	add_child(node)
	_attach_extra_layers(node)
	# The apron and water colour are runtime-built, so build them here too --
	# otherwise the editor viewport shows the same gap the game no longer has.
	for n in node.find_children("*", "MeshInstance3D", true, false):
		if String(n.name) in ground_meshes:
			_ground = n as MeshInstance3D
	if _ground != null:
		_build_water_apron()
	# Same reasoning for the vegetation shader: the leaf detail texture is
	# applied at load time, so without this the editor shows bare canopies while
	# the running game shows textured ones.
	_ensure_vertex_colour_albedo(node)
	_ensure_texture_mipmaps(node)
	_fix_material_textures(node)
	_strip_outliers(node)
	_cull_oversized_faces(node)
	_hide_meshes(node)
	_hide_materials(node)
	_snap_fragments(node)
	_measure_water(node)
	_extend_water(node)
	_build_water_wall(node)
	_add_glow_lights(node)
	_transform_bridges(node)
	_shorten_fences_at_stone(node)
	_add_crystal_glow(node)
	_apply_vegetation_wind(node)
	_apply_ground_detail()
	print("REGION_EDITOR preview for %s" % region_id)


## Directory holding baked regions.
const CACHE_DIR := "user://region_cache"


## Identifies the exact asset a cache file was baked from.
##
## Size plus mtime is enough to notice a replaced or re-exported GLB; without it
## a stale bake would silently outlive the asset it came from.
func _cache_key() -> String:
	var f := FileAccess.open(glb_path, FileAccess.READ)
	var size := f.get_length() if f != null else -1
	if f != null:
		f.close()
	# Every file that shapes the bake: the asset, the loader, and the GLB parser.
	# Missing any of them means an edit silently keeps using an older bake.
	var deps := ""
	for path in [get_script().resource_path if get_script() != null else "",
			"res://scripts/glb_util.gd", "res://scripts/region_render_lods.gd",
			"res://shaders/depth_compat.gdshaderinc"]:
		var f2 := FileAccess.open(path, FileAccess.READ)
		var sz := f2.get_length() if f2 != null else -1
		if f2 != null:
			f2.close()
		deps += "%s:%d:%d;" % [path, int(FileAccess.get_modified_time(path)), int(sz)]
	# Asset, loader script and every exported parameter all feed the key.  Keying
	# on the asset alone would let a bake outlive a change to the passes or to
	# this scene's settings, which is a silent wrong-result bug.
	return "%s|%d|%d|%s|%s|render_lods=%s" % [
		glb_path,
		int(FileAccess.get_modified_time(glb_path)), int(size),
		deps, _params_fingerprint(), str(_render_lods_enabled())]


## Hash of the exported settings that change how a map is conditioned.
func _params_fingerprint() -> String:
	var parts: Array[String] = []
	for p in get_property_list():
		# Exported settings only: every script variable would include runtime
		# state such as the ground cache, which mutates during load and would
		# make the key differ between writing the bake and checking it.
		if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		if not (p.usage & PROPERTY_USAGE_EDITOR):
			continue
		var val: Variant = get(p.name)
		parts.append("%s=%s" % [p.name, var_to_str(val)])
		# A texture path names a file whose pixels get embedded in the bake, so
		# its timestamp is part of the key as well.
		if val is String and (val as String).ends_with(".png"):
			var tf := FileAccess.open(val, FileAccess.READ)
			var tsz := tf.get_length() if tf != null else -1
			if tf != null:
				tf.close()
			parts.append("%s.mtime=%d.size=%d" % [val, int(FileAccess.get_modified_time(val)), int(tsz)])
	parts.sort()
	return "|".join(parts).sha256_text()


func _cache_paths() -> Array[String]:
	var base := "%s/%s" % [CACHE_DIR, region_id]
	if not _render_lods_enabled():
		base += "_no_render_lods"
	return [base + ".scn", base + ".key"]


func _render_lods_enabled() -> bool:
	return generate_render_lods and not OS.get_cmdline_user_args().has("--no-render-lods")


## Load the region, reusing a previous bake when the asset has not changed.
##
## The conditioning passes are edit-time work -- cleaning geometry, snapping
## fragments, trimming oversized faces -- but they used to run on every load and
## every Tab switch, which cost 10-15 s on foliage-heavy maps.  Baking the result
## once turns later loads into a scene read.
## Height of the water surface in this map, or 0 with `_has_water` false.
##
## Measured from the water materials themselves.  The project ships no
## map_layout.json, so the old water mask was always empty and the navmesh
## treated the riverbed as walkable -- paths and clicks crossed rivers.
func _measure_water(node: Node) -> void:
	_water_level = 0.0
	_has_water = false
	_water_cells = PackedByteArray()
	_water_cells.resize(163 * 163)
	_water_cells.fill(0)
	var level := {}
	var found := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var mm := mi.mesh.surface_get_material(si)
			var nm := String(mm.resource_name).to_lower() if mm != null else ""
			if nm.is_empty() or not _pattern_hit(nm, water_patterns) \
					or _pattern_hit(nm, water_exclude_patterns):
				continue
			# Hidden authored water keeps the true footprint; the generated
			# extension plane is a huge rectangle and must never be masked.
			if String(mi.name) == "WaterExtension":
				continue
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx = arr[Mesh.ARRAY_INDEX]
			var xf := mi.global_transform
			for v in vs:
				var w: Vector3 = xf * v
				var k := int(round(w.y * 20.0))
				level[k] = int(level.get(k, 0)) + 1
			# Footprint on the same 1 m grid the nav baker uses.  Rasterising
			# vertices is not enough: a river can be a handful of large flat
			# polygons, so 342 vertices covering 2000 m2 marked only 260 cells.
			# Triangles are filled properly instead.
			var tri_count: int = vs.size() / 3 if idx == null else idx.size() / 3
			for t in tri_count:
				var i0: int = t * 3
				var ia: int = i0 if idx == null else int(idx[i0])
				var ib: int = (i0 + 1) if idx == null else int(idx[i0 + 1])
				var ic: int = (i0 + 2) if idx == null else int(idx[i0 + 2])
				if ia >= vs.size() or ib >= vs.size() or ic >= vs.size():
					continue
				var a2: Vector3 = xf * vs[ia]
				var b2: Vector3 = xf * vs[ib]
				var c2: Vector3 = xf * vs[ic]
				var minx := minf(a2.x, minf(b2.x, c2.x))
				var maxx := maxf(a2.x, maxf(b2.x, c2.x))
				var minz := minf(a2.z, minf(b2.z, c2.z))
				var maxz := maxf(a2.z, maxf(b2.z, c2.z))
				var d := (b2.z - c2.z) * (a2.x - c2.x) + (c2.x - b2.x) * (a2.z - c2.z)
				if absf(d) < 1.0e-9:
					continue
				for gz in range(int(floor(minz + 81.5)), int(ceil(maxz + 81.5)) + 1):
					for gx in range(int(floor(minx + 81.5)), int(ceil(maxx + 81.5)) + 1):
						if gx < 0 or gz < 0 or gx >= 163 or gz >= 163:
							continue
						var px := float(gx) - 81.5
						var pz := float(gz) - 81.5
						var w1 := ((b2.z - c2.z) * (px - c2.x) + (c2.x - b2.x) * (pz - c2.z)) / d
						var w2 := ((c2.z - a2.z) * (px - c2.x) + (a2.x - c2.x) * (pz - c2.z)) / d
						var w3 := 1.0 - w1 - w2
						if w1 < -0.02 or w2 < -0.02 or w3 < -0.02:
							continue
						var ck := gz * 163 + gx
						if _water_cells[ck] == 0:
							_water_cells[ck] = 1
			found += 1
	if found == 0:
		_has_water = false
		return
	var best := 0
	var best_n := -1
	for k in level.keys():
		var c := int(level[k])
		if c > best_n:
			best_n = c
			best = int(k)
	_water_level = float(best) / 20.0
	_has_water = true


## Keep the finalized gameplay state, not a second interpretation of the
## conditioned visuals. In particular, water extension rounds its waterline
## differently from the initial footprint scan and hides the authored sheet.
func _store_water_state(node: Node) -> void:
	node.set_meta(WATER_CACHE_META, {"version": WATER_CACHE_VERSION,
		"has_water": _has_water, "level": _water_level,
		"cells": _water_cells.duplicate()})


func _restore_water_state(node: Node) -> bool:
	if not node.has_meta(WATER_CACHE_META):
		return false
	var saved: Variant = node.get_meta(WATER_CACHE_META)
	if not (saved is Dictionary):
		return false
	var version: Variant = saved.get("version")
	var has_water: Variant = saved.get("has_water")
	var level: Variant = saved.get("level")
	var cells: Variant = saved.get("cells")
	if not (version is int) or version != WATER_CACHE_VERSION \
			or not (has_water is bool) \
			or not (level is float or level is int) or not is_finite(float(level)) \
			or not (cells is PackedByteArray) or cells.size() != 163 * 163:
		return false
	for cell in cells:
		if cell != 0 and cell != 1:
			return false
	# Validate everything before assigning any field. A rejected cached scene
	# must not leave half of its state installed before the source is rebuilt.
	_has_water = has_water
	_water_level = float(level)
	_water_cells = cells.duplicate()
	return true


func _prepare_water_cache(node: Node3D) -> void:
	# These helpers are built as siblings while conditioning runs. Adopt them
	# only now, preserving world transforms and the existing pass order, so the
	# saved region includes the visible sheet and its shoreline collision wall.
	for generated_name in ["WaterExtension", "WaterBarrier"]:
		var generated := get_node_or_null(NodePath(generated_name)) as Node3D
		if generated == null:
			continue
		generated.reparent(node, true)
		generated.owner = node
		for descendant in generated.find_children("*", "", true, false):
			descendant.owner = node
	_store_water_state(node)


## Hide the hand-authored navmesh so it never renders.
##
## NAV_* meshes exist to tell the baker where the player may walk; the majority
## of them sit a few centimetres above the floor and would otherwise show as
## bright panels.  They stay in the tree (the baker reads their geometry) but
## are made invisible.
func _hide_nav_markers(node: Node) -> void:
	var hidden := 0
	for n in node.find_children("NAV_*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi != null:
			mi.visible = false
			hidden += 1
	if hidden > 0:
		print("REGION_NAVMARKERS hidden=%d" % hidden)


func _load_region() -> void:
	if Engine.is_editor_hint():
		return
	var phase := _load_stamp()
	var paths := _cache_paths()
	var node: Node3D = null
	var baked := false
	var force := OS.get_cmdline_user_args().has("--rebake")
	var cache_valid := not force and _cache_valid(paths)
	phase = _load_phase("region.cache_validate", phase)
	if cache_valid:
		if _load_perf_enabled:
			print("REGION_RESOURCE_CACHE resident=%s path=%s" % [
				str(ResourceLoader.has_cached(paths[0])), paths[0]])
		var packed := ResourceLoader.load(paths[0]) as PackedScene
		phase = _load_phase("region.cache_read", phase)
		if packed != null:
			node = packed.instantiate() as Node3D
			if node != null:
				baked = _restore_water_state(node)
				if not baked:
					# Legacy or damaged caches cannot recover the authoritative
					# waterline/footprint from already-conditioned visual meshes.
					node.free()
					node = null
			phase = _load_phase("region.cache_instantiate", phase)
	if baked:
		node.name = "RegionWorld"
		# In the tree before measuring: the passes need real global transforms,
		# and a detached node returns identity for them.
		add_child(node)
		phase = _load_phase("region.attach", phase)
		_hide_nav_markers(node)
		_maybe_hide_vegetation(node)
		_load_nav_markers()
		phase = _load_phase("region.nav_markers", phase)
		if _load_perf_enabled:
			print("REGION_WATER_CACHE restored level=%.3f has_water=%s" % [
				_water_level, str(_has_water)])
		_classify(node)
		_load_phase("region.classify", phase)
		print("REGION_CACHE hit %s" % paths[0])
		return
	# No usable bake: parse the GLB and run the full conditioning chain.
	var fresh := preload("res://scripts/glb_util.gd").instantiate(glb_path)
	phase = _load_phase("region.glb_load", phase)
	if fresh == null:
		push_error("region_map: could not load %s" % glb_path)
		return
	node = fresh as Node3D
	node.name = "RegionWorld"
	add_child(node)
	_attach_extra_layers(node)
	phase = _load_phase("region.attach", phase)
	_hide_nav_markers(node)
	_load_nav_markers()
	phase = _load_phase("region.nav_markers", phase)
	_measure_water(node)
	phase = _load_phase("region.water_measure", phase)
	_classify(node)
	phase = _load_phase("region.classify", phase)
	_ensure_vertex_colour_albedo(node)
	_ensure_texture_mipmaps(node)
	_fix_material_textures(node)
	_strip_outliers(node)
	_cull_oversized_faces(node)
	_hide_meshes(node)
	_hide_materials(node)
	_snap_fragments(node)
	_extend_water(node)
	_build_water_wall(node)
	_add_glow_lights(node)
	_transform_bridges(node)
	_shorten_fences_at_stone(node)
	_add_crystal_glow(node)
	_apply_vegetation_wind(node)
	phase = _load_phase("region.condition", phase)
	if _render_lods_enabled():
		var lods := preload("res://scripts/region_render_lods.gd").generate(node)
		print("REGION_RENDER_LODS meshes=%d surfaces=%d levels=%d base_tris=%d lowest_tris=%d ms=%d" % [
			lods.meshes, lods.surfaces, lods.levels, lods.base_triangles,
			lods.lowest_triangles, lods.elapsed_ms])
	phase = _load_phase("region.render_lods", phase)
	_prepare_water_cache(node)
	# Pack outside the tree: a node with a parent cannot be a scene root, and
	# the passes above must keep running while it is in the tree.
	remove_child(node)
	_bake(node, paths)
	add_child(node)
	phase = _load_phase("region.cache_write", phase)
	# Diagnostic visibility is session state, never part of the baked asset.
	# Otherwise a first run with --noveg poisoned later normal cache hits.
	_maybe_hide_vegetation(node)
	_load_phase("region.visibility", phase)


func _cache_valid(paths: Array[String]) -> bool:
	if not FileAccess.file_exists(paths[0]) or not FileAccess.file_exists(paths[1]):
		return false
	var f := FileAccess.open(paths[1], FileAccess.READ)
	if f == null:
		return false
	var stored := f.get_as_text().strip_edges()
	f.close()
	return stored == _cache_key()


## Pack the conditioned tree so the next load skips parsing and every pass.
## Give every node in the branch the scene root as owner.
##
## PackedScene.pack() only serialises nodes that have an owner, and anything
## attached at runtime (the extra GLB layers) has none.  Without this the bake
## silently saved only the base layer, so the map looked complete on the run
## that built the cache and lost its city on every run after that.
func _own_recursive(n: Node, root: Node) -> void:
	for c in n.get_children():
		c.owner = root
		_own_recursive(c, root)


func _bake(node: Node3D, paths: Array[String]) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_own_recursive(node, node)
	var packed := PackedScene.new()
	if packed.pack(node) != OK:
		return
	if ResourceSaver.save(packed, paths[0]) != OK:
		return
	var f := FileAccess.open(paths[1], FileAccess.WRITE)
	if f != null:
		f.store_string(_cache_key())
		f.close()
	print("REGION_CACHE baked %s" % paths[0])


## Sort meshes into ground, solid and decorative lists.
##
## Runs for a fresh parse and for a cache load alike, because those lists drive
## collision, spawning and the nav bake.
## True when the mesh name matches one of the decor_meshes patterns.
func _is_decor_mesh(nm: String) -> bool:
	for p in decor_meshes:
		var pat := String(p)
		if not pat.is_empty() and nm.contains(pat):
			return true
	return false


func _classify(node: Node) -> void:
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or String(mi.name) == "WaterExtension":
			continue
		var nm := String(mi.name)
		if nm in ground_meshes:
			# A map may split its walkable surface, e.g. outer terrain plus a
			# raised plaza plate.  Keeping only the last match silently dropped
			# one of them and the player spawned under the plaza.
			_grounds.append(mi)
			if _ground == null:
				_ground = mi
		elif nm in solid_meshes:
			_solids.append(mi)
		elif _is_decor_mesh(nm):
			_others.append(mi)
		elif default_meshes_solid:
			_solids.append(mi)
		else:
			_others.append(mi)
	# Diagnostic: are the artist's layers actually visible after conditioning?
	if OS.get_cmdline_user_args().has("--meshdiag"):
		# Where the map's structures actually are, relative to the spawn point:
		# a map can load perfectly and still spawn in an empty field.
		var sp := Vector3(spawn_xz.x, 0.0, spawn_xz.y)
		var near: Array = []
		for mm in node.find_children("*", "MeshInstance3D", true, false):
			var m4 := mm as MeshInstance3D
			if m4.mesh == null:
				continue
			var box := m4.global_transform * m4.get_aabb()
			var d := box.get_center().distance_to(sp)
			near.append([d, String(m4.name), box.size.y])
		near.sort_custom(func(a, b): return a[0] < b[0])
		for i in mini(5, near.size()):
			print("NEAR d=%.1fm %s height=%.1f" % [near[i][0], near[i][1], near[i][2]])
		var untextured: Array = []
		for mm in node.find_children("*", "MeshInstance3D", true, false):
			var m6 := mm as MeshInstance3D
			if m6.mesh == null:
				continue
			var with_tex := 0
			var total := 0
			for si in m6.mesh.get_surface_count():
				var mt: Variant = m6.mesh.surface_get_material(si)
				if mt is StandardMaterial3D:
					total += 1
					if (mt as StandardMaterial3D).albedo_texture != null:
						with_tex += 1
			if total > 0 and with_tex == 0:
				untextured.append(String(m6.name))
		print("UNTEXTURED meshes=%d sample=%s" % [untextured.size(), str(untextured.slice(0, 8))])
		var tex_shown := 0
		for mm in node.find_children("*", "MeshInstance3D", true, false):
			var m5 := mm as MeshInstance3D
			if m5.mesh == null or tex_shown >= 4:
				continue
			var mat5: Variant = m5.mesh.surface_get_material(0)
			if mat5 is StandardMaterial3D:
				var tex: Texture2D = (mat5 as StandardMaterial3D).albedo_texture
				if tex != null:
					var img := tex.get_image()
					print("TEX %s size=%s mipmaps=%s filter=%d" % [
						m5.name, str(img.get_size()) if img != null else "?",
						str(img.has_mipmaps()) if img != null else "?",
						(mat5 as StandardMaterial3D).texture_filter])
					tex_shown += 1
		var mats_shown := 0
		var vis := 0
		var hid := 0
		var tris_total := 0
		for mm in node.find_children("*", "MeshInstance3D", true, false):
			var m3 := mm as MeshInstance3D
			if m3.mesh == null:
				continue
			var tris := 0
			for si in m3.mesh.get_surface_count():
				var arr := m3.mesh.surface_get_arrays(si)
				var idx: Variant = arr[Mesh.ARRAY_INDEX]
				if idx != null and (idx as PackedInt32Array).size() > 0:
					tris += (idx as PackedInt32Array).size() / 3
				else:
					var vv: Variant = arr[Mesh.ARRAY_VERTEX]
					if vv is PackedVector3Array:
						tris += (vv as PackedVector3Array).size() / 3
			tris_total += tris
			if mats_shown < 4 and String(m3.name).begins_with("Flora_") and m3.mesh.get_surface_count() > 0:
				var arr0: Array = m3.mesh.surface_get_arrays(0)
				var cols0: Variant = arr0[Mesh.ARRAY_COLOR]
				print("COLOURS %s n=%d" % [m3.name, 0 if cols0 == null else (cols0 as PackedColorArray).size()])
				var mat: Variant = m3.mesh.surface_get_material(0)
				var cls := "null" if mat == null else (mat as Resource).get_class()
				var extra := ""
				if mat is StandardMaterial3D:
					var sm := mat as StandardMaterial3D
					extra = " albedo=%s vcol=%s tex=%s" % [
						str(sm.albedo_color), str(sm.vertex_color_use_as_albedo),
						"yes" if sm.albedo_texture != null else "none"]
				print("MAT %s surface0=%s%s" % [m3.name, cls, extra])
				mats_shown += 1
			if m3.is_visible_in_tree():
				vis += 1
			else:
				hid += 1
		print("MESH_DIAG visible=%d hidden=%d tris=%d" % [vis, hid, tris_total])
	print("REGION_CLASSIFY grounds=%d solids=%d others=%d" % [
		_grounds.size(), _solids.size(), _others.size()])


## Drop triangles that contain a corrupt vertex.
##
## The whole mesh is rebuilt in one pass and every surface is carried over in
## order.  Doing it surface-by-surface would replace a 13-surface mesh with a
## single surface and delete most of the map, so the rebuild is all-or-nothing.
func _strip_outliers(node: Node) -> void:
	var limit := outlier_limit
	if limit <= 0.0:
		return
	var dropped := 0
	var meshes := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		var am := mi.mesh as ArrayMesh
		var sliver_mesh := sliver_meshes.has(String(mi.name))
		var dirty := sliver_mesh
		if not dirty:
			for si in am.get_surface_count():
				var arr := am.surface_get_arrays(si)
				if arr.is_empty():
					continue
				var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				for v in vs:
					if maxf(maxf(absf(v.x), absf(v.y)), absf(v.z)) > limit:
						dirty = true
						break
				if dirty:
					break
		if not dirty:
			continue
		var rebuilt := ArrayMesh.new()
		for si in am.get_surface_count():
			var arr := am.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = PackedInt32Array()
			if arr[Mesh.ARRAY_INDEX] != null:
				idx = arr[Mesh.ARRAY_INDEX]
			var count: int = idx.size() if idx.size() > 0 else vs.size()
			var keep := PackedInt32Array()
			var t := 0
			while t + 2 < count:
				var a: int = idx[t] if idx.size() > 0 else t
				var b: int = idx[t + 1] if idx.size() > 0 else t + 1
				var c: int = idx[t + 2] if idx.size() > 0 else t + 2
				var ok := true
				for vi in [a, b, c]:
					var v: Vector3 = vs[vi]
					if maxf(maxf(absf(v.x), absf(v.y)), absf(v.z)) > limit:
						ok = false
						break
				if ok and sliver_mesh and sliver_max_edge > 0.0:
					var va: Vector3 = vs[a]
					var vb: Vector3 = vs[b]
					var vc: Vector3 = vs[c]
					var edge := maxf(maxf(va.distance_to(vb), vb.distance_to(vc)),
							vc.distance_to(va))
					if edge > sliver_max_edge:
						ok = false
				if ok:
					keep.append(a)
					keep.append(b)
					keep.append(c)
				t += 3
			dropped += (count / 3) - (keep.size() / 3)
			if keep.is_empty():
				# Nothing survived; keep the surface count stable with an empty
				# placeholder so later surface indices still line up.
				continue
			# Compact to the vertices the surviving triangles actually use.
			# Leaving the corrupt vertices in place keeps them in the mesh AABB,
			# which is what blew the map bounds out to 44 million metres.
			var remap := {}
			var nv := PackedVector3Array()
			var nn := PackedVector3Array()
			var nt := PackedFloat32Array()
			var nu := PackedVector2Array()
			var nc := PackedColorArray()
			var has_n: bool = arr[Mesh.ARRAY_NORMAL] != null
			var has_t: bool = arr[Mesh.ARRAY_TANGENT] != null
			var has_u: bool = arr[Mesh.ARRAY_TEX_UV] != null
			var has_c: bool = arr[Mesh.ARRAY_COLOR] != null
			var src_n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if has_n else PackedVector3Array()
			var src_t: PackedFloat32Array = arr[Mesh.ARRAY_TANGENT] if has_t else PackedFloat32Array()
			var src_u: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if has_u else PackedVector2Array()
			var src_c: PackedColorArray = arr[Mesh.ARRAY_COLOR] if has_c else PackedColorArray()
			var compact := PackedInt32Array()
			for oi in keep:
				if remap.has(oi):
					compact.append(int(remap[oi]))
					continue
				var ni: int = nv.size()
				remap[oi] = ni
				compact.append(ni)
				nv.append(vs[oi])
				if has_n:
					nn.append(src_n[oi])
				if has_t:
					for k in 4:
						nt.append(src_t[oi * 4 + k])
				if has_u:
					nu.append(src_u[oi])
				if has_c:
					nc.append(src_c[oi])
			var out := []
			out.resize(Mesh.ARRAY_MAX)
			out[Mesh.ARRAY_VERTEX] = nv
			if has_n:
				out[Mesh.ARRAY_NORMAL] = nn
			if has_t:
				out[Mesh.ARRAY_TANGENT] = nt
			if has_u:
				out[Mesh.ARRAY_TEX_UV] = nu
			if has_c:
				out[Mesh.ARRAY_COLOR] = nc
			out[Mesh.ARRAY_INDEX] = compact
			rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
			rebuilt.surface_set_material(rebuilt.get_surface_count() - 1,
					am.surface_get_material(si))
		if rebuilt.get_surface_count() > 0:
			mi.mesh = rebuilt
			meshes += 1
	if dropped > 0:
		print("REGION_OUTLIER dropped_tris=%d meshes=%d limit=%.0f" % [
			dropped, meshes, limit])


## Turn the carved signs into glowing crystals with local light.
##
## One light per connected piece rather than one per surface: a surface holds
## every carving on the map, and a single light at its centre would sit in empty
## grass.  Clustering by piece puts a light inside each actual recess.
func _add_glow_lights(node: Node) -> void:
	var glow := glow_color
	var made := 0
	var pieces := 0
	var placed: Array[Vector3] = []
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(si)
			var nm := String(m.resource_name).to_lower() if m != null else ""
			if not _pattern_hit(nm, glow_patterns) or _pattern_hit(nm, glow_exclude_patterns):
				continue
			if m is StandardMaterial3D:
				var sm := m as StandardMaterial3D
				sm.albedo_texture = null
				sm.albedo_color = glow
				sm.metallic = 0.15
				sm.roughness = 0.12
				sm.emission_enabled = true
				sm.emission = glow
				sm.emission_energy_multiplier = glow_energy
				sm.rim_enabled = true
				sm.rim = 0.6
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if vs.is_empty():
				continue
			var idx: PackedInt32Array = PackedInt32Array()
			if arr[Mesh.ARRAY_INDEX] != null:
				idx = arr[Mesh.ARRAY_INDEX]
			var soup := PackedVector3Array()
			if idx.size() > 0:
				for i in idx:
					soup.append(vs[i])
			else:
				soup = vs
			var xf := mi.global_transform
			for isl in _face_islands(soup):
				var tri: PackedVector3Array = isl
				pieces += 1
				if made >= glow_max_lights:
					continue
				var c := Vector3.ZERO
				for v in tri:
					var w: Vector3 = xf * v
					c += w
				c /= float(tri.size())
				# One light per distinct carving, not per piece: skip spots that
				# already have one nearby so the budget covers the whole map.
				var too_close := false
				for pp in placed:
					if pp.distance_to(c) < glow_light_min_separation:
						too_close = true
						break
				if too_close:
					continue
				placed.append(c)
				var light := OmniLight3D.new()
				light.name = "GlowLight%d" % made
				light.light_color = glow
				light.light_energy = glow_light_energy
				light.omni_range = glow_light_range
				light.omni_attenuation = 1.3
				light.shadow_enabled = false
				light.position = c
				add_child(light)
				made += 1
	print("REGION_GLOW pieces=%d lights=%d" % [pieces, made])


## Stretch or shift a bridge deck, regenerating the surface.
##
## Long axis is taken from the surface's own world AABB, so the same rule works
## for a deck that runs north-south and one that runs east-west.  Scaling is about
## the deck centre, which keeps both ends moving symmetrically.
func _transform_bridges(node: Node) -> void:
	if bridge_rules.is_empty():
		return
	var rules := {}
	for r in bridge_rules:
		rules[String(r.get("mesh", ""))] = r
	var applied := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not rules.has(String(mi.name)):
			continue
		var rule: Dictionary = rules[String(mi.name)]
		var sc := float(rule.get("scale", 1.0))
		var off: Vector3 = rule.get("offset", Vector3.ZERO)
		if is_equal_approx(sc, 1.0) and off == Vector3.ZERO:
			continue
		var xf := mi.global_transform
		var rebuilt := ArrayMesh.new()
		var changed := false
		for si in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(si)
			var m := mi.mesh.surface_get_material(si)
			if arr.is_empty():
				continue
			var nm := String(m.resource_name).to_lower() if m != null else ""
			if not _pattern_hit(nm, bridge_patterns):
				rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
				rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, m)
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if vs.is_empty():
				continue
			# World AABB decides the long axis.
			var bb := AABB(xf * vs[0], Vector3.ZERO)
			for v in vs:
				bb = bb.expand(xf * v)
			var axis := Vector3.RIGHT if bb.size.x >= bb.size.z else Vector3.BACK
			var centre := bb.get_center()
			var new_vs := PackedVector3Array()
			new_vs.resize(vs.size())
			for i in vs.size():
				var w: Vector3 = xf * vs[i]
				var rel: Vector3 = w - centre
				# Stretch only along the span; leave width and height alone so the
				# planks keep their section and the arch keeps its rise.
				if axis == Vector3.RIGHT:
					rel.x *= sc
				else:
					rel.z *= sc
				w = centre + rel + off
				new_vs[i] = xf.affine_inverse() * w
			var out := arr.duplicate()
			out[Mesh.ARRAY_VERTEX] = new_vs
			rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
			rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, m)
			changed = true
			applied += 1
		if changed:
			mi.mesh = rebuilt
			print("REGION_BRIDGE %s scale=%.2f offset=%s" % [String(mi.name), sc, str(off)])
	print("REGION_BRIDGE surfaces=%d" % applied)
	_debug_move_counts(node)


func _debug_move_counts(node: Node) -> void:
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null: continue
		for si in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(si)
			var nm := String(m.resource_name).to_lower() if m != null else ""
			if not nm.contains("pine"): continue
			var arr := mi.mesh.surface_get_arrays(si)
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var xf := mi.global_transform
			for k in vegetation_moves.size():
				var mv: Dictionary = vegetation_moves[k]
				var c: Vector3 = mv.get("center", Vector3.ZERO)
				var r: float = float(mv.get("radius", 0.0))
				var inside := 0
				for v in vs:
					var w: Vector3 = xf * v
					if Vector2(w.x - c.x, w.z - c.z).length() < r: inside += 1
				print("MOVECHK move%d center=%s inside=%d" % [k, str(c), inside])


## Remove fencing that intersects stone.
##
## Works on connected pieces rather than triangles: a fence is separate posts and
## rails, so retiring the pieces that touch rock leaves a clean end at the wall.
##
## Pieces are retired by moving their vertices far below the world rather than by
## deleting them.  Deleting would mean rebuilding the vertex arrays, and any
## mistake there silently drops UVs or normals -- which is exactly the kind of
## breakage that costs a round trip to spot.  Moving keeps every attribute
## attached and makes the piece invisible.
##
## Only whole pieces move, so no half-rail is left hanging through the ridge.
func _shorten_fences_at_stone(node: Node) -> void:
	if not shorten_fences_at_stone:
		return
	# Spatial hash of stone vertices, 1 m cells.
	var stone := {}
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(si)
			var nm := String(m.resource_name).to_lower() if m != null else ""
			if not _pattern_hit(nm, stone_patterns):
				continue
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var svs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var sxf := mi.global_transform
			for v in svs:
				var w := sxf * v
				var key := "%d,%d" % [int(floor(w.x)), int(floor(w.z))]
				if not stone.has(key):
					stone[key] = PackedVector3Array()
				var bucket: PackedVector3Array = stone[key]
				bucket.append(w)
				stone[key] = bucket
	if stone.is_empty():
		return

	var near := func(wp: Vector3) -> bool:
		var cx := int(floor(wp.x))
		var cz := int(floor(wp.z))
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var key := "%d,%d" % [cx + dx, cz + dz]
				if not stone.has(key):
					continue
				for sv in stone[key]:
					if wp.distance_to(sv) <= fence_stone_clearance:
						return true
		return false

	var retired := 0
	var surfaced := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var has_fence := false
		for si in mi.mesh.get_surface_count():
			var m0 := mi.mesh.surface_get_material(si)
			if m0 != null and _pattern_hit(String(m0.resource_name).to_lower(), fence_patterns):
				has_fence = true
				break
		if not has_fence:
			continue
		var xf := mi.global_transform
		var rebuilt := ArrayMesh.new()
		var touched := false
		for si in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(si)
			var m := mi.mesh.surface_get_material(si)
			if arr.is_empty():
				continue
			var nm := String(m.resource_name).to_lower() if m != null else ""
			if not _pattern_hit(nm, fence_patterns):
				rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
				rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, m)
				continue
			surfaced += 1
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx := PackedInt32Array()
			if arr[Mesh.ARRAY_INDEX] != null:
				idx = arr[Mesh.ARRAY_INDEX]
			# Union-find over vertices, merging by index when indexed and by
			# rounded position otherwise, so a piece is one group.
			var parent := {}
			var find := func(a: int) -> int:
				while parent.has(a) and int(parent[a]) != a:
					parent[a] = int(parent[int(parent[a])])
					a = int(parent[a])
				return a
			var key_of := func(i: int) -> int:
				if idx.size() > 0:
					return idx[i]
				var v := vs[i]
				return hash(Vector3i(roundi(v.x * 100.0), roundi(v.y * 100.0), roundi(v.z * 100.0)))
			var tris := (idx.size() / 3) if idx.size() > 0 else (vs.size() / 3)
			for t in tris:
				for k in 3:
					var kv: int = key_of.call(t * 3 + k)
					if not parent.has(kv):
						parent[kv] = kv
				var r0: int = find.call(key_of.call(t * 3))
				for k in [1, 2]:
					var rk: int = find.call(key_of.call(t * 3 + k))
					if r0 != rk:
						parent[rk] = r0
			# Which groups touch stone?
			var doomed := {}
			for t in tris:
				var hit := false
				for k in 3:
					var vi: int = (idx[t * 3 + k] if idx.size() > 0 else t * 3 + k)
					if near.call(xf * vs[vi]):
						hit = true
						break
				if hit:
					for k in 3:
						doomed[find.call(key_of.call(t * 3 + k))] = true
			if doomed.is_empty():
				rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
				rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, m)
				continue
			# Move every vertex of a doomed group 500 m down.
			var moved := 0
			var new_vs := vs.duplicate()
			var seen := {}
			for t in tris:
				for k in 3:
					var vi: int = (idx[t * 3 + k] if idx.size() > 0 else t * 3 + k)
					var r: int = find.call(key_of.call(t * 3 + k))
					if doomed.has(r) and not seen.has(vi):
						seen[vi] = true
						var p2 := new_vs[vi]
						new_vs[vi] = Vector3(p2.x, p2.y - 500.0, p2.z)
						moved += 1
			retired += moved
			var out := arr.duplicate()
			out[Mesh.ARRAY_VERTEX] = new_vs
			rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
			rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, m)
			touched = true
		if touched:
			mi.mesh = rebuilt
	print("REGION_FENCE surfaces=%d retired_verts=%d" % [surfaced, retired])


## Make the henge crystal glow and light its surroundings.
##
## The package ships M_crystal carrying the brick albedo with no emissive at all,
## so the centrepiece of the henge rendered as a grey brick lump.  Here it is
## turned into an untextured blue emissive, and a real OmniLight3D is dropped at
## its centre so the stones around it actually receive coloured light -- an
## emissive material alone brightens the crystal but casts nothing.
func _add_crystal_glow(node: Node) -> void:
	var glow := Color(0.22, 0.62, 1.0)
	var centre := Vector3.ZERO
	var found := false
	var hits := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(si)
			var nm := String(m.resource_name).to_lower() if m != null else ""
			if not nm.contains("crystal"):
				continue
			hits += 1
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if vs.is_empty():
				continue
			var xf := mi.global_transform
			var bb := AABB(xf * vs[0], Vector3.ZERO)
			for v in vs:
				bb = bb.expand(xf * v)
			centre += bb.get_center()
			found = true
			if m is StandardMaterial3D:
				var sm := m as StandardMaterial3D
				sm.albedo_texture = null
				sm.albedo_color = glow
				sm.metallic = 0.10
				sm.roughness = 0.14
				sm.emission_enabled = true
				sm.emission = glow
				sm.emission_energy_multiplier = 4.0
				sm.rim_enabled = true
				sm.rim = 0.55
	if not found:
		return
	centre /= float(hits)
	var light := OmniLight3D.new()
	light.name = "CrystalLight"
	light.light_color = glow
	light.light_energy = 3.2
	light.omni_range = 18.0
	light.omni_attenuation = 1.4
	light.shadow_enabled = false
	light.position = centre + Vector3(0, 0.8, 0)
	add_child(light)
	print("REGION_CRYSTAL surfaces=%d centre=%s" % [hits, str(centre)])


## Decode a texture straight from PNG bytes.
##
## Godot's import pipeline is bypassed on purpose: headless runs never write
## .import sidecars, so load("res://...png") works in the editor and fails in a
## headless boot.  Reading the file keeps both paths identical.
func _texture_from_file(path: String) -> Texture2D:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(img)


## Swap stone textures off wood materials.  Only materials whose override is set
## are touched, so correct ones (M_bark, M_prop_bark) are left alone.
func _fix_material_textures(node: Node) -> void:
	if material_texture_overrides.is_empty():
		return
	var cache := {}
	var fixed := []
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(si)
			if not (m is StandardMaterial3D):
				continue
			var sm := m as StandardMaterial3D
			var key := String(sm.resource_name).to_lower()
			if not material_texture_overrides.has(key):
				continue
			var file: String = material_texture_overrides[key]
			var full := material_texture_dir + file
			if not cache.has(full):
				cache[full] = _texture_from_file(full)
			var tex: Texture2D = cache[full]
			if tex == null:
				push_warning("region_map: missing override texture %s" % full)
				continue
			if sm.albedo_texture == tex:
				continue
			sm.albedo_texture = tex
			fixed.append(String(sm.resource_name))
	print("REGION_MATTEX fixed=%d %s" % [fixed.size(), str(fixed)])


## Leaf detail, decoded straight from PNG bytes.
##
## Loaded directly rather than via the import pipeline because headless Godot
## never writes .import sidecars, so a load("res://....png") would fail there
## while working in the editor -- exactly the kind of split that makes a bug
## look intermittent.
func _leaf_detail_texture() -> Texture2D:
	var f := FileAccess.open("res://assets/worlds/island/textures/leaf_detail.png",
			FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(img)


## Give every vegetation surface the wind shader, carrying over whatever the
## package already had: its albedo texture, its tint, and whether it wants vertex
## colour.  Foliage that shipped with no texture at all gets the leaf detail
## texture, so canopies stop rendering as flat colour blobs.
func _apply_vegetation_wind(node: Node) -> void:
	if not wind_enabled:
		return
	var sh: Shader = load("res://shaders/vegetation_wind.gdshader")
	if sh == null:
		push_warning("region_map: vegetation_wind.gdshader missing")
		return
	var leaf_tex := _leaf_detail_texture()
	# Where the bridges meet land, so plants there can be pushed out of the way.
	var clears := _bridge_clear_points(node)
	var applied := 0
	var textured := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s_idx in mi.mesh.get_surface_count():
			var old := mi.mesh.surface_get_material(s_idx)
			var nm := String(old.resource_name).to_lower() if old != null else ""
			if nm.is_empty() or not _pattern_hit(nm, wind_patterns) \
					or _pattern_hit(nm, wind_exclude_patterns):
				continue
			var arr := mi.mesh.surface_get_arrays(s_idx)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if vs.is_empty():
				continue
			# Per-surface height range gives the bend mask.  A grass blade and a
			# tree canopy both get 0..1 from this, which a single mesh-wide range
			# could not do.
			var lo := vs[0].y
			var hi := vs[0].y
			for v in vs:
				lo = minf(lo, v.y)
				hi = maxf(hi, v.y)

			var has_uv := false
			if arr[Mesh.ARRAY_TEX_UV] != null:
				has_uv = (arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() > 0
			var m := ShaderMaterial.new()
			m.shader = sh
			var tex: Texture2D = null
			var tint := Color(1, 1, 1, 1)
			var use_vc := true
			if old is StandardMaterial3D:
				var sm := old as StandardMaterial3D
				tex = sm.albedo_texture
				tint = sm.albedo_color
				use_vc = sm.vertex_color_use_as_albedo
			# No texture and it is foliage: give it leaf detail.
			if tex == null and leaf_tex != null and not _pattern_hit(nm, PackedStringArray(["bark"])):
				tex = leaf_tex
			# No UVs means every vertex fetches the same texel; a generated detail
			# texture would tint the whole surface a flat colour.
			if not has_uv:
				tex = null
			if tex == null:
				# Shader still samples the slot; a 1x1 white keeps it neutral.
				var w := Image.create(1, 1, false, Image.FORMAT_RGB8)
				w.fill(Color(1, 1, 1))
				tex = ImageTexture.create_from_image(w)
			else:
				textured += 1
			m.set_shader_parameter("albedo_tex", tex)
			m.set_shader_parameter("tint", tint)
			m.set_shader_parameter("use_texture", true)
			m.set_shader_parameter("use_vertex_color", use_vc)
			m.set_shader_parameter("base_y", lo)
			m.set_shader_parameter("top_y", hi)

			var is_grass := _pattern_hit(nm, wind_grass_patterns)
			m.set_shader_parameter("sway_strength",
					wind_grass_sway_strength if is_grass else wind_sway_strength)
			m.set_shader_parameter("sway_speed",
					wind_grass_sway_speed if is_grass else wind_sway_speed)
			m.set_shader_parameter("flutter", 0.026 if is_grass else 0.016)
			for mi_i in 2:
				var mk := ["move_a", "move_b"][mi_i] as String
				if vegetation_moves.size() > mi_i:
					var mv: Dictionary = vegetation_moves[mi_i]
					m.set_shader_parameter(mk + "_center", mv.get("center", Vector3.ZERO))
					m.set_shader_parameter(mk + "_offset", mv.get("offset", Vector3.ZERO))
					m.set_shader_parameter(mk + "_radius", float(mv.get("radius", 0.0)))
				else:
					m.set_shader_parameter(mk + "_radius", 0.0)
			# Up to four landing points: two bridges, two ends each.
			for ci in 4:
				var key: String = ["clear_a", "clear_b", "clear_c", "clear_d"][ci]
				var cp: Vector3 = clears[ci] if clears.size() > ci else Vector3(0, -9999, 0)
				m.set_shader_parameter(key, cp)
			mi.mesh.surface_set_material(s_idx, m)
			applied += 1
	print("REGION_WIND surfaces=%d textured=%d clear_pts=%s" % [
		applied, textured, str(clears)])


## Vertex-coloured packages (index-less albedo) render flat grey unless the
## albedo is multiplied by COLOR_0.  Godot sets this for most cases, but a
## package with a white base colour factor can arrive with it off.
func _ensure_vertex_colour_albedo(node: Node) -> void:
	var fixed := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var colours = arr[Mesh.ARRAY_COLOR]
			if colours == null or colours.size() == 0:
				continue
			var m := mi.mesh.surface_get_material(s) as StandardMaterial3D
			if m != null and not m.vertex_color_use_as_albedo:
				m.vertex_color_use_as_albedo = true
				fixed += 1
	if fixed > 0:
		print("REGION_VCOL enabled vertex-colour albedo on %d surfaces" % fixed)


## Give every albedo texture a mip chain.
##
## The artist's GLBs embed textures without mipmaps.  At any distance a tiled
## floor then samples one texel per pixel and the grout lines crawl into black
## crosses; the terrain texture happens to ship mipmaps, which is why only the
## buildings and paving shimmered.
func _ensure_texture_mipmaps(node: Node) -> void:
	var fixed := 0
	var seen := {}
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var m: Variant = mi.mesh.surface_get_material(s)
			if not (m is StandardMaterial3D):
				continue
			var sm := m as StandardMaterial3D
			var tex := sm.albedo_texture
			if tex == null:
				continue
			var rid := tex.get_rid()
			if seen.has(rid):
				continue
			seen[rid] = true
			var img := tex.get_image()
			if img == null or img.has_mipmaps():
				continue
			var copy := img.duplicate()
			copy.generate_mipmaps()
			sm.albedo_texture = ImageTexture.create_from_image(copy)
			fixed += 1
	if fixed > 0:
		print("REGION_MIPMAPS generated=%d" % fixed)


## Triplanar detail over the vertex-coloured ground.
## The package ships no water texture -- M_water is a flat
## [0.08, 0.32, 0.34] at metallic 0.3 with nothing to catch light, so in shadow
## it reads as a black void.  Give it a colour it can actually show.
func _water_material() -> ShaderMaterial:
	var sh: Shader = load("res://shaders/river_water.gdshader")
	var m := ShaderMaterial.new()
	m.resource_name = "Water_Runtime"
	if sh != null:
		m.shader = sh
	m.set_shader_parameter("shallow_color", water_color.lightened(0.22))
	m.set_shader_parameter("deep_color", water_color.darkened(0.62))
	m.set_shader_parameter("foam_color", Color(0.80, 0.90, 0.92))
	m.set_shader_parameter("glow_color", water_glow_color)
	m.set_shader_parameter("glow_strength", water_glow_strength)
	m.set_shader_parameter("bubble_strength", water_bubble_strength)
	m.set_shader_parameter("bubble_scale", water_bubble_scale)
	m.set_shader_parameter("bubble_density", water_bubble_density)
	m.set_shader_parameter("bubble_speed", water_bubble_speed)
	# Only in-place basins (fountains) ask for cubemap reflections; open rivers
	# keep the screen-space march, which reflects the actual banks.
	m.set_shader_parameter("env_reflect", 0.0)
	return m


func _hidden_water_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	# The name must keep matching the water pattern: the island apron locates
	# the painted sheet by material name, and renaming this to something neutral
	# silently made that apron return null.  _extend_water skips hidden surfaces
	# explicitly instead.
	m.resource_name = "Water_Hidden"
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	m.albedo_color = Color(0.0, 0.0, 0.0, 0.0)
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	m.no_depth_test = false
	return m


## Rasterise the ground into a height grid, once, for fragment snapping.
## Raycasts would be simpler but the editor viewport does not step physics, so
## the grid keeps the editor and the game showing the same thing.
func _build_ground_grid() -> Dictionary:
	if _ground == null or _ground.mesh == null:
		return {}
	var cell := maxf(snap_ground_cell, 0.25)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var xf := _ground.global_transform
	for s in _ground.mesh.get_surface_count():
		var arr := _ground.mesh.surface_get_arrays(s)
		if arr.is_empty():
			continue
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for v in vs:
			var w: Vector3 = xf * v
			lo = Vector2(minf(lo.x, w.x), minf(lo.y, w.z))
			hi = Vector2(maxf(hi.x, w.x), maxf(hi.y, w.z))
	if not is_finite(lo.x):
		return {}
	var nx := int((hi.x - lo.x) / cell) + 1
	var nz := int((hi.y - lo.y) / cell) + 1
	if nx <= 0 or nz <= 0 or nx * nz > 4000000:
		return {}
	var heights := PackedFloat32Array()
	heights.resize(nx * nz)
	heights.fill(-INF)
	for s in _ground.mesh.get_surface_count():
		var arr := _ground.mesh.surface_get_arrays(s)
		if arr.is_empty():
			continue
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for v in vs:
			var w: Vector3 = xf * v
			var gx := int((w.x - lo.x) / cell)
			var gz := int((w.z - lo.y) / cell)
			if gx < 0 or gz < 0 or gx >= nx or gz >= nz:
				continue
			var i := gz * nx + gx
			if w.y > heights[i]:
				heights[i] = w.y
	# Scatter leaves many empty cells; dilate a few times so a shard over a gap
	# still finds nearby ground instead of being left alone.
	for pass_i in 6:
		var next := heights.duplicate()
		for gz in nz:
			for gx in nx:
				var i := gz * nx + gx
				if heights[i] > -INF:
					continue
				var best := -INF
				for dz: int in [-1, 0, 1]:
					for dx: int in [-1, 0, 1]:
						var ax: int = gx + dx
						var az: int = gz + dz
						if ax < 0 or az < 0 or ax >= nx or az >= nz:
							continue
						var v2 := heights[az * nx + ax]
						if v2 > best:
							best = v2
				next[i] = best
		heights = next
	return {"lo": lo, "cell": cell, "nx": nx, "nz": nz, "h": heights}


func _grid_height(grid: Dictionary, x: float, z: float) -> float:
	if grid.is_empty():
		return NAN
	var lo: Vector2 = grid["lo"]
	var cell: float = grid["cell"]
	var nx: int = grid["nx"]
	var nz: int = grid["nz"]
	var gx := int((x - lo.x) / cell)
	var gz := int((z - lo.y) / cell)
	if gx < 0 or gz < 0 or gx >= nx or gz >= nz:
		return NAN
	var h: PackedFloat32Array = grid["h"]
	var v := h[gz * nx + gx]
	return NAN if v <= -INF else v


## Vertical wall around every water body, so the shoreline is not walkable.
##
## A flat plane cannot block anything -- the player simply stands on it or on the
## bed beneath.  Following the water mesh's boundary edges and extruding them
## upward gives a barrier that hugs the real outline, and because it stops at
## water level + height, bridge decks passing overhead stay untouched.
func _build_water_wall(node: Node) -> void:
	if not water_wall_enabled:
		return
	var faces := PackedVector3Array()
	var edges := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var mm := mi.mesh.surface_get_material(si)
			var nm := String(mm.resource_name).to_lower() if mm != null else ""
			if nm.is_empty() or not _pattern_hit(nm, water_patterns) \
					or _pattern_hit(nm, water_exclude_patterns):
				continue
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = PackedInt32Array()
			if arr[Mesh.ARRAY_INDEX] != null:
				idx = arr[Mesh.ARRAY_INDEX]
			var cnt: int = idx.size() if idx.size() > 0 else vs.size()
			var xf := mi.global_transform
			# Quantised positions double as vertex ids, because the surface has no
			# guarantee of shared indices after the exporter's join.
			var ids := {}
			var pos: Array[Vector3] = []
			var tris := PackedInt32Array()
			var t := 0
			while t + 2 < cnt:
				for k in 3:
					var vi: int = idx[t + k] if idx.size() > 0 else t + k
					var w: Vector3 = xf * vs[vi]
					var key := Vector3i(roundi(w.x * 100.0), roundi(w.y * 100.0),
							roundi(w.z * 100.0))
					if not ids.has(key):
						ids[key] = pos.size()
						pos.append(w)
					tris.append(int(ids[key]))
				t += 3
			var counts := {}
			var tn := tris.size() / 3
			for i in tn:
				var a := tris[i * 3]
				var b := tris[i * 3 + 1]
				var c := tris[i * 3 + 2]
				for e in [[a, b], [b, c], [c, a]]:
					var lo: int = mini(e[0], e[1])
					var hi: int = maxi(e[0], e[1])
					var ekey := lo * 4194304 + hi
					counts[ekey] = int(counts.get(ekey, 0)) + 1
			var top := _water_level + water_wall_height
			for ekey in counts.keys():
				if int(counts[ekey]) != 1:
					continue
				var lo2: int = int(ekey) / 4194304
				var hi2: int = int(ekey) % 4194304
				var p1: Vector3 = pos[lo2]
				var p2: Vector3 = pos[hi2]
				var a1 := Vector3(p1.x, _water_level - 1.0, p1.z)
				var a2 := Vector3(p2.x, _water_level - 1.0, p2.z)
				var b1 := Vector3(p1.x, top, p1.z)
				var b2 := Vector3(p2.x, top, p2.z)
				faces.append_array(PackedVector3Array([a1, a2, b2]))
				faces.append_array(PackedVector3Array([a1, b2, b1]))
				edges += 1
	if faces.is_empty():
		print("REGION_WALL no boundary edges found")
		return
	var body := StaticBody3D.new()
	body.name = "WaterBarrier"
	body.collision_layer = 2
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
	print("REGION_WALL edges=%d tris=%d top=%.2f" % [edges, faces.size() / 3,
		_water_level + water_wall_height])


## Drop loose fragments onto the terrain.
##
## Pieces are found by union-find over vertex indices, so a rib spanning several
## metres is one object instead of being split at a grid cell.  Only positions
## move: a translation leaves normals and UVs valid, so no soup rebuild and no
## normal recomputation are needed.
func _snap_fragments(node: Node) -> void:
	if not snap_fragments or snap_material_patterns.is_empty():
		return
	var grid := _build_ground_grid()
	if grid.is_empty():
		print("REGION_SNAP skipped: no ground grid")
		return
	var moved_pieces := 0
	var surfaces := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		if not snap_meshes.has(String(mi.name)):
			continue
		var am := mi.mesh as ArrayMesh
		for si in am.get_surface_count():
			var mm := am.surface_get_material(si)
			var nm := String(mm.resource_name).to_lower() if mm != null else ""
			if nm.is_empty() or not _pattern_hit(nm, snap_material_patterns) \
					or _pattern_hit(nm, snap_material_exclude):
				continue
			var arr := am.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var nv := vs.size()
			if nv == 0:
				continue
			var idx: PackedInt32Array = PackedInt32Array()
			if arr[Mesh.ARRAY_INDEX] != null:
				idx = arr[Mesh.ARRAY_INDEX]
			var count: int = idx.size() if idx.size() > 0 else nv
			var parent := PackedInt32Array()
			parent.resize(nv)
			for i in nv:
				parent[i] = i
			var t := 0
			while t + 2 < count:
				var a: int = idx[t] if idx.size() > 0 else t
				var b: int = idx[t + 1] if idx.size() > 0 else t + 1
				var c: int = idx[t + 2] if idx.size() > 0 else t + 2
				var ra: int = a
				while parent[ra] != ra:
					parent[ra] = parent[parent[ra]]
					ra = parent[ra]
				for other in [b, c]:
					var rb: int = other
					while parent[rb] != rb:
						parent[rb] = parent[parent[rb]]
						rb = parent[rb]
					if ra != rb:
						parent[rb] = ra
				t += 3
			var xf := mi.global_transform
			var inv := xf.affine_inverse()
			# One pass accumulating lowest Y, position sum and count per root.
			var low := {}
			var sum := {}
			var cnt := {}
			for i in nv:
				var r: int = i
				while parent[r] != r:
					parent[r] = parent[parent[r]]
					r = parent[r]
				parent[i] = r
				var w: Vector3 = xf * vs[i]
				if low.has(r):
					if w.y < low[r]:
						low[r] = w.y
					sum[r] = sum[r] + w
					cnt[r] = int(cnt[r]) + 1
				else:
					low[r] = w.y
					sum[r] = w
					cnt[r] = 1
			var delta := {}
			for r in low.keys():
				var centre: Vector3 = sum[r] / float(cnt[r])
				var g := _grid_height(grid, centre.x, centre.z)
				if is_nan(g):
					continue
				if float(low[r]) > g + snap_min_height:
					delta[r] = g + 0.02 - float(low[r])
			if delta.is_empty():
				continue
			var touched := 0
			for i in nv:
				var r2: int = parent[i]
				if not delta.has(r2):
					continue
				vs[i] = vs[i] + inv.basis * Vector3(0.0, float(delta[r2]), 0.0)
				touched += 1
			if touched == 0:
				continue
			moved_pieces += delta.size()
			var rebuilt := ArrayMesh.new()
			for sj in am.get_surface_count():
				if sj == si:
					var o := arr.duplicate()
					o[Mesh.ARRAY_VERTEX] = vs
					rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, o)
					rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, mm)
				else:
					var o2 := am.surface_get_arrays(sj)
					if o2.is_empty():
						continue
					rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, o2)
					rebuilt.surface_set_material(rebuilt.get_surface_count() - 1,
							am.surface_get_material(sj))
			mi.mesh = rebuilt
			surfaces += 1
			break
	if surfaces > 0:
		print("REGION_SNAP pieces=%d surfaces=%d" % [moved_pieces, surfaces])


## Remove individual triangles above an edge length, keeping the rest intact.
##
## Unlike _strip_outliers this leaves the vertex arrays untouched and filters only
## the index buffer, so normals, UVs and vertex colours stay exactly as authored.
func _cull_oversized_faces(node: Node) -> void:
	if max_face_edge <= 0.0 or max_face_meshes.is_empty():
		return
	var dropped := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		if not max_face_meshes.has(String(mi.name)):
			continue
		var am := mi.mesh as ArrayMesh
		var rebuilt := ArrayMesh.new()
		var changed := false
		for si in am.get_surface_count():
			var arr := am.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = PackedInt32Array()
			if arr[Mesh.ARRAY_INDEX] != null:
				idx = arr[Mesh.ARRAY_INDEX]
			var cnt: int = idx.size() if idx.size() > 0 else vs.size()
			var keep := PackedInt32Array()
			var t := 0
			var local_drop := 0
			while t + 2 < cnt:
				var ia: int = idx[t] if idx.size() > 0 else t
				var ib: int = idx[t + 1] if idx.size() > 0 else t + 1
				var ic: int = idx[t + 2] if idx.size() > 0 else t + 2
				var a := vs[ia]
				var e := maxf(maxf(a.distance_to(vs[ib]), vs[ib].distance_to(vs[ic])),
						vs[ic].distance_to(a))
				if e > max_face_edge:
					local_drop += 1
				else:
					keep.append(ia)
					keep.append(ib)
					keep.append(ic)
				t += 3
			if local_drop > 0:
				changed = true
				dropped += local_drop
			var o := arr.duplicate()
			o[Mesh.ARRAY_INDEX] = keep
			rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, o)
			rebuilt.surface_set_material(rebuilt.get_surface_count() - 1,
					am.surface_get_material(si))
		if changed:
			mi.mesh = rebuilt
	if dropped > 0:
		print("REGION_FACECULL meshes=%s dropped_tris=%d limit=%.1fm" % [
			str(max_face_meshes), dropped, max_face_edge])


## Remove entire mesh nodes by name.
func _hide_meshes(node: Node) -> void:
	if hide_meshes.is_empty():
		return
	# Collect first, then detach: freeing while find_children is walking the tree
	# invalidates the iterator.
	var doomed: Array[MeshInstance3D] = []
	for want in hide_meshes:
		for n in node.find_children(String(want), "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi != null:
				doomed.append(mi)
	var gone := 0
	for mi2 in doomed:
		var parent := mi2.get_parent()
		if parent != null:
			parent.remove_child(mi2)
		mi2.mesh = null
		mi2.queue_free()
		gone += 1
	if gone > 0:
		print("REGION_HIDEMESH removed=%d masks=%s" % [gone, str(hide_meshes)])


## Discard whole surfaces by material name.
func _hide_materials(node: Node) -> void:
	if hide_material_patterns.is_empty():
		return
	var hidden := 0
	var gone := _hidden_water_material()
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var mm := mi.mesh.surface_get_material(si)
			var nm := String(mm.resource_name).to_lower() if mm != null else ""
			if nm.is_empty() or not _pattern_hit(nm, hide_material_patterns):
				continue
			mi.mesh.surface_set_material(si, gone)
			hidden += 1
	if hidden > 0:
		print("REGION_HIDE surfaces=%d patterns=%s" % [hidden, str(hide_material_patterns)])


## Close the water in every direction by replacing the authored sheet with a
## single plane covering `water_extend_scale` times its footprint.
func _extend_water(node: Node) -> void:
	if not water_extend_enabled or water_extend_scale <= 1.0:
		return
	var hidden := _hidden_water_material()
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var level := {}
	var found := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var mm := mi.mesh.surface_get_material(si)
			var nm := String(mm.resource_name).to_lower() if mm != null else ""
			if nm.is_empty() or not _pattern_hit(nm, water_patterns) \
					or _pattern_hit(nm, water_exclude_patterns):
				continue
			# Already-hidden surfaces keep a water-ish name so the island apron
			# can still find them; they must not count as real water here.
			if nm.contains("hidden"):
				continue
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var xf := mi.global_transform
			for v in vs:
				var w: Vector3 = xf * v
				lo = Vector3(minf(lo.x, w.x), minf(lo.y, w.y), minf(lo.z, w.z))
				hi = Vector3(maxf(hi.x, w.x), maxf(hi.y, w.y), maxf(hi.z, w.z))
				var k := roundi(w.y * 10.0)
				level[k] = int(level.get(k, 0)) + 1
			mi.mesh.surface_set_material(si, hidden)
			found += 1
	if found == 0 or not is_finite(lo.x):
		print("REGION_WATERX surfaces=0 (nothing matched)")
		return
	# Most common vertex height is the true water level; the min/max include the
	# sloping shore trim and would sink the plane below the visible surface.
	var best_key := 0
	var best_count := -1
	for k in level.keys():
		var c := int(level[k])
		if c > best_count:
			best_count = c
			best_key = int(k)
	var y := float(best_key) / 10.0
	_water_level = y
	var cx := (lo.x + hi.x) * 0.5
	var cz := (lo.z + hi.z) * 0.5
	var sx := (hi.x - lo.x) * water_extend_scale
	var sz := (hi.z - lo.z) * water_extend_scale
	var plane := PlaneMesh.new()
	plane.size = Vector2(maxf(sx, 4.0), maxf(sz, 4.0))
	plane.subdivide_width = clampi(water_extend_cells, 0, 200)
	plane.subdivide_depth = clampi(water_extend_cells, 0, 200)
	var mi2 := MeshInstance3D.new()
	mi2.name = "WaterExtension"
	mi2.mesh = plane
	mi2.material_override = _water_material()
	mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi2.position = Vector3(cx, y + 0.02, cz)
	add_child(mi2)
	print("REGION_WATERX surfaces=%d level=%.2f size=%.0fx%.0f centre=(%.1f,%.1f)" % [
		found, y, sx, sz, cx, cz])


## Seal the seam between the water sheet and the banks, and paint both the same
## colour so the apron never shows as a seam of its own.
func _build_water_apron() -> void:
	if _ground == null:
		return
	var wm := _water_material()
	var hidden := _hidden_water_material()
	var painted := 0
	for s in _ground.mesh.get_surface_count():
		var mat := _ground.mesh.surface_get_material(s)
		var nm := String(mat.resource_name).to_lower() if mat != null else ""
		if nm.is_empty() or not _pattern_hit(nm, water_patterns) \
				or _pattern_hit(nm, water_exclude_patterns):
			continue
		# The plane below replaces this sheet entirely, so hide it rather than
		# recolouring it -- two transparent water surfaces would double-blend.
		_ground.mesh.surface_set_material(s, hidden)
		painted += 1
	if water_apron_width <= 0.0:
		return
	var apron := preload("res://scripts/water_apron.gd").build(
			_ground, water_patterns, water_exclude_patterns,
			water_apron_width, wm)
	if apron == null:
		print("REGION_WATER surfaces=%d apron=none" % painted)
		return
	add_child(apron)
	var arr := apron.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx = arr[Mesh.ARRAY_INDEX]
	var tris: int = (verts.size() if idx == null else idx.size()) / 3
	var ext: Vector2 = apron.get_meta("extent", Vector2.ZERO)
	print("REGION_WATER surfaces=%d plane_tris=%d verts=%d cells=%d extent=%.0fx%.0fm spread=%.0f" % [
		painted, tris, verts.size(), int(apron.get_meta("cells", 0)),
		ext.x, ext.y, water_apron_width])


func _pattern_hit(name: String, patterns: PackedStringArray) -> bool:
	for p in patterns:
		var pat := String(p).to_lower()
		if not pat.is_empty() and name.contains(pat):
			return true
	return false


func _apply_ground_detail() -> void:
	if ground_detail_texture.is_empty() or _ground == null:
		return
	var tex := load(ground_detail_texture) as Texture2D
	if tex == null:
		# Headless has no import cache; decode the file directly.
		var raw := FileAccess.get_file_as_bytes(ground_detail_texture)
		var img := Image.new()
		var ok := img.load_png_from_buffer(raw) if ground_detail_texture.ends_with(".png") \
				else img.load_jpg_from_buffer(raw)
		if ok == OK:
			tex = ImageTexture.create_from_image(img)
	if tex == null:
		push_warning("region_map: could not load ground detail %s" % ground_detail_texture)
		return
	for s in _ground.mesh.get_surface_count():
		var base := _ground.mesh.surface_get_material(s) as StandardMaterial3D
		var m := StandardMaterial3D.new()
		if base != null:
			m = base.duplicate() as StandardMaterial3D
		m.albedo_texture = tex
		m.vertex_color_use_as_albedo = true
		m.uv1_triplanar = true
		m.uv1_scale = Vector3.ONE * ground_detail_scale
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		_ground.mesh.surface_set_material(s, m)
	print("REGION_GROUND_DETAIL %s scale=%.3f surfaces=%d" % [
		ground_detail_texture.get_file(), ground_detail_scale,
		_ground.mesh.get_surface_count()])


func _build_collision() -> void:
	var phase := _load_stamp()
	# Deck boxes must exist before props are classified, otherwise the strip has
	# nothing to test against and silently removes nothing.
	if strip_props_on_decks:
		_collect_deck_boxes()
	phase = _load_phase("collision.deck_index", phase)
	if _grounds.is_empty():
		push_error("region_map: no ground mesh among %s in %s" % [str(ground_meshes), glb_path])
	# Diagnostic: NO_GROUND_COLL=1 drops ground bodies to isolate their cost.
	var skip_ground := OS.get_environment("NO_GROUND_COLL") == "1"
	if skip_ground:
		print("REGION_NOGROUND diagnostic: ground collision skipped")
	var gi := 0
	for g in (_grounds if not skip_ground else []):
		var gname := "GroundCollision" if gi == 0 else "GroundCollision%d" % gi
		if use_heightmap_ground:
			_add_heightmap_body(g, gname)
		else:
			_add_trimesh_body(g, gname, layer_ground)
		gi += 1
	phase = _load_phase("collision.ground", phase)
	for mi in _solids:
		# Decorative props are collision cost with no gameplay value: every rock
		# and stump is another trimesh the capsule tests against.  Bridge decks
		# are rebuilt separately as layer-1 Walkable_ bodies, so nothing that
		# matters is lost here.
		if skip_prop_collision and String(mi.name).contains("Props"):
			_prop_bodies_skipped += 1
			continue
		_add_classified_bodies(mi)
		phase = _load_phase("collision.solid.%s" % mi.name, phase)
	for mi in _others:
		# A mesh marked walkable is deliberately not "solid", but it still needs a
		# floor body or the player falls through it.  Everything else in the
		# others list stays decoration.
		if walkable_meshes.has(String(mi.name)):
			_add_classified_bodies(mi)
			phase = _load_phase("collision.walkable.%s" % mi.name, phase)
			continue
		print("REGION_COLLISION %s skipped (non-solid)" % mi.name)

	print("REGION_PROPS skipped=%d" % _prop_bodies_skipped)
	phase = _load_phase("collision.decor", phase)
	_add_bridge_bodies()
	_load_phase("collision.bridges", phase)


## Split one merged mesh into collision bodies by role.  Each primitive carries
## its own material, so this is the only handle on "which part is a flower and
## which is a wall" once Blender has joined the collection.
func _add_classified_bodies(mi: MeshInstance3D) -> void:
	var buckets := {}
	var decor: Array[String] = []
	var walk_mats: Array[String] = []
	var force_walk := walkable_meshes.has(String(mi.name))
	for s in mi.mesh.get_surface_count():
		var mat := mi.mesh.surface_get_material(s)
		var mname := String(mat.resource_name) if mat != null else ""
		var role := ROLE_WALKABLE if force_walk else _role_for(mname)
		if role == ROLE_DECOR:
			if mname not in decor:
				decor.append(mname)
			continue
		var faces := _surface_faces(mi, s)
		if faces.is_empty():
			continue
		if not _deck_boxes.is_empty():
			faces = _strip_faces_on_decks(faces)
		# Low geometry is a step, not a wall: the player's step-up reaches
		# 0.45 m, so anything under low_walkable_height has to be climbable or
		# stairs become knee-high fences.
		#
		# The height test must run per connected region, not per material.
		# M_prop_stone spans 6 m because it covers both a tall ruin and the flat
		# stone landing at the bridge end; judging the whole surface by its tallest
		# point made the landing solid and trapped the player on the deck.
		if role == ROLE_SOLID and _is_low_walkable_material(mname) \
				and _faces_height(faces) > low_walkable_height:
			var islands := _face_islands(faces)
			if islands.is_empty():
				# Splitting failed: fall back to whole-surface classification
				# rather than dropping the geometry out of collision entirely.
				if not buckets.has(role):
					buckets[role] = PackedVector3Array()
				buckets[role].append_array(faces)
				continue
			for island in islands:
				var island_role := role
				if _faces_height(island) <= low_walkable_height:
					island_role = ROLE_WALKABLE
				if island_role == ROLE_WALKABLE and force_walk:
					island = _walk_faces(island)
					if island.is_empty():
						continue
					if mname not in walk_mats:
						walk_mats.append(mname)
				if not buckets.has(island_role):
					buckets[island_role] = PackedVector3Array()
				buckets[island_role].append_array(island)
			continue
		if role == ROLE_WALKABLE and force_walk:
			faces = _walk_faces(faces)
			if faces.is_empty():
				continue
			if mname not in walk_mats:
				walk_mats.append(mname)
		if not buckets.has(role):
			buckets[role] = PackedVector3Array()
		buckets[role].append_array(faces)
	for role in buckets:
		var faces: PackedVector3Array = buckets[role]
		if faces.is_empty():
			continue
		var body_name := "Walkable_%s" % mi.name if role == ROLE_WALKABLE else "Solid_%s" % mi.name
		_add_body_from_faces(faces, body_name, int(role))
	if not decor.is_empty():
		print("REGION_DECOR %s no collision on %s" % [mi.name, str(decor)])
	if not walk_mats.is_empty():
		print("REGION_WALKABLE %s as ground: %s" % [mi.name, str(walk_mats)])


const ROLE_DECOR := 0
const ROLE_WALKABLE := 1
const ROLE_SOLID := 2


## Keep only the faces a player can actually stand on.
##
## A bridge mesh carries its deck, its railings and its arch in one surface, and
## marking the whole mesh walkable turned every railing into level-1 collision.
## The capsule then collided with rails at chest height and stopped dead in the
## middle of the deck -- the "stuck on the bridge" bug.  Steep faces are railing
## and arch sides, so they are dropped from the walkable body only; the visual
## mesh is untouched.
func _walk_faces(faces: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var i := 0
	while i + 2 < faces.size():
		var a: Vector3 = faces[i]
		var b: Vector3 = faces[i + 1]
		var c: Vector3 = faces[i + 2]
		var n := (b - a).cross(c - a)
		if n.length_squared() > 1.0e-12 and n.normalized().y > 0.55:
			out.append(a)
			out.append(b)
			out.append(c)
		i += 3
	return out


func _role_for(mname: String) -> int:
	var low := mname.to_lower()
	for p in force_solid_patterns:
		var pat := String(p).to_lower()
		if not pat.is_empty() and low.contains(pat):
			return ROLE_SOLID
	for p in walkable_patterns:
		var pat := String(p).to_lower()
		if not pat.is_empty() and low.contains(pat):
			return ROLE_WALKABLE
	for p in decor_patterns:
		var pat := String(p).to_lower()
		if not pat.is_empty() and low.contains(pat):
			return ROLE_DECOR
	return ROLE_SOLID


## World-space centres of the bridge deck ends, used to push vegetation aside.
##
## The decks are diagonal, so the AABB centre is not on the bridge; taking the
## two opposite corners of the deck AABB and snapping each to the nearest deck
## vertex gives points that are actually at the bridge landings.
func _bridge_clear_points(node: Node) -> Array:
	var pts := []
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(si)
			var nm := String(m.resource_name).to_lower() if m != null else ""
			if not nm.contains("bridge_plank"):
				continue
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if vs.is_empty():
				continue
			var xf := mi.global_transform
			var min_c := Vector3.INF
			var max_c := -Vector3.INF
			for v in vs:
				var w := xf * v
				min_c.x = minf(min_c.x, w.x); min_c.y = minf(min_c.y, w.y); min_c.z = minf(min_c.z, w.z)
				max_c.x = maxf(max_c.x, w.x); max_c.y = maxf(max_c.y, w.y); max_c.z = maxf(max_c.z, w.z)
			# Pick the deck vertices nearest the two opposite corners.
			var corner_a := Vector3(min_c.x, min_c.y, min_c.z)
			var corner_b := Vector3(max_c.x, min_c.y, max_c.z)
			var best_a := corner_a
			var best_b := corner_b
			var best_da := INF
			var best_db := INF
			for v in vs:
				var w := xf * v
				var da := Vector2(w.x - corner_a.x, w.z - corner_a.z).length()
				var db := Vector2(w.x - corner_b.x, w.z - corner_b.z).length()
				if da < best_da: best_da = da; best_a = w
				if db < best_db: best_db = db; best_b = w
			pts.append(best_a)
			pts.append(best_b)
	return pts


## Split a triangle soup into connected islands.
##
## Vertices are keyed by rounded position rather than by index, because the glTF
## exporter splits vertices at UV and normal seams, so a surface that is one
## piece of geometry still shares no indices along those seams.  Without merging
## by position the landing would shatter into hundreds of fragments.
func _face_islands(faces: PackedVector3Array) -> Array:
	var parent := {}
	var find := func(a: String) -> String:
		while parent.has(a) and String(parent[a]) != a:
			parent[a] = parent[String(parent[a])]
			a = String(parent[a])
		return a
	# Union by rounding to 1 cm.
	for i in range(0, faces.size() - 2, 3):
		var keys := []
		for k in 3:
			var v := faces[i + k]
			keys.append("%d,%d,%d" % [roundi(v.x * 100.0), roundi(v.y * 100.0), roundi(v.z * 100.0)])
		for k in 3:
			if not parent.has(keys[k]):
				parent[keys[k]] = keys[k]
		for k in [1, 2]:
			var ra: String = find.call(keys[0])
			var rb: String = find.call(keys[k])
			if ra != rb:
				parent[rb] = ra
	# Group triangles by island root.
	var groups := {}
	for i in range(0, faces.size() - 2, 3):
		var v := faces[i]
		var key := "%d,%d,%d" % [roundi(v.x * 100.0), roundi(v.y * 100.0), roundi(v.z * 100.0)]
		var r: String = find.call(key)
		if not groups.has(r):
			groups[r] = PackedVector3Array()
		var g: PackedVector3Array = groups[r]
		g.append(faces[i]); g.append(faces[i + 1]); g.append(faces[i + 2])
		groups[r] = g
	var out := []
	for r in groups:
		out.append(groups[r])
	return out


func _is_low_walkable_material(mname: String) -> bool:
	var low := mname.to_lower()
	for p in low_walkable_materials:
		var pat := String(p).to_lower()
		if not pat.is_empty() and low.contains(pat):
			return true
	return false


func _faces_height(faces: PackedVector3Array) -> float:
	if faces.is_empty():
		return 0.0
	var lo := faces[0].y
	var hi := lo
	for v in faces:
		lo = minf(lo, v.y)
		hi = maxf(hi, v.y)
	return hi - lo


## World-space triangle soup for one surface of a mesh.
func _surface_faces(mi: MeshInstance3D, surf: int) -> PackedVector3Array:
	var arr := mi.mesh.surface_get_arrays(surf)
	if arr.is_empty():
		return PackedVector3Array()
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	if vs.is_empty():
		return PackedVector3Array()
	var idx = arr[Mesh.ARRAY_INDEX]
	var xf := mi.global_transform
	var count: int = vs.size() if idx == null else idx.size()
	count -= count % 3
	var out := PackedVector3Array()
	out.resize(count)
	for k in count:
		out[k] = xf * vs[k if idx == null else idx[k]]
	return out


## Give bridge decks their own floor collision.
##
## A bridge is a prop, and props stay decoration, so the deck had no collider at
## all: a click ray fell through it into the river and was refused as water, and
## the baker had no surface to cross.  The planks are identified by material
## rather than by guessing from geometry, and only up-facing faces are kept so
## the rails do not become a wall down the middle of the walkway.
func _add_bridge_bodies() -> void:
	if bridge_patterns.is_empty():
		return
	var added := 0
	for n in find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var tris := PackedVector3Array()
		for si in mi.mesh.get_surface_count():
			var mm := mi.mesh.surface_get_material(si)
			var nm := String(mm.resource_name).to_lower() if mm != null else ""
			if nm.is_empty() or not _pattern_hit(nm, bridge_patterns):
				continue
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx = arr[Mesh.ARRAY_INDEX]
			var xf := mi.global_transform
			var tri_n: int = vs.size() / 3 if idx == null else idx.size() / 3
			for t in tri_n:
				var i0: int = t * 3
				var ia: int = i0 if idx == null else int(idx[i0])
				var ib: int = (i0 + 1) if idx == null else int(idx[i0 + 1])
				var ic: int = (i0 + 2) if idx == null else int(idx[i0 + 2])
				if ia >= vs.size() or ib >= vs.size() or ic >= vs.size():
					continue
				tris.append(xf * vs[ia])
				tris.append(xf * vs[ib])
				tris.append(xf * vs[ic])
		if tris.is_empty():
			continue
		var deck := _walk_faces(tris)
		if deck.size() < 9:
			continue
		_add_body_from_faces(deck, "Walkable_Bridge_%s" % String(mi.name), layer_ground)
		added += 1
	if added > 0:
		print("REGION_BRIDGE_COLLISION bodies=%d" % added)


## Split triangles into spatial tiles so the physics broadphase can reject most
## of a merged mesh.  A continent-sized concave shape defeats broadphase culling:
## its AABB always overlaps the player, so every query walks the whole BVH.
func _chunk_faces(faces: PackedVector3Array) -> Dictionary:
	var buckets := {}
	if collision_tile <= 0.0:
		buckets[Vector2i.ZERO] = faces
		return buckets
	var i := 0
	while i + 2 < faces.size():
		var c := (faces[i] + faces[i + 1] + faces[i + 2]) / 3.0
		var key := Vector2i(int(floor(c.x / collision_tile)), int(floor(c.z / collision_tile)))
		if not buckets.has(key):
			buckets[key] = PackedVector3Array()
		buckets[key].append(faces[i])
		buckets[key].append(faces[i + 1])
		buckets[key].append(faces[i + 2])
		i += 3
	return buckets


func _make_body(faces: PackedVector3Array, body_name: String, layer: int) -> void:
	var sh := ConcavePolygonShape3D.new()
	sh.set_faces(faces)
	# Authored meshes carry mixed winding, so a surface can face downward and
	# ConcavePolygonShape3D ignores backfaces by default.
	sh.backface_collision = false
	var body := StaticBody3D.new()
	body.name = body_name
	body.collision_layer = layer
	body.collision_mask = 0
	add_child(body)
	var cs := CollisionShape3D.new()
	cs.shape = sh
	body.add_child(cs)


func _add_body_from_faces(faces: PackedVector3Array, body_name: String, layer: int) -> void:
	var buckets := _chunk_faces(faces)
	var n := 0
	for key in buckets:
		var b: PackedVector3Array = buckets[key]
		_make_body(b, "%s_t%d_%d" % [body_name, key.x, key.y], layer)
		n += 1
	print("REGION_COLLISION %s layer=%d tris=%d tiles=%d" % [
		body_name, layer, faces.size() / 3, n])


func _add_trimesh_body(mi: MeshInstance3D, body_name: String, layer: int) -> void:
	var sh := mi.mesh.create_trimesh_shape()
	if sh == null:
		push_error("region_map: %s could not build a trimesh shape" % body_name)
		return
	var faces := sh.get_faces()
	# Chunking bakes world space, so the tiles carry no transform of their own.
	var xf := mi.global_transform
	if xf != Transform3D.IDENTITY:
		for i in faces.size():
			faces[i] = xf * faces[i]
	var buckets := _chunk_faces(faces)
	var n := 0
	for key in buckets:
		var b: PackedVector3Array = buckets[key]
		var body := StaticBody3D.new()
		body.name = "%s_t%d_%d" % [body_name, key.x, key.y]
		body.collision_layer = layer
		body.collision_mask = 0
		if layer == layer_ground:
			body.set_script(load("res://scripts/town_terrain_collision.gd"))
		add_child(body)
		var cs := CollisionShape3D.new()
		var csh := ConcavePolygonShape3D.new()
		csh.set_faces(b)
		csh.backface_collision = false
		cs.shape = csh
		body.add_child(cs)
		n += 1
	print("REGION_COLLISION %s layer=%d tris=%d tiles=%d" % [
		body_name, layer, faces.size() / 3, n])


## Spiral outward from spawn_center for ground with no solid geometry in a
## head-height cylinder above it.
func _find_spawn() -> void:
	var step := 1.5
	var rings := int(spawn_search_radius / step)
	for r in range(0, rings):
		var steps := 1 if r == 0 else maxi(6, int(float(r) * 2.2))
		for k in steps:
			var a := float(k) / float(steps) * TAU
			var p := spawn_center + Vector2(cos(a), sin(a)) * (float(r) * step)
			var gy := _ground_height(p.x, p.y)
			if is_nan(gy):
				continue
			# Reject if anything solid sits over this spot (roof, canopy, prop).
			if _blocked_above(p, gy):
				continue
			# Reject if a mask-3 ray (what the player actually uses) disagrees
			# with the ground-only ray: that means something else is on top.
			if not is_equal_approx(_ray_y(p.x, p.y, layer_ground | layer_solid), gy):
				continue
			spawn_xz = p
			print("REGION_SPAWN %s at %s ground=%.3f radius=%.1f" % [
				region_id, str(p), gy, float(r) * step])
			return
	push_warning("region_map: no clear spawn in %s; using centre" % region_id)
	spawn_xz = spawn_center


func _blocked_above(p: Vector2, gy: float) -> bool:
	# Cast from well above the tallest building, not just head height.  A roof
	# over the spawn is invisible to a 1.9 m probe, and the player's own ray
	# (mask 3) then lands on that roof instead of the street.
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(p.x, gy + 20.0, p.y), Vector3(p.x, gy + 0.15, p.y), layer_solid)
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## Raycast down onto the ground collision.  NAN when nothing is hit.
func _ray_y(x: float, z: float, mask: int) -> float:
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(x, 400.0, z), Vector3(x, -400.0, z), mask)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return float(hit["position"].y) if not hit.is_empty() else NAN


func _ground_height(x: float, z: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(x, 400.0, z), Vector3(x, -400.0, z), layer_ground)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return float(hit["position"].y) if not hit.is_empty() else NAN


func _report() -> void:
	var all: Array[MeshInstance3D] = []
	if _ground != null:
		all.append(_ground)
	all.append_array(_solids)
	all.append_array(_others)
	var polys := 0
	for mi in all:
		# _hide_meshes detaches nodes after classification, so the cached lists
		# can still hold them; touching a freed instance is a hard error.
		if not is_instance_valid(mi) or mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			polys += mi.mesh.surface_get_array_len(s) / 3
	print("REGION_MAP id=%s meshes=%d polys~%d bounds=%s spawn=%s" % [
		region_id, all.size(), polys, _bounds(), spawn_point()])


func _bounds() -> AABB:
	var all: Array[MeshInstance3D] = []
	if _ground != null:
		all.append(_ground)
	all.append_array(_solids)
	all.append_array(_others)
	var out := AABB()
	var first := true
	for mi in all:
		if not is_instance_valid(mi) or mi.mesh == null:
			continue
		var a: AABB = mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


## Load the standalone navmesh file, if the map declares one.
func _load_nav_markers() -> void:
	if String(nav_glb_path).is_empty():
		return
	var packed = preload("res://scripts/glb_util.gd").instantiate_raw(nav_glb_path)
	if packed == null:
		push_error("region_map: cannot load nav glb %s" % nav_glb_path)
		return
	var n := packed as Node3D
	n.name = "NavMarkers"
	add_child(n)
	_hide_nav_markers(n)
	print("REGION_NAVGLB %s" % nav_glb_path)


## Boxes covering every bridge deck triangle, so props lying on a deck can be
## told apart from the deck itself.
var _deck_boxes: Array = []
var _deck_box_index := preload("res://scripts/deck_box_index.gd").new()


## Record the deck surface for every plank-material triangle on the map.
func _collect_deck_boxes() -> void:
	_deck_boxes.clear()
	var meshes: Array = _solids.duplicate()
	for m in _others:
		meshes.append(m)
	for mi in meshes:
		var mesh_i := mi as MeshInstance3D
		if mesh_i == null or mesh_i.mesh == null:
			continue
		for s in mesh_i.mesh.get_surface_count():
			var mat := mesh_i.mesh.surface_get_material(s)
			var mn := String(mat.resource_name).to_lower() if mat != null else ""
			if not (mn.contains("plank") or mn.contains("bridge")):
				continue
			var fs := _surface_faces(mesh_i, s)
			for k in range(0, fs.size() - 2, 3):
				var a: Vector3 = fs[k]
				var b: Vector3 = fs[k + 1]
				var c: Vector3 = fs[k + 2]
				_deck_boxes.append([
					minf(a.x, minf(b.x, c.x)) - 0.8, maxf(a.x, maxf(b.x, c.x)) + 0.8,
					minf(a.z, minf(b.z, c.z)) - 0.8, maxf(a.z, maxf(b.z, c.z)) + 0.8,
					minf(a.y, minf(b.y, c.y)) - 0.15,
					maxf(a.y, maxf(b.y, c.y)) + 1.6])
	_deck_box_index.build(_deck_boxes)
	print("REGION_DECKS boxes=%d cells=%d fallback=%d" % [
		_deck_boxes.size(), _deck_box_index.cell_count(), _deck_box_index.fallback_count()])


## Drop triangles that lie inside a deck box: a boulder dumped across a bridge
## end is scenery, but as collision it walls off the deck the player is standing
## on -- which is why the bridge could be entered but never left.
func _strip_faces_on_decks(faces: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var dropped := 0
	for k in range(0, faces.size() - 2, 3):
		var a: Vector3 = faces[k]
		var b: Vector3 = faces[k + 1]
		var c: Vector3 = faces[k + 2]
		var cx := (a.x + b.x + c.x) / 3.0
		var cy := (a.y + b.y + c.y) / 3.0
		var cz := (a.z + b.z + c.z) / 3.0
		if _deck_box_index.contains(cx, cy, cz):
			dropped += 1
			continue
		out.append(a); out.append(b); out.append(c)
	if dropped > 0:
		print("REGION_DECK_STRIP faces=%d" % dropped)
	return out


## Hide foliage at load for framerate A/B tests.
##
## Run with --hideveg (or HIDE_VEG=1 in the environment) to strip the vegetation
## meshes from view without touching the asset.  Kept as a diagnostic: if the
## frame cost collapses without it, the foliage is the bottleneck.
func _maybe_hide_vegetation(node: Node) -> void:
	var args := OS.get_cmdline_user_args()
	var hide_veg := args.has("--noveg") or args.has("--hideveg") or OS.get_environment("HIDE_VEG") == "1"
	var hide_decor := args.has("--nodecor")
	if not (hide_veg or hide_decor):
		return
	var n := 0
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var nm := String((mi as Node).name)
		var hit := (hide_veg and nm.contains("Vegetation")) \
				or (hide_decor and (nm.contains("Props") or nm.contains("Vegetation")))
		if hit:
			(mi as MeshInstance3D).visible = false
			n += 1
	print("REGION_HIDEVEG hidden=%d decor=%s" % [n, str(hide_decor)])

func _tri_height(p: Vector2, a: Vector3, b: Vector3, c: Vector3) -> float:
	var pa := Vector2(a.x, a.z)
	var pb := Vector2(b.x, b.z)
	var pc := Vector2(c.x, c.z)
	var d1 := (pb - pa).cross(p - pa)
	var d2 := (pc - pb).cross(p - pb)
	var d3 := (pa - pc).cross(p - pc)
	var has_neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	if has_neg and has_pos:
		return NAN
	var area := (pb - pa).cross(pc - pa)
	if absf(area) < 1e-9:
		return maxf(a.y, maxf(b.y, c.y))
	var w0 := (pb - p).cross(pc - p) / area
	var w1 := (pc - p).cross(pa - p) / area
	var w2 := 1.0 - w0 - w1
	return w0 * a.y + w1 * b.y + w2 * c.y


func _add_heightmap_body(mi: MeshInstance3D, body_name: String) -> void:
	var sh := mi.mesh.create_trimesh_shape()
	if sh == null:
		push_error("region_map: %s could not build a trimesh shape" % body_name)
		return
	var faces := sh.get_faces()
	var xf := mi.global_transform
	if xf != Transform3D.IDENTITY:
		for i in faces.size():
			faces[i] = xf * faces[i]
	var minp := Vector3(INF, INF, INF)
	var maxp := Vector3(-INF, -INF, -INF)
	for v in faces:
		minp = minp.min(v)
		maxp = maxp.max(v)
	var step := maxf(heightmap_step, 0.25)
	var w := int(ceil((maxp.x - minp.x) / step)) + 1
	var d := int(ceil((maxp.z - minp.z) / step)) + 1
	if w < 2 or d < 2:
		push_error("region_map: heightmap for %s too small" % body_name)
		return
	var data := PackedFloat32Array()
	data.resize(w * d)
	data.fill(NAN)
	var i := 0
	while i + 2 < faces.size():
		var a := faces[i]
		var b := faces[i + 1]
		var c := faces[i + 2]
		var lo := Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z)))
		var hi := Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z)))
		var x0 := clampi(int(floor((lo.x - minp.x) / step)), 0, w - 1)
		var x1 := clampi(int(ceil((hi.x - minp.x) / step)), 0, w - 1)
		var z0 := clampi(int(floor((lo.y - minp.z) / step)), 0, d - 1)
		var z1 := clampi(int(ceil((hi.y - minp.z) / step)), 0, d - 1)
		for zi in range(z0, z1 + 1):
			for xi in range(x0, x1 + 1):
				var p := Vector2(minp.x + xi * step, minp.z + zi * step)
				var h := _tri_height(p, a, b, c)
				if is_nan(h):
					continue
				var idx := xi + zi * w
				if is_nan(data[idx]) or h > data[idx]:
					data[idx] = h
		i += 3
	# Fill holes from neighbours so unfilled cells do not become pits.
	var have := 0
	for k in data.size():
		if not is_nan(data[k]):
			have += 1
	for _pass in 6:
		var copy := data.duplicate()
		for zi in d:
			for xi in w:
				var idx := xi + zi * w
				if not is_nan(copy[idx]):
					continue
				var sum := 0.0
				var n := 0
				for dz in [-1, 0, 1]:
					for dx in [-1, 0, 1]:
						var nx: int = xi + int(dx)
						var nz: int = zi + int(dz)
						if nx < 0 or nz < 0 or nx >= w or nz >= d:
							continue
						var v := copy[nx + nz * w]
						if not is_nan(v):
							sum += v
							n += 1
				if n > 0:
					data[idx] = sum / float(n)
	var fallback := minp.y
	for k in data.size():
		if is_nan(data[k]):
			data[k] = fallback
	var body := StaticBody3D.new()
	body.name = body_name
	body.collision_layer = layer_ground
	body.collision_mask = 0
	body.set_script(load("res://scripts/town_terrain_collision.gd"))
	body.position = Vector3(minp.x + (w - 1) * step * 0.5, 0.0, minp.z + (d - 1) * step * 0.5)
	add_child(body)
	var hshape := HeightMapShape3D.new()
	hshape.map_width = w
	hshape.map_depth = d
	hshape.map_data = data
	var cs := CollisionShape3D.new()
	cs.shape = hshape
	body.add_child(cs)
	print("REGION_HEIGHTMAP %s w=%d d=%d step=%.2f cells=%d filled=%d" % [
		body_name, w, d, step, w * d, have])


## Attach the artist's extra layers under RegionWorld.
func _attach_extra_layers(node: Node3D) -> void:
	if extra_glb_paths.is_empty():
		return
	var util := preload("res://scripts/glb_util.gd")
	var added := 0
	for path in extra_glb_paths:
		var p := String(path)
		if p.is_empty():
			continue
		var layer := util.instantiate_raw(p)
		if layer == null:
			push_warning("region_map: extra layer failed to load: %s" % p)
			continue
		var n3 := layer as Node3D
		if n3 == null:
			push_warning("region_map: extra layer is not 3D: %s" % p)
			continue
		n3.name = p.get_file().get_basename()
		node.add_child(n3)
		var mc := 0
		for _m in n3.find_children("*", "MeshInstance3D", true, false):
			mc += 1
		print("REGION_LAYER %s meshes=%d" % [n3.name, mc])
		added += 1
	print("REGION_LAYERS attached=%d (+base) paths=%s" % [added, str(extra_glb_paths)])
