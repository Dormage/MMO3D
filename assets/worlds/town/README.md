# Walled town, Godot package

Built in Blender 5.3 from the map drawing. One static town inside its wall ring.
No interiors, no animation, no rig. One unit is one metre, Z up in Blender, Y up
in the GLB (the exporter converted it). The scene origin sits at the middle of
the traced map, and the built town measures 105.3 m by 94.1 m with its centre 0.5 m east and
4.4 m south of that origin, so place it by its bounds rather than by the node's
origin. Terrain top is Y 0, the street kerb stones reach 0.102 while the rampart kerb
reaches 0.260, roofs reach 12.95, and
the island underside drops to Y -4.5.

Blender is Z up with +Y north, and the exporter turns that into glTF's Y up. A
Blender position (x, y, z) arrives in Godot as (x, z, -y), so north comes out as
negative Z. Flip that sign when you compare these notes with a position in the
editor. The five nodes carry no rotation to compensate.

## Files

    town_godot_package.zip   74.2 MiB, carrying the other three items, zipped
    town_godot.glb           58.86 MiB, geometry and 15 embedded textures
    textures/                34.23 MiB, the same textures as loose files
    README.md                this file

`town.blend` (the source scene) and `town_export.blend` (the baked export scene)
sit one folder up, outside this package.

## What is in the GLB

    5 meshes       SM_Town_Buildings, SM_Town_Ground, SM_Town_Props,
                   SM_Town_Rampart, SM_Town_Vegetation
    5 primitives   one per mesh
    360,022 triangles, 467,292 vertices
    5 materials    plain metallic-roughness, metal 0, double-sided
    105.3 m by 94.1 m, buildings reach 12.95 m above the ground

Each mesh is one collection from the source scene joined into a single object
with one material: the town arrives as five meshes and five draw calls, where
the source scene has 1,367 meshes among 1,384 objects. The cost is per-building
culling, and a hit on any part of a mesh draws all of it. If you need
buildings separately, the source can be re-exported as loose parts: loose parts
keep their atlas UVs, so the same five texture sets still apply. Splitting each
mesh into four spatial chunks instead would give 20 draw calls and restore some
culling where five big meshes hurt on mobile.

Every node arrives with an identity transform, so a node's bounds in the GLB
are world-space bounds: no node carries a rotation or an offset to compensate
for.

The join also strips modifiers: 670 Bevel and 783 EdgeSplit come off before the
export, and the working scene's 892,198 evaluated triangles become 361,686 in
the five joined meshes, counted a fan per face. Triangulation and glTF's degenerate-face
removal leave 360,022 in the GLB. The three smoke puffs are not
part of those meshes: the join skips them, and their 2,640 triangles stay in the
source scene. The baked normal
map keeps the chamfers looking cut on flat faces.
Silhouettes of thin props lose the last millimetre of roundness. Keep the
beveled scene for hero shots and the GLB for gameplay.

## Textures

One atlas per mesh, three maps each:

    T_<mesh>_albedo.jpg     base colour, JPEG quality 90
    T_<mesh>_rough.png      roughness, full resolution, PNG, linear data
    T_<mesh>_normal.png     tangent-space normal, full resolution, PNG

Ground, Rampart, Buildings and Props atlases are 4096, Vegetation is 2048,
roughness at full resolution. UV island area covers 42 percent of the Ground
atlas, 25 of Rampart, 40 of Buildings, 44 of Props and 53 of Vegetation, so the
sheets are reasonably full and the texel density suits a third-person camera. The atlases were baked from the procedural materials
in Cycles, so the five materials are named `M_Buildings`, `M_Ground`,
`M_Props`, `M_Rampart` and `M_Vegetation`.
The look is in the textures, not in the material parameters.

Measured size of the 15 maps: albedo 11.42 MiB, roughness 6.13 MiB loose and
5.67 MiB inside the GLB, normal 16.69 MiB, 34.23 MiB in total as loose files. Roughness stays PNG because saving it as
JPEG runs a linear image through the display transform: a linear 0.42 became
0.66 and the town read about 1.6 times too rough. The normal maps are the
biggest single item and the ones worth dropping first if the download matters.

glTF has no separate roughness slot, so the exporter packs roughness into the
green channel of a metallicRoughness image and leaves red and blue at 1.0.
Metallic factor is 0, which nulls blue. Only the five roughness PNGs are
re-encoded inside the GLB, with red and blue forced to 255 while the green
channel is identical to the loose file. Albedo and normal images are
byte-identical to the loose copies. If you ever raise metallic on
these materials you must repack the channels first, or the whole town turns
metal.

