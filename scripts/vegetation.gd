extends Node
## Vegetation - wind sway for the tree props.
##
## The tree GLBs carry a baked sway weight in COLOR_0.a (0 at the root, ~1 at
## the canopy). Nothing read it before this script. Each tree surface gets a
## ShaderMaterial that replaces only the material, preserving the shipped
## albedo, normal and roughness textures, UV1 scale/offset, roughness and the
## COLOR_0.rgb multiplied into albedo. The original materials are untouched.
##
## Trunk and canopy are distinguished by the baked alpha profile: a surface with
## vertices at alpha < 0.25 is bark (weighted lower), the canopy keeps full
## weight. No map.gd edits; this is an autoload that adopts tree MeshInstances
## when they enter the tree.

const SHADER_PATH := "res://shaders/vegetation.gdshader"

@export_group("Wind")
## Metres of tip travel at COLOR_0.a = 1, before trunk weighting.
@export_range(0.0, 1.0, 0.005) var wind_strength: float = 0.12
@export_range(0.0, 8.0, 0.01) var wind_speed: float = 1.35
## Compass direction the wind blows toward: 0 = +Z, 90 = +X.
@export_range(-180.0, 180.0, 0.1) var wind_direction_deg: float = 65.0
## Spatial phase per metre. Larger = neighbouring trees less in sync.
@export_range(0.01, 2.0, 0.01) var wind_scale: float = 0.35

@export_group("Trunk vs canopy")
## Bark still moves a little; it is a tree, not a lamp post.
@export_range(0.0, 1.0, 0.01) var trunk_weight: float = 0.28
@export_range(0.0, 1.0, 0.01) var canopy_weight: float = 1.0
## A surface whose minimum COLOR_0.a is below this is treated as bark.
@export_range(0.0, 1.0, 0.01) var trunk_alpha_threshold: float = 0.25

@export_group("Distance")
@export_range(20.0, 400.0, 1.0) var distance_cutoff: float = 120.0
@export_range(0.0, 100.0, 0.5) var distance_fade: float = 25.0

var _shader: Shader
var _cache: Dictionary = {}
var _materials: Array[ShaderMaterial] = []
var _alpha_cache: Dictionary = {}
var _trees: int = 0
var _trunks: int = 0
var _canopies: int = 0
var _frames: int = 0
var _foliage_cards: int = 0
var _foliage_tris: int = 0
var _dead_branches: int = 0
var _card_mesh: ArrayMesh
var _card_mat: ShaderMaterial
var _card_mat_pink: ShaderMaterial
var _branch_mat: StandardMaterial3D

const LEAF_ATLAS := "res://assets/textures/leaf_green_atlas_1024.png"
const LEAF_PINK := "res://assets/textures/leaf_pink_atlas_1024.png"
const CARDS_PER_CANOPY := 160
const DETAIL_CARDS := 240


func _ready() -> void:
	_shader = load(SHADER_PATH) as Shader
	if _shader == null:
		push_error("vegetation: shader missing")
		return
	_card_mesh = _make_card_mesh()
	_card_mat = _make_card_material(LEAF_ATLAS)
	_card_mat_pink = _make_card_material(LEAF_PINK)
	_materials.append(_card_mat)
	_materials.append(_card_mat_pink)
	_branch_mat = StandardMaterial3D.new()
	_branch_mat.albedo_color = Color(0.18, 0.10, 0.05)
	_branch_mat.roughness = 0.92
	_branch_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	get_tree().node_added.connect(_on_node_added)
	_scan.call_deferred()


func _process(_delta: float) -> void:
	# Exports are tunable at runtime; refreshing four integers every half second
	# is cheaper than a setter on each export.
	_frames += 1
	if _frames % 30 == 1:
		for mat in _materials:
			_set_wind(mat)
	_update_player_occlusion()


