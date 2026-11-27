extends Node
## Removes the detached 2,114-triangle north-west terrain flake at runtime.
## terrain.glb is untouched, so its 1,746 boundary edges / 82 loops / 18 shells
## and AABB stay intact.  The flake's black underside was the last eye-level
## void; removing it reveals the continuous hillside behind.
const DATA := "res://assets/terrain_flake_tris.json"

func _ready() -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	if d.is_empty():
		push_error("terrain flake data missing")
		return
	var parent := get_parent()
	var terrain := parent.find_child("Terrain", true, false) as Node3D
	if terrain == null:
		return
	var mi: MeshInstance3D = null
	for n in terrain.find_children("*", "MeshInstance3D", true, false):
		var m := n as MeshInstance3D
		if m.mesh != null and m.mesh.get_surface_count() >= 9:
			mi = m
			break
	if mi == null:
		return
	var out := ArrayMesh.new()
	var removed := 0
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var idx = arr[Mesh.ARRAY_INDEX]
		if idx == null:
			continue
		var skip: Dictionary = {}
		for t in d.get(str(s), []):
			skip[int(t)] = true
		var nidx := PackedInt32Array()
		for t in range(idx.size() / 3):
			if skip.has(t):
				removed += 1
				continue
			nidx.append(idx[t * 3]); nidx.append(idx[t * 3 + 1]); nidx.append(idx[t * 3 + 2])
		arr[Mesh.ARRAY_INDEX] = nidx
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(s, mi.mesh.surface_get_material(s))
	mi.mesh = out
	print("terrain flake removed: %d tris, surfaces=%d" % [removed, out.get_surface_count()])
