## Headless bridge walk test.
##
## There is no display on the build machine, so bridges cannot be checked by
## looking at them.  Instead this walks a real CharacterBody3D along a real
## NavigationServer path, across every bridge on the map, and reports how far it
## actually got.  A bridge that is unreachable shows up as a missing path; a
## bridge with a collider in the doorway shows up as a path that exists but a
## capsule that stops moving.
extends Node

var player: CharacterBody3D
var nav: Node
var map: Node

const MAX_FRAMES := 900    # 15 s of walking at 60 Hz
const STALL_MOVE := 0.25   # metres of progress required per sample window
const SAMPLE := 30         # frames per stall sample
const APPROACH := 6.0      # how far beyond a deck end to look for land


func _ready() -> void:
	_run()


func _run() -> void:
	# The navigation map only answers queries after the server has synced the
	# freshly baked region, which happens later than the first physics_frame.
	# Poll a known-good point until the map is live instead of guessing a count.
	var tries := 0
	while tries < 240:
		await get_tree().physics_frame
		tries += 1
		var probe: Vector3 = nav.call("closest", player.global_position)
		if probe != Vector3.ZERO and probe.distance_to(player.global_position) < 3.0:
			break
	print("PROBE ready after %d frames" % tries)
	# Experiment: slope handling can zero horizontal motion on a ramped deck.
	if OS.get_environment("NAVTEST_SLOPE") == "0":
		player.floor_stop_on_slope = false
		print("PROBE slope_stop=off")
	if OS.get_environment("NAVTEST_CONST") == "0":
		player.floor_constant_speed = false
		print("PROBE constant_speed=off")
	var bridges := _bridges()
	if bridges.is_empty():
		print("PROBE no bridges on this map")
		print("PROBE_DONE")
		get_tree().quit()
		return
	print("PROBE bridges=%d" % bridges.size())
	if OS.get_cmdline_user_args().has("--waterspan"):
		for i in 4:
			var z := 4.0 + i * 0.5
			var line := ""
			while z < 26.0:
				line += ("W" if bool(nav.call("_over_water", -36.5, z)) else ".")
				z += 0.5
			print("WSPAN x=-36.5 from z=4 step0.5: %s" % line)
			break
		print("PROBE_DONE")
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--waterprobe"):
		for i in bridges.size():
			var deck: Array = bridges[i][1]
			var mn := Vector3(INF, INF, INF)
			var mx := Vector3(-INF, -INF, -INF)
			for t in deck:
				for v in t:
					mn = Vector3(minf(mn.x, v.x), minf(mn.y, v.y), minf(mn.z, v.z))
					mx = Vector3(maxf(mx.x, v.x), maxf(mx.y, v.y), maxf(mx.z, v.z))
			var cx := (mn.x + mx.x) * 0.5
			var w_lo := bool(nav.call("_over_water", cx, mn.z))
			var w_hi := bool(nav.call("_over_water", cx, mx.z))
			if w_lo or w_hi:
				print("WPROBE #%d x=%.1f z=%.1f..%.1f Y=%.1f wet_zmin=%s wet_zmax=%s" % [
					i, cx, mn.z, mx.z, mn.y, str(w_lo), str(w_hi)])
		print("PROBE_DONE")
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--bridgelist"):
		for i in bridges.size():
			var deck: Array = bridges[i][1]
			var c := Vector3.ZERO
			var n := 0
			var mn := Vector3(INF, INF, INF)
			var mx := Vector3(-INF, -INF, -INF)
			for t in deck:
				for v in t:
					c += v
					n += 1
					mn = Vector3(minf(mn.x, v.x), minf(mn.y, v.y), minf(mn.z, v.z))
					mx = Vector3(maxf(mx.x, v.x), maxf(mx.y, v.y), maxf(mx.z, v.z))
			c /= float(maxi(n, 1))
			print("BLIST #%d centre=(%.1f,%.1f,%.1f) min=(%.1f,%.1f) max=(%.1f,%.1f) water_c=%s water_min=%s water_max=%s" % [
				i, c.x, c.y, c.z, mn.x, mn.z, mx.x, mx.z,
				str(nav.call("is_water", c)),
				str(nav.call("is_water", Vector3(c.x, c.y, mn.z))),
				str(nav.call("is_water", Vector3(c.x, c.y, mx.z)))])
		print("PROBE_DONE")
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--bridgeaudit"):
		for entry in bridges:
			_audit(entry[0], entry[1])
		print("PROBE_DONE")
		get_tree().quit()
		return
	for entry in bridges:
		await _test(entry[0], entry[1])
	print("PROBE_DONE")
	get_tree().quit()


