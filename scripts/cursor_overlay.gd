extends Control
## Always-visible high-contrast pointer drawn in the game viewport.  The OS
## cursor is hidden while this is shown so there is never a second, invisible
## pointer and screenshots contain the real pointer pixels.

var _pos := Vector2(800, 450)
var _have_mouse := false
var _debug_lock := false
var _state := 0
const STATE_NORMAL := 0
const STATE_BLOCKED := 1
const STATE_INTERACTIVE := 2

func debug_set_position(p: Vector2) -> void:
	_pos = p
	_state = 0
	_debug_lock = true
	queue_redraw()

func set_state(s: int) -> void:
	if s != _state:
		_state = s
		queue_redraw()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_pos = (event as InputEventMouseMotion).position
		_have_mouse = true
		queue_redraw()

func _process(_delta: float) -> void:
	if _debug_lock:
		queue_redraw()
		return
	var vp := get_viewport().get_mouse_position()
	var sz := get_viewport_rect().size
	if vp.x >= 0.0 and vp.y >= 0.0 and vp.x <= sz.x and vp.y <= sz.y:
		_pos = vp
		_have_mouse = true
	queue_redraw()

func _draw() -> void:
	var black := Color(0.012, 0.010, 0.014)
	var pts := PackedVector2Array([
		Vector2(0, 0), Vector2(0, 24), Vector2(5, 18), Vector2(9, 27),
		Vector2(14, 24), Vector2(10, 15), Vector2(18, 15)
	])
	var world := PackedVector2Array()
	for p in pts:
		world.append(_pos + p)
	# Every state gets the 3.5 px black keyline first, so it stays readable on
	# sunlit grass and on the near-black void.
	if _state == STATE_BLOCKED:
		var red := Color(0.86, 0.22, 0.18)
		var grey := Color(0.62, 0.60, 0.58)
		draw_polyline(world + PackedVector2Array([world[0]]), black, 4.2, true)
		draw_colored_polygon(world, grey)
		draw_polyline(world + PackedVector2Array([world[0]]), red, 2.0, true)
		# Crossed-out ring to the lower-right of the arrow.
		var c := _pos + Vector2(25, 26)
		draw_circle(c, 10.0, Color(0.035, 0.02, 0.02, 0.92))
		draw_arc(c, 9.0, 0.0, TAU, 28, red, 2.6, true)
		draw_line(c + Vector2(-6, -6), c + Vector2(6, 6), red, 2.8, true)
		draw_line(c + Vector2(6, -6), c + Vector2(-6, 6), red, 2.8, true)
	elif _state == STATE_INTERACTIVE:
		var cyan := Color(0.22, 1.0, 0.90)
		draw_polyline(world + PackedVector2Array([world[0]]), black, 4.2, true)
		draw_colored_polygon(world, cyan.darkened(0.45))
		draw_polyline(world + PackedVector2Array([world[0]]), cyan, 2.0, true)
		var c := _pos + Vector2(27, 22)
		draw_circle(c, 11.0, Color(0.01, 0.05, 0.06, 0.90))
		draw_arc(c, 9.5, 0.0, TAU, 28, black, 4.0, true)
		draw_arc(c, 9.5, 0.0, TAU, 28, cyan, 2.2, true)
		draw_circle(c, 3.4, cyan)
	else:
		var gold := Color(1.0, 0.78, 0.22)
		draw_polyline(world + PackedVector2Array([world[0]]), black, 3.8, true)
		draw_colored_polygon(world, gold)
		draw_polyline(world + PackedVector2Array([world[0]]), Color(1, 0.96, 0.70), 1.2, true)
	draw_circle(_pos + Vector2(1, 1), 1.6, black)
