extends Node3D
## Top-down click-to-move RPG controller.
##  * bakes a NavigationRegion3D over the walkable terrain (nav_world.gd);
##  * moves the existing CharacterBody3D along NavigationAgent3D paths;
##  * owns the fixed 60-degree isometric follow camera and mouse-wheel zoom.
## Collision, slope limits and bridges are still the player controller's job.

const NavWorld := preload("res://scripts/nav_world.gd")
const CAM_PITCH_DEG := 60.0
const CAM_MIN_DIST := 18.0
const CAM_MAX_DIST := 26.0
const CAM_START_DIST := 22.0
const CAM_YAW_DEG := 0.0
const CAM_SMOOTH := 6.7
const CAM_POS_SMOOTH := 5.0
const WATER_GRID := 163
const WATER_HALF := 81.5

var map: Node3D
var player: CharacterBody3D
var nav: Node3D
var camera: Camera3D
var focus := Vector3.ZERO
var cam_dist := CAM_START_DIST
var _water: PackedByteArray
var _building_rects: Array = []
var _last_click := {}
var links_ready := false
var _paths := 0
var _rejected := 0
var real_clicks := 0
var real_moves := 0
var _route_root: Node3D
var _route_active := false
var _route_grace := 0.0
var cursor_overlay: Control
var click_debug: Label
var _click_last_frame := -1
var _input_clicks := 0
var _unhandled_clicks := 0
var _click_start := Vector3.ZERO
var _click_check := 0.0
var _click_waiting := false
var _click_stage := {}
var hover_ring: Node3D
var _look_offset := Vector3.ZERO
var _pan_drag := false
var _cam_obstructed := false
var _debug_hover := Vector2(-1, -1)
var _hover_clock := 0.0
var _edge_pan_armed := false
var _debug_free_cam := false
var free_cam := false
var free_speed := 14.0
var _free_yaw := 0.0
var _free_pitch := -0.20
var _free_drag := false
var _free_return := 0.0
var _free_from_pos := Vector3.ZERO
var _free_to_pos := Vector3.ZERO
var _free_from_quat := Quaternion()
var _free_to_quat := Quaternion()
var _view_label: Label
var _phys_prev := Vector3.ZERO
var _phys_curr := Vector3.ZERO
var _phys_ready := false
const PAN_MAX_OFFSET := 18.0
const PAN_KEY_SPEED := 11.0
const PAN_EDGE_PX := 14.0


func _ready() -> void:
	process_physics_priority = 100
	map = get_node_or_null("Map") as Node3D
	player = get_node_or_null("Player") as CharacterBody3D
	if map == null or player == null:
		push_error("game_controller: Map/Player missing")
		return
	_load_water()
	# Let Map finish its deferred collision/prop setup before carving obstacles.
	for i in 4:
		await get_tree().physics_frame
	# Launch straight into fullscreen when asked: godot --path . -- --fullscreen
	for arg in OS.get_cmdline_user_args():
		if String(arg).to_lower() in ["--fullscreen", "-fullscreen"]:
			get_window().mode = Window.MODE_FULLSCREEN
			break
	nav = NavWorld.new()
	nav.name = "NavWorld"
	# An authored world supplies its own obstacle layout; the procedural
	# flying-islands map keeps map_layout.json.
	if map.has_method("nav_layout_path"):
		nav.set("layout_path", map.call("nav_layout_path"))
	add_child(nav)
	# The region's Map node is not necessarily the node game.tscn hands us: an
	# authored world wraps it.  Look through the subtree for whichever node
	# actually carries the flag.
	var carrier: Node = null
	if map.get("nav_carve_solids") != null:
		carrier = map
	else:
		for n in map.find_children("*", "", true, false):
			if n.get("nav_carve_solids") != null:
				carrier = n
				break
	if carrier != null:
		nav.set("carve_solids", carrier.get("nav_carve_solids"))
	print("CARVEFLAG carrier=%s value=%s" % [
		String(carrier.name) if carrier != null else "<none>",
		str(carrier.get("nav_carve_solids")) if carrier != null else "<default true>"])
	# Give the baker the waterline before it runs: without it the riverbed is
	# walkable and both paths and clicks cross open water.
	if carrier != null and carrier.get("_has_water") == true:
		nav.set("water_level", carrier.get("_water_level"))
		nav.set("has_water", true)
		print("WATER_LEVEL %.2f from %s" % [float(carrier.get("_water_level")), String(carrier.name)])
	nav.set("cache_id", String(carrier.get("region_id")) if carrier != null else "")
	if carrier != null:
		var g = carrier.get("nav_stitch_gap")
		var r = carrier.get("nav_stitch_rise")
		if g != null:
			nav.set("stitch_max_gap", float(g))
		if r != null:
			nav.set("stitch_max_rise", float(r))
	if carrier != null:
		var cells = carrier.get("_water_cells")
		if cells is PackedByteArray and (cells as PackedByteArray).size() > 0:
			nav.set("supplied_water", cells)
	nav.call("build", map)
	print("SHIPPED_INPUT node=%s in_tree=%s unhandled_enabled=%s" % [
		String(get_path()), str(is_inside_tree()), str(is_processing_unhandled_input())])
	print("SHIPPED_NAV polygons=%d vertices=%d region_polys=%d map_rid_ok=%s" % [
		int(nav.get("polygons")), int(nav.get("vertices")),
		int(nav.get("region").navigation_mesh.get_polygon_count()) if nav.get("region") != null else -1,
		str(nav.call("map_rid").is_valid())])
	for i in 3:
		await get_tree().physics_frame
	_build_links_and_obstacles()
	for i in 2:
		await get_tree().physics_frame
	# Shipped-path assertion: a real 5 m meadow path must not be empty.
	for i in 12:
		await get_tree().physics_frame
	print("SHIPPED_PLAYER pos=%s in_tree=%s" % [str(player.global_position), str(player.is_inside_tree())])
	if OS.get_cmdline_user_args().has("--pathtest"):
		# Wait for the navigation map to sync before trusting any query.
		for i in 240:
			await get_tree().process_frame
			var c0 = nav.call("closest", player.global_position)
			if c0 is Vector3 and (c0 as Vector3).length_squared() > 0.0001:
				break
		var goals := [Vector3(-18, 4.4, -23), Vector3(-30, 4.5, -35), Vector3(24, 4.0, -34),
			Vector3(-18.5, 1.0, -21.0), Vector3(-17.0, 2.0, -22.0)]
		for g in goals:
			var target: Vector3 = nav.call("closest", g)
			var pp: PackedVector3Array = nav.call("path", player.global_position, target)
			var gap := 1.0e9
			if pp.size() >= 2:
				gap = pp[pp.size() - 1].distance_to(target)
			print("PATHTEST goal=(%.0f,%.1f,%.0f) closest=(%.1f,%.1f,%.1f) pts=%d reached=%s" % [
				g.x, g.y, g.z, target.x, target.y, target.z, pp.size(),
				str(gap <= 0.8)])
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--navheight"):
		var rid3 := String(carrier.get("region_id")) if carrier != null else "map"
		var outh := "user://navheight_%s.obj" % rid3
		nav.call("dump_heightnav", outh)
		print("NAVHEIGHT path=%s" % ProjectSettings.globalize_path(outh))
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--navpatch"):
		var rid2 := String(carrier.get("region_id")) if carrier != null else "map"
		var outp := "user://navpatch_%s.obj" % rid2
		nav.call("dump_gap_patch", outp)
		print("NAVPATCH path=%s" % ProjectSettings.globalize_path(outp))
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--navdump"):
		var rid := String(carrier.get("region_id")) if carrier != null else "map"
		var out := "user://navdump_%s.obj" % rid
		nav.call("dump_obj", out)
		print("NAVDUMP path=%s" % ProjectSettings.globalize_path(out))
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--naptest"):
		var probe := preload("res://scripts/nav_probe.gd").new()
		probe.name = "NavProbe"
		probe.player = player
		probe.nav = nav
		probe.map = map
		add_child(probe)
		return
	var pa: Vector3 = nav.call("closest", player.global_position)
	var pb: Vector3 = nav.call("closest", player.global_position + Vector3(5.0, 0.0, 0.0))
	var pp: PackedVector3Array = nav.call("path", pa, pb)
	var plen := 0.0
	for i in range(1, pp.size()):
		plen += pp[i - 1].distance_to(pp[i])
	print("SHIPPED_PATH a=%s b=%s points=%d length=%.2f" % [str(pa), str(pb), pp.size(), plen])
	_build_camera()
	# The deep distant-island layer is authored for a low horizon camera.  From
	# the 60-degree RPG camera its 92 m sheet crosses the upper frame as a hard
	# dark shard.  Keep the near horizon islands; hide only the deep layer.
	for n in map.find_children("DeepIsland_*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).visible = false
	print("DEEP_ISLANDS_HIDDEN")
	# The old orbit camera must never steal current from the RPG camera.
	var pc := player.get_node_or_null("PlayerCamera") as Camera3D
	if pc != null:
		pc.current = false
	if DisplayServer.get_name() != "headless":
		# The game owns a high-contrast pointer so it is always visible in the
		# rendered frame (an OS cursor is not part of the viewport texture).
		var layer := CanvasLayer.new()
		layer.name = "CursorLayer"
		layer.layer = 100
		add_child(layer)
		cursor_overlay = load("res://scripts/cursor_overlay.gd").new()
		layer.add_child(cursor_overlay)
		var hud := CanvasLayer.new()
		hud.name = "ViewModeLayer"
		hud.layer = 99
		add_child(hud)
		_view_label = Label.new()
		_view_label.name = "ViewModeLabel"
		_view_label.focus_mode = Control.FOCUS_NONE
		_view_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_view_label.anchor_top = 1.0
		_view_label.anchor_bottom = 1.0
		_view_label.offset_left = 18
		_view_label.offset_top = -64
		_view_label.offset_bottom = -18
		_view_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
		_view_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		_view_label.add_theme_font_size_override("font_size", 16)
		_view_label.add_theme_color_override("font_color", Color(0.95, 0.96, 0.92, 0.88))
		_view_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
		_view_label.add_theme_constant_override("shadow_offset_x", 1)
		_view_label.add_theme_constant_override("shadow_offset_y", 1)
		hud.add_child(_view_label)
		_update_view_label()
		# Click diagnostics are opt-in only.  CLICK_DEBUG=1 shows the stage-by-
		# stage line; the shipped game owns no permanent debug HUD.
		if OS.get_environment("CLICK_DEBUG") == "1":
			click_debug = Label.new()
			click_debug.name = "ClickDebug"
			click_debug.position = Vector2(18, 74)
			click_debug.add_theme_font_size_override("font_size", 15)
			click_debug.add_theme_color_override("font_color", Color(1, 0.90, 0.42))
			click_debug.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1.0))
			click_debug.add_theme_constant_override("shadow_offset_x", 2)
			click_debug.add_theme_constant_override("shadow_offset_y", 2)
			click_debug.mouse_filter = Control.MOUSE_FILTER_IGNORE
			click_debug.focus_mode = Control.FOCUS_NONE
			click_debug.text = "CLICK_HUD waiting for left click\nclick_received=NO"
			layer.add_child(click_debug)
		hover_ring = load("res://scripts/hover_ring.gd").new()
		hover_ring.name = "HoverRing"
		add_child(hover_ring)
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	print("GAME_CAM pitch=%.0f dist=%.1f..%.1f focus_owner=%s" % [
		CAM_PITCH_DEG, CAM_MIN_DIST, CAM_MAX_DIST, str(get_viewport().gui_get_focus_owner())])
	if OS.get_cmdline_user_args().has("--screenshot"):
		await _screenshot_mode()


