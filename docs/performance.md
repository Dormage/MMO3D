# Performance fixes and reproducible measurements

The main confirmed movement bottleneck was the player's sole-fitting code. While
walking, it scanned the complete character mesh and repeated skin-bind inversions
and bone-pose lookups on every physics tick. This work happened **outside** the
existing `move_and_slide()` timer, so the earlier movement counter did not measure
it. Free camera and idle movement skipped the expensive branch.

The changes cache the invariant foot samples, correct the profiling units, restore
render LODs after runtime mesh rebuilding, make the Compatibility renderer's water
depth reconstruction correct, and fix several diagnostic switches. A separate
spatial index accelerates bridge-deck collision filtering during region loading.

## 1. Confirmed findings

### Walking repeatedly scanned the character mesh

[`player_controller.gd`](../scripts/player_controller.gd) calls
`_fit_model_sole_only()` while moving. Previously `_sole_lowest_world()` searched
the model subtree, retrieved mesh arrays, and checked every vertex's four skin
weights on each call. It also inverted a bind transform and fetched a bone pose
separately for each eligible foot sample.

[`sole_sample_cache.gd`](../scripts/sole_sample_cache.gd) now performs mesh scanning
and bind-space preparation once when the visual model is built. Queries obtain
one current transform per relevant bone and calculate only the cached samples'
world-space Y values. The original first-surface selection, influence threshold,
and sole-fitting calculation are retained. Named/reordered skin bindings and
eight-weight meshes are handled explicitly. Loading a replacement body model
must rebuild this cache; changing a weapon does not invalidate it.

Official Godot **4.6.3**, using the project's real `player_animated.glb`, produced
the following function-level measurements in the headless regression benchmark:

| Measurement | Original scan | Cached calculation |
| --- | ---: | ---: |
| Source vertices inspected during each sole query | 10,616 | 0 |
| Cached foot samples evaluated | Not cached | 2,082 |
| Relevant foot/toe bones | 4 | 4 |
| Mean CPU time per sole query | 6.992 ms | 0.108 ms |

The measured function speedup was **64.6×**. This is a CPU microbenchmark, not a
claim that the whole game or rendered FPS improves by that factor. The focused
suite passed **85 checks**, including actual Idle, Walk, and StartWalk poses and
synthetic poses with rotation, negative scale, and nonuniform scale.

### The old movement log had the wrong denominator

The previous `MOVECOST` summed microseconds for about two seconds, divided the
total by 2,000, and printed the result as milliseconds. That is approximately
**milliseconds of work per elapsed second**, not milliseconds per physics tick or
rendered frame. It also assumed each reporting interval lasted exactly two
seconds.

The new logger uses a monotonic wall clock, counts actual physics ticks, and
reports the full player callback, movement, water checks, surface glue, and sole
queries separately. Timers are enabled by `PERF_LOG=1`; ordinary play does not
perform those timing calls.

### Full-scene movement smoke test

The initial optimized island run loaded the normal game scene, normal RPG camera,
population, collision, and navigation. It used a 2-second warm-up, a 3-second idle
phase, and an 8-second walking phase. It passed with:

| Measurement | Observed result |
| --- | ---: |
| Idle horizontal drift | 0.000 m |
| Walking distance | 27.860 m |
| Achieved average walking speed, including turns/waits | 3.482 m/s |
| Achieved physics rate during walking | 60.113 Hz |
| Total player callback per physics tick | 0.597 ms |
| Sole calculation per call during walking | 0.115 ms |
| Completed route turnarounds | 3 |

This was headless and validates CPU work and real movement. It does not validate
GPU performance. Region readiness took 58.35 seconds in that run, which preceded
the bridge-deck spatial-index optimization described below. Do not use that load
time as the final optimized startup result.

## 2. Other changes and their scope

### Render LODs survive region geometry preparation

Several region preparation passes replace an imported mesh with a new
`ArrayMesh`. The replacement can lose the render LOD index buffers created by the
importer. Raw GLTF fallback loading also differs from using the editor's imported
resource.