The GLB embeds all 15 textures, so you can drop the single file in and skip the
`textures/` folder. Keep the folder if you want to edit or downscale maps in
Godot without re-exporting.

## Importing into Godot 4

1. Drop `town_godot.glb` into the project, let it import.
2. Open the imported scene and instance it in your level.
3. Select the imported `.glb` in the FileSystem dock, open Advanced Import
   Settings, and check the materials. glTF materials arrive as
   `StandardMaterial3D` with albedo, roughness and normal already wired, five
   of them, one per mesh.
4. Optional: in the mesh import settings, enable Generate LODs if you want the
   engine to build them, and set a mesh compression if the file size matters.
5. Collision: there is none. For a walkable level, add `CollisionShape3D`
   nodes holding `ConcavePolygonShape3D` shapes, one mesh per shape, built from
   the five merged meshes rather than from named parts. Ground
   holds two objects, `SM_Terrain` and the 68 street kerb stones of
   `SM_RoadKerb_in`. Both cobbled squares are flat paving on the terrain surface
   at 0.00 m, with no separate paving geometry: the disc reaches 12.3 to 13 m
   from each well, about 25 m across, and runs under the surrounding buildings.
   Rampart holds the curtain wall, its walk at 0.17 m, the wall towers and the
   two continuous kerb sweeps, so the walk is floor too. Together those two
   meshes are 120,840 triangles.

   Buildings holds the buildings, the two wells and the shrine. Props is not
   floor, but eight pieces of it stand high enough to step on: the four
   `SM_Field` crop beds at 0.391 to 0.485 m, the three market cross steps at
   0.199, 0.409 and 0.639 m, and the cemetery wall at 0.798 m. In the GLB those
   are merged into `SM_Town_Props` and cannot be selected on their own, so either
   give Props one shape of its own, 92,062 triangles, or accept stepping through
   them. The rest of Props is loose objects and dressing: 503 toe rock pieces under
   the island edge, 38 gravestones, two sheep pens with 6 sheep, a cattle pen
   with 5 cows, stalls, carts, troughs, barrels and goods piles. The object names
   in this file are `town.blend` names: the GLB has five nodes and nothing
   finer.

   Ground, Rampart and Buildings together are 205,772 triangles, and all five
   meshes are 360,022, which is heavy for collision, so the usual route is a
   second low-poly collision mesh or boxes.
6. The town is a diorama: the ground ends in a cliff at the island's edge. If
   the camera can see the bottom, put something under it or hide the edge in
   the level design.

## What is in the town

Five meshes carry 1,364 joined meshes. The scene holds 1,384 objects: those
1,364 meshes, three smoke puffs that the join skips, 16 lights and 1 camera.
The lights and the camera do not export. The Buildings collection holds 45
objects: 42 buildings plus the two well structures and the cemetery shrine.

- Buildings: 6 houses, 5 cottages, 1 small house, 5 halls, 3 terraces of
  joined row houses (`SM_terrace_00`, plus the `SM_row_00` and `SM_row_01`
  pairs), 4 wall houses, 14 sheds, 1 barn, 1 tower (the round keep
  `SM_tower_11`, its roof at 12.95 m). Roofs are tile, shingle and slate. There is no thatch on
  any building; the thatch material is on hay and straw props only.
- Rampart: the curtain wall with its walk at 0.17 m, 136 merlons, 8 square
  wall-tower pavilions with doors and door lamps, the two gate blocks and their
  spans, and the two continuous kerb sweeps along the walk, whose tops reach
  0.26 m. The walk runs in two arcs, one from each gate to the other, because
  the two gate blocks are solid at walk level: a player walks from gate 0 round
  to the far gate without leaving the wall. Each of the eight pavilions carries
  a passage through its base 1.20 m wide and 2.30 m high, with the walk plate as
  its floor and the plinth course standing 10 mm proud inside it. The kerb runs
  through the passages too, so it is one sweep per half ring with no cut ends.
  A stone step at every tower door sits at 0.265 m, 0.095 m above the walk.
- Ground: the terrain, both cobbled squares as flat paving, and the 68 street
  kerb stones of `SM_RoadKerb_in` at 0.102 m.
