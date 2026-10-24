#!/usr/bin/env bash
# roblox-doctor: read-only health check of a Roblox (Rokit/Rojo) + Studio + Blender + MCP setup.
# Exit 0 = no failures, 1 = at least one failure, 2 = usage error.
# shellcheck disable=SC2329  # section_* functions are called by name from run_checks
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ALL_SECTIONS="toolchain project studio blender mcp cloud"
# The kit's root (for the plugin's marketplace path): three levels above this script's real folder.
KIT_ROOT=$(cd "$(cd "$SCRIPT_DIR" && pwd -P)/../../.." && pwd -P)
[ -f "$KIT_ROOT/.claude-plugin/marketplace.json" ] || KIT_ROOT='<path to roblox-dev-kit>'

usage() {
  cat <<EOF
usage: doctor.sh [--json] [--fix] [--section NAME[,NAME...]] [--project DIR] [--online] [--quiet]

Checks the machine (and the Rojo project found upward from DIR, default: current directory).
Sections: ${ALL_SECTIONS// /, }

  --json      machine-readable output: {"checks": [...], "summary": {...}}
  --fix       apply safe, idempotent fixes (blender symlink, rokit install, wally install,
              rojo sourcemap, rojo plugin install), then check again
  --section   only run these sections (comma-separated)
  --project   look for default.project.json upward from DIR instead of the current directory
  --online    also run checks that need the network (same as RDK_NETWORK_TESTS=1)
  --quiet     table output shows only warnings and failures
EOF
}

usage_error() {
  rdk_err "$1"
  usage >&2
  exit 2
}

json=0 fix=0 quiet=0 online=0 project_given=0
[ "${RDK_NETWORK_TESTS:-0}" = 1 ] && online=1
sections=$ALL_SECTIONS
start_dir=$PWD

while [ $# -gt 0 ]; do
  case $1 in
    --json) json=1 ;;
    --fix) fix=1 ;;
    --quiet | -q) quiet=1 ;;
    --online) online=1 ;;
    --section | --project)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      if [ "$1" = --section ]; then sections=${2//,/ }; else start_dir=$2 project_given=1; fi
      shift
      ;;
    --section=*) sections=${1#--section=} sections=${sections//,/ } ;;
    --project=*) start_dir=${1#--project=} project_given=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

for s in $sections; do
  case " $ALL_SECTIONS " in
    *" $s "*) ;;
    *) usage_error "unknown section: $s" ;;
  esac
done
[ -d "$start_dir" ] || usage_error "not a directory: $start_dir"
start_dir=$(cd "$start_dir" && pwd -P)

# --- check registry -------------------------------------------------------------

C_ID=() C_STATUS=() C_DETAIL=() C_FIX=() C_ACTION=()