## Collect individual bridges as [name, deck triangles].
##
## A map usually ships every bridge in one mesh, so its bounding box spans the
## whole map.  Triangles are split into connected islands first, and only deck
## faces (facing up) are kept, because ramps and railings would otherwise decide
## which way the bridge runs.
func _bridges() -> Array:
	var out: Array = []
	for node in map.find_children("Walkable_*", "StaticBody3D", true, false):
		var sb := node as StaticBody3D
		if sb == null:
			continue
		# Only real bridges.  Ramparts, buildings and pavilions are walkable too,
		# but walking a ring wall end to end is not a bridge test and reported
		# failures that had nothing to do with bridges.
		if not String(sb.name).to_lower().contains("bridge"):
			continue
		var tris: Array = []
		for cs in sb.get_children():
			if not (cs is CollisionShape3D):
				continue
			var shape := (cs as CollisionShape3D).shape
			if not (shape is ConcavePolygonShape3D):
				continue
			var xf: Transform3D = (cs as CollisionShape3D).global_transform
			var wf: PackedVector3Array = (shape as ConcavePolygonShape3D).get_faces()
			for k in range(0, wf.size() - 2, 3):
				tris.append([xf * wf[k], xf * wf[k + 1], xf * wf[k + 2]])
		var n := 0
		for deck in _islands(tris):
			n += 1
			out.append(["%s#%d" % [String(sb.name), n], deck])
	out.sort_custom(func(a, b): return _span(a[1]) > _span(b[1]))
	return out


func _span(deck: Array) -> float:
	var axis := _axis(deck)
	var lo := INF
	var hi := -INF
	for t in deck:
		for v in t:
			var d: float = (v as Vector3).dot(axis)
			lo = minf(lo, d)
			hi = maxf(hi, d)
	return 0.0 if lo > hi else hi - lo


## Principal horizontal direction of the deck, from a 2x2 covariance.
func _axis(deck: Array) -> Vector3:
	var c := Vector2.ZERO
	var n := 0
	for t in deck:
		for v in t:
			c += Vector2(v.x, v.z)
			n += 1
	if n == 0:
		return Vector3(0, 0, 1)
	c /= float(n)
	var cxx := 0.0
	var czz := 0.0
	var cxz := 0.0
	for t in deck:
		for v in t:
			var d := Vector2(v.x, v.z) - c
			cxx += d.x * d.x
			czz += d.y * d.y
			cxz += d.x * d.y
	var ang := 0.5 * atan2(2.0 * cxz, cxx - czz)
	return Vector3(cos(ang), 0.0, sin(ang))


## Connected-component split of a triangle soup, merged on shared vertices.
##
## Vertices are snapped to a coarse cell so a seam of a few millimetres still
## counts as connected; without that every bridge would fall into hundreds of
## single-triangle islands.
func _islands(tris: Array) -> Array:
	var parent := {}
	for i in tris.size():
		parent[i] = i
	var cell := {}
	var find := func(a: int) -> int:
		var r := a
		while parent[r] != r:
			r = parent[r]
		while parent[a] != r:
			var nx: int = parent[a]
			parent[a] = r
			a = nx
		return r
	for i in tris.size():
		for v in tris[i]:
			var key := "%d,%d,%d" % [int(round(v.x * 4.0)), int(round(v.y * 4.0)), int(round(v.z * 4.0))]
			if cell.has(key):
				var other: int = cell[key]
				var ra: int = find.call(i)
				var rb: int = find.call(other)
				if ra != rb:
					parent[ra] = rb
			else:
				cell[key] = i
	var groups := {}
	for i in tris.size():
		var r: int = find.call(i)
		if not groups.has(r):
			groups[r] = []
		groups[r].append(tris[i])
	var out: Array = []
	for r in groups:
		var deck: Array = []
		for t in groups[r]:
			var a: Vector3 = t[0]
			var b: Vector3 = t[1]
			var c: Vector3 = t[2]
			var nrm := (b - a).cross(c - a)
			if nrm.length_squared() < 1.0e-10:
				continue
			if absf(nrm.normalized().y) > 0.7:
				deck.append(t)
		if deck.is_empty():
			continue
		var span := _span(deck)
		if span < 4.0:
			continue
		out.append(deck)
	return out


## Walk outward from a deck end until the navmesh is reached.
##
## The obvious approach of using the bounding box fails: a bridge's box includes
## its arch, so the endpoints land in mid-air or over water, where there is no
## navmesh at all.  Searching along the deck axis finds real ground instead.
func _land(point: Vector3, axis: Vector3, sign: float) -> Vector3:
	var best := point
	var best_d := INF
	var d := 0.0
	while d <= APPROACH:
		var probe := point + axis * (sign * d)
		var snapped: Vector3 = nav.call("closest", probe)
		var flat := Vector2(snapped.x - probe.x, snapped.z - probe.z).length()
		if flat < 1.0 and flat < best_d:
			best_d = flat
			best = snapped
			if flat < 0.35:
				break
		d += 0.5
	if best_d == INF:
		return nav.call("closest", point)
	return best


