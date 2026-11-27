"""Render one 3/4 front thumbnail per GLB into <outdir>/<key>.png."""
import bpy
import json
import math
import os
import sys
from mathutils import Vector


def _args():
    argv = sys.argv
    rest = argv[argv.index("--") + 1:]
    return json.load(open(rest[0])), rest[1]


def _bounds():
    dg = bpy.context.evaluated_depsgraph_get()
    dg.update()
    lo = Vector((1e18, 1e18, 1e18))
    hi = Vector((-1e18, -1e18, -1e18))
    for inst in dg.object_instances:
        ob = inst.object
        if ob.type != "MESH" or not ob.visible_get():
            continue
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        for v in me.vertices:
            w = ev.matrix_world @ v.co
            for i in range(3):
                lo[i] = min(lo[i], w[i])
                hi[i] = max(hi[i], w[i])
        ev.to_mesh_clear()
    return lo, hi


def main():
    jobs, outdir = _args()
    os.makedirs(outdir, exist_ok=True)
    for job in jobs:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        sc = bpy.context.scene
        sc.render.engine = "BLENDER_EEVEE"
        sc.eevee.taa_render_samples = 16
        sc.render.resolution_x = 380
        sc.render.resolution_y = 440
        sc.render.film_transparent = False
        bpy.ops.import_scene.gltf(filepath=job["file"])
        sc.frame_set(0)
        bpy.context.view_layer.update()
        lo, hi = _bounds()
        c = (lo + hi) * 0.5
        size = max((hi - lo).length, 0.3)
        cam_d = bpy.data.cameras.new("Cam")
        cam_d.lens = 58
        cam = bpy.data.objects.new("Cam", cam_d)
        sc.collection.objects.link(cam)
        d = Vector((0.85, -1.15, 0.30)).normalized()
        cam.location = c + d * size * 1.05
        cam.rotation_euler = (c - cam.location).to_track_quat("-Z", "Y").to_euler()
        sc.camera = cam
        sun_d = bpy.data.lights.new("Sun", type="SUN")
        sun_d.energy = 4.0
        sun = bpy.data.objects.new("Sun", sun_d)
        sc.collection.objects.link(sun)
        sun.rotation_euler = (math.radians(55), 0, math.radians(35))
        world = bpy.data.worlds.new("W")
        sc.world = world
        world.use_nodes = True
        world.node_tree.nodes["Background"].inputs[0].default_value = (0.10, 0.11, 0.14, 1)
        world.node_tree.nodes["Background"].inputs[1].default_value = 0.8
        sc.render.filepath = os.path.join(outdir, "%s.png" % job["key"])
        bpy.ops.render.render(write_still=True)
        print("@@THUMB", job["key"], flush=True)
    print("@@DONE", flush=True)


main()