# check ID STATUS DETAIL [FIX] [ACTION]: ACTION names a safe fix that --fix may apply.
check() {
  local detail=${3//$'\n'/ } fix=${4:-}
  C_ID+=("$1")
  C_STATUS+=("$2")
  C_DETAIL+=("${detail//$'\t'/ }")
  C_FIX+=("${fix//$'\t'/ }")
  C_ACTION+=("${5:-}")
}

reset_checks() { C_ID=() C_STATUS=() C_DETAIL=() C_FIX=() C_ACTION=(); }

# Context the fixes need, discovered while checking.
PROJECT_ROOT='' BLENDER_BIN=''

# Rokit installs only tools it trusts, and asks interactively the first time; install-toolchain.sh
# --trust records that trust (rokit trust) once the user has agreed.
ROKIT_INSTALL_FIX="rokit install (the first time without a terminal: roblox-setup scripts/install-toolchain.sh --trust)"


count_lines() { printf '%s\n' "$1" | grep -c . || true; }

# wally_deps FILE SECTION: number of entries in [SECTION].
wally_deps() {
  awk -v want="[$2]" '
    /^[[:space:]]*\[/ { cur = $0; sub(/#.*/, "", cur); gsub(/[[:space:]]/, "", cur); next }
    cur == want { line = $0; sub(/#.*/, "", line); if (line ~ /=/) n++ }
    END { print n + 0 }
  ' "$1"
}

# --- sections -------------------------------------------------------------------

section_toolchain() {
  local out rokit_bin manifest='' tools alias spec version bin
  if rokit_bin=$(command -v rokit 2>/dev/null); then
    out=$(rokit --version 2>/dev/null) || true
    check toolchain.rokit ok "${out:-rokit} ($(rdk_tilde "$rokit_bin"))"
  elif [ -x "$RDK_ROKIT_BIN_DIR/rokit" ]; then
    check toolchain.rokit fail "installed in $(rdk_tilde "$RDK_ROKIT_BIN_DIR") but not on PATH" \
      "add to your shell profile: $(rdk_path_line "$RDK_ROKIT_BIN_DIR")"
  else
    check toolchain.rokit fail "rokit not found" "roblox-setup: scripts/install-toolchain.sh"
  fi

  if rdk_path_has "$RDK_ROKIT_BIN_DIR"; then
    check toolchain.rokit-path ok "$(rdk_tilde "$RDK_ROKIT_BIN_DIR") is on PATH"
  else
    check toolchain.rokit-path warn "$(rdk_tilde "$RDK_ROKIT_BIN_DIR") is not on PATH" \
      "add to your shell profile: $(rdk_path_line "$RDK_ROKIT_BIN_DIR")"
  fi

  if [ -n "$PROJECT_ROOT" ] && [ -f "$PROJECT_ROOT/rokit.toml" ]; then
    manifest="$PROJECT_ROOT/rokit.toml"
    tools=$(rdk_rokit_tools "$manifest")
  else
    tools=''
    for alias in $RDK_STANDARD_TOOLS; do tools="$tools$alias"$'\t'$'\n'; done
  fi

  while IFS=$'\t' read -r alias spec; do
    [ -n "$alias" ] || continue
    version=''
    case $spec in *@*) version=${spec##*@} ;; esac
    bin=$(command -v "$alias" 2>/dev/null || true)
    if [ -z "$bin" ] && [ -x "$RDK_ROKIT_BIN_DIR/$alias" ]; then bin="$RDK_ROKIT_BIN_DIR/$alias"; fi
    if [ -z "$bin" ]; then
      if [ -n "$manifest" ]; then
        check "toolchain.tool.$alias" fail "$alias not installed (rokit.toml pins ${version:-it})" "$ROKIT_INSTALL_FIX" rokit-install
      else
        check "toolchain.tool.$alias" fail "$alias not found" "roblox-setup: scripts/install-toolchain.sh --global"
      fi
      continue
    fi
    if ! out=$(cd "${PROJECT_ROOT:-$start_dir}" && "$bin" --version 2>&1); then
      check "toolchain.tool.$alias" fail "$alias is linked but does not run: ${out%%$'\n'*}" "$ROKIT_INSTALL_FIX" rokit-install
    elif [ -n "$version" ] && ! printf '%s' "$out" | grep -Fq -- "$version"; then
      check "toolchain.tool.$alias" warn "${out%%$'\n'*}; rokit.toml pins $version" "$ROKIT_INSTALL_FIX" rokit-install
    else
      check "toolchain.tool.$alias" ok "${out%%$'\n'*}"
    fi
  done <<<"$tools"

  if rdk_has git; then
    out=$(git --version 2>/dev/null) || true
    check toolchain.git ok "${out:-git}"
  else
    check toolchain.git fail "git not found" "install git (macOS: xcode-select --install)"
  fi
  if rdk_has uvx; then
    check toolchain.uv ok "uvx $(rdk_tilde "$(command -v uvx)")"
  else
    check toolchain.uv warn "uv/uvx not found (needed to run the Blender MCP server)" \
      "macOS: brew install uv; elsewhere: https://docs.astral.sh/uv/getting-started/installation/"
  fi
}

section_project() {
  local root=$PROJECT_ROOT f n newer
  if [ -z "$root" ]; then
    check project.detect skip "no default.project.json in $(rdk_tilde "$start_dir") or above"
    return 0
  fi
  check project.detect ok "Rojo project at $(rdk_tilde "$root")"

  for f in rokit.toml wally.toml .luaurc selene.toml stylua.toml; do
    if [ -f "$root/$f" ]; then
      check "project.file.$f" ok "$f present"
    else
      check "project.file.$f" warn "$f missing" "copy it from roblox-setup assets/template/$f"
    fi
  done

  if [ -f "$root/wally.toml" ]; then
    local missing=''
    n=$(wally_deps "$root/wally.toml" dependencies)
    [ "$n" -gt 0 ] && [ ! -d "$root/Packages" ] && missing="$missing Packages/"
    n=$(wally_deps "$root/wally.toml" server-dependencies)
    [ "$n" -gt 0 ] && [ ! -d "$root/ServerPackages" ] && missing="$missing ServerPackages/"
    n=$(wally_deps "$root/wally.toml" dev-dependencies)
    [ "$n" -gt 0 ] && [ ! -d "$root/DevPackages" ] && missing="$missing DevPackages/"
    if [ -n "$missing" ]; then
      check project.packages warn "wally.toml has dependencies but${missing} is missing" "wally install" wally-install
    else
      check project.packages ok "Wally packages in place"
    fi
  fi

  if [ ! -f "$root/sourcemap.json" ]; then
    check project.sourcemap warn "sourcemap.json missing (luau-lsp needs it to resolve the DataModel)" \
      "rojo sourcemap default.project.json -o sourcemap.json" rojo-sourcemap
  else
    newer=''
    if [ -d "$root/src" ]; then
      newer=$(find "$root/src" "$root/default.project.json" -type f -newer "$root/sourcemap.json" 2>/dev/null || true)
    elif [ "$root/default.project.json" -nt "$root/sourcemap.json" ]; then
      newer="$root/default.project.json"
    fi
    if [ -n "$newer" ]; then
      check project.sourcemap warn "sourcemap.json is older than $(rdk_tilde "${newer%%$'\n'*}")" \
        "rojo sourcemap default.project.json -o sourcemap.json (or keep rojo sourcemap --watch running)" rojo-sourcemap
    else
      check project.sourcemap ok "sourcemap.json is up to date"
    fi
  fi

  if rdk_has git && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    check project.git ok "git repository"
  else
    check project.git warn "not a git repository" "git init"
  fi

  if rdk_port_open localhost "$RDK_ROJO_PORT"; then
    check project.rojo-serve ok "something is listening on localhost:$RDK_ROJO_PORT (rojo serve)"
  else
    check project.rojo-serve skip "rojo serve is not running (start it with: rojo serve)"
  fi
}

section_studio() {
  local os bin dir f found=''
  os=$(rdk_os)
  case $os in
    macos)
      if [ -d "$RDK_STUDIO_APP" ]; then
        check studio.app ok "$RDK_STUDIO_APP"
      else
        check studio.app fail "Roblox Studio not found at $RDK_STUDIO_APP" "install Roblox Studio: https://create.roblox.com/docs/studio/setup"
      fi
      ;;
    windows) check studio.app skip "Studio app detection is not implemented on Windows" ;;
    *)
      check studio.app skip "Roblox Studio is not available on $os"
      return 0
      ;;
  esac

  if bin=$(rdk_find_studio_mcp); then
    check studio.mcp-binary ok "$bin"
  else
    check studio.mcp-binary fail "StudioMCP binary not found" "update Roblox Studio (the MCP server ships with it): https://create.roblox.com/docs/studio/mcp"
  fi

  dir=$(rdk_studio_plugins_dir) || dir=''
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    for f in "$dir"/RojoManagedPlugin.rbxm "$dir"/Rojo*.rbxm "$dir"/Rojo*.rbxmx; do
      if [ -f "$f" ]; then
        found=$f
        break
      fi
    done
  fi
  if [ -n "$found" ]; then
    check studio.rojo-plugin ok "Rojo plugin: $(rdk_tilde "$found")"
  else
    check studio.rojo-plugin warn "Rojo Studio plugin not installed in $(rdk_tilde "${dir:-the plugins folder}")" "rojo plugin install" rojo-plugin
  fi

  if [ "$os" = macos ] && rdk_has pgrep && pgrep -x RobloxStudio >/dev/null 2>&1; then
    check studio.running ok "Roblox Studio is running"
  else
    check studio.running skip "Roblox Studio is not running"
  fi
}

section_blender() {
  local bin on_path version series addon_dir manifest addon_version community
  if ! bin=$(rdk_find_blender); then
    check blender.binary fail "Blender not found" "install Blender ${RDK_BLENDER_MIN_VERSION}+ from https://www.blender.org/download/"
    return 0
  fi
  BLENDER_BIN=$bin
  check blender.binary ok "$bin"

  if on_path=$(command -v blender 2>/dev/null); then
    check blender.path ok "blender on PATH ($(rdk_tilde "$on_path"))"
  else
    check blender.path fail "blender is not on PATH" \
      "mkdir -p $(rdk_tilde "$RDK_LOCAL_BIN") && ln -s $(rdk_quote "$bin") $(rdk_tilde "$RDK_LOCAL_BIN")/blender" blender-symlink
  fi

  version=$(rdk_blender_version "$bin" || true)
  if [ -z "$version" ]; then
    check blender.version warn "could not read the Blender version from $bin --version"
    return 0
  elif rdk_version_ge "$version" "$RDK_BLENDER_MIN_VERSION"; then
    check blender.version ok "Blender $version"
  else
    check blender.version fail "Blender $version is older than $RDK_BLENDER_MIN_VERSION (the official MCP add-on needs it)" \
      "install Blender ${RDK_BLENDER_MIN_VERSION}+ from https://www.blender.org/download/"
  fi

  series=$(rdk_blender_series "$version")
  addon_dir=$(rdk_blender_addon_dir "$series")
  manifest="$addon_dir/blender_manifest.toml"
  if [ -f "$manifest" ]; then
    addon_version=$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest")
    if [ "$addon_version" = "$RDK_BLENDER_MCP_VERSION" ]; then
      check blender.addon ok "official MCP add-on $addon_version ($(rdk_tilde "$addon_dir"))"
    else
      check blender.addon warn "official MCP add-on ${addon_version:-?} installed; the kit pins $RDK_BLENDER_MCP_VERSION" \
        "roblox-setup: scripts/setup-blender.sh"
    fi
  else
    check blender.addon fail "official MCP add-on not installed (expected $(rdk_tilde "$addon_dir"))" \
      "roblox-setup: scripts/setup-blender.sh"
  fi

  if rdk_port_open localhost "$RDK_BLENDER_MCP_PORT"; then
    check blender.port ok "add-on server listening on localhost:$RDK_BLENDER_MCP_PORT"
  else
    check blender.port warn "nothing listening on localhost:$RDK_BLENDER_MCP_PORT (Blender not running, Auto Start off, or Online Access disabled)" \
      "start Blender; Preferences > Add-ons > MCP > Auto Start, and Preferences > System > Network > Allow Online Access"
  fi

  if community=$(rdk_blender_community_addon "$series"); then
    check blender.community-addon warn "community blender-mcp add-on found ($(rdk_tilde "$community")); it also uses port $RDK_BLENDER_MCP_PORT" \
      "disable one of the two add-ons in Blender > Preferences > Add-ons"
  else
    check blender.community-addon ok "no community blender-mcp add-on (no port clash)"
  fi

  if [ "$online" != 1 ]; then
    check blender.server skip "offline: run with --online to check that uvx can fetch blender-mcp $RDK_BLENDER_MCP_VERSION"
  elif ! rdk_has uvx; then
    check blender.server fail "uvx not found, so the Blender MCP server cannot start" "macOS: brew install uv"
  elif uvx --from "$RDK_BLENDER_MCP_SPEC" blender-mcp --help >/dev/null 2>&1; then
    check blender.server ok "uvx resolves blender-mcp $RDK_BLENDER_MCP_VERSION"
  else
    check blender.server fail "uvx could not fetch or run blender-mcp from $RDK_BLENDER_MCP_SPEC" \
      "uvx --from '$RDK_BLENDER_MCP_SPEC' blender-mcp --help"
  fi
}

# missing_server HARNESS ID NAME: report a server the harness does not get. Inside a project (a
# Rojo project found upward, or the folder given with --project) it is a failure: registered
# nowhere the harness reads for this project. Outside any project only the user scope is visible,
# and per-project registration is a valid choice, so it is a warning.
missing_server() {
  local h=$1 id=$2 name=$3 dir fix
  if [ -n "$PROJECT_ROOT" ] || [ "$project_given" = 1 ]; then
    dir=${PROJECT_ROOT:-$start_dir}
    fix="roblox-setup: scripts/mcp-config.sh --harness $h --project $(rdk_quote "$dir")"
    if [ "$h" = claude ] && [ "$name" = "$RDK_BLENDER_SERVER" ]; then
      # install.sh --project prints these plugin commands instead of adding a loose Blender server;
      # adding one now would later run beside the plugin's.
      fix="if you want the $RDK_PLUGIN_NAME plugin (it brings this server): cd $(rdk_quote "$dir") && claude plugin marketplace add $(rdk_quote "$KIT_ROOT") --scope project && claude plugin install $RDK_PLUGIN_NAME@$RDK_MARKETPLACE_NAME --scope project; otherwise $fix"
    fi
    check "$id" fail "$name not registered for this project ($(project_files "$h")) or at user scope ($(rdk_tilde "$(rdk_harness_mcp_config "$h")"))" "$fix"
  else
    check "$id" warn "$name not registered at user scope ($(rdk_tilde "$(rdk_harness_mcp_config "$h")")); project-level registration is fine: run the doctor inside the project (or with --project DIR)" \
      "per project: roblox-setup scripts/mcp-config.sh --harness $h --project DIR; user scope: --harness $h"
  fi
}

# project_files HARNESS: the project-level files the harness reads (for messages).
project_files() {
  case $1 in
    claude) echo "./.mcp.json, .claude/settings.json plugins" ;;
    codex) echo "./.codex/config.toml" ;;
    pi) echo "./.pi/mcp.json" ;;
    omp) echo "./.omp/mcp.json, ./.mcp.json, ./.codex/config.toml" ;;
  esac
}