func _update_player_occlusion() -> void:
	var scene := get_tree().current_scene
	var p: Node3D = null
	if scene != null:
		p = scene.get_node_or_null("Player") as Node3D
	if p == null:
		p = get_tree().root.get_node_or_null("Game/Player") as Node3D
	var cam: Camera3D = null
	if p != null and p.get_parent() != null:
		cam = p.get_parent().get("camera") as Camera3D
	if cam == null:
		cam = get_viewport().get_camera_3d()
	if p == null or cam == null:
		_apply_player_params(Vector2(-1, -1), 0.0, 0.0)
		return
	var head := p.global_position + Vector3.UP * 0.92
	if cam.is_position_behind(head):
		_apply_player_params(Vector2(-1, -1), 0.0, 0.0)
		return
	var vp := get_viewport().get_texture().get_size()
	if vp.x < 1.0:
		vp = get_viewport().get_visible_rect().size
	var sp := cam.unproject_position(head)
	_apply_player_params(Vector2(sp.x / maxf(1.0, vp.x), sp.y / maxf(1.0, vp.y)),
			cam.global_position.distance_to(head), 1.0)

func _apply_player_params(screen: Vector2, depth: float, active: float) -> void:
	for mat in _materials:
		if mat == null:
			continue
		mat.set_shader_parameter("player_screen", screen)
		mat.set_shader_parameter("player_depth", depth)
		mat.set_shader_parameter("player_active", active)

func _on_node_added(node: Node) -> void:
	if node is MeshInstance3D:
		_apply_to.call_deferred(node as MeshInstance3D)


func _scan() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		_apply_to(node as MeshInstance3D)
	if _trees > 0:
		print("vegetation: %d trees, %d trunk / %d canopy surfaces, %d materials" % [
				_trees, _trunks, _canopies, _materials.size()])
		print("foliage: %d cards, %d branch meshes, +%d tris (%.1f cards/tree)" % [
				_foliage_cards, _dead_branches, _foliage_tris,
				float(_foliage_cards) / maxf(1.0, float(_trees))])


func _apply_to(mi: MeshInstance3D) -> void:
	if mi == null or mi.get_meta("_vegetation_sway", false):
		return
	if not _looks_like_tree(mi):
		return
	var mesh := mi.mesh
	if mesh == null:
		return

	var applied := false
	for s in range(mesh.get_surface_count()):
		var alpha_min := _surface_alpha_min(mesh, s)
		if alpha_min > 1.0:
			continue
		var source := mi.get_surface_override_material(s)
		if source == null:
			source = mesh.surface_get_material(s)
		if not (source is StandardMaterial3D):
			continue
		var is_trunk := alpha_min < trunk_alpha_threshold
		var mat := _material_for(source as StandardMaterial3D, is_trunk, alpha_min)
		mi.set_surface_override_material(s, mat)
		if is_trunk:
			_trunks += 1
		else:
			_canopies += 1
		applied = true

	if applied:
		mi.set_meta("_vegetation_sway", true)
		_trees += 1
		_add_foliage(mi)


func _looks_like_tree(mi: MeshInstance3D) -> bool:
	var n := mi.name.to_lower()
	if n.contains("crystal"):
		return false
	if n.contains("tree"):
		return true
	# Some importers put the model name on the parent; check one level up.
	var p := mi.get_parent()
	if p != null:
		var pn := p.name.to_lower()
		if pn.contains("crystal"):
			return false
		if pn.contains("tree"):
			return true
	return false


## Min COLOR_0.a per surface, cached per mesh. Returns 2.0 if the surface has
## no vertex colours, which also filters out non-vegetation meshes.
func _surface_alpha_min(mesh: Mesh, s: int) -> float:
	var key := "%d:%d" % [mesh.get_instance_id(), s]
	if _alpha_cache.has(key):
		return _alpha_cache[key]
	var alpha_min := 2.0
	var arrays := mesh.surface_get_arrays(s)
	var cols = arrays[Mesh.ARRAY_COLOR]
	if cols != null:
		for c in cols:
			alpha_min = minf(alpha_min, c.a)
	_alpha_cache[key] = alpha_min
	return alpha_min