func _test(name: String, deck: Array) -> void:
	var axis := _axis(deck)
	var lo := INF
	var hi := -INF
	var lo_p := Vector3.ZERO
	var hi_p := Vector3.ZERO
	for t in deck:
		for v in t:
			var d: float = (v as Vector3).dot(axis)
			if d < lo:
				lo = d
				lo_p = v
			if d > hi:
				hi = d
				hi_p = v
	var span := hi - lo
	var pp: Vector3 = player.global_position
	print("PROBE_DBG %s player=%s closest_player=%s closest_lo=%s type=%s" % [
		name, str(pp), str(nav.call("closest", pp)),
		str(nav.call("closest", lo_p)), typeof(lo_p)])
	var start := _land(lo_p, axis, -1.0)
	var goal := _land(hi_p, axis, 1.0)
	var path: PackedVector3Array = nav.call("path", start, goal)
	var len := 0.0
	for i in range(1, path.size()):
		len += path[i - 1].distance_to(path[i])
	print("PROBE_BRIDGE %-22s span=%.1f path_pts=%d len=%.1f start=(%.1f,%.1f,%.1f) goal=(%.1f,%.1f,%.1f)" % [
		name, span, path.size(), len, start.x, start.y, start.z, goal.x, goal.y, goal.z])
	if path.size() < 2:
		print("PROBE_BRIDGE %-22s RESULT no_path (navmesh does not cross)" % name)
		return
	player.global_position = start + Vector3(0, 0.3, 0)
	player.velocity = Vector3.ZERO
	player.call("cancel_path")
	await get_tree().physics_frame
	if not player.call("move_along", path):
		print("PROBE_BRIDGE %-22s RESULT move_along_refused" % name)
		return
	var last := player.global_position
	var frames := 0
	var stalled_windows := 0
	var best := 99999.0
	while frames < MAX_FRAMES:
		await get_tree().physics_frame
		frames += 1
		var pos := player.global_position
		var to_goal := Vector2(pos.x - goal.x, pos.z - goal.z).length()
		best = minf(best, to_goal)
		if to_goal <= 1.2:
			break
		if frames % SAMPLE == 0:
			var moved := Vector2(pos.x - last.x, pos.z - last.z).length()
			last = pos
			if moved < STALL_MOVE:
				stalled_windows += 1
				if stalled_windows >= 2:
					_blocker(pos, goal)
					break
			else:
				stalled_windows = 0
	var endp := player.global_position
	var remain := Vector2(endp.x - goal.x, endp.z - goal.z).length()
	var ok := remain <= 1.5
	print("PROBE_BRIDGE %-22s RESULT %s frames=%d remain=%.2f best=%.2f pos=(%.1f,%.1f,%.1f)" % [
		name, "PASS" if ok else "STUCK", frames, remain, best, endp.x, endp.y, endp.z])
	player.call("cancel_path")


## Name whatever is standing in the way at a stall point.
##
## "Stuck on a bridge" is not actionable; knowing the collider's name and layer
## is, because it says whether the navmesh is routing through something solid or
## the capsule is catching on a step.
func _blocker(pos: Vector3, goal: Vector3) -> void:
	var space := player.get_world_3d().direct_space_state
	var dir := goal - pos
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	for height in [0.35, 0.9]:
		var from := pos + Vector3(0, height, 0)
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * 1.4)
		q.collision_mask = 3
		q.exclude = [player.get_rid()]
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			print("PROBE_HIT h=%.2f forward=clear" % height)
		else:
			var col: Object = hit.get("collider")
			print("PROBE_HIT h=%.2f forward=%s layer=%d dist=%.2f" % [
				height, String(col.name) if col != null else "<null>",
				int(hit.get("collider").collision_layer) if col != null and col is CollisionObject3D else -1,
				from.distance_to(hit["position"])])
	# Downward probe: a missing floor reads very differently from a wall.
	var dq := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 1.0, 0), pos + Vector3(0, -1.5, 0))
	dq.collision_mask = 3
	dq.exclude = [player.get_rid()]
	var dh: Dictionary = space.intersect_ray(dq)
	if dh.is_empty():
		print("PROBE_HIT floor=missing")
	else:
		var fc: Object = dh.get("collider")
		print("PROBE_HIT floor=%s layer=%d dy=%.2f" % [
			String(fc.name) if fc != null else "<null>",
			int((fc as CollisionObject3D).collision_layer) if fc is CollisionObject3D else -1,
			float(dh["position"].y) - pos.y])
	print("PROBE_HIT move=%s" % str(player.call("movement_debug")))
	# The capsule is wider than a centre ray, so an obstacle can clip its side
	# and never appear in a forward cast.  Slide collisions report what actually
	# stopped move_and_slide.
	for i in player.get_slide_collision_count():
		var sc := player.get_slide_collision(i)
		if sc == null:
			continue
		var col: Object = sc.get_collider()
		print("PROBE_SLIDE %d collider=%s layer=%d normal=%s point=%s" % [
			i, String(col.name) if col != null else "<null>",
			int((col as CollisionObject3D).collision_layer) if col is CollisionObject3D else -1,
			str(sc.get_normal()), str(sc.get_position())])
	var npath = player.get("_nav_path")
	var np: PackedVector3Array = npath if npath != null else PackedVector3Array()
	print("PROBE_STATE freeze=%s wait=%s settle=%s attacking=%s scripted=%s moving=%s" % [
		str(player.get("inspection_freeze")), str(player.get("_nav_wait")),
		str(player.get("_settle_timer")), str(player.get("_attacking")),
		str(player.get("_scripted")), str(player.get("_nav_active"))])
	print("PROBE_HIT nav_active=%s idx=%s/%d vel=%s target=%s" % [
		str(player.get("_nav_active")), str(player.get("_nav_index")), np.size(),
		str(player.velocity), str(player.get("_nav_target"))])
	if np.size() > 0:
		var li: int = int(player.get("_nav_index"))
		var nxt: Vector3 = np[mini(li, np.size() - 1)]
		print("PROBE_HIT next_pt=%s dist=%.2f last_pt=%s dist_last=%.2f" % [
			str(nxt), Vector2(nxt.x - pos.x, nxt.z - pos.z).length(),
			str(np[np.size() - 1]), Vector2(np[np.size() - 1].x - pos.x, np[np.size() - 1].z - pos.z).length()])


