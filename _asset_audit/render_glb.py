import bpy, sys, json, os, math
from mathutils import Vector
jobs=json.loads(sys.argv[sys.argv.index("--")+1])
outdir="/home/dormage/code/MMO3D2/_asset_audit/renders_glb"
os.makedirs(outdir,exist_ok=True)
for job in jobs:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc=bpy.context.scene
    sc.render.engine="BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in [i.identifier for i in bpy.types.RenderSettings.bl_rna.properties['engine'].enum_items] else "BLENDER_EEVEE"
    sc.render.resolution_x=520; sc.render.resolution_y=620
    sc.render.film_transparent=False
    bpy.ops.import_scene.gltf(filepath=job["file"])
    ms=[o for o in bpy.data.objects if o.type=="MESH"]
    if not ms: print("@@ skip",job["key"]); continue
    bpy.context.view_layer.update()
    lo=Vector((1e9,)*3); hi=Vector((-1e9,)*3)
    for o in ms:
        for c in o.bound_box:
            w=o.matrix_world@Vector(c)
            lo=Vector((min(lo[i],w[i]) for i in range(3))); hi=Vector((max(hi[i],w[i]) for i in range(3)))
    center=(lo+hi)/2; size=max((hi-lo).length,0.1)
    cam_d=bpy.data.cameras.new("C"); cam_d.lens=55
    cam=bpy.data.objects.new("C",cam_d); sc.collection.objects.link(cam)
    d=Vector((0.8,-1.0,0.35)).normalized()
    cam.location=center+d*size*1.15
    cam.rotation_euler=(center-cam.location).to_track_quat("-Z","Y").to_euler()
    sc.camera=cam
    # studio-ish light
    sun_d=bpy.data.lights.new("S",type="SUN"); sun_d.energy=3.2
    sun=bpy.data.objects.new("S",sun_d); sc.collection.objects.link(sun)
    sun.rotation_euler=(math.radians(50),0,math.radians(35))
    world=bpy.data.worlds.new("W"); sc.world=world; world.use_nodes=True
    world.node_tree.nodes["Background"].inputs[0].default_value=(0.12,0.13,0.15,1)
    world.node_tree.nodes["Background"].inputs[1].default_value=0.9
    sc.render.filepath=os.path.join(outdir,job["key"]+".png")
    bpy.ops.render.render(write_still=True)
    print("@@ rendered",job["key"],flush=True)
print("@@ DONE")
