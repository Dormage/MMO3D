#!/usr/bin/env python3
"""Second pass: resolve S3 ids for extra mob candidates from model pages, test animations."""
import json, os, re, struct, urllib.request, concurrent.futures

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
SCRAPE = os.path.join(WS, "_scrape")
CDN = "https://static.poly.pizza"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36"

EXTRA = [
    "QCm7qe9uNJ", "jkrEvQZb8J", "hNO9XvjlKa", "HvfIku26CK", "mdGe4IN31v",
    "PpLF4rt4ah", "IkB63XOPvr", "kzpT6fNmM5", "UgBmRVnQ9h", "4LjT020LQh",
    "OdCOFSmEhl", "1gNo5ezvmr", "lF3jeRJwiH", "UDTM6X1y9a", "mPDR0L5uKx",
    "mWojM4i2IH", "lFZfDh2hzP", "aOPA4hZeE9", "yq5ATpujSt", "1XZD9GK6Kj",
    "DM4QScSmbS", "wODZYCgX5Z", "LyjSUKHKnh", "XU7oNeKShV", "xtMYEVzyw0",
    "HYUUkdugoP", "VlXjG0N8Eg", "22K0aSZkHV", "JoBvxIUpZP", "Htcsn9OrXJ",
    "oAArCNHjFB", "sN18LyyHAU", "KiNAaBa4cK",
]


def fetch(url, dest=None, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
    if dest:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        open(dest, "wb").write(data)
    return data


def page_meta(pid):
    h = fetch("https://poly.pizza/m/" + pid).decode("utf-8", "replace")
    m = re.search(r"window\.__SERVER_APP_STATE__\s*=\s*(\{.*?\});?\s*</script>", h, re.S)
    if not m:
        return None
    d = json.loads(m.group(1))["initialData"]["model"]
    return {"title": d["Title"], "s3id": d["ResourceID"], "animated": d.get("Animated"),
            "type": d.get("Type"), "licence": d.get("Licence")}


def glb_animations(path):
    b = open(path, "rb").read()
    if len(b) < 12:
        return None
    magic, ver, length = struct.unpack("<III", b[:12])
    if magic != 0x46546C67:
        return None
    off = 12
    while off + 8 <= min(length, len(b)):
        clen, ctype = struct.unpack("<II", b[off:off + 8])
        if ctype == 0x4E4F534A:
            js = json.loads(b[off + 8:off + 8 + clen].decode("utf-8").rstrip("\x00 "))
            tris = 0
            for m in js.get("meshes", []):
                for p in m.get("primitives", []):
                    if "indices" in p:
                        tris += js["accessors"][p["indices"]]["count"] // 3
            return [a.get("name", "") for a in js.get("animations", [])], tris
        off += 8 + clen
    return None


def work(pid):
    out = {"publicID": pid, "page": "https://poly.pizza/m/" + pid}
    try:
        meta = page_meta(pid)
        if not meta:
            out["error"] = "no state"
            return out
        out.update(meta)
        gp = os.path.join(SCRAPE, "glb2", pid + ".glb")
        fetch(f"{CDN}/{meta['s3id']}.glb", gp)
        r = glb_animations(gp)
        if r is None:
            out["error"] = "bad glb"
            return out
        anims, tris = r
        out["animations"], out["tris"] = anims, tris
        tails = [a.split("|")[-1] for a in anims]
        out["has_hit"] = any("HitReact" in t or "HitRecieve" in t for t in tails)
        out["has_death"] = any("Death" in t for t in tails)
        out["has_run"] = any(t in ("Run", "Run2") or t.endswith("_Run") for t in tails)
        out["glb_bytes"] = os.path.getsize(gp)
    except Exception as e:
        out["error"] = repr(e)[:160]
    return out


def main():
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        res = list(ex.map(work, EXTRA))
    json.dump(res, open(os.path.join(SCRAPE, "manifest_extra.json"), "w"), indent=1)
    for r in res:
        f = "".join(x for x, k in (("H", "has_hit"), ("D", "has_death"), ("R", "has_run")) if r.get(k)) or "---"
        anims = ",".join(a.split("|")[-1] for a in r.get("animations", []))
        print(f"{f:3s} {str(r.get('title'))[:26]:26s} {r['publicID']} an={len(r.get('animations',[])):2d} "
              f"tris={r.get('tris',0):5d} {r.get('error','')} [{anims[:70]}]")


if __name__ == "__main__":
    main()
