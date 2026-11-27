# Monster asset audit — Unity packages → Godot 4.6

Scanned **26 Nov 2026**. Every downloaded Asset Store package on this machine was unpacked, every
FBX imported in headless Blender 5.3, and every creature measured and rendered.

- Packages: **19** (724 MB) in `~/.local/share/unity3d/Asset Store-5.x/`
- Assets inside: **1,671** files — **101 FBX**, 56 Unity `.anim` clips, 140 `.mat`, 22 demo scenes
- Creature models found: **23**
- Minimum bar used: **walk + attack + take-damage + death**, plus a rigged, skinned mesh

Verdict: **10 of 23 are clip-complete** (one of those is a head-only prop), 5 are one or two clips
short, 8 are rigged but have no animations at all. Nothing is usable in Godot as-is — Godot 4.6
cannot read FBX, so every model needs one GLB conversion pass (structure verified, see §5).

> **Update (same day):** all 10 clip-complete models are converted and running in the game.
> They live in `assets/models/monsters/` and wander a field in the Gy Graveyard region — see
> [MONSTERS_IN_GODOT.md](MONSTERS_IN_GODOT.md) for the scene wiring, tuning data and caveats.

---

## 1. Scoreboard

✅ = all four core clips present · ⚠️ = one or more missing · ⛔ = rig only, zero clips

| Model | Publisher | Rig | Tris | Height | Walk | Attack | Hit | Die | Verdict |
|---|---|---|---:|---:|---|---|---|---|---|
| Monster02 | PixeliusVita | 52 | 5,768 | 1.93 m | Walk | Attack01–03, Shoot | GetHit | Die | ✅ |
| Fantasy Rhino | Maksim Bugrimov | 35 | 4,300 | 1.71 m | Walk, Run | Attack | Get_Hit | Dead | ✅ |
| Turtle Dragon | hyun | 77 | 31,658 | 3.03 m | Walk, Run | Attack03 | Hit | Die | ✅ |
| Wolf Boss | HATOGAME | 67 | 4,120 | 3.76 m | Walk, Run | Attack1–3 | Hit | Die | ✅ |
| Catfish | HATOGAME | 73 | 5,864 | 2.01 m | Walk, Run | Attack1–2 | Hit | Die | ✅ |
| Watcher | HATOGAME | 11 | 3,508 | 0.73 m | Walk, Run | Attack1–2 | Hit | Die | ✅ |
| Ghoul Anklegrabber | SKULLVERTEX | 182 | 17,959 | 1.76 m | Run | AnkleBite, CrochBite | Hit | Dies | ✅ |
| Swarm08 | Dungeon Mason | 16 | 1,531 | 0.58 m | MoveFWD/BWD/L/R | Attack | GetHit | Die | ✅ |
| Swarm09 | Dungeon Mason | 12 | 1,138 | 1.29 m | MoveFWD/BWD/L/R | Attack | GetHit | Die | ✅ |
| Arachnid Alien Head | StockLancer | 36 | 27,566 | 0.45 m | WalkFW/BW/L/R | Attack4 | TakeHit | Dead | ✅ ¹ |
| Creep Horror Creature | AC Game Assets | 55 | 15,852 | 5.55 m | Walk1, Walk2 | Bite, Punch, Roar | — | Death | ⚠️ |
| Foe Creature | Nomadic UV | 30 | 7,316 | 1.87 m | Run | Attack | — | — | ⚠️ |
| Monster38 | PixeliusVita | 60 | 2,752 | 1.71 m | Walk, Run ² | Attack01–03 ² | — | Die01–03 ² | ⚠️ |
| Devil Bulldog (Lite) | Deepnest Studio | 127 | 18,240 | 1.67 m | — | Roar ³ | — | — | ⚠️ |
| Ores Dragon | AlexandruD | 211 | 40,221 | 0.93 m | — | — | — | — | ⚠️ |
| Monster37 | PixeliusVita | 60 | 1,860 | 1.44 m | — | — | — | — | ⛔ |
| Monster39 | PixeliusVita | 60 | 6,466 | 1.59 m | — | — | — | — | ⛔ |
| Monster40 | PixeliusVita | 60 | 3,138 | 1.52 m | — | — | — | — | ⛔ |
| Monster41 | PixeliusVita | 60 | 6,586 | 1.42 m | — | — | — | — | ⛔ |
| Monster42 | PixeliusVita | 60 | 9,954 | 1.59 m | — | — | — | — | ⛔ |
| Mini Monster MT01 | PixeliusVita | 53 | 6,185 | 0.70 m | — | — | — | — | ⛔ |
| Mini Monster MT02 | PixeliusVita | 62 | 4,074 | 1.88 m | — | — | — | — | ⛔ |
| Fantasy Character (Zimni) | Zimni | 97 | 23,072 | 1.90 m | — | — | — | — | ⛔ |