func _material_for(source: StandardMaterial3D, is_trunk: bool, _alpha_min: float) -> ShaderMaterial:
	var key := "%d:%s" % [source.get_instance_id(), "trunk" if is_trunk else "canopy"]
	if _cache.has(key):
		return _cache[key]

	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("sway_weight", trunk_weight if is_trunk else canopy_weight)

	var tex := source.albedo_texture
	mat.set_shader_parameter("has_albedo", tex != null)
	if tex != null:
		mat.set_shader_parameter("albedo_tex", tex)
	mat.set_shader_parameter("albedo_color", source.albedo_color * (1.0 if is_trunk else 1.45))
	mat.set_shader_parameter("use_vertex_color", source.vertex_color_use_as_albedo)

	var ntex := source.normal_texture
	mat.set_shader_parameter("has_normal", source.normal_enabled and ntex != null)
	if source.normal_enabled and ntex != null:
		mat.set_shader_parameter("normal_tex", ntex)
	mat.set_shader_parameter("normal_scale", source.normal_scale)

	var rtex := source.roughness_texture
	mat.set_shader_parameter("has_roughness", rtex != null)
	if rtex != null:
		mat.set_shader_parameter("roughness_tex", rtex)
	mat.set_shader_parameter("roughness_value", source.roughness)

	mat.set_shader_parameter("uv_scale", Vector2(source.uv1_scale.x, source.uv1_scale.y))
	mat.set_shader_parameter("uv_offset", Vector2(source.uv1_offset.x, source.uv1_offset.y))
	_set_wind(mat)
	_materials.append(mat)
	_cache[key] = mat
	return mat



# ---------------------------------------------------------------------------
# Procedural canopy cards.  No new asset pipeline: one tiny alpha-cut quad is
# scattered over the existing canopy surface by a MultiMesh, with per-card
# colour and orientation.  A few trees also get bare branch cards.
# ---------------------------------------------------------------------------

func _make_card_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 6:
		st.set_normal(Vector3(0, 0, 1))
		st.set_color(Color(1, 1, 1, 1))
	var uv := [Vector2(0,0), Vector2(1,0), Vector2(1,1),
			Vector2(0,0), Vector2(1,1), Vector2(0,1)]
	var vv := [Vector3(-0.5,-0.5,0), Vector3(0.5,-0.5,0), Vector3(0.5,0.5,0),
			Vector3(-0.5,-0.5,0), Vector3(0.5,0.5,0), Vector3(-0.5,0.5,0)]
	for i in 6:
		st.set_uv(uv[i])
		st.add_vertex(vv[i])
	return st.commit()

