#!/usr/bin/env python3
"""Reconcile FBX take names with GLB clip names per mob and update metadata."""
import json, os, re, struct

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
OUT = os.path.join(WS, "mobs")


def tail(name):
    parts = [p for p in name.split("|") if p.strip()]
    return parts[-1] if parts else name


def glb_names(path):
    b = open(path, "rb").read()
    off = 12
    while off + 8 <= len(b):
        clen, ctype = struct.unpack("<II", b[off:off + 8])
        if ctype == 0x4E4F534A:
            js = json.loads(b[off + 8:off + 8 + clen].decode("utf-8").rstrip("\x00 "))
            return [a.get("name", "") for a in js.get("animations", [])]
        off += 8 + clen
    return []


def fbx_takes(path):
    b = open(path, "rb").read()
    raw = sorted(set(re.findall(rb"([ -~]{2,140}?)\.tak", b)))
    return [r.decode() for r in raw]


def norm(names):
    """Unique logical clip names, ignoring the duplicated prefixed variants."""
    out = {}
    for n in names:
        t = tail(n)
        if t and len(t) >= 3:
            out.setdefault(t, n)
    return out


man = json.load(open(os.path.join(OUT, "manifest.json")))
problems = []
for e in man:
    d = os.path.join(OUT, e["folder"])
    fbx = os.path.join(d, e["files"]["fbx"])
    glb = os.path.join(d, e["files"]["glb"])
    gnames, fnames = glb_names(glb), fbx_takes(fbx)
    gnorm, fnorm = norm(gnames), norm(fnames)
    only_glb = sorted(set(gnorm) - set(fnorm))
    only_fbx = sorted(set(fnorm) - set(gnorm))
    e["fbx_takes"] = fnames
    e["fbx_take_strings"] = len(fnames)
    e["fbx_clips"] = sorted(fnorm)
    e["glb_clips"] = sorted(gnorm)
    e["clip_parity"] = {"only_in_glb": only_glb, "only_in_fbx": only_fbx}
    if only_glb or only_fbx:
        problems.append((e["folder"], only_glb, only_fbx))
    mj = os.path.join(d, "model.json")
    single = json.load(open(mj))
    single.update({k: e[k] for k in ("fbx_takes", "fbx_take_strings", "fbx_clips",
                                     "glb_clips", "clip_parity")})
    json.dump(single, open(mj, "w"), indent=2)

json.dump(man, open(os.path.join(OUT, "manifest.json"), "w"), indent=2)
print("clips per mob (unique):")
for e in man:
    print(f"  {e['folder'][:30]:30s} glb={len(e['glb_clips']):2d} fbx={len(e['fbx_clips']):2d} "
          f"strings={e['fbx_take_strings']:2d}")
print("\nparity problems:", problems or "none")
