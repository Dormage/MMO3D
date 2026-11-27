"""Render labelled orthographic axis views of GLBs for facing/orientation QA.

jobs JSON: [{"key": "...", "file": "..."}]
Output: <outdir>/<key>_<view>.png where view is plusX, minusX, plusY, minusY.
"""
import bpy
import json
import math
import os
import sys
from mathutils import Vector

VIEWS = {
    "plusX": (1, 0, 0),
    "minusX": (-1, 0, 0),
    "plusY": (0, 1, 0),
    "minusY": (0, -1, 0),
}


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
        if ob.type != "MESH":
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
        for view, direction in VIEWS.items():
            bpy.ops.wm.read_factory_settings(use_empty=True)
            sc = bpy.context.scene
            sc.render.engine = "BLENDER_EEVEE"
            sc.eevee.taa_render_samples = 12
            sc.render.resolution_x = 320
            sc.render.resolution_y = 380
            sc.render.resolution_percentage = 100
            sc.render.film_transparent = False
            bpy.ops.import_scene.gltf(filepath=job["file"])
            for arm in [o for o in bpy.data.objects if o.type == "ARMATURE"]:
                arm.data.pose_position = "REST"
            bpy.context.view_layer.update()
            lo, hi = _bounds()
            c = (lo + hi) * 0.5
            size = max((hi - lo).length, 0.2)
            cam_d = bpy.data.cameras.new("Cam")
            cam_d.type = "ORTHO"
            cam_d.ortho_scale = size * 0.92
            cam = bpy.data.objects.new("Cam", cam_d)
            sc.collection.objects.link(cam)
            cam.location = c + Vector(direction) * size * 2.0
            cam.rotation_euler = (c - cam.location).to_track_quat("-Z", "Y").to_euler()
            sc.camera = cam
            sun_d = bpy.data.lights.new("Sun", type="SUN")
            sun_d.energy = 4.0
            sun = bpy.data.objects.new("Sun", sun_d)
            sc.collection.objects.link(sun)
            sun.rotation_euler = (math.radians(50), 0, math.radians(30))
            world = bpy.data.worlds.new("W")
            sc.world = world
            world.use_nodes = True
            world.node_tree.nodes["Background"].inputs[0].default_value = (0.13, 0.14, 0.17, 1)
            world.node_tree.nodes["Background"].inputs[1].default_value = 1.1
            sc.render.filepath = os.path.join(outdir, "%s_%s.png" % (job["key"], view))
            bpy.ops.render.render(write_still=True)
        print("@@VIEWS", job["key"], flush=True)
    print("@@DONE", flush=True)


main()
