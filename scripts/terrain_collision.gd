extends StaticBody3D
## HeightMapShape3D collider for the walkable terrain top.  Built from the
## subdivided terrain mesh, not the old 1 m source grid.  The mesh is mirrored
## Z in map.gd; this grid maps directly to world XZ:
##   x = -81.5 + i * CELL, z = -81.5 + j * CELL
## The shape is scaled in XZ so its 767 local spans cover the 163 m map.

const N := 768
const HALF := 81.5
const CELL := 163.0 / 767.0
const TOP_SURFACES := 6

var _h := PackedFloat32Array()
var _lo := PackedFloat32Array()
var _cov := PackedByteArray()
var _steep := PackedByteArray()


func _ready() -> void:
	build()


func build() -> void:
	var t0 := Time.get_ticks_msec()
	_h.resize(N * N)
	_h.fill(-1.0e20)
	_lo.resize(N * N)
	_lo.fill(1.0e20)
	_cov.resize(N * N)
	_cov.fill(0)
	_steep.resize(N * N)
	_steep.fill(0)
	var terrain := get_parent().get_node_or_null("Terrain") as Node3D
	if terrain != null:
		for node in terrain.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			var xf := mi.global_transform
			var cm: Mesh = mi.get_meta("collision_mesh", mi.mesh) as Mesh
			if cm == null:
				cm = mi.mesh
			for s in range(mini(TOP_SURFACES, cm.get_surface_count())):
				var arrays := cm.surface_get_arrays(s)
				if arrays.is_empty():
					continue
				var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var idx = arrays[Mesh.ARRAY_INDEX]
				if idx == null or idx.size() == 0:
					for k in range(0, vs.size() - 2, 3):
						_raster(xf * vs[k], xf * vs[k + 1], xf * vs[k + 2])
				else:
					for k in range(0, idx.size() - 2, 3):
						_raster(xf * vs[idx[k]], xf * vs[idx[k + 1]],
								xf * vs[idx[k + 2]])
	# Fill enclosed uncovered holes from the outside first.  These are the
	# apertures through the island; if the heightmap interpolates across them
	# the collider floats over a hole instead of falling into the mesh.
	var outside := PackedByteArray()
	outside.resize(N * N)
	outside.fill(0)
	var q := PackedInt32Array()
	for i in range(N):
		for k: int in [i, (N - 1) * N + i, i * N, i * N + N - 1]:
			if _cov[k] == 0 and outside[k] == 0:
				outside[k] = 1
				q.append(k)
	var qi := 0
	while qi < q.size():
		var k: int = q[qi]
		qi += 1
		var ki := k % N
		for o: int in [-1, 1, -N, N]:
			if (o == -1 and ki == 0) or (o == 1 and ki == N - 1):
				continue
			var nk := k + o
			if nk < 0 or nk >= N * N:
				continue
			if _cov[nk] == 0 and outside[nk] == 0:
				outside[nk] = 1
				q.append(nk)
	var boxes: Array[Rect2] = []
	var lf := FileAccess.open("res://map_layout.json", FileAccess.READ)
	if lf != null:
		var ld: Dictionary = JSON.parse_string(lf.get_as_text())
		for isl in ld.get("islands", []):
			var bb: Array = isl["bbox"]
			boxes.append(Rect2(float(bb[0]) - 82.0, float(bb[1]) - 82.0,
				float(bb[2] - bb[0]), float(bb[3] - bb[1])))
	for k in range(N * N):
		if _cov[k] != 0:
			continue
		var ix := k % N
		var jz := k / N
		var wx := -HALF + float(ix) * CELL
		var wz := -HALF + float(jz) * CELL
		var in_island := outside[k] == 0
		for b in boxes:
			if b.has_point(Vector2(wx, wz)):
				in_island = true
				break
		if in_island:
			_cov[k] = 1
			_steep[k] = 1
			_h[k] = -25.0
	# Fill unwalked/edge samples from neighbours so the shape is continuous.
	for pass_i in 3:
		var added := 0
		for j in range(1, N - 1):
			for i in range(1, N - 1):
				var n := j * N + i
				if _cov[n] != 0:
					continue
				var sum := 0.0
				var cnt := 0
				for o: int in [-1, 1, -N, N]:
					if _cov[n + o] != 0:
						sum += _h[n + o]
						cnt += 1
				if cnt > 0:
					_h[n] = sum / float(cnt)
					_cov[n] = 1
					added += 1
		if added == 0:
			break
	var lo := 1.0e20
	var hi := -1.0e20
	var steep_cells := 0
	for i in _h.size():
		if _cov[i] == 0:
			_h[i] = -25.0
		elif _h[i] - _lo[i] > 0.080:
			# A cell that spans a cliff/overhang cannot be represented by one
			# height.  Cut it out of the heightmap and let the local trimesh
			# below own that face.
			_steep[i] = 1
			_h[i] = -25.0
			steep_cells += 1
	# Interpolation across a sharp crest is the other failure mode: the cell
	# itself is flat but the next cell is metres higher/lower.  Cut a one-cell
	# apron around those crests too.
	for j in range(1, N - 1):
		for i in range(1, N - 1):
			var k := j * N + i
			if _steep[k] != 0 or _cov[k] == 0:
				continue
			var dh := 0.0
			for o: int in [-1, 1, -N, N]:
				if _cov[k + o] != 0 and _steep[k + o] == 0:
					dh = maxf(dh, absf(_h[k] - _h[k + o]))
			if dh > 0.150:
				_steep[k] = 1
				_h[k] = -25.0
				steep_cells += 1
	# One residual crest at the outpost edge (69.6, -6.55) is a 6 cm
	# heightfield-above-mesh case.  Cut a small local patch there; leaving the
	# global threshold conservative keeps bridge approach decks stable.
	var pi := int(round((69.60 + HALF) / CELL))
	var pj := int(round((-6.55 + HALF) / CELL))
	for j in range(maxi(0, pj - 3), mini(N, pj + 4)):
		for i in range(maxi(0, pi - 3), mini(N, pi + 4)):
			var k := j * N + i
			if _cov[k] != 0 and _steep[k] == 0:
				_steep[k] = 1
				_h[k] = -25.0
				steep_cells += 1
	# Four open apertures still rasterise as heightmap because neighbouring top
	# faces cover their cell.  Cut a tight 2 m patch around each so the local
	# trimesh owns the actual opening rather than a flat bridge over it.
	for hole in [Vector2(44.80, -53.73), Vector2(59.91, -13.08),
			Vector2(68.18, 27.52), Vector2(50.87, -46.73),
			Vector2(73.16, 52.47)]:
		var hix := int(round((hole.x + HALF) / CELL))
		var hj := int(round((hole.y + HALF) / CELL))
		for j in range(maxi(0, hj - 10), mini(N, hj + 11)):
			for i in range(maxi(0, hix - 10), mini(N, hix + 11)):
				if Vector2(-HALF + float(i) * CELL, -HALF + float(j) * CELL).distance_to(hole) <= 5.0:
					var n := j * N + i
					_steep[n] = 1
					_h[n] = -25.0
	for v in _h:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var hm := HeightMapShape3D.new()
	hm.map_width = N
	hm.map_depth = N
	hm.map_data = _h
	var cs := CollisionShape3D.new()
	cs.shape = hm
	# Local heightmap spans 767 units; scale XZ to the 163 m map.  Index 0 is
	# exactly -81.5 and index 767 is +81.5, so no body offset is needed.
	cs.scale = Vector3(CELL, 1.0, CELL)
	add_child(cs)
	position = Vector3.ZERO
	var steep_faces := _add_steep_trimesh(terrain)
	# World-boundary ring only; per-island edges are left to the heightmap rim.
	_add_bounds()
	var ms := Time.get_ticks_msec() - t0
	var bytes := _h.size() * 4 + _cov.size() + hm.map_data.size() * 4
	print("terrain collision: %dx%d heightmap (%.3f m/cell), y %.2f..%.2f, build %d ms, data %.2f MB, steep_cells %d, steep_tris %d" % [
		N, N, CELL, lo, hi, ms, float(bytes) / 1048576.0, steep_cells, steep_faces / 3])




