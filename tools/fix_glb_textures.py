#!/usr/bin/env python3
"""Re-encode a GLB's embedded images so Godot can decode them.

Blender's JPEGs carry segments Godot's bundled jpgd rejects: load_jpg_from_buffer
returns ERR_FILE_CORRUPT (43) while the PNG maps in the same file decode fine,
so the town imports with every albedo and roughness map missing and renders flat
white.  Re-encoding through PIL produces baseline JFIF files Godot accepts.

Rebuilds the GLB in place: image bufferViews are replaced and every bufferView
offset and length is recomputed, so mesh data is preserved byte-for-byte.
"""
import json
import struct
import sys
import io
from PIL import Image

PATH = sys.argv[1] if len(sys.argv) > 1 else "assets/worlds/town_godot.glb"
QUALITY = 92


def read_glb(path):
    data = open(path, "rb").read()
    magic, version, total = struct.unpack("<III", data[:12])
    assert magic == 0x46546C67, "not a GLB"
    off = 12
    js = None
    binary = b""
    while off < total:
        clen, ctype = struct.unpack("<II", data[off:off + 8])
        chunk = data[off + 8:off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            binary = chunk
        off += 8 + clen
    return js, binary


def write_glb(path, js, binary):
    jb = json.dumps(js, separators=(",", ":")).encode("utf-8")
    jb += b" " * ((4 - len(jb) % 4) % 4)
    bb = binary + b"\x00" * ((4 - len(binary) % 4) % 4)
    total = 12 + 8 + len(jb) + 8 + len(bb)
    out = struct.pack("<III", 0x46546C67, 2, total)
    out += struct.pack("<II", len(jb), 0x4E4F534A) + jb
    out += struct.pack("<II", len(bb), 0x004E4942) + bb
    open(path, "wb").write(out)


def mime_of(raw):
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png", "png"
    if raw[:2] == b"\xff\xd8":
        return "image/jpeg", "jpeg"
    return None, None


def main():
    js, binary = read_glb(PATH)
    views = js["bufferViews"]
    images = js.get("images", [])
    print("images to rebuild:", len(images))

    # Pull every bufferView's bytes, so we can re-lay them out contiguously.
    contents = []
    for i, bv in enumerate(views):
        s = bv.get("byteOffset", 0)
        contents.append(bytearray(binary[s:s + bv["byteLength"]]))

    changed = 0
    for idx, im in enumerate(images):
        vi = im.get("bufferView")
        if vi is None:
            continue
        raw = bytes(contents[vi])
        mime, kind = mime_of(raw)
        if mime is None:
            print("  image %d: unknown container, left alone" % idx)
            continue
        try:
            pil = Image.open(io.BytesIO(raw))
            pil.load()
        except Exception as exc:
            print("  image %d: PIL cannot open (%s), left alone" % (idx, exc))
            continue
        buf = io.BytesIO()
        if kind == "png":
            # Normals must stay lossless; drop alpha only if it is fully opaque.
            out = pil.convert("RGB") if pil.mode not in ("RGB", "L") else pil
            out.save(buf, "PNG", optimize=True)
            new_mime = "image/png"
        else:
            out = pil.convert("RGB")
            out.save(buf, "JPEG", quality=QUALITY, progressive=False,
                     optimize=True, subsampling=2)
            new_mime = "image/jpeg"
        new = buf.getvalue()
        before = len(raw)
        contents[vi] = bytearray(new)
        if im.get("mimeType") != new_mime:
            im["mimeType"] = new_mime
        changed += 1
        print("  %-22s %-5s %8d -> %8d bytes  %s" % (
            im.get("name", idx), kind.upper(), before, len(new), new_mime))

    # Re-lay out every bufferView, honouring 4-byte alignment.
    new_bin = bytearray()
    for i, bv in enumerate(views):
        pad = (4 - len(new_bin) % 4) % 4
        new_bin.extend(b"\x00" * pad)
        bv["byteOffset"] = len(new_bin)
        bv["byteLength"] = len(contents[i])
        new_bin.extend(contents[i])
    js["buffers"] = [{"byteLength": len(new_bin)}]

    # Geometry bounds were not touched.
    write_glb(PATH, js, bytes(new_bin))
    print("REBUILT %s  images_changed=%d  bin=%d bytes" % (
        PATH, changed, len(new_bin)))


main()
