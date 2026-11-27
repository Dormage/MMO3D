import bpy, sys
from mathutils import Vector
p=sys.argv[sys.argv.index('--')+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=p)
bpy.context.view_layer.update()
for ob in bpy.data.objects:
    if ob.type!='MESH': continue
    print('OBJ',ob.name,'hide',ob.hide_render,ob.hide_viewport,'vis_cam',getattr(ob,'visible_camera',None),'vis_shadow',getattr(ob,'visible_shadow',None),'parent',ob.parent.name if ob.parent else None)
    dg=bpy.context.evaluated_depsgraph_get(); dg.update()
    ev=ob.evaluated_get(dg); me=ev.to_mesh()
    lo=Vector((1e9,)*3); hi=Vector((-1e9,)*3)
    for v in me.vertices:
        w=ev.matrix_world@v.co
        for i in range(3): lo[i]=min(lo[i],w[i]); hi[i]=max(hi[i],w[i])
    print('  eval dims',[round(hi[i]-lo[i],3) for i in range(3)],'min',[round(v,3) for v in lo],'max',[round(v,3) for v in hi],'nverts',len(me.vertices))
    ev.to_mesh_clear()
