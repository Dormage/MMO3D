import bpy, sys, json
files=json.loads(sys.argv[sys.argv.index("--")+1]); out={}
for f in files:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=f, use_anim=False)
    arm=next((o for o in bpy.data.objects if o.type=="ARMATURE"),None)
    if not arm: out[f]={"error":"no arm"}; continue
    out[f]={"bones":[b.name for b in arm.data.bones],
            "parents":{b.name:(b.parent.name if b.parent else None) for b in arm.data.bones}}
print("@@JSON@@"+json.dumps(out))
