import bpy, sys, math
from mathutils import Vector
p=sys.argv[sys.argv.index('--')+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
sc=bpy.context.scene
sc.render.engine='BLENDER_EEVEE'; sc.eevee.taa_render_samples=8
sc.render.resolution_x=380; sc.render.resolution_y=440
bpy.ops.import_scene.gltf(filepath=p)
sc.frame_set(0); bpy.context.view_layer.update()
print('OBJECTS',[(o.name,o.type,o.hide_render,o.visible_get()) for o in bpy.context.scene.objects])
dg=bpy.context.evaluated_depsgraph_get(); dg.update()
lo=Vector((1e9,)*3); hi=Vector((-1e9,)*3)
for inst in dg.object_instances:
    ob=inst.object
    if ob.type!='MESH': continue
    ev=ob.evaluated_get(dg); me=ev.to_mesh()
    for v in me.vertices:
        w=ev.matrix_world@v.co
        for i in range(3): lo[i]=min(lo[i],w[i]); hi[i]=max(hi[i],w[i])
    ev.to_mesh_clear()
print('BOUNDS',lo,hi)
c=(lo+hi)*0.5; size=max((hi-lo).length,0.3)
cam_d=bpy.data.cameras.new('Cam'); cam_d.lens=58
cam=bpy.data.objects.new('Cam',cam_d); sc.collection.objects.link(cam)
d=Vector((0.85,-1.15,0.30)).normalized(); cam.location=c+d*size*1.05
cam.rotation_euler=(c-cam.location).to_track_quat('-Z','Y').to_euler(); sc.camera=cam
print('CAM',cam.location,cam.rotation_euler,'center',c,'size',size)
sun_d=bpy.data.lights.new('Sun',type='SUN'); sun_d.energy=4; sun=bpy.data.objects.new('Sun',sun_d); sc.collection.objects.link(sun); sun.rotation_euler=(math.radians(55),0,math.radians(35))
w=bpy.data.worlds.new('W'); sc.world=w; w.use_nodes=True; w.node_tree.nodes['Background'].inputs[0].default_value=(0.1,0.11,0.14,1)
sc.render.filepath='/home/dormage/code/MMO3D2/_mob_library/renders_creatures/debug.png'
bpy.ops.render.render(write_still=True)
print('done')
