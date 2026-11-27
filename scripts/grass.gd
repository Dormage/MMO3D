extends Node
## Grass - slope-aware grass cards on the terrain, one MultiMesh per island.
##
## Autoload, and also callable by the scene builder:
##
##     Grass.build(map_node)          # idempotent, returns the clump count
##     Grass.clear_grass()            # removes what this node built
##
## It reads the *rendered terrain mesh* (assets/terrain.glb) for heights rather
## than re-implementing tools/ground.py, so grass can never disagree with the
## ground it grows on. A 0.5 m height field is rasterised once from the top
## triangles; slope, patch noise, pond margins and cliff margins decide where a
## clump may sit. Everything tunable is an export.
##
## One MultiMesh per island is deliberate: multi-pass shadows and frustum
## culling work per instance batch, and 19 draw calls for ~20k clumps is cheap.

const LAYOUT := "res://map_layout.json"
const PATH_MASK := "res://assets/textures/terrain_path_mask.png"
const CAPS_JSON := "res://assets/terrain_void_caps.json"
const ZONES_JSON := "res://assets/zones.json"
var W := 96
var H := 96
## World half-extent, derived from the layout width.  This used to be a
## hard-coded 48.0 for the old 96 m map; the current map is 163 m, so every
## land-mask lookup and height sample was shifted by 33.5 m.
var HALF := 48.0
const GRID_STEP := 0.5
var GRID_N := 193              # map_m / GRID_STEP + 1, set from the layout
const GRASS_SHADER := "res://shaders/grass.gdshader"

@export_group("Autobuild")
## Autoload behaviour: wait for the scene's Terrain node, then build once.
## Set false if the scene builder calls build() itself.
@export var autobuild: bool = true
@export var verbose: bool = true

@export_group("Density")
## Clumps per square metre on flat, open ground before slope/patch weighting.
## A clump is two crossed cards ~0.7 m wide; 6/m2 reads as turf at eye level.
@export_range(0.0, 24.0, 0.1) var density_per_m2: float = 10.0
## Above slope_start grass thins; by slope_end it is gone and rock shows.
@export_range(0.0, 89.0, 0.1) var slope_start_deg: float = 32.0
@export_range(0.0, 89.0, 0.1) var slope_end_deg: float = 52.0
## 0..1: how much low-frequency patchiness modulates density.
@export_range(0.0, 1.0, 0.01) var patch_contrast: float = 0.78
@export_range(0.01, 1.0, 0.001) var patch_frequency: float = 0.32
## Keep grass at least this many 1 m cells away from a pond edge.
@export_range(0, 3, 1) var water_margin_cells: int = 1
## And this many cells away from the island lip, so nothing floats off a cliff.
@export_range(0, 3, 1) var cliff_margin_cells: int = 1
## Hard budget. If the density would exceed it, every island is thinned by the
## same factor, so the look stays uniform and the frame cost stays bounded.
@export_range(1000, 200000, 500) var max_clumps_total: int = 56000

@export_group("Cards")
@export_range(0.2, 2.0, 0.01) var clump_height_min: float = 0.45
@export_range(0.2, 3.0, 0.01) var clump_height_max: float = 0.75
@export_range(0.2, 2.0, 0.01) var clump_width_min: float = 0.90
@export_range(0.2, 2.0, 0.01) var clump_width_max: float = 1.30
## How far the clump leans with the slope normal. 0 = always vertical.
@export_range(0.0, 1.0, 0.01) var slope_tilt: float = 0.55
## Roots are sunk this far so a 0.5 m height-field sample never shows a gap.
@export_range(0.0, 0.2, 0.001) var sink: float = 0.035
@export var random_seed: int = 90210
## Cards casting shadows doubles their cost; off by default, SSAO/contact
## reads well enough at eye level.
@export var cast_shadows: bool = false

@export_group("Card look")
@export var tint_a: Color = Color(0.60, 0.68, 0.42)
@export var tint_b: Color = Color(0.84, 0.91, 0.58)
@export var wind_strength: float = 0.10
@export var wind_speed: float = 1.35
@export var fade_start: float = 30.0
@export var fade_end: float = 65.0
## Alpha cutout.  The 512 px card is mostly transparent; after mipmapping its
## mean alpha is ~0.04, so the old 0.10 cutout discarded every distant blade.
@export var alpha_scissor: float = 0.010
@export var texture_size: int = 512
@export var blade_count: int = 34

var _built: bool = false
var _path_img: Image
var _path_tex: Texture2D
var _cap_polys: Array = []
var _caps_loaded := false
var _building: bool = false
var _map: Node3D
var _root: Node3D
var _clumps: int = 0
var _islands: int = 0
var _mesh: ArrayMesh
var _material: ShaderMaterial
var _layout: Dictionary
var _land: Dictionary
var _water: Dictionary
var _heights: PackedFloat32Array
var _covered: PackedByteArray
var _noise: FastNoiseLite
var _coverage: float = 0.0
var _ground_clumps: int = 0
var _ground_tris: int = 0
const SPAWN_XZ := Vector2(-2.0, 26.0)
var _building_rects: Array[Dictionary] = []
var _zone_dryness: Dictionary = {}
var _island_zone: Dictionary = {}
var _island_dryness: PackedFloat32Array = PackedFloat32Array()
var _wear_pts: Array[Vector4] = []


func _ready() -> void:
	if autobuild:
		set_process(true)
	else:
		set_process(false)


func _process(_delta: float) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	if not scene.has_node("Terrain"):
		# The terrain is built under Game/Map by map.gd, not as a direct child
		# of the current scene.  The old relative check was always false here,
		# so grass returned silently on every boot and never scattered.
		var t := scene.find_child("Terrain", true, false)
		if t == null:
			return
		scene = t.get_parent() if t.get_parent() != null else scene
	set_process(false)
	# Let map.gd finish its _ready (water, props, bridges) before we scatter.
	call_deferred("_deferred_build", scene)


func _deferred_build(scene: Node) -> void:
	if OS.get_environment("GRASS_SYNC") == "1":
		build(scene)
	else:
		await build_async(scene)


