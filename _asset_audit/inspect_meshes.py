import bpy, sys, json
from mathutils import Vector
p=sys.argv[sys.argv.index("--")+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=p, use_anim=False)
bpy.context.view_layer.update()
for o in bpy.data.objects:
    if o.type!="MESH": continue
    lo=Vector((1e9,)*3); hi=Vector((-1e9,)*3)
    for c in o.bound_box:
        w=o.matrix_world@Vector(c)
        lo=Vector((min(lo[i],w[i]) for i in range(3))); hi=Vector((max(hi[i],w[i]) for i in range(3)))
    print(f"@@ {o.name:18s} verts={len(o.data.vertices):6d} parent={o.parent.name if o.parent else '-':12s} "
          f"loc={tuple(round(x,2) for x in o.location)} scale={tuple(round(x,3) for x in o.scale)} "
          f"world_dims={tuple(round(x,2) for x in (hi-lo))}")
