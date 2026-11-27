extends Node3D
class_name DistantIslands
## A low-poly ring of background archipelago silhouettes beyond the playable
## map.  No collision, no props, no grass, no shadows.  Each island is a
## jagged ridge wall with a narrow sloped cap and a base at -30 m, plus a
## per-instance aerial-haze mix so the nearest layer keeps colour and the
## farthest nearly matches the sky horizon.

const SHADER := preload("res://shaders/distant_island.gdshader")

# x, z, width, depth, top_extra, haze, seed
# Deep layer: much smaller, far below the play space, heavily haze-faded so
# the chasm has vertical scale.  x, z, width, depth, top_extra, haze, seed, y.
const DEEP_SPECS := [
	[ 240.0,  -30.0, 92.0, 24.0, 10.0, 0.84, 131, -58.0],
	[ 120.0,  -95.0, 22.0, 14.0,  9.0, 0.82, 151, -92.0],
	[ 390.0, -120.0, 26.0, 16.0, 10.0, 0.86, 157, -105.0],
]

const SPECS := [
	[ -46.0,  358.0, 122.0, 80.0, 12.0, 0.34, 37],
	[-218.0,  226.0, 168.0, 100.0,  8.0, 0.14, 2],
	[-176.0,  252.0, 126.0, 84.0, 12.0, 0.18, 3],
	[-118.0,  286.0, 104.0, 70.0,  8.0, 0.22, 5],
	[ 122.0,  292.0, 100.0, 68.0,  7.0, 0.22, 7],
	[ 196.0,  316.0,  98.0, 68.0, 10.0, 0.25, 41],
	[ 294.0, -194.0,  96.0, 64.0,  6.0, 0.66, 67],
	[  32.0, -370.0, 126.0, 80.0, 11.0, 0.48, 71],
	[-276.0, -272.0, 100.0, 68.0,  8.0, 0.42, 83],
]

var _tris := 0
var _max_top := -1e9
var _min_radius := 1e9


func build(horizon: Color) -> void:
	for i in SPECS.size():
		var s: Array = SPECS[i]
		var x := float(s[0])
		var z := float(s[1])
		var width := float(s[2])
		var depth := float(s[3])
		var top_extra := float(s[4])
		var haze := float(s[5])
		var seed := int(s[6])
		var mi := MeshInstance3D.new()
		mi.name = "DistantIsland_%02d" % i
		mi.mesh = _make_mesh(seed, width, depth, top_extra)
		mi.position = Vector3(x, 0.0, z)
		mi.rotation.y = atan2(-x, -z)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		mat.set_shader_parameter("horizon_color", horizon)
		mat.set_shader_parameter("haze", minf(0.86, haze + 0.18))
		mat.set_shader_parameter("near_haze", 0.22)
		mat.set_shader_parameter("phase", float(seed) * 0.37)
		mi.material_override = mat
		add_child(mi)
		var aabb := mi.mesh.get_aabb()
		_tris += _mesh_tris(mi.mesh)
		_max_top = maxf(_max_top, aabb.position.y + aabb.size.y)
		_min_radius = minf(_min_radius, Vector2(x, z).length())
	# Second, much deeper layer.  Same sheet shader, but a small silhouette and
	# a very high haze value make it read as distance rather than decoration.
	for i in DEEP_SPECS.size():
		var d: Array = DEEP_SPECS[i]
		var dx := float(d[0])
		var dz := float(d[1])
		var dw := float(d[2])
		var dd := float(d[3])
		var dtop := float(d[4])
		var dhaze := float(d[5])
		var dseed := int(d[6])
		var dy := float(d[7])
		var dmi := MeshInstance3D.new()
		dmi.name = "DeepIsland_%02d" % i
		dmi.mesh = _make_mesh(dseed, dw, dd, dtop)
		dmi.position = Vector3(dx, dy, dz)
		dmi.rotation.y = atan2(-dx, -dz)
		dmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		dmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		var dmat := ShaderMaterial.new()
		dmat.shader = SHADER
		dmat.set_shader_parameter("horizon_color", horizon * 0.70)
		dmat.set_shader_parameter("haze", minf(0.86, dhaze * 0.92))
		dmat.set_shader_parameter("near_haze", 0.12)
		dmat.set_shader_parameter("phase", float(dseed) * 0.37)
		dmat.set_shader_parameter("alpha_mul", 1.0)
		dmi.material_override = dmat
		add_child(dmi)
		_tris += _mesh_tris(dmi.mesh)
	print("DEEP_ISLANDS count=%d y_min=%.1f y_max=%.1f" % [
		DEEP_SPECS.size(), -108.0, -62.0])

	var peaks: Array[float] = []
	for i in SPECS.size():
		var n := get_node_or_null("DistantIsland_%02d" % i) as MeshInstance3D
		if n != null:
			peaks.append(n.mesh.get_aabb().position.y + n.mesh.get_aabb().size.y)
	if not peaks.is_empty():
		var mean := 0.0
		for p in peaks:
			mean += p
		mean /= float(peaks.size())
		var v := 0.0
		for p in peaks:
			v += (p - mean) * (p - mean)
		v /= float(peaks.size())
		print("DISTANT_CRESTS peaks=%s mean=%.3f variance=%.3f" % [
			str(peaks), mean, v])
	print("DISTANT_ISLANDS count=%d tris=%d max_top_y=%.3f min_radius=%.1f" % [
		SPECS.size(), _tris, _max_top, _min_radius])





func _mesh_tris(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		var idx = arrays[Mesh.ARRAY_INDEX]
		if idx == null:
			n += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		else:
			n += (idx as PackedInt32Array).size() / 3
	return n


func _make_mesh(seed: int, width: float, depth: float, top_extra: float) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var n := 41
	var top_y: Array[float] = []
	for i in n:
		var t := float(i) / float(n - 1)
		var y := 0.04 + top_extra * (0.14 + 0.86 * rng.randf())
		# Multi-octave ridge: broad peaks, shoulders and small notches.
		y += top_extra * 0.16 * sin(t * 7.0 + float(seed) * 0.7)
		y += top_extra * 0.09 * sin(t * 17.0 - float(seed) * 0.3)
		y += 0.045 * sin(t * 41.0 + float(seed))
		y += 0.020 * sin(t * 83.0 - float(seed) * 0.8)
		top_y.append(maxf(0.02, y))
	# A single outward-facing sheet, not a closed box.  The old front/back/side
	# walls crossed at the silhouette and produced the hard rectangular slabs
	# and vertical spikes.  The shader fades the base and the two ends into haze.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in n - 1:
		var t0 := float(i) / float(n - 1)
		var t1 := float(i + 1) / float(n - 1)
		var x0 := -width * 0.5 + width * t0
		var x1 := -width * 0.5 + width * t1
		var f0 := Vector3(x0, top_y[i], 0.0)
		var f1 := Vector3(x1, top_y[i + 1], 0.0)
		var g0 := Vector3(x0, -30.0, 0.0)
		var g1 := Vector3(x1, -30.0, 0.0)
		st.set_uv(Vector2(t0, 1.0)); st.add_vertex(f0)
		st.set_uv(Vector2(t0, 0.0)); st.add_vertex(g0)
		st.set_uv(Vector2(t1, 1.0)); st.add_vertex(f1)
		st.set_uv(Vector2(t1, 1.0)); st.add_vertex(f1)
		st.set_uv(Vector2(t0, 0.0)); st.add_vertex(g0)
		st.set_uv(Vector2(t1, 0.0)); st.add_vertex(g1)
	st.generate_normals()
	return st.commit()
