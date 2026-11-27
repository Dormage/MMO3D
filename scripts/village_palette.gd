extends RefCounted
class_name VillagePalette
## Central material identity for every modular building and village prop.
## Slots come from the shared GLB material names; no GLB is edited.  The colours
## are deliberately compensated for the warm Atmosphere grade: the stone is
## cool-blue enough to render neutral, the plaster is cream, and the wood is a
## saturated brown.

const COLORS := {
	"stone": Color(0.235, 0.205, 0.165, 1.0),
	"plaster": Color(0.475, 0.458, 0.438, 1.0),
	"wood": Color(0.210, 0.145, 0.095, 1.0),
	"metal_dark": Color(0.115, 0.090, 0.070, 1.0),
	"trim": Color(0.168, 0.118, 0.082, 1.0),
	"grip": Color(0.105, 0.065, 0.042, 1.0),
}

const STONE_SHADER := preload("res://shaders/stone_palette.gdshader")
const SURFACE_SHADER := preload("res://shaders/palette_surface.gdshader")
const STONE_ROUGH_SHADER := preload("res://shaders/stone_roughness.gdshader")
const STONE_LIT := Color(0.240, 0.272, 0.238, 1.0)
const STONE_SHADOW := Color(0.200, 0.212, 0.198, 1.0)

const ROUGH := {
	"stone": 0.95, "plaster": 0.92, "wood": 1.0,
	"metal_dark": 0.68, "trim": 1.0, "grip": 0.88,
}

const METAL := {
	"stone": 0.0, "plaster": 0.0, "wood": 0.0,
	"metal_dark": 0.35, "trim": 0.55, "grip": 0.0,
}

## Unique unshaded IDs used only for ROI measurement.
const DEBUG_COLORS := {
	"stone": Color(1, 0, 0, 1),
	"plaster": Color(0, 0, 1, 1),
	"wood": Color(0, 1, 0, 1),
	"metal_dark": Color(1, 1, 0, 1),
	"trim": Color(1, 0, 1, 1),
	"grip": Color(0, 1, 1, 1),
}

static var _mats: Dictionary = {}
static var _baked_surfaces: Dictionary = {}
static var _stone_mat: ShaderMaterial = null
static var _debug_mats: Dictionary = {}
static var _cloth_mats: Dictionary = {}
static var _reported: Dictionary = {}

static func _base_slot(name: String) -> String:
	return name.get_slice(".", 0).to_lower()

static func material(slot: String) -> Material:
	var key := _base_slot(slot)
	if not COLORS.has(key):
		return null
	if key == "stone":
		if _stone_mat != null:
			return _stone_mat
		var sm := ShaderMaterial.new()
		sm.shader = STONE_ROUGH_SHADER if OS.get_environment("SURFACE_DEBUG") == "rough" else STONE_SHADER
		sm.set_shader_parameter("lit_color", STONE_LIT)
		sm.set_shader_parameter("shadow_color", STONE_SHADOW)
		sm.set_shader_parameter("sun_dir",
				Vector3(cos(deg_to_rad(28.0)) * sin(deg_to_rad(45.0)),
						sin(deg_to_rad(28.0)),
						cos(deg_to_rad(28.0)) * cos(deg_to_rad(45.0))).normalized())
		sm.set_shader_parameter("roughness_debug", OS.get_environment("SURFACE_DEBUG") == "rough")
		sm.set_shader_parameter("debug_b", OS.get_environment("SURFACE_DEBUG") == "b")
		_stone_mat = sm
		return sm
	if _mats.has(key):
		return _mats[key]
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	m.set_shader_parameter("base_color", COLORS[key])
	m.set_shader_parameter("shadow_sky", Color(0.160, 0.180, 0.210, 1.0))
	m.set_shader_parameter("shadow_energy", 1.0)
	m.set_shader_parameter("roughness_value", float(ROUGH[key]))
	m.set_shader_parameter("metallic_value", float(METAL[key]))
	var kinds := {"plaster": 0, "wood": 1, "metal_dark": 2, "trim": 3, "grip": 4}
	m.set_shader_parameter("surface_kind", int(kinds.get(key, 0)))
	m.set_shader_parameter("roughness_debug", OS.get_environment("SURFACE_DEBUG") == "rough")
	m.set_shader_parameter("sun_dir",
			Vector3(cos(deg_to_rad(28.0)) * sin(deg_to_rad(45.0)),
					sin(deg_to_rad(28.0)),
					cos(deg_to_rad(28.0)) * cos(deg_to_rad(45.0))).normalized())
	m.resource_name = key
	_mats[key] = m
	return m

