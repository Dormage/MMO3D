extends SceneTree
## godot --headless --path . --script res://tests/test_deck_box_index.gd
## Optional real-asset fixture: -- --deck-fixture=/tmp/deck_fixture.json

const BoxIndex := preload("res://scripts/deck_box_index.gd")
const RegionMap := preload("res://scripts/region_map.gd")
var _failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	if not ok:
		push_error("FAIL: " + description)
		_failures += 1


func _linear_contains(boxes: Array, x: float, y: float, z: float) -> bool:
	for box in boxes:
		if x >= box[0] and x <= box[1] and z >= box[2] and z <= box[3] \
				and y >= box[4] and y <= box[5]:
			return true
	return false


func _linear_filter(boxes: Array, faces: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for k in range(0, faces.size() - 2, 3):
		var a := faces[k]
		var b := faces[k + 1]
		var c := faces[k + 2]
		if not _linear_contains(boxes, (a.x + b.x + c.x) / 3.0,
				(a.y + b.y + c.y) / 3.0, (a.z + b.z + c.z) / 3.0):
			out.append(a); out.append(b); out.append(c)
	return out


func _run() -> void:
	var boxes: Array = [
		[-8.0, -4.0, -8.0, -4.0, -1.0, 1.0],
		[-4.0, 0.0, -4.0, 0.0, -1.0, 1.0],
		[4.0, 8.0, 4.0, 8.0, 3.0, 4.0],
		[4.0, 8.0, 4.0, 8.0, 8.0, 9.0],
		[12.0, 12.0, -12.0, -12.0, 2.0, 2.0],
		[-1000000.0, 1000000.0, -1000000.0, 1000000.0, 20.0, 21.0],
		[1.0e12, 1.0e12 + 10.0, -1.0e12, -1.0e12 + 10.0, -3.0, -2.0],
		[-INF, INF, -INF, INF, 30.0, 31.0],
		[0.0, -1.0, 0.0, 1.0, 0.0, 1.0],
		[NAN, 1.0, 0.0, 1.0, 0.0, 1.0],
	]
	var index := BoxIndex.new()
	index.build(boxes)
	_check(index.fallback_count() == 3, "huge and infinite boxes use bounded fallback")
	_check(index.cell_count() < 100, "huge boxes cannot expand the grid")
	var probes := [
		[-8.0, -1.0, -8.0], [-4.0, 1.0, -4.0], [0.0, 1.0, 0.0],
		[0.000000000001, 0.0, 0.0], [-8.000000000001, 0.0, -8.0],
		[4.0, 3.0, 4.0], [8.0, 4.0, 8.0], [8.0, 6.0, 8.0], [8.0, 9.0, 8.0],
		[12.0, 2.0, -12.0], [12.0, 2.000000000001, -12.0],
		[1000000.0, 20.0, -1000000.0], [1.0e12 + 5.0, -2.5, -1.0e12 + 5.0],
		[INF, 30.0, -INF], [NAN, 0.0, 0.0], [0.0, NAN, 0.0],
	]
	for p in probes:
		_check(index.contains(p[0], p[1], p[2]) == _linear_contains(boxes, p[0], p[1], p[2]),
			"boundary/vertical/fallback probe %s matches the original test" % str(p))
	var rng := RandomNumberGenerator.new()
	rng.seed = 946123
	for i in 400:
		var x := rng.randf_range(-150.0, 150.0)
		var z := rng.randf_range(-150.0, 150.0)
		var y := rng.randf_range(-3.0, 9.0)
		boxes.append([x, x + rng.randf_range(0.1, 12.0), z, z + rng.randf_range(0.1, 12.0), y, y + 2.0])
	index.build(boxes)
	var faces := PackedVector3Array()
	for i in 3000:
		var p := Vector3(rng.randf_range(-170.0, 170.0), rng.randf_range(-4.0, 12.0), rng.randf_range(-170.0, 170.0))
		_check(index.contains(p.x, p.y, p.z) == _linear_contains(boxes, p.x, p.y, p.z),
			"random probe %d matches brute force" % i)
		faces.append(p + Vector3(0.3, 0.2, 0.0))
		faces.append(p + Vector3(-0.2, 0.0, 0.4))
		faces.append(p + Vector3(0.0, -0.1, -0.3))
	# Call the actual region integration, not a duplicate indexed filter.
	var region := RegionMap.new()
	region.set("_deck_boxes", boxes)
	region.get("_deck_box_index").build(boxes)
	var actual: PackedVector3Array = region.call("_strip_faces_on_decks", faces)
	_check(actual == _linear_filter(boxes, faces), "triangle filtering preserves exact vertices and order")
	region.free()
	index.build([])
	_check(not index.contains(-6.0, 0.0, -6.0) and index.cell_count() == 0 and index.fallback_count() == 0,
		"rebuild clears every previous box")
	_microbenchmark(rng)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--deck-fixture="):
			_real_fixture(argument.substr("--deck-fixture=".length()))
	print("DECK_BOX_INDEX_TEST failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _microbenchmark(rng: RandomNumberGenerator) -> void:
	var boxes: Array = []
	for i in 4200:
		var x := float(i % 70) * 4.5 - 157.5
		var z := float(i / 70) * 4.5 - 135.0
		boxes.append([x - 0.8, x + 0.8, z - 0.8, z + 0.8, -0.15, 1.6])
	var probes: Array = []
	for i in 6000:
		probes.append([rng.randf_range(-180.0, 180.0), rng.randf_range(-1.0, 3.0), rng.randf_range(-155.0, 155.0)])
	_benchmark("synthetic", boxes, probes)


func _real_fixture(path: String) -> void:
	var fixture: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(fixture is Dictionary, "real-asset fixture loads")
	if fixture is Dictionary:
		_benchmark("island_source", fixture.boxes, fixture.probes)


func _benchmark(label: String, boxes: Array, probes: Array) -> void:
	var index := BoxIndex.new()
	var begin := Time.get_ticks_usec()
	index.build(boxes)
	var build_us := Time.get_ticks_usec() - begin
	var expected := PackedByteArray()
	begin = Time.get_ticks_usec()
	for p in probes:
		expected.append(1 if _linear_contains(boxes, p[0], p[1], p[2]) else 0)
	var linear_us := Time.get_ticks_usec() - begin
	begin = Time.get_ticks_usec()
	var actual := PackedByteArray()
	for p in probes:
		actual.append(1 if index.contains(p[0], p[1], p[2]) else 0)
	var indexed_us := Time.get_ticks_usec() - begin
	_check(actual == expected, "%s benchmark has exactly matching query results" % label)
	print("DECK_BOX_BENCH fixture=%s boxes=%d probes=%d build_ms=%.3f linear_ms=%.3f indexed_ms=%.3f speedup=%.1f cells=%d fallback=%d" % [
		label, boxes.size(), probes.size(), build_us / 1000.0, linear_us / 1000.0,
		indexed_us / 1000.0, float(linear_us) / maxf(1.0, float(indexed_us)),
		index.cell_count(), index.fallback_count()])