[`region_render_lods.gd`](../scripts/region_render_lods.gd) generates alternative
render index buffers after geometry preparation and before the conditioned region
is cached. It preserves the full-resolution vertices and base indices used by
physics and navigation, materials, sharing, and relevant mesh metadata. Skinned
meshes and meshes with blend shapes are excluded. Cache dependencies include the
LOD helper, and runs with `--no-render-lods` use a separate cache variant.

**Imported island foliage may already have LODs.** This helper restores LODs for
rebuilt or raw-loaded geometry; its presence does not imply a large GPU gain on
every map or camera view. The logged `base_tris` and `lowest_tris` describe stored
LOD geometry, not how many triangles a particular frame actually selected. It
does not merge objects or establish a reduction in draw-call count.

### Compatibility renderer and water shaders

`project.godot` defaults to `gl_compatibility`, matching the previously reported
better behavior on the target integrated GPU. Forward+ remains selectable from
the command line.

The two water shaders previously reconstructed depth using the Forward+/Mobile
NDC convention on every renderer.
[`depth_compat.gdshaderinc`](../shaders/depth_compat.gdshaderinc) now selects the
appropriate conversion for Compatibility's `[-1, 1]` depth range. This keeps water
depth, foam, and screen-space reconstruction consistent when changing renderers.
Forward+-only environment effects are enabled only when that renderer is active.

Renderer choice should be compared on the actual target machine. Software
rendering, headless loop throughput, and a different machine's CPU timings are
not substitutes for that comparison.

### Bridge-deck filtering during startup

The island contains thousands of exclusion boxes used to remove prop collision
from bridge decks. Checking every triangle centroid against every box made this
preparation step expensive even when the visual region cache was present.

[`deck_box_index.gd`](../scripts/deck_box_index.gd) indexes the original boxes in
an XZ grid and evaluates the unchanged inclusive XYZ containment test against
local candidates. Large or unusual boxes use a bounded fallback list. This is a
startup optimization, separate from walking physics and rendering. Collision
faces should remain identical to the previous exhaustive test.

The real-island equivalence check and observed load times are recorded in
section 7. The index changes candidate selection, not the collision rule.

### Diagnostic switches now remain effective

`--nopop` skips population and monster spawners before their asynchronous spawn
work. Directly authored or later-added actors also honor the flag. `--minphys`
retains actor visuals while suppressing their physics. The nearby-actor throttle
does not accidentally reactivate those disabled callbacks.

`--noshadow`, `--norefl`, `--noocc`, and `--nofog` inspect the scene-tree root so
they reach the shared atmosphere, environment, and sun outside the `Game` scene.
The previous current-scene-only search missed those autoload nodes.

An empty legacy box-bridge surface is no longer submitted to the navigation mesh
builder. Authored concave bridge collision continues through its existing path.

## 3. Prepare and run

Use the official **Godot 4.6.3** executable for comparable results. Set `GODOT` to
its absolute path, then run these commands from the repository root:

```bash
export GODOT="/absolute/path/to/Godot_v4.6.3-stable_linux.x86_64"
"$GODOT" --version
git lfs install --local
git lfs pull --include='assets/**'
"$GODOT" --headless --editor --path . --import --quit
```

The LFS command fetches runtime assets; offline source libraries are not needed
to play. The editor pass imports assets and registers project script classes. Wait for
it to finish before launching a game or benchmark. A fresh import and the first
conditioned region bake can take longer than a warm run.

For interactive profiling:

```bash
PERF_LOG=1 "$GODOT" --path . -- --region=island
```

Godot options such as `--rendering-method` go **before** the `--` separator. Game
options such as `--region=island` go **after** it.

## 4. Controlled whole-game benchmark

[`perf_benchmark.gd`](../tools/perf_benchmark.gd) loads `game.tscn`, waits for both
navigation links and the ordinary RPG camera, warms up, measures idle, then moves
the real player back and forth along a supported nearby navigation route. The
radius/direction search order is fixed, and the selected route is logged.

Run these sequentially, using the same renderer, window size, power mode, and
other options:

