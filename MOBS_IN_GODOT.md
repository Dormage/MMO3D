# Monsters and townsfolk imported from `assets.zip`

**Status: complete and verified.** The 70 rigged characters selected from the
`assets.zip` poly.pizza library are imported, normalised and placed in the game:

- **25 monsters** on the Floating Island, each with `walk`, `attack` and `die`
  (plus `idle`, `run`, `hit`), wandering around a per-model home radius.
- **45 humanoids in the Walled Town** and **45 in the Ashkari Bazaar**
  (the same full cast in both towns), with walk/idle/emote behaviour.
- Animals are not used as monsters. The old 10 Unity monsters in the Graveyard
  are untouched.

![Overview](docs/mobs/overview_grid.jpg)

## What was selected

The archive contains 81 animated rigs: **26 creature/enemy rigs, 10 animals and
45 humanoid NPC rigs**. The pack's own classification was used.

| Bucket | Count | Decision |
|---|---:|---|
| Creature / enemy rigs | 26 | 25 imported as monsters |
| Animal / pet rigs | 10 | excluded |
| Humanoid NPC rigs | 45 | all 45 imported |

The one creature rig that was not imported is **Zombie half** (`Zombie_half_Htcsn9OrXJ`):
it has walk, hit and death clips but **no attack clip**, so it fails the requested
walk + attack + die test. The 10 excluded animals are Fish, Frog, Pug, German
Shepard, Panda and five Rabbit pet variants. The pack's `Bunny` and `Dino` are the
Ultimate Monsters **enemy** rigs with combat clips, not the dedicated pet/animal
rigs, so they stay in the monster set.

All 70 selected models were normalised without touching meshes, skins or
textures: animation names were rewritten to the canonical roles
`walk / run / idle / attack / hit / die`. Four Mechs had `HitRecieve_1` renamed to
`hit`; the bachosoftdesign Zombie had `Running_Crawl` renamed to `run`. Every
selected model now resolves all six roles in Godot.

## Where they are

| Region | Scene | Spawner child | Roster | Actors |
|---|---|---|---:|---:|
| Floating Island | [`region_island.tscn`](scenes/region_island.tscn) | `Monsters` | [`data/island_monsters.json`](data/island_monsters.json) | 25 |
| Walled Town | [`region_town.tscn`](scenes/region_town.tscn) | `Townsfolk` | [`data/town_npcs.json`](data/town_npcs.json) | 45 |
| Ashkari Bazaar | [`region_desert.tscn`](scenes/region_desert.tscn) | `Townsfolk` | [`data/town_npcs.json`](data/town_npcs.json) | 45 |

**115 ambient actors in total.** The island uses `scatter` placement; both towns
use `districts` placement around eight anchors. Town placement is constrained to
the walkable ground inside the rampart, rejects roofs and awnings, and keeps a
minimum separation between actors. This is why no bazaar NPC is stranded on a
roof or outside the gate.

## Monsters — Floating Island (25)

All heights are the in-game height after normalisation. Every row has all six
clip roles; `walk`, `attack` and `die` are the required three.

