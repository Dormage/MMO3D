extends MeshInstance3D
## Rim-tied rock shed for the detached north-west terrain flake.  A sloped
## front face rises from the main hillside to the broken lip; the top slopes
## back into the hill instead of forming a horizontal cap.  No collision.
const X0 := -12.0
const X1 := -3.2
const Z_FRONT := -66.9
const Z_BACK := -70.2
const N := 14

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x51A7C0DE
	var v := PackedVector3Array()
	var idx := PackedInt32Array()
	var front_top: Array[Vector3] = []
	var front_bot: Array[Vector3] = []
	var back_top: Array[Vector3] = []
	for i in N + 1:
		var t := float(i) / float(N)
		var x := lerpf(X0, X1, t)
		# Jagged lip, highest near the middle, tied down at both ends.
		var lip := 2.55 + 0.65 * sin(t * PI) + 0.22 * sin(t * 9.0 + 0.4) + rng.randf_range(-0.12, 0.12)
		var zf := Z_FRONT + 0.35 * sin(t * 5.0 + 1.2)
		front_top.append(Vector3(x, lip, zf))
		front_bot.append(Vector3(x + 0.15 * sin(t * 7.0), -0.35 + 0.20 * sin(t * 6.0), zf + 0.15))
		back_top.append(Vector3(x - 0.10, lip - 0.95 + 0.25 * sin(t * 4.0 + 2.0), Z_BACK + 0.4 * sin(t * 3.0)))
	# Front face: two triangles per bay, jagged and non-planar.
	for i in N:
		var a := v.size()
		v.append(front_top[i]); v.append(front_top[i+1]); v.append(front_bot[i+1]); v.append(front_bot[i])
		idx.append_array([a, a+1, a+2, a, a+2, a+3])
	# Sloped back/top face: broken rock falling into the hill, never a lid.
	for i in N:
		var a := v.size()
		v.append(front_top[i]); v.append(back_top[i]); v.append(back_top[i+1]); v.append(front_top[i+1])
		idx.append_array([a, a+1, a+2, a, a+2, a+3])
	# End caps tie the shed to the lip.
	for e in [0, N]:
		var a := v.size()
		v.append(front_top[e]); v.append(front_bot[e]); v.append(back_top[e])
		idx.append_array([a, a+1, a+2])
	var col := PackedColorArray()
	for p in v:
		var s := 0.72 + 0.18 * sin(p.y * 6.3 + p.x * 1.4) + 0.08 * sin(p.z * 4.1)
		col.append(Color(s, s * 0.92, s * 0.84))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_INDEX] = idx
	arrays[Mesh.ARRAY_COLOR] = col
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.31, 0.235, 0.165)
	mat.roughness = 0.97
	mat.vertex_color_use_as_albedo = true
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	print("terrain hole rock: %d verts, %d tris, lip x %.1f..%.1f" % [v.size(), idx.size() / 3, X0, X1])
