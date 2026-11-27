# Walled town, Godot package

Built in Blender 5.3 from the map drawing. One static town inside its wall ring.
No interiors, no animation, no rig. One unit is one metre, Z up in Blender, Y up
in the GLB (the exporter converted it), origin at the town's centre on the
ground plane.

## Files

    town_godot.glb        65 MB, geometry and 15 embedded textures
    textures/             37 MB, the same textures as loose files
    README.md             this file

`town.blend` (the source scene) and `town_export.blend` (the baked export scene)
sit one folder up, outside this package.

## What is in the GLB

    5 meshes       SM_Town_Buildings, SM_Town_Ground, SM_Town_Props,
                   SM_Town_Rampart, SM_Town_Vegetation
    64 primitives  one per material slot
    358k triangles
    63 materials   plain metallic-roughness, metal 0
    105 m across, buildings reach 13.5 m above the ground

Each mesh is one collection from the source scene joined into a single object:
you get the whole town as five meshes, not 1,225 separate objects. That keeps
draw calls low at the cost of per-building culling. If you need buildings
separately, say so and the source can be re-exported per object, but each
building then needs its own texture set.

## Textures

One atlas per mesh, three maps each:

    T_<mesh>_albedo.jpg     base colour
    T_<mesh>_rough.jpg      roughness, half resolution
    T_<mesh>_normal.png     tangent-space normal, full resolution

Ground, Buildings and Props atlases are 4096, Rampart and Vegetation are 2048,
roughness at half of that. The atlases were baked from the procedural materials
in Cycles, so every material name in the GLB is a generic `M_<mesh>_NN`. The
look is in the textures, not in the material parameters.

The GLB embeds all 15 textures, so you can drop the single file in and skip the
`textures/` folder. Keep the folder if you want to edit or downscale maps in
Godot without re-exporting.

## Importing into Godot 4

1. Drop `town_godot.glb` into the project, let it import.
2. Open the imported scene and instance it in your level.
3. Select the imported `.glb` in the FileSystem dock, open Advanced Import
   Settings, and check the materials. glTF materials arrive as
   `StandardMaterial3D` with albedo, roughness and normal already wired.
4. Optional: in the mesh import settings, enable Generate LODs if you want the
   engine to build them, and set a mesh compression if the file size matters.
5. Collision: there is none. The ground is a heightfield-like scan of the
   town's surface, not a collider. For a walkable level, either add a
   `CollisionShape3D` with a `ConcavePolygonShape3D` built from the Ground and
   Buildings meshes, or block the town out with simple boxes. A concave shape
   over 358k triangles is heavy; the usual route is a low-poly collision mesh.
6. The town is a diorama: the ground ends in a cliff at the island's edge. If
   the camera can see the bottom, put something under it or hide the edge in
   the level design.

## Known gaps

- Smoke is not in the export. It was alpha cards and would have shipped as
  solid grey lumps. Add it as a GPUParticles3D over three chimney positions if
  you want it.
- No interior geometry, no doors that open, no NPCs. There is one fenced pen
  with sheep and no other livestock.
- The normal maps carry baked surface detail only; there are no separate AO or
  metallic maps, and metal is 0 everywhere except the well's ironwork, which is
  baked into the albedo.
- Textures are not power-of-two-packed per object; they are atlases per mesh, so
  UV islands are dense and texel density varies between a large roof and a
  small barrel.