## Cloth surfaces are intentionally skipped by apply() so their original
## blue/gold stripe palette survives.  This wraps those surfaces in the
## procedural shader while passing the existing albedo through untouched.
static func apply_cloth(root: Node) -> void:
	if root == null:
		return
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s) as StandardMaterial3D
			if src == null:
				continue
			var key := _base_slot(String(src.resource_name))
			if key != "plaster" and key != "trim":
				continue
			var ck := "%s|%s" % [key, src.albedo_color.to_html()]
			if not _cloth_mats.has(ck):
				var cm := ShaderMaterial.new()
				cm.shader = SURFACE_SHADER
				cm.set_shader_parameter("surface_kind", 5)
				cm.set_shader_parameter("cloth_base_color", src.albedo_color)
				cm.set_shader_parameter("base_color", src.albedo_color)
				cm.set_shader_parameter("shadow_sky", Color(0.160, 0.180, 0.210, 1.0))
				cm.set_shader_parameter("roughness_value", 0.88)
				cm.set_shader_parameter("metallic_value", 0.0)
				cm.set_shader_parameter("sun_dir",
						Vector3(cos(deg_to_rad(28.0)) * sin(deg_to_rad(45.0)),
								sin(deg_to_rad(28.0)),
								cos(deg_to_rad(28.0)) * cos(deg_to_rad(45.0))).normalized())
				cm.resource_name = "cloth_" + key
				_cloth_mats[ck] = cm
			mi.set_surface_override_material(s, _cloth_mats[ck])

static func _debug_material(slot: String) -> StandardMaterial3D:
	var key := _base_slot(slot)
	if not DEBUG_COLORS.has(key):
		return null
	if _debug_mats.has(key):
		return _debug_mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = "debug_" + key
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = DEBUG_COLORS[key]
	m.cull_mode = BaseMaterial3D.CULL_BACK
	_debug_mats[key] = m
	return m

static func _block_hash(v: Vector3, salt: float) -> float:
	var n := sin(v.x * 127.1 + v.y * 311.7 + v.z * 74.7 + salt) * 43758.5453
	return n - floor(n)

## The wall/building GLBs merge every block into one stone surface.  A shader
## cell hash cannot line up with the irregular block widths, so bake a stable
## random colour per connected block into COLOR.  This edits the runtime mesh
## only; the GLB files are untouched.
static func _bake_block_colors(mi: MeshInstance3D, surface: int) -> void:
	var mesh := mi.mesh
	if mesh == null or mesh.get_surface_count() > 16:
		return
	var key := "%d:%d" % [mesh.get_instance_id(), surface]
	if _baked_surfaces.has(key):
		return
	var mdt := MeshDataTool.new()
	if mdt.create_from_surface(mesh, surface) != OK:
		return
	var n := mdt.get_vertex_count()
	if n == 0:
		return
	var parent := []
	parent.resize(n)
	for i in n:
		parent[i] = i
	var find_root := func find_root(i: int) -> int:
		while parent[i] != i:
			parent[i] = parent[parent[i]]
			i = parent[i]
		return i
	var union := func union(a: int, b: int) -> void:
		var ra: int = find_root.call(a)
		var rb: int = find_root.call(b)
		if ra != rb:
			parent[rb] = ra
	# Weld exact-position vertices: a block's six faces are separate triangles
	# in the GLB but share corner positions.
	var seen := {}
	for i in n:
		var v := mdt.get_vertex(i)
		var pk := "%.4f:%.4f:%.4f" % [v.x, v.y, v.z]
		if seen.has(pk):
			union.call(i, int(seen[pk]))
		else:
			seen[pk] = i
	for i in n:
		for e in mdt.get_vertex_edges(i):
			union.call(i, mdt.get_edge_vertex(e, 0))
	# Gather connected components and their centroids.
	var comps := {}
	for i in n:
		var r: int = find_root.call(i)
		if not comps.has(r):
			comps[r] = []
		(comps[r] as Array).append(i)
	for r in comps:
		var verts: Array = comps[r]
		var c := Vector3.ZERO
		for i in verts:
			c += mdt.get_vertex(int(i))
		c /= float(verts.size())
		var min_y := INF
		var max_y := -INF
		var min_x := INF
		var max_x := -INF
		for i in verts:
			var vv := mdt.get_vertex(int(i))
			min_y = minf(min_y, vv.y)
			max_y = maxf(max_y, vv.y)
			min_x = minf(min_x, vv.x)
			max_x = maxf(max_x, vv.x)
		var cr := _block_hash(c, 1.0)
		var cg := _block_hash(c, 7.0)
		# b/a carry the block's true vertical bounds so the shader can put a
		# narrow contact shadow on the real top and bottom edges, not on a
		# world-space course grid that is offset from the GLB base.
		var span_y := maxf(max_y - min_y, 0.0001)
		var span_x := maxf(max_x - min_x, 0.0001)
		for i in verts:
			var vv := mdt.get_vertex(int(i))
			mdt.set_vertex_color(int(i), Color(cr, cg,
					(vv.y - min_y) / span_y, (vv.x - min_x) / span_x))
	# MeshDataTool.commit_to_surface can drop the COLOR channel for imported
	# surfaces, so rebuild the ArrayMesh and attach the colour array explicitly.
	var colors := PackedColorArray()
	colors.resize(n)
	for i in n:
		colors[i] = mdt.get_vertex_color(i)
	var rebuilt := ArrayMesh.new()
	for si in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(si)
		if si == surface:
			arrays[Mesh.ARRAY_COLOR] = colors
		rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		rebuilt.surface_set_material(si, mesh.surface_get_material(si))
	mi.mesh = rebuilt
	_baked_surfaces["%d:%d" % [rebuilt.get_instance_id(), surface]] = true

