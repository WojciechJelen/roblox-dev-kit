#!/usr/bin/env bash
# Install the official Blender MCP add-on (Blender Lab), turn on Auto Start, and make `blender`
# reachable on PATH. Idempotent. Run it while Blender is closed.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ADDON_URL="https://projects.blender.org/lab/blender_mcp/releases/download/v${RDK_BLENDER_MCP_VERSION}/mcp-${RDK_BLENDER_MCP_VERSION}.zip"
ADDON_SHA256="a7a9da816192502e5a0a202a396444e266b47d8fc4f74ad4698048bd43040707"   # mcp-1.0.3.zip, 17975 bytes
ADDON_MODULE="bl_ext.user_default.mcp"
# projects.blender.org answers plain curl with a Cloudflare challenge; release downloads work with a browser UA.
BROWSER_UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

usage() {
  cat <<EOF
usage: setup-blender.sh [--allow-online-access] [--zip FILE] [--no-symlink] [--force] [--dry-run]

Installs the official MCP add-on $RDK_BLENDER_MCP_VERSION into Blender's "User Default" extensions repo,
enables it with Auto Start, saves preferences, and links blender into $(rdk_tilde "$RDK_LOCAL_BIN") when
it is not on PATH.

  --allow-online-access  also turn on Preferences > System > Network > Allow Online Access.
                         The add-on refuses to start its server while it is off.
  --zip FILE             install this mcp-$RDK_BLENDER_MCP_VERSION.zip instead of downloading it
  --no-symlink           do not create the blender symlink
  --force                run even though Blender is open (it may overwrite the saved preferences on exit)
  --dry-run              print what would happen
EOF
}

allow_online=0 zip='' symlink=1 force=0 dry_run=0
while [ $# -gt 0 ]; do
  case $1 in
    --allow-online-access) allow_online=1 ;;
    --zip)
      [ $# -ge 2 ] || rdk_die "--zip needs a file"
      zip=$2
      shift
      ;;
    --no-symlink) symlink=0 ;;
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      rdk_err "unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

blender=$(rdk_find_blender) || rdk_die "Blender not found. Install Blender ${RDK_BLENDER_MIN_VERSION}+ from https://www.blender.org/download/ (or set RDK_BLENDER_BIN)."
version=$(rdk_blender_version "$blender") || rdk_die "could not read the version of $blender"
rdk_version_ge "$version" "$RDK_BLENDER_MIN_VERSION" ||
  rdk_die "Blender $version is too old: the official MCP add-on needs $RDK_BLENDER_MIN_VERSION or newer"
series=$(rdk_blender_series "$version")
addon_dir=$(rdk_blender_addon_dir "$series")
rdk_info "Blender $version: $blender"

if [ $force = 0 ] && [ "$(rdk_os)" = macos ] && rdk_has pgrep && pgrep -x Blender >/dev/null 2>&1; then
  rdk_die "Blender is running. Quit it first (it can overwrite the preferences this script saves), or pass --force."
fi

if community=$(rdk_blender_community_addon "$series"); then
  rdk_warn "the community blender-mcp add-on is also installed ($(rdk_tilde "$community"))."
  rdk_warn "Both listen on port $RDK_BLENDER_MCP_PORT: disable one of them in Preferences > Add-ons."
fi

# --- 1. the add-on zip ---------------------------------------------------------------

install=1
installed_version=''
if [ -f "$addon_dir/blender_manifest.toml" ]; then
  installed_version=$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$addon_dir/blender_manifest.toml")
fi
if [ "$installed_version" = "$RDK_BLENDER_MCP_VERSION" ]; then
  install=0
  rdk_info "add-on $installed_version already installed in $(rdk_tilde "$addon_dir")"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ $install = 1 ]; then
  if [ -z "$zip" ]; then
    zip="$tmp/mcp-$RDK_BLENDER_MCP_VERSION.zip"
    rdk_info "downloading $ADDON_URL"
    [ $dry_run = 1 ] || curl -fsSL -A "$BROWSER_UA" -o "$zip" "$ADDON_URL"
  fi
  if [ $dry_run = 0 ]; then
    [ -f "$zip" ] || rdk_die "add-on zip not found: $zip"
    sum=$(rdk_sha256 "$zip")
    [ "$sum" = "$ADDON_SHA256" ] || rdk_die "checksum mismatch for $zip: got $sum, expected $ADDON_SHA256"
  fi
