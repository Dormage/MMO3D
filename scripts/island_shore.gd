extends Node3D
## Cheap shingle rim for the three tiny bare islets (13/14/16).  These have no
## pond and no authored shore, so the terrain edge ended in a hard cut.  A
## three-band ribbon follows the island ellipse and is seated on the walkable
## terrain; no collision and no gameplay footprint.

const DATA := "res://map_layout.json"
const S := 1.6979
const CELL := 81.5
const IDS := [13, 14, 16]

func build(map: Node3D) -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	if d.is_empty():
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.39, 0.36, 0.30)
	mat.roughness = 0.98
	var rock_shader := load("res://shaders/bank_rock.gdshader") as Shader
	var albedo := load("res://assets/textures/stone_basalt/albedo.jpg")
	var rough := load("res://assets/textures/stone_basalt/rough.jpg")
	var rock_models := ["props/prop_bank_rock_s", "props/prop_bank_rock_m",
			"rocks_boulder_s", "ruins_slab_mossy_s"]
	var rock_count := 0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 3
	var n := 40
	for isl in d["islands"]:
		if not IDS.has(int(isl["id"])):
			continue
		var b: Array = isl["bbox"]
		var cx := (float(b[0]) + float(b[2])) * 0.5
		var cz := (float(b[1]) + float(b[3])) * 0.5
		var c := Vector3((cx - CELL) * S, 0.0, -(cz - CELL) * S)
		var rx := (float(b[2]) - float(b[0])) * S * 0.5
		var rz := (float(b[3]) - float(b[1])) * S * 0.5
		var pts: Array = []
		for r in rings:
			var f: float = [0.68, 0.84, 0.97][r]
			var row: Array = []
			for i in n:
				var a := TAU * float(i) / float(n)
				var x := c.x + cos(a) * rx * f
				var z := c.z + sin(a) * rz * f
				var y := float(map.call("_terrain_y", x, z))
				if y < -1.5:
					y = c.y - 0.6
				row.append(Vector3(x, y + 0.035, z))
			pts.append(row)
		for r in rings - 1:
			var A: Array = pts[r]
			var B: Array = pts[r + 1]
			for i in n:
				var j := (i + 1) % n
				st.add_vertex(A[i]); st.add_vertex(B[i]); st.add_vertex(B[j])
				st.add_vertex(A[i]); st.add_vertex(B[j]); st.add_vertex(A[j])
		# Mixed bank rocks break the rim into clusters with deliberate gaps.
		for k in 8:
			if k == 3 or k == 6:
				continue
			var bh := absi(hash("islet_%d_%d" % [int(isl["id"]), k]))
			var a := TAU * float(k) / 8.0 + float(bh % 37) * 0.01
			var rad := 0.83 + float(bh % 12) * 0.008
			var x := c.x + cos(a) * rx * rad
			var z := c.z + sin(a) * rz * rad
			var model: String = rock_models[(k + int(isl["id"])) % rock_models.size()]
			var packed := load("res://assets/models/%s.glb" % model) as PackedScene
			if packed == null:
				continue
			var inst := packed.instantiate() as Node3D
			if inst == null:
				continue
			var sc := (0.42 + float(bh % 55) / 100.0) if not model.contains("slab") else (0.7 + float(bh % 40) / 100.0)
			var tone := Color(0.50 + float(bh % 7) * 0.035, 0.47 + float(bh % 5) * 0.035, 0.42 + float(bh % 4) * 0.035)
			var rm := ShaderMaterial.new()
			rm.shader = rock_shader
			rm.set_shader_parameter("rock_albedo", albedo)
			rm.set_shader_parameter("rock_rough", rough)
			rm.set_shader_parameter("rock_tone", Vector3(tone.r, tone.g, tone.b))
			inst.name = "IsletRock_%d_%d" % [int(isl["id"]), k]
			inst.position = Vector3(x, float(map.call("_terrain_y", x, z)) + 0.02, z)
			inst.rotation = Vector3(float(bh % 9 - 4) * 0.03, float(bh % 628) / 100.0, float(bh % 11 - 5) * 0.03)
			inst.scale = Vector3(sc, sc * (0.5 if model.contains("slab") else 1.0), sc)
			for child in inst.find_children("*", "MeshInstance3D", true, false):
				(child as MeshInstance3D).material_override = rm
			add_child(inst)
			rock_count += 1
			# One tight double per islet.
			if k == 1:
				var dup := packed.instantiate() as Node3D
				if dup != null:
					dup.name = "IsletRock_%d_pair" % int(isl["id"])
					dup.position = inst.position + Vector3(0.22, -0.02, 0.16)
					dup.rotation = Vector3(0.03, inst.rotation.y + 1.0, -0.02)
					dup.scale = Vector3(sc * 0.55, sc * 0.5, sc * 0.6)
					for child in dup.find_children("*", "MeshInstance3D", true, false):
						(child as MeshInstance3D).material_override = rm
					add_child(dup)
					rock_count += 1
	st.generate_normals()
	var mesh := st.commit()
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "IslandShore"
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The warm outer ribbon reads as a detached gold hoop over the void from
	# the inspection camera.  It is a 3-islet shingle rim, not a marker; fade
	# it out once the islet itself is a distant speck.
	mi.visibility_range_end = 120.0
	mi.visibility_range_end_margin = 12.0
	add_child(mi)
	var arrays := mesh.surface_get_arrays(0)
	var nv: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	print("island shore: 3 islets, %d verts, ~%d tris, %d mixed rocks" % [nv, nv / 3, rock_count])
