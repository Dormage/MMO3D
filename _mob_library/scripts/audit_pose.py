"""Second pass: pose-space bounds (what the game actually shows) and foot offset."""
import bpy, json, os, sys
from mathutils import Vector

def jobs_args():
    argv=sys.argv; rest=argv[argv.index('--')+1:]
    return json.load(open(rest[0])), rest[1]

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
    if n==0: return None
    return {"min":[round(v,4) for v in lo],"max":[round(v,4) for v in hi],
            "size":[round(hi[i]-lo[i],4) for i in range(3)],
            "verts":n}

def audit(job):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=job["file"])
    bpy.context.scene.frame_set(0)
    bpy.context.view_layer.update()
    b=bounds()
    armatures=[o for o in bpy.data.objects if o.type=='ARMATURE']
    bones={}
    if armatures:
        arm=armatures[0]
        for name in ('Root','Hips','Head','Foot.L','Foot.R'):
            pb=arm.pose.bones.get(name)
            if pb: bones[name]=[round(v,4) for v in (arm.matrix_world@pb.head)]
    return {"key":job["key"],"file":job["file"],"bounds_pose":b,"bones_pose":bones,
            "armatures":[o.name for o in armatures]}

def main():
    jobs,out=jobs_args(); res=[]
    for i,job in enumerate(jobs):
        try: r=audit(job)
        except Exception as e: r={"key":job.get("key"),"error":repr(e)}
        res.append(r); print("@@P",i+1,len(jobs),r.get("key"),flush=True)
    json.dump(res,open(out,"w"),indent=1)
    print("@@DONE",len(res),flush=True)

main()
