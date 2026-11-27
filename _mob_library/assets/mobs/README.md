# Mob library: 28 rigged mobs with hit, death and run

Source is poly.pizza, starting from the Dragon Evolved page
(https://poly.pizza/m/LlwD0QNUPj), which belongs to Quaternius' Ultimate Monsters Bundle.
The crawl covered that bundle (45 models), the two enemy packs (9 models), and a
keyword sweep of all 84 creature-like models in Quaternius' catalogue.

28 of the 84 inspected models have a hit reaction, a death clip and a run clip.
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

Total 211,190 triangles across all mobs. Smallest is Goblin
(2,912 tris), largest is Character Soldier (20,712 tris).
Bone counts run from 12 (simple monsters) to 62 (Soldier). Each mob carries 7 to 24
unique clips. manifest.json lists them under glb_clips, and animation_count is the raw
count of animation entries in the GLB, which repeats each clip once with and once without
the armature prefix in some uploads.

13 mobs come from the Ultimate Monsters Bundle, 15 from elsewhere in
the same catalogue (enemy packs, robots, zombies, skeletons, soldiers).

## Licence

25 models are CC0 1.0. 3 are CC-BY 3.0 and need visible credit to Quaternius:

- Soldier (https://poly.pizza/m/oAArCNHjFB)
- Zombie (https://poly.pizza/m/22K0aSZkHV)
- Zombie half (https://poly.pizza/m/Htcsn9OrXJ)

Licence and creator for each mob is in its model.json and in manifest.json.

## Validation

Each GLB was parsed after download: container length matches, one skinned mesh with a
joint list, and every animation carries at least one channel. Each FBX was checked for
`AnimationStack` and `AnimationCurveNode` records plus its take names, which match the
GLB clip names. FBX take names were reconciled with GLB clip names for all 28 mobs: the unique
clip sets match in both formats with no differences.

Three uploads (Pirate_Captain, both large Skeletons) have clip names truncated at 64
characters in the source itself, so `CharacterArmature|...|Death|CharacterArmature|Dea`
appears in the file. The `clean` field in manifest.json gives the readable name.

Scripts that produced this set are in `_scrape/` (crawl.py, crawl_extra.py, retry.py,
select.py, finalize.py).
