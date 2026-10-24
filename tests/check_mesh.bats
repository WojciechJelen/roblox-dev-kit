#!/usr/bin/env bats
# check_mesh.py. Most tests need a real Blender (RDK_BLENDER_TESTS=1); they build small car scenes
# on the fly (tests/fixtures/car_scene.py) with Blender's user folders in a temp dir.

load helpers

setup_file() {
  real_blender_enabled || return 0
  build_car car
  build_car heavy --heavy Wheel_FL
  build_car textured --texture 2048
  build_car rotated --rotated Body
}

setup() {
  setup_fake_machine
  RUN="$BLENDER_SCRIPTS/run_blender.sh"
}

# check BLEND ARGS...: run check_mesh.py on BLEND (stdout only in $output).
check() {
  local blend=$1
  shift
  use_real_blender
  run --separate-stderr bash "$RUN" --blend "$blend" check_mesh.py "$@"
}

@test "--help works without Blender; a real check needs Blender" {
  run python3 "$BLENDER_SCRIPTS/check_mesh.py" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--max-tris N"* ]]
  [[ "$output" == *"--require-names REGEX"* ]]
  run python3 "$BLENDER_SCRIPTS/check_mesh.py" --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"run it inside Blender"* ]]
}

@test "real Blender: a clean car has per-mesh triangle counts and sizes in studs, and no violations" {
  require_real_blender
  check "$(car car)" --json
  [ "$status" -eq 0 ]
  report=$(json_line)
  [ "$(jq -r .ok <<<"$report")" = true ]
  [ "$(jq -r .scope <<<"$report")" = all ]
  [ "$(jq -r '.limits.max_tris' <<<"$report")" = 20000 ]
  [ "$(jq -r '.objects[] | select(.name == "Body") | .triangles' <<<"$report")" = 12 ]
  [ "$(jq '.objects[] | select(.name == "Body") | .dimensions_studs == [4, 8, 2]' <<<"$report")" = true ]
  [ "$(jq -r '[.objects[] | select(.name | startswith("Wheel_")) | .triangles] | unique | .[]' <<<"$report")" = 124 ]
  [ "$(jq '.objects[] | select(.name == "Wheel_FL") | .origin_offset_studs == 0' <<<"$report")" = true ]
  [ "$(jq -r .summary.triangles <<<"$report")" = 508 ]
  # The wheels' 32-sided caps are n-gons: a warning, not a violation.
  [ "$(jq -r '[.warnings[] | select(.code == "ngons")] | length' <<<"$report")" = 4 ]
}

@test "real Blender: a mesh over 20,000 triangles is a violation; --no-modifiers counts the base mesh" {
  require_real_blender
  check "$(car heavy)" --json
  [ "$status" -eq 1 ]
  report=$(json_line)
  [ "$(jq -r '.objects[] | select(.name == "Wheel_FL") | .triangles' <<<"$report")" = 24576 ]
  [ "$(jq -r '.violations[] | "\(.object) \(.code) \(.message)"' <<<"$report")" = "Wheel_FL tris 24576 triangles, over the 20000 limit" ]
  check "$(car heavy)" --json --no-modifiers
  [ "$status" -eq 0 ]
  [ "$(jq -r '.objects[] | select(.name == "Wheel_FL") | .triangles' <<<"$(json_line)")" = 124 ]
  [ "$(jq -r '.warnings[] | select(.code == "modifiers") | .object' <<<"$(json_line)")" = Wheel_FL ]
}

@test "real Blender: --max-tris and --max-texture set the limits" {
  require_real_blender
  check "$(car car)" --json --max-tris 100
  [ "$status" -eq 1 ]
  [ "$(jq -r '[.violations[] | .object] | join(",")' <<<"$(json_line)")" = "Wheel_FL,Wheel_FR,Wheel_RL,Wheel_RR" ]
  check "$(car textured)" --json --objects Body
  [ "$status" -eq 1 ]
  [ "$(jq -r '.objects[0].textures[0] | "\(.image) \(.width)x\(.height)"' <<<"$(json_line)")" = "BodyColor 2048x2048" ]
  [ "$(jq -r '.violations[0].code' <<<"$(json_line)")" = texture ]
  check "$(car textured)" --json --objects Body --max-texture 4096
  [ "$status" -eq 0 ]
}

@test "real Blender: --require-names with --require-count checks the wheel set" {
  require_real_blender
  check "$(car car)" --json --require-names '^Wheel_(FL|FR|RL|RR)$' --require-count 4
  [ "$status" -eq 0 ]
  check "$(car car)" --json --objects Body,Wheel_FL --require-names '^Wheel_(FL|FR|RL|RR)$' --require-count 4
  [ "$status" -eq 1 ]
  [[ "$(jq -r '.violations[0].message' <<<"$(json_line)")" == "1 object(s) match '^Wheel_(FL|FR|RL|RR)\$' (Wheel_FL), expected at least 4" ]]
}

@test "real Blender: an unapplied rotation is a warning" {
  require_real_blender
  check "$(car rotated)" --json --objects Body
  [ "$status" -eq 0 ]
  [ "$(jq -r '.objects[0].unapplied_transforms | join(",")' <<<"$(json_line)")" = rotation ]
  [ "$(jq -r '.warnings[0].code' <<<"$(json_line)")" = transforms ]
}

@test "real Blender: the table for people names each object and its problems" {
  require_real_blender
  check "$(car heavy)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"limits: 20000 triangles per mesh, 1024 px textures"* ]]
  [[ "$output" == *"violation: 24576 triangles, over the 20000 limit"* ]]
  [[ "$output" == *"warning: 2 n-gon(s)"* ]]
  [[ "$output" == *"1 violation(s), 3 warning(s)"* ]]
}

@test "real Blender: unknown objects, an empty selection and bad limits are usage errors" {
  require_real_blender
  check "$(car car)" --objects Body,Nope
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no object named 'Nope'"* ]]
  check "$(car car)" --selected
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no mesh objects are selected"* ]]
  check "$(car car)" --max-tris 0
  [ "$status" -eq 2 ]
}

@test "real Blender: --report writes the JSON report to a file" {
  require_real_blender
  check "$(car car)" --report "$FAKE/report.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .summary.objects "$FAKE/report.json")" = 5 ]
  [ "$(jq -r .blend_file "$FAKE/report.json")" = "$(car car)" ]
}

@test "real Blender: importable from code running in Blender, without changing the scene" {
  require_real_blender
  use_real_blender
  run --separate-stderr "$REAL_BLENDER" --background --quiet "$(car heavy)" --python-exit-code 1 --python-expr '
import json, sys
import bpy
sys.path.insert(0, sys.argv[sys.argv.index("--") + 1])
import check_mesh
before = (len(bpy.data.objects), len(bpy.data.meshes), bpy.data.is_dirty)
result = check_mesh.check(names=["Wheel_FL", "Body"])
print(json.dumps({"ok": result["ok"], "tris": [o["triangles"] for o in result["objects"]],
                  "unchanged": before == (len(bpy.data.objects), len(bpy.data.meshes), bpy.data.is_dirty)}))
' -- "$BLENDER_SCRIPTS"
  [ "$status" -eq 0 ]
  [ "$(json_line)" = '{"ok": false, "tris": [24576, 12], "unchanged": true}' ]
}