func _load_water() -> void:
	# An authored town ships no water mask; start with dry land everywhere.
	var txt := ""
	var wf := FileAccess.open("res://map_layout.json", FileAccess.READ)
	if wf != null:
		txt = wf.get_as_text()
	var d: Dictionary = {}
	if not txt.is_empty():
		var parsed = JSON.parse_string(txt)
		if parsed is Dictionary:
			d = parsed
	_water = PackedByteArray(); _water.resize(WATER_GRID * WATER_GRID); _water.fill(0)
	for w in d.get("water_mask", []):
		_water[int(w)] = 1
	_building_rects.clear()
	for b in d.get("buildings", []):
		var fp: Array = b.get("footprint", [4.0, 4.0])
		_building_rects.append([Vector2(float(b["x"]), -float(b["z"])),
			Vector2(float(fp[0]) * 0.5, float(fp[1]) * 0.5),
			float(b.get("yaw", 0.0)), String(b.get("id", ""))])


func _build_links_and_obstacles() -> void:
	# No NavigationLink3D edges: a returned path must be physically walkable.
	# Wait for the region map to finish syncing, then register tree avoidance.
	for i in 20:
		await get_tree().physics_frame
	var trees := 0
	for n in map.find_children("*", "MeshInstance3D", true, false):
		var nm := String(n.name).to_lower()
		if not (nm.begins_with("trees_") or nm.contains("tree_green") or nm.contains("tree_teal")):
			continue
		var mi := n as MeshInstance3D
		var ob := NavigationObstacle3D.new()
		ob.name = "TreeObstacle_%d" % trees
		ob.radius = 0.45
		ob.height = 2.0
		ob.avoidance_enabled = true
		ob.affect_navigation_mesh = false
		nav.add_child(ob)
		ob.global_position = mi.global_position
		trees += 1
	print("NAV_LINKS links=0 tree_obstacles=%d" % trees)
	# Clustered detail for the thin outer islands.  Runs after the navmesh has
	# synced so solids can be kept clear of walkable routes.
	# Procedural island scatter belongs to the flying-islands world.  An
	# authored world (town_map.gd) supplies its own props, so running this
	# would litter the town with detail meant for thin outer islands.
	if not map.has_method("nav_layout_path"):
		var detail_script := load("res://scripts/island_detail.gd")
		var detail = detail_script.new()
		detail.build(map, nav)
	else:
		print("ISLAND_DETAIL skipped: authored world")
	links_ready = true


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "RPGCamera"
	camera.near = 0.10
	camera.far = 700.0
	camera.fov = 52.0
	add_child(camera)
	camera.current = true
	focus = player.global_position
	_place_camera(true)


func _place_camera(immediate: bool = false) -> void:
	if camera == null:
		return
	var yaw := deg_to_rad(CAM_YAW_DEG)
	var pitch := deg_to_rad(CAM_PITCH_DEG)
	var back := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	var desired := focus + back * cam_dist
	var obstructed := false
	# Never let the eye go through terrain or a building roof.
	if not _debug_free_cam:
		var q := PhysicsRayQueryParameters3D.create(focus + Vector3(0, 1.2, 0), desired, 3)
		q.exclude = [player.get_rid()]
		var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			var hp: Vector3 = hit["position"]
			# An elevated 60-degree camera may sit above a roof that crosses
			# the low focus ray.  Pull in only when the desired eye is near or
			# below that obstruction; otherwise keep the intended framing.
			if desired.y <= hp.y + 1.5:
				obstructed = true
				desired = hp + (focus - hp).normalized() * 0.65
	# Hard floor clamp against the terrain, independent of the focus ray.  The
	# eye can never end up inside a cliff when the camera is panned to an edge
	# or held at min zoom.
	if not _debug_free_cam:
		var fq := PhysicsRayQueryParameters3D.create(
			Vector3(desired.x, 160.0, desired.z), Vector3(desired.x, -80.0, desired.z), 1)
		fq.exclude = [player.get_rid()]
		var fh := player.get_world_3d().direct_space_state.intersect_ray(fq)
		if not fh.is_empty() and desired.y < float(fh["position"].y) + 0.90:
			desired.y = float(fh["position"].y) + 0.90
	if immediate:
		camera.global_position = desired
	elif _cam_obstructed and not obstructed:
		# Recovery must not read as a one-second dolly: once the line clears,
		# snap straight back to the intended framing distance.
		camera.global_position = desired
	else:
		camera.global_position = camera.global_position.lerp(desired, 1.0 - exp(-CAM_POS_SMOOTH * get_process_delta_time()))
	_cam_obstructed = obstructed
	camera.look_at(focus + Vector3(0, 0.55, 0), Vector3.UP)


