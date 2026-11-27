import bpy, sys
from mathutils import Vector
p=sys.argv[sys.argv.index('--')+1]
def bounds(label):
    dg=bpy.context.evaluated_depsgraph_get(); dg.update()
    lo=Vector((1e9,)*3); hi=Vector((-1e9,)*3); n=0
    for inst in dg.object_instances:
        ob=inst.object
        if ob.type!='MESH': continue
        ev=ob.evaluated_get(dg); me=ev.to_mesh()
        for v in me.vertices:
            w=ev.matrix_world@v.co
            for i in range(3): lo[i]=min(lo[i],w[i]); hi[i]=max(hi[i],w[i])
            n+=1
        ev.to_mesh_clear()
    print(label,'dims',[round(hi[i]-lo[i],3) for i in range(3)],'min',[round(v,3) for v in lo],'max',[round(v,3) for v in hi],'n',n)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=p)
bpy.context.view_layer.update()
bounds('POSE_default')
for arm in [o for o in bpy.data.objects if o.type=='ARMATURE']:
    arm.data.pose_position='REST'
bpy.context.view_layer.update()
bounds('REST')
for arm in [o for o in bpy.data.objects if o.type=='ARMATURE']:
    arm.data.pose_position='POSE'
bpy.context.view_layer.update()
bounds('POSE_again')
print('objects in scene',[o.name for o in bpy.context.scene.objects if o.type=='MESH'])
