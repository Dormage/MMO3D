"""Bounds at the middle of the Walk clip (the pose the game will show)."""
import bpy, json, os, sys
from mathutils import Vector

def args():
    argv=sys.argv; rest=argv[argv.index('--')+1:]
    return json.load(open(rest[0])), rest[1]

def clean(name):
    return name.split('|')[-1]

def bounds():
    dg=bpy.context.evaluated_depsgraph_get(); dg.update()
    lo=Vector((1e18,)*3); hi=Vector((-1e18,)*3); n=0
    for inst in dg.object_instances:
        ob=inst.object
        if ob.type!='MESH': continue
        ev=ob.evaluated_get(dg); me=ev.to_mesh()
        for v in me.vertices:
            w=ev.matrix_world@v.co
            for i in range(3):
                lo[i]=min(lo[i],w[i]); hi[i]=max(hi[i],w[i])
            n+=1
        ev.to_mesh_clear()
    return None if n==0 else {"min":[round(v,4) for v in lo],"max":[round(v,4) for v in hi],
        "size":[round(hi[i]-lo[i],4) for i in range(3)],"verts":n}

def audit(job):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=job["file"])
    sc=bpy.context.scene
    arm=next((o for o in bpy.data.objects if o.type=='ARMATURE'),None)
    chosen=None; frame=0.0
    if arm and arm.animation_data:
        ad=arm.animation_data
        lc={a.name.lower():a for a in bpy.data.actions}
        for want in ('walk','idle','run'):
            for a in bpy.data.actions:
                if clean(a.name).lower()==want:
                    chosen=a; break
            if chosen: break
        if chosen is None and bpy.data.actions:
            chosen=bpy.data.actions[0]
        if chosen:
            ad.action=chosen
            if chosen.slots:
                ad.action_slot=chosen.slots[0]
            lo,hi=chosen.frame_range
            frame=lo+(hi-lo)*0.5
            sc.frame_set(int(round(frame)))
    bpy.context.view_layer.update()
    b=bounds()
    bones={}
    if arm:
        for name in ('Root','Hips','Head','Foot.L','Foot.R'):
            pb=arm.pose.bones.get(name)
            if pb: bones[name]=[round(v,4) for v in (arm.matrix_world@pb.head)]
    return {"key":job["key"],"action":chosen.name if chosen else None,"frame":frame,
            "bounds_walk":b,"bones_walk":bones}

def main():
    jobs,out=args(); res=[]
    for i,job in enumerate(jobs):
        try: r=audit(job)
        except Exception as e: r={"key":job.get("key"),"error":repr(e)}
        res.append(r); print("@@W",i+1,len(jobs),r.get("key"),flush=True)
    json.dump(res,open(out,"w"),indent=1)
    print("@@DONE",len(res),flush=True)
main()