func _physics_process(_delta: float) -> void:
	if player == null:
		return
	var pos := player.global_position
	if not _phys_ready or pos.distance_to(_phys_curr) > 2.0:
		_phys_prev = pos
		_phys_curr = pos
		_phys_ready = true
	else:
		_phys_prev = _phys_curr
		_phys_curr = pos


func _interpolated_player_position() -> Vector3:
	if not _phys_ready:
		return player.global_position
	var a := Engine.get_physics_interpolation_fraction()
	return _phys_prev.lerp(_phys_curr, clampf(a, 0.0, 1.0))


func _process(delta: float) -> void:
	_perf_sample(delta)
	_throttle_actors(delta)
	if not _nopop_done:
		_nopop_done = true
		call_deferred("_apply_nopop")
	if not _minphys_done:
		_minphys_done = true
		call_deferred("_apply_minphys")
	if not _cli_gfx_applied:
		_cli_gfx_applied = true
		call_deferred("_apply_cli_graphics")
	if player == null or camera == null:
		return
	if free_cam:
		_process_free_camera(delta)
		return
	if _free_return > 0.0:
		_process_camera_return(delta)
		return
	_update_pan(delta)
	var target := _interpolated_player_position() + _look_offset
	# Sub-centimetre idle residuals must not move the camera.
	var planar_speed := Vector2(player.velocity.x, player.velocity.z).length()
	if planar_speed < 0.08 and target.distance_to(focus) < 0.05:
		target = focus
	focus = focus.lerp(target, 1.0 - exp(-CAM_SMOOTH * delta))
	_place_camera()
	# Hover is decoration: while the camera is travelling the cursor target moves
	# every frame anyway, so a raycast 22 times a second buys nothing and costs
	# frame time exactly when the player is moving.
	_hover_clock += delta
	if _hover_clock >= 0.045:
		_hover_clock = 0.0
		if planar_speed < 0.6:
			_update_hover()
	if _click_waiting:
		_click_check -= delta
		if _click_check <= 0.0:
			_click_waiting = false
			var moved := player.global_position.distance_to(_click_start) > 0.15
			_update_click_hud("YES" if moved else "NO")
			print("CLICK_MOVED moved=%s dist=%.3f active=%s" % [
				str(moved), player.global_position.distance_to(_click_start),
				str(player.call("is_path_active"))])
	if _route_active:
		_route_grace -= delta
		if _route_grace <= 0.0 and not bool(player.call("is_path_active")):
			_clear_route()


func _update_pan(delta: float) -> void:
	var k := Vector3.ZERO
	# Arrow keys pan the camera.  WASD stays with the character controller
	# (it moves and cancels a click path), so the two systems do not fight.
	if Input.is_key_pressed(KEY_LEFT):
		k.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		k.x += 1.0
	if Input.is_key_pressed(KEY_UP):
		k.z -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		k.z += 1.0
	if DisplayServer.get_name() != "headless" and _debug_hover.x < 0.0 and _edge_pan_armed:
		var vp := get_viewport()
		var sz := vp.get_visible_rect().size
		var mp := vp.get_mouse_position()
		if mp.x >= 0.0 and mp.y >= 0.0 and mp.x <= sz.x and mp.y <= sz.y:
			if mp.x < PAN_EDGE_PX: k.x -= 1.0
			if mp.x > sz.x - PAN_EDGE_PX: k.x += 1.0
			if mp.y < PAN_EDGE_PX: k.z -= 1.0
			if mp.y > sz.y - PAN_EDGE_PX: k.z += 1.0
	if k.length_squared() > 0.0:
		_look_offset += k.normalized() * PAN_KEY_SPEED * delta
	_clamp_look_offset()


func _clamp_look_offset() -> void:
	_look_offset.x = clampf(_look_offset.x, -PAN_MAX_OFFSET, PAN_MAX_OFFSET)
	_look_offset.z = clampf(_look_offset.z, -PAN_MAX_OFFSET, PAN_MAX_OFFSET)
	if _look_offset.length() > PAN_MAX_OFFSET:
		_look_offset = _look_offset.normalized() * PAN_MAX_OFFSET


func _is_interactive_node(col: CollisionObject3D) -> bool:
	var words := ["gate", "stall", "barrel", "crate", "cart", "sign", "well",
		"door", "chest", "npc", "vendor", "lantern", "banner"]
	var n: Node = col
	for depth in 4:
		if n == null:
			break
		var nm := String(n.name).to_lower()
		for wd in words:
			if nm.contains(wd):
				return true
		n = n.get_parent()
	return false


func _update_hover() -> void:
	if camera == null or nav == null or cursor_overlay == null or hover_ring == null:
		return
	var vr := get_viewport().get_visible_rect().size
	var screen := _debug_hover if _debug_hover.x >= 0.0 else get_viewport().get_mouse_position()
	if screen.x < 0.0 or screen.y < 0.0 or screen.x > vr.x or screen.y > vr.y:
		cursor_overlay.set_state(1)
		hover_ring.hide_ring()
		return
	var from := camera.project_ray_origin(screen)
	var to := from + camera.project_ray_normal(screen) * 800.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 3)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		cursor_overlay.set_state(1)
		hover_ring.hide_ring()
		return
	var p: Vector3 = hit["position"]
	var col := hit["collider"] as CollisionObject3D
	if col != null and (col.collision_layer & 2) != 0:
		if _is_interactive_node(col):
			cursor_overlay.set_state(2)
			hover_ring.show_at(p, true)
		else:
			cursor_overlay.set_state(1)
			hover_ring.show_at(p, false)
		return
	if nav.call("is_water", p):
		cursor_overlay.set_state(1)
		hover_ring.show_at(p, false)
		return
	# Terrain is always a legal destination now, so show the live ring rather
	# than the blocked cross no matter how far the navmesh sits.
	cursor_overlay.set_state(0)
	hover_ring.show_at(p, true)


## Borderless fullscreen toggle.  MODE_FULLSCREEN rather than exclusive: it
## survives alt-tab and multi-monitor changes far more gracefully.
func toggle_fullscreen() -> void:
	var win := get_window()
	# An embedded game window is a child of the editor and cannot go fullscreen,
	# so say so instead of silently doing nothing.
	if win.has_method("is_embedded") and win.is_embedded():
		print("FULLSCREEN refused: game is embedded in the editor. "
				+ "Editor Settings > Run > Window Placement > Game Embed Mode = Disabled")
		return
	var is_full := win.mode == Window.MODE_FULLSCREEN \
			or win.mode == Window.MODE_EXCLUSIVE_FULLSCREEN
	win.mode = Window.MODE_WINDOWED if is_full else Window.MODE_FULLSCREEN
	print("FULLSCREEN %s mode=%d" % ["off" if is_full else "on", int(win.mode)])


