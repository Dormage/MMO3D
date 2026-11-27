#!/usr/bin/env python3
"""Retry rate-limited pages and classify animations robustly (names may be truncated at 64 chars)."""
import json, os, re, struct, time, urllib.request

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
SCRAPE = os.path.join(WS, "_scrape")
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36"


def fetch(url, dest=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        d = r.read()
    if dest:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        open(dest, "wb").write(d)
    return d


def page_meta(pid):
    h = fetch("https://poly.pizza/m/" + pid).decode("utf-8", "replace")
    m = re.search(r"window\.__SERVER_APP_STATE__\s*=\s*(\{.*?\});?\s*</script>", h, re.S)
    d = json.loads(m.group(1))["initialData"]["model"]
    return {"title": d["Title"], "s3id": d["ResourceID"], "animated": d.get("Animated"),
            "type": d.get("Type"), "licence": d.get("Licence"), "tris": d.get("Tris"),
            "creator": d["Creator"]["Username"], "tags": d.get("Tags")}


def glb_info(path):
    b = open(path, "rb").read()
    magic, ver, length = struct.unpack("<III", b[:12])
    assert magic == 0x46546C67, "not glb"
    assert length == len(b), f"truncated {len(b)}/{length}"
    off, js = 12, None
    while off + 8 <= len(b):
        clen, ctype = struct.unpack("<II", b[off:off + 8])
        if ctype == 0x4E4F534A:
            js = json.loads(b[off + 8:off + 8 + clen].decode("utf-8").rstrip("\x00 "))
            break
        off += 8 + clen
    anims = []
    for a in js.get("animations", []):
        ch = len(a.get("channels", []))
        anims.append({"name": a.get("name", ""), "channels": ch})
    tris = 0
    for m in js.get("meshes", []):
        for p in m.get("primitives", []):
            if "indices" in p:
                tris += js["accessors"][p["indices"]]["count"] // 3
    return {"animations": anims, "tris": tris, "skins": len(js.get("skins", [])),
            "images": len(js.get("images", [])), "nodes": len(js.get("nodes", [])),
            "materials": len(js.get("materials", []))}


PAT = {
    "hit": re.compile(r"hit", re.I),
    "death": re.compile(r"death|dead|\bdie\b|\bdea\b", re.I),
    "run": re.compile(r"(^|\||_|\b)run2?($|\||\b)|running", re.I),
    "walk": re.compile(r"walk", re.I),
    "fly": re.compile(r"fly", re.I),
    "swim": re.compile(r"swim", re.I),
}


def roles(anims):
    names = [a["name"] for a in anims]
    out = {k: [n for n in names if p.search(n)] for k, p in PAT.items()}
    return out


def retry():
    fixes = {}
    for pid in ["sN18LyyHAU", "KiNAaBa4cK"]:
        for attempt in range(4):
            try:
                meta = page_meta(pid)
                gp = os.path.join(SCRAPE, "glb2", pid + ".glb")
                fetch(f"https://static.poly.pizza/{meta['s3id']}.glb", gp)
                meta.update(glb_info(gp))
                fixes[pid] = meta
                print("ok", pid, meta["title"], len(meta["animations"]))
                break
            except Exception as e:
                print("retry", pid, attempt, repr(e)[:80])
                time.sleep(5 * (attempt + 1))
    json.dump(fixes, open(os.path.join(SCRAPE, "manifest_fix.json"), "w"), indent=1)


if __name__ == "__main__":
    retry()
