#!/usr/bin/env python3
"""Stage 3: enumerate every animated model poly.pizza exposes, inspect clips, find hit+death+run."""
import json, os, re, struct, time, urllib.error, urllib.request, concurrent.futures

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
SCRAPE = os.path.join(WS, "_scrape")
CDN = "https://static.poly.pizza"
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36"}
PAT = {
    "hit": re.compile(r"hit", re.I),
    "death": re.compile(r"death|dead|\bdie\b|\bdea\b", re.I),
    "run": re.compile(r"(^|[|_\s])run2?($|[|_\s])|running", re.I),
    "walk": re.compile(r"walk", re.I),
    "fly": re.compile(r"fly", re.I),
    "swim": re.compile(r"swim", re.I),
}


def get_json(url, tries=5):
    for i in range(tries):
        try:
            r = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(r, timeout=40) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(5 * (i + 1))
                continue
            raise
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(3 * (i + 1))
    return None


def get_bytes(url, tries=4):
    for i in range(tries):
        try:
            r = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(r, timeout=90) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            if e.code in (429, 503):
                time.sleep(5 * (i + 1))
                continue
            raise
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(3 * (i + 1))
    return None


def enumerate_animated():
    out, page = [], 0
    while page < 40:
        try:
            d = get_json(f"https://poly.pizza/api/explore?anim=1&Page={page}")
        except urllib.error.HTTPError as e:
            print(f"page {page}: stopped ({e.code})")
            break
        res = (d or {}).get("results") or []
        if not res:
            break
        out.extend(res)
        page += 1
    return out


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
    if js is None:
        return None
    anims = [a.get("name", "") for a in js.get("animations", [])]
    tris = 0
    for m in js.get("meshes", []):
        for p in m.get("primitives", []):
            if "indices" in p:
                tris += js["accessors"][p["indices"]]["count"] // 3
    skins = js.get("skins", [])
    return {"animations": anims, "tris": tris, "skins": len(skins),
            "bones": len(skins[0].get("joints", [])) if skins else 0,
            "valid": magic == 0x46546C67 and length == len(b)}


def work(c):
    pid = c["publicID"]
    out = dict(c)
    try:
        d = get_json(f"https://poly.pizza/api/model/{pid}/details")
        if not d or not d.get("ResourceID"):
            out["error"] = "no details/resource id"
            return out
        out.update({"title": d.get("Title"), "s3id": d.get("ResourceID"),
                    "licence": d.get("Licence"),
                    "creator": (d.get("Creator") or {}).get("Username"),
                    "tags": d.get("Tags"), "type": d.get("Type")})
        gp = os.path.join(SCRAPE, "site_glb", pid + ".glb")
        os.makedirs(os.path.dirname(gp), exist_ok=True)
        if not os.path.exists(gp):
            data = get_bytes(f"{CDN}/{d['ResourceID']}.glb")
            if not data:
                out["error"] = "download failed"
                return out
            open(gp, "wb").write(data)
        info = glb_info(gp)
        if not info:
            out["error"] = "bad glb"
            return out
        out.update(info)
        out["flags"] = {k: bool([n for n in info["animations"] if p.search(n)])
                        for k, p in PAT.items()}
        out["glb"] = gp
    except Exception as e:
        out["error"] = repr(e)[:140]
    return out


def main():
    listed = enumerate_animated()
    print(f"animated models listed by explore: {len(listed)}")
    known = set()
    for fn in ("models_all.json", "site_models.json"):
        p = os.path.join(SCRAPE, fn)
        if os.path.exists(p):
            data = json.load(open(p))
            if isinstance(data, dict):
                for v in data.values():
                    known.add(v.get("publicID"))
            else:
                for r in data:
                    known.add(r.get("publicID"))
    cands, seen = [], set()
    for r in listed:
        pid = r.get("publicID")
        if not pid or pid in known or pid in seen:
            continue
        seen.add(pid)
        cands.append({"publicID": pid, "title": r.get("title"),
                      "creator": (r.get("creator") or {}).get("username"),
                      "licence": r.get("licence"), "page": "https://poly.pizza/m/" + pid})
    print(f"already inspected: {len(known)}, to inspect now: {len(cands)}")
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:
        res = list(ex.map(work, cands))
    json.dump(res, open(os.path.join(SCRAPE, "site_rest.json"), "w"), indent=1)
    ok = [r for r in res if (r.get("flags") or {}).get("hit") and (r.get("flags") or {}).get("death")
          and (r.get("flags") or {}).get("run")]
    print(f"\nnewly inspected: {len(res)}, qualify: {len(ok)}")
    for r in ok:
        print(f"  HDR {str(r.get('title'))[:28]:28s} {r['publicID']} an={len(r['animations']):2d} "
              f"tris={r['tris']:5d} {str(r.get('licence')):10s} {r.get('creator')}")


if __name__ == "__main__":
    main()