func _input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo:
		var ke := event as InputEventKey
		if ke.keycode == KEY_TAB:
			_switch_region(1 if ke.shift_pressed else -1)
			get_viewport().set_input_as_handled()
			return
		# Number keys 8/9 jump straight to a region, leaving 1-7 for weapons.
		if ke.keycode >= KEY_8 and ke.keycode <= KEY_9:
			_jump_region(ke.keycode - KEY_8 + 1)
			get_viewport().set_input_as_handled()
			return
		# F11 rather than Escape: Escape already leaves the free camera.
		if ke.keycode == KEY_F11:
			toggle_fullscreen()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo \
			and (event as InputEventKey).keycode == KEY_F:
		toggle_free_camera()
		get_viewport().set_input_as_handled()
		return
	if free_cam:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT:
				_free_drag = mb.pressed
				get_viewport().set_input_as_handled()
				return
			if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				free_speed = minf(free_speed * 1.25, 160.0)
				get_viewport().set_input_as_handled()
				return
			if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				free_speed = maxf(free_speed / 1.25, 0.5)
				get_viewport().set_input_as_handled()
				return
		if event is InputEventMouseMotion and _free_drag:
			var rel := (event as InputEventMouseMotion).relative
			_free_yaw -= rel.x * 0.0030
			_free_pitch = clampf(_free_pitch - rel.y * 0.0030, -1.50, 1.50)
			get_viewport().set_input_as_handled()
		return
	# Catch the left click before GUI consumption, and dedupe against the
	# _unhandled_input path below.  The shipped game must not depend on no
	# Control having eaten the event.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_input_clicks += 1
			_handle_left_click(mb)


## Cycle to the next (or previous) region.  A reload is used rather than an
## in-place swap: collision, navmesh, obstacle links and the water plane are all
## bound to whichever region was present in _ready(), and rebuilding them from
## scratch is the only way to be certain none of it goes stale.
func _switch_region(step: int) -> void:
	if not RegionState.cycle(step):
		return
	_reload_for_region()


func _jump_region(index: int) -> void:
	if index >= RegionState.count() or index == RegionState.current:
		return
	if RegionState.select(index):
		_reload_for_region()


func _reload_for_region() -> void:
	print("REGION_SWITCH -> %d:%s (%s)" % [
		RegionState.current, RegionState.current_id(), RegionState.current_name()])
	# Deferred: we are inside input dispatch and the node cannot be freed mid-event.
	get_tree().call_deferred("change_scene_to_file", "res://game.tscn")


func _handle_left_click(mb: InputEventMouseButton) -> void:
	var frame := Engine.get_process_frames()
	if frame == _click_last_frame:
		return
	_click_last_frame = frame
	real_clicks += 1
	var raw := mb.position
	var screen := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(screen) if camera != null else Vector3.ZERO
	var dir := camera.project_ray_normal(screen) if camera != null else Vector3.ZERO
	var r := attempt_click(screen)
	if bool(r.get("found", false)):
		real_moves += 1
	var wp: Vector3 = r.get("point", Vector3.ZERO)
	var path: PackedVector3Array = r.get("path", PackedVector3Array())
	var hit_kind := String(r.get("hit", "none"))
	var path_text := "%d pts" % path.size() if path.size() >= 2 else "ERR"
	_click_stage = {"raw": raw, "screen": screen, "world": wp, "hit": hit_kind,
		"path": path_text, "reason": String(r.get("reason", "?")), "found": bool(r.get("found", false))}
	_click_start = player.global_position if player != null else Vector3.ZERO
	_click_check = 0.65
	_click_waiting = true
	_update_click_hud("pending")
	print("CLICK_STAGE received=YES input=%d unhandled=%d raw=%s viewport=%s from=%s dir=%s world=%s hit=%s path=%s found=%s reason=%s" % [
		_input_clicks, _unhandled_clicks, str(raw), str(screen), str(from), str(dir), str(wp), hit_kind, path_text,
		str(r.get("found")), str(r.get("reason"))])


func _update_click_hud(moved: String) -> void:
	if click_debug == null:
		return
	var raw: Vector2 = _click_stage.get("raw", Vector2.ZERO)
	var screen: Vector2 = _click_stage.get("screen", Vector2.ZERO)
	var wp: Vector3 = _click_stage.get("world", Vector3.ZERO)
	click_debug.text = "click_received=YES  raw=(%.0f,%.0f)  viewport=(%.0f,%.0f)\nworld=(%.2f,%.2f,%.2f)  hit=%s  path=%s  moved=%s\nreason=%s" % [
		raw.x,raw.y,screen.x,screen.y,wp.x,wp.y,wp.z,
		String(_click_stage.get("hit","none")),String(_click_stage.get("path","ERR")),moved,
		String(_click_stage.get("reason","?"))]


func _unhandled_input(event: InputEvent) -> void:
	if free_cam:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_pan_drag = mb.pressed
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_dist = clampf(cam_dist - 0.8, CAM_MIN_DIST, CAM_MAX_DIST)
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist = clampf(cam_dist + 0.8, CAM_MIN_DIST, CAM_MAX_DIST)
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_unhandled_clicks += 1
			_handle_left_click(mb)
			return
		return
	if event is InputEventMouseMotion and not _pan_drag:
		if (event as InputEventMouseMotion).relative.length() > 0.5:
			_edge_pan_armed = true
	if event is InputEventMouseMotion and _pan_drag:
		var rel := (event as InputEventMouseMotion).relative
		var s := 0.0018 * cam_dist
		_look_offset += Vector3(-rel.x * s, 0.0, -rel.y * s)
		_clamp_look_offset()
		return
	if event is InputEventKey and (event as InputEventKey).pressed 			and not (event as InputEventKey).echo:
		var kc := (event as InputEventKey).keycode
		if kc == KEY_R or kc == KEY_HOME:
			_look_offset = Vector3.ZERO




func _clear_route() -> void:
	if _route_root != null:
		# Remove immediately so a new click can reuse the ClickRoute name in
		# the same frame; queue_free alone leaves the old name reserved and
		# Godot silently renames the replacement to ClickRoute2.
		if _route_root.get_parent() != null:
			_route_root.get_parent().remove_child(_route_root)
		_route_root.queue_free()
		_route_root = null
	_route_active = false


func _route_material(col: Color, depth_test: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 1.6
	m.disable_receive_shadows = true
	m.no_depth_test = depth_test
	m.render_priority = 4
	return m


func _show_route(path: PackedVector3Array, target: Vector3) -> void:
	_clear_route()
	if path.size() < 2:
		return
	_route_root = Node3D.new()
	_route_root.name = "ClickRoute"
	add_child(_route_root)
	var line := ImmediateMesh.new()
	var lm := _route_material(Color(0.10, 0.55, 1.0), false)
	line.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, lm)
	for p in path:
		line.surface_add_vertex(p + Vector3(0, 0.075, 0))
	line.surface_end()
	var lmi := MeshInstance3D.new()
	lmi.name = "RouteLine"
	lmi.mesh = line
	lmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_route_root.add_child(lmi)
	# Dots make the corridor readable at the 60-degree camera even where a
	# 1-pixel line aliases into the grass.
	var dot_mesh := SphereMesh.new()
	dot_mesh.radius = 0.055
	dot_mesh.height = 0.11
	dot_mesh.radial_segments = 8
	dot_mesh.rings = 4
	var dm := _route_material(Color(0.25, 0.72, 1.0), false)
	var acc := 0.0
	var step := 0.48
	for i in range(1, path.size()):
		var a := path[i - 1]
		var b := path[i]
		var seg := a.distance_to(b)
		if seg < 0.001:
			continue
		var t := step - acc
		while t <= seg:
			var p := a.lerp(b, t / seg)
			var dot := MeshInstance3D.new()
			dot.mesh = dot_mesh
			dot.material_override = dm
			dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_route_root.add_child(dot)
			dot.global_position = p + Vector3(0, 0.085, 0)
			t += step
		acc = fmod(acc + seg, step)
	# Destination: blue vertical beam + octahedral head + base ring.
	var pin := Node3D.new()
	pin.name = "DestinationPin"
	_route_root.add_child(pin)
	pin.global_position = target + Vector3(0, 0.02, 0)
	var beam := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.035
	cyl.bottom_radius = 0.055
	cyl.height = 1.55
	beam.mesh = cyl
	beam.position.y = 0.80
	beam.material_override = _route_material(Color(0.10, 0.48, 1.0), true)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pin.add_child(beam)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.13
	sm.height = 0.26
	sm.radial_segments = 4
	sm.rings = 2
	head.mesh = sm
	head.position.y = 1.72
	head.material_override = _route_material(Color(0.30, 0.78, 1.0), true)
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pin.add_child(head)
	var ring := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = 0.17
	tor.outer_radius = 0.25
	ring.mesh = tor
	ring.rotation.x = PI * 0.5
	ring.position.y = 0.02
	ring.material_override = _route_material(Color(0.16, 0.62, 1.0), true)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pin.add_child(ring)
	var light := OmniLight3D.new()
	light.light_color = Color(0.15, 0.55, 1.0)
	light.light_energy = 0.9
	light.omni_range = 4.5
	light.shadow_enabled = false
	pin.add_child(light)
	_route_active = true
	_route_grace = 0.30


