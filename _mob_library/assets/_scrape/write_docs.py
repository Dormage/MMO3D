#!/usr/bin/env python3
"""Write mobs_extra/README.md and a root README covering both collections."""
import collections, csv, json, os

WS = "/home/vake/Sloth/Stuff/ASSETS/3d/assets"
base = json.load(open(os.path.join(WS, "mobs", "manifest.json")))
extra = json.load(open(os.path.join(WS, "mobs_extra", "manifest.json")))
allrows = base + extra
ccby = [e for e in allrows if "BY" in (e["licence"] or "")]
import re as _re
def _bucket(title):
    t = str(title).lower()
    if _re.search(r"monster|enemy|orc|goblin|zombie|skeleton|demon|slime|spider|dragon|frog|rat\b|"
                  r"wasp|crab|bee\b|ghost|mech|robot|giant|golem|yeti|troll|worm|snake|dino|alien|"
                  r"mutant|undead|hydra|wyvern|scorpion|blob|skull|sharky", t):
        return "mob"
    if _re.search(r"panda|rabbit|dog|shepard|cat\b|cow|donkey|deer|alpaca|bull|fox|shiba|stag|husky|"
                  r"wolf|horse|pug|animal|bird|pigeon|chicken|fish|bunny", t):
        return "animal"
    return "character"
for e in base:
    e["bucket"] = _bucket(e["title"])
buckets = collections.Counter(e.get("bucket") or "mob" for e in allrows)
xbuckets = collections.Counter(e.get("bucket") or "mob" for e in extra)
total_tris = sum(e["tris"] for e in allrows)
base_tris = sum(e["tris"] for e in base)
extra_tris = sum(e["tris"] for e in extra)
clip_min = min(len(e.get("clips") or e.get("glb_clips") or []) for e in allrows)
clip_max = max(len(e.get("clips") or e.get("glb_clips") or []) for e in allrows)

credit = "\n".join(f"- {e['title']}, {e['creator']} ({e['page']})" for e in ccby)

readme_extra = f"""# Extra mobs: {len(extra)} rigged models from the rest of poly.pizza

These are the animated models outside the monster and enemy packs that still carry a hit
reaction, a death clip and a run clip. Every one was found by the sitewide sweep described
in the parent README.

## Layout

Each folder holds the original FBX, the GLB conversion and a model.json with clip names:

```
mobs_extra/
  manifest.json      clip names, tri count, bone count, licence, source page
  animations.csv     hit, death and run clip name per model
  <Name>_<id>/
    <Name>_<id>.fbx
    <Name>_<id>.glb
    model.json
```

## What is in here

{xbuckets['mob']} are enemy or creature rigs: four mechs, a giant, a shark character and a
third zombie from another creator. {xbuckets['character']} are humanoid NPC rigs (workers, astronauts, adventurers,
soldiers, punks, a king, witches). {xbuckets['animal']} are animals (panda, rabbits, dogs).

The bucket in each model.json comes from the model title, so treat it as a rough label.
Rigs sharing the same skeleton (the 24 clip character set) let you swap models on one
animation set.

## Licence

{sum(1 for e in extra if e['licence'].startswith('CC0'))} are CC0 1.0, {len([e for e in extra if 'BY' in e['licence']])} are CC-BY 3.0 and need credit.
Every model records its licence and creator in model.json.
"""
open(os.path.join(WS, "mobs_extra", "README.md"), "w").write(readme_extra)

root = f"""# poly.pizza mob library: {len(allrows)} animated rigs with hit, death and run

The request started at https://poly.pizza/m/LlwD0QNUPj (Dragon Evolved by Quaternius) and
asked for every animated mob that has at least a hit, a death and a run clip.

## What the crawl covered

The Dragon Evolved page belongs to Quaternius' Ultimate Monsters Bundle. poly.pizza
exposes packs and models through its API:

- `/api/user/Quaternius` returned 1,411 models and 48 packs, each pack listing a public id
  and a CDN id for every model.
- `/api/model/<id>/details` returns one model record with its CDN id, tri count and licence.
- `/api/explore?anim=1&Page=N` lists the animated models on the site, 32 per page.

The mob packs were crawled first: Ultimate Monsters Bundle (45 models), Animated Enemies
(5) and Enemies Pack (4). A keyword sweep over the 1,411 Quaternius models added robots,
zombies, skeletons and soldiers outside those packs. The sitewide pass then enumerated all
{371} animated models the explore endpoint serves, pages 0 to 11.

## Result

{len(allrows)} models of the {371} animated models on the site have a hit reaction, a death clip and a run
clip. All {len(allrows)} are downloaded, in two folders:

```
mobs/         {len(base)} monster and enemy rigs from the mob packs      {base_tris:,} tris
mobs_extra/   {len(extra)} rigs from the rest of the site                  {extra_tris:,} tris
```

By type: {buckets['mob']} creature or enemy rigs, {buckets['animal']} animals, {buckets['character']} humanoid NPC rigs.
Total {total_tris:,} triangles. Clip counts per rig run from {clip_min} to {clip_max}.

Every folder has the model as FBX (original upload, animation takes, embedded materials)
and as GLB (glTF 2.0 conversion), plus a model.json with the exact clip names:

| clip role | names in the files |
|---|---|
| hit | HitReact, HitRecieve, HitRecieve_2 |
| death | Death, Death_2 |
| run | Run, Run2, Run_Gun, Run_Shoot, Run_Arms, Run_Attack, Run_Back, Run_Left |

Each collection has a manifest.json, an animations.csv and a README. mobs/excluded.csv
lists the inspected models that failed, with the reason.

## Models that failed the criteria

The dragon from the starting page has Death and HitReact but no run. It flies instead, with
Fast_Flying and Flying_Idle, so it fails. The same applies to the other flying rigs
(Alpaking, Armabee, Glub, Goleling, Hywirl, Ghost, Squidle, Tribal, Enemy Flying, Enemy
Small, Bat, both Dragons). Nineteen more mobs have Walk but no Run. The 290 animated models
that failed are listed with reasons in mobs/excluded.csv where they were inspected.

## Licence

{sum(1 for e in allrows if (e['licence'] or '').startswith('CC0'))} of {len(allrows)} are CC0 1.0. {len(ccby)} are CC-BY 3.0 and need visible credit:

{credit}

## Validation

Every GLB was parsed after download: container length matches the header, the file holds one
skinned mesh with a joint list, and every animation carries at least one channel. Every FBX
was checked for AnimationStack and AnimationCurveNode records. In mobs/, FBX take names and
GLB clip names were reconciled per model and the unique clip sets match for all {len(base)}.

Three uploads (Pirate Captain, both large Skeletons) carry clip names truncated at 64
characters by the source pipeline, so a name can end in `...|Dea`. The `clean` field in
manifest.json holds the readable name. Clip names inside the files were not changed.

## Limits of this crawl

The explore endpoint stops answering at page 12 without a login (HTTP 401), so models
behind that wall were not enumerated. Search results are capped near 45 per query, which
is why the search pass alone undercounted. Scripts for every stage are in `_scrape/`.
"""
open(os.path.join(WS, "README.md"), "w").write(root)
print(root[:900])
print("...\n")
print(readme_extra[:700])
