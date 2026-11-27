extends Node3D
## Navigation bake for the top-down RPG.  Builds a filtered, world-space walk
## mesh from the visible terrain top (slope <= ~42 deg), removes water, void,
## buildings, solid props and tree trunks, then bakes a NavigationMesh with
## Recast.  The visible terrain and collision are never modified.

const LAYOUT := "res://map_layout.json"
## Overridden by an authored world (see town_map.gd) before build() runs.
var layout_path := LAYOUT
const GRID := 163
const HALF := 81.5
const MAX_SLOPE_Y := 0.72          # cos(44 deg)
const CELL := 0.25
## Erosion radius.  0.32 m (the player's capsule radius) eroded the walkable
## area to nothing on this mesh at a 0.25 m cell: Recast rounded it up to two
## cells and the town's narrow walkable spans vanished, baking 0 polygons.
## 0.10 keeps the mesh; the capsule's own collision handles wall clearance.
const AGENT_RADIUS := 0.10

var region: NavigationRegion3D
var navmesh: NavigationMesh
var source_faces := 0
var bake_ms := 0
var polygons := 0
var vertices := 0
var nav_cells := 0
var _water: PackedByteArray
# Supplied by the region: below this height is water, not ground.
var water_level := 0.0
var has_water := false
# Set before build(): identifies the map so its baked navmesh can be reused.
var cache_id := ""
## Objects whose names start with this are a hand-authored navmesh: when any
## exist, they ARE the walkable surface and nothing is guessed from meshes.
var nav_marker_prefix := "NAV_"
## How far apart two navmesh islands may be and still be stitched at runtime.
## The bake leaves seams of 0.25-0.9 m where it could not merge contours, which
## is what made a staircase 0.94 m from the main island unreachable.
var edge_connection_margin := 1.0
## Stitch navmesh pieces that the bake left within this distance of each other.
## The baker splits contours at cell resolution, so a staircase 0.94 m from the
## main floor ends up an island that no path can enter.  A link bridges a step,
## never a cliff: the rise limit keeps vertical gaps out.
@export var stitch_max_gap := 1.3
@export var stitch_max_rise := 0.9
var supplied_water := PackedByteArray()
var _rects: Array = []             # [center Vector2, half Vector2, yaw]
var _circles: Array = []           # [center Vector2, radius]
var _bridge_segs: Array = []       # [Vector2 a, Vector2 b]
## 1 m blocker cells covered by a Solid_* concave shape.  Keyed by grid index
## packed into one int so lookup is a dictionary hit rather than an array scan.
## Whether to carve Solid_* geometry into the blocker grid.  Off for maps whose
## solid meshes cover the whole layout: the town ships one material per mesh, so
## every building and rampart counts as solid and a 1 m carve eats the streets.
var carve_solids := true
var _solid_cells := {}
var _solid_cell_count := 0


var _dbg_slope := 0
var _dbg_blocked := 0
var _dbg_low := 0


