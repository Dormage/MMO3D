import bpy, json, sys
from mathutils import Vector
path=sys.argv[sys.argv.index('--')+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=path)
bpy.context.view_layer.update()
for ob in bpy.data.objects:
    if ob.type!='MESH': continue
    lo=Vector((1e9,)*3); hi=Vector((-1e9,)*3)
    for c in ob.bound_box:
        w=ob.matrix_world@Vector(c)
        for i in range(3): lo[i]=min(lo[i],w[i]); hi[i]=max(hi[i],w[i])
    print('OBJ',ob.name,'dims',[round(hi[i]-lo[i],3) for i in range(3)],'min',[round(v,3) for v in lo],'max',[round(v,3) for v in hi],
          'hide_render',ob.hide_render,'hide_view',ob.hide_viewport,'verts',len(ob.data.vertices),
          'mats',[s.material.name if s.material else None for s in ob.material_slots],
          'parent',ob.parent.name if ob.parent else None,'scale',[round(v,3) for v in ob.scale])
    for s in ob.material_slots:
        m=s.material
        if not m: continue
        print('  MAT',m.name,'blend',getattr(m,'surface_render_method',None),'diffuse',list(m.diffuse_color))
        if m.use_nodes:
            for n in m.node_tree.nodes:
                if n.type=='BSDF_PRINCIPLED':
                    print('   alpha',n.inputs['Alpha'].default_value,'base',list(n.inputs['Base Color'].default_value))
