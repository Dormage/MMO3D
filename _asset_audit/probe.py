import bpy, json, sys, os
from mathutils import Vector

path = sys.argv[sys.argv.index("--") + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=path, use_anim=True)
acts = [{"name": a.name, "frame_range": list(a.frame_range)} for a in bpy.data.actions]
arms = []
for ob in bpy.data.objects:
    if ob.type == "ARMATURE":
        arms.append({"name": ob.name, "bones": len(ob.data.bones),
                     "root": [b.name for b in ob.data.bones if b.parent is None][:5]})
meshes = []
for ob in bpy.data.objects:
    if ob.type == "MESH":
        ob.data.calc_loop_triangles()
        meshes.append({"name": ob.name, "tris": len(ob.data.loop_triangles),
                       "verts": len(ob.data.vertices), "vgroups": len(ob.vertex_groups),
                       "mods": [m.type for m in ob.modifiers], "mats": len(ob.data.materials),
                       "dims": [round(x, 3) for x in ob.dimensions]})
print("@@JSON@@" + json.dumps({"file": path, "actions": acts, "armatures": arms,
                               "meshes": meshes, "images": len(bpy.data.images),
                               "materials": [m.name for m in bpy.data.materials]}))