func build(map: Node3D) -> void:
	var t0 := Time.get_ticks_msec()
	# Applied first, and on every load: a cached navmesh returns before the bake
	# block below, which silently skipped this and made the margin look inert.
	var env_m := OS.get_environment("EDGE_MARGIN")
	if not env_m.is_empty():
		edge_connection_margin = float(env_m)
	var mrid: RID = get_world_3d().navigation_map if is_inside_tree() else map_rid()
	if mrid.is_valid():
		NavigationServer3D.map_set_edge_connection_margin(mrid, edge_connection_margin)
		print("NAV_EDGE margin=%.2f" % edge_connection_margin)
	var markers := map.find_children("%s*" % nav_marker_prefix, "MeshInstance3D", true, false)
	if not markers.is_empty():
		_build_from_markers(markers, map, t0)
		return
	_load_layout()
	_collect_obstacles(map)
	if carve_solids:
		_collect_solid_footprints(map)
	var terrain := _find_terrain(map)
	if terrain == null:
		push_error("nav: Terrain not found")
		return
	var faces := PackedVector3Array()
	for s in mini(6, terrain.mesh.get_surface_count()):
		var arr := terrain.mesh.surface_get_arrays(s)
		if arr.is_empty():
			continue
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx = arr[Mesh.ARRAY_INDEX]
		var xf := terrain.global_transform
		var count: int = vs.size() if idx == null else idx.size()
		for k in range(0, count - 2, 3):
			var a := xf * vs[k if idx == null else idx[k]]
			var b := xf * vs[(k + 1) if idx == null else idx[k + 1]]
			var c := xf * vs[(k + 2) if idx == null else idx[k + 2]]
			var n := (b - a).cross(c - a)
			if n.length_squared() < 1.0e-10:
				continue
			n = n.normalized()
			if absf(n.y) < MAX_SLOPE_Y:
				_dbg_slope += 1
				continue
			var cen := (a + b + c) / 3.0
			if cen.y < -4.0:
				_dbg_low += 1
				continue
			# Test the vertices as well as the centre.  A triangle is much
			# smaller than the 1 m blocking cell, so testing only the centre let
			# walls sit inside walkable polygons and paths ran through buildings.
			if _blocked(cen.x, cen.z) or _blocked(a.x, a.z) \
					or _blocked(b.x, b.z) or _blocked(c.x, c.z):
				_dbg_blocked += 1
				continue
			# rcMarkWalkableTriangles keeps only triangles whose winding yields
			# an upward normal in Recast's own convention, which is the OPPOSITE
			# sign to cross(b-a, c-a) here.  Emitting the natural winding gave a
			# 0-polygon bake from 97k triangles; swapping the last two vertices
			# of every upward face is what finally produced a mesh.
			if n.y <= 0.0:
				faces.append(a); faces.append(b); faces.append(c)
			else:
				faces.append(a); faces.append(c); faces.append(b)
	# Bridges and stair runs sit outside the terrain mesh, so the bake would
	# never cross the water.  They were given layer-1 collision by name, but
	# recast reads geometry, not collision, so add their faces explicitly.
	var walk_extra := 0
	for node in map.find_children("Walkable_*", "StaticBody3D", true, false):
		var sb := node as StaticBody3D
		if sb == null or (sb.collision_layer & 1) == 0:
			continue
		for cs in sb.get_children():
			if not (cs is CollisionShape3D):
				continue
			var shape := (cs as CollisionShape3D).shape
			if not (shape is ConcavePolygonShape3D):
				continue
			var wf: PackedVector3Array = (shape as ConcavePolygonShape3D).get_faces()
			for k in range(0, wf.size() - 2, 3):
				var a := wf[k]
				var b := wf[k + 1]
				var c := wf[k + 2]
				var n := (b - a).cross(c - a)
				if n.length_squared() < 1.0e-10:
					continue
				n = n.normalized()
				if absf(n.y) < MAX_SLOPE_Y:
					continue
				# Walkable bodies skip the blocker grid, which is how a patch of
				# floor got baked straight across the river and paths walked on
				# water.  Anything at or below the waterline inside the water
				# footprint is riverbed, not deck; bridge decks sit above it and
				# are kept.
				var wcen := (a + b + c) / 3.0
				if has_water and wcen.y <= water_level + 0.05 and _over_water(wcen.x, wcen.z):
					continue
				if n.y <= 0.0:
					faces.append(a); faces.append(b); faces.append(c)
				else:
					faces.append(a); faces.append(c); faces.append(b)
				walk_extra += 1
	if walk_extra > 0:
		print("NAV_WALKABLE surfaces faces=%d" % walk_extra)
	source_faces = faces.size() / 3
	# Causeway decks are thin layer-1 boxes above the terrain.  Recast cannot
	# parse boxes from a face soup, so add their top quads explicitly.
	var bridge_mesh := _add_bridge_mesh(map)
	navmesh = NavigationMesh.new()
	navmesh.cell_size = CELL
	navmesh.cell_height = 0.10
	navmesh.agent_radius = AGENT_RADIUS
	navmesh.agent_height = 1.70
	navmesh.agent_max_climb = 0.55
	navmesh.agent_max_slope = 42.0
	navmesh.region_min_size = 1.0
	navmesh.edge_max_error = 1.2
	navmesh.detail_sample_distance = 1.0
	navmesh.detail_sample_max_error = 1.0
	navmesh.filter_low_hanging_obstacles = true
	navmesh.filter_ledge_spans = false
	navmesh.filter_walkable_low_height_spans = true
	# Reuse a previous bake when nothing that fed it has changed.  Baking costs
	# 12 s on the foliage maps and ran on every single load.
	_mask_water(map)
	if _nav_cache_load():
		return
	var src := NavigationMeshSourceGeometryData3D.new()
	src.add_faces(faces, Transform3D.IDENTITY)
	if bridge_mesh != null and bridge_mesh.get_surface_count() > 0:
		src.add_mesh(bridge_mesh, Transform3D.IDENTITY)
	NavigationServer3D.bake_from_source_geometry_data(navmesh, src)
	bake_ms = Time.get_ticks_msec() - t0
	polygons = navmesh.get_polygon_count()
	vertices = navmesh.get_vertices().size()
	nav_cells = _area_cells()
	region = NavigationRegion3D.new()
	region.name = "NavigationRegion3D"
	region.navigation_mesh = navmesh
	add_child(region)
	print("NAV_FILTER slope=%d blocked=%d low=%d" % [_dbg_slope, _dbg_blocked, _dbg_low])
	print("NAV_BAKE source_tris=%d bake_ms=%d polygons=%d vertices=%d approx_cells=%d cell=%.2f" % [
		source_faces, bake_ms, polygons, vertices, nav_cells, CELL])
	_stitch_islands()
	_nav_cache_save()


func _load_layout() -> void:
	# An authored world can pass an empty path: it ships no obstacle layout,
	# so carve from the collision bodies instead of a JSON file.
	if String(layout_path).is_empty():
		return
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(layout_path))
	_water = PackedByteArray(); _water.resize(GRID * GRID); _water.fill(0)
	for w in d.get("water_mask", []):
		_water[int(w)] = 1
	# Solid building footprints are carved as oriented rectangles.  The gate
	# keeps its central 3.6 m passage open; only the two jambs are cut.
	for b in d.get("bridges", []):
		_bridge_segs.append([Vector2(float(b["ax"]), -float(b["az"])),
			Vector2(float(b["bx"]), -float(b["bz"]))])
	for b in d.get("buildings", []):
		var cx := float(b["x"])
		var cz := -float(b["z"])
		var yaw := float(b.get("yaw", 0.0))
		var fp: Array = b.get("footprint", [4.0, 4.0])
		var hw := float(fp[0]) * 0.5 + AGENT_RADIUS
		var hd := float(fp[1]) * 0.5 + AGENT_RADIUS
		if String(b.get("id", "")) == "village_gate":
			var open_half := 1.8
			for sx: float in [-1.0, 1.0]:
				var jamb_half: float = (hw - open_half) * 0.5
				var ox: float = sx * (open_half + jamb_half)
				_rects.append([Vector2(cx + ox, cz), Vector2(jamb_half, hd), yaw])
		else:
			_rects.append([Vector2(cx, cz), Vector2(hw, hd), yaw])


