#!/usr/bin/env bats
# run_blender.sh with a fake Blender that records its arguments.

load helpers

setup() {
  setup_fake_machine
  RUN_BLENDER="$BLENDER_SCRIPTS/run_blender.sh"
  # The fake prints nothing; it writes one argument per line and exits with $FAKE_EXIT.
  export RDK_BLENDER_BIN="$FAKE/bin/blender"
  fake_cmd blender "printf '%s\n' \"\$@\" >\"$FAKE/argv\"; exit \${FAKE_EXIT:-0}"
  printf 'print("hi")\n' >"$FAKE/script.py"
  touch "$FAKE/scene.blend"
}

argv() { tr '\n' ' ' <"$FAKE/argv" | sed 's/ $//'; }

@test "runs the script headless with the file loaded first and the script's arguments after --" {
  run bash "$RUN_BLENDER" --blend "$FAKE/scene.blend" "$FAKE/script.py" --objects "Body,Wheel FL" --json
  [ "$status" -eq 0 ]
  [ "$(argv)" = "--background --quiet $FAKE/scene.blend --python-exit-code 1 --python $FAKE/script.py -- --objects Body,Wheel FL --json" ]
  [ "$(sed -n 10p "$FAKE/argv")" = "Body,Wheel FL" ] # one argument, spaces kept
}

@test "never uses --factory-startup unless asked" {
  run bash "$RUN_BLENDER" "$FAKE/script.py"
  [ "$status" -eq 0 ]
  run ! grep -qx -- --factory-startup "$FAKE/argv"
  [ "$(argv)" = "--background --quiet --python-exit-code 1 --python $FAKE/script.py --" ]
  run bash "$RUN_BLENDER" --factory-startup "$FAKE/script.py"
  grep -qx -- --factory-startup "$FAKE/argv"
}

@test "passes the script's exit code through" {
  FAKE_EXIT=7 run bash "$RUN_BLENDER" "$FAKE/script.py"
  [ "$status" -eq 7 ]
  FAKE_EXIT=1 run bash "$RUN_BLENDER" "$FAKE/script.py"
  [ "$status" -eq 1 ]
}

@test "--dry-run prints the command and runs nothing" {
  run bash "$RUN_BLENDER" --dry-run --blend "$FAKE/scene.blend" "$FAKE/script.py" -- --x
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ $FAKE/bin/blender --background --quiet $FAKE/scene.blend --python-exit-code 1 --python $FAKE/script.py -- --x"* ]]
  [ ! -e "$FAKE/argv" ]
}

@test "options after the script name belong to the script; one -- after it is dropped" {
  run bash "$RUN_BLENDER" "$FAKE/script.py" --blend other.blend --dry-run
  [ "$status" -eq 0 ]
  [ "$(argv)" = "--background --quiet --python-exit-code 1 --python $FAKE/script.py -- --blend other.blend --dry-run" ]
  run bash "$RUN_BLENDER" -- "$FAKE/script.py" -- --json -- x
  [ "$status" -eq 0 ]
  [ "$(argv)" = "--background --quiet --python-exit-code 1 --python $FAKE/script.py -- --json -- x" ]
}

@test "a bare script name means the script next to run_blender.sh" {
  run bash "$RUN_BLENDER" check_mesh.py --json
  [ "$status" -eq 0 ]
  grep -qx -- "$BLENDER_SCRIPTS/check_mesh.py" "$FAKE/argv"
}

@test "--verbose keeps Blender's status lines" {
  run bash "$RUN_BLENDER" --verbose "$FAKE/script.py"
  [ "$status" -eq 0 ]
  run ! grep -qx -- --quiet "$FAKE/argv"
}

@test "usage errors exit 2 before Blender runs" {
  run bash "$RUN_BLENDER"
  [ "$status" -eq 2 ]
  run bash "$RUN_BLENDER" "$FAKE/missing.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"script not found"* ]]
  run bash "$RUN_BLENDER" --blend "$FAKE/missing.blend" "$FAKE/script.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"blend file not found"* ]]
  run bash "$RUN_BLENDER" --bogus "$FAKE/script.py"
  [ "$status" -eq 2 ]
  [ ! -e "$FAKE/argv" ]
}

@test "a missing Blender is an error with a hint" {
  export RDK_BLENDER_BIN="$FAKE/nowhere/blender"
  run bash "$RUN_BLENDER" "$FAKE/script.py"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Blender not found"* ]]
}

@test "finds Blender in /Applications when it is not on PATH" {
  unset RDK_BLENDER_BIN
  rm "$FAKE/bin/blender"
  mkdir -p "$RDK_BLENDER_APP/Contents/MacOS"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"%s"\n' "$FAKE/argv" >"$RDK_BLENDER_APP/Contents/MacOS/Blender"
  chmod +x "$RDK_BLENDER_APP/Contents/MacOS/Blender"
  run bash "$RUN_BLENDER" "$FAKE/script.py"
  [ "$status" -eq 0 ]
  grep -qx -- --background "$FAKE/argv"
}
