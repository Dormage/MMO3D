#!/usr/bin/env python3
"""Merge crawl passes, classify animations on full names, print selection table."""
import json, os, re, struct

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
SCRAPE = os.path.join(WS, "_scrape")

PAT = {
    "hit": re.compile(r"hit", re.I),
    "death": re.compile(r"death|dead|\bdie\b|\bdea\b", re.I),
    "run": re.compile(r"(^|[|_\s])run2?($|[|_\s])|running", re.I),
    "walk": re.compile(r"walk", re.I),
    "fly": re.compile(r"fly", re.I),
    "swim": re.compile(r"swim", re.I),
}


def glb_info(path):
    b = open(path, "rb").read()
    magic, ver, length = struct.unpack("<III", b[:12])
    ok = magic == 0x46546C67 and length == len(b)
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
    return {"animations": anims, "tris": tris, "skins": len(js.get("skins", [])),
            "images": len(js.get("images", [])), "valid": ok,
            "bytes": len(b), "bones": len(js.get("skins", [{}])[0].get("joints", [])) if js.get("skins") else 0}


def load_pass1():
    out = {}
    for r in json.load(open(os.path.join(SCRAPE, "manifest.json"))):
        gp = os.path.join(SCRAPE, "glb", r["publicID"] + ".glb")
        if not os.path.exists(gp):
            continue
        info = glb_info(gp)
        out[r["publicID"]] = {
            "publicID": r["publicID"], "s3id": r["s3id"], "title": r["title"],
            "pack": r["pack"], "page": r["page"], "glb": gp, "source": "bundle",
            **info,
        }
    return out


def load_pass2():
    out = {}
    for fn in ("manifest_extra.json", "manifest_fix.json"):
        p = os.path.join(SCRAPE, fn)
        if not os.path.exists(p):
            continue
        data = json.load(open(p))
        if isinstance(data, dict):
            items = []
            for k, v in data.items():
                v = dict(v)
                v.setdefault("publicID", k)
                items.append(v)
        else:
            items = data
        for r in items:
            if not r.get("s3id") or not r.get("animations"):
                continue
            pid = r["publicID"]
            gp = os.path.join(SCRAPE, "glb2", pid + ".glb")
            if not os.path.exists(gp):
                continue
            info = glb_info(gp)
            out[pid] = {
                "publicID": pid, "s3id": r["s3id"], "title": r["title"],
                "pack": "catalog scan", "page": "https://poly.pizza/m/" + pid,
                "glb": gp, "source": "catalog", "licence": r.get("licence"),
                **info,
            }
    return out


def main():
    models = load_pass1()
    models.update(load_pass2())
    rows = []
    for pid, m in models.items():
        names = m["animations"]
        flags = {k: [n for n in names if p.search(n)] for k, p in PAT.items()}
        m["flags"] = flags
        m["has"] = {k: bool(flags[k]) for k in ("hit", "death", "run")}
        rows.append(m)

    rows.sort(key=lambda r: (not all(r["has"].values()), r["title"].lower()))
    strict = [r for r in rows if all(r["has"].values())]

    print(f"total inspected: {len(rows)}   strict hit+death+run: {len(strict)}\n")
    print(f"{'':4s} {'title':22s} {'id':11s} {'an':>3s} {'tris':>5s} {'walk':>4s} {'fly':>3s} licence  packs")
    for r in rows:
        f = "".join(k[0].upper() if r["has"][k] else "-" for k in ("hit", "death", "run"))
        print(f"{f:4s} {r['title'][:22]:22s} {r['publicID']:11s} {len(r['animations']):3d} "
              f"{r['tris']:5d} {len(r['flags']['walk']):4d} {len(r['flags']['fly']):3d} "
              f"{str(r.get('licence') or '?'):8s} {r['pack']}")

    json.dump(rows, open(os.path.join(SCRAPE, "models_all.json"), "w"), indent=1)
    json.dump(strict, open(os.path.join(SCRAPE, "models_strict.json"), "w"), indent=1)
    print(f"\nstrict ids: {' '.join(r['publicID'] for r in strict)}")


if __name__ == "__main__":
    main()
