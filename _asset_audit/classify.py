"""Turn the raw Blender audit into a per-creature classification (JSON + CSV)."""
import json
import os
import re

BASE = "/home/dormage/code/MMO3D2/_asset_audit"
TREE = os.path.join(BASE, "tree")

RAW = {}
for line in open(os.path.join(BASE, "audit_raw.jsonl")):
    r = json.loads(line)
    RAW[r["file"]] = r

CREATURES = [
    dict(strip=['Catfish@', 'Catfish_'], key="catfish", name="Catfish", pub="HATOGAME", pkg="01Monster_Catfish_",
         mesh="Catfish_skin.FBX", anims=["Catfish@"]),
    dict(strip=['Watcher@', 'Watcher_'], key="watcher", name="Watcher", pub="HATOGAME", pkg="01Monster_Watcher_",
         mesh="Watcher_skin.FBX", anims=["Watcher@"]),
    dict(strip=['Wolfboss@', 'Wolfboss_'], key="wolf", name="Wolf Boss", pub="HATOGAME", pkg="01Monster_Wolf_Boss_",
         mesh="Wolfboss_skin.FBX", anims=["Wolfboss@"]),
    dict(strip=['Rhino@'], key="rhino", name="Fantasy Rhino", pub="Maksim Bugrimov", pkg="Fantasy_Rhino_",
         mesh="Rino_mesh.FBX", anims=["Rhino@"]),
    dict(strip=['turtle_dragon_'], key="turtle", name="Turtle Dragon", pub="hyun", pkg="Season2TurtleDragon_",
         mesh="Mesh/turtle_dragon.fbx", anims=["turtle_dragon_"]),
    dict(strip=['Swarm08_'], key="swarm08", name="Swarm08 (Minion)", pub="Dungeon Mason",
         pkg="Monster_Minion_Survivor_PBR_Polyart_", mesh="Character/Swarm08.fbx",
         anims=["Swarm08_"]),
    dict(strip=['Swarm09_'], key="swarm09", name="Swarm09 (Minion)", pub="Dungeon Mason",
         pkg="Monster_Minion_Survivor_PBR_Polyart_", mesh="Character/Swarm09.fbx",
         anims=["Swarm09_"]),
    dict(key="monster02", name="Monster02", pub="PixeliusVita",
         pkg="Fantasy_Monster_3D_Model_02_-_Game_Ready_-_PixeliusVita_",
         mesh="Monster02_AllAnim.fbx", anims=[]),
    dict(key="ghoul", name="Ghoul Anklegrabber", pub="SKULLVERTEX", pkg="Ghoul_Anklegrabber_",
         mesh="AnkleGrabber.fbx", anims=[]),
    dict(key="creep", name="Creep Horror Creature", pub="AC Game Assets",
         pkg="Creep_Horror_Creature_", mesh="Creep_mesh.fbx", anims=[]),
    dict(key="foe", name="Foe Creature", pub="Nomadic UV", pkg="Foe_Creature_",
         mesh="Foe_creature.fbx", anims=[]),
    dict(strip=['DevilBulldog@'], key="bulldog", name="Devil Bulldog (Lite)", pub="Deepnest Studio",
         pkg="Stylized_Devil_Bulldog-_Lite_Version_", mesh="DevilBulldog.fbx",
         anims=["DevilBulldog@"]),
    dict(key="monster38", name="Monster38", pub="PixeliusVita",
         pkg="Fantasy_Monster_Evolution_Pack_37-3839_Game_Ready_Creatures_PixeliusVita_",
         mesh="Monster38.fbx", anims=[]),
    dict(key="monster37", name="Monster37", pub="PixeliusVita",
         pkg="Fantasy_Monster_Evolution_Pack_37-3839_Game_Ready_Creatures_PixeliusVita_",
         mesh="Monster37.fbx", anims=[]),
    dict(key="monster39", name="Monster39", pub="PixeliusVita",
         pkg="Fantasy_Monster_Evolution_Pack_37-3839_Game_Ready_Creatures_PixeliusVita_",
         mesh="Monster39.fbx", anims=[]),
    dict(key="monster40", name="Monster40", pub="PixeliusVita",
         pkg="Fantasy_Monster_Evolution_Pack_40-4142_Game_Ready_Creatures_PixeliusVita_",
         mesh="Monster40.fbx", anims=[]),
    dict(key="monster41", name="Monster41", pub="PixeliusVita",
         pkg="Fantasy_Monster_Evolution_Pack_40-4142_Game_Ready_Creatures_PixeliusVita_",
         mesh="Monster41.fbx", anims=[]),
    dict(key="monster42", name="Monster42", pub="PixeliusVita",
         pkg="Fantasy_Monster_Evolution_Pack_40-4142_Game_Ready_Creatures_PixeliusVita_",
         mesh="Monster42.fbx", anims=[]),
    dict(key="mt01", name="Mini Monster MT01", pub="PixeliusVita",
         pkg="FreeTrial_Pack_2_Mini_Monster_Rigged_PixeliusVita_", mesh="MT01.fbx", anims=[]),
    dict(key="mt02", name="Mini Monster MT02", pub="PixeliusVita",
         pkg="FreeTrial_Pack_2_Mini_Monster_Rigged_PixeliusVita_", mesh="MT02.fbx", anims=[]),
    dict(key="oresdragon", name="Ores Dragon", pub="AlexandruD", pkg="Character_OresDragon_",
         mesh="OresDragonLow2.fbx", anims=[]),
    dict(key="fantasy", name="Fantasy Character (Zimni)", pub="Zimni", pkg="Fantasy_character_",
         mesh="Fantasy_character.fbx", anims=[]),
    dict(strip=['AS_ArachnicAlienHead_'], key="arachnid", name="Arachnid Alien Head", pub="StockLancer",
         pkg="Arachnid-Alien_Head_Lite_", mesh="SKM_ArachnidAlienHead_Lite.fbx",
         anims=["AS_ArachnicAlienHead_"]),
]