- Squares and market: 2 cobbled squares, 2 wells with their own lamps, a
  market cross in 11 parts, 7 market stalls, 4 crop beds, roadside goods.
- Livestock: 2 sheep pens with 6 sheep, 1 cattle pen with 5 cows.
- Cemetery: 38 gravestones, a low wall and a shrine, all inside the ring road;
  the nearest grave is 17.5 m from the west gate and the group's centre 25 m.
- Green: 31 trees and 32 bushes, all 63 Vegetation objects on the plateau
  inside the walls. The slopes outside are bare rock.
- 503 toe rock pieces, each deformed by a per-name hash so no two are the same shape, under the island edge, and 3 smoke puffs that stay in
  `town.blend` and never reach the GLB.
- 16 lights in `town.blend`: 13 point lamps, including the 8 `L_TowerDoor`
  lamps and the lanterns over the two wells, and 3 suns. None ship in the GLB.

## Known gaps

- Smoke is not in the export. It was alpha cards and would have shipped as
  solid grey lumps. Add it as a GPUParticles3D over three chimney positions if
  you want it.
- No interior geometry, no doors that open, no NPCs. Livestock is props only:
  two market sheep pens with six sheep, and a cattle pen with five cows.
- Window panes, lanterns and lamp glass are baked into the albedo, so at dusk
  they will not glow on their own. For the lit-window look, add an emissive
  material on those faces or a light per window. `town/scene.py` has the two
  presets: `apply_hour("noon")` keys a high sun, a cool sky and 0.26 strength
  mist; `apply_hour("dusk")` keys a low warm sun, drops the mist to 0.15 and
  warms its colour to (0.44, 0.32, 0.27).
- The gate spans meet at y = 0 with 1.742 square metres of coincident face:
  0.516 at the east gate between `SM_GateSpan_0_1` and `_0_-1`, 1.226 at the
  west between `SM_GateSpan_1_1` and `_1_-1`. The two door leaves of each gate
  also butt on a 0.465 square metre centre seam. These faces meet inside a
  joined solid rather than under open sky, so they do not z-fight; delete them
  if your collision builder objects to coincident faces. A further 2.875 square metres of coincident faces sit where
  the five gate merlon bottoms meet the tops of `SM_GateParapet_0` and `_1`, and
  those are deliberate: the merlons are set into the parapet. The 131 wall
  merlons share no face at all, since their bottoms sit at 3.14 m against a
  coping top at 3.18 m.
- There are no separate AO or metallic maps. Metal is 0 on every material, and
  the well's ironwork is colour in the albedo, not a metal response.
- Paving joints are in the Ground normal map: 1.60 percent of the sheet
  deviates by more than 4 of 255 in red or green (blue is the flat axis); the
  joint cores alone are 0.53 percent at 22 degrees mean, and the steepest
  joint flank tilts the surface 33.9 degrees. A lane joint is 1 texel wide, 5 cm at
  the Ground's 20.6 pixels per metre; a plaza joint is 1.9 texels, 9.3 cm.
  The sheet holds 20.6 pixels per metre, so the joints survive until about mip
  2: roughly 180 m from a perpendicular view, about 60 m at a 20 degree
  camera angle. Props carries the most, 14.8 percent of its sheet past 4 of 255, then
  Buildings at 11.31. Rampart and Vegetation hold mostly broad form slopes. Every
  material is double-sided, metal 0, and none is emissive.
- The GLB has no light entities and no emissive materials: the lamps, lanterns
  and lit windows are geometry and baked colour. Light the town from the engine
  side, or copy the two presets in `town/scene.py` (`apply_hour` with "noon" and
  "dusk") for the intended key angles and lamp watts: noon runs a strong high
  sun with cool fill, dusk a low warm key with the mist thinned to 0.15.
- Every primitive carries TANGENT and the meshes are triangulated, so the
  normal maps light as baked. Nothing else rides in the file: no extensions,
  no cameras, no lights.
- Texel density varies between meshes rather than within one. Packing by island
  area keeps each sheet even to within 1.09 to 1.26 times between its 5th and
  95th percentile. Ground sits at 20.6 pixels per metre, Rampart 20.6,
  Buildings 16.86 (a 5.9 cm texel, the softest of the five), Props 47.42 and
  Vegetation 26.74, so stonework reads softer than barrels and crates up
  close. Rampart's sheet was 2048, which put a stone joint on 1 to 2 pixels;
  it is 4096 now.
