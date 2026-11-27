# Floating town, Godot package

Built in Blender 5.3 from the map drawing. One static floating-island diorama.
No interiors, no animation, no rig. One unit is one metre, Z up in Blender, Y up
in the GLB (the exporter converted it), origin at the island's centre on the
ground plane.

## Files

    town_godot.glb        108 MB, geometry, 13 embedded textures, vertex colours
    textures/             14 source texture files (loose copies)
    README.md             this file

`godot_bake.blend` (the export scene) sits one folder up, outside this package.

## What is in the GLB

    6 meshes       SM_Town_Buildings, SM_Town_Ground, SM_Town_Props,
                   SM_Town_Rampart, SM_Town_Vegetation, SM_Town_Water
    215 primitives one per material slot
    1,432,386 triangles
    185 materials  plain metallic-roughness, metal 0, roughness 0.85
    185 m across

Each mesh is one category from the source scene joined into a single object:
you get the whole island as six meshes, not 7,452 separate objects. That keeps
draw calls low at the cost of per-object culling.

## Colour: tiling textures plus vertex colours

**This is the important difference from `town_godot_package.zip`.**

That package baked procedural materials into per-mesh atlases. This scene
cannot use that approach:

- **7,409 of 7,452 source objects had no UV map.** They were coloured by
  procedural node trees (colour ramps, noise, mix chains) evaluated in object
  space, so there were no UVs to bake into.
- **777,746 of the 1,432,386 triangles are vegetation** — individual grass
  blades, leaves and ferns. Smart UV Project packs those into islands with
  sub-pixel area, so a 4096 atlas bakes to uniform noise. This was tried and
  produced an unusable green smear.

So it ships as **tiling textures on cube-projected UVs, modulated by
`COLOR_0` vertex colours**. Every material gets a base colour texture from
`textures/` chosen by name (plaster, slate, wood, planks, stone, granite, dirt,
cobble, grass, leaf, bark, door, window). 156 of 185 materials carry a texture.

**Vegetation is textureless and colour-only.** Trees, bushes and pines use
`COLOR_0` alone, so their hue comes through directly. This was deliberate: with
a texture attached, the multiply is not guaranteed to survive the importer and
the trees rendered white. Colour-only proved reliable.

Ground, buildings, props, rampart and water carry **white** vertex colour so the
texture shows its own colour unmodulated.

**In Godot:** the glTF importer creates `StandardMaterial3D` with
`vertex_color_use_as_albedo` enabled when a mesh has `COLOR_0` and a white base
colour factor. If the island renders white or grey on import, set
**Albedo → Vertex Color Use As Albedo** on the materials, or run:

```gdscript
for mesh_instance in find_children("*", "MeshInstance3D", true, false):
    var mat := mesh_instance.get_active_material(0)
    if mat is StandardMaterial3D:
        mat.vertex_color_use_as_albedo = true
```

## What you lose compared with the Blender render

The colour is right; the fine surface detail is not. There is no baked leaf,
bark or stone texture on the meshes, so up close the vegetation reads as flat
coloured geometry. At the diorama's viewing distance that is close to the
Blender result, but it is not identical.

The source textures are in `textures/` if you want to rebuild materials with
real maps per category. Doing so needs UVs, which the meshes now have (Smart UV
Project was applied), and a bake at a resolution high enough for the vegetation
density — realistically that means splitting vegetation into species groups of
a few thousand faces each rather than one 777k-face mesh.

## Importing into Godot 4

1. Drop `town_godot.glb` into the project and let it import.
2. Open the imported scene and instance it in your level.
3. Select the `.glb` in the FileSystem dock, open Advanced Import Settings, and
   confirm the materials have vertex-colour-as-albedo enabled.
4. Optional: enable Generate LODs in the mesh import settings. 1.43M triangles
   is heavy for a single view; LODs help.
5. **Collision: there is none.** Add a `CollisionShape3D` with a
   `ConcavePolygonShape3D` built from `SM_Town_Ground`, or block the level out
   with simple boxes. A concave shape over 1.4M triangles is impractical; build
   a low-poly collision mesh instead.
6. The island is a diorama: the ground ends in a cut edge showing soil and rock.
   If the camera can see underneath, put something below it or hide the edge.

## Known gaps

- **No texture atlases.** See above. Vertex colours only.
- **No lighting.** The Blender scene's sun, fill, rim, campfire and stone-circle
  lights are not exported. You need a `DirectionalLight3D` plus whatever local
  lights you planned; the Blender render used exposure 1.32, world strength 1.45
  and AgX Medium High Contrast.
- **No water shading.** `SM_Town_Water` is flat geometry with the baked colour.
  For anything convincing, give it a `StandardMaterial3D` with transparency,
  metallic ~0.3, roughness ~0.15, and a normal map.
- **The crystal will not glow** unless you set emission on its material.
- Smoke is not in the export; it was alpha cards.
- No interiors, no doors that open, no NPCs.
- No AO or metallic maps, metal is 0 everywhere.
- **Trees have no texture detail.** Vegetation is flat vertex colour on smooth
  blobs, so up close they read as coloured spheres. The Blender render had a
  leaf texture multiplied in. Adding it back requires the importer to honour
  COLOR_0 x baseColorTexture together; test on one material before rolling out.
- **Trees are brighter than the Blender render.** The palette was lifted ~1.95x
  because the unlit deep tones read near-black in engine. If they look garish
  under your lighting, scale the vegetation albedo down.
- **No normal or roughness maps.** Everything is roughness 0.85, metal 0.
- **The waterfall** uses a flat teal material with no transparency.
