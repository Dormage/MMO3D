#!/usr/bin/env python3
"""Build the Blender conversion job list for the clip-complete monsters."""
import json
import os

TREE = "/home/dormage/code/MMO3D2/_asset_audit/tree"
OUT = "/home/dormage/code/MMO3D2/assets/models/monsters"

HATOGAME = "Assets/Hatogame_new/"
ANIMS_HATO = {
    "walk": "walk", "run": "run", "idle": "idle", "battleidle": "idle_battle",
    "attack1": "attack1", "attack2": "attack2", "hit": "hit", "die": "die",
    "sturn": "stunned",
}
ANIMS_WOLF = dict(ANIMS_HATO)
ANIMS_WOLF.update({"attack3": "attack3"})


def tex(pkg, name):
    for root, _d, names in os.walk(os.path.join(TREE, pkg)):
        if name in names:
            return os.path.join(root, name)
    raise FileNotFoundError(f"{name} in {pkg}")


def find(pkg, basename):
    for root, _d, names in os.walk(os.path.join(TREE, pkg)):
        if basename in names:
            return os.path.join(root, basename)
    raise FileNotFoundError(f"{basename} in {pkg}")


jobs = []
CAT = "01Monster_Catfish_"
CAT_BASE = f"{CAT}/{HATOGAME}Catfish/"
jobs.append({
    "key": "catfish", "mesh": CAT_BASE + "Mesh/Catfish_skin.FBX",
    "anims": [{"file": CAT_BASE + "Animation/Catfish@%s.FBX" % k, "clip": v}
              for k, v in ANIMS_HATO.items()],
    "textures": {"base": tex(CAT, "Catfish_Albedo.png"),
                 "normal": tex(CAT, "Catfish_Normal.png")},
    "roughness": 0.58, "loop_fix": True, "out": f"{OUT}/catfish.glb",
})

WAT = "01Monster_Watcher_"
WAT_BASE = f"{WAT}/{HATOGAME}Watcher/"
jobs.append({
    "key": "watcher", "mesh": WAT_BASE + "Mesh/Watcher_skin.FBX",
    "anims": [{"file": WAT_BASE + "Animation/Watcher@%s.FBX" % k, "clip": v}
              for k, v in ANIMS_HATO.items()],
    "textures": {"base": tex(WAT, "Watcher_Albedo.png"),
                 "normal": tex(WAT, "Watcher_Normal.png")},
    "roughness": 0.55, "loop_fix": True, "out": f"{OUT}/watcher.glb",
})

WOLF = "01Monster_Wolf_Boss_"
WOLF_BASE = f"{WOLF}/{HATOGAME}BossMonsterPack1/Wolfboss/"
jobs.append({
    "key": "wolf_boss", "mesh": WOLF_BASE + "Mesh/Wolfboss_skin.FBX",
    "anims": [{"file": WOLF_BASE + "Animation/Wolfboss@%s.FBX" % k, "clip": v}
              for k, v in ANIMS_WOLF.items()],
    "textures": {"base": tex(WOLF, "Wolfboss_Albedo.png"),
                 "normal": tex(WOLF, "Wolfboss_Normal.png")},
    "roughness": 0.62, "time_scale": 0.25, "out": f"{OUT}/wolf_boss.glb",
})

RH = "Fantasy_Rhino_"
RH_BASE = f"{RH}/Assets/Rhino/"
jobs.append({
    "key": "rhino", "mesh": RH_BASE + "Mesh/Rino_mesh.FBX",
    "anims": [{"file": RH_BASE + "animation/Rhino@%s.FBX" % k, "clip": v} for k, v in [
        ("Walk", "walk"), ("Run", "run"), ("Idle", "idle"), ("Attack", "attack"),
        ("Get_Hit", "hit"), ("Dead", "die"), ("Eats", "eat"), ("shout", "shout")]],
    "textures": {"base": tex(RH, "Rhinoceros_Albedo.tga"),
                 "normal": tex(RH, "Rhinoceros_normals.tga"),
                 "emissive": tex(RH, "Rhinoceros_Emissive.tga")},
    "roughness": 0.6, "out": f"{OUT}/rhino.glb",
})

TU = "Season2TurtleDragon_"
TU_BASE = f"{TU}/Assets/Season2_Jackpot packV1.5/TurtleDragon/"
jobs.append({
    "key": "turtle_dragon", "mesh": TU_BASE + "Mesh/turtle_dragon.fbx",
    "anims": [{"file": TU_BASE + "Ani/turtle_dragon_%s.fbx" % k, "clip": v} for k, v in [
        ("Walk", "walk"), ("Run", "run"), ("Idle", "idle"), ("Attack03", "attack"),
        ("Hit", "hit"), ("Die", "die")]],
    "textures": {"base": tex(TU, "TurtleDragon_Alb.tga"),
                 "normal": tex(TU, "TurtleDragon_N.tga")},
    "roughness": 0.55, "out": f"{OUT}/turtle_dragon.glb",
})

