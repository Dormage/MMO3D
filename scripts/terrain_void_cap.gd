extends MeshInstance3D
class_name TerrainVoidCap
## Dark soil underlay for the terrain's open boundary slits.
##
## The terrain GLB has 1,746 single-face boundary edges grouped into 59 open
## chains (29 up-facing apertures, ~40 m^2 total).  Every up-facing aperture
## borders dirt or pond material (13 soil, 10 pond, 5 sand, 1 ash); none
## borders grass, so the dark marks on open grass in the 40 m ortho are
## shading, not void.  Welding the mesh made the holes worse, so the GLB is
## not touched.  Instead this node loads a coarse sheet baked by
## tools/terrain_void_underlay.py: a 1 m grid that follows the LOWEST nearby
## top-surface sample minus 0.5 m and is built inside the island footprint.
## It is hidden by intact terrain and visible only through an aperture, where
## it reads as dark soil instead of the black void.
##
##     var cap := TerrainVoidCap.new()
##     cap.name = "TerrainVoidCap"
##     map.add_child(cap)          # builds itself in _ready()
##
## TERRAIN_VOID_CAP=0 in the environment skips it, for before/after captures.

const BIN_PATH := "res://assets/terrain_void_underlay.bin"
const MAGIC := "TVU1"
## Soil tone.  StandardMaterial3D treats albedo_color as sRGB, so this reads
## as a dark brown after the grade; unshaded so a slit is never black.
const SOIL := Color(0.20, 0.125, 0.075, 1.0)
const SOIL_NAME := "TerrainVoidCapSoil"

func _ready() -> void:
	build()


func build() -> MeshInstance3D:
	if mesh != null:
		return self
	var f := FileAccess.open(BIN_PATH, FileAccess.READ)
	if f == null:
		push_error("TerrainVoidCap: missing " + BIN_PATH)
		return null
	if f.get_buffer(4).get_string_from_ascii() != MAGIC:
		push_error("TerrainVoidCap: bad magic in " + BIN_PATH)
		f.close()
		return null
	var nv := f.get_32()
	var nt := f.get_32()
	if nv <= 0 or nt <= 0:
		push_error("TerrainVoidCap: empty mesh")
		f.close()
		return null
	var verts := PackedVector3Array()
	verts.resize(nv)
	for i in nv:
		verts[i] = Vector3(f.get_float(), f.get_float(), f.get_float())
	var idx := PackedInt32Array()
	idx.resize(nt * 3)
	for i in nt * 3:
		idx[i] = f.get_32()
	f.close()

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var soil := SOIL
	if OS.get_environment("CAP_DEBUG") == "1":
		soil = Color(1.0, 0.0, 1.0, 1.0)
	var mat := StandardMaterial3D.new()
	mat.resource_name = SOIL_NAME
	mat.albedo_color = soil
	# Unshaded: with a lit material the slits in shadow read black again.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# The sheet is below the surface; both sides can be looked at through a
	# slit from a steep angle.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true

	self.mesh = am
	material_override = mat
	# It is filler, not geometry: no shadows, no GI, no reflection probe.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	print("terrain void cap: %d verts, %d tris, soil underlay" % [nv, nt])
	return self
