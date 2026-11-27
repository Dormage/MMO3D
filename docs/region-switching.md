# Region transitions and repeated loading

This change follows the Compatibility/OpenGL performance work. It addresses
scene replacement and work that was still repeated when revisiting a map.

## The OpenGL crash was a shadow LOD mismatch

The full rendered switch test reproduced a native signal 11 on both official
Godot 4.6.3 and 4.7.2 when desert became visible after leaving town. Moving the
transition to a persistent owner and waiting two frames did not prevent it.

The generated render meshes had new LOD index buffers, but the helper assigned
the original imported `shadow_mesh` to those rebuilt meshes. The shadow mesh
could have a different number of surfaces or LOD levels. In the GLES3 shadow
pass, the renderer selects a level using the main surface and applies that
level to the shadow surface. The captured crash instruction dereferenced that
shadow LOD's index buffer.

The same full rendered town -> desert -> town route passed independently with
`--no-render-lods` and with `--noshadow`, including visible geometry and player
movement. The repaired default then passed that route with **both render LODs
and shadows enabled** on 4.6.3.

The repair clears only the obsolete optimized `shadow_mesh` on a mesh whose
LODs were regenerated. The engine then uses that main mesh's matching LOD
buffers for ordinary shadow rendering. Shadow casting remains enabled; base
geometry, materials, collision, and navigation are unchanged. The tradeoff is
giving up a separate vertex-optimized shadow mesh on these regenerated meshes.
Meshes that do not receive new LODs keep their original resources.

