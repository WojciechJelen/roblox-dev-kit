# Shared setup for the bats suites. Every test runs on a fake machine under $BATS_TEST_TMPDIR:
# a fake HOME, a PATH without the real harnesses or tools, and fake Studio/Blender installs.
# Nothing here reads or writes the real user environment.
# shellcheck shell=bash
# Variables set here are read by the .bats files, and $output comes from bats' `run`;
# fake scripts are written with single-quoted bodies on purpose.
# shellcheck disable=SC2034,SC2154,SC2016

bats_require_minimum_version 1.5.0

KIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
SETUP_SCRIPTS="$KIT_ROOT/skills/roblox-setup/scripts"
DOCTOR="$KIT_ROOT/skills/roblox-doctor/scripts/doctor.sh"
BLENDER_SCRIPTS="$KIT_ROOT/skills/blender-to-roblox/scripts"
FIND_SCRIPTS="$KIT_ROOT/skills/find-resources/scripts"

# Opt-in gates, read before setup_fake_machine clears RDK_NETWORK_TESTS (which the doctor also reads).
NETWORK_TESTS=${RDK_NETWORK_TESTS:-0}

# Resolve the real tools the scripts need before PATH is narrowed.
REAL_JQ=$(command -v jq)
REAL_GIT=$(command -v git || true)
REAL_PYTHON=$(command -v python3 || true)
REAL_HOME=$HOME
REAL_LUNE_ON_PATH=$(command -v lune || true)

setup_fake_machine() {
  FAKE="$BATS_TEST_TMPDIR/machine"
  mkdir -p "$FAKE/home" "$FAKE/bin" "$FAKE/Applications"
  export HOME="$FAKE/home" RDK_HOME="$FAKE/home"
  unset CLAUDE_CONFIG_DIR CODEX_HOME BLENDER_PATH
  unset BLENDER_USER_RESOURCES BLENDER_USER_CONFIG BLENDER_USER_SCRIPTS BLENDER_USER_EXTENSIONS
  # GitHub's Linux runners export XDG_CONFIG_HOME; the fake home must win.
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
  unset ROBLOX_API_KEY ROBLOX_CREATOR_TYPE ROBLOX_CREATOR_ID
  unset RDK_NO_JQ RDK_NETWORK_TESTS RDK_BLENDER_BIN RDK_STUDIO_MCP_BIN RDK_STUDIO_PLUGINS_DIR RDK_ROKIT_BIN_DIR ROKIT_ROOT
  export NO_COLOR=1 RDK_OS=macos
  export RDK_STUDIO_APP="$FAKE/Applications/RobloxStudio.app"
  export RDK_BLENDER_APP="$FAKE/Applications/Blender.app"
  export RDK_LOCAL_BIN="$FAKE/home/.local/bin"
  # Only a fake uvx (fake_cmd uvx ...) may run; never the real one in /opt/homebrew/bin.
  export RDK_UVX="$FAKE/bin/uvx"
  # Port 1 is never served on a developer machine, so the port checks are deterministic
  # even while the developer runs Blender or `rojo serve`.
  export RDK_BLENDER_MCP_PORT=1 RDK_ROJO_PORT=1

  ln -s "$REAL_JQ" "$FAKE/bin/jq"
  [ -z "$REAL_GIT" ] || ln -s "$REAL_GIT" "$FAKE/bin/git"
  [ -z "$REAL_PYTHON" ] || ln -s "$REAL_PYTHON" "$FAKE/bin/python3"
  export PATH="$FAKE/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  cd "$FAKE/home" || return 1
}

# fake_cmd NAME BODY: an executable NAME on PATH running BODY (bash).
fake_cmd() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$FAKE/bin/$1"
  chmod +x "$FAKE/bin/$1"
}

# fake_logging_cmd NAME: NAME records its argv (one line per call) in $FAKE/calls.log and succeeds.
fake_logging_cmd() {
  fake_cmd "$1" "{ printf '%s' \"\$(basename \"\$0\")\"; printf ' [%s]' \"\$@\"; echo; } >>\"$FAKE/calls.log\""
}

