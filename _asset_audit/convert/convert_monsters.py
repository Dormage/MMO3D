"""Convert monster FBX sets (mesh + optional separate animation files) to textured GLB.

Job fields:
  key, mesh, anims:[{file, clip}], out,
  textures:{base, normal, metallic, roughness, emissive, alpha},
  roughness (float), metallic (float), clip_prefix (optional)
"""
import bpy
import json
import math
import os
import sys

JOBS = json.loads(sys.argv[sys.argv.index("--") + 1])


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = 30


def armatures():
    return [o for o in bpy.data.objects if o.type == "ARMATURE"]


def action_motion_range(action, threshold=0.08):
    """First/last frame that actually moves, ignoring baked static lead-ins/outs."""
    fcs = [fc for cb, fc in fcurves_with_bags(action)]
    if not fcs:
        return None
    start, end = action.frame_range
    frames = list(range(int(math.floor(start)), int(math.ceil(end)) + 1))
    if len(frames) < 3:
        return None
    prev = None
    energy = []
    for f in frames:
        cur = [fc.evaluate(f) for fc in fcs]
        energy.append(sum(abs(a - b) for a, b in zip(cur, prev)) if prev else 0.0)
        prev = cur
    top = max(energy)
    if top <= 1e-6:
        return None
    th = top * threshold
    active = [i for i, e in enumerate(energy) if e > th]
    if len(active) < 2:
        return None
    first = max(0, active[0] - 1)
    last = min(len(frames) - 1, active[-1] + 1)
    return frames[first], frames[last]


def trim_action(action, start, end):
    """Keep [start,end] and shift it to frame 0 so the exported clip starts at t=0."""
    for cb, fc in fcurves_with_bags(action):
        # remove back-to-front: removing invalidates keyframe pointers after it
        for i in range(len(fc.keyframe_points) - 1, -1, -1):
            kp = fc.keyframe_points[i]
            if kp.co.x < start - 1e-4 or kp.co.x > end + 1e-4:
                fc.keyframe_points.remove(kp, fast=True)
        for kp in fc.keyframe_points:
            kp.co.x -= start
            kp.handle_left.x -= start
            kp.handle_right.x -= start
            kp.interpolation = "LINEAR"
        fc.update()


def close_loop(action, fps, blend_seconds=0.3):
    """Ease the tail of a cyclic action back onto its first-frame pose.

    Unity/FBX walk takes often carry secondary motion (antennae, tail) whose last
    key does not match the first, so LOOP_LINEAR pops at the wrap.  Only tracks
    that actually differ are touched, and only over the last `blend_seconds`."""
    fcs = [fc for cb, fc in fcurves_with_bags(action)]
    if not fcs:
        return False
    start = min(fc.keyframe_points[0].co.x for fc in fcs if len(fc.keyframe_points))
    end = max(fc.keyframe_points[-1].co.x for fc in fcs if len(fc.keyframe_points))
    span = end - start
    if span <= 0.0:
        return False
    blend = min(blend_seconds * fps, span * 0.35)
    bstart = end - blend
    changed = False
    for fc in fcs:
        if len(fc.keyframe_points) < 2:
            continue
        v0 = fc.evaluate(start)
        v1 = fc.evaluate(end)
        if abs(v1 - v0) < 1e-4:
            continue
        window = [kp for kp in fc.keyframe_points if kp.co.x >= bstart - 1e-6]
        if len(window) < 2:
            # sparse track: anchor both ends so the tail still eases onto frame 0
            fc.keyframe_points.insert(bstart, fc.evaluate(bstart))
            if len([kp for kp in fc.keyframe_points if kp.co.x >= bstart - 1e-6]) < 2:
                fc.keyframe_points.insert(end, fc.evaluate(end))
            fc.update()
            window = [kp for kp in fc.keyframe_points if kp.co.x >= bstart - 1e-6]
        if len(window) < 2:
            continue
        orig = [(kp.co.x, kp.co.y) for kp in window]
        for kp, (x, y) in zip(window, orig):
            w = min(1.0, max(0.0, (x - bstart) / blend))
            w = w * w * (3.0 - 2.0 * w)
            kp.co.y = y * (1.0 - w) + v0 * w
        fc.update()
        changed = True
    # The glTF exporter's first sample lands on start+1, not start, so pin the
    # first two frames to the loop pose; otherwise a fast cycle keeps a one-frame
    # pop at the wrap even though the fcurves match at start/end.
    for fc in fcs:
        if len(fc.keyframe_points) < 2:
            continue
        v0 = fc.evaluate(start)
        for kp in fc.keyframe_points:
            if kp.co.x <= start + 1.0001 or kp.co.x >= end - 1.0001:
                kp.co.y = v0
        fc.update()

    seam = 0.0
    for fc in fcs:
        if len(fc.keyframe_points) >= 2:
            seam = max(seam, abs(fc.evaluate(start) - fc.evaluate(end)))
    print("@@ close_loop %s span=%.2f blend=%.2f changed=%s residual=%.4f" % (action.name, span, blend, changed, seam))
    return changed


