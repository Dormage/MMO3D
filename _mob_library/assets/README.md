# poly.pizza mob library: 81 animated rigs with hit, death and run

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
371 animated models the explore endpoint serves, pages 0 to 11.

## Result

81 models of the 371 animated models on the site have a hit reaction, a death clip and a run
clip. All 81 are downloaded, in two folders:

```
mobs/         28 monster and enemy rigs from the mob packs      211,190 tris
mobs_extra/   53 rigs from the rest of the site                  361,468 tris
```

By type: 26 creature or enemy rigs, 10 animals, 45 humanoid NPC rigs.
Total 572,658 triangles. Clip counts per rig run from 7 to 36.

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

69 of 81 are CC0 1.0. 12 are CC-BY 3.0 and need visible credit:

- Soldier, Quaternius (https://poly.pizza/m/oAArCNHjFB)
- Zombie, Quaternius (https://poly.pizza/m/22K0aSZkHV)
- Zombie half, Quaternius (https://poly.pizza/m/Htcsn9OrXJ)
- Zombie, bachosoftdesign (https://poly.pizza/m/xqEzosAVYX)
- Big arm, Quaternius (https://poly.pizza/m/KaVJET0WHx)
- Animated Wizard, Quaternius (https://poly.pizza/m/kttbFvCl2C)
- Suit, Quaternius (https://poly.pizza/m/sOUciDsoVV)
- Worker, Quaternius (https://poly.pizza/m/E8079Ahx7k)
- Witch, Quaternius (https://poly.pizza/m/QBEOV9ZUT8)
- Sci Fi Character, Quaternius (https://poly.pizza/m/4pUXv5V8kq)
- German Shepard, Quaternius (https://poly.pizza/m/Hssa6NPc6W)
- Characters Pug, Quaternius (https://poly.pizza/m/xvcUwuKl4c)

## Validation

Every GLB was parsed after download: container length matches the header, the file holds one
skinned mesh with a joint list, and every animation carries at least one channel. Every FBX
was checked for AnimationStack and AnimationCurveNode records. In mobs/, FBX take names and
GLB clip names were reconciled per model and the unique clip sets match for all 28.

Three uploads (Pirate Captain, both large Skeletons) carry clip names truncated at 64
characters by the source pipeline, so a name can end in `...|Dea`. The `clean` field in
manifest.json holds the readable name. Clip names inside the files were not changed.

## Limits of this crawl

The explore endpoint stops answering at page 12 without a login (HTTP 401), so models
behind that wall were not enumerated. Search results are capped near 45 per query, which
is why the search pass alone undercounted. Scripts for every stage are in `_scrape/`.