## Ray from the camera through the cursor.  Layer 2 is a wall/building/prop:
## reject rather than pathing through it.  Water and off-nav clicks snap to the
## nearest navmesh point only when it is within 1.5 m; otherwise reject.
func attempt_click(screen: Vector2) -> Dictionary:
	var res := {"clicked": false, "found": false, "reason": "no_camera", "point": Vector3.ZERO,
		"hit": "none", "path": PackedVector3Array(), "length": 0.0, "straight": 0.0, "nearest": 0.0}
	_clear_route()
	if camera == null or nav == null or player == null:
		return res
	res["clicked"] = true
	var from := camera.project_ray_origin(screen)
	var to := from + camera.project_ray_normal(screen) * 800.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 3)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	if OS.get_environment("CLICK_DEBUG") == "1":
		print("CLICK_DBG screen=%s from=%s dir=%s hit=%s col=%s layer=%d" % [
			str(screen),str(from),str(camera.project_ray_normal(screen)),str(not hit.is_empty()),
			String((hit["collider"] as Node).name) if not hit.is_empty() else "none",
			(hit["collider"] as CollisionObject3D).collision_layer if not hit.is_empty() else -1])
	if hit.is_empty():
		res["reason"] = "no_ground"
		_rejected += 1
		_last_click = res
		return res
	var col := hit["collider"] as CollisionObject3D
	# Judge a solid body by the face that was hit, not by its layer.  A bridge
	# deck belongs to a solid mesh, so rejecting every layer-2 hit made the deck
	# unclickable even though the capsule walks it fine -- the surface is level,
	# so it is a destination, not a wall.  Steep faces stay rejected.
	var hit_n: Vector3 = hit.get("normal", Vector3.UP)
	var flat_hit := hit_n.y >= 0.6
	if col != null and (col.collision_layer & 2) != 0 and not flat_hit:
		res["hit"] = "building"
		res["reason"] = "blocked_building"
		_rejected += 1
		_last_click = res
		return res
	var p: Vector3 = hit["position"]
	res["point"] = p
	res["hit"] = "terrain"
	if nav.call("is_water", p):
		res["hit"] = "water"
		res["reason"] = "water"
		_rejected += 1
		_last_click = res
		return res
	var closest: Vector3 = nav.call("closest", p)
	var nd := p.distance_to(closest)
	if OS.get_environment("CLICK_DEBUG") == "1":
		print("CLICK_NAV p=%s closest=%s nd=%.3f" % [str(p),str(closest),nd])
	res["nearest"] = nd
	var path: PackedVector3Array = nav.call("path", player.global_position, closest)
	# Route on the navmesh whenever a route exists, even if the click landed well
	# off it.  The previous rule gave up as soon as the target was more than 1.5 m
	# from the mesh and walked in a straight line instead, which is why the player
	# ground into walls and props instead of going around them.  A straight line
	# is now only used when the navmesh offers no path at all.
	var gap := 1.0e9
	if path.size() >= 2:
		gap = path[path.size() - 1].distance_to(closest)
	var use_nav := path.size() >= 2 and gap <= 0.80
	var final_point := closest
	if not use_nav:
		# The destination sits on a navmesh island the player cannot reach -- an
		# elevated terrace whose stairs were never baked.  The fallback here used
		# to be a straight line, which drove the player into the cliff and left
		# them stuck.  Refuse rather than pretend it is walkable.
		if gap < 1.0e8:
			res["reason"] = "unreachable"
			res["nearest"] = closest.distance_to(p)
			_rejected += 1
			_last_click = res
			return res
		path = PackedVector3Array([player.global_position, p])
		final_point = p
		res["reason"] = "direct"
	# The navmesh is eroded, so its closest point can sit short of a walkable
	# click.  Walk that final leg directly, but only when it is short enough that
	# there is nothing to route around in it.
	var leg_limit := 8.0 if flat_hit else 3.0
	if use_nav and p.distance_to(closest) > 0.03 and p.distance_to(closest) <= leg_limit:
		path.append(p)
		final_point = p
	var length := 0.0
	for i in range(1, path.size()):
		length += path[i - 1].distance_to(path[i])
	res["found"] = true
	res["reason"] = "ok"
	res["path"] = path
	res["length"] = length
	res["straight"] = player.global_position.distance_to(final_point)
	res["point"] = final_point
	player.call("move_along", path)
	_show_route(path, final_point)
	_paths += 1
	_last_click = res
	return res


func _inside_building(p: Vector3) -> bool:
	for r in _building_rects:
		var c: Vector2 = r[0]
		var h: Vector2 = r[1]
		var yaw: float = r[2]
		var d := Vector2(p.x, p.z) - c
		var cs := cos(-yaw)
		var sn := sin(-yaw)
		var lx := d.x * cs - d.y * sn
		var lz := d.x * sn + d.y * cs
		if absf(lx) <= h.x and absf(lz) <= h.y:
			# Gate has a 3.6 m clear centre: only its jambs are solid.
			if String(r[3]) == "village_gate" and absf(lx) < 1.8:
				continue
			return true
	return false


func _is_water(p: Vector3) -> bool:
	var i := int(round(p.x + WATER_HALF))
	var j := int(round(p.z + WATER_HALF))
	if i < 0 or j < 0 or i >= WATER_GRID or j >= WATER_GRID:
		return false
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var ii: int = i + dx
			var jj: int = j + dz
			if ii >= 0 and jj >= 0 and ii < WATER_GRID and jj < WATER_GRID \
					and _water[jj * WATER_GRID + ii] != 0:
				return true
	return false


func debug_click_world(p: Vector3, allow_offscreen := false) -> Dictionary:
	# Direct obstacle assertions for the test matrix: a point on a building,
	# wall or pond is rejected even if the camera ray would graze past it.
	if _inside_building(p):
		return {"clicked": true, "found": false, "reason": "blocked_building", "point": p,
			"path": PackedVector3Array(), "length": 0.0, "straight": 0.0, "nearest": 0.0}
	if nav.call("is_water", p):
		return {"clicked": true, "found": false, "reason": "water", "point": p,
			"path": PackedVector3Array(), "length": 0.0, "straight": 0.0, "nearest": 0.0}
	var s := camera.unproject_position(p)
	var vp := camera.get_viewport().get_visible_rect().size
	if not allow_offscreen and (s.x < 0 or s.y < 0 or s.x > vp.x or s.y > vp.y):
		return {"clicked": false, "found": false, "reason": "offscreen", "point": p,
			"path": PackedVector3Array(), "length": 0.0, "straight": 0.0, "nearest": 0.0}
	# For logic tests, project_ray still gives the ray through p even when the
	# point is just outside the viewport rectangle.
	var from := camera.project_ray_origin(s)
	var to := from + camera.project_ray_normal(s) * 800.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 3)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {"clicked": true, "found": false, "reason": "no_ground", "point": p,
			"path": PackedVector3Array(), "length": 0.0, "straight": 0.0, "nearest": 0.0}
	var col := hit["collider"] as CollisionObject3D
	if col != null and (col.collision_layer & 2) != 0:
		return {"clicked": true, "found": false, "reason": "blocked_building", "point": hit["position"],
			"path": PackedVector3Array(), "length": 0.0, "straight": 0.0, "nearest": 0.0}
	return attempt_click(s)


