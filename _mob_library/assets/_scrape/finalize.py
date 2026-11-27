#!/usr/bin/env python3
"""Download qualifying mobs as FBX + GLB into mobs/, with manifest and report."""
import csv, io, json, os, re, shutil, struct, time, urllib.request, zipfile

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
SCRAPE = os.path.join(WS, "_scrape")
OUT = os.path.join(WS, "mobs")
CDN = "https://static.poly.pizza"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36"

PAT = {
    "hit": re.compile(r"hit", re.I),
    "death": re.compile(r"death|dead|\bdie\b|\bdea\b", re.I),
    "run": re.compile(r"(^|[|_\s])run2?($|[|_\s])|running", re.I),
}


def fetch(url, dest=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=90) as r:
        d = r.read()
    if dest:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        open(dest, "wb").write(d)
    return d


def page_meta(pid):
    for attempt in range(4):
        try:
            h = fetch("https://poly.pizza/m/" + pid).decode("utf-8", "replace")
            m = re.search(r"window\.__SERVER_APP_STATE__\s*=\s*(\{.*?\});?\s*</script>", h, re.S)
            d = json.loads(m.group(1))["initialData"]["model"]
            return {"title": d["Title"], "s3id": d["ResourceID"],
                    "licence": d.get("Licence"), "creator": d["Creator"]["Username"],
                    "animated": d.get("Animated"), "sourceType": d.get("Type"),
                    "tags": d.get("Tags", []), "views": d.get("Views"),
                    "downloads": d.get("Downloads"), "uploadDate": d.get("UploadDate")}
        except Exception as e:
            if attempt == 3:
                raise
            time.sleep(3 * (attempt + 1))


def slug(t):
    s = re.sub(r"[^A-Za-z0-9]+", "_", t).strip("_")
    return s or "mob"


def fbx_check(path):
    b = open(path, "rb").read()
    takes = sorted(set(re.findall(rb"[A-Za-z ]*\|\s*([A-Za-z0-9_]+)\.tak", b)))
    stacks = b.count(b"AnimationStack")
    curves = b.count(b"AnimationCurveNode")
    return {"bytes": len(b), "anim_stacks": stacks, "anim_curve_nodes": curves,
            "takes": [t.decode() for t in takes]}


def glb_info(path):
    b = open(path, "rb").read()
    magic, ver, length = struct.unpack("<III", b[:12])
    off, js = 12, None
    while off + 8 <= len(b):
        clen, ctype = struct.unpack("<II", b[off:off + 8])
        if ctype == 0x4E4F534A:
            js = json.loads(b[off + 8:off + 8 + clen].decode("utf-8").rstrip("\x00 "))
            break
        off += 8 + clen
    anims = []
    for a in js.get("animations", []):
        anims.append({"name": a.get("name", ""), "channels": len(a.get("channels", []))})
    tris = 0
    for m in js.get("meshes", []):
        for p in m.get("primitives", []):
            if "indices" in p:
                tris += js["accessors"][p["indices"]]["count"] // 3
    skin = js.get("skins", [{}])
    return {"bytes": len(b), "glb_valid": magic == 0x46546C67 and length == len(b),
            "animations": anims, "tris": tris,
            "bones": len(skin[0].get("joints", [])) if skin and skin[0] else 0,
            "materials": len(js.get("materials", [])),
            "images": len(js.get("images", [])), "meshes": len(js.get("meshes", []))}


def clean_anim(name):
    """Mangled names repeat the armature prefix and can be cut at 64 chars."""
    parts = [p for p in re.split(r"[|]", name) if p.strip()]
    uniq = []
    for p in parts:
        if p not in uniq:
            uniq.append(p)
    # drop pure-prefix parts that also prefix another part
    core = [p for p in uniq if not any(q != p and q.startswith(p) for q in uniq)]
    return core[-1] if core else name


def main():
    strict = json.load(open(os.path.join(SCRAPE, "models_strict.json")))
    os.makedirs(OUT, exist_ok=True)
    manifest, seen = [], set()
    for r in strict:
        pid = r["publicID"]
        if pid in seen:
            continue
        seen.add(pid)
        meta = None
        if not r.get("licence") or r.get("licence") == "?":
            meta = page_meta(pid)
            time.sleep(1.2)
        folder = f"{slug(r['title'])}_{pid}"
        d = os.path.join(OUT, folder)
        os.makedirs(d, exist_ok=True)

        glb_path = os.path.join(d, folder + ".glb")
        shutil.copyfile(r["glb"], glb_path)
        fbx_path = os.path.join(d, folder + ".fbx")
        if not os.path.exists(fbx_path):
            zdata = fetch(f"{CDN}/{r['s3id']}.zip")
            z = zipfile.ZipFile(io.BytesIO(zdata))
            member = [n for n in z.namelist() if n.lower().endswith(".fbx")][0]
            open(fbx_path, "wb").write(z.read(member))

        g = glb_info(glb_path)
        f = fbx_check(fbx_path)
        names = [a["name"] for a in g["animations"]]
        roles = {k: [n for n in names if p.search(n)] for k, p in PAT.items()}
        entry = {
            "folder": folder,
            "title": r["title"],
            "publicID": pid,
            "page": "https://poly.pizza/m/" + pid,
            "creator": (meta or {}).get("creator") or r.get("creator", "Quaternius"),
            "licence": (meta or {}).get("licence") or r.get("licence"),
            "pack": r.get("pack"),
            "tris": g["tris"],
            "bones": g["bones"],
            "materials": g["materials"],
            "files": {"fbx": os.path.basename(fbx_path), "glb": os.path.basename(glb_path),
                      "fbx_bytes": f["bytes"], "glb_bytes": g["bytes"]},
            "animation_count": len(g["animations"]),
            "animations": [{"name": a["name"], "clean": clean_anim(a["name"]),
                            "channels": a["channels"]} for a in g["animations"]],
            "required": {k: roles[k] for k in ("hit", "death", "run")},
            "required_clean": {k: [clean_anim(n) for n in roles[k]] for k in roles},
            "fbx_anim_stacks": f["anim_stacks"],
            "fbx_curve_nodes": f["anim_curve_nodes"],
            "fbx_takes": f["takes"],
            "checks": {
                "glb_valid": g["glb_valid"],
                "skinned": g["bones"] > 0,
                "animations_present": len(g["animations"]) > 0,
                "all_animations_have_channels": all(a["channels"] > 0 for a in g["animations"]),
                "fbx_has_animation": f["anim_stacks"] > 0 and f["anim_curve_nodes"] > 0,
            },
        }
        json.dump(entry, open(os.path.join(d, "model.json"), "w"), indent=2)
        manifest.append(entry)
        print(f"{folder:34s} an={entry['animation_count']:2d} tris={entry['tris']:5d} "
              f"bones={entry['bones']:2d} fbx={f['anim_stacks']}/{f['anim_curve_nodes']} {entry['licence']}")

    json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=2)

    with open(os.path.join(OUT, "animations.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["folder", "title", "publicID", "hit", "death", "run", "animation_count",
                    "tris", "bones", "licence", "page"])
        for e in manifest:
            w.writerow([e["folder"], e["title"], e["publicID"],
                        ";".join(e["required_clean"]["hit"]),
                        ";".join(e["required_clean"]["death"]),
                        ";".join(e["required_clean"]["run"]),
                        e["animation_count"], e["tris"], e["bones"], e["licence"], e["page"]])
    print(f"\nwrote {len(manifest)} mobs to {OUT}")


if __name__ == "__main__":
    main()
