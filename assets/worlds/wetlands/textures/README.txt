No bitmap textures are included in this package.

All colour is stored as COLOR_0 vertex colours on the nine GLB primitives. The
source Blender scene used procedural node trees and image textures for ground,
stone, wood, bone, flesh, and water ripples; those do not survive glTF cleanly,
so they were replaced with per-vertex colour.

See ../README.md for the Godot vertex-colour import note.