```bash
"$GODOT" --path . --script res://tools/perf_benchmark.gd -- \
  --region=island --bench-label=cached

"$GODOT" --path . --script res://tools/perf_benchmark.gd -- \
  --region=island --bench-label=legacy --bench-legacy-sole
```

`--bench-legacy-sole` is diagnostic only. It injects
[`legacy_sole_sampler.gd`](../tools/legacy_sole_sampler.gd), reproducing the old
full-mesh sole scan while preserving the current scene, renderer, cache metadata,
movement code, and telemetry. Ordinary gameplay never loads it. The output marks
`legacy_sole` explicitly.

The default phases are 3 seconds of warm-up, 5 seconds idle, and 12 seconds
walking. Override them with `--bench-warmup`, `--bench-idle`, `--bench-walk`, and
`--bench-timeout`; values are seconds:

```bash
"$GODOT" --path . --script res://tools/perf_benchmark.gd -- \
  --region=island --bench-warmup=5 --bench-idle=10 --bench-walk=20 \
  --bench-timeout=300 --bench-label=long-cached
```

Use `--nopop` on **both** runs to isolate the player from random population
placement and actor activity. Keep population on for a separate representative
gameplay comparison. Do not operate the movement keys or camera while measuring.
Compare matching `BENCH_ROUTE` output and repeat the pair if unrelated activity
causes large frame-time spikes.

The benchmark emits JSON after `BENCH_START`, `BENCH_READY`, `BENCH_ROUTE`,
`BENCH_RESULT`, and `BENCH_PASS`. It exits nonzero for missing readiness, timeout,
no viable local route, insufficient movement, stopped navigation, idle drift, or
falling below the tested terrain.

For a CPU and movement smoke test, add `--headless` before `--path`:

```bash
"$GODOT" --headless --path . --script res://tools/perf_benchmark.gd -- \
  --region=island --bench-timeout=300 --bench-label=headless-cpu
```

Headless output names its throughput `headless_loop_hz`. **It is not rendered
FPS, does not exercise the GPU, and must not be reported as a graphics speedup.**

Do not combine this harness with `--naptest`, `--pathtest`, `--screenshot`, or the
navigation export modes. Those modes return early or quit normal startup; the
harness rejects them.

### Renderer and feature comparisons

```bash
"$GODOT" --rendering-method gl_compatibility --path . \
  --script res://tools/perf_benchmark.gd -- --region=island --bench-label=compat

"$GODOT" --rendering-method forward_plus --path . \
  --script res://tools/perf_benchmark.gd -- --region=island --bench-label=forward
```

Change one feature per comparison:

| Game option | Effect |
| --- | --- |
| `--no-render-lods` | Disables generated render LODs and viewport LOD selection; uses a separate conditioned region cache. |
| `--noshadow` | Disables light shadows, including the shared atmosphere's sun. |
| `--nofog` | Disables regular and volumetric fog. |
| `--norefl` or `--noocc` | Disables environment SSR, SSAO, SSIL, SDFGI, and glow. The two flags remain aliases. |
| `--nopop` | Omits population and monster generation/processing. |
| `--minphys` | Diagnostic player/ground physics reduction; actors remain visual. This changes gameplay collision and is not a shipping quality preset. |
| `--noveg`, `--nodecor`, `--unshaded` | Existing visual isolation switches; they change the scene being measured. |

After switching a cache variant, separate the first conditioning/load cost from
steady gameplay. `REGION_CACHE hit` confirms reuse; neither a cache hit nor an LOD
generation count establishes that rendered frame time improved.

## 5. Read the counters correctly

