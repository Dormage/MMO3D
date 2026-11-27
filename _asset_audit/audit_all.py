"""Batch-audit every FBX in the reconstructed Unity asset tree with headless Blender.

Writes one JSON object per FBX to audit_raw.jsonl (flushed per file) so progress
is visible while the job runs.
"""
import bpy
import json
import os
import sys

BASE = "/home/dormage/code/MMO3D2/_asset_audit"
TREE = os.path.join(BASE, "tree")
OUT = os.path.join(BASE, "audit_raw.jsonl")


def collect(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    res = {"file": os.path.relpath(path, TREE), "bytes": os.path.getsize(path),
           "ok": False, "error": None, "actions": [], "armatures": [], "meshes": [],
           "materials": [], "images": [], "uv": 0}
    try:
        bpy.ops.import_scene.fbx(filepath=path, use_anim=True)
    except Exception as e:  # noqa: BLE001
        res["error"] = f"import failed: {e}"
        return res

    res["ok"] = True
    for a in bpy.data.actions:
        fr = list(a.frame_range)
        res["actions"].append({"name": a.name, "range": fr,
                               "dur_frames": round(fr[1] - fr[0], 2)})
    for ob in bpy.data.objects:
        if ob.type == "ARMATURE":
            bones = ob.data.bones
            res["armatures"].append({
                "name": ob.name, "bones": len(bones),
                "roots": [b.name for b in bones if b.parent is None][:6],
                "sample_bones": [b.name for b in list(bones)[:8]],
                "scale": [round(x, 4) for x in ob.scale],
            })
        elif ob.type == "MESH":
            me = ob.data
            me.calc_loop_triangles()
            res["meshes"].append({
                "name": ob.name, "tris": len(me.loop_triangles), "verts": len(me.vertices),
                "vgroups": len(ob.vertex_groups), "mats": len(me.materials),
                "uv_layers": len(me.uv_layers),
                "mods": [m.type for m in ob.modifiers],
                "dims": [round(x, 3) for x in ob.dimensions],
                "shape_keys": bool(me.shape_keys),
            })
            res["uv"] = max(res["uv"], len(me.uv_layers))
    for m in bpy.data.materials:
        res["materials"].append(m.name)
    for im in bpy.data.images:
        res["images"].append({"name": im.name, "size": list(im.size),
                              "src": im.filepath, "packed": bool(im.packed_file)})
    return res


def main():
    files = []
    for root, _dirs, names in os.walk(TREE):
        for n in names:
            if n.lower().endswith(".fbx"):
                files.append(os.path.join(root, n))
    files.sort()
    done = set()
    if os.path.exists(OUT):
        with open(OUT) as f:
            for ln in f:
                try:
                    done.add(json.loads(ln)["file"])
                except Exception:
                    pass
    print(f"@@ progress: {len(files)} fbx total, {len(done)} already done", flush=True)
    with open(OUT, "a") as f:
        for i, p in enumerate(files, 1):
            rel = os.path.relpath(p, TREE)
            if rel in done:
                continue
            r = collect(p)
            f.write(json.dumps(r) + "\n")
            f.flush()
            acts = len(r["actions"])
            tris = sum(m["tris"] for m in r["meshes"])
            bones = sum(a["bones"] for a in r["armatures"])
            print(f"@@ [{i}/{len(files)}] {rel} | acts={acts} bones={bones} tris={tris} err={r['error']}",
                  flush=True)
    print("@@ DONE", flush=True)


main()
