#!/usr/bin/env bash
# Builds car.blend in the workspace with a real Blender: a body and four wheels, where Wheel_FL has
# a level-4 Subdivision Surface modifier (24,576 triangles evaluated). Blender's user folders go to
# ./.blender-user, never the real ones; blender.env tells the agent to use the same folder.
set -euo pipefail
case_dir=$(cd "$(dirname "$0")" && pwd)
blender=$(command -v blender || true)
[ -n "$blender" ] || blender=/Applications/Blender.app/Contents/MacOS/Blender
[ -x "$blender" ] || {
  echo "check-mesh-report needs Blender (on PATH, or /Applications/Blender.app)" >&2
  exit 1
}
mkdir -p .blender-user
BLENDER_USER_RESOURCES="$PWD/.blender-user" "$blender" --background --quiet --python-exit-code 1 \
  --python "$case_dir/../../tests/fixtures/car_scene.py" -- "$PWD/car.blend" --heavy Wheel_FL >/dev/null
printf 'BLENDER_USER_RESOURCES="%s"\nRDK_BLENDER_BIN="%s"\n' "$PWD/.blender-user" "$blender" >blender.env