| Counter | Units and interpretation |
| --- | --- |
| `frame_ms_mean`, `p50`, `p95`, `p99`, `max` | Wall-clock rendered/process-frame intervals in milliseconds. Compare the tail as well as the mean. |
| `fps` | Observed frame count divided by elapsed wall seconds. Headless benchmarks rename this `headless_loop_hz`. |
| `engine_phys_last_ms` | Godot's latest physics-frame monitor; not the sum of player code alone. |
| `physics_hz` / `hz` | Actual physics ticks divided by elapsed wall seconds. Target is 60 unless configured otherwise. |
| `physics_per_frame` / `ticks_per_frame` | Physics steps executed per rendered/process frame. |
| `player_ms_tick` / `total_ms_tick` | Complete player `_physics_process` CPU time divided by counted player ticks. |
| `move_ms_tick`, `water_ms_tick`, `glue_ms_tick` | Their accumulated CPU time divided by the same player tick count. They are components of player time, not additional work to add to it. |
| `sole_ms_call` / `SOLECOST ms_call` | Sole-query CPU time divided by actual sole-query calls. Idle can have zero calls. |
| `distance_xz_m`, `achieved_mps` | Actual accumulated horizontal displacement and displacement per wall second, including route turns and waits. |
| `velocity_xz` | Player velocity magnitude at the reporting instant; it is not a measured speed over the interval. |
| `vertex_indices` / render primitive monitor | Godot's rendered vertex/index count across passes; do not automatically label it triangle count. |
| `render_objs` | Objects rendered in the frame, excluding culled objects; not total scene nodes. |
| `active_objs` | Godot's physics engine active-object monitor; not a count of AI scripts or enabled `CharacterBody3D` callbacks. |

With the existing physics cap of four steps per frame and a 60 Hz target, below
15 rendered FPS the engine cannot execute 60 physics steps per wall second. The
simulation can slow even when movement uses `delta`. The cap limits catch-up work;
it does not make an expensive physics tick cheaper. Check achieved physics rate
and real movement as well as FPS.

Authoritative Godot 4.6 references:

