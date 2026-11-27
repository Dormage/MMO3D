"""Select, normalise and copy the poly.pizza mob library into the Godot project.

Only the GLB container's JSON chunk is rewritten: animation names are cleaned,
core roles are renamed to walk/run/idle/attack/hit/die, duplicate takes are
dropped. Mesh, skin, textures and binary animation data are untouched.

Outputs:
  assets/models/mob_monsters/<slug>.glb
  assets/models/mob_humanoids/<slug>.glb
  _mob_library/scripts/selection.json
"""
import json
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIB = os.path.join(ROOT, "_mob_library", "assets")
OUT_MON = os.path.join(ROOT, "assets", "models", "mob_monsters")
OUT_HUM = os.path.join(ROOT, "assets", "models", "mob_humanoids")
OUT_SEL = os.path.join(ROOT, "_mob_library", "scripts", "selection.json")

MONSTERS = [
    "Alien_RRliSQBP7r", "Blue_Demon_S7jYW6Amye", "Bunny_irZjWFARyl",
    "Cactoro_IGn9lhdama", "Demon_IkB63XOPvr", "Demon_LnfIziKv4o",
    "Dino_wuerCFCWNR", "Enemy_Large_UgBmRVnQ9h", "Goblin_OdCOFSmEhl",
    "Monkroose_j4rVPvxyLg", "Mushroom_King_grnFTziU8u", "Orc_5vO2YJsPEf",
    "Skeleton_DM4QScSmbS", "Yeti_ceRHrn8HHE", "Yeti_xtMYEVzyw0",
    "Zombie_22K0aSZkHV", "Zombie_JoBvxIUpZP", "Zombie_VlXjG0N8Eg",
    "Giant_BldaiPtyJa", "Mech_4UvIHxnoSR", "Mech_D5wW2jDO42",
    "Mech_o3Ps8z8ByP", "Mech_tLs9mFVCSU", "Sharky_iPV5YmAoIv",
    "Zombie_xqEzosAVYX",
]

HUMANOIDS = [
    # seven humanoid rigs that live in the monster packs
    "Character_Enemy_mdGe4IN31v", "Character_Soldier_PpLF4rt4ah",
    "Ninja_xGYmeDpfTu", "Pirate_Captain_sN18LyyHAU",
    "Skeleton_1XZD9GK6Kj", "Skeleton_yq5ATpujSt", "Soldier_oAArCNHjFB",
    # 38 character-bucket rigs from mobs_extra
    "Adventurer_5EGWBMpuXq", "Adventurer_ZwF0K7WBmu",
    "Animated_Platformer_Character_kKtL4zvS3n", "Animated_Wizard_kttbFvCl2C",
    "Animated_Woman_nIItLV9nxS", "Animated_Woman_qJ2gsTUBHL",
    "Anne_tZYaOQ4l94", "Astronaut_0D54W8yfrA", "Astronaut_3hC2i0CTuO",
    "Astronaut_OgeSH89Nmx", "Astronaut_zbtPq4dOJL",
    "Beach_Character_DojKLcO34E", "Big_arm_KaVJET0WHx",
    "Business_Man_JFrLIKqvCH", "Casual_Character_kZ3DmIoGip",
    "Character_Animated_DgOCW9ZCRJ", "Character_Hazmat_z3TSQYx1Kn",
    "Characters_Matt_66kQ4dBBC7", "Characters_Sam_UcLErL2W37",
    "Characters_Shaun_eJFT9MxzOM", "Cube_Guy_Character_K1IczhnvQ5",
    "Cube_Woman_Character_75ikp7NEDx", "Farmer_7pn3R6hPvE",
    "Henry_yEdSk8tRKc", "Hooded_Adventurer_y9KWOVG21R",
    "Hoodie_Character_gKLBoRsyKe", "King_I1gTjmuK2m", "Lis_gjuwleUT1U",
    "Mako_2urczqZ9Xf", "Punk_BTALZymknF", "Punk_djXoqejw6w",
    "SWAT_Btfn3G5Xv4", "Sci_Fi_Character_4pUXv5V8kq", "Steve_OF8rWAO1gC",
    "Suit_sOUciDsoVV", "Witch_QBEOV9ZUT8", "Worker_E8079Ahx7k",
    "Worker_Yg2bQZO6Hj",
]