## Build the grass layer under `map_node`. Safe to call more than once; the
## second call is a no-op and returns the existing clump count.
func build(map_node: Node) -> int:
	if OS.get_environment("GRASS_DISABLE") == "1":
		_built = true
		print("grass: disabled for comparison")
		return 0
	if _built:
		return _clumps
	if _building:
		return _clumps
	if map_node == null or not is_instance_valid(map_node):
		push_warning("grass: no map node")
		return 0
	_building = true
	var t0 := Time.get_ticks_msec()
	_map = map_node as Node3D
	_layout = _read_json(LAYOUT)
	if _layout.is_empty():
		_building = false
		return 0
	_load_zone_dryness()
	_build_wear_points()
	# the grid is not 96 any more: read it, or every cell index is wrong
	var meta: Dictionary = _layout.get("meta", {})
	W = int(meta.get("width", 96))
	H = int(meta.get("height", 96))
	HALF = float(W) * 0.5
	GRID_N = int(float(W) / GRID_STEP) + 1
	_land.clear()
	for c in _layout.get("land_mask", []):
		_land[int(c)] = true
	_water.clear()
	for c in _layout.get("water_mask", []):
		_water[int(c)] = true
	_collect_building_rects(map_node)

	var terrain: Node3D = _map.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		push_warning("grass: no Terrain node")
		_building = false
		return 0
	var mesh_instances := terrain.find_children("*", "MeshInstance3D", true, false)
	if mesh_instances.is_empty():
		push_warning("grass: Terrain has no mesh")
		_building = false
		return 0

	var t_height := Time.get_ticks_msec()
	_build_height_field(mesh_instances)
	print("grass timing: heightfield=%d ms" % (Time.get_ticks_msec() - t_height))
	_noise = FastNoiseLite.new()
	_noise.seed = random_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = patch_frequency
	_noise.fractal_octaves = 3
	_noise.fractal_gain = 0.5

	var t_comp := Time.get_ticks_msec()
	var islands := _components()
	print("grass timing: components=%d ms" % (Time.get_ticks_msec() - t_comp))
	_island_dryness = PackedFloat32Array()
	for cells in islands:
		_island_dryness.append(_island_dryness_for(cells))
	# Pass 1: expected clumps before the budget, so pass 2 can scale uniformly.
	var weights: Array[float] = []
	var total_weight := 0.0
	for cells in islands:
		var w := _island_weight(cells)
		weights.append(w)
		total_weight += w
	var keep := 1.0
	if total_weight * density_per_m2 > float(max_clumps_total):
		keep = float(max_clumps_total) / (total_weight * density_per_m2)

	_clear_grass_only()
	_root = Node3D.new()
	_root.name = "Grass"
	_map.add_child(_root)
	var t_cards := Time.get_ticks_msec()
	_mesh = _make_card_mesh()
	_material = _make_material()
	print("grass timing: cards+texture=%d ms" % (Time.get_ticks_msec() - t_cards))
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	var tris := 0
	var islands_since_yield := 0
	for i in range(islands.size()):
		var cells: Array = islands[i]
		var xforms: Array[Transform3D] = []
		var customs: Array[Color] = []
		_scatter_island(i, cells, keep, xforms, customs, _island_dryness[i])
		if xforms.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = _mesh
		mm.instance_count = xforms.size()
		var aabb := AABB(xforms[0].origin, Vector3.ZERO)
		for k in range(xforms.size()):
			mm.set_instance_transform(k, xforms[k])
			mm.set_instance_custom_data(k, customs[k])
			aabb = aabb.expand(xforms[k].origin)
			aabb = aabb.expand(xforms[k].origin + Vector3(0.0,
					clump_height_max * 1.2, 0.0))
		aabb = aabb.grow(1.5)
		mm.custom_aabb = aabb
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "GrassIsland%02d" % i
		mmi.multimesh = mm
		mmi.material_override = _material
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED \
				if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Keep ~20k cards out of the SDFGI voxelisation; they still receive it.
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_root.add_child(mmi)
		_clumps += xforms.size()
		tris += xforms.size() * 4
		_islands += 1

	# The spawn hill can fall inside a patch/margin hole even when it is
	# visibly turf.  Seed a deterministic near ring so the first 5 m always
	# has real cards, not just the terrain texture.
	var near_x: Array[Transform3D] = []
	var near_c: Array[Color] = []
	var nrng := RandomNumberGenerator.new()
	nrng.seed = random_seed + 991
	var step := 0.65
	var r := 5.0
	var q := -r
	while q <= r:
		var qz := -r
		while qz <= r:
			if q * q + qz * qz <= r * r:
				var ci := clampi(int(round(qz + HALF - 0.5)), 0, H - 1) * W \
						+ clampi(int(round(q + HALF - 0.5)), 0, W - 1)
				var h := _height_at(q, qz)
				var f := _turf_fields(q, qz, 0.35)
				if not is_nan(h) and _grassable(ci) and f.worn < 0.82 						and not _inside_building(q, qz):
					var sl := _slope_deg(q, qz)
					if sl < 58.0:
						var hx := _height_at(q + 0.5, qz) - _height_at(q - 0.5, qz)
						var hz := _height_at(q, qz + 0.5) - _height_at(q, qz - 0.5)
						var upn := Vector3(-hx, 1.0, -hz).normalized()
						var upv := Vector3.UP.lerp(upn, slope_tilt).normalized()
						var yaw := nrng.randf() * TAU
						var fwd := Vector3(cos(yaw), 0.0, sin(yaw))
						fwd = (fwd - upv * fwd.dot(upv)).normalized()
						var right := upv.cross(fwd).normalized()
						var hh: float = nrng.randf_range(0.55, 0.85) * float(f.height)
						var ww: float = nrng.randf_range(0.45, 0.68) * clampf(sqrt(float(f.density)), 0.45, 1.2)
						var bs := Basis(right, upv, fwd).scaled(Vector3(ww, hh, ww))
						var jx := nrng.randf_range(-0.28, 0.28)
						var jz := nrng.randf_range(-0.28, 0.28)
						near_x.append(Transform3D(bs, Vector3(q + jx, h - sink, qz + jz)))
						near_c.append(Color(nrng.randf(), nrng.randf(),
								0.6 + nrng.randf() * 0.8, 0.35))
			qz += step
		q += step
	if not near_x.is_empty():
		var nmm := MultiMesh.new()
		nmm.transform_format = MultiMesh.TRANSFORM_3D
		nmm.use_custom_data = true
		nmm.mesh = _mesh
		nmm.instance_count = near_x.size()
		var naabb := AABB(near_x[0].origin, Vector3.ZERO)
		for k in range(near_x.size()):
			nmm.set_instance_transform(k, near_x[k])
			nmm.set_instance_custom_data(k, near_c[k])
			naabb = naabb.expand(near_x[k].origin)
		naabb = naabb.grow(2.0)
		nmm.custom_aabb = naabb
		var nmi := MultiMeshInstance3D.new()
		nmi.name = "GrassNear"
		nmi.multimesh = nmm
		nmi.material_override = _material
		nmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_root.add_child(nmi)
		_clumps += near_x.size()
		tris += near_x.size() * 4

	_build_ground_cover()
	_built = true
	_building = false
	if verbose:
		print("grass: %d islands, %d clumps, %d tris, grid %.0f%% covered, %.0f ms" % [
			_islands, _clumps, tris + _ground_tris, _coverage * 100.0,
			float(Time.get_ticks_msec() - t0)])
		print("grass ground cover: %d clumps, %d tris (total %d)" % [
			_ground_clumps, _ground_tris, tris + _ground_tris])
	return _clumps