section_mcp() {
  local h where studio_names blender_names dupes
  # Project-level registrations count for the project the doctor checks (else the start directory).
  local RDK_PROJECT_DIR=${PROJECT_ROOT:-$start_dir}
  for h in $RDK_HARNESSES; do
    if ! rdk_harness_installed "$h"; then
      check "mcp.$h" skip "$h is not installed"
      continue
    fi

    if where=$(rdk_mcp_where "$h" "$RDK_STUDIO_SERVER"); then
      check "mcp.$h.studio" ok "$RDK_STUDIO_SERVER registered ($where)"
    else
      missing_server "$h" "mcp.$h.studio" "$RDK_STUDIO_SERVER"
    fi

    if [ "$h" = claude ] && rdk_claude_plugin_enabled; then
      check "mcp.$h.blender" ok "provided by the $RDK_PLUGIN_NAME plugin (plugin_${RDK_PLUGIN_NAME}_blender)"
    elif where=$(rdk_mcp_where "$h" "$RDK_BLENDER_SERVER"); then
      check "mcp.$h.blender" ok "$RDK_BLENDER_SERVER registered ($where)"
    else
      missing_server "$h" "mcp.$h.blender" "$RDK_BLENDER_SERVER"
    fi

    if [ "$h" != codex ] && ! rdk_has_jq; then
      check "mcp.$h.duplicates" skip "duplicate detection needs jq"
      continue
    fi
    studio_names=$(rdk_mcp_names_matching "$h" 'StudioMCP|studio-mcp\.sh' | sort -u || true)
    blender_names=$(rdk_mcp_names_matching "$h" 'blender-mcp|blender_mcp|mcp-for-blender' | sort -u || true)
    if [ "$h" = claude ] && rdk_claude_plugin_enabled; then
      blender_names=$(printf '%s\n%s\n' "$blender_names" "plugin_${RDK_PLUGIN_NAME}_blender" | sed '/^$/d')
    fi
    dupes=''
    [ "$(count_lines "$studio_names")" -gt 1 ] && dupes="Studio: $(printf '%s' "$studio_names" | tr '\n' ' ')"
    [ "$(count_lines "$blender_names")" -gt 1 ] && dupes="$dupes${dupes:+; }Blender: $(printf '%s' "$blender_names" | tr '\n' ' ')"
    if [ -n "$dupes" ]; then
      check "mcp.$h.duplicates" warn "more than one server for the same app (${dupes% }); every tool shows up twice" \
        "keep $RDK_STUDIO_SERVER and $RDK_BLENDER_SERVER (or the plugin's), remove the rest with the harness's mcp remove command"
    else
      check "mcp.$h.duplicates" ok "no duplicate Studio/Blender servers"
    fi
  done
}