ATTACK_PRIORITY = [
    "Attack", "Sword_Slash", "Punch", "Staff_Attack", "Dagger_Attack",
    "Spell1", "Gun_Shoot", "Shoot_Small", "Shoot_Big", "Punch_Left",
    "Punch_Right", "Kick", "Kick_Left", "Kick_Right", "Weapon", "Bite",
    "Headbutt", "Slash", "Stab", "Idle_Attack", "Run_Attack",
]
HIT_CANDIDATES = ["HitReact", "HitRecieve", "HitRecieve_1", "HitRecieve_2", "Hit_reaction", "RecieveHit", "TakeHit"]
DIE_CANDIDATES = ["Death", "Die", "Dead"]


def clean_name(name: str) -> str:
    return name.split("|")[-1].strip()


def slugify(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", title.lower()).strip("_")


def read_glb(path):
    with open(path, "rb") as f:
        magic, version, length = struct.unpack("<III", f.read(12))
        if magic != 0x46546C67:
            raise ValueError("not a GLB: %s" % path)
        chunks = []
        while f.tell() < length:
            clen, ctype = struct.unpack("<II", f.read(8))
            chunks.append((ctype, f.read(clen)))
    return version, chunks


def write_glb(path, version, chunks):
    body = b""
    for ctype, data in chunks:
        body += struct.pack("<II", len(data), ctype) + data
    total = 12 + len(body)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, version, total))
        f.write(body)


def normalise_glb(src, dst, model):
    version, chunks = read_glb(src)
    json_idx = None
    for i, (ctype, _data) in enumerate(chunks):
        if ctype == 0x4E4F534A:
            json_idx = i
            break
    if json_idx is None:
        raise ValueError("no JSON chunk: %s" % src)
    doc = json.loads(chunks[json_idx][1].decode("utf-8"))

    name_map = {}
    for a in model.get("animations", []):
        if a.get("name"):
            name_map[a["name"]] = a.get("clean") or clean_name(a["name"])

    entries = []
    for idx, anim in enumerate(doc.get("animations", [])):
        orig = anim.get("name") or "clip_%d" % idx
        clean = name_map.get(orig) or clean_name(orig)
        if not clean:
            clean = "clip_%d" % idx
        # Prefer an unprefixed exact name when the same clip was uploaded twice.
        pref = 0 if orig == clean else 1
        entries.append({"idx": idx, "orig": orig, "clean": clean, "pref": pref})

    # One take per clean name. Short/unprefixed names win.
    chosen = {}
    for e in sorted(entries, key=lambda e: (e["pref"], len(e["orig"]), e["orig"])):
        chosen.setdefault(e["clean"].lower(), e)
    kept = list(chosen.values())

    clean_names = {e["clean"].lower(): e for e in kept}

    def pick(candidates):
        for cand in candidates:
            e = clean_names.get(cand.lower())
            if e:
                return e
        return None

    roles = {
        "walk": pick(["Walk"]),
        "run": pick(["Run", "Run2", "Running_Crawl"]),
        "idle": pick(["Idle", "Idle_Neutral"]),
        "attack": pick(ATTACK_PRIORITY),
        "hit": pick(HIT_CANDIDATES),
        "die": pick(DIE_CANDIDATES),
    }
    role_names = {k: (v["clean"] if v else "") for k, v in roles.items()}

    # Assign unique final names.
    used = set()
    final = {}
    # canonical roles first
    for role, entry in roles.items():
        if entry is not None:
            final[entry["idx"]] = role
            used.add(role)
    # everything else keeps its readable clean name
    for e in kept:
        if e["idx"] in final:
            continue
        base = re.sub(r"[^A-Za-z0-9_. -]+", "", e["clean"]).strip() or "clip"
        name = base
        n = 2
        while name.lower() in used:
            name = "%s_%d" % (base, n)
            n += 1
        final[e["idx"]] = name
        used.add(name.lower())

    dropped = 0
    new_anims = []
    for idx, anim in enumerate(doc.get("animations", [])):
        if idx not in final:
            dropped += 1
            continue
        anim["name"] = final[idx]
        new_anims.append(anim)
    doc["animations"] = new_anims

    data = json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    data += b" " * ((-len(data)) % 4)
    chunks[json_idx] = (0x4E4F534A, data)
    write_glb(dst, version, chunks)

    names = {final[i].lower(): final[i] for i in final}
    ordered = [final[e["idx"]] for e in kept if e["idx"] in final]
    return {
        "role_clips": {k: names.get(k, "") for k in roles},
        "role_source": role_names,
        "clips": ordered,
        "dropped_duplicates": dropped,
        "glb_bytes": os.path.getsize(dst),
    }