| # | Model | GLB | Height | Clips | Licence |
|---:|---|---|---:|---|---|
| 1 | Alien | [alien.glb](assets/models/mob_monsters/alien.glb) | 3.45 m | 6/6 | CC0 |
| 2 | Blue Demon | [blue_demon.glb](assets/models/mob_monsters/blue_demon.glb) | 3.05 m | 6/6 | CC0 |
| 3 | Bunny | [bunny.glb](assets/models/mob_monsters/bunny.glb) | 3.69 m | 6/6 | CC0 |
| 4 | Cactoro | [cactoro.glb](assets/models/mob_monsters/cactoro.glb) | 3.82 m | 6/6 | CC0 |
| 5 | Demon | [demon.glb](assets/models/mob_monsters/demon.glb) | 2.73 m | 6/6 | CC0 |
| 6 | Demon | [demon_lnfi.glb](assets/models/mob_monsters/demon_lnfi.glb) | 3.06 m | 6/6 | CC0 |
| 7 | Dino | [dino.glb](assets/models/mob_monsters/dino.glb) | 3.10 m | 6/6 | CC0 |
| 8 | Enemy Large | [enemy_large.glb](assets/models/mob_monsters/enemy_large.glb) | 3.67 m | 6/6 | CC0 |
| 9 | Giant | [giant.glb](assets/models/mob_monsters/giant.glb) | 3.92 m | 6/6 | CC0 |
| 10 | Goblin | [goblin.glb](assets/models/mob_monsters/goblin.glb) | 2.98 m | 6/6 | CC0 |
| 11 | Mech | [mech.glb](assets/models/mob_monsters/mech.glb) | 3.35 m | 6/6 | CC0 |
| 12 | Mech | [mech_d5ww.glb](assets/models/mob_monsters/mech_d5ww.glb) | 3.48 m | 6/6 | CC0 |
| 13 | Mech | [mech_o3ps.glb](assets/models/mob_monsters/mech_o3ps.glb) | 3.46 m | 6/6 | CC0 |
| 14 | Mech | [mech_tls9.glb](assets/models/mob_monsters/mech_tls9.glb) | 3.94 m | 6/6 | CC0 |
| 15 | Monkroose | [monkroose.glb](assets/models/mob_monsters/monkroose.glb) | 2.85 m | 6/6 | CC0 |
| 16 | Mushroom King | [mushroom_king.glb](assets/models/mob_monsters/mushroom_king.glb) | 3.48 m | 6/6 | CC0 |
| 17 | Orc | [orc.glb](assets/models/mob_monsters/orc.glb) | 3.32 m | 6/6 | CC0 |
| 18 | Sharky | [sharky.glb](assets/models/mob_monsters/sharky.glb) | 1.47 m | 6/6 | CC0 |
| 19 | Skeleton | [skeleton.glb](assets/models/mob_monsters/skeleton.glb) | 3.03 m | 6/6 | CC0 |
| 20 | Yeti | [yeti.glb](assets/models/mob_monsters/yeti.glb) | 2.70 m | 6/6 | CC0 |
| 21 | Yeti | [yeti_xtmy.glb](assets/models/mob_monsters/yeti_xtmy.glb) | 3.19 m | 6/6 | CC0 |
| 22 | Zombie | [zombie.glb](assets/models/mob_monsters/zombie.glb) | 1.62 m | 6/6 | CC-BY 3.0 |
| 23 | Zombie | [zombie_jobv.glb](assets/models/mob_monsters/zombie_jobv.glb) | 2.75 m | 6/6 | CC0 |
| 24 | Zombie | [zombie_vlxj.glb](assets/models/mob_monsters/zombie_vlxj.glb) | 1.35 m | 6/6 | CC0 |
| 25 | Zombie | [zombie_xqez.glb](assets/models/mob_monsters/zombie_xqez.glb) | 4.01 m | 6/6 | CC-BY 3.0 |

## Humanoids — Walled Town and Ashkari Bazaar (45)

The same 45 rigs are spawned in both towns. Heights are normalised to a
consistent 1.72–1.89 m human scale; the taller authored rigs (Ninja, Character
Enemy, the cube characters) are scaled down, not stretched. This is the library's
full **humanoid rig** bucket, so alongside people it includes a few stylized
biped mascots (Animated Platformer Character, the animal-helmet astronaut
variants, Big arm and the cube people).

