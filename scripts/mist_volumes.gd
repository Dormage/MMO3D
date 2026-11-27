extends Node3D
## Soft low mist.  The shipped GLB (`models/water/mist.glb`) is an opaque
## icosphere cluster; at ground scale it reads as flat polygonal sheets with
## hard rims.  These volumes use camera-facing radial puffs instead, so every
## edge reaches alpha zero.  The GLB remains the source/reference asset only.

const SHADER := preload("res://shaders/mist_billboard.gdshader")

# x, z, radius, base_y, height, count, size, opacity, seed
const VOLUMES := [
	# Pond margins — opposite banks of the one outer pond with visible water.
	# The village pond is deliberately absent.
	[65.0, 47.0, 3.6, -0.12, 2.4, 12, 3.1, 0.88, 0.11],
	[78.0, 48.5, 3.6, -0.12, 2.4, 12, 3.1, 0.84, 0.27],
	# Cliff bases, below the turf lip and away from every route.
	[31.5, 10.0, 8.0, -1.0, 6.0, 7, 10.0, 0.58, 0.59],
	[-26.0, -45.0, 8.0, -1.0, 6.0, 7, 10.0, 0.58, 0.71],
	[-19.0, 55.0, 8.0, -1.0, 6.0, 7, 10.0, 0.54, 0.83],
]

var _material: ShaderMaterial
var _puffs := 0

func _ready() -> void:
	if OS.get_environment("MIST_OFF") == "1":
		return
	_build()

func _build() -> void:
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.render_priority = 2
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	for i in VOLUMES.size():
		var v: Array = VOLUMES[i]
		var cx := float(v[0]); var cz := float(v[1])
		var rad := float(v[2]); var base_y := float(v[3])
		var height := float(v[4]); var count := int(v[5])
		var size := float(v[6]); var op := float(v[7]); var seed := float(v[8])
		var rng := RandomNumberGenerator.new()
		rng.seed = int(seed * 100003.0) + i * 7919
		for k in count:
			var mi := MeshInstance3D.new()
			mi.name = "Mist_%02d_%02d" % [i, k]
			mi.mesh = quad
			mi.material_override = _material
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			var a := rng.randf() * TAU
			var rr := sqrt(rng.randf()) * rad
			var sc := size * (0.72 + rng.randf() * 0.68)
			mi.position = Vector3(cx + cos(a) * rr, base_y + rng.randf() * height * 0.34,
				cz + sin(a) * rr)
			mi.scale = Vector3(sc, sc * (0.55 + rng.randf() * 0.35), sc)
			mi.set_instance_shader_parameter("mist_base_y", base_y)
			mi.set_instance_shader_parameter("mist_height", height)
			mi.set_instance_shader_parameter("mist_seed", seed + float(k) * 0.137)
			mi.set_instance_shader_parameter("mist_opacity", op)
			# Per-puff opacity via a per-instance material would add draw calls;
			# keep one shared material and scale the puff instead.
			add_child(mi)
			_puffs += 1
	print("mist volumes: %d (pond margins 2, cliff bases 3), %d puffs" % [
		VOLUMES.size(), _puffs])

func density_at(x: float, z: float) -> float:
	var best := 0.0
	for v in VOLUMES:
		var d := Vector2(x - float(v[0]), z - float(v[1])).length()
		best = max(best, clamp(1.0 - d / (float(v[2]) * 2.2), 0.0, 1.0))
	return best