section_cloud() {
  if [ -n "${ROBLOX_API_KEY:-}" ]; then
    check cloud.api-key ok "ROBLOX_API_KEY is set (value hidden)"
  else
    check cloud.api-key warn "ROBLOX_API_KEY is not set (only needed for Open Cloud uploads)" \
      "create a key at https://create.roblox.com/dashboard/credentials; see roblox-setup references/manual-steps.md"
  fi
  case "${ROBLOX_CREATOR_TYPE:-}" in
    User | Group)
      if [ -n "${ROBLOX_CREATOR_ID:-}" ]; then
        check cloud.creator ok "$ROBLOX_CREATOR_TYPE $ROBLOX_CREATOR_ID"
      else
        check cloud.creator warn "ROBLOX_CREATOR_TYPE is set but ROBLOX_CREATOR_ID is not" "export ROBLOX_CREATOR_ID=<user or group id>"
      fi
      ;;
    '') check cloud.creator warn "ROBLOX_CREATOR_TYPE / ROBLOX_CREATOR_ID not set (who owns uploaded assets)" \
      "export ROBLOX_CREATOR_TYPE=User (or Group) and ROBLOX_CREATOR_ID=<id>" ;;
    *) check cloud.creator warn "ROBLOX_CREATOR_TYPE must be User or Group, not '$ROBLOX_CREATOR_TYPE'" "export ROBLOX_CREATOR_TYPE=User" ;;
  esac
}

