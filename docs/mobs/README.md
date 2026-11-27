# Mob screenshot and verification notes

These images were captured **in-engine**, not from Blender. The game was rendered
with Godot 4.6.3 Forward+ using Vulkan (Mesa llvmpipe) inside an Xvfb display, then
the root viewport was saved by the `--screenshot` debug mode in
[`scripts/game_controller.gd`](../../scripts/game_controller.gd).

## Reproduce a screenshot

From the project root:

```bash
# Xvfb + software Vulkan.  Xvfb must stay alive while Godot runs.
# This workspace's Xvfb was extracted under _runtime/debs/xvfb/usr/bin/Xvfb;
# use that path if Xvfb is not installed system-wide.
Xvfb :99 -screen 0 1600x900x24 -ac -nolisten tcp -extension GLX &
export DISPLAY=:99
export XDG_DATA_HOME=$PWD/_runtime/xdg_data
export XDG_CONFIG_HOME=$PWD/_runtime/xdg_config
export XDG_CACHE_HOME=$PWD/_runtime/xdg_cache
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json

/home/dormage/Downloads/Godot_v4.6.3-stable_linux.x86_64 \
  --path . --rendering-driver vulkan --audio-driver Dummy \
  -- --region=town --screenshot
```

The `--screenshot` mode waits for the population spawner, takes three framed
views, a densest-cluster close-up and a whole-population overview, writes PNGs
to `user://screenshots/`, then quits. Valid regions for this mode are `island`,
`town` and `desert`.

## Headless population checks

These do not need a display or GPU:

```bash
XDG_DATA_HOME=$PWD/_runtime/xdg_data \
XDG_CONFIG_HOME=$PWD/_runtime/xdg_config \
XDG_CACHE_HOME=$PWD/_runtime/xdg_cache \
/home/dormage/Downloads/Godot_v4.6.3-stable_linux.x86_64 \
  --headless --path . -- --region=town --population-check
```

The check prints `POPULATION`, per-actor `POP_ACTOR` clip maps, and `POP_CHECK`
with spawned / moved / six-role counts.
