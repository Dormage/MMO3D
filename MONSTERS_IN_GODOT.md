# Monsters in the game

> This document covers the older 10-pack Unity Graveyard set. The 70 rigs
> imported from `assets.zip` (25 island monsters + 45 town humanoids) are
> documented in [`MOBS_IN_GODOT.md`](MOBS_IN_GODOT.md).

Ten Unity monster packs converted to GLB, texture-wired, and dropped into the **Gy Graveyard**
region (the sand map built in `~/code/desert` — this project has no separate desert region; the
graveyard is the non-city open map). Fifteen monsters now wander a small area around the player spawn.

## What was converted

All ten models from the audit that had a complete walk / attack / hit / die set plus textures.
Animations are renamed to plain lowercase names, meshes are skinned, textures are embedded in the
GLB and extracted by Godot on import.

| Model | File | Animations | Joints | Tris | GLB |
|---|---|---|---:|---:|---:|
| Monster02 | `monster02.glb` | 11 | 52 | 5,768 | 3.7 MB |
| Rhino | `rhino.glb` | 8 | 35 | 3,492 | 11.3 MB |
| Turtle Dragon | `turtle_dragon.glb` | 6 | 77 | 14,134 | 11.4 MB |
| Wolf Boss | `wolf_boss.glb` | 10 | 67 | 4,120 | 11.9 MB |
| Catfish | `catfish.glb` | 9 | 73 | 5,864 | 8.6 MB |
| Watcher | `watcher.glb` | 9 | 11 | 3,508 | 9.6 MB |
| Ghoul Anklegrabber | `ghoul.glb` | 10 | 182 | 17,959 | 15.3 MB |
| Swarm08 | `swarm08.glb` | 8 | 16 | 1,531 | 1.0 MB |
| Swarm09 | `swarm09.glb` | 8 | 12 | 1,138 | 1.0 MB |
| Arachnid Head | `arachnid.glb` | 9 | 36 | 27,566 | 5.2 MB |

Clip names (identical style across the set, so a generic picker finds `walk` and `idle`):

- **Catfish / Watcher / Wolf** — `walk, run, idle, idle_battle, attack1..3, hit, die, stunned`
- **Rhino** — `walk, run, idle, attack, hit, die, eat, shout`
- **Turtle Dragon** — `walk, run, idle, attack, hit, die`
- **Monster02** — `walk, run, idle, idle2, attack1..3, shoot, hit, die, stunned`
- **Ghoul** — `walk, attack1, attack2, hit, die, idle, idle_alert, angry, sleep, hush`
- **Swarm08/09** — `walk, walk_back, walk_left, walk_right, idle, attack, hit, die`
- **Arachnid** — `walk, walk2, walk_back, walk_left, walk_right, attack, hit, die, jump`

## Where it lives

```
assets/models/monsters/      10 GLBs + Godot-extracted textures and .import sidecars
data/monsters.json           roster: model, height, speed, wander radius, scale, count
scripts/monster_actor.gd     one wandering monster (loads GLB, ground steering, walk/idle)
scripts/monster_field.gd     spawner node: reads the roster, finds ground, places instances
scenes/region_graveyard.tscn now has a `Monsters` child node running monster_field.gd
```

## Seeing it

Run the game, then jump straight to the graveyard:

- press **9** (region 2), or **Tab** twice, or launch with
  `godot --path . -- --region=graveyard`

The player spawns at the middle of the field; monsters are placed 6–18 m out so they never spawn
on top of you, and each wanders inside a 4–8 m home radius.

## How it behaves

Each monster is a `CharacterBody3D` with a capsule fitted to its height:

- picks a random reachable point inside its home radius (downward raycast onto collision layer 1,
  rejects slopes over ~44°, keeps within 3 m of its spawn height),
- walks there at its own speed, turns to face the direction, plays `walk`,
- pauses 1.5–4.5 s playing `idle`, then repeats,
- gravity + `move_and_slide`, so it follows the terrain and slides along walls,
- no navmesh required. Collision layer 4, mask = ground + solids, so monsters don't block the
  player or each other.

