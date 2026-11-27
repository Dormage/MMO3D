import bpy, sys
p=sys.argv[sys.argv.index("--")+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=p)
arm=next(o for o in bpy.data.objects if o.type=="ARMATURE")
act=next((a for a in bpy.data.actions if a.name.split("|")[-1]=="walk"), None)
arm.animation_data_create(); arm.animation_data.action=act
try:
    if len(act.slots): arm.animation_data.action_slot=act.slots[0]
except Exception: pass
sc=bpy.context.scene; f0,f1=act.frame_range
feet=[b.name for b in arm.data.bones if b.name.lower().endswith("foot") or b.name.lower().endswith("foot0")]
print("@@ action",act.name,"frames",round(f0,1),round(f1,1),"fps",sc.render.fps,"feet",feet)
for name in feet:
    zs=[]
    for f in range(int(f0),int(f1)+1):
        sc.frame_set(f); bpy.context.view_layer.update()
        zs.append((arm.matrix_world @ arm.pose.bones[name].head).z)
    base=min(zs)
    lifts=sum(1 for i in range(1,len(zs)-1) if zs[i]<zs[i-1] and zs[i]<=zs[i+1] and zs[i]<base+0.05)
    # frames where foot is raised > 15cm above its lowest
    raised=[i for i,z in enumerate(zs) if z>base+0.15]
    print(f"@@ {name}: base={base:.2f} raised_frames={raised[0] if raised else '-'}..{raised[-1] if raised else '-'} of {len(zs)} minima={lifts}")