| # | Model | GLB | Height | Clips | Licence |
|---:|---|---|---:|---|---|
| 1 | Adventurer | [adventurer.glb](assets/models/mob_humanoids/adventurer.glb) | 1.80 m | 6/6 | CC0 |
| 2 | Adventurer | [adventurer_zwf0.glb](assets/models/mob_humanoids/adventurer_zwf0.glb) | 1.80 m | 6/6 | CC0 |
| 3 | Animated Platformer Character | [animated_platformer_character.glb](assets/models/mob_humanoids/animated_platformer_character.glb) | 1.80 m | 6/6 | CC0 |
| 4 | Animated Wizard | [animated_wizard.glb](assets/models/mob_humanoids/animated_wizard.glb) | 1.75 m | 6/6 | CC-BY 3.0 |
| 5 | Animated Woman | [animated_woman.glb](assets/models/mob_humanoids/animated_woman.glb) | 1.72 m | 6/6 | CC0 |
| 6 | Animated Woman | [animated_woman_qj2g.glb](assets/models/mob_humanoids/animated_woman_qj2g.glb) | 1.89 m | 6/6 | CC0 |
| 7 | Anne | [anne.glb](assets/models/mob_humanoids/anne.glb) | 1.76 m | 6/6 | CC0 |
| 8 | Astronaut | [astronaut.glb](assets/models/mob_humanoids/astronaut.glb) | 1.75 m | 6/6 | CC0 |
| 9 | Astronaut | [astronaut_3hc2.glb](assets/models/mob_humanoids/astronaut_3hc2.glb) | 1.78 m | 6/6 | CC0 |
| 10 | Astronaut | [astronaut_oges.glb](assets/models/mob_humanoids/astronaut_oges.glb) | 1.78 m | 6/6 | CC0 |
| 11 | Astronaut | [astronaut_zbtp.glb](assets/models/mob_humanoids/astronaut_zbtp.glb) | 1.78 m | 6/6 | CC0 |
| 12 | Beach Character | [beach_character.glb](assets/models/mob_humanoids/beach_character.glb) | 1.77 m | 6/6 | CC0 |
| 13 | Big arm | [big_arm.glb](assets/models/mob_humanoids/big_arm.glb) | 1.73 m | 6/6 | CC-BY 3.0 |
| 14 | Business Man | [business_man.glb](assets/models/mob_humanoids/business_man.glb) | 1.81 m | 6/6 | CC0 |
| 15 | Casual Character | [casual_character.glb](assets/models/mob_humanoids/casual_character.glb) | 1.85 m | 6/6 | CC0 |
| 16 | Character Animated | [character_animated.glb](assets/models/mob_humanoids/character_animated.glb) | 1.89 m | 6/6 | CC0 |
| 17 | Character Enemy | [character_enemy.glb](assets/models/mob_humanoids/character_enemy.glb) | 1.84 m | 6/6 | CC0 |
| 18 | Character Hazmat | [character_hazmat.glb](assets/models/mob_humanoids/character_hazmat.glb) | 1.79 m | 6/6 | CC0 |
| 19 | Character Soldier | [character_soldier.glb](assets/models/mob_humanoids/character_soldier.glb) | 1.80 m | 6/6 | CC0 |
| 20 | Characters Matt | [characters_matt.glb](assets/models/mob_humanoids/characters_matt.glb) | 1.77 m | 6/6 | CC0 |
| 21 | Characters Sam | [characters_sam.glb](assets/models/mob_humanoids/characters_sam.glb) | 1.86 m | 6/6 | CC0 |
| 22 | Characters Shaun | [characters_shaun.glb](assets/models/mob_humanoids/characters_shaun.glb) | 1.74 m | 6/6 | CC0 |
| 23 | Cube Guy Character | [cube_guy_character.glb](assets/models/mob_humanoids/cube_guy_character.glb) | 1.87 m | 6/6 | CC0 |
| 24 | Cube Woman Character | [cube_woman_character.glb](assets/models/mob_humanoids/cube_woman_character.glb) | 1.76 m | 6/6 | CC0 |
| 25 | Farmer | [farmer.glb](assets/models/mob_humanoids/farmer.glb) | 1.79 m | 6/6 | CC0 |
| 26 | Henry | [henry.glb](assets/models/mob_humanoids/henry.glb) | 1.82 m | 6/6 | CC0 |
| 27 | Hooded Adventurer | [hooded_adventurer.glb](assets/models/mob_humanoids/hooded_adventurer.glb) | 1.82 m | 6/6 | CC0 |
| 28 | Hoodie Character | [hoodie_character.glb](assets/models/mob_humanoids/hoodie_character.glb) | 1.84 m | 6/6 | CC0 |
| 29 | King | [king.glb](assets/models/mob_humanoids/king.glb) | 1.83 m | 6/6 | CC0 |
| 30 | Lis | [lis.glb](assets/models/mob_humanoids/lis.glb) | 1.76 m | 6/6 | CC0 |
| 31 | Mako | [mako.glb](assets/models/mob_humanoids/mako.glb) | 1.82 m | 6/6 | CC0 |
| 32 | Ninja | [ninja.glb](assets/models/mob_humanoids/ninja.glb) | 1.78 m | 6/6 | CC0 |
| 33 | Pirate Captain | [pirate_captain.glb](assets/models/mob_humanoids/pirate_captain.glb) | 1.72 m | 6/6 | CC0 |
| 34 | Punk | [punk.glb](assets/models/mob_humanoids/punk.glb) | 1.86 m | 6/6 | CC0 |
| 35 | Punk | [punk_djxo.glb](assets/models/mob_humanoids/punk_djxo.glb) | 1.78 m | 6/6 | CC0 |
| 36 | Sci Fi Character | [sci_fi_character.glb](assets/models/mob_humanoids/sci_fi_character.glb) | 1.73 m | 6/6 | CC-BY 3.0 |
| 37 | Skeleton | [skeleton_1xzd.glb](assets/models/mob_humanoids/skeleton_1xzd.glb) | 1.77 m | 6/6 | CC0 |
| 38 | Skeleton | [skeleton_yq5a.glb](assets/models/mob_humanoids/skeleton_yq5a.glb) | 1.88 m | 6/6 | CC0 |
| 39 | Soldier | [soldier.glb](assets/models/mob_humanoids/soldier.glb) | 1.88 m | 6/6 | CC-BY 3.0 |
| 40 | Steve | [steve.glb](assets/models/mob_humanoids/steve.glb) | 1.83 m | 6/6 | CC0 |
| 41 | Suit | [suit.glb](assets/models/mob_humanoids/suit.glb) | 1.75 m | 6/6 | CC-BY 3.0 |
| 42 | SWAT | [swat.glb](assets/models/mob_humanoids/swat.glb) | 1.87 m | 6/6 | CC0 |
| 43 | Witch | [witch.glb](assets/models/mob_humanoids/witch.glb) | 1.75 m | 6/6 | CC-BY 3.0 |
| 44 | Worker | [worker.glb](assets/models/mob_humanoids/worker.glb) | 1.72 m | 6/6 | CC-BY 3.0 |
| 45 | Worker | [worker_yg2b.glb](assets/models/mob_humanoids/worker_yg2b.glb) | 1.89 m | 6/6 | CC0 |

