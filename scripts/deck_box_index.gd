extends RefCounted
## Spatial lookup for the existing bridge-deck exclusion boxes.
##
## Boxes retain their original [min_x, max_x, min_z, max_z, min_y, max_y]
## bounds. The grid only narrows candidates; the final inclusive containment
## test is unchanged. Unusually large/non-finite boxes use a bounded fallback
## list rather than allocating an unbounded number of grid cells.

const CELL_SIZE := 4.0
const MAX_CELLS_PER_BOX := 256
const MIN_CELL_COORD := -2147483648.0
const MAX_CELL_COORD := 2147483647.0

var _cells: Dictionary = {}
var _large_boxes: Array = []


func build(boxes: Array) -> void:
	_cells.clear()
	_large_boxes.clear()
	for box in boxes:
		# Such a box cannot contain any point under the original comparisons.
		if box[0] > box[1] or box[2] > box[3] or box[4] > box[5]:
			continue
		var invalid := false
		for bound in box:
			if is_nan(bound):
				invalid = true
				break
		if invalid:
			continue
		if not is_finite(box[0]) or not is_finite(box[1]) \
				or not is_finite(box[2]) or not is_finite(box[3]):
			_large_boxes.append(box)
			continue
		# Check floating-point coordinates before converting to Vector2i. This
		# also handles corrupt huge coordinates without integer overflow.
		var x0 := floorf(float(box[0]) / CELL_SIZE)
		var x1 := floorf(float(box[1]) / CELL_SIZE)
		var z0 := floorf(float(box[2]) / CELL_SIZE)
		var z1 := floorf(float(box[3]) / CELL_SIZE)
		if x0 < MIN_CELL_COORD or x1 > MAX_CELL_COORD \
				or z0 < MIN_CELL_COORD or z1 > MAX_CELL_COORD \
				or (x1 - x0 + 1.0) * (z1 - z0 + 1.0) > MAX_CELLS_PER_BOX:
			_large_boxes.append(box)
			continue
		# Include the maximum cell too: a point exactly on a deck's maximum
		# boundary must still match, including a boundary on a grid line.
		for z in range(int(z0), int(z1) + 1):
			for x in range(int(x0), int(x1) + 1):
				var cell := Vector2i(x, z)
				if not _cells.has(cell):
					_cells[cell] = []
				_cells[cell].append(box)


func contains(x: float, y: float, z: float) -> bool:
	# Keep the centroid components as floats. Constructing a Vector3 here
	# would round them to float32 and could change boundary containment.
	if is_nan(x) or is_nan(y) or is_nan(z):
		return false
	if is_finite(x) and is_finite(z):
		var gx := floorf(x / CELL_SIZE)
		var gz := floorf(z / CELL_SIZE)
		if gx >= MIN_CELL_COORD and gx <= MAX_CELL_COORD \
				and gz >= MIN_CELL_COORD and gz <= MAX_CELL_COORD:
			var cell := Vector2i(int(gx), int(gz))
			if _cells.has(cell):
				for box in _cells[cell]:
					if x >= box[0] and x <= box[1] and z >= box[2] and z <= box[3] \
							and y >= box[4] and y <= box[5]:
						return true
	for box in _large_boxes:
		if x >= box[0] and x <= box[1] and z >= box[2] and z <= box[3] \
				and y >= box[4] and y <= box[5]:
			return true
	return false


func cell_count() -> int:
	return _cells.size()


func fallback_count() -> int:
	return _large_boxes.size()
