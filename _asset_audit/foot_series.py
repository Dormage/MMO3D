import bpy, sys
p=sys.argv[sys.argv.index("--")+1]
clip=sys.argv[sys.argv.index("--")+2]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=p)
arm=next(o for o in bpy.data.objects if o.type=="ARMATURE")
act=next((a for a in bpy.data.actions if a.name.split("|")[-1]==clip), None)
if act is None: print("@@ no clip",clip,[a.name for a in bpy.data.actions]); sys.exit()
arm.animation_data_create(); arm.animation_data.action=act
try:
    if len(act.slots): arm.animation_data.action_slot=act.slots[0]
except Exception: pass
sc=bpy.context.scene; f0,f1=act.frame_range
names=[b.name for b in arm.data.bones if b.name in ("Bip01 L Foot","Bip01 R Foot")]
print(f"@@ {clip} frames {f0:.0f}..{f1:.0f} ({(f1-f0)/sc.render.fps:.2f}s)")
for name in names:
    zs=[]
    for f in range(int(f0),int(f1)+1):
        sc.frame_set(f); bpy.context.view_layer.update()
        zs.append((arm.matrix_world @ arm.pose.bones[name].head).z)
    step=max(1,len(zs)//24)
    print(f"@@ {name}: ", [round(z,2) for z in zs[::step]])