func build_async(map_node: Node) -> int:
	if OS.get_environment("GRASS_DISABLE") == "1":
		_built = true
		print("grass: disabled for comparison")
		return 0
	if _built or _building:
		return _clumps
	# One frame with the map already visible; then time-sliced build.
	await get_tree().process_frame
	return await _build_impl_async(map_node)


func _build_impl_async(map_node: Node) -> int:
	if OS.get_environment("GRASS_DISABLE") == "1":
		_built = true
		print("grass: disabled for comparison")
		return 0
	if _built:
		return _clumps
	if _building:
		return _clumps
	if map_node == null or not is_instance_valid(map_node):
		push_warning("grass: no map node")
		return 0
	_building = true
	var t0 := Time.get_ticks_msec()
	_map = map_node as Node3D
	_layout = _read_json(LAYOUT)
	if _layout.is_empty():
		_building = false
		return 0
	_load_zone_dryness()
	_build_wear_points()
	# the grid is not 96 any more: read it, or every cell index is wrong
	var meta: Dictionary = _layout.get("meta", {})
	W = int(meta.get("width", 96))
	H = int(meta.get("height", 96))
	HALF = float(W) * 0.5
	GRID_N = int(float(W) / GRID_STEP) + 1
	_land.clear()
	for c in _layout.get("land_mask", []):
		_land[int(c)] = true
	_water.clear()
	for c in _layout.get("water_mask", []):
		_water[int(c)] = true
	_collect_building_rects(map_node)

	var terrain: Node3D = _map.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		push_warning("grass: no Terrain node")
		_building = false
		return 0
	var mesh_instances := terrain.find_children("*", "MeshInstance3D", true, false)
	if mesh_instances.is_empty():
		push_warning("grass: Terrain has no mesh")
		_building = false
		return 0

	var t_height := Time.get_ticks_msec()
	_build_height_field_staged(mesh_instances)
	print("grass timing: heightfield=%d ms" % (Time.get_ticks_msec() - t_height))
	_noise = FastNoiseLite.new()
	_noise.seed = random_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = patch_frequency
	_noise.fractal_octaves = 3
	_noise.fractal_gain = 0.5

	var t_comp := Time.get_ticks_msec()
	var islands := _components()
	print("grass timing: components=%d ms" % (Time.get_ticks_msec() - t_comp))
	_island_dryness = PackedFloat32Array()
	for cells in islands:
		_island_dryness.append(_island_dryness_for(cells))
	# Pass 1: expected clumps before the budget, so pass 2 can scale uniformly.
	var weights: Array[float] = []
	var total_weight := 0.0
	for cells in islands:
		var w := _island_weight(cells)
		weights.append(w)
		total_weight += w
	var keep := 1.0
	if total_weight * density_per_m2 > float(max_clumps_total):
		keep = float(max_clumps_total) / (total_weight * density_per_m2)

	_clear_grass_only()
	_root = Node3D.new()
	_root.name = "Grass"
	_map.add_child(_root)
	var t_cards := Time.get_ticks_msec()
	_mesh = _make_card_mesh()
	_material = _make_material()
	print("grass timing: cards+texture=%d ms" % (Time.get_ticks_msec() - t_cards))
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	var tris := 0
	var islands_since_yield := 0
	for i in range(islands.size()):
		var cells: Array = islands[i]
		var xforms: Array[Transform3D] = []
		var customs: Array[Color] = []
		_scatter_island(i, cells, keep, xforms, customs, _island_dryness[i])
		islands_since_yield += 1
		if islands_since_yield >= 5:
			islands_since_yield = 0
			await get_tree().process_frame
		if xforms.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = _mesh
		mm.instance_count = xforms.size()
		var aabb := AABB(xforms[0].origin, Vector3.ZERO)
		for k in range(xforms.size()):
			mm.set_instance_transform(k, xforms[k])
			mm.set_instance_custom_data(k, customs[k])
			aabb = aabb.expand(xforms[k].origin)
			aabb = aabb.expand(xforms[k].origin + Vector3(0.0,
					clump_height_max * 1.2, 0.0))
		aabb = aabb.grow(1.5)
		mm.custom_aabb = aabb
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "GrassIsland%02d" % i
		mmi.multimesh = mm
		mmi.material_override = _material
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED \
				if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Keep ~20k cards out of the SDFGI voxelisation; they still receive it.
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_root.add_child(mmi)
		_clumps += xforms.size()
		tris += xforms.size() * 4
		_islands += 1

	# The spawn hill can fall inside a patch/margin hole even when it is
	# visibly turf.  Seed a deterministic near ring so the first 5 m always
	# has real cards, not just the terrain texture.
	var near_x: Array[Transform3D] = []
	var near_c: Array[Color] = []
	var nrng := RandomNumberGenerator.new()
	nrng.seed = random_seed + 991
	var step := 0.65
	var r := 5.0
	var q := -r
	while q <= r:
		var qz := -r
		while qz <= r:
			if q * q + qz * qz <= r * r:
				var ci := clampi(int(round(qz + HALF - 0.5)), 0, H - 1) * W \
						+ clampi(int(round(q + HALF - 0.5)), 0, W - 1)
				var h := _height_at(q, qz)
				var f := _turf_fields(q, qz, 0.35)
				if not is_nan(h) and _grassable(ci) and f.worn < 0.82 						and not _inside_building(q, qz):
					var sl := _slope_deg(q, qz)
					if sl < 58.0:
						var hx := _height_at(q + 0.5, qz) - _height_at(q - 0.5, qz)
						var hz := _height_at(q, qz + 0.5) - _height_at(q, qz - 0.5)
						var upn := Vector3(-hx, 1.0, -hz).normalized()
						var upv := Vector3.UP.lerp(upn, slope_tilt).normalized()
						var yaw := nrng.randf() * TAU
						var fwd := Vector3(cos(yaw), 0.0, sin(yaw))
						fwd = (fwd - upv * fwd.dot(upv)).normalized()
						var right := upv.cross(fwd).normalized()
						var hh: float = nrng.randf_range(0.55, 0.85) * float(f.height)
						var ww: float = nrng.randf_range(0.45, 0.68) * clampf(sqrt(float(f.density)), 0.45, 1.2)
						var bs := Basis(right, upv, fwd).scaled(Vector3(ww, hh, ww))
						var jx := nrng.randf_range(-0.28, 0.28)
						var jz := nrng.randf_range(-0.28, 0.28)
						near_x.append(Transform3D(bs, Vector3(q + jx, h - sink, qz + jz)))
						near_c.append(Color(nrng.randf(), nrng.randf(),
								0.6 + nrng.randf() * 0.8, 0.35))
			qz += step
		q += step
	if not near_x.is_empty():
		var nmm := MultiMesh.new()
		nmm.transform_format = MultiMesh.TRANSFORM_3D
		nmm.use_custom_data = true
		nmm.mesh = _mesh
		nmm.instance_count = near_x.size()
		var naabb := AABB(near_x[0].origin, Vector3.ZERO)
		for k in range(near_x.size()):
			nmm.set_instance_transform(k, near_x[k])
			nmm.set_instance_custom_data(k, near_c[k])
			naabb = naabb.expand(near_x[k].origin)
		naabb = naabb.grow(2.0)
		nmm.custom_aabb = naabb
		var nmi := MultiMeshInstance3D.new()
		nmi.name = "GrassNear"
		nmi.multimesh = nmm
		nmi.material_override = _material
		nmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_root.add_child(nmi)
		_clumps += near_x.size()
		tris += near_x.size() * 4

	_build_ground_cover()
	_built = true
	_building = false
	if verbose:
		print("grass: %d islands, %d clumps, %d tris, grid %.0f%% covered, %.0f ms" % [
			_islands, _clumps, tris + _ground_tris, _coverage * 100.0,
			float(Time.get_ticks_msec() - t0)])
		print("grass ground cover: %d clumps, %d tris (total %d)" % [
			_ground_clumps, _ground_tris, tris + _ground_tris])
	return _clumps