func _reset_follow_history() -> void:
	if player == null:
		return
	_phys_prev = player.global_position
	_phys_curr = player.global_position
	_phys_ready = true


func toggle_free_camera() -> void:
	if free_cam:
		_exit_free_camera()
	else:
		_enter_free_camera()


func _enter_free_camera() -> void:
	if player == null or camera == null:
		return
	free_cam = true
	_free_return = 0.0
	_free_drag = false
	_free_yaw = camera.rotation.y
	_free_pitch = camera.rotation.x
	free_speed = 14.0
	player.call("set_inspection_freeze", true)
	if hover_ring != null:
		hover_ring.hide_ring()
	if cursor_overlay != null:
		cursor_overlay.set_state(0)
	_update_view_label()


func _exit_free_camera() -> void:
	if player == null or camera == null:
		return
	_free_drag = false
	free_cam = false
	# Capture the free pose, snap the follow rig to its exact target, then
	# restore the free pose and ease between them.
	var from_pos := camera.global_position
	var from_quat := camera.global_transform.basis.get_rotation_quaternion()
	focus = player.global_position
	_look_offset = Vector3.ZERO
	cam_dist = CAM_START_DIST
	_place_camera(true)
	_free_from_pos = from_pos
	_free_from_quat = from_quat
	_free_to_pos = camera.global_position
	_free_to_quat = camera.global_transform.basis.get_rotation_quaternion()
	camera.global_position = from_pos
	camera.quaternion = from_quat
	_free_return = 0.32
	_update_view_label()


func _process_free_camera(delta: float) -> void:
	# Six degrees of freedom, no collision, no clamp, no navmesh.  The player
	# is frozen at his exact transform; only this camera moves.
	camera.rotation = Vector3(_free_pitch, _free_yaw, 0.0)
	var move := Vector3.ZERO
	var fwd := -camera.global_transform.basis.z
	var right := camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		move += fwd
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		move -= fwd
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		move -= right
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		move += right
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_SPACE):
		move += Vector3.UP
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_CTRL):
		move -= Vector3.UP
	if move.length_squared() > 0.0:
		var boost := 4.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		camera.global_position += move.normalized() * free_speed * boost * delta


func _process_camera_return(delta: float) -> void:
	_free_return = maxf(0.0, _free_return - delta)
	var t := 1.0 - _free_return / 0.32
	var e := t * t * (3.0 - 2.0 * t)
	camera.global_position = _free_from_pos.lerp(_free_to_pos, e)
	camera.quaternion = _free_from_quat.slerp(_free_to_quat, e)
	if _free_return <= 0.0:
		camera.global_position = _free_to_pos
		camera.quaternion = _free_to_quat
		player.call("set_inspection_freeze", false)
		focus = player.global_position
		_look_offset = Vector3.ZERO
		cam_dist = CAM_START_DIST
		_place_camera(true)
		_update_view_label()


func _update_view_label() -> void:
	if _view_label == null:
		return
	if free_cam:
		_view_label.text = "FREE CAMERA   [F] PLAYER VIEW\nWASD/Arrows fly  ·  Q/E or Space/Ctrl up/down  ·  LMB drag look  ·  Wheel speed  ·  Shift boost"
		_view_label.add_theme_color_override("font_color", Color(0.92, 0.98, 1.0, 0.92))
	else:
		_view_label.text = "PLAYER VIEW   [F] FREE CAMERA"
		_view_label.add_theme_color_override("font_color", Color(0.95, 0.96, 0.92, 0.88))


func debug_free_pose(pos: Vector3, look_at_pos: Vector3) -> void:
	if camera == null:
		return
	camera.global_position = pos
	camera.look_at(look_at_pos, Vector3.UP)
	_free_yaw = camera.rotation.y
	_free_pitch = camera.rotation.x


func debug_teleport(p: Vector3) -> void:
	_debug_free_cam = false
	player.global_position = p
	player.velocity = Vector3.ZERO
	_look_offset = Vector3.ZERO
	focus = p
	_reset_follow_history()
	_place_camera(true)


func debug_camera_to(p: Vector3, dist: float = 24.0) -> void:
	_debug_free_cam = true
	_look_offset = Vector3.ZERO
	focus = p
	cam_dist = clampf(dist, CAM_MIN_DIST, CAM_MAX_DIST)
	_place_camera(true)


## Headless/offscreen visual check: free camera, a few angles, PNG to user://.
func _screenshot_mode() -> void:
	await get_tree().create_timer(3.5).timeout
	var region := ""
	var reg := get_node_or_null("/root/RegionState")
	if reg != null:
		region = String(reg.call("current_id"))
	if region.is_empty() and map.has_method("region_id"):
		region = String(map.call("region_id"))
	if region.is_empty():
		region = "region"
	var shots: Array = []
	match region:
		"island":
			shots = [
				[Vector3(0.0, 34.0, 38.0), Vector3(0.0, 1.0, 0.0)],
				[Vector3(-32.0, 20.0, 30.0), Vector3(-28.0, 1.0, 18.0)],
				[Vector3(38.0, 22.0, -34.0), Vector3(32.0, 1.0, -28.0)],
			]
		"town":
			shots = [
				[Vector3(0.0, 24.0, 26.0), Vector3(0.0, 1.0, 0.0)],
				[Vector3(28.0, 18.0, 30.0), Vector3(24.0, 1.0, 20.0)],
				[Vector3(-28.0, 18.0, -24.0), Vector3(-24.0, 1.0, -16.0)],
			]
		"desert":
			shots = [
				[Vector3(0.0, 26.0, 28.0), Vector3(0.0, 1.0, 0.0)],
				[Vector3(26.0, 18.0, 30.0), Vector3(22.0, 1.0, 20.0)],
				[Vector3(-28.0, 20.0, 26.0), Vector3(-24.0, 1.0, 18.0)],
			]
		_:
			shots = [[Vector3(0.0, 26.0, 28.0), Vector3(0.0, 1.0, 0.0)]]
	_enter_free_camera()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://screenshots"))
	for i in shots.size():
		var shot: Array = shots[i]
		debug_free_pose(shot[0] as Vector3, shot[1] as Vector3)
		await _save_viewport_shot(region, str(i))
	# One close-up of the densest knot of populated actors, so the screenshot
	# set shows readable character detail instead of only a wide layout view.
	var pop := get_tree().get_nodes_in_group("population")
	if not pop.is_empty():
		var best: Node3D = null
		var best_count := -1
		var best_group: Array[Node3D] = []
		for a in pop:
			if not (a is Node3D):
				continue
			var group: Array[Node3D] = []
			for b in pop:
				if b is Node3D and (a as Node3D).global_position.distance_to((b as Node3D).global_position) <= 14.0:
					group.append(b as Node3D)
			if group.size() > best_count:
				best_count = group.size()
				best = a as Node3D
				best_group = group
		if best != null:
			var centre := Vector3.ZERO
			for a in best_group:
				centre += a.global_position
			centre /= maxf(float(best_group.size()), 1.0)
			debug_free_pose(centre + Vector3(0.0, 15.0, 15.0), centre + Vector3(0.0, 1.1, 0.0))
			await _save_viewport_shot(region, "cluster")
		# A high three-quarter shot that contains every populated actor, so the
		# whole distribution is visible in one frame.
		var lo := Vector3(1.0e9, 1.0e9, 1.0e9)
		var hi := Vector3(-1.0e9, -1.0e9, -1.0e9)
		for a in pop:
			if a is Node3D:
				lo = lo.min((a as Node3D).global_position)
				hi = hi.max((a as Node3D).global_position)
		var mid := (lo + hi) * 0.5
		var radius := maxf((hi - lo).length() * 0.5, 20.0)
		var h := maxf(45.0, radius * 1.45)
		debug_free_pose(mid + Vector3(0.0, h, h), mid)
		await _save_viewport_shot(region, "overview")
	get_tree().quit()


