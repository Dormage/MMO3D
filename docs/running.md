# Running MMO3D

## The game

```bash
./run_game.sh                     # town, Compatibility renderer
./run_game.sh --region=ruins2     # jump straight to a map
PERF_LOG=1 ./run_game.sh          # per-2s perf line (fps/proc/phys/draws/prims/objs)
```

The project defaults to the **Compatibility (GLES3)** renderer because the
integrated Intel GPU is roughly twice as fast on it.

## The editor — must use Forward+

```bash
./run_editor.sh
```

**Opening the project with the editor on Compatibility segfaults.** Godot's own
`SceneShaderGLES3` vertex shader fails to compile on this Mesa/Intel driver and
the GL backend then crashes during teardown:

```
ERROR: SceneShaderGLES3: Vertex shader compilation failed
ERROR: Method/function failed.
handle_crash: Program crashed with signal 11
```

It is not caused by project content: the editor runs 2+ minutes with
`--rendering-method forward_plus` and never crashes, while the *game* runs fine
on Compatibility. The launcher overrides the renderer for the editor session
only, leaving `project.godot` on Compatibility so the Play button still uses the
fast path.

## Diagnostics

| flag | effect |
|---|---|
| `--region=<id>` | start in a region (town, island, graveyard, wetlands, desert, ruins2) |
| `--naptest` | walk a navmesh route automatically |
| `--switchtest` | switch region 90 frames after start (reproduces reload bugs) |
| `--lum` | print mean screen luminance, then quit |
| `SHOT=/path.png` | with `--lum`, save the frame |
| `--overview` | wide camera for screenshots |
| `--meshdiag` | report visible/hidden mesh counts |
| `PERF_LOG=1` | perf line every 2 s |
| `--noshadow --norefl --unshaded --noveg --nodecor --nopop --minphys` | strip features to isolate cost |
