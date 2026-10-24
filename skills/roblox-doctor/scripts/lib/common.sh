#!/usr/bin/env bash
# vendored from /lib/common.sh — edit the source, run make sync-lib
# Shared shell helpers for roblox-dev-kit. Source this file; do not execute it.
# Works on macOS bash 3.2 and bash 5. Every machine-specific path can be
# overridden with an RDK_* variable so tests can fake the whole machine.
# shellcheck disable=SC2034  # constants and colours are used by the scripts that source this
set -euo pipefail

# --- constants ---------------------------------------------------------------

RDK_KIT_VERSION="0.1.0"
RDK_PLUGIN_NAME="roblox"
RDK_STUDIO_SERVER="Roblox_Studio"   # the name Studio's own "Quick connect" uses
RDK_BLENDER_SERVER="blender"
RDK_BLENDER_MCP_VERSION="1.0.3"
RDK_BLENDER_MIN_VERSION="5.1"
RDK_BLENDER_MCP_SPEC="git+https://projects.blender.org/lab/blender_mcp.git@v${RDK_BLENDER_MCP_VERSION}#subdirectory=mcp"
RDK_ROJO_PORT="34872"
RDK_HARNESSES="claude codex pi omp"
RDK_STANDARD_TOOLS="rojo wally lune stylua selene luau-lsp zap asphalt"

# --- overridable paths ---------------------------------------------------------

RDK_HOME="${RDK_HOME:-$HOME}"
RDK_ROKIT_BIN_DIR="${RDK_ROKIT_BIN_DIR:-$RDK_HOME/.rokit/bin}"
RDK_LOCAL_BIN="${RDK_LOCAL_BIN:-$RDK_HOME/.local/bin}"
RDK_BLENDER_APP="${RDK_BLENDER_APP:-/Applications/Blender.app}"
RDK_STUDIO_APP="${RDK_STUDIO_APP:-/Applications/RobloxStudio.app}"
RDK_BLENDER_MCP_PORT="${RDK_BLENDER_MCP_PORT:-9876}"

# --- logging -----------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  RDK_C_RED=$'\033[31m' RDK_C_GREEN=$'\033[32m' RDK_C_YELLOW=$'\033[33m'
  RDK_C_DIM=$'\033[2m' RDK_C_BOLD=$'\033[1m' RDK_C_RESET=$'\033[0m'
else
  RDK_C_RED='' RDK_C_GREEN='' RDK_C_YELLOW='' RDK_C_DIM='' RDK_C_BOLD='' RDK_C_RESET=''
fi

rdk_info() { printf '%s\n' "$*" >&2; }
rdk_warn() { printf '%swarning:%s %s\n' "$RDK_C_YELLOW" "$RDK_C_RESET" "$*" >&2; }
rdk_err() { printf '%serror:%s %s\n' "$RDK_C_RED" "$RDK_C_RESET" "$*" >&2; }
rdk_die() {
  rdk_err "$*"
  exit 1
}

# --- generic helpers -----------------------------------------------------------

rdk_has() { command -v "$1" >/dev/null 2>&1; }

# jq is optional for read-only checks; RDK_NO_JQ=1 forces the fallbacks (used by the tests).
rdk_has_jq() { [ "${RDK_NO_JQ:-0}" != 1 ] && rdk_has jq; }

rdk_os() {
  if [ -n "${RDK_OS:-}" ]; then
    printf '%s\n' "$RDK_OS"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux) echo linux ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

# rdk_version_ge A B: true when dotted version A >= B. Non-numeric suffixes are ignored.
rdk_version_ge() {
  local a b i x y
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2 3; do
    x=${a[$i]:-0} y=${b[$i]:-0}
    x=${x%%[!0-9]*} y=${y%%[!0-9]*}
    x=${x:-0} y=${y:-0}
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}

# rdk_path_has DIR: true when DIR is an entry of $PATH.
rdk_path_has() {
  case ":${PATH}:" in
    *":$1:"* | *":$1/:"*) return 0 ;;
  esac
  return 1
}

