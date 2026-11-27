"""Render a 3/4 view of each creature model (Workbench, headless)."""
import bpy
import json
import math
import os
import sys
from mathutils import Vector

BASE = "/home/dormage/code/MMO3D2/_asset_audit"
OUT = os.path.join(BASE, "renders")
os.makedirs(OUT, exist_ok=True)

JOBS = json.loads(sys.argv[sys.argv.index("--") + 1])

COLORS = {
    "catfish": (0.42, 0.48, 0.38, 1), "watcher": (0.45, 0.40, 0.55, 1),
    "wolf": (0.48, 0.42, 0.36, 1), "rhino": (0.44, 0.46, 0.50, 1),
    "turtle": (0.36, 0.48, 0.44, 1), "swarm08": (0.52, 0.40, 0.38, 1),
    "swarm09": (0.50, 0.44, 0.34, 1), "monster02": (0.44, 0.44, 0.48, 1),
    "ghoul": (0.46, 0.44, 0.38, 1), "creep": (0.42, 0.40, 0.42, 1),
    "foe": (0.44, 0.42, 0.36, 1), "bulldog": (0.52, 0.42, 0.40, 1),
    "monster38": (0.42, 0.46, 0.46, 1), "monster37": (0.46, 0.46, 0.42, 1),
    "mt01": (0.44, 0.46, 0.44, 1), "oresdragon": (0.46, 0.40, 0.44, 1),
    "fantasy": (0.44, 0.44, 0.46, 1), "arachnid": (0.40, 0.42, 0.46, 1),
}


def setup_scene():
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.render.resolution_x = 560
    sc.render.resolution_y = 680
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sh = sc.display.shading
    sh.light = "STUDIO"
    sh.studio_light = "Default"
    sh.color_type = "OBJECT"
    sh.show_cavity = True
    sh.cavity_type = "BOTH"
    sh.curvature_ridge_factor = 1.2
    sh.curvature_valley_factor = 1.0
    sh.show_object_outline = True
    sh.object_outline_color = (0.05, 0.05, 0.06)
    sh.background_type = "VIEWPORT"
    sh.background_color = (0.09, 0.095, 0.105)
    sc.view_settings.view_transform = "Standard"
    return sc


def frame_objects(sc, meshes):
    mins = Vector((1e9, 1e9, 1e9))
    maxs = Vector((-1e9, -1e9, -1e9))
    for ob in meshes:
        for c in ob.bound_box:
            w = ob.matrix_world @ Vector(c)
            mins = Vector((min(mins.x, w.x), min(mins.y, w.y), min(mins.z, w.z)))
            maxs = Vector((max(maxs.x, w.x), max(maxs.y, w.y), max(maxs.z, w.z)))
    center = (mins + maxs) / 2
    size = max((maxs - mins).length, 0.01)
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = 60
    cam = bpy.data.objects.new("Cam", cam_data)
    sc.collection.objects.link(cam)
    direction = Vector((0.85, -1.0, 0.42)).normalized()
    cam.location = center + direction * size * 1.15
    cam.rotation_euler = (center - cam.location).to_track_quat("-Z", "Y").to_euler()
    sc.camera = cam
    return center, size


for job in JOBS:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = setup_scene()
    bpy.ops.import_scene.fbx(filepath=job["file"], use_anim=False)
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    meshes = [o for o in meshes if len(o.data.vertices) > 20]
    if not meshes:
        print(f"@@ SKIP no mesh {job['name']}", flush=True)
        continue
    # hide helper props imported alongside the creature
    for o in list(bpy.data.objects):
        if o.type == "MESH" and len(o.data.vertices) <= 20:
            o.hide_render = True
    col = COLORS.get(job["key"], (0.45, 0.45, 0.45, 1))
    for o in meshes:
        o.color = col
        o.show_all_edges = False
    frame_objects(sc, meshes)
    path = os.path.join(OUT, job["key"] + ".png")
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print(f"@@ RENDERED {job['key']} -> {path}", flush=True)
print("@@ DONE", flush=True)