func _save_viewport_shot(region: String, suffix: String) -> void:
	for _f in 8:
		await get_tree().process_frame
	await get_tree().create_timer(0.15).timeout
	var img := get_viewport().get_texture().get_image()
	var path := "user://screenshots/%s_%s.png" % [region, suffix]
	var err := img.save_png(path)
	print("SCREENSHOT region=%s i=%s size=%s err=%d path=%s" % [
		region, suffix, str(img.get_size()), err, ProjectSettings.globalize_path(path)])


func stats() -> Dictionary:
	return {"paths": _paths, "rejected": _rejected, "last": _last_click}


func debug_hover_screen(s: Vector2) -> void:
	_debug_hover = s
	if cursor_overlay != null and cursor_overlay.has_method("debug_set_position"):
		cursor_overlay.call("debug_set_position", s)
	_hover_clock = 1.0


func debug_set_zoom(d: float) -> void:
	cam_dist = clampf(d, CAM_MIN_DIST, CAM_MAX_DIST)
	_place_camera(true)


func debug_pan_offset(o: Vector3) -> void:
	_look_offset = Vector3(o.x, 0.0, o.z)
	_clamp_look_offset()
	focus = player.global_position + _look_offset
	_place_camera(true)


func debug_camera_state() -> Dictionary:
	var ground := 0.0
	if camera != null and player != null:
		var q := PhysicsRayQueryParameters3D.create(
			Vector3(camera.global_position.x, 160.0, camera.global_position.z),
			Vector3(camera.global_position.x, -80.0, camera.global_position.z), 1)
		q.exclude = [player.get_rid()]
		var h := player.get_world_3d().direct_space_state.intersect_ray(q)
		if not h.is_empty():
			ground = float(h["position"].y)
	return {"focus": focus, "offset": _look_offset, "dist": cam_dist,
		"cam": camera.global_position if camera != null else Vector3.ZERO,
		"clearance": (camera.global_position.y - ground) if camera != null else 0.0}


func debug_probe_screen(s: Vector2) -> Dictionary:
	var from := camera.project_ray_origin(s)
	var to := from + camera.project_ray_normal(s) * 800.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 3)
	q.exclude = [player.get_rid()]
	var h := player.get_world_3d().direct_space_state.intersect_ray(q)
	if h.is_empty():
		return {"hit": false}
	var col := h["collider"] as CollisionObject3D
	return {"hit": true, "point": h["position"], "name": col.name if col != null else "",
		"layer": col.collision_layer if col != null else 0,
		"interactive": _is_interactive_node(col) if col != null else false}


## Opt-in, wall-clock profiling. Physics may fall behind real time when the
## step cap is reached, so neither `delta` nor a presumed 120 ticks is a valid
## denominator. Timers below use the actual player tick/call counts.
## Engine process/physics monitors are last-frame snapshots, not additive
## components of our wall-clock frame measurements. Render "primitives" count
## vertices/indices over passes; they must not be labelled as triangle counts.
var _perf_enabled := OS.get_environment("PERF_LOG") == "1"
## The standalone benchmark consumes the same counters in defined phases.
var _perf_external_sampling := false
var _perf_start_us := -1
var _perf_previous_us := -1
var _perf_start_physics := 0
var _perf_frame_ms := PackedFloat64Array()


func _perf_sample(_delta: float) -> void:
	if not _perf_enabled or _perf_external_sampling:
		return
	_perf_sample_at(Time.get_ticks_usec())


func _perf_sample_at(now: int) -> void:
	if _perf_start_us < 0:
		_perf_start_us = now
		_perf_previous_us = now
		_perf_start_physics = Engine.get_physics_frames()
		# Discard work before this window, including initial model fitting.
		if player != null:
			player.call("perf_take")
		print("PERF_CONTEXT godot=%s renderer=%s driver=%s display=%s physics_target_hz=%d max_steps_per_frame=%d time_scale=%.3f" % [
			Engine.get_version_info().get("string", "unknown"),
			RenderingServer.get_current_rendering_method(),
			RenderingServer.get_current_rendering_driver_name(),
			DisplayServer.get_name(), Engine.physics_ticks_per_second,
			Engine.max_physics_steps_per_frame, Engine.time_scale])
		return
	_perf_frame_ms.append(float(now - _perf_previous_us) / 1000.0)
	_perf_previous_us = now
	var elapsed_us := now - _perf_start_us
	if elapsed_us < 2000000:
		return
	var physics_frames := Engine.get_physics_frames()
	var counters: Dictionary = player.call("perf_take") if player != null else {}
	var m := _perf_window_metrics(_perf_frame_ms, elapsed_us,
		physics_frames - _perf_start_physics, counters)
	var spd := Vector2(player.velocity.x, player.velocity.z).length() if player != null else 0.0
	print("PERF wall_s=%.3f frames=%d fps=%.1f frame_ms_mean=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f engine_proc_last_ms=%.2f engine_phys_last_ms=%.2f draws=%d vertex_indices=%d render_objs=%d velocity_xz=%.2f" % [
		m.wall_s, m.frames, m.fps, m.frame_ms_mean, m.frame_ms_p50,
		m.frame_ms_p95, m.frame_ms_p99, m.frame_ms_max,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)), spd])
	# active_objs is the engine physics monitor, not an actor/AI count.
	print("PHYS3D ticks=%d hz=%.2f ticks_per_frame=%.2f target_hz=%d active_objs=%d pairs=%d islands=%d" % [
		physics_frames - _perf_start_physics, m.physics_hz, m.physics_per_frame,
		Engine.physics_ticks_per_second,
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT))])
	print("PLAYERCOST ticks=%d total_ms_tick=%.3f move_ms_tick=%.3f water_ms_tick=%.3f glue_ms_tick=%.3f path_calls=%d distance_xz=%.3f achieved_mps=%.3f" % [
		m.player_ticks, m.player_ms_tick, m.move_ms_tick, m.water_ms_tick,
		m.glue_ms_tick, int(counters.get("path_calls", 0)),
		float(counters.get("distance_xz", 0.0)), m.achieved_mps])
	# Sole queries may also come from a diagnostic; use calls, not ticks.
	print("SOLECOST calls=%d ms_call=%.3f cache_samples=%d cache_bones=%d" % [
		int(counters.get("sole_calls", 0)), m.sole_ms_call,
		int(counters.get("sole_samples", 0)), int(counters.get("sole_bones", 0))])
	_perf_start_us = now
	_perf_start_physics = physics_frames
	_perf_frame_ms.clear()