## Remove every MultiMesh this node put under the map.
func clear_grass() -> void:
	_clear_grass_only()
	_clumps = 0
	_islands = 0
	_built = false


func clump_count() -> int:
	return _clumps


func _clear_grass_only() -> void:
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null


# ---------------------------------------------------------------- height field

func _build_height_field(mesh_instances: Array) -> void:
	_heights = PackedFloat32Array()
	_heights.resize(GRID_N * GRID_N)
	_heights.fill(-1.0e20)
	_covered = PackedByteArray()
	_covered.resize(GRID_N * GRID_N)
	_covered.fill(0)

	for node in mesh_instances:
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := mi.global_transform
		for s in range(mi.mesh.get_surface_count()):
			var arrays := mi.mesh.surface_get_arrays(s)
			if arrays.is_empty():
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx = arrays[Mesh.ARRAY_INDEX]
			if idx == null or idx.size() == 0:
				for k in range(0, verts.size() - 2, 3):
					_raster_tri(xf * verts[k], xf * verts[k + 1], xf * verts[k + 2])
			else:
				for k in range(0, idx.size() - 2, 3):
					_raster_tri(xf * verts[idx[k]], xf * verts[idx[k + 1]],
							xf * verts[idx[k + 2]])
	# A 0.5 m grid over 0.33 m triangles should be covered, but pond fringes and
	# exact-edge samples can leave holes. Fill them from covered neighbours so a
	# missing sample does not silently delete a patch of grass.
	for pass_i in range(3):
		var added := 0
		for j in range(1, GRID_N - 1):
			for i in range(1, GRID_N - 1):
				var n := j * GRID_N + i
				if _covered[n] == 1:
					continue
				var sum := 0.0
				var cnt := 0
				for o: int in [-1, 1, -GRID_N, GRID_N]:
					var m := n + o
					if _covered[m] == 1:
						sum += _heights[m]
						cnt += 1
				if cnt > 0:
					_heights[n] = sum / float(cnt)
					_covered[n] = 2          # 2 = filled, not measured
					added += 1
		if added == 0:
			break
	var cov := 0
	for c in _covered:
		if c != 0:
			cov += 1
	_coverage = float(cov) / float(GRID_N * GRID_N)