def fcurves_with_bags(act):
    out = []
    try:
        for layer in act.layers:
            for strip in layer.strips:
                for cb in strip.channelbags:
                    for fc in cb.fcurves:
                        out.append((cb, fc))
    except Exception:
        pass
    return out


def action_fcurves(act):
    out = []
    try:
        for layer in act.layers:
            for strip in layer.strips:
                for cb in strip.channelbags:
                    out.extend(cb.fcurves)
    except Exception:
        pass
    return out


def assign_action(arm, act):
    if arm.animation_data is None:
        arm.animation_data_create()
    ad = arm.animation_data
    ad.action = act
    try:
        if act.slots:
            ad.action_slot = act.slots[0]
    except Exception:
        pass


def load_texture(path, colorspace="sRGB"):
    img = bpy.data.images.load(path, check_existing=True)
    img.colorspace_settings.name = colorspace
    return img


def wire_material(mat, tex, job):
    mat.use_nodes = True
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    bsdf = next((n for n in nodes if n.type == "BSDF_PRINCIPLED"), None)
    if bsdf is None:
        bsdf = nodes.new("ShaderNodeBsdfPrincipled")
        out = next((n for n in nodes if n.type == "OUTPUT_MATERIAL"), None) or nodes.new("ShaderNodeOutputMaterial")
        links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    bsdf.inputs["Roughness"].default_value = job.get("roughness", 0.62)
    bsdf.inputs["Metallic"].default_value = job.get("metallic", 0.0)
    if "IOR" in bsdf.inputs:
        bsdf.inputs["IOR"].default_value = 1.45

    if tex.get("base"):
        img = load_texture(tex["base"], "sRGB")
        n = nodes.new("ShaderNodeTexImage")
        n.image = img
        n.location = (-620, 320)
        links.new(n.outputs["Color"], bsdf.inputs["Base Color"])
        if tex.get("alpha"):
            links.new(n.outputs["Alpha"], bsdf.inputs["Alpha"])
            try:
                mat.surface_render_method = "DITHERED"
            except Exception:
                pass

    if tex.get("normal"):
        img = load_texture(tex["normal"], "Non-Color")
        n = nodes.new("ShaderNodeTexImage")
        n.image = img
        n.location = (-620, 40)
        nm = nodes.new("ShaderNodeNormalMap")
        nm.location = (-300, 40)
        links.new(n.outputs["Color"], nm.inputs["Color"])
        links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])

    if tex.get("emissive"):
        img = load_texture(tex["emissive"], "sRGB")
        n = nodes.new("ShaderNodeTexImage")
        n.image = img
        n.location = (-620, -240)
        links.new(n.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = job.get("emission_strength", 1.0)


def convert(job):
    reset()
    bpy.ops.import_scene.fbx(filepath=job["mesh"], use_anim=True)
    mains = armatures()
    if not mains:
        return {"key": job["key"], "error": "no armature in mesh file"}
    main_arm = mains[0]
    main_arm.name = "Armature"

    imported = []
    for spec in job.get("anims", []):
        before_objs = set(bpy.data.objects)
        before_acts = set(bpy.data.actions)
        bpy.ops.import_scene.fbx(filepath=spec["file"], use_anim=True)
        new_objs = [o for o in bpy.data.objects if o not in before_objs]
        new_arms = [o for o in new_objs if o.type == "ARMATURE"]
        new_acts = [a for a in bpy.data.actions if a not in before_acts]
        # the armature-level action is the one whose fcurves drive pose bones
        arm_names = [o.name for o in new_arms]
        picked = [a for a in new_acts
                  if any(a.name.startswith(n + "|") for n in arm_names)]
        if not picked and new_acts:
            picked = sorted(new_acts, key=lambda a: a.frame_range[1] - a.frame_range[0],
                            reverse=True)[:1]
        for a in picked[:1]:
            a.name = spec["clip"]
            imported.append(a)
        # drop the duplicate rig + any meshes it carried
        for o in new_objs:
            try:
                bpy.data.objects.remove(o, do_unlink=True)
            except Exception:
                pass

    if imported:
        # keep only the wanted actions so the exporter does not emit duplicates
        for a in list(bpy.data.actions):
            if a not in imported:
                try:
                    bpy.data.actions.remove(a)
                except Exception:
                    pass
    else:
        # animations were embedded in the mesh file
        keep = []
        cmap = job.get("clip_map", {})
        for a in list(bpy.data.actions):
            if not any(fc.data_path.startswith("pose.bones") for fc in action_fcurves(a)):
                continue
            short = a.name.split("|")[-1]
            if short in cmap:
                if cmap[short] == "":
                    continue  # explicit drop (static pose clips)
                a.name = cmap[short]
            keep.append(a)
        for a in list(bpy.data.actions):
            if a not in keep:
                bpy.data.actions.remove(a)

    # optional global retime (Wolf Boss takes are baked at ~4x real duration)
    ts = float(job.get("time_scale", 1.0))
    if ts != 1.0:
        for a in bpy.data.actions:
            for _cb, fc in fcurves_with_bags(a):
                for kp in fc.keyframe_points:
                    kp.co.x *= ts
                    kp.handle_left.x *= ts
                    kp.handle_right.x *= ts
                fc.update()

    # optional root-motion strip: the walk cycle must not translate the actor
    if job.get("strip_root"):
        roots = [b.name for b in main_arm.data.bones if b.parent is None]
        for a in bpy.data.actions:
            for cb, fc in list(fcurves_with_bags(a)):
                if fc.data_path == "location":
                    cb.fcurves.remove(fc)          # armature-object travel (FBX root motion)
                elif any(fc.data_path == 'pose.bones["%s"].location' % r for r in roots):
                    cb.fcurves.remove(fc)

    trim_names = [n.lower() for n in job.get("trim_clips", [])]
    if trim_names:
        fps = bpy.context.scene.render.fps / max(bpy.context.scene.render.fps_base, 1e-6)
        for a in bpy.data.actions:
            if a.name.split("|")[-1].lower() not in trim_names:
                continue
            rng = action_motion_range(a, float(job.get("trim_threshold", 0.08)))
            if not rng:
                continue
            start, end = rng
            head = (start - a.frame_range[0]) / fps
            tail = (a.frame_range[1] - end) / fps
            if head > 0.15 or tail > 0.15:
                trim_action(a, start, end)

    if job.get("loop_fix"):
        fps = bpy.context.scene.render.fps / max(bpy.context.scene.render.fps_base, 1e-6)
        for a in bpy.data.actions:
            if a.name.split("|")[-1].lower() in ("walk", "run"):
                close_loop(a, fps, float(job.get("loop_blend", 0.3)))

    # one bound action so the exporter has a valid pose; ACTIONS mode emits the rest
    if imported:
        assign_action(main_arm, imported[0])
    elif bpy.data.actions:
        assign_action(main_arm, bpy.data.actions[0])

    # drop helper/duplicate parts that do not survive the FBX->glTF transform
    drops = [d.lower() for d in job.get("drop_meshes", [])]
    if drops:
        for o in list(bpy.data.objects):
            if o.type == "MESH" and any(d in o.name.lower() for d in drops):
                bpy.data.objects.remove(o, do_unlink=True)

    tex = job.get("textures", {})
    for m in bpy.data.materials:
        wire_material(m, tex, job)

    os.makedirs(os.path.dirname(job["out"]), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=job["out"], export_format="GLB",
        export_animations=True, export_animation_mode="ACTIONS",
        export_nla_strips=False, export_anim_single_armature=True,
        export_apply=False, export_yup=True, export_skins=True,
        export_morph=False, export_cameras=False, export_lights=False,
        export_extras=False, export_image_format="AUTO",
    )
    return {"key": job["key"], "out": job["out"],
            "actions": [a.name for a in bpy.data.actions],
            "armatures": [a.name for a in armatures()],
            "materials": [m.name for m in bpy.data.materials],
            "size_kb": os.path.getsize(job["out"]) // 1024}


results = []
for job in JOBS:
    try:
        r = convert(job)
    except Exception as e:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        r = {"key": job["key"], "error": str(e)}
    results.append(r)
    print("@@ " + json.dumps(r), flush=True)
print("@@JSON@@" + json.dumps(results))
