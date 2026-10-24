#!/usr/bin/env bats
# setup-blender.sh with a fake Blender; one opt-in test drives the real Blender against temp dirs.

load helpers

setup() {
  setup_fake_machine
  SETUP_BLENDER="$SETUP_SCRIPTS/setup-blender.sh"
  fake_cmd pgrep 'exit 1' # "Blender is not running"
}

@test "--dry-run downloads nothing and changes nothing" {
  fake_blender
  fake_logging_cmd curl
  run bash "$SETUP_BLENDER" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"downloading https://projects.blender.org/lab/blender_mcp/releases/download/v1.0.3/mcp-1.0.3.zip"* ]]
  [[ "$output" == *"--background --python-exit-code 1 --python-expr"* ]]
  [[ "$output" == *"blender-mcp --help   (prepares uv's cache)"* ]]
  [ ! -e "$FAKE/calls.log" ]
  [ ! -e "$FAKE/blender.log" ]
  [ ! -e "$RDK_LOCAL_BIN" ]
}

@test "an installed add-on is enabled with Auto Start and blender is linked" {
  fake_blender
  install_fake_addon 1.0.3
  fake_logging_cmd curl
  run bash "$SETUP_BLENDER"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE/calls.log" ] # nothing downloaded
  grep -q -- '--background --python-exit-code 1 --python-expr' "$FAKE/blender.log"
  grep -q -- '-- none 0 0 bl_ext.user_default.mcp$' "$FAKE/blender.log"
  [ "$(readlink "$RDK_LOCAL_BIN/blender")" = "$RDK_BLENDER_APP/Contents/MacOS/Blender" ]
  [[ "$output" == *'export PATH="$HOME/.local/bin:$PATH"'* ]]
  [[ "$output" == *"'Allow Online Access' is off"* ]]
  [ ! -e "$HOME/.zshrc" ]
}

@test "--allow-online-access is passed to Blender" {
  fake_blender
  install_fake_addon 1.0.3
  run bash "$SETUP_BLENDER" --allow-online-access --no-symlink
  [ "$status" -eq 0 ]
  grep -q -- '-- none 0 1 bl_ext.user_default.mcp$' "$FAKE/blender.log"
  [[ "$output" != *"Allow Online Access' is off"* ]]
  [ ! -e "$RDK_LOCAL_BIN/blender" ]
}

@test "a zip with the wrong checksum is refused before Blender runs" {
  fake_blender
  echo "not the add-on" >"$FAKE/mcp-1.0.3.zip"
  run bash "$SETUP_BLENDER" --zip "$FAKE/mcp-1.0.3.zip"
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$FAKE/blender.log" ]
}

@test "refuses Blender older than 5.1 and a missing Blender" {
  run bash "$SETUP_BLENDER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Blender not found"* ]]
  fake_blender 4.5.3
  run bash "$SETUP_BLENDER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"too old"* ]]
}

@test "refuses to run while Blender is open unless --force" {
  fake_blender
  install_fake_addon 1.0.3
  fake_cmd pgrep '[ "$2" = Blender ]'
  run bash "$SETUP_BLENDER" --no-symlink
  [ "$status" -eq 1 ]
  [[ "$output" == *"Blender is running"* ]]
  run bash "$SETUP_BLENDER" --no-symlink --force
  [ "$status" -eq 0 ]
}

@test "warns when the community add-on is installed too" {
  fake_blender
  install_fake_addon 1.0.3
  addons="$FAKE/home/Library/Application Support/Blender/5.2/scripts/addons"
  mkdir -p "$addons"
  echo 'bpy.types.Scene.blendermcp_port = 1' >"$addons/addon.py"
  run bash "$SETUP_BLENDER" --no-symlink
  [ "$status" -eq 0 ]
  [[ "$output" == *"community blender-mcp add-on is also installed"* ]]
}

@test "a failing Blender run is reported" {
  fake_blender
  install_fake_addon 1.0.3
  cat >"$RDK_BLENDER_APP/Contents/MacOS/Blender" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --version ] && { echo "Blender 5.2.1"; exit 0; }
echo "Traceback: RuntimeError: add-on bl_ext.user_default.mcp is not enabled"
exit 1
EOF
  run bash "$SETUP_BLENDER" --no-symlink
  [ "$status" -eq 1 ]
  [[ "$output" == *"RuntimeError"* ]]
  [[ "$output" == *"could not install or enable the add-on"* ]]
}

# Opt-in: RDK_BLENDER_TESTS=1 with a real Blender >= 5.1, and the add-on zip either in
# RDK_TEST_ADDON_ZIP or downloadable (RDK_NETWORK_TESTS=1). Uses temp Blender user dirs only.
@test "real Blender: installs and enables the add-on in temp user dirs" {
  [ "${RDK_BLENDER_TESTS:-0}" = 1 ] || skip "set RDK_BLENDER_TESTS=1 to run against a real Blender"
  real=${RDK_REAL_BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
  [ -x "$real" ] || skip "no Blender at $real"
  zip=${RDK_TEST_ADDON_ZIP:-}
  if [ -z "$zip" ]; then
    [ "$NETWORK_TESTS" = 1 ] || skip "set RDK_TEST_ADDON_ZIP or RDK_NETWORK_TESTS=1"
    zip_args=()
  else
    zip_args=(--zip "$zip")
  fi
  export RDK_BLENDER_BIN="$real" BLENDER_USER_RESOURCES="$FAKE/blender-res"
  run bash "$SETUP_BLENDER" --allow-online-access ${zip_args[@]+"${zip_args[@]}"}
  [ "$status" -eq 0 ]
  [ -f "$FAKE/blender-res/extensions/user_default/mcp/blender_manifest.toml" ]
  run "$real" --background --python-expr 'import bpy
a = bpy.context.preferences.addons.get("bl_ext.user_default.mcp")
print("CHECK", a is not None and a.preferences.use_autostart, bpy.context.preferences.system.use_online_access)'
  [[ "$output" == *"CHECK True True"* ]]
}

@test "prepares the pinned server in uv's cache unless --no-warm" {
  fake_blender
  install_fake_addon 1.0.3
  fake_logging_cmd uvx
  run bash "$SETUP_BLENDER" --no-symlink
  [ "$status" -eq 0 ]
  grep -qx 'uvx \[--from\] \[git+https://projects.blender.org/lab/blender_mcp.git@v1.0.3#subdirectory=mcp\] \[blender-mcp\] \[--help\]' "$FAKE/calls.log"
  rm "$FAKE/calls.log"
  run bash "$SETUP_BLENDER" --no-symlink --no-warm
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE/calls.log" ]
}

@test "a failed warm-up is a warning, not a failure" {
  fake_blender
  install_fake_addon 1.0.3
  fake_cmd uvx 'echo "network unreachable" >&2; exit 2'
  run bash "$SETUP_BLENDER" --no-symlink
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not prepare the Blender MCP server"* ]]
}