func _raster_tri(a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (b - a).cross(c - a)
	var nn := n.normalized()
	if absf(nn.y) < 0.18:
		return                       # cliff wall or underside: not a surface
	var minx := minf(a.x, minf(b.x, c.x))
	var maxx := maxf(a.x, maxf(b.x, c.x))
	var minz := minf(a.z, minf(b.z, c.z))
	var maxz := maxf(a.z, maxf(b.z, c.z))
	var i0 := clampi(int(floor((minx + HALF) / GRID_STEP)), 0, GRID_N - 1)
	var i1 := clampi(int(ceil((maxx + HALF) / GRID_STEP)), 0, GRID_N - 1)
	var j0 := clampi(int(floor((minz + HALF) / GRID_STEP)), 0, GRID_N - 1)
	var j1 := clampi(int(ceil((maxz + HALF) / GRID_STEP)), 0, GRID_N - 1)
	if i1 < i0 or j1 < j0:
		return
	var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(d) < 1.0e-9:
		return
	var inv := 1.0 / d
	for j in range(j0, j1 + 1):
		var pz := -HALF + float(j) * GRID_STEP
		for i in range(i0, i1 + 1):
			var px := -HALF + float(i) * GRID_STEP
			var u := ((b.z - c.z) * (px - c.x) + (c.x - b.x) * (pz - c.z)) * inv
			if u < -0.001 or u > 1.001:
				continue
			var v := ((c.z - a.z) * (px - c.x) + (a.x - c.x) * (pz - c.z)) * inv
			if v < -0.001 or v > 1.001:
				continue
			var w := 1.0 - u - v
			if w < -0.001 or w > 1.001:
				continue
			var h := u * a.y + v * b.y + w * c.y
			var k := j * GRID_N + i
			if _covered[k] == 0 or h > _heights[k]:
				_heights[k] = h
				_covered[k] = 1


## Bilinear height at a world position; NAN when no samples are nearby.
func _height_at(x: float, z: float) -> float:
	var gx := clampf((x + HALF) / GRID_STEP, 0.0, float(GRID_N - 1))
	var gz := clampf((z + HALF) / GRID_STEP, 0.0, float(GRID_N - 1))
	var i0 := clampi(int(floor(gx)), 0, GRID_N - 2)
	var j0 := clampi(int(floor(gz)), 0, GRID_N - 2)
	var tx := gx - float(i0)
	var tz := gz - float(j0)
	var n00 := j0 * GRID_N + i0
	var n10 := n00 + 1
	var n01 := n00 + GRID_N
	var n11 := n01 + 1
	var sum := 0.0
	var wsum := 0.0
	for e in [[n00, (1.0 - tx) * (1.0 - tz)], [n10, tx * (1.0 - tz)],
			[n01, (1.0 - tx) * tz], [n11, tx * tz]]:
		if _covered[e[0]] != 0:
			sum += _heights[e[0]] * float(e[1])
			wsum += float(e[1])
	if wsum <= 0.0:
		return NAN
	return sum / wsum


func _slope_deg(x: float, z: float) -> float:
	var hx0 := _height_at(x - 0.5, z)
	var hx1 := _height_at(x + 0.5, z)
	var hz0 := _height_at(x, z - 0.5)
	var hz1 := _height_at(x, z + 0.5)
	if is_nan(hx0) or is_nan(hx1) or is_nan(hz0) or is_nan(hz1):
		return 90.0
	var dx := (hx1 - hx0) / 1.0
	var dz := (hz1 - hz0) / 1.0
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


# ---------------------------------------------------------------- placement

func _cell_xy(cell: int) -> Vector2:
	return Vector2(float(cell % W) - HALF + 0.5, float(cell / W) - HALF + 0.5)


## The dirt lane is bare by design: no cards on the compacted surface, and a
## ragged 0.3 m margin comes from the mask's soft edge.  Loaded lazily so the
## grass layer still works if the mask is missing.
func _path_blocked(x: float, z: float) -> bool:
	return _path_wear(x, z) > 0.82 or _cap_blocked(x, z)

## 0..1 baked lane coverage, matching terrain.gdshader's pcov range.
func _path_wear(x: float, z: float) -> float:
	if _path_img == null:
		var tex := load(PATH_MASK) as Texture2D
		if tex != null:
			_path_img = tex.get_image()
	if _path_img == null:
		return 0.0
	var u := (x + 82.0) / 164.0
	var v := (z + 82.0) / 164.0
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return 0.0
	var ix := clampi(int(u * float(_path_img.get_width())), 0,
			_path_img.get_width() - 1)
	var iy := clampi(int(v * float(_path_img.get_height())), 0,
			_path_img.get_height() - 1)
	return smoothstep(0.12, 0.48, _path_img.get_pixel(ix, iy).r)

func _build_wear_points() -> void:
	_wear_pts.clear()
	for b in _layout.get("buildings", []):
		if String(b.get("id", "")) == "village_gate":
			_wear_pts.append(Vector4(float(b["x"]), float(b["z"]), 3.2, 0.50))
	for b in _layout.get("buildings", []):
		var bid := String(b.get("id", ""))
		if bid.contains("village") and bid != "village_gate":
			_wear_pts.append(Vector4(float(b["x"]), float(b["z"]), 2.0, 0.22))
	for b in _layout.get("bridges", []):
		_wear_pts.append(Vector4(float(b["x"]), float(b["z"]), 1.8, 0.30))
		if _wear_pts.size() >= 16:
			break
	if _wear_pts.size() > 16:
		_wear_pts.resize(16)

func _wear_point_at(x: float, z: float) -> float:
	var traffic := 0.0
	for wp in _wear_pts:
		var wd := Vector2(x - wp.x, z - wp.y).length()
		traffic = maxf(traffic,
				(1.0 - smoothstep(wp.z * 0.30, wp.z, wd)) * wp.w)
	return clampf(traffic, 0.0, 1.0)

func _load_zone_dryness() -> void:
	var z: Dictionary = _read_json(ZONES_JSON)
	if z.is_empty():
		return
	var zone_family: Dictionary = {}
	for e in z.get("zones", []):
		var fam := String(e.get("families", {}).get("top", ""))
		zone_family[String(e.get("id", ""))] = _dryness_of(fam)
	for island_id in z.get("island_zone", {}).keys():
		var zone_id := String(z["island_zone"][island_id])
		if zone_family.has(zone_id):
			_zone_dryness[String(island_id)] = float(zone_family[zone_id])

func _dryness_of(fam: String) -> float:
	if fam == "grass_dry":
		return 1.0
	if fam == "grass_meadow":
		return 0.35
	if fam == "grass_lush":
		return 0.0
	if fam == "dirt_ash":
		return 0.85
	return 0.35

func _island_dryness_for(cells: Array) -> float:
	if cells.is_empty():
		return 0.35
	var c := Vector2.ZERO
	for cell in cells:
		c += _cell_xy(int(cell))
	c /= float(cells.size())
	for isl in _layout.get("islands", []):
		var b: Array = isl.get("bbox", [])
		if b.size() < 4:
			continue
		if c.x >= float(b[0]) and c.x <= float(b[2]) 				and c.y >= float(b[1]) and c.y <= float(b[3]):
			return float(_zone_dryness.get(str(isl.get("id", "0")), 0.35))
	return 0.35


func _cap_blocked(x: float, z: float) -> bool:
	if not _caps_loaded:
		_load_cap_polys()
	for e in _cap_polys:
		var b: Rect2 = e["bbox"]
		if x < b.position.x or x > b.end.x or z < b.position.y or z > b.end.y:
			continue
		if Geometry2D.is_point_in_polygon(Vector2(x, z), e["poly"]):
			return true
	return false


func _load_cap_polys() -> void:
	_caps_loaded = true
	var txt := FileAccess.get_file_as_string(CAPS_JSON)
	if txt.is_empty():
		return
	var d: Dictionary = JSON.parse_string(txt)
	if d.is_empty() or not d.has("caps"):
		return
	for cap in d["caps"]:
		var raw: Array = cap.get("verts", [])
		if raw.size() < 3:
			continue
		var pts: PackedVector2Array = PackedVector2Array()
		for v in raw:
			pts.append(Vector2(float(v[0]), float(v[2])))
		var hull := _hull2d(pts)
		if hull.size() < 3:
			continue
		var lo := hull[0]
		var hi := hull[0]
		for p in hull:
			lo.x = minf(lo.x, p.x); lo.y = minf(lo.y, p.y)
			hi.x = maxf(hi.x, p.x); hi.y = maxf(hi.y, p.y)
		_cap_polys.append({"poly": hull, "bbox": Rect2(lo, hi - lo)})


func _hull2d(points: PackedVector2Array) -> PackedVector2Array:
	var pts := Array(points)
	pts.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and a.y < b.y))
	var lower: Array = []
	for p in pts:
		while lower.size() >= 2 and _cross2d(lower[-2], lower[-1], p) <= 0.0:
			lower.pop_back()
		lower.append(p)
	var upper: Array = []
	for i in range(pts.size() - 1, -1, -1):
		var p: Vector2 = pts[i]
		while upper.size() >= 2 and _cross2d(upper[-2], upper[-1], p) <= 0.0:
			upper.pop_back()
		upper.append(p)
	lower.pop_back()
	upper.pop_back()
	return PackedVector2Array(lower + upper)


func _cross2d(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)


