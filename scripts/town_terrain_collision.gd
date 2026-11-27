extends StaticBody3D
## Terrain collision for the authored town world.
##
## The procedural map attached terrain_collision.gd, which owns the
## walkable_height() contract that bridge_placement, building_collision and
## island_detail all call.  The town needs that same contract but has no
## heightfield cache to search -- a downward raycast against layer 1 gives the
## same answer directly.

const GROUND_MASK := 1


## Height of walkable ground at (x, z).  Returns NAN when nothing is hit, which
## is the "missing" sentinel the callers already test for.
func walkable_height(x: float, z: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(x, 400.0, z), Vector3(x, -400.0, z), GROUND_MASK)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return NAN
	return float(hit["position"].y)


## True when the point has ground under it (used by prop placement checks).
func has_ground(x: float, z: float) -> bool:
	return not is_nan(walkable_height(x, z))