Tuning is all in `data/monsters.json`:

| Field | Meaning |
|---|---|
| `glb` | model path |
| `height`, `radius` | capsule size in metres |
| `speed` | walk speed (m/s) |
| `wander` | home radius in metres |
| `scale` | visual scale (Arachnid is 2.0 so the 0.45 m head reads at ~0.9 m) |
| `count` | instances (swarms get 2–3) |
| `yaw_offset` | 0 normally; Wolf is `-1.5708` because it faces +X |

To add another monster later (Creep and Foe are the next best candidates — see
`MONSTER_ASSETS.md`), drop its GLB in the folder, add one JSON entry, restart. No code change.

## Conversion notes / known quirks

- **Wolf Boss timing** — its FBX takes are long (7.5 s walk, 15–25 s attacks) and the walk take ends
  with a two-thirds frozen hold. Dead tail is trimmed and the rest retimed ×0.5: walk 1.17 s, attacks
  7.5–12.6 s. Revert with `"time_scale": 1.0` in `_asset_audit/convert/build_jobs.py`.
- **Wolf orientation** — rig faces +X (all other models face +Z); handled by `yaw_offset`.
- **Rhino** — its eyes, teeth and three 20-vert trim pieces were bone-parented in the FBX and
  exported 60–150 m away from the body. They were dropped; body + tongue remain. If you want eyes
  back, the clean fix is to re-skin those parts onto the head bone in Blender before export.
- **Turtle Dragon** — the FBX contained three stacked LODs; only `lod0` is in the GLB.
- **Catfish walk** — the take starts with 1.6 s of frozen pose; trimmed off, so the clip is now
  1.27 s of continuous walk.
- **Loop repair** — Catfish, Watcher, Arachnid and Wolf had secondary bones (antennae, tail, root
  bob) whose last key did not match the first. The converter now eases the last ~0.3 s onto frame 0
  and pins the first/last two frames, so all ten walk clips loop with a seam under 1° and no dead
  frames (verified by sampling every clip at 30 fps).
- **Monster02 root motion** — the walk/run/attack clips animate the Armature object itself (2.44 m
  walk, 4.94 m run). That object-level travel is stripped so the actor moves instead; bone-level
  root translation is stripped too.
- **Arachnid** — has no idle clip, so it freezes (paused) between walks instead of idling.
- **Ghoul** — uses an alpha-tested albedo; the material is set to dithered alpha.
- **Watcher** — mesh origin sits ~1.5 m up, so it hovers. Intentional-looking for a floating eye.
- **Textures** — 1K–2K, embedded. Folder is ~145 MB including Godot's extracted copies.
- **No combat yet** — only walking/idling is wired. `attack1`, `hit` and `die` are already in every
  GLB, so an AI state machine can call them directly.

## Verification

Godot 4.6.3, headless, `region_graveyard.tscn` and the full `game.tscn`:

```
MONSTERS spawned=15 centre=(0.0, 0.22467, 0.0) monster02_0@walk/idle, rhino_0@walk/idle, ...
SHIPPED_NAV polygons=4215 vertices=2416 map_rid_ok=true
MONSTER_STATE wolf_boss_0 pos=(14.3, 0.0, 6.8) anim=walk floor=true
```

All 15 instances resolve a walk clip (Arachnid resolves walk, no idle), stay `floor=true`, and move
between 0 and ~20 m from spawn. Run with `-- --monster-report` to print per-monster state every 3 s.

The engine was run headless (no window/GPU), so visuals were checked by rendering the converted
GLBs in Blender rather than by in-engine screenshots: see `_asset_audit/renders_glb/`.

## Re-converting

```bash
cd _asset_audit
python3 convert/build_jobs.py                       # rebuild jobs.json from the extracted packs
blender -b --factory-startup -P convert/convert_monsters.py -- "$(cat convert/jobs.json)"
```

The extracted Unity packages the script reads from are in `_asset_audit/tree/` (recreated by
`build_tree.py`; the folder is `.gdignore`d and safe to delete).