func _grassable(cell: int) -> bool:
	var x := cell % W
	var z := cell / W
	# A pond cell never grows grass, and its bank is left bare for one cell so
	# the cards do not stand in the water or hover over the silt.
	for dz in range(-water_margin_cells, water_margin_cells + 1):
		for dx in range(-water_margin_cells, water_margin_cells + 1):
			var n := (z + dz) * W + (x + dx)
			if x + dx < 0 or z + dz < 0 or x + dx >= W or z + dz >= H:
				continue
			if _water.has(n):
				return false
	# Anything within cliff_margin_cells of the void is left alone: a grass
	# card rooted on the lip reads as floating when seen from below.
	for dz in range(-cliff_margin_cells, cliff_margin_cells + 1):
		for dx in range(-cliff_margin_cells, cliff_margin_cells + 1):
			var xx := x + dx
			var zz := z + dz
			if xx < 0 or zz < 0 or xx >= W or zz >= H:
				return false
			var n := zz * W + xx
			if not _land.has(n) and not _water.has(n):
				return false
	return true


func _patch(x: float, z: float) -> float:
	var n := _noise.get_noise_2d(x, z)          # -1..1
	return clampf(0.55 + (n * 0.5 + 0.5) * (0.75 + patch_contrast * 0.5),
			0.2, 1.7)


func _density_at(x: float, z: float) -> float:
	var slope := _slope_deg(x, z)
	if slope >= slope_end_deg:
		return 0.0
	var on_flat := 1.0 - smoothstep(slope_start_deg, slope_end_deg, slope)
	return density_per_m2 * on_flat * _patch(x, z)


func _island_weight(cells: Array) -> float:
	var w := 0.0
	if density_per_m2 <= 0.0:
		return 0.0
	for cell in cells:
		if not _grassable(int(cell)):
			continue
		var p := _cell_xy(int(cell))
		w += _density_at(p.x, p.y) / density_per_m2
	return w


func _collect_building_rects(_scene: Node) -> void:
	# Use the layout, not the runtime nodes: grass may build before map.gd has
	# finished adding every Building_* child.  map.gd's world convention is
	# x = layout.x, z = -layout.z, yaw = layout.yaw.
	_building_rects.clear()
	if not _layout.has("buildings"):
		return
	for b in _layout["buildings"]:
		var fp: Array = b.get("footprint", [0.0, 0.0])
		if fp.size() < 2: continue
		var x := float(b.get("x", 0.0))
		var z := -float(b.get("z", 0.0))
		var yaw := float(b.get("yaw", 0.0))
		var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(x, 0.0, z))
		_building_rects.append({"xform": xf,
			"hx": float(fp[0]) * 0.5 + 0.04,
			"hz": float(fp[1]) * 0.5 + 0.04})

func _inside_building(px: float, pz: float) -> bool:
	for r in _building_rects:
		var xf: Transform3D = r["xform"]
		var q := xf.affine_inverse() * Vector3(px, 0.0, pz)
		if absf(q.x) <= float(r["hx"]) and absf(q.z) <= float(r["hz"]):
			return true
	return false

## Tall grass thins with distance from the spawn meadow.  This is what keeps
## the far hillsides cheap while the 1.5 m shot gets a real sward.
func _near_scale(x: float, z: float) -> float:
	var d := Vector2(x - SPAWN_XZ.x, z - SPAWN_XZ.y).length()
	return lerpf(2.20, 0.50, smoothstep(8.0, 34.0, d))

# ---------------------------------------------------------------- turf fields
# These are the same world-space bands terrain.gdshader uses for the 3-15 m
# meadow read (0.075 / 0.160 / 0.340 / 0.255 cycles per metre) plus the baked
# path mask and the layout wear points.  Reproducing them on the CPU lets the
# cards be shorter, sparser and duller exactly where the turf is dry or worn.

func _hash11(n: float) -> float:
	return fposmod(sin(n * 127.1) * 43758.5453, 1.0)

func _vnoise2(p: Vector2) -> float:
	var i := Vector2(floor(p.x), floor(p.y))
	var f := Vector2(p.x - i.x, p.y - i.y)
	f = Vector2(f.x * f.x * (3.0 - 2.0 * f.x), f.y * f.y * (3.0 - 2.0 * f.y))
	var a := _hash11(i.x + i.y * 57.0)
	var b := _hash11(i.x + 1.0 + i.y * 57.0)
	var c := _hash11(i.x + (i.y + 1.0) * 57.0)
	var d := _hash11(i.x + 1.0 + (i.y + 1.0) * 57.0)
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)

func _tfield(x: float, z: float, ox: float, oz: float, freq: float) -> float:
	return _vnoise2(Vector2(x * freq + ox, z * freq + oz))

func _turf_fields(x: float, z: float, island_dry: float) -> Dictionary:
	var mp_broad := _tfield(x, z, 17.3, -4.2, 0.075)
	var mp_mid := _tfield(x, z, -9.8, 6.7, 0.160)
	var mp_small := _tfield(x, z, 5.1, 12.4, 0.340)
	var meadow_n := 0.55 * mp_broad + 0.30 * mp_mid + 0.15 * mp_small
	var dry_m := smoothstep(0.49, 0.63, meadow_n)
	var lush_m := smoothstep(0.49, 0.64, 1.0 - meadow_n)

	var n_large := _tfield(x, z, 3.7, 8.9, 0.27)
	var n_med := _tfield(x, z, -4.1, 2.3, 0.61)
	var dry_field := smoothstep(0.62, 0.78, 0.55 * n_large + 0.45 * n_med)
	var mid_broad := _tfield(x, z, 21.4, -9.3, 0.145)
	var mid_patch := _tfield(x, z, -13.2, 4.8, 0.310)
	var mid_dry := smoothstep(0.47, 0.66, 0.68 * mid_broad + 0.32 * mid_patch)
	var island_n := _tfield(x, z, -12.7, -3.9, 0.255)
	var dry_island := smoothstep(0.58, 0.76, island_n)
	var lush_island := smoothstep(0.56, 0.74, 1.0 - island_n)
	var dry := maxf(dry_m, maxf(dry_field * 0.58,
			maxf(mid_dry * 0.38, maxf(dry_island * 0.45, island_dry * 0.55))))
	var lush := maxf(lush_m, lush_island * 0.42)
	var worn := maxf(_path_wear(x, z), _wear_point_at(x, z))
	var height := clampf((1.0 - 0.32 * dry) * (1.0 - 0.62 * worn),
			0.25, 1.15)
	var dens := clampf((1.0 + 0.38 * lush - 0.58 * dry) * (1.0 - 0.86 * worn),
			0.0, 1.5)
	return {"dry": clampf(dry, 0.0, 1.0), "lush": clampf(lush, 0.0, 1.0),
			"worn": worn, "height": height, "density": dens}