## Walkable top height from the heightfield only.  This deliberately ignores
## the steep trimesh and the terrain underside: bridge placement and prop
## grounding need the surface a capsule stands on, not the first physics hit.
func walkable_height(x: float, z: float) -> float:
	if x < -HALF or x > HALF or z < -HALF or z > HALF:
		return NAN
	var fx := (x + HALF) / CELL
	var fz := (z + HALF) / CELL
	var i := clampi(int(floor(fx)), 0, N - 2)
	var j := clampi(int(floor(fz)), 0, N - 2)
	var tx := clampf(fx - float(i), 0.0, 1.0)
	var tz := clampf(fz - float(j), 0.0, 1.0)
	var k00 := j * N + i
	var k10 := k00 + 1
	var k01 := k00 + N
	var k11 := k01 + 1
	if _cov[k00] != 0 and _cov[k10] != 0 and _cov[k01] != 0 and _cov[k11] != 0 \
			and _steep[k00] == 0 and _steep[k10] == 0 \
			and _steep[k01] == 0 and _steep[k11] == 0:
		return lerpf(lerpf(_h[k00], _h[k10], tx), lerpf(_h[k01], _h[k11], tx), tz)
	# A bridge end can sit on the one-cell steep apron.  Search outward for the
	# nearest walkable sample rather than accepting the trimesh/underside hit.
	for radius in range(1, 9):
		var best := NAN
		var best_d := 1.0e20
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dz) != radius:
					continue
				var ci := clampi(i + dx, 0, N - 1)
				var cj := clampi(j + dz, 0, N - 1)
				var k := cj * N + ci
				if _cov[k] == 0 or _steep[k] != 0:
					continue
				var wx := -HALF + float(ci) * CELL
				var wz := -HALF + float(cj) * CELL
				var d := Vector2(wx - x, wz - z).length_squared()
				if d < best_d:
					best_d = d
					best = _h[k]
		if not is_nan(best):
			return best
	return NAN


