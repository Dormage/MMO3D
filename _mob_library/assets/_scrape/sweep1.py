#!/usr/bin/env python3
"""Stage 1: collect sitewide animated mob candidates from poly.pizza search."""
import json, os, time, urllib.error, urllib.parse, urllib.request, concurrent.futures

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
SCRAPE = os.path.join(WS, "_scrape")
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36"}

QUERIES = ["monster", "enemy", "creature", "zombie", "skeleton", "goblin", "orc", "slime",
           "demon", "ghost", "robot", "alien", "dragon", "mutant", "undead", "troll",
           "beast", "spider", "bat", "worm", "fish monster", "boss", "imp", "reaper",
           "necromancer", "ogre", "knight enemy", "guard enemy", "turret enemy", "crab",
           "wasp", "rat", "frog", "wolf", "bear", "golem", "hydra", "wyvern", "scorpion",
           "insect", "spirit", "vampire", "werewolf", "snake"]


def get(url, tries=5):
    for i in range(tries):
        try:
            r = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(r, timeout=40) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(4 * (i + 1))
                continue
            raise
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(2 * (i + 1))
    return None


def query_pages(q, max_pages=6):
    out, seen = [], set()
    for page in range(max_pages):
        d = get(f"https://poly.pizza/api/search/{urllib.parse.quote(q)}?anim=1&Page={page}")
        if not d:
            break
        res = d.get("results") or []
        if not res:
            break
        new = 0
        for r in res:
            pid = r.get("publicID")
            if pid and pid not in seen:
                seen.add(pid)
                r["query"] = q
                out.append(r)
                new += 1
        if new == 0:
            break
        if len(out) >= (d.get("count") or 0):
            break
    return out


def main():
    known = set()
    for fn in ("models_all.json",):
        for r in json.load(open(os.path.join(SCRAPE, fn))):
            known.add(r["publicID"])
    cands, seen = [], set()
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:
        for q, res in zip(QUERIES, ex.map(query_pages, QUERIES)):
            added = 0
            for r in res:
                pid = r["publicID"]
                if pid in seen or pid in known:
                    continue
                seen.add(pid)
                cands.append({"publicID": pid, "title": r.get("title"),
                              "creator": (r.get("creator") or {}).get("username"),
                              "licence": r.get("licence"), "query": q,
                              "page": "https://poly.pizza/m/" + pid})
                added += 1
            print(f"{q:16s} results={len(res):3d} new={added:3d}")
    json.dump(cands, open(os.path.join(SCRAPE, "site_candidates.json"), "w"), indent=1)
    print(f"\nnew candidates to inspect: {len(cands)}")


if __name__ == "__main__":
    main()