func _scatter_island(island_index: int, cells: Array, keep: float,
		xforms: Array[Transform3D], customs: Array[Color], island_dry: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed + island_index * 104729
	for cell in cells:
		var ci := int(cell)
		if not _grassable(ci):
			continue
		var centre := _cell_xy(ci)
		var field := _turf_fields(centre.x, centre.y, island_dry)
		if field.worn > 0.82:
			continue
		var inside_cell := _inside_building(centre.x, centre.y)
		var density: float = _density_at(centre.x, centre.y) * keep 				* float(field.density) * _near_scale(centre.x, centre.y)
		if density <= 0.0:
			continue
		var count := int(floor(density))
		if rng.randf() < density - float(count):
			count += 1
		for _k in range(count):
			var px := centre.x - 0.5 + rng.randf()
			var pz := centre.y - 0.5 + rng.randf()
			if inside_cell:
				continue
			var h := _height_at(px, pz)
			if is_nan(h):
				continue
			var slope := _slope_deg(px, pz)
			if slope >= slope_end_deg:
				continue
			var hx := _height_at(px + 0.5, pz) - _height_at(px - 0.5, pz)
			var hz := _height_at(px, pz + 0.5) - _height_at(px, pz - 0.5)
			var nrm := Vector3(-hx, 1.0, -hz)
			if nrm.length_squared() < 0.0001:
				nrm = Vector3.UP
			nrm = nrm.normalized()
			var up := Vector3.UP.lerp(nrm, slope_tilt)
			if up.length_squared() < 0.0001:
				up = Vector3.UP
			up = up.normalized()
			var yaw := rng.randf() * TAU
			var fwd := Vector3(cos(yaw), 0.0, sin(yaw))
			fwd = fwd - up * fwd.dot(up)
			if fwd.length_squared() < 0.0001:
				fwd = Vector3.FORWARD
			fwd = fwd.normalized()
			var right := up.cross(fwd).normalized()
			var basis := Basis(right, up, fwd)
			basis = basis.rotated(basis.x.normalized(),
					rng.randf_range(-0.16, 0.16))
			var height: float = rng.randf_range(clump_height_min, clump_height_max) 					* float(field.height)
			var width: float = rng.randf_range(clump_width_min, clump_width_max) 					* clampf(sqrt(float(field.density)), 0.45, 1.20)
			basis = basis.scaled(Vector3(width, height, width))
			var pos := Vector3(px, h - sink, pz)
			xforms.append(Transform3D(basis, pos))
			customs.append(Color(rng.randf(), rng.randf(),
					0.6 + rng.randf() * 0.8, island_dry))


func _build_ground_cover() -> void:
	_ground_clumps = 0
	_ground_tris = 0
	var xforms: Array[Transform3D] = []
	var customs: Array[Color] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed + 7717
	var step := 0.075
	var radius := 7.5
	var q := -radius
	while q <= radius:
		var qz := -radius
		while qz <= radius:
			var px := SPAWN_XZ.x + q + rng.randf_range(-0.045, 0.045)
			var pz := SPAWN_XZ.y + qz + rng.randf_range(-0.045, 0.045)
			var rr := Vector2(q, qz).length()
			if rr > radius:
				qz += step
				continue
			var ci := clampi(int(round(pz + HALF - 0.5)), 0, H - 1) * W \
					+ clampi(int(round(px + HALF - 0.5)), 0, W - 1)
			var h := _height_at(px, pz)
			var f := _turf_fields(px, pz, 0.35)
			if is_nan(h) or not _grassable(ci) or f.worn > 0.72 \
					or _inside_building(px, pz) or _slope_deg(px, pz) > 40.0:
				qz += step
				continue
			var height := rng.randf_range(0.05, 0.15) * lerpf(0.7, 1.25, f.lush)
			var width := rng.randf_range(0.10, 0.21) * lerpf(0.8, 1.15, f.lush)
			var yaw := rng.randf() * TAU
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(width, height, width))
			xforms.append(Transform3D(basis, Vector3(px, h - 0.012, pz)))
			customs.append(Color(rng.randf(), rng.randf(),
					0.6 + rng.randf() * 0.8, 0.35))
			qz += step
		q += step
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _mesh
	mm.instance_count = xforms.size()
	var aabb := AABB(xforms[0].origin, Vector3.ZERO)
	for k in xforms.size():
		mm.set_instance_transform(k, xforms[k])
		mm.set_instance_custom_data(k, customs[k])
		aabb = aabb.expand(xforms[k].origin)
	aabb = aabb.grow(1.0)
	mm.custom_aabb = aabb
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "GrassGroundCover"
	mmi.multimesh = mm
	mmi.material_override = _material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_root.add_child(mmi)
	_ground_clumps = xforms.size()
	_ground_tris = xforms.size() * 4
	_clumps += _ground_clumps

func _build_height_field_staged(_mesh_instances: Array) -> void:
	_heights = PackedFloat32Array()
	_heights.resize(GRID_N * GRID_N)
	_heights.fill(-1.0e20)
	_covered = PackedByteArray()
	_covered.resize(GRID_N * GRID_N)
	_covered.fill(0)
	# Use TerrainCollision's 768x768 walkable height grid instead of
	# re-rasterising 376k render triangles.  This is the same surface the
	# player walks on; it cuts the height pass from ~0.7 s to ~20 ms.
	var tc := _map.get_node_or_null("TerrainCollision")
	if tc != null and tc.get("_h") != null:
		var hs: PackedFloat32Array = tc.get("_h")
		var covs: PackedByteArray = tc.get("_cov")
		var n: int = int(tc.get("N"))
		var cs: float = float(tc.get("CELL"))
		var half: float = float(tc.get("HALF"))
		for j in range(GRID_N):
			var wz := -HALF + float(j) * GRID_STEP
			var jj := clampi(int(round((wz + half) / cs)), 0, n - 1)
			for i in range(GRID_N):
				var wx := -HALF + float(i) * GRID_STEP
				var ii := clampi(int(round((wx + half) / cs)), 0, n - 1)
				var k := jj * n + ii
				if covs[k] != 0 and hs[k] > -20.0:
					var g := j * GRID_N + i
					_heights[g] = hs[k]
					_covered[g] = 1
		await get_tree().process_frame
	else:
		for node in _mesh_instances:
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			for si in range(mi.mesh.get_surface_count()):
				_raster_surface(mi, si)
		await get_tree().process_frame
	# fill holes
	for pass_i in range(3):
		var added := 0
		for j in range(1, GRID_N - 1):
			for i in range(1, GRID_N - 1):
				var n2 := j * GRID_N + i
				if _covered[n2] == 1:
					continue
				var sum := 0.0
				var cnt := 0
				for o: int in [-1, 1, -GRID_N, GRID_N]:
					var m := n2 + o
					if _covered[m] == 1:
						sum += _heights[m]
						cnt += 1
				if cnt > 0:
					_heights[n2] = sum / float(cnt)
					_covered[n2] = 2
					added += 1
		if added == 0:
			break
	var cov := 0
	for c in _covered:
		if c != 0:
			cov += 1
	_coverage = float(cov) / float(GRID_N * GRID_N)