MON02 = "Fantasy_Monster_3D_Model_02_-_Game_Ready_-_PixeliusVita_"
MON02_BASE = f"{MON02}/Assets/Stylized3DMonster/Monster02/"
jobs.append({
    "key": "monster02", "mesh": MON02_BASE + "Monster02_AllAnim.fbx", "anims": [],
    "clip_map": {"Monster02_Walk": "walk", "Monster02_Run": "run",
                 "Monster02_Idle": "idle", "Monster02_Idle_v02": "idle2",
                 "Monster02_Attack01": "attack1", "Monster02_Attack02": "attack2",
                 "Monster02_Attack03": "attack3", "Monster02_Shoot": "shoot",
                 "Monster02_GetHit": "hit", "Monster02_Die": "die",
                 "Monster02_Stunned": "stunned"},
    "textures": {"base": tex(MON02, "Monster02_Color01.png")},
    "roughness": 0.72, "strip_root": True, "out": f"{OUT}/monster02.glb",
})

GH = "Ghoul_Anklegrabber_"
jobs.append({
    "key": "ghoul", "mesh": f"{GH}/Assets/Ghoul/Assets/Meshes/AnkleGrabber.fbx", "anims": [],
    "clip_map": {"Run": "walk", "AnkleBite": "attack1", "CrochBite": "attack2",
                 "Hit": "hit", "Dies": "die", "IdleOne": "idle",
                 "IdleAlert": "idle_alert", "AngryReaction": "angry",
                 "Sleeps": "sleep", "HushLitteBaby": "hush", "Pose": ""},
    "textures": {"base": tex(GH, "AnkleGrabber_AlbedoTransparency.tga"),
                 "normal": tex(GH, "AnkleGrabber_Normal.tga")},
    "roughness": 0.55, "alpha": True, "out": f"{OUT}/ghoul.glb",
})

SW = "Monster_Minion_Survivor_PBR_Polyart_"
SW_BASE = f"{SW}/Assets/Monster Minion Survivor PBR Polyart/"
SW_CLIPS = [("MoveFWD", "walk"), ("MoveBWD", "walk_back"), ("MoveLFT", "walk_left"),
            ("MoveRGT", "walk_right"), ("Idle", "idle"), ("Attack", "attack"),
            ("GetHit", "hit"), ("Die", "die")]
for key, swarm in (("swarm08", "Swarm08"), ("swarm09", "Swarm09")):
    jobs.append({
        "key": key, "mesh": SW_BASE + f"Mesh/Character/{swarm}.fbx",
        "anims": [{"file": SW_BASE + f"Animation/{swarm}/{swarm}_{k}.fbx", "clip": v}
                  for k, v in SW_CLIPS],
        "textures": {"base": tex(SW, "Albedo.png")},
        "roughness": 0.5, "out": f"{OUT}/{key}.glb",
    })

AR = "Arachnid-Alien_Head_Lite_"
AR_BASE = f"{AR}/Assets/Stocklancer/ArachnidAlienHead_Lite/"
jobs.append({
    "key": "arachnid", "mesh": AR_BASE + "Mesh/SKM_ArachnidAlienHead_Lite.fbx",
    "anims": [{"file": AR_BASE + "Animation/AS_ArachnicAlienHead_%s_Lite.fbx" % f, "clip": c}
              for f, c in [("WalkFW", "walk"), ("WalkFW4", "walk2"),
                           ("WalkBW ", "walk_back"), ("WalkL", "walk_left"),
                           ("WalkR", "walk_right"), ("Attack4", "attack"),
                           ("TakeHit", "hit"), ("Dead", "die"),
                           ("BasicJump", "jump")]],
    "textures": {"base": tex(AR, "T_ArachnidHead_Lite1K_BC_Dirt.png"),
                 "normal": tex(AR, "T_ArachnidHead_Lite1K_N.png")},
    "roughness": 0.55, "loop_fix": True, "out": f"{OUT}/arachnid.glb",
})

# per-job alpha passthrough
for j in jobs:
    if j.get("alpha"):
        j["textures"]["alpha"] = True

# make every path absolute against the reconstructed tree
for j in jobs:
    j["mesh"] = os.path.join(TREE, j["mesh"]) if not os.path.isabs(j["mesh"]) else j["mesh"]
    for a in j["anims"]:
        a["file"] = os.path.join(TREE, a["file"]) if not os.path.isabs(a["file"]) else a["file"]
    for k, v in list(j["textures"].items()):
        if isinstance(v, str) and not os.path.isabs(v):
            j["textures"][k] = os.path.join(TREE, v)

with open("/home/dormage/code/MMO3D2/_asset_audit/convert/jobs.json", "w") as f:
    json.dump(jobs, f, indent=1)

for j in jobs:
    missing = [a["file"] for a in j["anims"] if not os.path.isfile(a["file"])]
    tmiss = [p for p in j["textures"].values() if isinstance(p, str) and not os.path.isfile(p)]
    print(f"{j['key']:16s} anims={len(j['anims']):2d} tex={len(j['textures'])} "
          f"missing_anim={missing} missing_tex={tmiss}")
