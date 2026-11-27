extends RefCounted
## Floods the water's whole neighbourhood with one big flat plane.
##
## The authored river is a flat sheet whose outline stops short of the banks,
## leaving a gap between water and ground.  Rather than sealing that seam edge by
## edge, put a large plane at the waterline and let the terrain do the work:
## ground above the waterline hides it, ground below shows it.  The visible river
## then becomes every place the terrain actually dips below the water, so no
## hollow can be left uncovered however the bank is shaped.
##
## The plane deliberately intersects and passes through the terrain.  That is the
## point -- the excess is buried, and the player only ever sees the parts that
## stand up through the channel.
##
## Coverage is derived from the ground mesh's own vertices, NOT from physics
## raycasts.  Raycasting meant the plane silently vanished anywhere there was no
## live physics world -- notably the editor viewport -- which looked exactly like
## the bug it was meant to fix.  Mesh-derived coverage behaves the same in both.
##
## Two other details are load-bearing:
##
## * The plane sits a hair below the waterline, or it z-fights with the authored
##   sheet and reads as diagonal stripes across the river.
## * Triangles are wound to face up; Godot culls backfaces.


## How far ABOVE the waterline the plane sits.
##
## It has to clear the authored sheet rather than sit under it.  A plane below the
## sheet leaves the sheet proud by that offset, and the sheet's own triangle edges
## then read as faint horizontal seams across the water.  Above it, the plane
## simply covers the sheet and there is nothing to see through.
##
## Raised by roughly the wave trough depth so the shader's displacement cannot
## sink the surface below the bed at the shoreline and open a gap.
const PLANE_LIFT := 0.05

## Grid resolution used to trim the plane to the island footprint.  Also the
## vertex density the shader's waves displace, so it has to be fine enough to
## sample the shortest wave rather than just to trace the shoreline.
const CELL := 1.25