The native attribution was checked against the official
[GLES3 index-buffer accessor](https://github.com/godotengine/godot/blob/4.6.3-stable/drivers/gles3/storage/mesh_storage.h)
and [shadow render path](https://github.com/godotengine/godot/blob/4.6.3-stable/drivers/gles3/rasterizer_scene_gles3.cpp).
The official Linux executable is stripped: this is a match between its faulting
instruction and the engine's inline LOD accessor, supported by the controlled
runs, rather than a fully symbolized backtrace.

Existing conditioned-region caches automatically invalidate when
`scripts/region_render_lods.gd` changes. Their cache key already includes that
helper's file stamp, so users do not need to delete the import cache manually.

## Scene replacement must outlive the outgoing scene

The previous two-stage reload ran on `Game`. It queued that same scene for
deletion, awaited two process frames, then attempted to load the replacement.
Deletion canceled the coroutine that was supposed to complete the transition.

An isolated reproduction of that exact code on official Godot 4.6.3 and 4.7.2
reported:

```text
old_alive=false resumed=false second_loaded=false current_scene=null
```

A surviving process therefore was insufficient evidence of a working switch.
The scene could disappear without the process reporting an error.

`RegionState`, the persistent autoload, now owns the transition. It validates
the replacement `PackedScene`, sets an immediate busy guard, unloads the old
scene, waits two process-frame boundaries, and attaches the replacement. The
separation allows the normal engine teardown/synchronization cycle to run
before replacement construction. It is not described as a general GPU fence.
An unconditional `frame_post_draw` wait is avoided because headless or suspended
rendering need not emit it.

`Game` also rejects region input before its camera and navigation initialization
are complete. `scene_changed` alone is insufficient: the game's asynchronous
startup continues across physics frames after its scene is attached.

Existing controls are preserved: **Tab selects the previous registry entry;
Shift+Tab selects the next**. From town, ordinary Tab selects desert. Repeated
Tab/number-key input during teardown does not change the pending destination or
start another reload.

## Repeated work and inconsistent scene caches

### Authored navigation always missed its cache

Town, desert, and graveyard provide separate authored navigation GLBs. The
navigation builder had a `marker_file` field for identifying those files, but
the game never assigned it. Cache lookup therefore used the fallback signature
with `source_faces=0`, before geometry inspection; cache saving used the eventual
nonzero face count. The two keys could never match.

The game now supplies the region's `nav_glb_path`. The authored-navigation key
uses the source path and file stamp, the navigation script stamp, a cache
version, and relevant bake settings. Geometry is unchanged; a later load can
actually reuse the previously baked `NavigationMesh`.

### Navigation links were recomputed after every cache hit

The saved navigation mesh did not include the results of `_stitch_islands()`.
That routine repeatedly searches disconnected polygon groups for appropriate
links, respecting maximum gap, height difference, water, and bridges.

The first instrumented warm town reload spent **4.340 seconds** in stitching,
out of **5.755 seconds** until playable. Its navigation mesh was already a cache
hit. A desert run spent **6.623 seconds** in the separate Recast bake that the
authored-file key now allows it to skip. These are measurements from the test
host, not estimates for the user's GPU or CPU.

The follow-up stores the existing stitch algorithm's exact ordered endpoints as
small navigation-resource metadata. Reuse must match the actual navigation
geometry, water footprint, bridge segments, gap/rise settings, and algorithm
version. Missing, stale, or invalid metadata falls back to the original search.
It does not retain old scenes or accumulate graphics resources for every map.

### Cached water state could trigger another navigation bake

The five-map checks found a separate wetlands cache inconsistency. The cold
load finalized gameplay water at **0.00 m**, but loading the conditioned scene
measured it as **0.05 m**. `_measure_water()` rounded authored heights to
0.05 m, while the cold-only `_extend_water()` used 0.10 m rounding and overwrote
the final water level. The revisit skipped that second step. This changed
walkable face filtering and correctly invalidated navigation, costing another
**13.158 seconds of Recast baking** in the captured revisit.

The conditioned scene now preserves its finalized gameplay water level,
presence flag, and footprint mask as versioned metadata. Cached loads restore
that state instead of deriving a different result from already conditioned
geometry. Invalid or missing metadata causes a rebuild from the source.

Generated `WaterExtension` and `WaterBarrier` nodes also belonged to the region
host outside the packed subtree, so they disappeared on cached loads. They
are now included at final packing, with their world transforms preserved.
This keeps the cached scene's generated water surface and barrier consistent
with the cold scene.

## Measured loading results

The controlled CPU comparison used official Godot 4.6.3 on an AMD EPYC 9V74
host, headless, with population disabled. The region and baked navigation
caches were both already warm for the return to town. Only reuse of the stitch
metadata was disabled in the comparison run.

| Return to town | Recompute stitching | Reuse stitch metadata |
| --- | ---: | ---: |
| Time until playable | 5.728887 s | 1.554021 s |
| Navigation-link stitching | 4159.111 ms | 2.777 ms |
| Total navigation phase | 4184.496 ms | 8.082 ms |

That measured return became **72.9% shorter**. These are individual controlled
samples, not a distribution of load times or a prediction for another CPU.
The separate desert navigation bake measured 6622.724 ms before reuse; the
cached mesh and link metadata reduced its complete navigation phase to
12.995 ms in the later run. Remaining work includes mesh instantiation,
collision construction, actor startup, and engine synchronization.

First visits after a source/helper update still regenerate the affected
caches. In particular, the first desert visit in the `--no-stitch-cache` run
also rebaked navigation after its signature changed; its full load time must
not be used to attribute the entire improvement to stitching alone.

After the water-state repair, a final headless run completed **two full cycles
(ten transitions)** on 4.6.3. Every second-cycle destination hit the conditioned
scene cache, baked navigation cache, and stitch cache, with no Recast bake.

| Map | Second-cycle time until playable |
| --- | ---: |
| Town | 1.333007 s |
| Desert | 2.085752 s |
| Island | 2.670116 s |
| Graveyard | 2.724266 s |
| Wetlands | 3.648586 s |

Wetlands retained the same 0.00 m water level and 11,445 navigation polygons on
both visits. The first cycle still paid the one-time cost of conditioning the
large source scenes; these repeat-load times must not be presented as first
installation or asset-import times. Population was disabled in this CPU
comparison and is enabled in the separate full-cycle rendered checks.

The exact commands, phase measurements, completed switch records, diagnostics,
and renderer investigation are in
[region-switching-results.json](region-switching-results.json). OpenGL
validation uses Mesa llvmpipe software rendering and is recorded separately;
its frame rate and wall-clock loading times do not represent the user's GPU.

## Final rendered verification

With the final water-cache repair applied, Godot **4.7.2** completed the full
**town -> desert -> wetlands -> graveyard -> island -> town** OpenGL cycle
with population, shadows, and render LODs enabled. All five destinations had
rendered objects, the expected navigation mesh, a new active Game/camera, and
more than 1.14 m of supported player movement. The process exited successfully
with no engine-error or native-crash records.

The lifecycle runner also observed ten teardown-gap frames and rejected input
during six asynchronous startups. The earlier repaired **4.6.3** rendered
town/desert round trip passed with LODs and shadows enabled, and the final
4.6.3 headless run verified all ten transitions after the water-cache repair.

These rendered checks used X11 and Mesa llvmpipe at a 640 x 360 window on the
test host. They exercise the OpenGL renderer and actual scene replacement,
but do not substitute for the user's graphics driver or exhaustive traversal
of every location. Existing navigation edge-overlap warnings remain recorded
in the results; the supported local movement checks pass.

## Reproduce a real switch

After retrieving LFS assets and importing the project, run:

```bash
export GODOT="/absolute/path/to/Godot"
git lfs pull --include='assets/**'
"$GODOT" --headless --editor --path . --import --quit

PERF_LOG=1 "$GODOT" --path . \
  --script res://tools/region_switch_benchmark.gd -- \
  --region=town --nopop
```

The default route switches **town -> desert -> town**, injecting the actual
Tab and Shift+Tab input. For all five regions in reverse registry order:

```bash
PERF_LOG=1 "$GODOT" --path . \
  --script res://tools/region_switch_benchmark.gd -- \
  --region=town --nopop \
  --switch-steps=-1,-1,-1,-1,-1 --switch-timeout=300
```

Each destination must have a new `Game` instance, the correct mounted region,
an active camera, a populated navigation mesh, supported player position, and
at least one meter of actual movement. The harness also probes rapid input and
input during asynchronous startup. `SWITCH_PASS` is printed only after every
requested destination passes; a timeout or blank scene exits nonzero.

Movement gets eight seconds of simulated physics time, bounded by the same
per-stage wall timeout. This matters for software rendering: the game's
physics-step cap can allow only a few physics ticks per real second. The
harness still requires the full movement distance and continued ground
support, and records both movement ticks and wall time.

Add `--headless` before `--path` for CPU/lifecycle checks. A headless pass does
not exercise the OpenGL renderer. Omit `--nopop` for a population-enabled run.
Do not combine this harness with the old `--switchtest`, which is an automatic
trigger rather than an assertion of successful replacement.

## Compare loading work

`PERF_LOG=1` prints `LOAD_PHASE` lines for region loading, collision, navigation,
water preparation, and cache operations. `SWITCH_READY`/`SWITCH_OK` include
`ready_s`, measured from initial instantiation or switch input until the map is
playable, before the harness's extra settling frames.

Use the same route and engine for controlled comparisons:

- `--no-nav-cache` forces navigation rebaking instead of reading the saved mesh.
- `--no-stitch-cache` forces the navigation-link search instead of reusing its
  saved endpoints.

Warm the conditioned region once before comparing repeated loads. A first bake
after a source or algorithm change is expected to be slower. Keep that cost
separate from revisiting an unchanged region.

Phase totals overlap: `region.ready_total` and `region.physics_wait` can include
work performed by other startup coroutines while the region is suspended.
Do not add them to their component timings. Synchronous phases such as
`nav.bake`, `nav.stitch`, and `region.collision_total` isolate the corresponding
work.

## Regression commands

```bash
"$GODOT" --headless --path . --script res://tests/test_region_switch.gd
"$GODOT" --headless --path . --script res://tests/test_nav_marker_cache.gd
"$GODOT" --headless --path . --script res://tests/test_nav_stitch_cache.gd
"$GODOT" --headless --path . --script res://tests/test_region_render_lods.gd
"$GODOT" --headless --path . --script res://tests/test_region_water_cache.gd
```

The lifecycle fixture passed 50 checks on Godot 4.6.3 and 4.7.2, including four
completed replacements and input rejection during startup. The navigation
tests verify cache reuse and invalidation while comparing actual output
geometry/link endpoints.

The strengthened LOD regression failed against the old helper and passes
**97 checks** after the repair on both engine versions. It covers compatible
multi-surface source meshes with zero or one imported LOD, verifies every
generated surface/LOD's effective shadow representation, and repeats the
checks after serialization. It also checks unchanged geometry/materials,
enabled shadow casting, and retention of original resources for skipped or
unsimplified meshes.

The water-cache regression passes **97 checks on both versions** using actual
cold, cached, and recovery loading branches. It verifies the finalized water
state, byte-identical footprints and navigation signatures, generated water
geometry and collision roles, ownership, preserved world transforms under
transformed parents, dry maps, and recovery from missing or malformed metadata.