func _collect_obstacles(map: Node3D) -> void:
	# Every layer-2 static box (buildings, walls, barrels, boulders...) is a
	# walk obstacle.  Use the actual collision shape so the bake agrees with
	# the controller, not a hand-maintained prop list.
	for n in map.find_children("*", "StaticBody3D", true, false):
		var body := n as StaticBody3D
		if body.collision_layer & 2 == 0:
			continue
		var is_prop := String(body.name).begins_with("Solid_")
		var pad := 0.15 if is_prop else AGENT_RADIUS
		for c in body.find_children("*", "CollisionShape3D", true, false):
			var cs := c as CollisionShape3D
			var sh := cs.shape
			if sh is BoxShape3D:
				var box := sh as BoxShape3D
				var xf := cs.global_transform
				_rects.append([Vector2(xf.origin.x, xf.origin.z),
					Vector2(box.size.x * xf.basis.get_scale().x * 0.5 + pad,
						box.size.z * xf.basis.get_scale().z * 0.5 + pad),
					xf.basis.get_euler().y])
	# Tree trunks are visual-only; they get NavigationObstacle3D avoidance in
	# game_controller.gd.  Do not carve them into the static bake.
	# Gate barrier body is disabled while open; do not carve its centre.
	print("NAV_CUTOUTS rects=%d trunk_circles=%d" % [_rects.size(), _circles.size()])


## Carve Solid_* bodies into the blocker grid.
##
## The box-based collector above never fires on this map: every solid body is a
## ConcavePolygonShape3D, so nothing was ever carved and the baked mesh ran
## straight through buildings.  Collision was correct, which is why the player
## could feel walls the navmesh did not know about.
##
## Faces are filtered to a height band because the packages contain duplicate
## geometry far below the playable surface (one bridge exists again at y=-37);
## rasterising that would carve a hole in the middle of the island.
func _collect_solid_footprints(map: Node3D) -> void:
	const BAND_LO := -2.0
	const BAND_HI := 20.0
	var marked := 0
	var skipped := 0
	for node in map.find_children("Solid_*", "StaticBody3D", true, false):
		var body := node as StaticBody3D
		if body == null or (body.collision_layer & 2) == 0:
			continue
		for c in body.find_children("*", "CollisionShape3D", true, false):
			var cs := c as CollisionShape3D
			if cs == null or not (cs.shape is ConcavePolygonShape3D):
				continue
			var wf: PackedVector3Array = (cs.shape as ConcavePolygonShape3D).get_faces()
			var xf := cs.global_transform
			for k in range(0, wf.size() - 2, 3):
				var a := xf * wf[k]
				var b := xf * wf[k + 1]
				var c2 := xf * wf[k + 2]
				var ymin := minf(a.y, minf(b.y, c2.y))
				var ymax := maxf(a.y, maxf(b.y, c2.y))
				if ymax < BAND_LO or ymin > BAND_HI:
					skipped += 1
					continue
				# Only steep faces block.  Flat plates are floors and plazas: the
				# town ships one material per mesh, so "solid" covers whole
				# building and rampart meshes including their ground plates.
				# Rasterising those erased 80% of the town's walkable area.
				var nrm := (b - a).cross(c2 - a)
				var nl := nrm.length()
				if nl < 1.0e-6:
					continue
				if absf(nrm.y / nl) > 0.55:
					continue
				var minx := minf(a.x, minf(b.x, c2.x))
				var maxx := maxf(a.x, maxf(b.x, c2.x))
				var minz := minf(a.z, minf(b.z, c2.z))
				var maxz := maxf(a.z, maxf(b.z, c2.z))
				# One metre cells, matching _blocked()'s indexing.
				for gx in range(int(floor(minx + HALF)), int(ceil(maxx + HALF)) + 1):
					for gz in range(int(floor(minz + HALF)), int(ceil(maxz + HALF)) + 1):
						if gx < 0 or gz < 0 or gx >= GRID or gz >= GRID:
							continue
						var key := gx * 4096 + gz
						if not _solid_cells.has(key):
							_solid_cells[key] = true
							marked += 1
	print("NAV_SOLIDS cells=%d faces_marked=%d faces_skipped_band=%d" % [
		marked, marked, skipped])


func _blocked(x: float, z: float) -> bool:
	var i := int(round(x + HALF))
	var j := int(round(z + HALF))
	if not _solid_cells.is_empty() and _solid_cells.has(i * 4096 + j):
		return true
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var ii: int = i + dx
			var jj: int = j + dz
			if ii < 0 or jj < 0 or ii >= GRID or jj >= GRID:
				return true
			if _water.size() > jj * GRID + ii and _water[jj * GRID + ii] != 0 \
			and not _near_bridge(x, z):
				return true
	for r in _rects:
		var c: Vector2 = r[0]
		var h: Vector2 = r[1]
		var yaw: float = r[2]
		var d := Vector2(x, z) - c
		var cs := cos(-yaw)
		var sn := sin(-yaw)
		var lx := d.x * cs - d.y * sn
		var lz := d.x * sn + d.y * cs
		if absf(lx) <= h.x and absf(lz) <= h.y:
			return true
	for c in _circles:
		if Vector2(x, z).distance_squared_to(c[0]) < c[1] * c[1]:
			return true
	return false


