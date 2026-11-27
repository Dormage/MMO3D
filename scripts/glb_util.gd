extends RefCounted
## GLB loading that works with and without Godot's import cache.
##
## In the editor a .glb gets an .import sidecar and load() returns a
## PackedScene.  Headless Godot never writes those sidecars, and a freshly
## created project has no .godot cache at all, so load() returns null and
## .instantiate() would crash.  Fall back to parsing the GLB directly.
##
## Usage:  preload("res://scripts/glb_util.gd").instantiate("res://x.glb")


static func instantiate(path: String) -> Node:
	var res := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
	if res is PackedScene:
		return (res as PackedScene).instantiate()
	# No importer output: read the container ourselves.
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_error("glb_util: cannot parse '%s' (%d)" % [path, err])
		return null
	var node := doc.generate_scene(state)
	if node == null:
		push_error("glb_util: generate_scene failed for '%s'" % path)
	return node


## Parse a GLB straight from disk, ignoring Godot's import cache.
##
## The navmesh file is edited in an external tool, and an .import sidecar would
## keep serving the previous geometry.  For files that must always match what is
## on disk, use this instead of instantiate().
static func instantiate_raw(path: String) -> Node:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_error("glb_util: cannot parse '%s' (%d)" % [path, err])
		return null
	var node := doc.generate_scene(state)
	if node == null:
		push_error("glb_util: generate_scene failed for '%s'" % path)
	return node
