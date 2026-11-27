extends Node3D
## Gate state controller.  Reads the authored glTF extras on the Portcullis
## node (Godot stores them in Node metadata "extras"), moves the Portcullis
## between the authored closed/open local Y values, and enables a matching
## box collider in the arch.  Default OPEN so the playable route stays clear.
## Debug key: G toggles.

var _port: Node3D
var _body: StaticBody3D
var _shape: CollisionShape3D
var _closed_y := 0.0
var _open_y := 2.3
var _is_open := true


func _ready() -> void:
	var map := get_parent().get_node_or_null("Map")
	if map == null:
		push_error("gate_state: no Map")
		return
	var gate := map.find_child("Building_village_gate", true, false) as Node3D
	if gate == null:
		push_warning("gate_state: no gate in this world, controller idle")
		set_process(false)
		return
		return
	_port = gate.find_child("Portcullis", true, false) as Node3D
	if _port == null:
		push_error("gate_state: Portcullis missing")
		return
	# Read the authored extras.  Godot's glTF importer puts the JSON object in
	# the "extras" metadata key; no re-export or hard-coded offsets needed.
	var ex: Dictionary = {}
	if _port.has_meta("extras"):
		ex = _port.get_meta("extras")
	_closed_y = float(ex.get("local_y_closed", 0.0))
	_open_y = float(ex.get("local_y_open", 2.3))
	_build_collider(gate)
	# Deliberate override: the authored default is closed, but this playable
	# slice starts OPEN so the spawn-to-gate route is clear.
	set_open(true)
	print("GATE_EXTRAS ", JSON.stringify(ex))
	print("GATE_OFFSETS closed_y=%.3f open_y=%.3f" % [_closed_y, _open_y])


func _build_collider(gate: Node3D) -> void:
	_body = StaticBody3D.new()
	_body.name = "GateBarrier"
	_body.collision_layer = 1
	_shape = CollisionShape3D.new()
	var box := BoxShape3D.new()
	# 4 m clear opening; 2.5 m tall from the threshold; 0.6 m thick.
	box.size = Vector3(4.0, 2.5, 0.6)
	_shape.shape = box
	_body.add_child(_shape)
	add_child(_body)
	var gp := gate.global_position
	_body.global_position = Vector3(gp.x, gp.y + 1.25, gp.z)


func set_open(open: bool) -> void:
	_is_open = open
	if _port != null:
		_port.position.y = _open_y if open else _closed_y
	if _shape != null:
		_shape.disabled = open
	if _body != null:
		_body.collision_layer = 0 if open else 1
	print("GATE_STATE open=%s port_y=%.3f collision=%s" % [
		str(open), _port.position.y if _port != null else 0.0,
		"off" if open else "on"])


func is_open() -> bool:
	return _is_open


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_G:
		set_open(not _is_open)