func _make_card_material(atlas: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("is_card", true)
	mat.set_shader_parameter("has_albedo", true)
	mat.set_shader_parameter("albedo_tex", load(atlas))
	mat.set_shader_parameter("albedo_color",
			Color(0.80, 0.88, 0.70, 1.0) if atlas.contains("green") else Color(1, 1, 1, 1))
	mat.set_shader_parameter("use_vertex_color", false)
	mat.set_shader_parameter("uv_scale", Vector2(0.5, 0.5))
	mat.set_shader_parameter("uv_offset", Vector2.ZERO)
	mat.set_shader_parameter("alpha_cut", 0.42)
	mat.set_shader_parameter("sway_weight", 1.0)
	mat.set_shader_parameter("roughness_value", 0.88)
	mat.set_shader_parameter("backlight_strength", 0.20)
	var pink := atlas.contains("pink")
	mat.set_shader_parameter("card_saturation", 0.55 if pink else 1.0)
	mat.set_shader_parameter("card_emission", 0.65 if pink else 1.0)
	return mat

func _tree_root(mi: MeshInstance3D) -> Node3D:
	var n: Node3D = mi
	while n != null and n.get_parent() != null:
		if n.name.to_lower().contains("tree"):
			return n
		n = n.get_parent()
	return mi

func _add_foliage(mi: MeshInstance3D) -> void:
	if OS.get_environment("FOLIAGE_DISABLE") == "1":
		return
	if mi.has_meta("_foliage_added"):
		return
	mi.set_meta("_foliage_added", true)
	var mesh := mi.mesh
	if mesh == null:
		return
	# Canopy = any surface whose COLOR_0.a profile is not bark.
	var pts: Array[Vector3] = []
	var nrms: Array[Vector3] = []
	var weights: Array[float] = []
	for s in range(mesh.get_surface_count()):
		if _surface_alpha_min(mesh, s) < trunk_alpha_threshold:
			continue
		var a := mesh.surface_get_arrays(s)
		var vs: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var ns = a[Mesh.ARRAY_NORMAL]
		var idx = a[Mesh.ARRAY_INDEX]
		var ids: PackedInt32Array
		if idx == null:
			ids = PackedInt32Array()
			for k in range(vs.size()):
				ids.append(k)
		else:
			ids = idx as PackedInt32Array
		for t in range(0, ids.size() - 2, 3):
			var ia := int(ids[t]); var ib := int(ids[t+1]); var ic := int(ids[t+2])
			var pa := vs[ia]; var pb := vs[ib]; var pc := vs[ic]
			var ar := 0.5 * (pb - pa).cross(pc - pa).length()
			if ar < 1e-8:
				continue
			pts.append(pa); pts.append(pb); pts.append(pc)
			if ns != null:
				nrms.append(ns[ia]); nrms.append(ns[ib]); nrms.append(ns[ic])
			else:
				var fn := (pb - pa).cross(pc - pa).normalized()
				nrms.append(fn); nrms.append(fn); nrms.append(fn)
			weights.append(ar); weights.append(ar); weights.append(ar)
	if pts.is_empty():
		return
	var center := Vector3.ZERO
	var mn := pts[0]; var mx := pts[0]
	for p in pts:
		center += p; mn = mn.min(p); mx = mx.max(p)
	center /= float(pts.size())
	var radius := maxf(0.3, (mx - mn).length() * 0.5)

	var root := _tree_root(mi)
	# Slight per-instance non-uniform canopy/root scale + a little extra yaw.
	# This is the only change to the existing model transform.
	if not root.has_meta("_foliage_variation"):
		root.set_meta("_foliage_variation", true)
		var rv := RandomNumberGenerator.new()
		rv.seed = hash(mi.global_position) ^ 0x9E3779B9
		root.scale = root.scale * Vector3(rv.randf_range(0.93, 1.07),
				rv.randf_range(0.95, 1.06), rv.randf_range(0.93, 1.07))
		root.rotate_y(rv.randf_range(-0.16, 0.16))

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(mi.global_position) ^ 0x51ED270B
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.instance_count = CARDS_PER_CANOPY
	mm.mesh = _card_mesh
	for i in CARDS_PER_CANOPY:
		var ti := _weighted_tri(rng, weights)
		var base := ti * 3
		var pa := pts[base]; var pb := pts[base+1]; var pc := pts[base+2]
		var u := rng.randf(); var v := rng.randf()
		if u + v > 1.0:
			u = 1.0 - u; v = 1.0 - v
		var p := pa + (pb - pa) * u + (pc - pa) * v
		var n := nrms[base] + nrms[base+1] + nrms[base+2]
		if n.length() < 1e-5:
			n = (pb - pa).cross(pc - pa)
		n = n.normalized()
		# One in five cards sits inside the crown, in shadow.
		var interior := (i % 5) == 0
		if interior:
			p = center + (p - center) * 0.58
			n = (p - center).normalized()
		var outward := (p - center)
		if outward.length() < 1e-4:
			outward = n
		p += outward.normalized() * rng.randf_range(0.005, 0.07)
		# Card plane tangent to the crown, random roll around the normal.
		var t := n.cross(Vector3.UP)
		if t.length() < 0.05:
			t = n.cross(Vector3.RIGHT)
		t = t.normalized()
		var b := n.cross(t).normalized()
		var roll := rng.randf_range(0.0, TAU)
		var t2 := (t * cos(roll) + b * sin(roll)).normalized()
		var b2 := n.cross(t2).normalized()
		# Redistribute, do not multiply: 20 large masses, 54 small edge
		# cards pushed onto the silhouette, the rest medium.  Total stays 160.
		var legacy := OS.get_environment("FOLIAGE_LEGACY") == "1"
		var large := (i % 24) == 0 and not legacy
		var edge := (i % 2) == 0 and not large and not legacy
		var sx: float
		var sy: float
		if edge:
			sx = rng.randf_range(0.13, 0.21)
			sy = rng.randf_range(0.12, 0.19)
		elif large:
			sx = rng.randf_range(0.40, 0.58)
			sy = rng.randf_range(0.34, 0.50)
		elif legacy:
			sx = rng.randf_range(0.18, 0.36)
			sy = rng.randf_range(0.16, 0.32)
		else:
			sx = rng.randf_range(0.20, 0.34)
			sy = rng.randf_range(0.18, 0.30)
		if edge:
			# Pull the small cards just inside the crown surface so a lone card
			# cannot float free of its neighbour support.
			p = center + (p - center) * 0.90
		var basis := Basis(t2 * sx, b2 * sy, n)
		mm.set_instance_transform(i, Transform3D(basis, p))
		# Two-tone: dark inside, brighter sky-facing outside, per-tree tint.
		var radial := clampf((p - center).length() / radius, 0.0, 1.0)
		var shade := lerpf(0.60, 1.16, radial)
		if interior:
			shade *= 0.78
		var tint := Color(0.92 + 0.06 * rng.randf(), 0.96 + 0.06 * rng.randf(),
				0.86 + 0.08 * rng.randf()) if legacy else Color(
				0.84 + 0.16 * rng.randf(), 0.88 + 0.14 * rng.randf(),
				0.74 + 0.22 * rng.randf())
		# 0..15 packed: leaf cell 0-3 plus a 90-degree screen rotation.
		var code := 0 if legacy else rng.randi_range(0, 15)
		mm.set_instance_custom_data(i, Color(tint.r * shade, tint.g * shade,
				tint.b * shade, float(code) / 15.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "FoliageCards"
	mmi.multimesh = mm
	mmi.material_override = _card_mat_pink if mi.name.to_lower().contains("blossom") else _card_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(mn - Vector3(radius,radius,radius) * 0.3,
			(mx - mn) + Vector3(radius,radius,radius) * 0.6)
	mmi.visibility_range_begin = 8.0
	mmi.visibility_range_begin_margin = 1.0
	mmi.visibility_range_end = 120.0
	root.add_child(mmi)
	_foliage_cards += CARDS_PER_CANOPY
	_foliage_tris += CARDS_PER_CANOPY * 2

	# Near-camera detail layer.  The base cards carry four atlas leaves each;
	# these smaller cards add the fine silhouette that only reads inside 12 m.
	# They share the same material, shader and player-fade uniforms.
	if not (OS.get_environment("FOLIAGE_LEGACY") == "1"):
		var dmm := MultiMesh.new()
		dmm.transform_format = MultiMesh.TRANSFORM_3D
		dmm.use_custom_data = true
		dmm.instance_count = DETAIL_CARDS
		dmm.mesh = _card_mesh
		for i in DETAIL_CARDS:
			var ti := _weighted_tri(rng, weights)
			var base := ti * 3
			var pa := pts[base]; var pb := pts[base+1]; var pc := pts[base+2]
			var u := rng.randf(); var v := rng.randf()
			if u + v > 1.0:
				u = 1.0 - u; v = 1.0 - v
			var p := pa + (pb - pa) * u + (pc - pa) * v
			var n := nrms[base] + nrms[base+1] + nrms[base+2]
			if n.length() < 1e-5:
				n = (pb - pa).cross(pc - pa)
			n = n.normalized()
			var outward := (p - center)
			if outward.length() < 1e-4:
				outward = n
			p += outward.normalized() * rng.randf_range(0.01, 0.05)
			var t := n.cross(Vector3.UP)
			if t.length() < 0.05:
				t = n.cross(Vector3.RIGHT)
			t = t.normalized()
			var b := n.cross(t).normalized()
			var roll := rng.randf_range(0.0, TAU)
			var t2 := (t * cos(roll) + b * sin(roll)).normalized()
			var b2 := n.cross(t2).normalized()
			var sx := rng.randf_range(0.08, 0.14)
			var sy := rng.randf_range(0.07, 0.12)
			dmm.set_instance_transform(i, Transform3D(Basis(t2 * sx, b2 * sy, n), p))
			var radial := clampf((p - center).length() / radius, 0.0, 1.0)
			var shade := lerpf(0.64, 1.12, radial)
			var tint := Color(0.86 + 0.14 * rng.randf(), 0.90 + 0.12 * rng.randf(),
					0.78 + 0.20 * rng.randf())
			var code := rng.randi_range(0, 15)
			dmm.set_instance_custom_data(i, Color(tint.r * shade, tint.g * shade,
					tint.b * shade, float(code) / 15.0))
		var dmi := MultiMeshInstance3D.new()
		dmi.name = "FoliageDetail"
		dmi.multimesh = dmm
		dmi.material_override = _card_mat_pink if mi.name.to_lower().contains("blossom") else _card_mat
		dmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		dmi.custom_aabb = AABB(mn - Vector3(radius,radius,radius) * 0.3,
				(mx - mn) + Vector3(radius,radius,radius) * 0.6)
		dmi.visibility_range_end = 12.0
		dmi.visibility_range_end_margin = 1.0
		dmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		root.add_child(dmi)
		_foliage_cards += DETAIL_CARDS
		_foliage_tris += DETAIL_CARDS * 2

	# Dead-branch cards are deliberately disabled.  They are straight, unshaded
	# strips that read as "long branches growing in all directions" from the
	# side; leaf cards alone give the crown its silhouette.
	if false and rng.randf() < 0.27:
		_add_dead_branches(root, center, radius, rng)

func _weighted_tri(rng: RandomNumberGenerator, weights: Array[float]) -> int:
	var total := 0.0
	for w in weights:
		total += w
	var pick := rng.randf() * total
	var acc := 0.0
	for i in weights.size():
		acc += weights[i]
		if pick <= acc:
			return i / 3
	return maxi(0, (weights.size() / 3) - 1)

func _add_dead_branches(root: Node3D, center: Vector3, radius: float,
		rng: RandomNumberGenerator) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var branches := 5
	for b in branches:
		var dir := Vector3(rng.randf_range(-1,1), rng.randf_range(-0.15,0.65),
				rng.randf_range(-1,1)).normalized()
		if dir.y < 0.0:
			dir.y = -dir.y * 0.25
		var start := center + dir * radius * rng.randf_range(0.20, 0.35)
		var end := center + dir * radius * rng.randf_range(1.02, 1.26)
		var w := rng.randf_range(0.025, 0.045)
		var side := dir.cross(Vector3.UP)
		if side.length() < 0.05:
			side = dir.cross(Vector3.RIGHT)
		side = side.normalized() * w
		var side2 := dir.cross(side).normalized() * w
		_quad(st, start - side, end - side, end + side, start + side)
		_quad(st, start - side2, end - side2, end + side2, start + side2)
	var mi := MeshInstance3D.new()
	mi.name = "DeadBranches"
	mi.mesh = st.commit()
	mi.material_override = _branch_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	_dead_branches += 1
	_foliage_tris += branches * 4

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var n := (b - a).cross(c - a).normalized()
	for p in [a, b, c, a, c, d]:
		st.set_normal(n)
		st.set_color(Color(1,1,1,1))
		st.add_vertex(p)

func _set_wind(mat: ShaderMaterial) -> void:
	var dir := Vector2(cos(deg_to_rad(wind_direction_deg)),
			sin(deg_to_rad(wind_direction_deg)))
	mat.set_shader_parameter("wind_strength", wind_strength)
	mat.set_shader_parameter("wind_speed", wind_speed)
	mat.set_shader_parameter("wind_dir", dir)
	mat.set_shader_parameter("wind_scale", wind_scale)
	mat.set_shader_parameter("distance_cutoff", distance_cutoff)
	mat.set_shader_parameter("distance_fade", distance_fade)
