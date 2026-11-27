extends SceneTree
## Report how a GLB's meshes arrive in Godot before any conditioning: do the
## vertex colours survive the raw parse, and what do the materials look like?

func _initialize() -> void:
	for path in ["res://assets/worlds/ruins2/ruins2_flora.glb"]:
		var n = preload("res://scripts/glb_util.gd").instantiate_raw(path)
		if n == null:
			print("NULL for ", path)
			quit()
			return
		var shown := 0
		for mi in n.find_children("*", "MeshInstance3D", true, false):
			if shown >= 3:
				break
			if mi.mesh == null:
				continue
			var arr = mi.mesh.surface_get_arrays(0)
			var cols = arr[Mesh.ARRAY_COLOR]
			var cn := 0 if cols == null else cols.size()
			var m = mi.mesh.surface_get_material(0)
			var extra := ""
			if m is StandardMaterial3D:
				extra = " albedo=%s vcol=%s" % [str(m.albedo_color), str(m.vertex_color_use_as_albedo)]
			print("MESH %s colors=%d%s" % [mi.name, cn, extra])
			shown += 1
	quit()
