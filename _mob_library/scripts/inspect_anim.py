import bpy,sys
p=sys.argv[sys.argv.index('--')+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=p)
for ob in bpy.data.objects:
    if ob.type=='ARMATURE':
        ad=ob.animation_data
        print('ARM',ob.name,'action',ad.action.name if ad and ad.action else None,'slot',getattr(ad,'action_slot',None))
        print(' slots',[s.identifier for s in (ad.action.slots if ad and ad.action else [])])
print('frame',bpy.context.scene.frame_current)
for a in bpy.data.actions[:5]:
    print('ACT',a.name,'range',a.frame_range,'slots',[s.identifier for s in a.slots])