## Report, without walking anything, whether a path from the bank before a deck
## to the bank after it stays on the deck.
##
## The walking test answers "can the player get across"; this answers the
## different question "does pathing even try to cross", and how far the deck ends
## sit from the nearest navmesh, which is what a missing deck-to-bank join looks
## like.
func _audit(name: String, deck: Array) -> void:
	var axis := _axis(deck)
	var lo := INF
	var hi := -INF
	var lo_p := Vector3.ZERO
	var hi_p := Vector3.ZERO
	for t in deck:
		for v in t:
			var d: float = (v as Vector3).dot(axis)
			if d < lo:
				lo = d
				lo_p = v
			if d > hi:
				hi = d
				hi_p = v
	var start := _land(lo_p, axis, -1.0)
	var goal := _land(hi_p, axis, 1.0)
	var path: PackedVector3Array = nav.call("path", start, goal)
	var len := 0.0
	var wet := 0
	for i in path.size():
		if i > 0:
			len += path[i - 1].distance_to(path[i])
		if bool(nav.call("is_water", path[i])):
			wet += 1
	var gap_lo: float = (nav.call("closest", lo_p) as Vector3).distance_to(lo_p)
	var gap_hi: float = (nav.call("closest", hi_p) as Vector3).distance_to(hi_p)
	print("AUDIT %-22s span=%.1f pts=%d len=%.1f detour=%.1f wet=%d gap_lo=%.2f gap_hi=%.2f" % [
		name, hi - lo, path.size(), len, len / maxf(hi - lo, 0.1), wet, gap_lo, gap_hi])
	# Why is there a hole between the deck and the navmesh?  Walk the gap and
	# report what a downward ray finds, so the cause is named rather than guessed.
	if gap_lo > 1.0 or gap_hi > 1.0:
		var near_lo: Vector3 = nav.call("closest", lo_p)
		var near_hi: Vector3 = nav.call("closest", hi_p)
		for pair in [[lo_p, near_lo], [hi_p, near_hi]]:
			var from_p: Vector3 = pair[0]
			var to_p: Vector3 = pair[1]
			if from_p.distance_to(to_p) <= 1.0:
				continue
			for k in 5:
				var t := float(k) / 4.0
				var xz := from_p.lerp(to_p, t)
				var q := PhysicsRayQueryParameters3D.create(
					Vector3(xz.x, xz.y + 6.0, xz.z), Vector3(xz.x, xz.y - 6.0, xz.z), 3)
				var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
				if hit.is_empty():
					print("RAY   %-18s t=%.2f NO_HIT at (%.1f,%.1f)" % [name, t, xz.x, xz.z])
					continue
				var col = hit.get("collider")
				var nm := String((col as Node).name) if col is Node else "?"
				var lay := (col as CollisionObject3D).collision_layer if col is CollisionObject3D else 0
				var hp: Vector3 = hit["position"]
				var nrm: Vector3 = hit.get("normal", Vector3.UP)
				print("RAY   %-18s t=%.2f y=%.2f ny=%.2f layer=%d %s" % [
					name, t, hp.y, nrm.y, lay, nm])
