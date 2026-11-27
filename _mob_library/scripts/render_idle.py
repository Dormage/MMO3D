import bpy,json,sys,os,math,re
from mathutils import Vector
argv=sys.argv; rest=argv[argv.index('--')+1:]
jobs=json.load(open(rest[0])); outdir=rest[1]; os.makedirs(outdir,exist_ok=True)
def pick(acts,tok):
    for a in acts:
        if re.search(r'(^|[|])'+tok+r'([|]|$)',a.name.lower()): return a
    for a in acts:
        if tok in a.name.lower(): return a
    return None
def bounds():
    dg=bpy.context.evaluated_depsgraph_get(); dg.update(); lo=Vector((1e18,)*3); hi=Vector((-1e18,)*3)
    for inst in dg.object_instances:
        ob=inst.object
        if ob.type!='MESH': continue
        ev=ob.evaluated_get(dg); me=ev.to_mesh()
        for v in me.vertices:
            w=ev.matrix_world@v.co
            for i in range(3): lo[i]=min(lo[i],w[i]); hi[i]=max(hi[i],w[i])
        ev.to_mesh_clear()
    return lo,hi
for job in jobs:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc=bpy.context.scene; sc.render.engine='BLENDER_EEVEE'; sc.eevee.taa_render_samples=12
    sc.render.resolution_x=380; sc.render.resolution_y=440
    bpy.ops.import_scene.gltf(filepath=job['file'])
    arm=next((o for o in bpy.data.objects if o.type=='ARMATURE'),None)
    if arm and arm.animation_data:
        ad=arm.animation_data; acts=list(bpy.data.actions)
        a=pick(acts,'idle') or pick(acts,'walk') or (acts[0] if acts else None)
        if a:
            ad.action=a
            if a.slots: ad.action_slot=a.slots[0]
            lo,hi=a.frame_range; sc.frame_set(int(round(lo+(hi-lo)*0.5)))
    bpy.context.view_layer.update()
    lo,hi=bounds(); c=(lo+hi)*0.5; size=max((hi-lo).length,0.3)
    cam_d=bpy.data.cameras.new('Cam'); cam_d.lens=58
    cam=bpy.data.objects.new('Cam',cam_d); sc.collection.objects.link(cam)
    d=Vector((0.85,-1.15,0.30)).normalized(); cam.location=c+d*size*1.05
    cam.rotation_euler=(c-cam.location).to_track_quat('-Z','Y').to_euler(); sc.camera=cam
    sun_d=bpy.data.lights.new('Sun',type='SUN'); sun_d.energy=4; sun=bpy.data.objects.new('Sun',sun_d); sc.collection.objects.link(sun); sun.rotation_euler=(math.radians(55),0,math.radians(35))
    w=bpy.data.worlds.new('W'); sc.world=w; w.use_nodes=True; w.node_tree.nodes['Background'].inputs[0].default_value=(0.10,0.11,0.14,1); w.node_tree.nodes['Background'].inputs[1].default_value=0.8
    sc.render.filepath=os.path.join(outdir,job['key']+'.png'); bpy.ops.render.render(write_still=True)
    print('@@IDLE',job['key'],flush=True)
