Backup taken before converting the remaining maps to heightfield navmeshes.

REVERTING A SINGLE MAP
  Edit scenes/region_<map>.tscn and delete the line:
      nav_glb_path = "res://assets/worlds/<map>/nav_<map>.glb"
  The map then falls back to the original recast contour bake. Nothing else
  changes, because the heightfield path is opt-in per map.

REVERTING EVERYTHING
  Copy scripts/*.gd and scenes/region_*.tscn from this folder back over the
  project, then delete assets/worlds/*/nav_*.glb.

WHAT CHANGED IN THIS WORK
  nav_world.gd      heightfield exporter (dump_heightnav), island stitching
                    (NavigationLink3D), waterline filter for walkable bodies
  region_map.gd     nav_glb_path + _load_nav_markers()
  glb_util.gd       instantiate_raw() so the nav file on disk always wins
  game_controller.gd  --navpatch / --navheight / --pathtest hooks