## Build the water plane around every water surface of `ground`.
## `spread` is how far past the authored sheet the plane reaches.
## Returns null when there is no water to work with.
static func build(ground: MeshInstance3D, water_patterns: PackedStringArray,
		exclude_patterns: PackedStringArray, spread: float,
		material_override: Material = null) -> MeshInstance3D:
	if ground == null or spread <= 0.0:
		return null

	var faces := PackedVector3Array()
	var material: Material = null
	for s in ground.mesh.get_surface_count():
		var mat := ground.mesh.surface_get_material(s)
		var nm := String(mat.resource_name).to_lower() if mat != null else ""
		if nm.is_empty():
			continue
		if not _matches_any(nm, water_patterns) or _matches_any(nm, exclude_patterns):
			continue
		var arr := ground.mesh.surface_get_arrays(s)
		if arr.is_empty():
			continue
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if vs.is_empty():
			continue
		var idx = arr[Mesh.ARRAY_INDEX]
		var xf := ground.global_transform
		var count: int = vs.size() if idx == null else idx.size()
		count -= count % 3
		for k in count:
			faces.append(xf * vs[k if idx == null else idx[k]])
		if material == null:
			material = mat
	if faces.is_empty():
		return null

	# Which way round the authored sheet is wound.  Godot's front faces are
	# clockwise, so an UP-facing triangle has a NEGATIVE cross(b-a, c-a).y --
	# the opposite of Blender.  Reading the sign from the sheet we are replacing
	# means the plane inherits the right convention instead of assuming it.
	var up_sign := 0.0
	for t in range(0, mini(faces.size(), 3000) - 2, 3):
		up_sign += (faces[t + 1] - faces[t]).cross(faces[t + 2] - faces[t]).y
	up_sign = -1.0 if up_sign < 0.0 else 1.0

	# The sheet is flat, so one sample gives the waterline.
	var water_y := faces[0].y
	var lo := Vector2(faces[0].x, faces[0].z)
	var hi := lo
	for v in faces:
		water_y = maxf(water_y, v.y)
		lo.x = minf(lo.x, v.x); lo.y = minf(lo.y, v.z)
		hi.x = maxf(hi.x, v.x); hi.y = maxf(hi.y, v.z)

	# Every ground vertex, in world space.  This doubles as the island footprint
	# and as the proof that terrain exists over a cell.
	var gverts := PackedVector3Array()
	for s in ground.mesh.get_surface_count():
		var arr := ground.mesh.surface_get_arrays(s)
		if arr.is_empty():
			continue
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx = arr[Mesh.ARRAY_INDEX]
		var xf := ground.global_transform
		var count: int = vs.size() if idx == null else idx.size()
		for k in count:
			gverts.append(xf * vs[k if idx == null else idx[k]])
	if gverts.is_empty():
		return null

	# Bounds: the authored sheet plus `spread`, but never past the island itself.
	var glo := Vector2(gverts[0].x, gverts[0].z)
	var ghi := glo
	for v in gverts:
		glo.x = minf(glo.x, v.x); glo.y = minf(glo.y, v.z)
		ghi.x = maxf(ghi.x, v.x); ghi.y = maxf(ghi.y, v.z)
	var x0 := maxf(lo.x - spread, glo.x)
	var z0 := maxf(lo.y - spread, glo.y)
	var x1 := minf(hi.x + spread, ghi.x)
	var z1 := minf(hi.y + spread, ghi.y)
	if x1 - x0 < 1.0 or z1 - z0 < 1.0:
		return null

	# Rasterise the ground footprint by marking the cell under every ground
	# vertex.  Dense authored terrain means this traces the silhouette closely
	# enough that the plane cannot hang out over the cliff.
	var nx := maxi(1, int(ceil((x1 - x0) / CELL)))
	var nz := maxi(1, int(ceil((z1 - z0) / CELL)))
	var dx := (x1 - x0) / float(nx)
	var dz := (z1 - z0) / float(nz)
	var occupied := {}
	for v in gverts:
		var ix := int((v.x - x0) / dx)
		var iz := int((v.z - z0) / dz)
		if ix < 0 or iz < 0 or ix >= nx or iz >= nz:
			continue
		occupied[ix + iz * nx] = true
	if occupied.is_empty():
		return null

	# Indexed, with shared corners.  Emitting each cell as its own quad duplicated
	# vertices, and float rounding left hairline gaps every CELL metres.
	var y := water_y + PLANE_LIFT
	var verts := PackedVector3Array()
	var index_of := {}
	var indices := PackedInt32Array()
	var corner := func(ix: int, iz: int) -> int:
		var key := ix * 100003 + iz
		if index_of.has(key):
			return int(index_of[key])
		var v := Vector3(x0 + float(ix) * dx, y, z0 + float(iz) * dz)
		verts.append(v)
		var idx: int = verts.size() - 1
		index_of[key] = idx
		return idx
	for key in occupied:
		var ix: int = int(key) % nx
		var iz: int = int(key) / nx
		var i00: int = corner.call(ix, iz)
		var i10: int = corner.call(ix + 1, iz)
		var i11: int = corner.call(ix + 1, iz + 1)
		var i01: int = corner.call(ix, iz + 1)
		# Wound so the normal points up.
		indices.append(i00); indices.append(i01); indices.append(i11)
		indices.append(i00); indices.append(i11); indices.append(i10)

	if indices.is_empty():
		return null

	# Flip every triangle if the winding came out the wrong way round.  Without
	# this the plane is visible from underneath the island and invisible from
	# above -- which looks exactly like "the water isn't there".
	var check := 0
	for t in range(0, mini(indices.size(), 3000) - 2, 3):
		check += (verts[indices[t + 1]] - verts[indices[t]]).cross(
				verts[indices[t + 2]] - verts[indices[t]]).y
	if (check < 0.0) != (up_sign < 0.0):
		for t in range(0, indices.size() - 2, 3):
			var tmp := indices[t + 1]
			indices[t + 1] = indices[t + 2]
			indices[t + 2] = tmp

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var use_mat: Material = material_override if material_override != null else material
	if use_mat != null:
		mesh.surface_set_material(0, use_mat)
	var mi := MeshInstance3D.new()
	mi.name = "WaterApron"
	mi.mesh = mesh
	# Vertices are already world-space.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.set_meta("cells", occupied.size())
	mi.set_meta("verts", verts.size())
	mi.set_meta("extent", Vector2(x1 - x0, z1 - z0))
	return mi


static func _matches_any(name: String, patterns: PackedStringArray) -> bool:
	for p in patterns:
		var pat := String(p).to_lower()
		if not pat.is_empty() and name.contains(pat):
			return true
	return false
