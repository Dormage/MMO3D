import bpy, sys, json, math, os
from mathutils import Vector
jobs=json.loads(sys.argv[sys.argv.index("--")+1])
for job in jobs:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc=bpy.context.scene
    sc.render.engine="BLENDER_EEVEE"
    sc.render.resolution_x=520; sc.render.resolution_y=620
    bpy.ops.import_scene.gltf(filepath=job["file"])
    sc.frame_set(1)
    dg=bpy.context.evaluated_depsgraph_get(); dg.update()
    lo=Vector((1e9,)*3); hi=Vector((-1e9,)*3)
    for inst in dg.object_instances:
        ob=inst.object
        if ob.type!="MESH": continue
        ev=ob.evaluated_get(dg)
        me=ev.to_mesh()
        for v in me.vertices:
            w=ev.matrix_world@v.co
            lo=Vector((min(lo[i],w[i]) for i in range(3))); hi=Vector((max(hi[i],w[i]) for i in range(3)))
        ev.to_mesh_clear()
    if lo.x>1e8:
        print("@@ no geom",job["key"]); continue
    center=(lo+hi)/2; size=max((hi-lo).length,0.1)
    print("@@ bounds",job["key"],[round(x,2) for x in (hi-lo)])
    cam_d=bpy.data.cameras.new("C"); cam_d.lens=50
    cam=bpy.data.objects.new("C",cam_d); sc.collection.objects.link(cam)
    d=Vector((0.85,-1.0,0.3)).normalized()
    cam.location=center+d*size*2.0
    cam.rotation_euler=(center-cam.location).to_track_quat("-Z","Y").to_euler()
    sc.camera=cam
    sun_d=bpy.data.lights.new("S",type="SUN"); sun_d.energy=3.0
    sun=bpy.data.objects.new("S",sun_d); sc.collection.objects.link(sun)
    sun.rotation_euler=(math.radians(52),0,math.radians(30))
    w=bpy.data.worlds.new("W"); sc.world=w; w.use_nodes=True
    w.node_tree.nodes["Background"].inputs[0].default_value=(0.12,0.13,0.15,1)
    w.node_tree.nodes["Background"].inputs[1].default_value=0.9
    sc.render.filepath="/home/dormage/code/MMO3D2/_asset_audit/renders_glb/%s_eval.png"%job["key"]
    bpy.ops.render.render(write_still=True)
print("@@ DONE")
