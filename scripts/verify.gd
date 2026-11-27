extends SceneTree
## Headless probe: loads the inspection scene and reports what actually exists,
## so the rig/animation wiring can be verified without a display.


func _init() -> void:
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		print("FAIL: main.tscn did not load")
		quit(1)
		return

	var root := packed.instantiate()
	get_root().add_child(root)

	await process_frame
	await process_frame

	var dragon: Node3D = root.get_node_or_null("Dragon")
	if dragon == null:
		print("FAIL: no Dragon node")
		quit(1)
		return

	_report_tree(dragon, 0)

	var ap := _find(dragon, "AnimationPlayer") as AnimationPlayer
	var skel := _find(dragon, "Skeleton3D") as Skeleton3D
	var mi := _find(dragon, "MeshInstance3D") as MeshInstance3D

	print("--- animation ---")
	if ap:
		print("player        : ", ap.name)
		print("animations    : ", ap.get_animation_list())
		print("playing       : ", ap.current_animation, "  (running=", ap.is_playing(), ")")
		if ap.current_animation != "":
			var a := ap.get_animation(ap.current_animation)
			print("length        : %.2f s   loop=%s" % [a.length, a.loop_mode])
			ap.seek(a.length * 0.4, true)
			print("seeked to     : %.2f s" % ap.current_animation_position)
	else:
		print("FAIL: no AnimationPlayer")

	print("--- skeleton ---")
	if skel:
		print("bones         : ", skel.get_bone_count())
		if skel.get_bone_count() > 0:
			print("first bone    : ", skel.get_bone_name(0))
	else:
		print("FAIL: no Skeleton3D")

	print("--- mesh ---")
	if mi and mi.mesh:
		print("surfaces      : ", mi.mesh.get_surface_count())
		print("material      : ", mi.get_active_material(0))
		print("aabb          : ", mi.get_aabb())
	else:
		print("FAIL: no MeshInstance3D")

	print("--- camera ---")
	var cam := _find(root, "Camera3D") as Camera3D
	if cam:
		print("global pos    : ", cam.global_position)
		print("fov           : ", cam.fov)
	else:
		print("FAIL: no Camera3D")

	var props := []
	for c in root.get_children():
		if c.name in ["Boulder", "Column", "Statue", "Tree"]:
			props.append(str(c.name))
	print("--- props ---")
	print("loaded        : ", props)

	print("--- environment ---")
	var we := _find(root, "WorldEnvironment") as WorldEnvironment
	print("has env       : ", we != null and we.environment != null)

	print("OK")
	quit(0)


func _report_tree(n: Node, depth: int) -> void:
	if depth > 3:
		return
	print("  ".repeat(depth), n.name, " (", n.get_class(), ")")
	for c in n.get_children():
		_report_tree(c, depth + 1)


func _find(n: Node, type_name: String) -> Node:
	for c in n.get_children():
		if c.is_class(type_name) or (c.get_script() != null and c.get_class() == type_name):
			return c
		var f := _find(c, type_name)
		if f:
			return f
	return null