# rdk_path_line DIR: the line a user adds to their shell profile to put DIR on PATH.
# Scripts print it; they never edit shell rc files themselves.
rdk_path_line() {
  local d=$1
  case $d in
    "$RDK_HOME"/*) d="\$HOME${d#"$RDK_HOME"}" ;;
  esac
  # shellcheck disable=SC2016  # $PATH is meant literally
  printf 'export PATH="%s:$PATH"\n' "$d"
}

# rdk_tilde PATH: replace the home prefix with ~ for display.
rdk_tilde() {
  case $1 in
    "$RDK_HOME") printf '~\n' ;;
    "$RDK_HOME"/*) printf '~%s\n' "${1#"$RDK_HOME"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

rdk_sha256() {
  if rdk_has shasum; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

rdk_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  # Remaining control characters are never meaningful in our output; drop them.
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# rdk_quote ARG...: print the arguments as one shell-safe command line.
rdk_quote() {
  local out='' a
  for a in "$@"; do
    case $a in
      '' | *[!A-Za-z0-9_./:=@%+,-]*) a="'$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'" ;;
    esac
    out="$out${out:+ }$a"
  done
  printf '%s\n' "$out"
}

# rdk_port_open HOST PORT: true when something accepts TCP connections there.
rdk_port_open() {
  # bash's /dev/tcp has no timeout, but a closed local port refuses immediately.
  if (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null; then
    return 0
  fi
  # Some bash builds lack /dev/tcp; python is the portable fallback (no nc dependency).
  if rdk_has python3; then
    python3 -I -c 'import socket,sys
try: socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=1).close()
except OSError: sys.exit(1)' "$1" "$2" 2>/dev/null
    return
  fi
  return 1
}

# --- projects ------------------------------------------------------------------

# rdk_check_project_name NAME: names end up in JSON, TOML, Markdown and sed replacements;
# this character set needs no escaping in any of them.
rdk_check_project_name() {
  case $1 in
    [A-Za-z0-9]*) ;;
    *) rdk_die "project name must start with a letter or digit: $1" ;;
  esac
  case $1 in
    *[!A-Za-z0-9\ _-]*) rdk_die "project name may only contain letters, digits, spaces, '_' and '-': $1" ;;
  esac
  [ ${#1} -le 50 ] || rdk_die "project name is longer than 50 characters: $1"
}

# rdk_package_name NAME: lowercase kebab-case, as Wally package names require.
rdk_package_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-' | sed 's/^-//; s/-$//'
}

# --- Blender -----------------------------------------------------------------

rdk_find_blender() {
  local p
  if [ -n "${RDK_BLENDER_BIN:-}" ]; then
    [ -x "$RDK_BLENDER_BIN" ] || return 1
    printf '%s\n' "$RDK_BLENDER_BIN"
    return 0
  fi
  if p=$(command -v blender 2>/dev/null); then
    printf '%s\n' "$p"
    return 0
  fi
  case "$(rdk_os)" in
    macos)
      for p in "$RDK_BLENDER_APP/Contents/MacOS/Blender" "$RDK_HOME/Applications/Blender.app/Contents/MacOS/Blender"; do
        if [ -x "$p" ]; then
          printf '%s\n' "$p"
          return 0
        fi
      done
      ;;
    linux)
      for p in /snap/bin/blender /usr/local/bin/blender /usr/bin/blender; do
        if [ -x "$p" ]; then
          printf '%s\n' "$p"
          return 0
        fi
      done
      ;;
  esac
  return 1
}

# rdk_blender_version BIN: print "5.2.1" from `Blender --version`.
rdk_blender_version() {
  local out line
  out=$("$1" --version 2>/dev/null) || true
  while IFS= read -r line; do
    case $line in
      "Blender "[0-9]*)
        line=${line#Blender }
        printf '%s\n' "${line%% *}"
        return 0
        ;;
    esac
  done <<<"$out"
  return 1
}

# rdk_blender_series 5.2.1 -> 5.2 (the folder name Blender uses for user data).
rdk_blender_series() {
  local major minor rest
  IFS=. read -r major minor rest <<<"$1"
  printf '%s.%s\n' "$major" "${minor:-0}"
}

# The rdk_blender_*_dir helpers mirror Blender's own BLENDER_USER_* overrides.
rdk_blender_resources_dir() {
  if [ -n "${BLENDER_USER_RESOURCES:-}" ]; then
    printf '%s\n' "$BLENDER_USER_RESOURCES"
    return 0
  fi
  case "$(rdk_os)" in
    macos) printf '%s\n' "$RDK_HOME/Library/Application Support/Blender/$1" ;;
    linux) printf '%s\n' "${XDG_CONFIG_HOME:-$RDK_HOME/.config}/blender/$1" ;;
    windows) printf '%s\n' "${APPDATA:-$RDK_HOME/AppData/Roaming}/Blender Foundation/Blender/$1" ;;
    *) return 1 ;;
  esac
}

rdk_blender_ext_dir() {
  if [ -n "${BLENDER_USER_EXTENSIONS:-}" ]; then
    printf '%s\n' "$BLENDER_USER_EXTENSIONS"
    return 0
  fi
  printf '%s/extensions\n' "$(rdk_blender_resources_dir "$1")"
}

rdk_blender_scripts_dir() {
  if [ -n "${BLENDER_USER_SCRIPTS:-}" ]; then
    printf '%s\n' "$BLENDER_USER_SCRIPTS"
    return 0
  fi
  printf '%s/scripts\n' "$(rdk_blender_resources_dir "$1")"
}

# Official add-on location, confirmed by a real install on Blender 5.2.1:
# <extensions>/user_default/mcp (module bl_ext.user_default.mcp).
rdk_blender_addon_dir() { printf '%s/user_default/mcp\n' "$(rdk_blender_ext_dir "$1")"; }

# rdk_blender_community_addon SERIES: print a file of the community add-on (ahujasid/blender-mcp)
# if it is installed. It listens on the same port as the official one; its code names things blendermcp_*.
rdk_blender_community_addon() {
  local d hits official
  official=$(rdk_blender_addon_dir "$1")
  for d in "$(rdk_blender_scripts_dir "$1")/addons" "$(rdk_blender_ext_dir "$1")"; do
    [ -d "$d" ] || continue
    hits=$(grep -rl --include='*.py' -e 'blendermcp_' "$d" 2>/dev/null | grep -v -F "$official/" || true)
    if [ -n "$hits" ]; then
      printf '%s\n' "${hits%%$'\n'*}"
      return 0
    fi
  done
  return 1
}

# --- Roblox Studio -------------------------------------------------------------

rdk_find_studio_mcp() {
  local p
  if [ -n "${RDK_STUDIO_MCP_BIN:-}" ]; then
    [ -x "$RDK_STUDIO_MCP_BIN" ] || return 1
    printf '%s\n' "$RDK_STUDIO_MCP_BIN"
    return 0
  fi
  case "$(rdk_os)" in
    macos) p="$RDK_STUDIO_APP/Contents/MacOS/StudioMCP" ;;
    # Path stub (untested): Roblox documents `cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat` on Windows.
    windows) p="${LOCALAPPDATA:-$RDK_HOME/AppData/Local}/Roblox/mcp.bat" ;;
    *) return 1 ;;
  esac
  [ -f "$p" ] || return 1
  printf '%s\n' "$p"
}

rdk_studio_plugins_dir() {
  if [ -n "${RDK_STUDIO_PLUGINS_DIR:-}" ]; then
    printf '%s\n' "$RDK_STUDIO_PLUGINS_DIR"
    return 0
  fi
  case "$(rdk_os)" in
    macos) printf '%s\n' "$RDK_HOME/Documents/Roblox/Plugins" ;;
    windows) printf '%s\n' "${LOCALAPPDATA:-$RDK_HOME/AppData/Local}/Roblox/Plugins" ;;
    *) return 1 ;;
  esac
}

# --- harnesses -----------------------------------------------------------------

rdk_is_harness() {
  case $1 in
    claude | codex | pi | omp) return 0 ;;
  esac
  return 1
}

rdk_harness_installed() { rdk_is_harness "$1" && rdk_has "$1"; }

rdk_claude_dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$RDK_HOME/.claude}"; }

rdk_claude_json() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_CONFIG_DIR/.claude.json"
  else
    printf '%s\n' "$RDK_HOME/.claude.json"
  fi
}

rdk_codex_config() { printf '%s\n' "${CODEX_HOME:-$RDK_HOME/.codex}/config.toml"; }
rdk_pi_mcp_json() { printf '%s\n' "$RDK_HOME/.pi/agent/mcp.json"; }
rdk_omp_mcp_json() { printf '%s\n' "$RDK_HOME/.omp/agent/mcp.json"; }

rdk_harness_mcp_config() {
  case $1 in
    claude) rdk_claude_json ;;
    codex) rdk_codex_config ;;
    pi) rdk_pi_mcp_json ;;
    omp) rdk_omp_mcp_json ;;
    *) return 1 ;;
  esac
}

# Codex, pi and OMP all read ~/.agents/skills; Claude Code reads ~/.claude/skills.
rdk_harness_skills_dir() {
  case $1 in
    claude) printf '%s/skills\n' "$(rdk_claude_dir)" ;;
    codex | pi | omp) printf '%s\n' "$RDK_HOME/.agents/skills" ;;
    *) return 1 ;;
  esac
}

# rdk_mcp_launch_lines HARNESS: print "name<TAB>command args..." per registered server.
# Claude Code: user scope plus local scope for $PWD. Needs jq for JSON configs.
rdk_mcp_launch_lines() {
  local f
  f=$(rdk_harness_mcp_config "$1") || return 1
  [ -f "$f" ] || return 0
  case $1 in
    codex)
      awk '
        /^[[:space:]]*\[/ {
          cur = ""
          if (match($0, /^[[:space:]]*\[mcp_servers\.[^].]+/)) {
            cur = substr($0, RSTART, RLENGTH)
            sub(/^[[:space:]]*\[mcp_servers\./, "", cur)
            gsub(/"/, "", cur)
            if (!(cur in seen)) { seen[cur] = 1; order[++n] = cur }
          }
          next
        }
        cur != "" && /^[[:space:]]*(command|args)[[:space:]]*=/ { launch[cur] = launch[cur] " " $0 }
        END { for (i = 1; i <= n; i++) print order[i] "\t" launch[order[i]] }
      ' "$f"
      ;;
    claude)
      rdk_has_jq || return 1
      jq -r --arg cwd "$PWD" '
        [(.mcpServers // {}), (.projects[$cwd].mcpServers // {})] | add | to_entries[]
        | "\(.key)\t\(.value.command // .value.url // "") \((.value.args // []) | join(" "))"' "$f"
      ;;
    pi | omp)
      rdk_has_jq || return 1
      jq -r '(.mcpServers // {}) | to_entries[]
        | "\(.key)\t\(.value.command // .value.url // "") \((.value.args // []) | join(" "))"' "$f"
      ;;
  esac
}

# rdk_mcp_has HARNESS NAME: true when NAME is registered for HARNESS.
rdk_mcp_has() {
  local f
  f=$(rdk_harness_mcp_config "$1") || return 1
  [ -f "$f" ] || return 1
  if [ "$1" = codex ] || rdk_has_jq; then
    rdk_mcp_launch_lines "$1" | cut -f1 | grep -Fxq -- "$2"
  else
    # Without jq this may also match a same-named server in another Claude project scope.
    grep -Eq "\"$2\"[[:space:]]*:[[:space:]]*\\{" "$f"
  fi
}

# rdk_mcp_names_matching HARNESS ERE: names whose command/args match ERE.
rdk_mcp_names_matching() {
  rdk_mcp_launch_lines "$1" | awk -F '\t' -v re="$2" '$2 ~ re { print $1 }'
}

# The Claude Code plugin counts as enabled when any roblox@<marketplace> entry is true
# in the user settings or in the current project's settings.
rdk_claude_plugin_enabled() {
  local f
  for f in "$(rdk_claude_dir)/settings.json" "$PWD/.claude/settings.json" "$PWD/.claude/settings.local.json"; do
    [ -f "$f" ] || continue
    if rdk_has_jq; then
      jq -e --arg p "$RDK_PLUGIN_NAME@" \
        '[(.enabledPlugins // {}) | to_entries[] | select((.key | startswith($p)) and .value == true)] | length > 0' \
        "$f" >/dev/null 2>&1 && return 0
    else
      grep -Eq "\"$RDK_PLUGIN_NAME@[^\"]+\"[[:space:]]*:[[:space:]]*true" "$f" && return 0
    fi
  done
  return 1
}
