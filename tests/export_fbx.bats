#!/usr/bin/env bats
# export_fbx.py and render_preview.py. Most tests need a real Blender (RDK_BLENDER_TESTS=1); they
# build small car scenes on the fly with Blender's user folders in a temp dir.

load helpers

setup_file() {
  real_blender_enabled || return 0
  build_car car
  build_car heavy --heavy Wheel_FL
}

setup() {
  setup_fake_machine
  RUN="$BLENDER_SCRIPTS/run_blender.sh"
  OUT="$FAKE/out"
}

# export BLEND ARGS...: run export_fbx.py on BLEND (stdout only in $output).
export_fbx() {
  local blend=$1
  shift
  use_real_blender
  run --separate-stderr bash "$RUN" --blend "$blend" export_fbx.py "$@"
}

is_fbx() { [ "$(head -c 18 "$1")" = "Kaydara FBX Binary" ] && [ "$(wc -c <"$1" | tr -d ' ')" -gt 1000 ]; }

@test "--help works without Blender" {
  run python3 "$BLENDER_SCRIPTS/export_fbx.py" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--per-object"* ]]
  [[ "$output" == *"--apply-modifiers"* ]]
  run python3 "$BLENDER_SCRIPTS/render_preview.py" --help
  [ "$status" -eq 0 ]
}

