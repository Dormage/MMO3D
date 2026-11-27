#!/usr/bin/env python3
"""Write excluded.csv (with reasons) and README.md for the delivered mob pack."""
import csv, json, os, re

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
OUT = os.path.join(WS, "mobs")
SCRAPE = os.path.join(WS, "_scrape")

rows = json.load(open(os.path.join(SCRAPE, "models_all.json")))
manifest = json.load(open(os.path.join(OUT, "manifest.json")))
kept = {e["publicID"] for e in manifest}


def locomotion(f):
    if f["run"]:
        return "run"
    if f["walk"]:
        return "walk only"
    if f["fly"]:
        return "flight only"
    if f["swim"]:
        return "swim only"
    return "no locomotion clip"


with open(os.path.join(OUT, "excluded.csv"), "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["title", "publicID", "has_hit", "has_death", "locomotion", "animation_count",
                "reason_excluded", "page"])
    for r in sorted(rows, key=lambda x: x["title"].lower()):
        if r["publicID"] in kept:
            continue
        missing = [k for k in ("hit", "death") if not r["has"][k]]
        loco = locomotion(r["flags"])
        reason = []
        if "hit" in missing:
            reason.append("no hit clip")
        if "death" in missing:
            reason.append("no death clip")
        if not r["has"]["run"]:
            reason.append(f"no run clip ({loco})")
        w.writerow([r["title"], r["publicID"], r["has"]["hit"], r["has"]["death"], loco,
                    len(r["animations"]), "; ".join(reason), r["page"]])

cc0 = sum(1 for e in manifest if (e["licence"] or "").startswith("CC0"))
ccby = [e for e in manifest if (e["licence"] or "").startswith("CC-BY")]
bundle = [e for e in manifest if e["pack"] == "Ultimate Monsters Bundle"]
catalog = [e for e in manifest if e["pack"] != "Ultimate Monsters Bundle"]
total_tris = sum(e["tris"] for e in manifest)
clip_min = min(len(e["glb_clips"]) for e in manifest)
clip_max = max(len(e["glb_clips"]) for e in manifest)
biggest = max(manifest, key=lambda e: e["tris"])
smallest = min(manifest, key=lambda e: e["tris"])

readme = f"""# Mob library: {len(manifest)} rigged mobs with hit, death and run

Source is poly.pizza, starting from the Dragon Evolved page
(https://poly.pizza/m/LlwD0QNUPj), which belongs to Quaternius' Ultimate Monsters Bundle.
The crawl covered that bundle (45 models), the two enemy packs (9 models), and a
keyword sweep of all {len(rows)} creature-like models in Quaternius' catalogue.

{len(manifest)} of the {len(rows)} inspected models have a hit reaction, a death clip and a run clip.
The rest are listed in excluded.csv with the reason.

## Layout

```
mobs/
  manifest.json        every mob: animations, bone count, tri count, licence, source page
  animations.csv       hit/death/run clip names per mob
  excluded.csv         inspected models that failed the criteria, with reasons
  <Name>_<id>/
    <Name>_<id>.fbx    original upload, animation takes, embedded materials
    <Name>_<id>.glb    glTF 2.0 conversion by poly.pizza
    model.json         this mob's metadata and clip names
```

Both formats hold the same animation set. The FBX opens in Unity and Unreal.
The GLB opens in Godot, Blender, three.js and any glTF viewer.

## Requirements check

Every folder has a hit reaction, a death clip and a run clip. Clip names differ
by rig family:

- CharacterArmature rigs use `HitReact`, `Death`, `Run`.
- Older monster rigs use `HitRecieve` (spelled that way in the source), `Death`, `Run`.
- A few humanoids and zombies add variants: `Run_Gun`, `Run_Arms`, `HitRecieve_2`, `Death_2`.

`animations.csv` lists the exact clip name for each mob. Clip names are not renamed
inside the files, so imports stay identical to the source upload.

## Scale of the set

Total {total_tris:,} triangles across all mobs. Smallest is {smallest['title']}
({smallest['tris']:,} tris), largest is {biggest['title']} ({biggest['tris']:,} tris).
Bone counts run from 12 (simple monsters) to 62 (Soldier). Each mob carries {clip_min} to {clip_max}
unique clips. manifest.json lists them under glb_clips, and animation_count is the raw
count of animation entries in the GLB, which repeats each clip once with and once without
the armature prefix in some uploads.

{bundle.__len__()} mobs come from the Ultimate Monsters Bundle, {catalog.__len__()} from elsewhere in
the same catalogue (enemy packs, robots, zombies, skeletons, soldiers).

## Licence

{cc0} models are CC0 1.0. {ccby.__len__()} are CC-BY 3.0 and need visible credit to Quaternius:

{chr(10).join('- ' + e['title'] + ' (' + e['page'] + ')' for e in ccby)}

Licence and creator for each mob is in its model.json and in manifest.json.

## Validation

Each GLB was parsed after download: container length matches, one skinned mesh with a
joint list, and every animation carries at least one channel. Each FBX was checked for
`AnimationStack` and `AnimationCurveNode` records plus its take names, which match the
GLB clip names. FBX take names were reconciled with GLB clip names for all {len(manifest)} mobs: the unique
clip sets match in both formats with no differences.

Three uploads (Pirate_Captain, both large Skeletons) have clip names truncated at 64
characters in the source itself, so `CharacterArmature|...|Death|CharacterArmature|Dea`
appears in the file. The `clean` field in manifest.json gives the readable name.

Scripts that produced this set are in `_scrape/` (crawl.py, crawl_extra.py, retry.py,
select.py, finalize.py).
"""
open(os.path.join(OUT, "README.md"), "w").write(readme)
print(readme[:1200])
