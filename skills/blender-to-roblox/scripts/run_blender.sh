#!/usr/bin/env bash
# Run a Python script inside a headless Blender, optionally with a .blend file loaded, and
# return the script's exit code. A Python exception exits 1 (--python-exit-code 1).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
usage: run_blender.sh [--blend FILE] [--factory-startup] [--verbose] [--dry-run] [--] SCRIPT.py [--] [ARGS...]

Runs: blender --background [FILE] --python-exit-code 1 --python SCRIPT.py -- ARGS...
Everything after SCRIPT.py goes to the script (a "--" right after it is dropped).
Blender is found on PATH or in the usual install locations (RDK_BLENDER_BIN overrides).
The script's exit code is passed through; a Python exception exits 1.

  --blend FILE        open this .blend before the script runs (otherwise Blender's startup scene)
  --factory-startup   ignore the user's startup file, preferences and add-ons. Off by default:
                      a script that saves preferences would then save factory settings over the user's.
  --verbose           keep Blender's status lines (by default it runs with --quiet)
  --dry-run           print the command instead of running it

SCRIPT.py may be a path or the name of a script next to this one (check_mesh.py, export_fbx.py,
render_preview.py). Each of those has --help.
EOF
}

blend='' factory=0 quiet=1 dry_run=0
while [ $# -gt 0 ]; do
  case $1 in
    --blend)
      [ $# -ge 2 ] || {
        rdk_err "--blend needs a file"
        exit 2
      }
      blend=$2
      shift
      ;;
    --factory-startup) factory=1 ;;
    --verbose) quiet=0 ;;
    --dry-run) dry_run=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      rdk_err "unknown option: $1"
      usage >&2
      exit 2
      ;;
    *) break ;;
  esac
  shift
done

[ $# -ge 1 ] || {
  rdk_err "no script given"
  usage >&2
  exit 2
}
script=$1
shift
[ "${1:-}" != -- ] || shift
if [ ! -f "$script" ] && [ -f "$SCRIPT_DIR/$script" ]; then
  script="$SCRIPT_DIR/$script"
fi
[ -f "$script" ] || {
  rdk_err "script not found: $script"
  exit 2
}
if [ -n "$blend" ] && [ ! -f "$blend" ]; then
  rdk_err "blend file not found: $blend"
  exit 2
fi

blender=$(rdk_find_blender) ||
  rdk_die "Blender not found. Install Blender ${RDK_BLENDER_MIN_VERSION}+ from https://www.blender.org/download/, put it on PATH (roblox-doctor --fix links it into $(rdk_tilde "$RDK_LOCAL_BIN")), or set RDK_BLENDER_BIN."

cmd=("$blender" --background)
[ $factory = 0 ] || cmd+=(--factory-startup)
[ $quiet = 0 ] || cmd+=(--quiet)
[ -z "$blend" ] || cmd+=("$blend")
cmd+=(--python-exit-code 1 --python "$script" -- "$@")

if [ $dry_run = 1 ]; then
  rdk_info "+ $(rdk_quote "${cmd[@]}")"
  exit 0
fi
exec "${cmd[@]}"
