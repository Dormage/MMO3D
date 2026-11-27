#!/usr/bin/env python3
"""Crawl Quaternius mob packs on poly.pizza, download assets, check animations."""
import json, os, re, struct, sys, urllib.request, concurrent.futures, hashlib

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
SCRAPE = os.path.join(WS, "_scrape")
CDN = "https://static.poly.pizza"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36"

BUNDLES = [
    "Ultimate Monsters Bundle",
    "Animated Enemies",
    "Enemies Pack",
]


def fetch(url, dest=None, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
    if dest:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
    return data


def glb_animations(path):
    """Return list of animation names from a .glb without external deps."""
    b = open(path, "rb").read()
    if len(b) < 12:
        return None
    magic, ver, length = struct.unpack("<III", b[:12])
    if magic != 0x46546C67:
        return None
    off, js = 12, None
    total = min(length, len(b))
    while off + 8 <= total:
        clen, ctype = struct.unpack("<II", b[off:off + 8])
        chunk = b[off + 8:off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk.decode("utf-8").rstrip("\x00 "))
            break
        off += 8 + clen
    if js is None:
        return None
    return [a.get("name", "") for a in js.get("animations", [])]


def glb_stats(path):
    b = open(path, "rb").read()
    magic, ver, length = struct.unpack("<III", b[:12])
    off = 12
    while off + 8 <= len(b):
        clen, ctype = struct.unpack("<II", b[off:off + 8])
        if ctype == 0x4E4F534A:
            js = json.loads(b[off + 8:off + 8 + clen].decode("utf-8").rstrip("\x00 "))
            tris = 0
            for m in js.get("meshes", []):
                for p in m.get("primitives", []):
                    acc = js["accessors"][p["indices"]] if "indices" in p else None
                    if acc:
                        tris += acc["count"] // 3
            return tris, len(js.get("skins", []))
        off += 8 + clen
    return 0, 0


def classify(names):
    """Map animation names to roles: hit, death, run."""
    roles = {"hit": [], "death": [], "run": [], "other": []}
    for n in names:
        tail = n.split("|")[-1].lower().replace("_", "").replace(" ", "")
        if re.search(r"hit|damage|hurt|takehit", tail):
            roles["hit"].append(n)
        elif re.search(r"death|die|dying|dead", tail):
            roles["death"].append(n)
        elif re.search(r"run|sprint|gallop|swim|fly", tail):
            roles["run"].append(n)
        else:
            roles["other"].append(n)
    return roles


def main():
    state = json.load(open(os.path.join(SCRAPE, "u_q.json")))
    titles = {m["publicID"]: m["title"] for m in state["models"]}
    seen, candidates = set(), []
    for l in state["lists"]:
        if l["Name"] in BUNDLES:
            for m in l["Models"]:
                pid = m["PublicID"]
                if pid in seen:
                    continue
                seen.add(pid)
                candidates.append({
                    "publicID": pid,
                    "s3id": m["S3ID"],
                    "title": titles.get(pid, pid),
                    "pack": l["Name"],
                    "page": "https://poly.pizza/m/" + pid,
                })
    print(f"candidates: {len(candidates)}")

    rawdir = os.path.join(SCRAPE, "glb")
    os.makedirs(rawdir, exist_ok=True)

    def work(c):
        gp = os.path.join(rawdir, c["publicID"] + ".glb")
        try:
            if not os.path.exists(gp) or os.path.getsize(gp) < 1000:
                fetch(f"{CDN}/{c['s3id']}.glb", gp)
            anims = glb_animations(gp)
            tris, skins = glb_stats(gp)
            c["animations"] = anims or []
            c["tris"], c["skins"] = tris, skins
            c["glb_bytes"] = os.path.getsize(gp)
            c["glb_ok"] = anims is not None
        except Exception as e:
            c["animations"] = []
            c["glb_ok"] = False
            c["error"] = repr(e)[:200]
        c["roles"] = classify(c["animations"])
        c["has"] = {k: bool(v) for k, v in c["roles"].items()}
        return c

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(work, candidates))

    json.dump(results, open(os.path.join(SCRAPE, "manifest.json"), "w"), indent=1)

    ok = [r for r in results if all(r["has"].get(k) for k in ("hit", "death", "run"))]
    print(f"\nwith hit+death+run: {len(ok)} / {len(results)}")
    for r in sorted(results, key=lambda x: x["title"].lower()):
        flags = "".join(k[0].upper() if r["has"].get(k) else "-" for k in ("hit", "death", "run"))
        print(f"{flags:3s} {r['title'][:24]:24s} {r['publicID']} an={len(r['animations']):2d} "
              f"tris={r.get('tris',0):5d} {','.join(r['animations'][:1])[:30]}")


if __name__ == "__main__":
    main()
