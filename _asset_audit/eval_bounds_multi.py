import bpy, sys, json
from mathutils import Vector
files=json.loads(sys.argv[sys.argv.index("--")+1])
for name,p in files:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=p)
    bpy.context.scene.frame_set(1)
    dg=bpy.context.evaluated_depsgraph_get(); dg.update()
    print("==",name)
    for ob in bpy.data.objects:
        if ob.type!="MESH": continue
        ev=ob.evaluated_get(dg); me=ev.to_mesh()
        if not me.vertices: ev.to_mesh_clear(); continue
        lo=Vector((1e9,)*3); hi=Vector((-1e9,)*3)
        for v in me.vertices:
            w=ev.matrix_world@v.co
            lo=Vector((min(lo[i],w[i]) for i in range(3))); hi=Vector((max(hi[i],w[i]) for i in range(3)))
        ev.to_mesh_clear()
        c=(lo+hi)/2
        print(f"@@   {ob.name:22s} v={len(ob.data.vertices):5d} dims={tuple(round(x,2) for x in (hi-lo))} c={tuple(round(x,1) for x in c)}")