¹ Animations complete, but the mesh is a **floating head/torso** (0.45 m, no legs) — usable as a
hovering enemy or bolted onto another body, not as a ground walker.
² Monster38's clips exist only as Unity `.anim` files, not as FBX takes, and there is **no hit clip**.
³ "Roar" is the only combat-ish clip in the Lite pack.

Visual contact sheet of all of the above — `_asset_audit/renders/contact_sheet.png`:

![Creature contact sheet](_asset_audit/renders/contact_sheet.png)

---

## 2. Ready to convert (10)

### Monster02 — PixeliusVita ★ best asset of the batch
`Fantasy_Monster_3D_Model_02_-_Game_Ready_-_PixeliusVita_/…/Monster02_AllAnim.fbx`
52 bones · 5,768 tris · 1.93 m · **one file contains mesh + all 11 clips**

| Clip | s | Clip | s | Clip | s |
|---|---:|---|---:|---|---:|
| Walk | 1.33 | Attack01 | 2.00 | GetHit | 0.67 |
| Run | 0.67 | Attack02 | 2.00 | Die | 1.00 |
| Idle | 2.97 | Attack03 | 2.33 | Stunned | 2.97 |
| Idle_v02 | 6.00 | Shoot | 2.33 | | |

Bonus: separate `Anim/InPlace_Anim/*.anim` versions exist for all clips. **The FBX walk carries
2.44 m of baked root translation** — use the InPlace set or delete the root track, otherwise
`CharacterBody3D` movement will double up. Textures are named in the FBX (`Monster02_Color01.png`),
so relinking is a drag-and-drop.

### Fantasy Rhino — Maksim Bugrimov
`Fantasy_Rhino_/Assets/Rhino/…` · 35 bones · 4,300 tris · 1.71 m
Clips: Walk 1.67 s, Run 0.67 s, Attack 1.23 s, Get_Hit 0.67 s, Dead 1.67 s, Idle 8 s, Eats 10.67 s,
shout 4.67 s. Each clip FBX **also contains the mesh** (duplicated), so merge to one GLB and drop the
duplicates. Textures referenced by name (Rhinoceros_Albedo.tga etc.), 6 TGAs present.

### Turtle Dragon — hyun
`Season2TurtleDragon_/…` · 77 bones · 31,658 tris · 3.03 m
Walk 1.07 s, Run 0.8 s, Attack03 2.33 s, Hit 1.07 s, Die 3.0 s, Idle 2.0 s. Mesh FBX is animation-free;
six separate animation FBX. Heaviest tri-count of the "ready" group — fine on desktop, check mobile.

### Wolf Boss — HATOGAME
`01Monster_Wolf_Boss_/…` · 67 bones · 4,120 tris · 3.76 m (big boss silhouette)
Walk 7.52 s, Run 3.33 s, Attack1 15.2 s, Attack2 18.05 s, Attack3 25.22 s, Hit 11.73 s, Die 6.33 s,
Idle 33.82 s, Stun 3.07 s, BattleIdle 15.03 s.
⚠️ **Duration anomaly:** these are 3–5× longer than equivalent clips in every other pack. Either a
deliberately ponderous boss or a take baked at ~96 fps. Preview it; if it plays in slow motion,
scale the keys by 0.25 in Blender. Animations are animation-only FBX (no mesh) and the FBX references
no textures — 4 PNGs sit next to the model and must be assigned by hand.

### Catfish — HATOGAME
73 bones · 5,864 tris · 2.01 m. Nine clips (walk 2.93 s, run 3.27 s, attack1/2 2.97 s, hit 2.5 s,
die 4.17 s, idle 10 s, battleidle 3.67 s, stun 3.33 s). Same pattern as Wolf: anim-only FBX,
textures unassigned. Good mid-tier mob.

### Watcher — HATOGAME
11 bones · 3,508 tris · 0.73 m — a floating spiked eye. Nine clips, all present; "walk" is a hover
bob. Cheapest animation set in the batch (11 bones) and a good fit for a floating/ambient enemy.

### Ghoul Anklegrabber — SKULLVERTEX
`Ghoul_Anklegrabber_/…/AnkleGrabber.fbx` · 182 bones · 17,959 tris · 1.76 m · all 11 clips embedded
in the mesh FBX: Run 1.33 s, AnkleBite 6.14 s, CrochBite 4.64 s, Hit 3.27 s, Dies 3.17 s,
IdleAlert/IdleOne 2.67 s, plus flavour clips (AngryReaction, HushLitteBaby, Sleeps, Pose).
No walk — **Run is the only locomotion clip**. 182 bones is the heaviest rig of the ready group;
7 TGAs exist but the FBX references none, so materials are manual.

