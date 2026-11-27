import bpy, sys, json
jobs=json.loads(sys.argv[sys.argv.index("--")+1])
out=[]
for j in jobs:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps=30
    bpy.ops.import_scene.fbx(filepath=j["file"], use_anim=True)
    arm=next(o for o in bpy.data.objects if o.type=="ARMATURE")
    acts=[a for a in bpy.data.actions if any("pose.bones" in fc.data_path for fc in
          (fc for l in a.layers for s in l.strips for cb in s.channelbags for fc in cb.fcurves))]
    act=max(acts,key=lambda a:a.frame_range[1]-a.frame_range[0])
    ad=arm.animation_data_create(); ad.action=act
    try:
        if act.slots: ad.action_slot=act.slots[0]
    except Exception: pass
    # pick a foot-ish bone with the most vertical travel
    best=None
    for b in arm.pose.bones:
        if any(k in b.name.lower() for k in ("foot","toe","ankle","hoof","leg")):
            zs=[]
            for f in range(int(act.frame_range[0]), int(act.frame_range[1])+1, 2):
                bpy.context.scene.frame_set(f)
                zs.append((arm.matrix_world@b.head).z)
            if len(zs)>4:
                amp=max(zs)-min(zs)
                if best is None or amp>best[1]: best=(b.name,amp,zs)
    if not best:
        out.append({"name":j["name"],"error":"no foot"}); continue
    name,amp,zs=best
    mean=sum(zs)/len(zs)
    crossings=0; prev=zs[0]-mean
    for z in zs[1:]:
        cur=z-mean
        if prev<0<=cur: crossings+=1
        prev=cur
    frames=int(act.frame_range[1]-act.frame_range[0])
    out.append({"name":j["name"],"bone":name,"amp":round(amp,3),"cycles":crossings,
                "seconds":round(frames/30,2),"cycle_s":round((frames/30)/crossings,2) if crossings else None})
    print("@@",json.dumps(out[-1]),flush=True)
print("@@JSON@@"+json.dumps(out))