- [Performance monitor definitions](https://docs.godotengine.org/en/4.6/classes/class_performance.html)
- [Physics tick rate and maximum steps per frame](https://docs.godotengine.org/en/4.6/classes/class_engine.html)
- [Mesh LOD](https://docs.godotengine.org/en/4.6/tutorials/3d/mesh_lod.html)
- [Renderer-dependent depth reconstruction](https://docs.godotengine.org/en/4.6/tutorials/shaders/advanced_postprocessing.html)

## 6. Regression checks

After the initial import, run the focused tests with the same 4.6.3 executable:

```bash
"$GODOT" --headless --path . --script res://tests/test_player_sole_cache.gd -- --real-player
"$GODOT" --headless --path . --script res://tests/test_perf_metrics.gd
"$GODOT" --headless --path . --script res://tests/test_region_render_lods.gd
"$GODOT" --headless --path . --script res://tests/test_deck_box_index.gd
"$GODOT" --headless --path . --script res://tests/test_population_diagnostics.gd
"$GODOT" --headless --path . --script res://tests/test_population_diagnostics.gd -- --nopop
"$GODOT" --headless --path . --script res://tests/test_population_diagnostics.gd -- --minphys
```

The sole-cache test without `--real-player` uses synthetic geometry and does not
need the player GLB. The actual-model test verifies animation pose equivalence
and prints `SOLE_BENCH` timings; it exits nonzero if LFS assets are still pointers.

## 7. Completed validation — 2026-11-27

Tests used official Godot **4.6.3** on a Linux x86-64 host exposing an AMD EPYC
7763 CPU. The exact engine binary's SHA-256 is
`d0bc2113065e481c9c2c2b2c37daa4e8be3fe9e27f0ab9ab0b6096e9a37907f3`.
The repository base was `fabd7b4`. Measurements below are from this test host,
not the user's integrated GPU. Machine-readable benchmark output is preserved
in [`performance_results.json`](performance_results.json).

### Controlled whole-game comparison

Both runs loaded the ordinary island game, RPG camera, navigation, and collision
with `--nopop`. They used the same 8 m route, 2 seconds warm-up, 3 seconds idle,
and 8 seconds walking. Only `--bench-legacy-sole` differed. Both passed, completed
three turnarounds, and had zero idle drift.

| Walking measurement | Original sole scan | Cached sole calculation |
| --- | ---: | ---: |
| Complete player callback, ms per physics tick | 6.674 | 0.653 |
| Sole calculation, ms per call | 6.771 | 0.122 |
| `move_and_slide`, ms per physics tick | 0.457 | 0.457 |
| Actual physics rate, Hz | 60.036 | 59.993 |
| Actual horizontal distance, m | 27.732 | 27.796 |
| Average walking speed including turns, m/s | 3.461 | 3.474 |
| Headless process-frame p95, ms | 14.712 | 8.129 |
| Headless process-frame p99, ms | 18.158 | 9.186 |

This isolates approximately **90% less player-callback CPU time** and a **56×
faster sole query** in the full scene. The unchanged collision timing and similar
distance support that the saving comes from the sole scan, rather than skipped
movement. The last two rows describe a headless process loop; they are not a
rendered-FPS result. One paired run establishes the large local CPU saving, not
a distribution of performance across machines.

### Bridge-deck filtering and loading

The real-island index check compared 7,707 queries against all 4,200 original
deck boxes, including triangle centroids and boundaries. Every answer matched
the exhaustive implementation. On that run, exhaustive lookup took 4,372.96 ms;
indexed lookup took 55.97 ms after an 8.38 ms build, about **78× faster** for the
query set. The focused regression also checks negative coordinates, inclusive
grid edges, stacked heights, degenerate and very large boxes, reset/rebuild,
non-finite inputs, and exact filtered-face order.

Observed populated-island readiness changed from **58.35 s** before indexing to
**9.69 s** with indexing in a subsequent warm run. These are separate end-to-end
runs, not a repeated cold/warm load experiment; the controlled evidence for the
index itself is the identical-result query comparison above. A first conditioned
bake additionally generates and saves LODs, so compare warm runs separately.

### Five-map movement coverage

Each map used the normal scene and camera, a 1-second warm-up, 2 seconds idle,
and 5 seconds walking. Island kept population enabled; the other four used
`--nopop` to isolate player/terrain behavior. Every run passed with zero idle
drift, no detected falls or stuck movement, and no engine/script errors.

| Map | Distance in walking phase, m | Physics rate, Hz | Player CPU, ms/tick | Result |
| --- | ---: | ---: | ---: | --- |
| Island | 17.049 | 59.966 | 0.554 | Pass |
| Town | 17.066 | 59.984 | 1.464 | Pass |
| Desert | 17.209 | 60.114 | 0.215 | Pass |
| Graveyard | 17.126 | 60.126 | 0.581 | Pass |
| Wetlands | 16.958 | 59.985 | 0.395 | Pass |

These are local supported routes near each spawn. They do not certify every
bridge or triangle's winding. Existing navigation edge-overlap warnings remain
on island and wetlands; the tested paths completed despite them.

### Render and integration checks

The ordinary island scene was rendered with `gl_compatibility` / `opengl3`
using Mesa 25.0.7 **llvmpipe**, OpenGL 4.5, with population omitted. The captured
frame showed the player, terrain, vegetation, shadows, and shoreline water.
Both water shaders also passed a dedicated render smoke check with no shader
or script errors. This validates shader compilation and a visible scene on a
software renderer; it does not measure the target GPU's performance or certify
Forward+ visuals.

LOD regression checks preserve full-resolution arrays, materials, mesh sharing,
and collision/navigation faces across generation and cache reload. The actual
conditioned island stored 470 LOD levels across 195 surfaces, with 1,432,386 base
triangles and 19,697 triangles summed at the lowest stored levels. Those counts
are available geometry, not the LODs selected by the rendered camera. No claim
of a measured target-hardware LOD or draw-call speedup is made.

The final integrated test pass completed the initial editor import and all seven
commands in section 6 without errors. The sole test passed all 85 equivalence
checks. Its repeated real-player microbenchmark measured 6.135 ms versus
0.106 ms per query (58×), consistent with the earlier 64.6× sample and the
full-scene comparison. Profiler units, stalled-physics accounting, frame
percentiles, and all three population diagnostic modes also passed.

The existing single-sided concave collision settings and authored triangle
winding are not globally rewritten by the sole-cache change. A historical
improvement after toggling backface collision remains a separate observation;
the new measurements do not justify claiming that every terrain triangle was
previously tested twice or that all remaining cost comes from rendering.
