import bpy, sys, json
files=json.loads(sys.argv[sys.argv.index("--")+1]); out=[]
for name,f in files:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=f, use_anim=False)
    arm=next((o for o in bpy.data.objects if o.type=="ARMATURE"),None)
    if not arm: out.append({"name":name,"error":"no arm"}); continue
    bones={b.name:b for b in arm.data.bones}
    head=None
    for kw in ("head","skull","jaw","neck"):
        cands=[b for b in arm.data.bones if kw in b.name.lower()]
        if cands:
            # prefer the one furthest forward from origin
            head=max(cands,key=lambda b:(arm.matrix_world@b.head_local).length)
            break
    if head is None:
        out.append({"name":name,"error":"no head bone","bones":[b.name for b in arm.data.bones][:12]}); continue
    root=[b for b in arm.data.bones if b.parent is None][0]
    hp=arm.matrix_world@head.head_local
    rp=arm.matrix_world@root.head_local
    d=hp-rp
    out.append({"name":name,"head":head.name,"root":root.name,
                "dx":round(d.x,2),"dy":round(d.y,2),"dz":round(d.z,2)})
    print("@@",json.dumps(out[-1]),flush=True)
print("@@JSON@@"+json.dumps(out))
