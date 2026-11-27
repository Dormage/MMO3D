extends RefCounted
## Cheap visual room liner for the two house modules.
##
## The authored GLB already contains an inner shell, but it is inside the
## stone/plaster core and its floor is below the terrain/grass cards, so a
## doorway still reads as a hole.  This adds a raised floor, four inner walls
## (the front one split around the open door) and a dark ceiling.  All meshes
## are local children of the existing building instance: no footprint, origin
## or palette slot changes.  Visual only; building collision is untouched.

const WALL_MAT := Color(0.170, 0.140, 0.108)
const FLOOR_MAT := Color(0.148, 0.110, 0.072)
const CEIL_MAT := Color(0.090, 0.073, 0.058)
const SILL_MAT := Color(0.230, 0.215, 0.185)

static var _wall: StandardMaterial3D
static var _floor: StandardMaterial3D
static var _ceil: StandardMaterial3D
static var _sill: StandardMaterial3D
static var _triangles_added := 0

static func _mat(color: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = 0.0
	m.emission_enabled = true
	m.emission = color * 0.14
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m

static func _debug_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m

static func _box(parent: Node3D, name: String, size: Vector3, pos: Vector3,
		m: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.name = name
	mi.position = pos
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_triangles_added += 12

static func dress(building: Node3D, model: String) -> int:
	if building == null:
		return 0
	var is_a := model.ends_with("building_house_a")
	var is_b := model.ends_with("building_house_b")
	if not is_a and not is_b:
		return 0
	if _wall == null:
		if OS.get_environment("INTERIOR_DEBUG") == "1":
			_wall = _debug_mat(Color(1, 0, 0))
			_floor = _debug_mat(Color(0, 1, 0))
			_ceil = _debug_mat(Color(0, 0, 1))
			_sill = _debug_mat(Color(1, 1, 0))
		else:
			_wall = _mat(WALL_MAT, 0.97)
			_floor = _mat(FLOOR_MAT, 0.90)
			_ceil = _mat(CEIL_MAT, 0.98)
			_sill = _mat(SILL_MAT, 0.94)
	# Sit the liner ~10 cm inside the authored stone face so its darker
	# plaster, not the exterior masonry, is what a doorway shows.
	var hx := 2.45
	var hz := 3.40 if is_a else 2.92
	# Both doors sit on terrain that rises through the footprint (house_b2:
	# terrain ~0.54 at the threshold).  Put the room floor just above that
	# grade so no grass card can stand inside the room.
	var floor_y := 0.62 if is_a else 0.40
	# The relief runs uphill through several footprints (house_b2 reaches
	# ~0.89 m, house_a2 ~1.37 m).  Lift the slab just above the highest terrain
	# inside the room so the terrain can never show through the floor.
	var parent: Node = building.get_parent()
	while parent != null and not parent.has_method("_terrain_y"):
		parent = parent.get_parent()
	if parent != null and parent.has_method("_terrain_y"):
		var hi := -1.0e30
		for ix in [-0.9, -0.45, 0.0, 0.45, 0.9]:
			for iz in [-0.9, -0.45, 0.0, 0.45, 0.9]:
				var w: Vector3 = building.global_transform * Vector3(
						ix * hx, 0.0, iz * hz)
				hi = maxf(hi, float(parent.call("_terrain_y", w.x, w.z)))
		var sy := maxf(absf(building.global_transform.basis.get_scale().y), 0.0001)
		floor_y = maxf(floor_y,
				(hi - building.global_position.y) / sy + 0.055)
		print("INTERIOR_FLOOR %s terrain_hi=%.3f floor_local=%.3f" % [
				building.name, hi, floor_y])
	var ceil_y := 2.78 if is_a else 2.88
	var door_w := 1.22
	var door_h := 2.08
	var t := 0.07
	var before := _triangles_added
	# Floor: top is a shallow step above the terrain, hidden by the threshold.
	_box(building, "Interior_Floor", Vector3(2.0*hx, 0.16, 2.0*hz),
		Vector3(0.0, floor_y - 0.08, 0.0), _floor)
	# Stone threshold bridges the step at the door.  It stays within the
	# footprint and hides the grass strip that was visible under the door.
	_box(building, "Interior_Threshold", Vector3(door_w + 0.52, 0.16, 0.62),
		Vector3(0.0, floor_y - 0.08, hz + 0.25), _sill)
	# Back, left and right inner walls.
	_box(building, "Interior_Back", Vector3(2.0*hx, ceil_y - floor_y, t),
		Vector3(0.0, (floor_y + ceil_y)*0.5, -hz), _wall)
	_box(building, "Interior_Left", Vector3(t, ceil_y - floor_y, 2.0*hz),
		Vector3(-hx, (floor_y + ceil_y)*0.5, 0.0), _wall)
	_box(building, "Interior_Right", Vector3(t, ceil_y - floor_y, 2.0*hz),
		Vector3(hx, (floor_y + ceil_y)*0.5, 0.0), _wall)
	# Front wall with a real door-sized opening.  Three pieces keep the door
	# clear and still complete the room silhouette.
	var side_w := hx - door_w*0.5
	_box(building, "Interior_FrontL", Vector3(side_w, ceil_y - floor_y, t),
		Vector3(-(door_w*0.5 + side_w*0.5), (floor_y + ceil_y)*0.5, hz), _wall)
	_box(building, "Interior_FrontR", Vector3(side_w, ceil_y - floor_y, t),
		Vector3(door_w*0.5 + side_w*0.5, (floor_y + ceil_y)*0.5, hz), _wall)
	var head_h := ceil_y - (floor_y + door_h)
	if head_h > 0.02:
		_box(building, "Interior_FrontHead", Vector3(door_w, head_h, t),
			Vector3(0.0, floor_y + door_h + head_h*0.5, hz), _wall)
	# Dark ceiling closes the room to the sky.
	_box(building, "Interior_Ceiling", Vector3(2.0*hx, 0.10, 2.0*hz),
		Vector3(0.0, ceil_y + 0.05, 0.0), _ceil)
	# One cheap warm lamp makes the room read without changing the exterior
	# lighting.  Visual only; no shadow map, no extra triangles.
	var lamp := OmniLight3D.new()
	lamp.name = "Interior_Lamp"
	lamp.position = Vector3(0.0, ceil_y - 0.35, -0.35)
	lamp.light_color = Color(0.95, 0.72, 0.46)
	# A room-sized lantern: bright enough to read wall and floor values at
	# both ends of the 5.8 m long house, still warm and interior-only.
	lamp.light_energy = 5.2
	lamp.omni_range = 10.0
	lamp.omni_attenuation = 0.75
	lamp.shadow_enabled = false
	building.add_child(lamp)
	# Low front fill near the doorway: the single ceiling lamp leaves the
	# near half of the floor below the 0.04 target.  This is still interior
	# only, no shadow map, no exterior change.
	var fill := OmniLight3D.new()
	fill.name = "Interior_LampFront"
	fill.position = Vector3(0.0, floor_y + 1.25, hz - 0.70)
	fill.light_color = Color(0.95, 0.76, 0.52)
	fill.light_energy = 1.35
	fill.omni_range = 5.0
	fill.omni_attenuation = 1.0
	fill.shadow_enabled = false
	building.add_child(fill)
	return _triangles_added - before
