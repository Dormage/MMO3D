extends Node3D
## Simple layout-footprint box colliders for buildings.  The gate is split into
## two side boxes so its central passage stays clear; every other building gets
## one box.  These are collision only, no visible mesh.

const LAYOUT := "res://map_layout.json"


func build() -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	var map := get_parent()
	var tc := map.get_node_or_null("TerrainCollision") if map != null else null
	if d.is_empty() or not d.has("buildings"):
		push_warning("building collision: no layout buildings")
		return
	var n := 0
	for b in d["buildings"]:
		var id := String(b.get("id", ""))
		var x := float(b["x"])
		var z := -float(b["z"])
		var y := float(b["y"])
		var yaw := float(b.get("yaw", 0.0))
		var fp: Array = b.get("footprint", [4.0, 4.0])
		var fw := float(fp[0])
		var fd := float(fp[1])
		var pad_h := float(b.get("pad_h", 0.0))
		var base := y - pad_h
		if tc != null:
			var gh: float = tc.call("walkable_height", x, z)
			if not is_nan(gh):
				base = gh + 0.01
		var height := 6.0
		if id == "village_gate":
			# 4 m clear centre; 5.45 m half-width leaves two 3.45 m jambs.
			var open := 4.0
			var side := (fw - open) * 0.5
			for sx: float in [-1.0, 1.0]:
				_add_box("GateSide_%d" % n,
						Vector3(x + sx * (open * 0.5 + side * 0.5), base,
							z), Vector3(side, height, fd), yaw)
				n += 1
		else:
			_add_box("Building_%s" % id, Vector3(x, base, z),
					Vector3(fw, height, fd), yaw)
			n += 1
	print("building collision: %d boxes (gate centre open 4.0 m)" % n)


func _add_box(nm: String, base_pos: Vector3, size: Vector3, yaw: float) -> void:
	var body := StaticBody3D.new()
	body.name = nm
	body.collision_layer = 2
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = Vector3.ZERO
	body.add_child(cs)
	body.position = base_pos + Vector3(0.0, size.y * 0.5, 0.0)
	body.rotation.y = yaw
	add_child(body)