RULES = {
    "walk": r"(walk|movefwd|move_fwd|movebwd|locomotion|run)",
    "run": r"(^|_)run",
    "attack": r"(attack|bite|punch|shoot|claw|slash|roar)",
    "hit": r"(hit|takehit|take_hit|damage|hurt|flinch)",
    "die": r"(die|dead|death|dies)",
    "idle": r"(idle)",
}


def files_of(pkg, pattern):
    hits = []
    for rel in RAW:
        if rel.startswith(pkg + "/") and pattern.lower() in rel.lower():
            hits.append(rel)
    return sorted(hits)


def clip_entries(rel_list, embedded):
    """Return clip dicts from FBX files or from embedded armature actions."""
    out = []
    for rel in rel_list:
        r = RAW[rel]
        acts = r["actions"]
        armnames = [a["name"] for a in r["armatures"]]
        if embedded and len(acts) > 1:
            keep = [a for a in acts if any(a["name"].startswith(n + "|") for n in armnames)]
        else:
            keep = [a for a in acts if any(a["name"].startswith(n + "|") for n in armnames)][:1]
        if not keep:
            keep = acts[:1]
        for a in keep:
            short = a["name"].split("|")[-1]
            if re.match(r"^(Base ?Layer|Take \d+|Layer\d+|Take \d+\|BaseLayer)$", short, re.I):
                stem = os.path.splitext(os.path.basename(rel))[0]
                short = stem.split("@")[-1] if "@" in stem else stem
                for pre in (c.get("strip") or []):
                    if short.lower().startswith(pre.lower()):
                        short = short[len(pre):]
                short = re.sub(r"_Lite$", "", short, flags=re.I)
            short = re.sub(r"\.\d{3}$", "", short)
            src = "embedded" if len(rel_list) == 0 or embedded else "file"
            out.append({"name": short, "raw": a["name"], "frames": a["range"],
                        "seconds": round((a["range"][1] - a["range"][0]) / 30.0, 2),
                        "source": src, "file": os.path.basename(rel)})
    return out


def classify(clips):
    names = [c["name"].lower() for c in clips]
    found = {}
    for bucket, pat in RULES.items():
        rx = re.compile(pat)
        found[bucket] = [c["name"] for c, n in zip(clips, names) if rx.search(n)]
    return found


models = []
for c in CREATURES:
    pkg = c["pkg"]
    mesh_rel = next((rel for rel in files_of(pkg, c["mesh"]) if os.path.basename(rel).lower() == os.path.basename(c["mesh"]).lower()), None)
    if mesh_rel is None:
        mesh_rel = files_of(pkg, c["mesh"])[0]

    anim_rels = []
    for pat in c["anims"]:
        for rel in files_of(pkg, pat):
            if rel.lower().endswith(".fbx") and rel != mesh_rel and "lod1" not in rel.lower():
                if rel not in anim_rels:
                    anim_rels.append(rel)

    mr = RAW[mesh_rel]
    embedded = bool(mr["actions"]) and not anim_rels
    clips = clip_entries([mesh_rel] if embedded else anim_rels, embedded)
    if not clips and embedded:
        clips = clip_entries([mesh_rel], True)
    found = classify(clips)

    # Unity .anim clips shipped instead of FBX takes
    anim_yaml = []
    for root, _d, names in os.walk(os.path.join(TREE, pkg)):
        for n in names:
            if n.lower().endswith(".anim") and c["key"] in n.lower().replace("monster", "monster"):
                anim_yaml.append(n)
    anim_yaml = sorted(set(anim_yaml))

    meshes = mr["meshes"]
    biggest = max(meshes, key=lambda m: m["tris"]) if meshes else None
    bones = max([a["bones"] for a in mr["armatures"]] or [0])
    tris = sum(m["tris"] for m in meshes)
    height = max([m["dims"][2] for m in meshes] or [0])

    missing = [k for k in ("walk", "attack", "hit", "die") if not found[k]]
    if not clips and anim_yaml:
        status = "PARTIAL"
    elif not clips:
        status = "MODEL_ONLY"
    elif not missing:
        status = "READY"
    else:
        status = "PARTIAL"

    models.append({
        "key": c["key"], "name": c["name"], "publisher": c["pub"], "package": pkg,
        "mesh_file": mesh_rel, "mesh_includes_anims": embedded,
        "anim_fbx": [os.path.basename(a) for a in anim_rels],
        "unity_anim_clips": anim_yaml,
        "bones": bones, "tris": tris, "height_m": round(height, 2),
        "materials": biggest["mats"] if biggest else 0,
        "skinned": bool(biggest and "ARMATURE" in biggest["mods"] and biggest["vgroups"] > 0),
        "clips": clips, "coverage": {k: found[k] for k in ("walk", "run", "attack", "hit", "die", "idle")},
        "missing": missing, "status": status,
    })

with open(os.path.join(BASE, "monsters.json"), "w") as f:
    json.dump(models, f, indent=1)

for m in models:
    print(f"{m['status']:10s} {m['name']:26s} clips={len(m['clips']):2d} bones={m['bones']:4d} "
          f"tris={m['tris']:6d} h={m['height_m']:4.2f} missing={m['missing']} "
          f"yaml={len(m['unity_anim_clips'])} emb={m['mesh_includes_anims']}")
    print("           ", [c["name"] for c in m["clips"]])
