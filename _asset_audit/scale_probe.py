import bpy, sys, json
from mathutils import Vector
files = json.loads(sys.argv[sys.argv.index("--")+1])
out=[]
for f in files:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=f, use_anim=False)
    ms=[o for o in bpy.data.objects if o.type=="MESH" and len(o.data.vertices)>20]
    if not ms:
        out.append({"file":f,"error":"no mesh"}); continue
    bpy.context.view_layer.update()
    lo=Vector((1e9,)*3); hi=Vector((-1e9,)*3)
    for o in ms:
        for c in o.bound_box:
            w=o.matrix_world@Vector(c)
            lo=Vector((min(lo[i],w[i]) for i in range(3)))
            hi=Vector((max(hi[i],w[i]) for i in range(3)))
    dims=hi-lo
    out.append({"file":f,"height_m":round(dims.z,3),"width_m":round(dims.x,3),
                "depth_m":round(dims.y,3),"feet_z":round(lo.z,3),
                "center_xy":[round((lo.x+hi.x)/2,3),round((lo.y+hi.y)/2,3)]})
    print("@@ "+json.dumps(out[-1]),flush=True)
print("@@JSON@@"+json.dumps(out))
