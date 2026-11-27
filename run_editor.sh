#!/usr/bin/env bash
# Open the project in the Godot editor.
#
# The editor must NOT use the Compatibility (GLES3) renderer on this machine:
# its scene shader fails to compile and the driver segfaults.  The game itself
# runs fine on Compatibility, so that stays the project default and this
# launcher only overrides the renderer for the editor session.
GODOT="${GODOT:-$HOME/Downloads/Godot_v4.7.2-stable_linux.x86_64}"
exec "$GODOT" --path "$(dirname "$0")" --editor --rendering-method forward_plus "$@"