func _raster_surface(mi: MeshInstance3D, s: int) -> void:
	var arrays := mi.mesh.surface_get_arrays(s)
	if arrays.is_empty():
		return
	var xf := mi.global_transform
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx = arrays[Mesh.ARRAY_INDEX]
	if idx == null or idx.size() == 0:
		for k in range(0, verts.size() - 2, 3):
			_raster_tri(xf * verts[k], xf * verts[k + 1], xf * verts[k + 2])
	else:
		for k in range(0, idx.size() - 2, 3):
			_raster_tri(xf * verts[idx[k]], xf * verts[idx[k + 1]],
					xf * verts[idx[k + 2]])


func _components() -> Array:
	var seen := {}
	var comps: Array = []
	for start in _land.keys():
		if seen.has(start):
			continue
		var q: Array[int] = [int(start)]
		seen[start] = true
		var cells: Array[int] = []
		while q.size() > 0:
			var c: int = q.pop_back()
			cells.append(c)
			var x := c % W
			var z := c / W
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx := x + d.x
				var nz := z + d.y
				if nx < 0 or nz < 0 or nx >= W or nz >= H:
					continue
				var n := nz * W + nx
				if _land.has(n) and not seen.has(n):
					seen[n] = true
					q.append(n)
		comps.append(cells)
	return comps


# ---------------------------------------------------------------- cards

func _make_card_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	# Two crossed quads, both with an upward normal. Grass cards lit by their
	# geometric normal would be black at a low sun; lighting them like the
	# ground they grow from is the standard cheat and it reads correctly.
	var quads := [
		[Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 1, 0), Vector3(-0.5, 1, 0)],
		[Vector3(0, 0, -0.5), Vector3(0, 0, 0.5), Vector3(0, 1, 0.5), Vector3(0, 1, -0.5)],
	]
	for quad in quads:
		var base := verts.size()
		for k in range(4):
			verts.append(quad[k])
			normals.append(Vector3.UP)
		# image space: v=0 is the top of the texture
		uvs.append(Vector2(0, 1))
		uvs.append(Vector2(1, 1))
		uvs.append(Vector2(1, 0))
		uvs.append(Vector2(0, 0))
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _make_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(GRASS_SHADER)
	_path_tex = load(PATH_MASK) as Texture2D
	var wps := PackedVector4Array()
	for wp in _wear_pts:
		wps.append(wp)
	mat.set_shader_parameter("path_mask", _path_tex)
	mat.set_shader_parameter("path_rect", Vector4(-82.0, -82.0, 164.0, 164.0))
	mat.set_shader_parameter("wear_pts", wps)
	mat.set_shader_parameter("wear_count", _wear_pts.size())
	mat.set_shader_parameter("grass_texture", _make_texture())
	mat.set_shader_parameter("tint_a", tint_a)
	mat.set_shader_parameter("tint_b", tint_b)
	mat.set_shader_parameter("wind_strength", wind_strength)
	mat.set_shader_parameter("wind_speed", wind_speed)
	mat.set_shader_parameter("fade_start", fade_start)
	mat.set_shader_parameter("fade_end", fade_end)
	mat.set_shader_parameter("alpha_scissor", alpha_scissor)
	return mat


## A clump of tapered blades drawn into an RGBA texture. Generated at runtime
## so the repo carries no extra asset and the card cannot drift from its shader.
func _make_texture() -> ImageTexture:
	var size := maxi(128, texture_size)
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	# Keep a green RGB under the transparent pixels: mip averaging otherwise
	# pulls every distant card toward black.
	img.fill(Color(0.22, 0.30, 0.14, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed + 17
	for b in range(maxi(12, blade_count)):
		# Three loose clusters per card leave the gaps between tufts.
		var cluster := float(b % 3) / 3.0 + 0.17
		var bx := size * clampf(cluster + rng.randf_range(-0.15, 0.15), 0.04, 0.96)
		var h := rng.randf_range(size * 0.36, size * 0.99)
		var lean := rng.randf_range(-size * 0.12, size * 0.12)
		var bend := rng.randf_range(-size * 0.10, size * 0.10)
		var w0 := rng.randf_range(size * 0.0070, size * 0.0160)
		var dry := rng.randf() < 0.05
		var broken := rng.randf() < 0.12
		var end_t := 1.0 if not broken else rng.randf_range(0.55, 0.82)
		# 3-5 segments, piecewise so the blade has visible joints, not a
		# single smooth ribbon.  The tip tapers to zero width.
		var segs := 5
		var pts: Array[Vector2] = []
		for si in range(segs + 1):
			var t := float(si) / float(segs) * end_t
			var sx := bx + lean * t * t + bend * sin(t * PI)
			pts.append(Vector2(sx, t))
		var base_col := Color(0.10, 0.15, 0.055) if not dry else Color(0.19, 0.17, 0.085)
		var tip_col := Color(0.34, 0.44, 0.16) if not dry else Color(0.42, 0.43, 0.23)
		for yy in range(int(h * end_t)):
			var t := float(yy) / maxf(1.0, h)
			var si := mini(int(floor(t * float(segs))), segs - 1)
			var lt := clampf((t - float(si) / float(segs)) * float(segs), 0.0, 1.0)
			var px := lerpf(pts[si].x, pts[si + 1].x, lt)
			var width := w0 * pow(1.0 - t, 0.72) + 0.15
			var col := base_col.lerp(tip_col, t)
			var lin := col.srgb_to_linear()
			var py := size - 1 - yy
			var lo := int(floor(px - width))
			var hi := int(ceil(px + width))
			for xx in range(lo, hi + 1):
				if xx < 0 or xx >= size or py < 0 or py >= size:
					continue
				var a := clampf(1.0 - absf(float(xx) - px) / width, 0.0, 1.0)
				a *= smoothstep(0.0, 0.10, t) * (1.0 - smoothstep(0.90, 1.0, t))
				if broken and t > end_t - 0.035:
					a *= 0.35
				if a < 0.06:
					continue
				if img.get_pixel(xx, py).a < a:
					img.set_pixel(xx, py, Color(lin.r, lin.g, lin.b, a))
	img.fix_alpha_edges()
	img.generate_mipmaps()
	if OS.get_environment("GRASS_DEBUG_TEX") == "1":
		img.save_png("/tmp/grass_texture.png")
	return ImageTexture.create_from_image(img)

func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("grass: cannot open " + path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	return {}