## Runtime behaviour

[`scripts/population_field.gd`](scripts/population_field.gd) builds a walkable
candidate grid from the region's ground collision, picks spaced spawn points,
and instantiates [`scripts/population_actor.gd`](scripts/population_actor.gd).
Each actor:

- is a `CharacterBody3D` on collision layer 4, masking ground + solids, so the
  player, NPCs and monsters pass through each other but not through walls;
- plays `walk` while moving and `idle` at its target;
- picks a new random target inside its JSON `wander` radius around its original
  spawn point, never pathing permanently away from home;
- rejects water and obstacle targets, applies gravity and `move_and_slide`;
- occasionally plays `attack` (island, 35% chance) or `Wave` (towns, 28% chance);
- has `kill()`, `anim_check()` and `debug_state()` helpers for inspection.

The monster roster uses a 5 m minimum separation and 12 m keep-clear radius around
the player spawn; town rosters use 2.4 m separation and 3.5 m keep-clear.
Speeds are 0.8–1.7 m/s for monsters and 0.55–0.89 m/s for townsfolk.

## Verification

Headless runs against the actual game scenes:

| Region | Command | Candidates | Spawned | Moved after 8 s | Six clip roles |
|---|---|---:|---:|---:|---:|
| island | `--region=island --population-check` | 1,506 | **25/25** | **25/25** | **25/25** |
| town | `--region=town --population-check` | 1,036 | **45/45** | **45/45** | **45/45** |
| desert | `--region=desert --population-check` | 1,256 | **45/45** | **45/45** | **45/45** |

Island movement distances after the 8 s check were 0.36–6.35 m, all inside their
per-model wander radii. The island check was repeated eight times after the flat-pad
filter was added; all eight runs reported 25/25 moving. All 115 actors reported
`floor=true`. Town/desert actors stayed on street-level floors: the bazaar's
final y range was 0.0 to 0.2 m, with no actor above the 3.5 m street-rise limit;
the Walled Town's actors were all at y = 0.0.