run_checks() {
  local s
  reset_checks
  PROJECT_ROOT=$(rdk_find_project_root "$start_dir" || true)
  for s in $sections; do "section_$s"; done
}

# --- fixes --------------------------------------------------------------------

apply_fix() {
  case $1 in
    blender-symlink)
      mkdir -p "$RDK_LOCAL_BIN"
      if [ -e "$RDK_LOCAL_BIN/blender" ] || [ -L "$RDK_LOCAL_BIN/blender" ]; then
        rdk_warn "$(rdk_tilde "$RDK_LOCAL_BIN")/blender already exists; not replacing it"
        return 1
      fi
      ln -s "$BLENDER_BIN" "$RDK_LOCAL_BIN/blender"
      rdk_path_has "$RDK_LOCAL_BIN" || rdk_warn "$(rdk_tilde "$RDK_LOCAL_BIN") is not on PATH; add: $(rdk_path_line "$RDK_LOCAL_BIN")"
      ;;
    rokit-install)
      # Never --no-trust-check: trusting tools is the user's decision (see ROKIT_INSTALL_FIX).
      (cd "$PROJECT_ROOT" && rokit install) ||
        { rdk_warn "rokit install failed; if Rokit asked to trust tools, run roblox-setup scripts/install-toolchain.sh --trust"; return 1; }
      ;;
    wally-install) (cd "$PROJECT_ROOT" && wally install) ;;
    rojo-sourcemap) (cd "$PROJECT_ROOT" && rojo sourcemap default.project.json -o sourcemap.json) ;;
    rojo-plugin) rojo plugin install ;;
    *) return 1 ;;
  esac
}