func _raster(a: Vector3, b: Vector3, c: Vector3) -> void:
	# The solidified GLB carries downward and vertical faces in the same
	# materials as the top.  Feeding those into min() made every covered cell
	# look like a 20 m cliff and marked 347k cells steep.  The heightmap is a
	# top-surface field: ignore faces that are not upward enough.
	var fn := (b - a).cross(c - a)
	var fl := fn.length()
	if fl < 1.0e-9 or absf(fn.y) / fl < 0.20:
		return
	# The solidified bottom shell is 20-40 m below the walkable top.  It can
	# have upward-facing triangles after mirroring; reject it by height as
	# well as by normal.
	if (a.y + b.y + c.y) < -18.0:
		return
	var minx := minf(a.x, minf(b.x, c.x))
	var maxx := maxf(a.x, maxf(b.x, c.x))
	var minz := minf(a.z, minf(b.z, c.z))
	var maxz := maxf(a.z, maxf(b.z, c.z))
	var i0 := clampi(int(floor((minx + HALF) / CELL)), 0, N - 1)
	var i1 := clampi(int(ceil((maxx + HALF) / CELL)), 0, N - 1)
	var j0 := clampi(int(floor((minz + HALF) / CELL)), 0, N - 1)
	var j1 := clampi(int(ceil((maxz + HALF) / CELL)), 0, N - 1)
	if i1 < i0 or j1 < j0:
		return
	var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(d) < 1.0e-9:
		return
	var inv := 1.0 / d
	for j in range(j0, j1 + 1):
		var pz := -HALF + float(j) * CELL
		for i in range(i0, i1 + 1):
			var px := -HALF + float(i) * CELL
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
			var k := j * N + i
			if _cov[k] == 0:
				_h[k] = h
				_lo[k] = h
				_cov[k] = 1
			else:
				_h[k] = maxf(_h[k], h)
				_lo[k] = minf(_lo[k], h)


## Local concave collider for cells the heightmap had to cut out.  Only
## triangles that touch a steep cell are included; flat terrain stays on the
## O(1) heightfield.
func _add_steep_trimesh(terrain: Node3D) -> int:
	var faces := PackedVector3Array()
	for node in terrain.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := mi.global_transform
		for s in range(mini(TOP_SURFACES, mi.mesh.get_surface_count())):
			var arrays := mi.mesh.surface_get_arrays(s)
			if arrays.is_empty():
				continue
			var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx = arrays[Mesh.ARRAY_INDEX]
			if idx == null or idx.size() == 0:
				continue
			for k in range(0, idx.size() - 2, 3):
				var a := xf * vs[idx[k]]
				var b := xf * vs[idx[k + 1]]
				var c := xf * vs[idx[k + 2]]
				var minx := minf(a.x, minf(b.x, c.x))
				var maxx := maxf(a.x, maxf(b.x, c.x))
				var minz := minf(a.z, minf(b.z, c.z))
				var maxz := maxf(a.z, maxf(b.z, c.z))
				var i0 := clampi(int(floor((minx + HALF) / CELL)), 0, N - 1)
				var i1 := clampi(int(ceil((maxx + HALF) / CELL)), 0, N - 1)
				var j0 := clampi(int(floor((minz + HALF) / CELL)), 0, N - 1)
				var j1 := clampi(int(ceil((maxz + HALF) / CELL)), 0, N - 1)
				var hit := false
				for j in range(j0, j1 + 1):
					for i in range(i0, i1 + 1):
						if _steep[j * N + i] != 0:
							hit = true
							break
					if hit:
						break
				if hit:
					faces.append(a); faces.append(b); faces.append(c)
	if faces.is_empty():
		return 0
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var body := StaticBody3D.new()
	body.name = "TerrainSteepCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_child(cs)
	add_child(body)
	return faces.size()

func _add_bounds() -> void:
	# Invisible world-edge walls.  Heightmap rim handles the terrain top; the
	# island cliffs remain physical drop-offs (no per-island ring, which would
	# need bridge gaps and is outside this pass).
	for spec in [
		[Vector3(-82.0, 5.0, 0.0), Vector3(1.0, 30.0, 166.0)],
		[Vector3(82.0, 5.0, 0.0), Vector3(1.0, 30.0, 166.0)],
		[Vector3(0.0, 5.0, -82.0), Vector3(166.0, 30.0, 1.0)],
		[Vector3(0.0, 5.0, 82.0), Vector3(166.0, 30.0, 1.0)],
	]:
		var wall := StaticBody3D.new()
		wall.name = "WorldBound"
		wall.collision_layer = 1
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = spec[1]
		cs.shape = bs
		cs.position = spec[0]
		wall.add_child(cs)
		add_child(wall)