### Swarm08 & Swarm09 — Dungeon Mason
`Monster_Minion_Survivor_PBR_Polyart_/…` · 16 and 12 bones · 1,531 / 1,138 tris · 0.58 / 1.29 m.
Eight clips each, **one FBX per clip with the mesh included**: Attack 0.53 s, Die 0.63 s,
GetHit 0.4 s, Idle 0.67 s, MoveFWD/BWD/LFT/RGT 0.67 s (flying creatures — MoveFWD is the "walk").
The cheapest monsters here; ideal MMO trash/crowd mobs. Only 2 textures each (Albedo,
Metallic-Smoothness) and the FBX references them by name.

### Arachnid Alien Head — StockLancer
36 bones · 27,566 tris · 0.45 m tall, 0.71 wide. Clips: WalkFW, WalkFW4, WalkBW, WalkL, WalkR
(1 s each), Attack4 1.33 s, TakeHit 1.0 s, Dead 2.5 s, BasicJump 1.5 s. Animation set is complete
and clean, but the mesh is a head-and-shoulders bust with no body/legs — treat it as a floating head
enemy, not a walker. 4 materials, 3 PNGs, one texture path points at a dead `D:/…/UE_WIP/` location.

---

## 3. Close, but not meeting the bar (5)

| Model | Has | Missing | Effort to fix |
|---|---|---|---|
| **Creep Horror Creature** | Walk1/Walk2 4 s, Bite 4 s, Punch 4 s, Roar, Death 2 s, Crouch, JumpIn/Out, Eat, Sniff | **Hit** | Small — retime Death's first 0.5 s or Roar into a flinch. 5.55 m tall, 15,852 tris, 55 bones, plus a 3,169-tri LOD with the same 18 clips. No material at all in the FBX (24 PNGs in the folder). |
| **Foe Creature** | Attack 4 s, Run 0.8 s, Idle 4 s | **Hit, Die** | Medium — needs two authored clips; skeleton is only 30 bones so hand-animating is viable. 7,316 tris, 1.87 m. Textures referenced by name. |
| **Monster38** | 3 attacks, 3 idles, 3 dies, walk, run — **as Unity `.anim` only** | **Hit**, plus a format conversion | Medium — `.anim` clips contain full path-based quaternion curves (`root/root.x/spine_01.x/…`) that match the rig exactly. A small YAML→action converter unlocks this model **and five more** (see §4). |
| **Devil Bulldog (Lite)** | IdleBreath 1.97 s, IdleSnuff 3.97 s, Roar 2.63 s | **Walk, Hit, Die**, no real attack | Not fixable in the Lite pack — it ships 3 showcase clips by design (the package readme says so). 18,240 tris, 127 bones, 2 textures referenced. The paid full version is where the combat set lives. |
| **Ores Dragon** | 4 clips, generically named: `basic_animation` 5.77 s, `metarigAction` 5.17 s, 2 duplicates | **Everything identifiable** | Low value — 211 bones (metarig leftovers), 40,221 tris, 0.93 m, animations are unnamed/unstructured. Would need a full cleanup + new anim set. |

---

## 4. Rigged but zero animations (8) — and a way to salvage five of them

| Model | Rig | Tris | Note |
|---|---|---:|---|
| Monster37 | 60 | 1,860 | shared rig → Monster38 clips retarget |
| Monster39 | 60 | 6,466 | shared rig → Monster38 clips retarget |
| Monster40 | 60 | 3,138 | shared rig → Monster38 clips retarget |
| Monster41 | 60 | 6,586 | shared rig → Monster38 clips retarget |
| Monster42 | 60 | 9,954 | shared rig → Monster38 clips retarget |
| Mini Monster MT01 | 53 | 6,185 | own rig; no clips anywhere in the package |
| Mini Monster MT02 | 62 | 4,074 | own rig; no clips anywhere in the package |
| Fantasy Character (Zimni) | 97 | 23,072 | already your player (`assets/models/player/player_animated.glb`, 11 clips) |

**Key finding:** Monster37/38/39/40/41/42 all share an **identical 60-bone skeleton** — same bone
names, same order, same hierarchy (`root.x → spine_01.x → … → toes_01.r`). Monster38's `.anim`
clips are therefore drop-in retargets for the other five. Converting that one clip set to a GLB
animation library turns **5 unusable models into 5 ready models** (walk, run, 3 attacks, 3 deaths,
3 idles) for the cost of one script. MT01/MT02 use a different 53/62-bone rig and cannot share it.

