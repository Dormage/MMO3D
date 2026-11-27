import bpy, sys, json
from mathutils import Vector
p=sys.argv[sys.argv.index("--")+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=p)
arm=next(o for o in bpy.data.objects if o.type=="ARMATURE")
feet=[b.name for b in arm.data.bones if any(k in b.name.lower() for k in ("foot","toe","hoof"))]
print("@@ feet:", feet)
act=next((a for a in bpy.data.actions if a.name.split("|")[-1]=="walk"), None)
if act is None:
    print("@@ no walk action", [a.name for a in bpy.data.actions]); sys.exit()
arm.animation_data_create()
arm.animation_data.action=act
try:
    if len(act.slots): arm.animation_data.action_slot=act.slots[0]
except Exception as e: print("@@ slot", e)
sc=bpy.context.scene
f0,f1=act.frame_range
print(f"@@ action {act.name} frames {f0}..{f1} fps {sc.render.fps}")
for name in feet[:2]:
    zs=[]
    for f in range(int(f0), int(f1)+1):
        sc.frame_set(f)
        bpy.context.view_layer.update()
        pb=arm.pose.bones[name]
        w=arm.matrix_world @ pb.head
        zs.append(w.z)
    # count local minima
    mins=sum(1 for i in range(1,len(zs)-1) if zs[i]<zs[i-1] and zs[i]<=zs[i+1])
    print(f"@@ {name} min={min(zs):.3f} max={max(zs):.3f} minima={mins} series={[round(z,2) for z in zs[::max(1,len(zs)//30)]]}")
