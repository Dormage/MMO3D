#!/usr/bin/env python3
"""Reconstruct real Unity asset folder trees from extracted .unitypackage GUID folders."""
import json
import os
import shutil

BASE = "/home/dormage/code/MMO3D2/_asset_audit"
PKGS = os.path.join(BASE, "pkgs")
TREE = os.path.join(BASE, "tree")

manifest = {}
for pkg in sorted(os.listdir(PKGS)):
    src = os.path.join(PKGS, pkg)
    if not os.path.isdir(src):
        continue
    entries = []
    for guid in sorted(os.listdir(src)):
        d = os.path.join(src, guid)
        pn = os.path.join(d, "pathname")
        asset = os.path.join(d, "asset")
        if not (os.path.isfile(pn) and os.path.isfile(asset)):
            continue
        with open(pn, "r", encoding="utf-8", errors="replace") as f:
            rel = f.read().strip().split("\n")[0].strip()
        if not rel:
            continue
        dest = os.path.join(TREE, pkg, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        try:
            if not os.path.exists(dest):
                os.link(asset, dest)
        except OSError:
            shutil.copy2(asset, dest)
        meta = os.path.join(d, "asset.meta")
        if os.path.isfile(meta) and not os.path.exists(dest + ".meta"):
            try:
                os.link(meta, dest + ".meta")
            except OSError:
                shutil.copy2(meta, dest + ".meta")
        entries.append({"guid": guid, "path": rel, "size": os.path.getsize(asset)})
    manifest[pkg] = entries
    print(f"{pkg}: {len(entries)} assets")

with open(os.path.join(BASE, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=1)
print("total packages:", len(manifest))