needs_tool_for_fix() {
  case $1 in
    rokit-install) echo rokit ;;
    wally-install) echo wally ;;
    rojo-sourcemap | rojo-plugin) echo rojo ;;
  esac
}

run_fixes() {
  local i n=${#C_ID[@]} action tool done_actions=' '
  for ((i = 0; i < n; i++)); do
    action=${C_ACTION[$i]}
    [ -n "$action" ] || continue
    case ${C_STATUS[$i]} in warn | fail) ;; *) continue ;; esac
    case $done_actions in *" $action "*) continue ;; esac
    done_actions="$done_actions$action "
    tool=$(needs_tool_for_fix "$action")
    if [ -n "$tool" ] && ! rdk_has "$tool"; then
      rdk_warn "fix $action skipped: $tool is not on PATH"
      continue
    fi
    rdk_info "fix: $action"
    apply_fix "$action" >&2 || rdk_warn "fix $action failed"
  done
}

# --- output -------------------------------------------------------------------

render_table() {
  local i n=${#C_ID[@]} width=4 id short section prev='' status sym colour ok=0 warn=0 fail=0 skip=0
  for ((i = 0; i < n; i++)); do
    short=${C_ID[$i]#*.}
    [ ${#short} -gt "$width" ] && width=${#short}
  done
  local project=none
  [ -z "$PROJECT_ROOT" ] || project=$(rdk_tilde "$PROJECT_ROOT")
  printf '%sroblox-doctor %s%s  %s  project: %s\n' "$RDK_C_BOLD" "$RDK_KIT_VERSION" "$RDK_C_RESET" "$(rdk_os)" "$project"
  for ((i = 0; i < n; i++)); do
    id=${C_ID[$i]} status=${C_STATUS[$i]}
    case $status in
      ok) ok=$((ok + 1)) sym='✓' colour=$RDK_C_GREEN ;;
      warn) warn=$((warn + 1)) sym='!' colour=$RDK_C_YELLOW ;;
      fail) fail=$((fail + 1)) sym='✗' colour=$RDK_C_RED ;;
      *) skip=$((skip + 1)) sym='-' colour=$RDK_C_DIM ;;
    esac
    if [ $quiet = 1 ] && { [ "$status" = ok ] || [ "$status" = skip ]; }; then continue; fi
    section=${id%%.*}
    if [ "$section" != "$prev" ]; then
      printf '\n%s%s%s\n' "$RDK_C_BOLD" "$section" "$RDK_C_RESET"
      prev=$section
    fi
    printf '  %s%s%s %-*s  %s\n' "$colour" "$sym" "$RDK_C_RESET" "$width" "${id#*.}" "${C_DETAIL[$i]}"
    if [ -n "${C_FIX[$i]}" ] && { [ "$status" = warn ] || [ "$status" = fail ]; }; then
      printf '    %*s  %sfix:%s %s\n' "$width" '' "$RDK_C_DIM" "$RDK_C_RESET" "${C_FIX[$i]}"
    fi
  done
  printf '\n%d ok, %d warn, %d fail, %d skip\n' "$ok" "$warn" "$fail" "$skip"
}

