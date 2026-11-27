extends Node3D
## Free-fly inspection camera.
##   Mouse  - look (click to capture, Esc to release)
##   WASD   - move horizontally
##   Space / Ctrl - up / down
##   Shift  - move fast
##   Wheel  - change speed

@export var speed: float = 8.0
@export var look_sensitivity: float = 0.0025
@export var pitch_limit: float = 1.45

var camera: Camera3D
var _pitch: float = 0.0


func _ready() -> void:
	camera = get_node_or_null("Camera3D")
	if camera == null:
		camera = Camera3D.new()
		camera.name = "Camera3D"
		add_child(camera)
	# start looking slightly down at the dragon
	_pitch = -0.22
	camera.rotation.x = _pitch
	# The shipped game owns the pointer through CursorOverlay.  Capturing here
	# on Wayland threw "Parameter pointed_win is null" at boot and on every
	# click, and stole the OS pointer from the RPG camera.  Free-fly remains
	# usable via WASD; pointer capture is opt-in only by the editor.
	process_mode = Node.PROCESS_MODE_DISABLED if get_tree().get_first_node_in_group("player") != null else Node.PROCESS_MODE_INHERIT


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# yaw on this node (keeps horizon level), pitch on the camera child
		rotate_y(-event.relative.x * look_sensitivity)
		_pitch = clamp(_pitch - event.relative.y * look_sensitivity, -pitch_limit, pitch_limit)
		camera.rotation.x = _pitch

	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = min(speed * 1.25, 120.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = max(speed / 1.25, 0.5)

	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		pass


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	var basis := global_transform.basis

	if Input.is_key_pressed(KEY_W):
		dir -= basis.z
	if Input.is_key_pressed(KEY_S):
		dir += basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= basis.x
	if Input.is_key_pressed(KEY_D):
		dir += basis.x
	if Input.is_key_pressed(KEY_SPACE):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):
		dir -= Vector3.UP

	if dir.length_squared() > 0.0:
		var boost := 4.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		global_position += dir.normalized() * speed * boost * delta