fi

# --- 2. install, enable, Auto Start, save preferences ------------------------------------

# Runs with the user's normal preferences loaded (never --factory-startup, which would save
# factory defaults over them). Any exception makes Blender exit 1 via --python-exit-code.
read -r -d '' PY <<'PYEOF' || true
import sys
import bpy
import addon_utils

zip_path, install, allow_online, module = sys.argv[sys.argv.index("--") + 1:]
prefs = bpy.context.preferences
if install == "1":
    result = bpy.ops.extensions.package_install_files(
        filepath=zip_path, repo="user_default", enable_on_install=True, overwrite=True)
    if "FINISHED" not in result:
        raise RuntimeError("package_install_files returned %r" % (result,))
if prefs.addons.get(module) is None:
    addon_utils.enable(module, default_set=True)
addon = prefs.addons.get(module)
if addon is None or addon.preferences is None:
    raise RuntimeError("add-on %s is not enabled after installation" % module)
addon.preferences.use_autostart = True
if allow_online == "1":
    prefs.system.use_online_access = True
bpy.ops.wm.save_userpref()
print("RDK-RESULT enabled=1 autostart=%d online_access=%d" % (
    addon.preferences.use_autostart, prefs.system.use_online_access))
PYEOF

if [ $install = 1 ]; then
  rdk_info "installing and enabling the add-on (Blender runs in the background)"
else
  rdk_info "making sure the add-on is enabled with Auto Start (Blender runs in the background)"
fi
if [ $dry_run = 1 ]; then
  rdk_info "+ $(rdk_quote "$blender" --background --python-exit-code 1 --python-expr '<script>' -- "${zip:-<zip>}" "$install" "$allow_online" "$ADDON_MODULE")"
  online_access=unknown
else
  if ! out=$("$blender" --background --python-exit-code 1 --python-expr "$PY" -- "${zip:-none}" "$install" "$allow_online" "$ADDON_MODULE" 2>&1); then
    printf '%s\n' "$out" | tail -n 20 >&2
    rdk_die "Blender could not install or enable the add-on (output above)"
  fi
  result=$(printf '%s\n' "$out" | grep '^RDK-RESULT ' || true)
  [ -n "$result" ] || rdk_die "Blender finished without confirming the add-on state"
  case $result in *online_access=1*) online_access=1 ;; *) online_access=0 ;; esac
  rdk_info "add-on enabled with Auto Start ($(rdk_tilde "$addon_dir"))"
fi

# --- 3. blender on PATH ------------------------------------------------------------------

if [ $symlink = 1 ] && ! rdk_has blender; then
  link="$RDK_LOCAL_BIN/blender"
  if [ -e "$link" ] || [ -L "$link" ]; then
    rdk_warn "$(rdk_tilde "$link") already exists but is not on PATH; leaving it alone"
  else
    rdk_info "+ ln -s $(rdk_quote "$blender") $(rdk_tilde "$link")"
    if [ $dry_run = 0 ]; then
      mkdir -p "$RDK_LOCAL_BIN"
      ln -s "$blender" "$link"
    fi
  fi
  if ! rdk_path_has "$RDK_LOCAL_BIN"; then
    rdk_info "$(rdk_tilde "$RDK_LOCAL_BIN") is not on PATH. Add this line to your shell profile:"
    rdk_info "  $(rdk_path_line "$RDK_LOCAL_BIN")"
  fi
fi

# --- 4. what is left for the user ---------------------------------------------------------

if [ "$online_access" = 0 ]; then
  rdk_warn "Blender's 'Allow Online Access' is off, so the add-on will not start its server."
  rdk_warn "Turn it on in Preferences > System > Network, or re-run with --allow-online-access."
fi
rdk_info "done: start Blender and the add-on listens on localhost:$RDK_BLENDER_MCP_PORT (check with the roblox-doctor skill)"
