#!/usr/bin/env python3
"""Download the sitewide qualifiers not yet delivered into mobs_extra/."""
import csv, io, json, os, re, shutil, struct, time, urllib.request, zipfile

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
SCRAPE = os.path.join(WS, "_scrape")
OUT = os.path.join(WS, "mobs_extra")
CDN = "https://static.poly.pizza"
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36"}
PAT = {
    "hit": re.compile(r"hit", re.I),
    "death": re.compile(r"death|dead|\bdie\b|\bdea\b", re.I),
    "run": re.compile(r"(^|[|_\s])run2?($|[|_\s])|running", re.I),
}


def get_bytes(url, tries=4):
    for i in range(tries):
        try:
            r = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(r, timeout=90) as resp:
                return resp.read()
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(3 * (i + 1))


def slug(t):
    s = re.sub(r"[^A-Za-z0-9]+", "_", str(t)).strip("_")
    return s or "mob"


def tail(name):
    parts = [p for p in name.split("|") if p.strip()]
    return parts[-1] if parts else name


def clean_anim(name):
    parts = []
    for p in name.split("|"):
        if p.strip() and p not in parts:
            parts.append(p)
    core = [p for p in parts if not any(q != p and q.startswith(p) for q in parts)]
    return core[-1] if core else name


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
    anims = [a.get("name", "") for a in js.get("animations", [])]
    tris = 0
    for m in js.get("meshes", []):
        for p in m.get("primitives", []):
            if "indices" in p:
                tris += js["accessors"][p["indices"]]["count"] // 3
    skins = js.get("skins", [])
    return {"animations": anims, "tris": tris, "bones": len(skins[0].get("joints", [])) if skins else 0,
            "valid": magic == 0x46546C67 and length == len(b)}


def fbx_takes(path):
    b = open(path, "rb").read()
    raw = sorted(set(re.findall(rb"([ -~]{2,140}?)\.tak", b)))
    return [r.decode() for r in raw], b.count(b"AnimationStack"), b.count(b"AnimationCurveNode")


def bucket(title):
    t = str(title).lower()
    if re.search(r"monster|enemy|orc|goblin|zombie|skeleton|demon|slime|spider|dragon|frog|rat\b|"
                 r"wasp|crab|bee\b|ghost|mech|robot|giant|golem|yeti|troll|worm|snake|dino|alien|"
                 r"mutant|undead|hydra|wyvern|scorpion|blob|skull|sharky", t):
        return "mob"
    if re.search(r"panda|rabbit|dog|shepard|cat\b|cow|donkey|deer|alpaca|bull|fox|shiba|stag|husky|"
                 r"wolf|horse|pug|animal|bird|pigeon|chicken|fish|bunny", t):
        return "animal"
    return "character"


def main():
    q = json.load(open(os.path.join(SCRAPE, "site_qualified.json")))
    have = {e["publicID"] for e in json.load(open(os.path.join(WS, "mobs", "manifest.json")))}
    todo = [r for r in q if r["publicID"] not in have]
    os.makedirs(OUT, exist_ok=True)
    print(f"qualified sitewide: {len(q)}, already delivered: {len(have)}, to fetch: {len(todo)}")
    man = []
    for r in todo:
        pid = r["publicID"]
        folder = f"{slug(r.get('title'))}_{pid}"
        d = os.path.join(OUT, folder)
        os.makedirs(d, exist_ok=True)
        cache = r.get("glb") or os.path.join(SCRAPE, "site_glb", pid + ".glb")
        glb_path = os.path.join(d, folder + ".glb")
        if os.path.exists(cache):
            shutil.copyfile(cache, glb_path)
        else:
            open(glb_path, "wb").write(get_bytes(f"{CDN}/{r['s3id']}.glb"))
        fbx_path = os.path.join(d, folder + ".fbx")
        if not os.path.exists(fbx_path):
            z = zipfile.ZipFile(io.BytesIO(get_bytes(f"{CDN}/{r['s3id']}.zip")))
            member = [n for n in z.namelist() if n.lower().endswith(".fbx")][0]
            open(fbx_path, "wb").write(z.read(member))
            time.sleep(0.4)
        g = glb_info(glb_path)
        takes, stacks, curves = fbx_takes(fbx_path)
        names = g["animations"]
        roles = {k: [n for n in names if p.search(n)] for k, p in PAT.items()}
        clips = sorted({clean_anim(n) for n in names})
        entry = {
            "folder": folder, "title": r.get("title"), "publicID": pid,
            "page": "https://poly.pizza/m/" + pid,
            "creator": r.get("creator"), "licence": r.get("licence"),
            "bucket": bucket(r.get("title")),
            "tris": g["tris"], "bones": g["bones"],
            "files": {"fbx": os.path.basename(fbx_path), "glb": os.path.basename(glb_path),
                      "fbx_bytes": os.path.getsize(fbx_path), "glb_bytes": os.path.getsize(glb_path)},
            "animation_count": len(names), "clips": clips,
            "animations": [{"name": n, "clean": clean_anim(n)} for n in names],
            "required": {k: [clean_anim(n) for n in v] for k, v in roles.items()},
            "fbx_takes": takes, "fbx_anim_stacks": stacks, "fbx_curve_nodes": curves,
            "checks": {"glb_valid": g["valid"], "skinned": g["bones"] > 0,
                       "all_have_channels": all(len(n) > 0 for n in names),
                       "fbx_has_animation": stacks > 0 and curves > 0},
        }
        json.dump(entry, open(os.path.join(d, "model.json"), "w"), indent=2)
        man.append(entry)
        print(f"  {folder[:34]:34s} {entry['bucket']:9s} an={len(names):2d} tris={entry['tris']:5d} "
              f"{str(entry['licence']):10s} {entry['creator']}")

    json.dump(man, open(os.path.join(OUT, "manifest.json"), "w"), indent=2)
    with open(os.path.join(OUT, "animations.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["folder", "title", "bucket", "creator", "licence", "hit", "death", "run",
                    "clips", "tris", "bones", "page"])
        for e in man:
            w.writerow([e["folder"], e["title"], e["bucket"], e["creator"], e["licence"],
                        ";".join(e["required"]["hit"]), ";".join(e["required"]["death"]),
                        ";".join(e["required"]["run"]), len(e["clips"]), e["tris"], e["bones"], e["page"]])
    print(f"\nwrote {len(man)} entries to {OUT}")


if __name__ == "__main__":
    main()