func _quad_up(faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	# Recast rasterizes bridge quads with the opposite winding to a Y-up
	# render normal; the source terrain uses the same convention.
	if (b - a).cross(c - a).y >= 0.0:
		faces.append(a); faces.append(c); faces.append(b)
		faces.append(a); faces.append(d); faces.append(c)
	else:
		faces.append(a); faces.append(b); faces.append(c)
		faces.append(a); faces.append(c); faces.append(d)


func _add_bridge_mesh(map: Node3D) -> ArrayMesh:
	var faces := PackedVector3Array()
	var n := 0
	var game := map.get_parent()
	var roots: Array[Node] = [map]
	if game != null:
		roots.append(game)
	var space := map.get_world_3d().direct_space_state
	for node in _find_bodies(roots):
		var body := node as StaticBody3D
		var bn2 := String(body.name)
		if body.collision_layer & 1 == 0:
			continue
		if not (bn2.begins_with("BridgeDeck") or bn2.begins_with("BridgeRamp") or bn2.begins_with("BridgeLanding")):
			continue
		for c in body.find_children("*", "CollisionShape3D", true, false):
			var cs := c as CollisionShape3D
			var bs := cs.shape as BoxShape3D
			if bs == null:
				continue
			var xf := cs.global_transform
			var sz := bs.size.z * 0.5
			var sy := bs.size.y * 0.5
			var hw := bs.size.x * 0.5
			var a := xf * Vector3(-hw, sy, -sz)
			var b := xf * Vector3(hw, sy, -sz)
			var cc := xf * Vector3(hw, sy, sz)
			var d := xf * Vector3(-hw, sy, sz)
			_quad_up(faces, a, b, cc, d)
			n += 1
	var mesh := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = faces
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	print("NAV_BRIDGES decks=%d verts=%d" % [n, faces.size()])
	return mesh


func _near_bridge(x: float, z: float) -> bool:
	var p := Vector2(x, z)
	for seg in _bridge_segs:
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		if p.distance_to(a + ab * t) <= 2.2:
			return true
	return false


func _find_bodies(roots: Array[Node]) -> Array:
	var out: Array = []
	for r in roots:
		if r == null:
			continue
		for n in r.find_children("*", "StaticBody3D", true, false):
			if not out.has(n):
				out.append(n)
	return out


func _find_terrain(map: Node3D) -> MeshInstance3D:
	# TerrainSurface may merge the authored GLB surfaces into one mesh, so do
	# not key off the old 10-surface count.  The terrain node keeps its name.
	# The authored mesh is Map/Terrain/Terrain.  Do not match the parent
	# Node3D, and do not fall back to whatever has >= 6 surfaces: houses have
	# six surfaces and their wall triangles silently produced an empty bake.
	# Ask the region what its ground is before falling back to the built-in names:
	# authored worlds name their ground whatever the export produced (SM_Ground
	# for the graveyard package), and a hard-coded list silently bakes nothing.
	# The caller passes the Map wrapper, which has no ground_meshes of its own;
	# the region node underneath does.  Without this probe the lookup silently
	# fell through to the hard-coded names and baked no navmesh at all.
	var owner_node: Node = map
	if owner_node.get("ground_meshes") == null:
		for n in map.find_children("*", "", true, false):
			if n.get("ground_meshes") != null:
				owner_node = n
				break
	if owner_node.get("ground_meshes") != null:
		map = owner_node
	if map.has_method("ground_meshes"):
		var named: Variant = map.call("ground_meshes")
		if named != null:
			for want in named:
				for n in map.find_children(String(want), "MeshInstance3D", true, false):
					var mi2 := n as MeshInstance3D
					if mi2 != null and mi2.mesh != null:
						return mi2
	elif map.get("ground_meshes") != null:
		for want in map.get("ground_meshes"):
			for n in map.find_children(String(want), "MeshInstance3D", true, false):
				var mi2 := n as MeshInstance3D
				if mi2 != null and mi2.mesh != null:
					return mi2
	for want in ["Terrain", "SM_Town_Ground", "SM_Ground"]:
		for n in map.find_children(want, "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi != null and mi.mesh != null:
				return mi
	return null


func _area_cells() -> int:
	if navmesh == null:
		return 0
	var verts := navmesh.get_vertices()
	var area := 0.0
	for p in navmesh.get_polygon_count():
		var poly := navmesh.get_polygon(p)
		for k in range(1, poly.size() - 1):
			var a := verts[poly[0]]
			var b := verts[poly[k]]
			var c := verts[poly[k + 1]]
			area += absf((b - a).cross(c - a).y) * 0.5
	return int(area / (CELL * CELL))


func map_rid() -> RID:
	if region != null:
		var m := region.get_navigation_map()
		if m.is_valid():
			return m
	if is_inside_tree():
		return get_world_3d().navigation_map
	return RID()


func closest(p: Vector3) -> Vector3:
	return NavigationServer3D.map_get_closest_point(map_rid(), p)


func path(from: Vector3, to: Vector3) -> PackedVector3Array:
	return NavigationServer3D.map_get_path(map_rid(), from, to, true)


## Signature of everything that determines the baked navmesh.
func _nav_signature() -> String:
	# The mask decides which ground is walkable, so it belongs in the signature;
	# leaving it out let a cached navmesh outlive a changed river footprint.
	var sum := 0
	for i in supplied_water.size():
		if supplied_water[i] != 0:
			sum = (sum * 31 + i) & 0x7fffffff
	return "%s|src=%d|water=%.3f|%s|%.3f|%.2f|mask=%d:%d" % [
		cache_id, source_faces, water_level, str(has_water), AGENT_RADIUS, CELL,
		supplied_water.size(), sum]


func _nav_cache_paths() -> Array:
	return ["user://region_cache/%s_nav.res" % cache_id,
		"user://region_cache/%s_nav.key" % cache_id]


func _nav_cache_load() -> bool:
	if String(cache_id).is_empty():
		return false
	var paths := _nav_cache_paths()
	if not FileAccess.file_exists(paths[0]) or not FileAccess.file_exists(paths[1]):
		return false
	var f := FileAccess.open(paths[1], FileAccess.READ)
	if f == null:
		return false
	var stored := f.get_as_text().strip_edges()
	f.close()
	if stored != _nav_signature():
		return false
	var nav: NavigationMesh = ResourceLoader.load(paths[0])
	if nav == null:
		return false
	navmesh = nav
	polygons = navmesh.get_polygon_count()
	vertices = navmesh.get_vertices().size()
	bake_ms = 0
	nav_cells = _area_cells()
	region = NavigationRegion3D.new()
	region.name = "NavigationRegion3D"
	region.navigation_mesh = navmesh
	add_child(region)
	print("NAV_CACHE hit polygons=%d vertices=%d" % [polygons, vertices])
	_stitch_islands()
	return true


func _nav_cache_save() -> void:
	if String(cache_id).is_empty() or navmesh == null or polygons <= 0:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://region_cache"))
	var paths := _nav_cache_paths()
	if ResourceSaver.save(navmesh, paths[0]) != OK:
		return
	var f := FileAccess.open(paths[1], FileAccess.WRITE)
	if f != null:
		f.store_string(_nav_signature())
		f.close()


## Rasterise the water bodies into the 1 m blocking grid.
##
## The project ships no map_layout.json, so the water mask was permanently empty
## and both the navmesh and the click filter treated rivers as dry ground.  The
## footprint is taken straight from the water materials instead, which is the
## same information the missing layout was supposed to carry.  Height cannot be
## used for this: the desert fountain sits at y=0.8 over a plaza at y=0, so a
## "below the waterline" rule would delete the whole plaza.
func _mask_water(map: Node) -> void:
	# The region measures the footprint before it hides or renames the authored
	# water, so prefer that over scanning materials that may already be hidden.
	if supplied_water.size() == GRID * GRID:
		_water = supplied_water
		var n := 0
		for v in _water:
			if v != 0:
				n += 1
		print("NAV_WATERMASK cells=%d (from region)" % n)
		var blocked_hits := 0
		var tested := 0
		for i in range(0, GRID, 7):
			for j in range(0, GRID, 7):
				if _water[j * GRID + i] == 0:
					continue
				tested += 1
				if _blocked(i - HALF, j - HALF):
					blocked_hits += 1
		print("NAV_WATERMASK blocked=%d/%d bridgesegs=%d" % [blocked_hits, tested, _bridge_segs.size()])
		return
	if _water.size() != GRID * GRID:
		_water = PackedByteArray()
		_water.resize(GRID * GRID)
		_water.fill(0)
	var marked := 0
	for n in map.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var mm := mi.mesh.surface_get_material(si)
			var nm := String(mm.resource_name).to_lower() if mm != null else ""
			if nm.is_empty() or not nm.contains("water") or nm.contains("hidden"):
				continue
			if nm.contains("waterfall") or nm.contains("jet"):
				continue
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var xf := mi.global_transform
			for v in vs:
				var w: Vector3 = xf * v
				var i := int(round(w.x + HALF))
				var j := int(round(w.z + HALF))
				if i < 0 or j < 0 or i >= GRID or j >= GRID:
					continue
				var key := j * GRID + i
				if _water[key] == 0:
					_water[key] = 1
					marked += 1
	print("NAV_WATERMASK cells=%d" % marked)


## True when this spot is water, using the same mask the navmesh used.
func is_water(p: Vector3) -> bool:
	if _water.size() != GRID * GRID:
		return false
	# The mask is a footprint: a bridge deck sits over a water cell while being
	# perfectly dry, so the height decides.  Without this a deck is refused as
	# water and cannot be clicked at all.
	if has_water and p.y > water_level + 0.35:
		return false
	var i := int(round(p.x + HALF))
	var j := int(round(p.z + HALF))
	if i < 0 or j < 0 or i >= GRID or j >= GRID:
		return false
	if _near_bridge(p.x, p.z):
		return false
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var ii: int = i + dx
			var jj: int = j + dz
			if ii >= 0 and jj >= 0 and ii < GRID and jj < GRID \
					and _water[jj * GRID + ii] != 0:
				return true
	return false


## Bake straight from hand-authored navmesh geometry.
##
## Every heuristic in this file -- ground meshes, walkable lists, material
## roles, slope caps, water masks -- exists to guess which triangles a player
## may stand on.  Guessing is what left the stone staircases unreachable while
## the one staircase that happened to sit on the terrain mesh worked fine.
## With marker objects the artist states it directly, and the guesswork is
## skipped entirely.
func _build_from_markers(markers: Array, map: Node3D, t0: int) -> void:
	var faces := PackedVector3Array()
	var tris := 0
	for n in markers:
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx = arr[Mesh.ARRAY_INDEX]
			var xf := mi.global_transform
			var count: int = vs.size() if idx == null else idx.size()
			for k in range(0, count - 2, 3):
				var a := xf * vs[k if idx == null else int(idx[k])]
				var b := xf * vs[(k + 1) if idx == null else int(idx[k + 1])]
				var c := xf * vs[(k + 2) if idx == null else int(idx[k + 2])]
				var nrm := (b - a).cross(c - a)
				if nrm.length_squared() < 1.0e-10:
					continue
				# Same convention as the terrain loop below: recast reads winding
				# with the opposite sign to cross(b-a, c-a), so an upward face is
				# emitted reversed.  Getting this backwards bakes 0 polygons.
				if nrm.normalized().y <= 0.0:
					faces.append(a); faces.append(b); faces.append(c)
				else:
					faces.append(a); faces.append(c); faces.append(b)
				tris += 1
	navmesh = NavigationMesh.new()
	navmesh.cell_size = CELL
	navmesh.cell_height = 0.10
	navmesh.agent_radius = AGENT_RADIUS
	navmesh.agent_height = 1.70
	navmesh.agent_max_climb = 0.70
	navmesh.agent_max_slope = 60.0
	navmesh.region_min_size = 0.0
	navmesh.edge_max_error = 1.2
	navmesh.detail_sample_distance = 1.0
	navmesh.detail_sample_max_error = 1.0
	navmesh.filter_ledge_spans = false
	navmesh.filter_walkable_low_height_spans = false
	source_faces = tris
	var src := NavigationMeshSourceGeometryData3D.new()
	src.add_faces(faces, Transform3D.IDENTITY)
	NavigationServer3D.bake_from_source_geometry_data(navmesh, src)
	bake_ms = Time.get_ticks_msec() - t0
	polygons = navmesh.get_polygon_count()
	vertices = navmesh.get_vertices().size()
	nav_cells = _area_cells()
	region = NavigationRegion3D.new()
	region.name = "NavigationRegion3D"
	region.navigation_mesh = navmesh
	add_child(region)
	print("NAV_MARKERS meshes=%d tris=%d polygons=%d bake_ms=%d" % [
		markers.size(), tris, polygons, bake_ms])
	_stitch_islands()


## Write the baked navmesh out as Wavefront OBJ.
##
## Lets the navmesh be opened, corrected and re-exported in a modelling tool
## instead of being re-guessed from the map meshes on every bake.
func dump_obj(path: String) -> bool:
	if navmesh == null or polygons <= 0:
		push_error("nav: nothing to dump")
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("nav: cannot write %s" % path)
		return false
	var verts := navmesh.get_vertices()
	for v in verts:
		f.store_line("v %.4f %.4f %.4f" % [v.x, v.y, v.z])
	for pi in polygons:
		var poly := navmesh.get_polygon(pi)
		if poly.size() < 3:
			continue
		var ids := PackedStringArray()
		for j in poly.size():
			ids.append(str(int(poly[j]) + 1))
		f.store_line("f " + " ".join(ids))
	f.close()
	print("NAVDUMP wrote %s verts=%d polys=%d" % [path, verts.size(), polygons])
	# The water footprint goes out beside it so an edited navmesh can drop the
	# faces that were baked over open water.
	if supplied_water.size() == GRID * GRID:
		var wp := path.get_basename() + "_water.txt"
		var wf := FileAccess.open(wp, FileAccess.WRITE)
		if wf != null:
			var n := 0
			for j in GRID:
				for i in GRID:
					if supplied_water[j * GRID + i] != 0:
						wf.store_line("%.2f %.2f" % [float(i) - HALF, float(j) - HALF])
						n += 1
			wf.close()
			print("NAVDUMP water cells=%d -> %s" % [n, wp])
	return true


## Join navmesh pieces that are separated only by a bake seam.
func _stitch_islands() -> void:
	if navmesh == null or polygons <= 0:
		return
	var verts := navmesh.get_vertices()
	var par := PackedInt32Array()
	par.resize(polygons)
	for i in polygons:
		par[i] = i
	# Group by shared edges, not by proximity: quantising coordinates split
	# polygons that clearly belong to one surface (1677 parts for a mesh that
	# has 77), which made every link join a fragment to itself.
	var edge_owner := {}
	for pi in polygons:
		var poly := navmesh.get_polygon(pi)
		for j in poly.size():
			var a_i := int(poly[j])
			var b_i := int(poly[(j + 1) % poly.size()])
			var k: int = (mini(a_i, b_i) << 20) | maxi(a_i, b_i)
			if edge_owner.has(k):
				var ra := _uf_root(par, pi)
				var rb := _uf_root(par, int(edge_owner[k]))
				if ra != rb:
					par[ra] = rb
			else:
				edge_owner[k] = pi
	var groups := {}
	for pi in polygons:
		var r := _uf_root(par, pi)
		if not groups.has(r):
			groups[r] = {}
		var poly := navmesh.get_polygon(pi)
		for j in poly.size():
			groups[r][int(poly[j])] = true
	var parts := []
	for r in groups.keys():
		parts.append((groups[r] as Dictionary).keys())
	parts.sort_custom(func(x, y): return x.size() > y.size())
	if parts.size() < 2:
		print("NAV_STITCH parts=1 links=0")
		return
	var body: Array = (parts[0] as Array).duplicate()
	# Bucket the connected body spatially: comparing every vertex of every piece
	# against the whole body was quadratic and cost 10-20 s on the big maps.
	var gcell := 1.6
	var buckets := {}
	for vb in body:
		var bp: Vector3 = verts[int(vb)]
		var bk := Vector3i(floori(bp.x / gcell), floori(bp.y / gcell), floori(bp.z / gcell))
		if not buckets.has(bk):
			buckets[bk] = []
		(buckets[bk] as Array).append(int(vb))
	var rest: Array = []
	for i in range(1, parts.size()):
		rest.append(parts[i])
	var links := 0
	var rings := int(ceil(stitch_max_gap / gcell)) + 1
	while not rest.is_empty():
		var best_d := INF
		var best_i := -1
		var best_a := Vector3.ZERO
		var best_b := Vector3.ZERO
		for i in rest.size():
			for va in (rest[i] as Array):
				var pa: Vector3 = verts[int(va)]
				var ck := Vector3i(floori(pa.x / gcell), floori(pa.y / gcell), floori(pa.z / gcell))
				for dy in range(-rings, rings + 1):
					for dz in range(-rings, rings + 1):
						for dx in range(-rings, rings + 1):
							var k2 := Vector3i(ck.x + dx, ck.y + dy, ck.z + dz)
							if not buckets.has(k2):
								continue
							for vb in (buckets[k2] as Array):
								var d: float = pa.distance_squared_to(verts[int(vb)])
								if d < best_d:
									best_d = d
									best_i = i
									best_a = pa
									best_b = verts[int(vb)]
		if best_i < 0:
			break
		var gap := sqrt(best_d)
		if gap > stitch_max_gap or absf(best_a.y - best_b.y) > stitch_max_rise:
			rest.remove_at(best_i)
			continue
		var link := NavigationLink3D.new()
		link.name = "NavStitch%d" % links
		link.start_position = best_a
		link.end_position = best_b
		link.bidirectional = true
		add_child(link)
		links += 1
		for vb in (rest[best_i] as Array):
			var bp2: Vector3 = verts[int(vb)]
			var bk2 := Vector3i(floori(bp2.x / gcell), floori(bp2.y / gcell), floori(bp2.z / gcell))
			if not buckets.has(bk2):
				buckets[bk2] = []
			(buckets[bk2] as Array).append(int(vb))
		body.append_array(rest[best_i] as Array)
		rest.remove_at(best_i)
	print("NAV_STITCH parts=%d links=%d unreached=%d" % [parts.size(), links, rest.size()])


func _uf_root(par: PackedInt32Array, i: int) -> int:
	var x := i
	while par[x] != x:
		par[x] = par[par[x]]
		x = par[x]
	return x


## True when this spot is inside the water footprint.
func _over_water(x: float, z: float) -> bool:
	if supplied_water.size() != GRID * GRID:
		return false
	var i := int(round(x + HALF))
	var j := int(round(z + HALF))
	if i < 0 or j < 0 or i >= GRID or j >= GRID:
		return false
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var ii: int = i + dx
			var jj: int = j + dz
			if ii >= 0 and jj >= 0 and ii < GRID and jj < GRID \
					and supplied_water[jj * GRID + ii] != 0:
				return true
	return false


## Write quads wherever solid ground exists but the navmesh does not.
##
## The baked mesh has holes where the rasteriser dropped contours -- in front of
## the stone stairs, for instance -- and an open hole cannot be filled by
## bridging edges because there is no loop to bridge.  Ground is sampled with
## downward rays instead, and only the uncovered cells are emitted, so the
## result can be merged into an edited navmesh without duplicating faces.
func dump_gap_patch(path: String, step := 0.5) -> bool:
	if navmesh == null or polygons <= 0:
		return false
	var verts := navmesh.get_vertices()
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for v in verts:
		lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
		hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
	lo -= Vector3(6, 0, 6)
	hi += Vector3(6, 0, 6)
	# Rasterise the existing navmesh so covered cells are skipped.
	var nx := int(ceil((hi.x - lo.x) / step)) + 1
	var nz := int(ceil((hi.z - lo.z) / step)) + 1
	var covered := PackedByteArray()
	covered.resize(nx * nz)
	covered.fill(0)
	for pi in polygons:
		var poly := navmesh.get_polygon(pi)
		for j in range(1, poly.size() - 1):
			var a := verts[int(poly[0])]
			var b := verts[int(poly[j])]
			var c := verts[int(poly[j + 1])]
			var minx := minf(a.x, minf(b.x, c.x))
			var maxx := maxf(a.x, maxf(b.x, c.x))
			var minz := minf(a.z, minf(b.z, c.z))
			var maxz := maxf(a.z, maxf(b.z, c.z))
			var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
			if absf(d) < 1.0e-9:
				continue
			for gz in range(int(floor((minz - lo.z) / step)), int(ceil((maxz - lo.z) / step)) + 1):
				for gx in range(int(floor((minx - lo.x) / step)), int(ceil((maxx - lo.x) / step)) + 1):
					if gx < 0 or gz < 0 or gx >= nx or gz >= nz:
						continue
					var px := lo.x + gx * step
					var pz := lo.z + gz * step
					var w1 := ((b.z - c.z) * (px - c.x) + (c.x - b.x) * (pz - c.z)) / d
					var w2 := ((c.z - a.z) * (px - c.x) + (a.x - c.x) * (pz - c.z)) / d
					if w1 < -0.02 or w2 < -0.02 or (1.0 - w1 - w2) < -0.02:
						continue
					covered[gz * nx + gx] = 1
	# Only grow the mesh near what already exists: a gap in front of a staircase
	# is a few cells wide, whereas a rooftop is metres away and must stay out.
	var dist := PackedInt32Array()
	dist.resize(nx * nz)
	dist.fill(-1)
	var queue: Array = []
	for i in covered.size():
		if covered[i] != 0:
			dist[i] = 0
			queue.append(i)
	var head := 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		var cx := cur % nx
		var cz := cur / nx
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nxp: int = cx + d.x
			var nzp: int = cz + d.y
			if nxp < 0 or nzp < 0 or nxp >= nx or nzp >= nz:
				continue
			var ni := nzp * nx + nxp
			if dist[ni] == -1:
				dist[ni] = dist[cur] + 1
				queue.append(ni)
	var reach_cells := int(ceil(3.0 / step))
	var space := get_world_3d().direct_space_state
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("nav: cannot write %s" % path)
		return false
	var quads := 0
	var cells := 0
	for gz in nz:
		for gx in nx:
			if covered[gz * nx + gx] != 0:
				continue
			if dist[gz * nx + gx] < 0 or dist[gz * nx + gx] > reach_cells:
				continue
			var px := lo.x + gx * step
			var pz := lo.z + gz * step
			if _over_water(px, pz):
				continue
			var from := Vector3(px, hi.y + 6.0, pz)
			var to := Vector3(px, lo.y - 6.0, pz)
			var q := PhysicsRayQueryParameters3D.create(from, to, 3)
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			var nrm: Vector3 = hit.get("normal", Vector3.UP)
			if nrm.y < 0.55:
				continue
			var col = hit.get("collider")
			var cname := String((col as Node).name) if col is Node else ""
			# Foliage and loose props are not floor, however flat their tops are.
			if cname.contains("Vegetation") or cname.contains("Props"):
				continue
			var y: float = (hit["position"] as Vector3).y
			cells += 1
			var h := step * 0.5
			var p00 := Vector3(px - h, y, pz - h)
			var p10 := Vector3(px + h, y, pz - h)
			var p11 := Vector3(px + h, y, pz + h)
			var p01 := Vector3(px - h, y, pz + h)
			for v in [p00, p10, p11, p01]:
				f.store_line("v %.3f %.3f %.3f" % [v.x, v.y, v.z])
			var b := quads * 4
			f.store_line("f %d %d %d" % [b + 1, b + 2, b + 3])
			f.store_line("f %d %d %d" % [b + 1, b + 3, b + 4])
			quads += 1
	f.close()
	print("NAVPATCH cells=%d quads=%d -> %s" % [cells, quads, path])
	return quads > 0


## Emit a continuous heightfield navmesh for the whole map.
##
## This game is 2.5D: one walkable level per area, reached by steps and ramps.
## The recast bake keeps splitting that surface into islands because it works on
## contours, so instead the floor is sampled on a grid and emitted as one
## connected sheet.  Stairs become a ramp of 0.5 m cells, which the bake climbs
## with agent_max_climb, and there are no seams to stitch.
func dump_heightnav(path: String, step := 0.5) -> bool:
	var space := get_world_3d().direct_space_state
	var lo := Vector3(-48.0, -2.0, -48.0)
	var hi := Vector3(48.0, 30.0, 48.0)
	var nx := int(ceil((hi.x - lo.x) / step)) + 1
	var nz := int(ceil((hi.z - lo.z) / step)) + 1
	var ok := PackedByteArray()
	ok.resize(nx * nz)
	ok.fill(0)
	var ys := PackedFloat32Array()
	ys.resize(nx * nz)
	ys.fill(NAN)
	for gz in nz:
		for gx in nx:
			var px := lo.x + gx * step
			var pz := lo.z + gz * step
			if _over_water(px, pz):
				continue
			var q := PhysicsRayQueryParameters3D.create(
				Vector3(px, hi.y, pz), Vector3(px, lo.y, pz), 3)
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			var nrm: Vector3 = hit.get("normal", Vector3.UP)
			if nrm.y < 0.55:
				continue
			var col = hit.get("collider")
			var cname := String((col as Node).name) if col is Node else ""
			if cname.contains("Vegetation") or cname.contains("Props"):
				continue
			ok[gz * nx + gx] = 1
			ys[gz * nx + gx] = (hit["position"] as Vector3).y
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("nav: cannot write %s" % path)
		return false
	var base := 0
	var quads := 0
	for gz in nz - 1:
		for gx in nx - 1:
			var i00 := gz * nx + gx
			var i10 := gz * nx + gx + 1
			var i01 := (gz + 1) * nx + gx
			var i11 := (gz + 1) * nx + gx + 1
			if ok[i00] == 0 or ok[i10] == 0 or ok[i01] == 0 or ok[i11] == 0:
				continue
			var x0 := lo.x + gx * step
			var x1 := x0 + step
			var z0 := lo.z + gz * step
			var z1 := z0 + step
			var p00 := Vector3(x0, ys[i00], z0)
			var p10 := Vector3(x1, ys[i10], z0)
			var p01 := Vector3(x0, ys[i01], z1)
			var p11 := Vector3(x1, ys[i11], z1)
			for v in [p00, p10, p11, p01]:
				f.store_line("v %.3f %.3f %.3f" % [v.x, v.y, v.z])
			var b := base * 4
			f.store_line("f %d %d %d" % [b + 1, b + 2, b + 3])
			f.store_line("f %d %d %d" % [b + 1, b + 3, b + 4])
			base += 1
			quads += 1
	f.close()
	print("NAVHEIGHT step=%.2f quads=%d -> %s" % [step, quads, path])
	return quads > 0