fake_studio() {
  mkdir -p "$RDK_STUDIO_APP/Contents/MacOS"
  printf '#!/bin/sh\necho studio-mcp "$@"\n' >"$RDK_STUDIO_APP/Contents/MacOS/StudioMCP"
  chmod +x "$RDK_STUDIO_APP/Contents/MacOS/StudioMCP"
}

# fake_blender [VERSION]: a Blender that reports VERSION and emulates the add-on install that
# setup-blender.sh asks for (args after "--": zip install allow_online module).
fake_blender() {
  local version=${1:-5.2.1}
  mkdir -p "$RDK_BLENDER_APP/Contents/MacOS"
  cat >"$RDK_BLENDER_APP/Contents/MacOS/Blender" <<EOF
#!/usr/bin/env bash
if [ "\$1" = --version ]; then echo "Blender $version LTS"; echo "	build date: 2026-08-25"; exit 0; fi
printf '%s\n' "\$*" >>"$FAKE/blender.log"
while [ \$# -gt 0 ] && [ "\$1" != -- ]; do shift; done
shift
install=\$2 allow=\$3
if [ "\$install" = 1 ]; then
  dir="$FAKE/home/Library/Application Support/Blender/${version%.*}/extensions/user_default/mcp"
  mkdir -p "\$dir" && printf 'id = "mcp"\nversion = "1.0.3"\n' >"\$dir/blender_manifest.toml"
fi
echo "RDK-RESULT enabled=1 autostart=1 online_access=\$allow"
EOF
  chmod +x "$RDK_BLENDER_APP/Contents/MacOS/Blender"
}

blender_addon_dir() {
  printf '%s\n' "$FAKE/home/Library/Application Support/Blender/${1:-5.2}/extensions/user_default/mcp"
}

install_fake_addon() { # install_fake_addon [VERSION] [SERIES]
  local dir
  dir=$(blender_addon_dir "${2:-5.2}")
  mkdir -p "$dir"
  printf 'id = "mcp"\nversion = "%s"\n' "${1:-1.0.3}" >"$dir/blender_manifest.toml"
}

# fake_tool NAME VERSION_OUTPUT: a toolchain binary in ~/.rokit/bin answering --version.
fake_tool() {
  mkdir -p "$FAKE/home/.rokit/bin"
  printf '#!/bin/sh\n[ "$1" = --version ] && echo "%s"\nexit 0\n' "$2" >"$FAKE/home/.rokit/bin/$1"
  chmod +x "$FAKE/home/.rokit/bin/$1"
}

# fake_full_toolchain: rokit plus every tool at the versions the template pins, on PATH.
fake_full_toolchain() {
  fake_tool rokit "rokit 1.2.0"
  fake_tool rojo "Rojo 7.7.1"
  fake_tool wally "wally 0.3.2"
  fake_tool lune "lune 0.11.1"
  fake_tool stylua "stylua 2.6.0"
  fake_tool selene "selene 0.32.0"
  fake_tool luau-lsp "1.70.1"
  fake_tool zap "cli 0.6.29"
  fake_tool asphalt "asphalt 2.0.2"
  export PATH="$FAKE/home/.rokit/bin:$PATH"
}

# scaffold_project DIR: a template project (no git init) for doctor tests.
scaffold_project() {
  bash "$SETUP_SCRIPTS/scaffold.sh" "$1" "Test Game" --no-git >/dev/null 2>&1
}

# status_of ID: the status of check ID in the doctor JSON held in $output.
status_of() {
  printf '%s' "$output" | jq -r --arg id "$1" '.checks[] | select(.id == $id) | .status'
}

detail_of() {
  printf '%s' "$output" | jq -r --arg id "$1" '.checks[] | select(.id == $id) | .detail'
}

# --- opt-in suites that drive a real Blender (RDK_BLENDER_TESTS=1) ----------------------------
# Blender's user folders point into the test's temp dir, so the real preferences are never touched.

REAL_BLENDER=${RDK_REAL_BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}

real_blender_enabled() { [ "${RDK_BLENDER_TESTS:-0}" = 1 ] && [ -x "$REAL_BLENDER" ]; }

require_real_blender() {
  [ "${RDK_BLENDER_TESTS:-0}" = 1 ] || skip "set RDK_BLENDER_TESTS=1 to run against a real Blender"
  [ -x "$REAL_BLENDER" ] || skip "no Blender at $REAL_BLENDER"
}

# use_real_blender: after setup_fake_machine, let the scripts run the real Blender.
use_real_blender() {
  export RDK_BLENDER_BIN=$REAL_BLENDER BLENDER_USER_RESOURCES="$BATS_FILE_TMPDIR/blender-user"
}

# build_car NAME [car_scene.py options]: build $BATS_FILE_TMPDIR/NAME/NAME.blend (see tests/fixtures).
build_car() {
  local name=$1
  shift
  mkdir -p "$BATS_FILE_TMPDIR/$name"
  BLENDER_USER_RESOURCES="$BATS_FILE_TMPDIR/blender-user" "$REAL_BLENDER" --background --quiet --python-exit-code 1 \
    --python "$KIT_ROOT/tests/fixtures/car_scene.py" -- "$BATS_FILE_TMPDIR/$name/$name.blend" "$@" >/dev/null
}

car() { printf '%s\n' "$BATS_FILE_TMPDIR/$1/$1.blend"; }

# fbx_contents FILE: import FILE into an empty scene in a fresh headless Blender and print its mesh
# objects as one JSON line, {"Name": number of faces, ...}. This is what the export tests assert on.
fbx_contents() {
  BLENDER_USER_RESOURCES="$BATS_FILE_TMPDIR/blender-user" "$REAL_BLENDER" --background --quiet --python-exit-code 1 \
    --python-expr '
import json, sys
import bpy
bpy.ops.wm.read_homefile(use_empty=True, use_factory_startup=True)
bpy.ops.import_scene.fbx(filepath=sys.argv[-1])
print(json.dumps({o.name: len(o.data.polygons) for o in bpy.data.objects if o.type == "MESH"}, sort_keys=True))
' -- "$1" 2>/dev/null | grep '^{' | tail -n 1
}

# json_line: the one-line JSON report in $output (Blender prints its own lines around it).
json_line() { printf '%s\n' "$output" | grep '^{' | tail -n 1; }

# listen_on_free_port: start a TCP listener; sets LISTEN_PORT and LISTEN_PID.
listen_on_free_port() {
  local portfile="$BATS_TEST_TMPDIR/port"
  "$REAL_PYTHON" -I -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(30)' "$portfile" &
  LISTEN_PID=$!
  local i=0
  while [ ! -s "$portfile" ] && [ $i -lt 100 ]; do
    i=$((i + 1))
    "$REAL_PYTHON" -I -c 'import time; time.sleep(0.05)'
  done
  LISTEN_PORT=$(cat "$portfile")
}

# --- Lune (the model scanner tests) -------------------------------------------------------------
# Skipped unless Lune is installed (`command -v lune` or ~/.rokit/bin/lune). Rokit's shim only runs
# where a rokit.toml lists lune, which the fake HOME has not, so the tests use the binary in Rokit's
# tool storage when it is there. RDK_REAL_LUNE picks a binary.

require_lune() {
  local c
  REAL_LUNE=${RDK_REAL_LUNE:-}
  if [ -z "$REAL_LUNE" ]; then
    [ -n "$REAL_LUNE_ON_PATH" ] || [ -x "$REAL_HOME/.rokit/bin/lune" ] || skip "lune is not installed (command -v lune, ~/.rokit/bin/lune)"
    for c in "$REAL_HOME"/.rokit/tool-storage/lune-org/lune/*/lune "$REAL_LUNE_ON_PATH" "$REAL_HOME/.rokit/bin/lune"; do
      if [ -n "$c" ] && [ -x "$c" ] && "$c" --version >/dev/null 2>&1; then
        REAL_LUNE=$c
        break
      fi
    done
  fi
  [ -n "$REAL_LUNE" ] || skip "no runnable lune found"
  export RDK_LUNE_BIN=$REAL_LUNE
}