def main():
    walk = {x["key"]: x for x in json.load(open(os.path.join(ROOT, "_mob_library", "scripts", "audit_walk.json")))}
    walk_fix = {x["key"]: x for x in json.load(open(os.path.join(ROOT, "_mob_library", "scripts", "audit_walk_fix.json")))}
    walk.update(walk_fix)

    os.makedirs(OUT_MON, exist_ok=True)
    os.makedirs(OUT_HUM, exist_ok=True)
    used_slugs = set()
    sel = []

    for category, folders, outdir in (
            ("monster", MONSTERS, OUT_MON), ("humanoid", HUMANOIDS, OUT_HUM)):
        for folder in folders:
            src_dir = None
            for group in ("mobs", "mobs_extra"):
                cand = os.path.join(LIB, group, folder)
                if os.path.isdir(cand):
                    src_dir = cand
                    break
            if src_dir is None:
                raise SystemExit("missing source folder %s" % folder)
            model = json.load(open(os.path.join(src_dir, "model.json")))
            glb_src = os.path.join(src_dir, model["files"]["glb"])

            slug = slugify(model["title"])
            if slug in used_slugs:
                slug = "%s_%s" % (slug, model["publicID"][:4].lower())
            if slug in used_slugs:
                raise SystemExit("duplicate slug %s" % slug)
            used_slugs.add(slug)
            glb_dst = os.path.join(outdir, slug + ".glb")

            info = normalise_glb(glb_src, glb_dst, model)
            roles = info["role_clips"]
            if category == "monster":
                missing = [r for r in ("walk", "attack", "die") if not roles.get(r)]
                if missing:
                    raise SystemExit("%s missing monster roles %s" % (slug, missing))

            bounds = walk[folder]["bounds_walk"]
            raw_h = bounds["size"][2]
            raw_min_z = bounds["min"][2]
            raw_w = min(bounds["size"][0], bounds["size"][1])

            if category == "humanoid":
                # Town NPCs share the player's scale range. The monster-pack
                # humanoids (Ninja, Character Enemy, Cube people) are authored
                # 2-3x taller than the townsfolk, so they are normalised.
                target_h = 1.72 + (sum(ord(c) for c in slug) % 18) * 0.01
                scale = target_h / max(raw_h, 0.2)
                radius = max(0.22, min(0.42, raw_w * scale * 0.26))
                speed = 0.55 + (sum(ord(c) for c in slug) % 35) * 0.01
                wander = 1.8 + (sum(ord(c) for c in slug) % 25) * 0.1
            else:
                scale = 1.0
                radius = max(0.30, min(0.85, raw_w * 0.24))
                speed = max(0.8, min(1.7, 0.55 + raw_h * 0.22))
                wander = 4.0 + (sum(ord(c) for c in slug) % 41) * 0.1

            height = raw_h * scale
            foot_offset = -raw_min_z * scale + 0.02
            sel.append({
                "slug": slug,
                "name": model["title"],
                "category": category,
                "folder": folder,
                "glb": "res://" + os.path.relpath(glb_dst, ROOT).replace(os.sep, "/"),
                "height": round(height, 3),
                "raw_height": round(raw_h, 3),
                "radius": round(radius, 3),
                "scale": round(scale, 4),
                "foot_offset": round(foot_offset, 3),
                "speed": round(speed, 2),
                "wander": round(wander, 2),
                "yaw_offset": 0.0,
                "roles": roles,
                "clips": info["clips"],
                "tris": model.get("tris"),
                "bones": model.get("bones"),
                "licence": model.get("licence"),
                "creator": model.get("creator"),
                "page": model.get("page"),
                "dropped_duplicates": info["dropped_duplicates"],
                "glb_bytes": info["glb_bytes"],
            })
            print("NORMALISED %-10s %-42s h=%.2f scale=%.2f roles=%s" % (
                category, slug, height, scale, info["role_clips"]), flush=True)

    with open(OUT_SEL, "w") as f:
        json.dump(sel, f, indent=1)
    print("SELECTED monsters=%d humanoids=%d" % (
        sum(1 for x in sel if x["category"] == "monster"),
        sum(1 for x in sel if x["category"] == "humanoid")))


main()