static func apply(root: Node, rule: Dictionary = {}) -> void:
	if root == null:
		return
	var debug := OS.get_environment("PALETTE_DEBUG") == "1"
	var remap: Dictionary = rule.get("map", {})
	var skip: Array = rule.get("skip", [])
	var bake_surfaces: Array = []
	var applied: Array = []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var s := 0
		while s < mi.mesh.get_surface_count():
			var idx := s
			s += 1
			if idx >= mi.mesh.get_surface_count():
				break
			var src := mi.get_active_material(idx) as StandardMaterial3D
			if src == null:
				continue
			var key := _base_slot(String(src.resource_name))
			if not COLORS.has(key) or skip.has(key):
				continue
			var target := String(remap.get(key, key))
			if not debug and (target == "stone" or target == "wood" or target == "metal_dark"):
				bake_surfaces.append([mi, idx, target])
			var dst := _debug_material(target) if debug else material(target)
			if dst == null:
				continue
			if not _reported.has(key):
				_reported[key] = true
				var after: Variant = dst
				if dst is StandardMaterial3D:
					after = (dst as StandardMaterial3D).albedo_color
				elif dst is ShaderMaterial:
					var sm := dst as ShaderMaterial
					after = sm.get_shader_parameter("lit_color")
					if after == null:
						after = sm.get_shader_parameter("base_color")
				print("PALETTE slot=%s before=%s after=%s debug=%s" % [
					target, src.albedo_color, after, debug])
			if idx < mi.mesh.get_surface_count():
				mi.set_surface_override_material(idx, dst)
				applied.append([mi, idx, dst])
	# Bake after the surface walk: MeshDataTool may compact unused surfaces and
	# invalidate later surface indices.
	for pair in bake_surfaces:
		var bmi: MeshInstance3D = pair[0]
		var bsurf: int = pair[1]
		var btarget: String = pair[2]
		_bake_block_colors(bmi, bsurf)
		if bsurf < bmi.mesh.get_surface_count():
			bmi.set_surface_override_material(bsurf, material(btarget))
	# Replacing the mesh clears MeshInstance surface overrides.  Put every
	# converted slot back, not just the baked stone/wood/iron one.
	for pair in applied:
		var ami: MeshInstance3D = pair[0]
		var aidx: int = pair[1]
		var adst: Material = pair[2]
		if aidx < ami.mesh.get_surface_count():
			ami.mesh.surface_set_material(aidx, adst)
			ami.set_surface_override_material(aidx, adst)
