extends Node3D
## Five flat, half-buried stepping stones on the z 27-30 lane rise.  Visual
## only: no collision body, and each slab is tilted to the local terrain slope
## so no edge floats.  Heights/angles are sampled from terrain.glb at x -4.10.

const X := -4.10
const STONES := [
	[27.55, -0.242, 32.48],
	[28.35, -0.694, 24.97],
	[29.15, -0.996, 16.95],
	[29.95, -1.166, 5.72],
]


func build() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.40, 0.37, 0.32)
	mat.roughness = 0.95

	mat.metallic = 0.0
	var n := 0
	for s in STONES:
		var z: float = s[0]
		var y: float = s[1]
		var ang: float = deg_to_rad(s[2])
		var box := BoxMesh.new()
		box.size = Vector3(0.62, 0.012, 0.48)
		var mi := MeshInstance3D.new()
		mi.name = "SlopeStone_%d" % n
		mi.mesh = box
		mi.material_override = mat
		mi.position = Vector3(X, y - 0.003, z)
		mi.rotation = Vector3(ang, 0.0, 0.0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		n += 1
	print("slope stepping stones: %d, visual only, no collision" % n)