---

## 5. Godot reality check

**FBX is not importable by Godot 4.6.** Every model needs Blender → GLB. The export path is proven on
Monster02: the 11 takes came out as **11 separate glTF animations, one 52-joint skin, one mesh,
3.8 MB** (`_asset_audit/pilot/monster02_pilot.glb`). I could not do an in-engine import test — there is
no Godot binary on this machine — so that last step is yours. The project already does this for the
player and weapons, and `tools/fix_glb_textures.py` is there for the JPEG-decode issue.

Per-model conversion notes:

1. **Textures.** The FBX files carry absolute Windows paths (`D:/____WIP____/…`, `E:/Alican/…`) that
   don't exist, so textures never load. Packages with texture names inside the FBX (Monster02, Rhino,
   Turtle, Swarm, Foe, Bulldog) are a simple relink. Catfish, Watcher, Wolf, Ghoul and Creep have
   **no texture references at all** — the PNG/TGA sets must be assigned to materials by hand.
2. **Split rigs.** Catfish, Watcher, Wolf, Turtle and Arachnid ship animation-only FBX. Import the
   skin FBX and append the actions from the clip FBX in Blender (same bone names), then export one GLB.
   Rhino and Swarm duplicate the mesh in every clip file — export once, discard the duplicates.
3. **Root motion.** Monster02's walk translates 2.44 m; strip the root track or use the InPlace clips.
   Sampled walk clips of Catfish, Watcher, Wolf, Rhino, Turtle, Ghoul, Swarm, Creep are in-place
   (root displacement < 0.02 m).
4. **Scale.** Real heights range 0.58 m (Swarm08) to 5.55 m (Creep) — set a per-scene scale rather
   than trusting the import defaults. Arachnid and Bulldog rigs carry a 0.01 armature scale, so
   apply transforms before export.
5. **Bone budgets.** Ghoul 182, Ores Dragon 211, Bulldog 127, Zimni 97. Desktop-fine, but a crowd of
   Ghouls is 182 bones × N. Swarm (12–16 bones) is the crowd mob.
6. **Unity-specific files are dead weight:** `.mat`, `.shader`, `.controller`, `.cs`, `.prefab`,
   `.unity` — the URP shaders and animator controllers do not port. Judge materials by the textures,
   not the `.mat`.
7. **Rename on import.** glTF animation names come through raw (`root|Monster02_Walk`). Normalise to
   `walk / run / idle / attack / hit / die` and set loop flags, then drive an `AnimationTree`.

---

## 6. Recommended order of work

1. **Convert the easy, self-contained wins first:** Monster02, Fantasy Rhino, Swarm08/09,
   Ghoul — 5 monsters with 1–2 hours of texture wiring.
2. **Next:** Turtle Dragon, Catfish, Watcher, Wolf Boss, Arachnid (split-rig merge + manual textures).
3. **Cheap completeness fixes:** add a hit clip to Creep (retime Roar/Death); author hit + die for Foe.
4. **High-leverage:** convert Monster38's `.anim` clips onto the shared 60-bone rig → Monster37/39/40/41/42
   become usable. That is the single best return on effort in this batch.
5. **Skip / buy:** Devil Bulldog Lite (3 showcase clips only — full version needed, this is the model
   in your screenshot); Ores Dragon (unstructured 211-bone metarig export).

---

## 7. Where things are

| Path | What |
|---|---|
| `_asset_audit/` | Reconstructed package tree (`.gdignore`d — Godot won't import it). 1.1 GB, safe to delete; `build_tree.py` recreates it from the Asset Store cache. |
| `_asset_audit/tree/<Package>/Assets/…` | Original Unity folder layout, every FBX/texture in place |
| `_asset_audit/monsters.json` / `monsters.csv` | Machine-readable results (clips, coverage, bones, tris, heights) |
| `_asset_audit/audit_raw.jsonl` | Raw per-FBX Blender dump (101 records) |
| `_asset_audit/renders/` | 18 model renders + `contact_sheet.png` |
| `_asset_audit/pilot/monster02_pilot.glb` | Proof-of-pipeline export (11 animations) |
| `~/.local/share/unity3d/Asset Store-5.x/` | The original `.unitypackage` downloads |

Not monsters, for completeness: `2D Isometric City theme Pack` (2D tiles), `Dynamic Ragdoll System`
(Unity scripts + a 2,708-tri demo mannequin), plus scene props `BackDrop`, `Stage`, `DisplayDisc`,
`background_sphere`.