## Separate arithmetic from sampling so units and low-FPS windows can be
## regression-tested without a renderer, imported assets, or real-time waits.
static func _perf_window_metrics(frame_ms: PackedFloat64Array, elapsed_us: int,
		physics_ticks: int, counters: Dictionary) -> Dictionary:
	var wall_s := maxf(float(elapsed_us) / 1000000.0, 0.000001)
	var frames := frame_ms.size()
	var ticks := int(counters.get("ticks", 0))
	var tick_divisor := float(maxi(ticks, 1)) * 1000.0
	var ordered := frame_ms.duplicate()
	ordered.sort()
	return {
		"wall_s": wall_s, "frames": frames, "fps": float(frames) / wall_s,
		"frame_ms_mean": wall_s * 1000.0 / float(maxi(frames, 1)) if frames > 0 else 0.0,
		"frame_ms_p50": _perf_percentile(ordered, 0.50),
		"frame_ms_p95": _perf_percentile(ordered, 0.95),
		"frame_ms_p99": _perf_percentile(ordered, 0.99),
		"frame_ms_max": ordered[-1] if not ordered.is_empty() else 0.0,
		"physics_hz": float(physics_ticks) / wall_s,
		"physics_per_frame": float(physics_ticks) / float(maxi(frames, 1)),
		"player_ticks": ticks,
		"player_ms_tick": float(counters.get("player_us", 0)) / tick_divisor,
		"move_ms_tick": float(counters.get("move_us", 0)) / tick_divisor,
		"water_ms_tick": float(counters.get("water_us", 0)) / tick_divisor,
		"glue_ms_tick": float(counters.get("glue_us", 0)) / tick_divisor,
		"sole_ms_call": float(counters.get("sole_us", 0)) / (float(maxi(int(counters.get("sole_calls", 0)), 1)) * 1000.0),
		"achieved_mps": float(counters.get("distance_xz", 0.0)) / wall_s,
	}


static func _perf_percentile(ordered: PackedFloat64Array, fraction: float) -> float:
	if ordered.is_empty():
		return 0.0
	# Nearest-rank percentile; at least one sample contributes, even below 1 Hz.
	return ordered[clampi(ceili(fraction * ordered.size()) - 1, 0, ordered.size() - 1)]


## Distant actors do not need to simulate.
##
## Every CharacterBody3D runs its own move_and_slide against the whole world
## each physics tick, so cost scales with total population regardless of
## whether any two of them ever touch.  Sleeping the ones far from the player
## makes that cost scale with what is near you instead.
const ACTOR_FULL_RADIUS := 45.0
var _throttle_clock := 0.0

func _throttle_actors(delta: float) -> void:
	if player == null:
		return
	_throttle_clock += delta
	if _throttle_clock < 0.5:
		return
	_throttle_clock = 0.0
	# Diagnostics deliberately disable actor physics regardless of distance.
	# Never resurrect those callbacks when an actor is near the player.
	var diagnostic_args := OS.get_cmdline_user_args()
	if diagnostic_args.has("--nopop") or diagnostic_args.has("--minphys"):
		return
	var root := get_tree().current_scene
	if root == null:
		return
	var pp := player.global_position
	var slept := 0
	for n in root.find_children("*", "CharacterBody3D", true, false):
		if n == player:
			continue
		var body := n as CharacterBody3D
		if body == null:
			continue
		var near := pp.distance_to(body.global_position) < ACTOR_FULL_RADIUS
		if body.is_physics_processing() != near:
			body.set_physics_process(near)
			if not near:
				slept += 1
	if slept > 0 and OS.get_environment("PERF_LOG") == "1":
		print("THROTTLE slept=%d" % slept)


## Graphics test switches, so the cost of each layer can be measured from the
## command line instead of guessed at.
##
##   --noshadow   disable every light's shadow
##   --norefl     SSR / SSAO / SSIL / SDFGI / glow off
##   --noocc      same as --norefl (ambient occlusion family)
##   --nofog      disable regular and volumetric fog
##   --unshaded   viewport unshaded debug draw (no lighting, no shaders)
##   --no-render-lods  disable automatic mesh LOD selection for an A/B test
var _cli_gfx_applied := false

func _apply_cli_graphics() -> void:
	var a := OS.get_cmdline_user_args()
	# Atmosphere owns the active sun and environment outside current_scene.
	# Searching only Game left its sun shadows on during --noshadow tests.
	var root := get_tree().root
	if root == null:
		return
	if a.has("--noshadow"):
		var n := 0
		for l in root.find_children("*", "Light3D", true, false):
			var lt := l as Light3D
			if lt != null:
				lt.shadow_enabled = false
				n += 1
		print("CLI_GFX shadow_off lights=%d" % n)
	if a.has("--norefl") or a.has("--noocc") or a.has("--nofog"):
		var no_reflections := a.has("--norefl") or a.has("--noocc")
		var e_count := 0
		for w in root.find_children("*", "WorldEnvironment", true, false):
			var we := w as WorldEnvironment
			if we == null or we.environment == null:
				continue
			var env := we.environment
			if no_reflections:
				env.ssr_enabled = false
				env.ssao_enabled = false
				env.ssil_enabled = false
				env.sdfgi_enabled = false
				env.glow_enabled = false
			if a.has("--nofog"):
				env.fog_enabled = false
				env.volumetric_fog_enabled = false
			we.environment = env
			e_count += 1
		if e_count == 0:
			# The map may set the environment straight on the World3D instead of
			# using a WorldEnvironment node.
			var w3 := get_viewport().world_3d
			if w3 != null and w3.environment != null:
				var env3 := w3.environment
				if no_reflections:
					env3.ssr_enabled = false
					env3.ssao_enabled = false
					env3.ssil_enabled = false
					env3.sdfgi_enabled = false
					env3.glow_enabled = false
				if a.has("--nofog"):
					env3.fog_enabled = false
					env3.volumetric_fog_enabled = false
				w3.environment = env3
				e_count = 1
		print("CLI_GFX environments=%d effects_off=%s fog_off=%s" % [
			e_count, str(no_reflections), str(a.has("--nofog"))])
	if a.has("--no-render-lods"):
		get_viewport().mesh_lod_threshold = 0.0
		print("CLI_GFX render_lods_off")
	if a.has("--unshaded"):
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_UNSHADED
		print("CLI_GFX unshaded")
	if a.has("--novsync"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		print("CLI_GFX vsync_off")


## --minphys: strip every physics body except the player and the ground/walkable
## surfaces, so the cost of "everything else" can be measured on its own.
var _minphys_done := false

func _apply_minphys() -> void:
	if not OS.get_cmdline_user_args().has("--minphys"):
		return
	var root := get_tree().current_scene
	if root == null:
		return
	var kept := 0
	var off := 0
	for n in root.find_children("*", "PhysicsBody3D", true, false):
		if n == player:
			continue
		var pb := n as PhysicsBody3D
		if pb == null:
			continue
		var nm := String(pb.name)
		var is_floor := pb is StaticBody3D and (nm.begins_with("GroundCollision")
				or nm.begins_with("Walkable"))
		if is_floor:
			kept += 1
			continue
		pb.collision_layer = 0
		pb.collision_mask = 0
		if pb is CharacterBody3D:
			(pb as CharacterBody3D).set_physics_process(false)
		off += 1
	print("MINPHYS kept_ground=%d disabled=%d" % [kept, off])


## --nopop: spawners skip generation and actor _ready guards handle late actors.
## This pass also disables any already-authored population, including child
## animation work and collision, without hiding unrelated monster-named props.
var _nopop_done := false

func _apply_nopop() -> void:
	if not OS.get_cmdline_user_args().has("--nopop"):
		return
	var root := get_tree().current_scene
	if root == null:
		return
	var hidden := 0
	for n in root.find_children("*", "CharacterBody3D", true, false):
		var body := n as CharacterBody3D
		if body == null or body == player:
			continue
		if not (body is PopulationActor or body is MonsterActor or body.is_in_group("population")):
			continue
		body.visible = false
		body.collision_layer = 0
		body.collision_mask = 0
		body.set_physics_process(false)
		body.process_mode = Node.PROCESS_MODE_DISABLED
		hidden += 1
	print("NOPOP hidden=%d" % hidden)
