"""Headless Blender audit for the poly.pizza mob library.

Reads jobs JSON: [{"key": "...", "file": "..."}], imports each GLB, and prints
one JSON record per model with rest-pose bounds, object/material/action info.
No scene data is modified or exported.
"""
import bpy
import json
import os
import sys
from mathutils import Vector


def _jobs():
    argv = sys.argv
    if "--" not in argv:
        raise SystemExit("expected -- jobs.json out.json")
    rest = argv[argv.index("--") + 1:]
    jobs = json.load(open(rest[0]))
    out = rest[1] if len(rest) > 1 else None
    return jobs, out


def _bounds_meshes():
    dg = bpy.context.evaluated_depsgraph_get()
    dg.update()
    lo = Vector((1e18, 1e18, 1e18))
    hi = Vector((-1e18, -1e18, -1e18))
    verts = 0
    for inst in dg.object_instances:
        ob = inst.object
        if ob.type != "MESH":
            continue
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        try:
            for v in me.vertices:
                w = ev.matrix_world @ v.co
                lo.x = min(lo.x, w.x); lo.y = min(lo.y, w.y); lo.z = min(lo.z, w.z)
                hi.x = max(hi.x, w.x); hi.y = max(hi.y, w.y); hi.z = max(hi.z, w.z)
                verts += 1
        finally:
            ev.to_mesh_clear()
    if verts == 0:
        return None
    return {"min": [round(v, 5) for v in lo],
            "max": [round(v, 5) for v in hi],
            "size": [round(hi[i] - lo[i], 5) for i in range(3)],
            "center": [round((hi[i] + lo[i]) * 0.5, 5) for i in range(3)],
            "verts": verts}


def audit(job):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    bpy.ops.import_scene.gltf(filepath=job["file"])
    bpy.context.view_layer.update()

    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    for arm in armatures:
        arm.data.pose_position = "REST"
    bpy.context.view_layer.update()

    objs = list(bpy.data.objects)
    meshes = [o for o in objs if o.type == "MESH"]
    mats = set()
    for ob in meshes:
        for slot in ob.material_slots:
            if slot.material:
                mats.add(slot.material.name)
    images = [im.name for im in bpy.data.images if im.size[0] > 0]
    b = _bounds_meshes()

    actions = []
    for a in bpy.data.actions:
        lo, hi = a.frame_range
        actions.append({"name": a.name, "range": [round(lo, 2), round(hi, 2)]})
    actions.sort(key=lambda a: a["name"])

    rec = {
        "key": job["key"],
        "file": job["file"],
        "bounds_rest": b,
        "mesh_objects": [o.name for o in meshes],
        "armatures": [o.name for o in armatures],
        "materials": sorted(mats),
        "images": images,
        "actions": actions,
    }
    # Root/hip/head world positions in rest pose are useful for origin checks.
    if armatures:
        arm = armatures[0]
        points = {}
        for name in ("Root", "Hips", "Head", "Foot.L", "Foot.R"):
            pb = arm.pose.bones.get(name)
            if pb is not None:
                points[name] = [round(v, 4) for v in (arm.matrix_world @ pb.head)]
        rec["bones_rest"] = points
    return rec


def main():
    jobs, out = _jobs()
    results = []
    for i, job in enumerate(jobs):
        try:
            rec = audit(job)
        except Exception as exc:  # keep going: one bad asset must not kill the batch
            rec = {"key": job.get("key", "?"), "file": job.get("file", "?"), "error": repr(exc)}
        results.append(rec)
        print("@@AUDIT", json.dumps(rec), flush=True)
        print("@@PROGRESS %d/%d %s" % (i + 1, len(jobs), rec.get("key")), flush=True)
    if out:
        with open(out, "w") as f:
            json.dump(results, f, indent=1)
    print("@@DONE %d" % len(results), flush=True)


main()