@test "real Blender: exports every mesh to one FBX with Roblox's settings" {
  require_real_blender
  export_fbx "$(car car)" --out "$OUT/car.fbx" --json
  [ "$status" -eq 0 ]
  is_fbx "$OUT/car.fbx"
  result=$(json_line)
  [ "$(jq -r '.exported[0].objects | join(",")' <<<"$result")" = "Body,Wheel_FL,Wheel_FR,Wheel_RL,Wheel_RR" ]
  [ "$(jq -c '.settings | {apply_scale_options, global_scale, axis_forward, axis_up, path_mode, embed_textures, add_leaf_bones, bake_anim, object_types}' <<<"$result")" = \
    '{"apply_scale_options":"FBX_SCALE_UNITS","global_scale":1.0,"axis_forward":"Z","axis_up":"Y","path_mode":"COPY","embed_textures":true,"add_leaf_bones":false,"bake_anim":false,"object_types":["MESH"]}' ]
  # The file itself: FBX unit scale 100 (Blender metres), Y up, coordinates in Blender units (= studs).
  fbx2json=$(ls "$(dirname "$REAL_BLENDER")"/../Resources/*/scripts/addons_core/io_scene_fbx/fbx2json.py 2>/dev/null | head -n 1)
  if [ -n "$fbx2json" ]; then
    python3 -I "$fbx2json" "$OUT/car.fbx" >/dev/null
    run python3 -I -c '
import json, sys
found = {}
def walk(n):
    if isinstance(n, list):
        if len(n) > 1 and n[0] == "P" and isinstance(n[1], list) and n[1] and n[1][0] in ("UnitScaleFactor", "UpAxis"):
            found[n[1][0]] = n[1][-1]
        for c in n:
            walk(c)
walk(json.load(open(sys.argv[1])))
print(found["UnitScaleFactor"], found["UpAxis"])' "$OUT/car.json"
    [ "$output" = "100.0 1" ]
  fi
}

@test "real Blender: violations stop the export unless --force" {
  require_real_blender
  export_fbx "$(car heavy)" --out "$OUT/heavy.fbx" --apply-modifiers
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to export: 1 violation(s)"* ]]
  [ ! -e "$OUT/heavy.fbx" ]
  export_fbx "$(car heavy)" --out "$OUT/heavy.fbx" --apply-modifiers --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"exporting despite 1 violation(s) (--force)"* ]]
  is_fbx "$OUT/heavy.fbx"
}

@test "real Blender: without --apply-modifiers the base mesh is checked and exported, with a warning" {
  require_real_blender
  export_fbx "$(car heavy)" --out "$OUT/base.fbx" --objects Wheel_FL
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: 1 modifier(s) not included (export with --apply-modifiers)"* ]]
  is_fbx "$OUT/base.fbx"
}

@test "real Blender: --per-object writes one FBX per wheel, named after the object" {
  require_real_blender
  export_fbx "$(car car)" --out "$OUT/wheels" --per-object --objects Wheel_FL,Wheel_FR,Wheel_RL,Wheel_RR --triangulate
  [ "$status" -eq 0 ]
  [ "$(cd "$OUT/wheels" && ls | tr '\n' ' ')" = "Wheel_FL.fbx Wheel_FR.fbx Wheel_RL.fbx Wheel_RR.fbx " ]
  for f in "$OUT"/wheels/*.fbx; do is_fbx "$f"; done
}

@test "real Blender: --dry-run checks and plans but writes nothing" {
  require_real_blender
  export_fbx "$(car car)" --out "$OUT/wheels" --per-object --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would export Wheel_RR -> $OUT/wheels/Wheel_RR.fbx"* ]]
  [ ! -e "$OUT" ]
}

@test "real Blender: --out must match the mode" {
  require_real_blender
  export_fbx "$(car car)" --out "$OUT/car"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--out must end in .fbx"* ]]
  export_fbx "$(car car)" --out "$OUT/car.fbx" --per-object
  [ "$status" -eq 2 ]
  [ ! -e "$OUT" ]
}

@test "real Blender: exporting twice from a live session leaves the scene as it was" {
  require_real_blender
  use_real_blender
  run --separate-stderr "$REAL_BLENDER" --background --quiet "$(car car)" --python-exit-code 1 --python-expr '
import json, sys
import bpy
scripts, out = sys.argv[sys.argv.index("--") + 1:]
sys.path.insert(0, scripts)
import export_fbx
body = bpy.data.objects["Body"]
body.select_set(True)
bpy.context.view_layer.objects.active = body
state = lambda: (sorted(o.name for o in bpy.context.selected_objects), bpy.context.view_layer.objects.active.name,
                 len(bpy.data.objects), len(bpy.data.meshes), len(bpy.data.materials))
before = state()
for _ in range(2):
    result = export_fbx.export(out, names=["Wheel_FL", "Wheel_FR"], per_object=True, apply_modifiers=True)
print(json.dumps({"unchanged": state() == before, "files": [e["path"].rsplit("/", 1)[1] for e in result["exported"]]}))
' -- "$BLENDER_SCRIPTS" "$OUT/live"
  [ "$status" -eq 0 ]
  [ "$(json_line)" = '{"unchanged": true, "files": ["Wheel_FL.fbx", "Wheel_FR.fbx"]}' ]
}

@test "real Blender: render_preview writes a PNG and leaves no camera behind" {
  require_real_blender
  use_real_blender
  run bash "$RUN" --blend "$(car car)" render_preview.py --out "$OUT/car.png" --size 128
  [ "$status" -eq 0 ]
  [[ "$output" == *"rendered $OUT/car.png (Body, Wheel_FL, Wheel_FR, Wheel_RL, Wheel_RR)"* ]]
  [ "$(head -c 4 "$OUT/car.png" | tail -c 3)" = PNG ]
  run --separate-stderr "$REAL_BLENDER" --background --quiet "$(car car)" --python-exit-code 1 --python-expr '
import sys
import bpy
sys.path.insert(0, sys.argv[sys.argv.index("--") + 1])
import render_preview
render_preview.render(sys.argv[-1], names=["Wheel_FL"], size=64)
print("{\"cameras\": %d, \"engine\": \"%s\"}" % (len(bpy.data.cameras), bpy.context.scene.render.engine))
' -- "$BLENDER_SCRIPTS" "$OUT/wheel.png"
  [ "$status" -eq 0 ]
  [ "$(json_line)" = '{"cameras": 0, "engine": "BLENDER_EEVEE"}' ]
  [ -s "$OUT/wheel.png" ]
}
