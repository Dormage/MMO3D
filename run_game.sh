#!/usr/bin/env bash
# Launch the game (Compatibility renderer, as set in project.godot).
# Extra args go to the game after --, e.g.  ./run_game.sh --region=ruins2
GODOT="${GODOT:-$HOME/Downloads/Godot_v4.7.2-stable_linux.x86_64}"
exec "$GODOT" --path "$(dirname "$0")" --rendering-method gl_compatibility -- "$@"