Final logs:

- [`final_island.log`](_mob_library/scripts/final_island.log)
- [`final_town.log`](_mob_library/scripts/final_town.log)
- [`final_desert.log`](_mob_library/scripts/final_desert.log)
- [`final_checks.log`](_mob_library/scripts/final_checks.log) (summary of all three)

The screenshots were rendered in-engine with Godot 4.6.3 Forward+ on Vulkan
(llvmpipe) under Xvfb, not with Blender, so they show the real game camera,
materials, HUD and placement:

- [Walled Town overview](docs/mobs/screenshots/town_overview.jpg) · [close-up](docs/mobs/screenshots/town_cluster.jpg)
- [Ashkari Bazaar overview](docs/mobs/screenshots/desert_overview.jpg) · [close-up](docs/mobs/screenshots/desert_cluster.jpg)
- [Floating Island overview](docs/mobs/screenshots/island_overview.jpg) · [wide](docs/mobs/screenshots/island_0.jpg) · [close-up](docs/mobs/screenshots/island_cluster.jpg)

Contact sheets for the full selection:

- [Monster/animals review sheet](docs/mobs/monster_contact_sheet.jpg) (36 creature and animal rigs reviewed; the 10 animals are the non-combat rigs)
- [Humanoid contact sheet](docs/mobs/humanoid_contact_sheet.jpg) (all 45)

## Rebuilding / editing

The source stays in `_mob_library/` (staging only; the game reads
`assets/models/mob_monsters/` and `assets/models/mob_humanoids/`).

```bash
# Re-run the selection + GLB normalisation (70 outputs, 523,542 tris)
python3 _mob_library/scripts/normalize_glb.py

# Re-import after changing a GLB
cd /home/dormage/code/MMO3D2
XDG_DATA_HOME=$PWD/_runtime/xdg_data \
XDG_CONFIG_HOME=$PWD/_runtime/xdg_config \
XDG_CACHE_HOME=$PWD/_runtime/xdg_cache \
/home/dormage/Downloads/Godot_v4.6.3-stable_linux.x86_64 --headless --path . --editor --quit

# Population check / screenshot modes
#   -- --region=island --population-check
#   -- --region=town   --population-check
#   -- --region=desert --population-check
#   -- --region=town   --screenshot   (needs a display; see [`docs/mobs/README.md`](docs/mobs/README.md))
```

The machine-readable selection (slug, source folder, category, height, radius,
scale, foot offset, speed, wander, roles, tris, licence, page) is
[`_mob_library/scripts/selection.json`](_mob_library/scripts/selection.json).

## Credits

The 9 CC-BY 3.0 models below are credited in-game at the bottom-right of every
populated region ("Mob models: Quaternius, bachosoftdesign · CC BY 3.0 ·
poly.pizza") and here. The other 61 selected models are CC0 1.0.

| Model | Creator | Source |
|---|---|---|
| Animated Wizard | Quaternius | [poly.pizza](https://poly.pizza/m/kttbFvCl2C) |
| Big arm | Quaternius | [poly.pizza](https://poly.pizza/m/KaVJET0WHx) |
| Sci Fi Character | Quaternius | [poly.pizza](https://poly.pizza/m/4pUXv5V8kq) |
| Soldier | Quaternius | [poly.pizza](https://poly.pizza/m/oAArCNHjFB) |
| Suit | Quaternius | [poly.pizza](https://poly.pizza/m/sOUciDsoVV) |
| Witch | Quaternius | [poly.pizza](https://poly.pizza/m/QBEOV9ZUT8) |
| Worker | Quaternius | [poly.pizza](https://poly.pizza/m/E8079Ahx7k) |
| Zombie | Quaternius | [poly.pizza](https://poly.pizza/m/22K0aSZkHV) |
| Zombie | bachosoftdesign | [poly.pizza](https://poly.pizza/m/xqEzosAVYX) |

Old Graveyard content (10 Unity monsters, weapons and the existing town assets)
is unchanged and documented separately in [`MONSTERS_IN_GODOT.md`](MONSTERS_IN_GODOT.md).
