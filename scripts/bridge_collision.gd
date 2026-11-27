extends Node3D
## Box colliders for the ten baked bridge decks.  bridges.glb is one mesh, so
## there are no per-bridge prop transforms to copy; the spans come from
## map_layout.json and the deck height is sampled from the bridge mesh's lower
## envelope at five stations, then four boxes follow that sag.  No triangle
## collision is created.

const LAYOUT := "res://map_layout.json"
const STATIONS := [0.03, 0.25, 0.5, 0.75, 0.97]


func _ready() -> void:
	build()


func build() -> void:
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	if layout.is_empty():
		push_error("bridge_collision: no layout")
		return
	var map := get_parent().get_node_or_null("Map")
	if map == null:
		push_error("bridge_collision: no Map")
		return
	var bridges := map.find_child("Bridges", true, false) as Node3D
	if bridges == null:
		push_error("bridge_collision: Bridges missing")
		return
	var verts := _bridge_vertices(bridges)
	print("bridge collision: %d bridge vertices" % verts.size())
	var total := 0
	for i in layout["bridges"].size():
		var b: Dictionary = layout["bridges"][i]
		var a := Vector3(float(b["ax"]), 0.0, -float(b["az"]))
		var bb := Vector3(float(b["bx"]), 0.0, -float(b["bz"]))
		var dir := (bb - a).normalized()
		var length := a.distance_to(bb)
		var hs: Array[float] = []
		for t: float in STATIONS:
			hs.append(_deck_y(verts, a, dir, length, t))
		for s in range(STATIONS.size() - 1):
			var t0: float = STATIONS[s]
			var t1: float = STATIONS[s + 1]
			var p0 := a + dir * (length * t0)
			var p1 := a + dir * (length * t1)
			var y0 := hs[s]
			var y1 := hs[s + 1]
			var seg_len := p0.distance_to(p1)
			if seg_len < 0.05:
				continue
			var mid := p0.lerp(p1, 0.5)
			var yaw := atan2(dir.x, dir.z)
			var pitch := atan2(y1 - y0, seg_len)
			var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
			var body := StaticBody3D.new()
			body.name = "Bridge_%d_%d" % [i, s]
			body.collision_layer = 1
			body.transform = Transform3D(basis, Vector3(mid.x, (y0 + y1) * 0.5 - 0.13, mid.z))
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(1.35, 0.26, seg_len + 0.12)
			cs.shape = box
			body.add_child(cs)
			add_child(body)
			total += 1
		print("BRIDGE_COLLISION %d deck_mid=%.3f boxes=4 len=%.2f" % [
			i, hs[2], length])
	print("bridge collision: %d boxes over %d bridges" % [total, layout["bridges"].size()])


func _bridge_vertices(bridges: Node3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for n in bridges.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var a: Array = mi.mesh.surface_get_arrays(s)
			var vs: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			for v in vs:
				out.append(mi.global_transform * v)
	return out


func _deck_y(verts: PackedVector3Array, a: Vector3, dir: Vector3,
		length: float, t: float) -> float:
	var c := a + dir * (length * t)
	var perp := Vector3(-dir.z, 0.0, dir.x)
	var best := 1.0e20
	for v in verts:
		var rel := v - c
		if absf(rel.dot(dir)) < 0.20 and absf(rel.dot(perp)) < 0.50:
			best = minf(best, v.y)
	if best > 1.0e19:
		return c.y
	return best
