"""Measure root/hip displacement of locomotion clips (root motion vs in-place)."""
import bpy
import json
import sys
from mathutils import Vector

JOBS = json.loads(sys.argv[sys.argv.index("--") + 1])
out = []
for job in JOBS:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = 30
    try:
        bpy.ops.import_scene.fbx(filepath=job["file"], use_anim=True)
    except Exception as e:  # noqa: BLE001
        out.append({"file": job["file"], "error": str(e)})
        continue
    arm = next((o for o in bpy.data.objects if o.type == "ARMATURE"), None)
    if not arm:
        out.append({"file": job["file"], "error": "no armature"})
        continue
    # armature-sized action = the one with pose.bones fcurves
    def fcurves_of(act):
        out = []
        try:
            for layer in act.layers:
                for strip in layer.strips:
                    for cb in strip.channelbags:
                        out.extend(cb.fcurves)
        except Exception:
            pass
        return out

    acts = [a for a in bpy.data.actions
            if any(fc.data_path.startswith("pose.bones") for fc in fcurves_of(a))]
    if job.get("match"):
        m = [a for a in acts if job["match"].lower() in a.name.lower()]
        if m:
            acts = m
    acts.sort(key=lambda a: a.frame_range[1] - a.frame_range[0], reverse=True)
    if not acts:
        out.append({"file": job["file"], "error": "no armature action"})
        continue
    act = acts[0]
    arm.animation_data_create()
    arm.animation_data.action = act
    try:
        if act.slots:
            arm.animation_data.action_slot = act.slots[0]
    except Exception:
        pass
    dg = bpy.context.evaluated_depsgraph_get()
    root = next((b for b in arm.data.bones if b.parent is None), None)
    f0, f1 = int(act.frame_range[0]), int(act.frame_range[1])
    pts = []
    for f in range(f0, f1 + 1, max(1, (f1 - f0) // 40)):
        bpy.context.scene.frame_set(f)
        dg.update()
        if root:
            pts.append(arm.matrix_world @ arm.pose.bones[root.name].head)
    if not pts:
        out.append({"file": job["file"], "error": "no samples"})
        continue
    d = pts[-1] - pts[0]
    horiz = [Vector((p.x - pts[0].x, 0, p.y - pts[0].y)) for p in pts]
    out.append({"file": job["file"], "action": act.name,
                "frames": [f0, f1], "seconds": round((f1 - f0) / 30.0, 2),
                "root_delta_m": [round(v, 3) for v in d],
                "root_delta_len": round(d.length, 3),
                "max_horiz_dev": round(max(h.length for h in horiz), 3),
                "z_range": round(max(p.z for p in pts) - min(p.z for p in pts), 3)})
    print("@@ " + json.dumps(out[-1]), flush=True)
print("@@JSON@@" + json.dumps(out))