render_json() {
  local i n=${#C_ID[@]} sep='' ok=0 warn=0 fail=0 skip=0
  if rdk_has_jq; then
    for ((i = 0; i < n; i++)); do
      printf '%s\t%s\t%s\t%s\t%s\n' "${C_ID[$i]}" "${C_ID[$i]%%.*}" "${C_STATUS[$i]}" "${C_DETAIL[$i]}" "${C_FIX[$i]}"
    done | jq -R -s '
      split("\n") | map(select(length > 0) | split("\t")
        | {id: .[0], section: .[1], status: .[2], detail: .[3], fix: .[4]})
      | {checks: ., summary: (reduce .[] as $c ({ok: 0, warn: 0, fail: 0, skip: 0}; .[$c.status] += 1))}'
    return
  fi
  printf '{"checks":['
  for ((i = 0; i < n; i++)); do
    case ${C_STATUS[$i]} in
      ok) ok=$((ok + 1)) ;;
      warn) warn=$((warn + 1)) ;;
      fail) fail=$((fail + 1)) ;;
      *) skip=$((skip + 1)) ;;
    esac
    printf '%s{"id":"%s","section":"%s","status":"%s","detail":"%s","fix":"%s"}' "$sep" \
      "$(rdk_json_escape "${C_ID[$i]}")" "$(rdk_json_escape "${C_ID[$i]%%.*}")" "${C_STATUS[$i]}" \
      "$(rdk_json_escape "${C_DETAIL[$i]}")" "$(rdk_json_escape "${C_FIX[$i]}")"
    sep=','
  done
  printf '],"summary":{"ok":%d,"warn":%d,"fail":%d,"skip":%d}}\n' "$ok" "$warn" "$fail" "$skip"
}

# --- main -------------------------------------------------------------------------

run_checks
if [ $fix = 1 ]; then
  run_fixes
  run_checks
fi

if [ $json = 1 ]; then render_json; else render_table; fi

for ((i = 0; i < ${#C_STATUS[@]}; i++)); do
  [ "${C_STATUS[$i]}" = fail ] && exit 1
done
exit 0
