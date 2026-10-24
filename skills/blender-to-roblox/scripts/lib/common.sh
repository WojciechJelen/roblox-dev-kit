#!/usr/bin/env bash
# vendored from /lib/common.sh — edit the source, run make sync-lib
# Shared shell helpers for roblox-dev-kit. Source this file; do not execute it.
# Works on macOS bash 3.2 and bash 5. Every machine-specific path can be
# overridden with an RDK_* variable so tests can fake the whole machine.
# shellcheck disable=SC2034,SC2016  # constants are used by the sourcing scripts; jq filters use $names literally
set -euo pipefail

# --- constants ---------------------------------------------------------------

RDK_KIT_VERSION="0.1.0"
RDK_PLUGIN_NAME="roblox"
RDK_MARKETPLACE_NAME="roblox-dev-kit" # .claude-plugin/marketplace.json "name"
RDK_STUDIO_SERVER="Roblox_Studio"   # the name Studio's own "Quick connect" uses
RDK_BLENDER_SERVER="blender"
RDK_BLENDER_MCP_VERSION="1.0.3"
RDK_BLENDER_MIN_VERSION="5.1"
RDK_BLENDER_MCP_SPEC="git+https://projects.blender.org/lab/blender_mcp.git@v${RDK_BLENDER_MCP_VERSION}#subdirectory=mcp"
RDK_HARNESSES="claude codex pi omp"
RDK_STANDARD_TOOLS="rojo wally lune stylua selene luau-lsp zap asphalt"
# Sent with every web request the kit makes; Poly Haven's API terms ask for a user agent that names the software.
RDK_USER_AGENT="roblox-dev-kit/${RDK_KIT_VERSION} (+https://github.com/WojciechJelen/roblox-dev-kit)"

# --- overridable paths ---------------------------------------------------------

RDK_HOME="${RDK_HOME:-$HOME}"
RDK_ROKIT_BIN_DIR="${RDK_ROKIT_BIN_DIR:-${ROKIT_ROOT:-$RDK_HOME/.rokit}/bin}"
RDK_LOCAL_BIN="${RDK_LOCAL_BIN:-$RDK_HOME/.local/bin}"
RDK_BLENDER_APP="${RDK_BLENDER_APP:-/Applications/Blender.app}"
RDK_STUDIO_APP="${RDK_STUDIO_APP:-/Applications/RobloxStudio.app}"
RDK_BLENDER_MCP_PORT="${RDK_BLENDER_MCP_PORT:-9876}"
RDK_ROJO_PORT="${RDK_ROJO_PORT:-34872}"

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

rdk_md5() {
  if rdk_has md5sum; then
    md5sum "$1" | cut -d' ' -f1
  else
    md5 -q "$1"
  fi
}

# rdk_uri TEXT: TEXT percent-encoded for a URL query value or path segment (needs jq).
rdk_uri() { jq -rn --arg v "$1" '$v | @uri'; }

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

# rdk_find_project_root DIR: the nearest directory at or above DIR holding default.project.json.
rdk_find_project_root() {
  local d=$1
  while :; do
    if [ -f "$d/default.project.json" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    [ "$d" = / ] && return 1
    d=$(dirname "$d")
  done
}

# rdk_check_project_target DIR [FORCE]: exit unless DIR (physical path) is a sensible place for
# per-project agent files. A plugin folder is not a project; a subfolder of a Rojo project is
# refused unless FORCE is 1, because agents read project files from the folder they start in.
rdk_check_project_target() {
  local dir=$1 root
  if [ -f "$dir/.claude-plugin/plugin.json" ]; then
    rdk_die "$dir is a Claude Code plugin (it has .claude-plugin/plugin.json), not a project; pass the game's folder"
  fi
  if root=$(rdk_find_project_root "$dir") && [ "$root" != "$dir" ] && [ "${2:-0}" != 1 ]; then
    rdk_die "$dir is inside the Rojo project $root, and agents read project files from the folder they start in (normally the project root). Use --project $root, or add --force to write into $dir anyway."
  fi
}

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

# rdk_rokit_tools FILE: "alias<TAB>owner/repo@version" for each entry of rokit.toml's [tools].
# Table headers are compared without trailing comments ("[tools] # pinned" still counts).
rdk_rokit_tools() {
  awk '
    /^[[:space:]]*\[/ { h = $0; sub(/#.*/, "", h); gsub(/[[:space:]]/, "", h); in_tools = (h == "[tools]"); next }
    in_tools {
      line = $0
      sub(/#.*/, "", line)
      if (line !~ /=/) next
      alias = line; sub(/=.*/, "", alias); gsub(/[[:space:]"]/, "", alias)
      spec = line; sub(/^[^=]*=/, "", spec); gsub(/[[:space:]"]/, "", spec)
      if (alias != "" && spec != "") print alias "\t" spec
    }
  ' "$1"
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

# rdk_find_uvx: RDK_UVX if set (and only that), else uvx on PATH, else the usual install
# locations (GUI-started harnesses often have a minimal PATH).
rdk_find_uvx() {
  local p
  if [ -n "${RDK_UVX:-}" ]; then
    [ -x "$RDK_UVX" ] || return 1
    printf '%s\n' "$RDK_UVX"
    return 0
  fi
  if p=$(command -v uvx 2>/dev/null); then
    printf '%s\n' "$p"
    return 0
  fi
  for p in /opt/homebrew/bin/uvx /usr/local/bin/uvx "$RDK_HOME/.local/bin/uvx" "$RDK_HOME/.cargo/bin/uvx"; do
    if [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# rdk_find_lune: a lune binary that runs. RDK_LUNE_BIN if set (and only that), else lune on PATH,
# Rokit's shim, then the newest binary in Rokit's tool storage. A Rokit shim only runs where a
# rokit.toml (the project's or Rokit's global one) lists lune, so each candidate is tried first.
rdk_find_lune() {
  local p v stored='' stored_v=''
  if [ -n "${RDK_LUNE_BIN:-}" ]; then
    [ -x "$RDK_LUNE_BIN" ] || return 1
    printf '%s\n' "$RDK_LUNE_BIN"
    return 0
  fi
  for p in "${ROKIT_ROOT:-$RDK_HOME/.rokit}"/tool-storage/lune-org/lune/*/lune; do
    [ -x "$p" ] || continue
    v=$(basename "$(dirname "$p")")
    if [ -z "$stored" ] || rdk_version_ge "$v" "$stored_v"; then stored=$p stored_v=$v; fi
  done
  for p in "$(command -v lune 2>/dev/null || true)" "$RDK_ROKIT_BIN_DIR/lune" "$stored"; do
    [ -n "$p" ] && [ -x "$p" ] || continue
    if "$p" --version 2>/dev/null | grep -qi '^lune '; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# rdk_warm_blender_server: fetch and build the pinned Blender MCP server into uv's cache.
# A cold `uvx --from git+...` start clones ~200 MB and takes ~45 s, longer than MCP clients
# wait for a server to start; once cached it starts in ~4 s.
rdk_warm_blender_server() {
  local uvx_bin out
  if ! uvx_bin=$(rdk_find_uvx); then
    rdk_warn "uvx not found, so the Blender MCP server cannot be prepared (macOS: brew install uv)"
    return 1
  fi
  rdk_info "preparing the Blender MCP server $RDK_BLENDER_MCP_VERSION in uv's cache (the first time downloads ~200 MB, about a minute)"
  if out=$("$uvx_bin" --from "$RDK_BLENDER_MCP_SPEC" blender-mcp --help 2>&1); then
    rdk_info "Blender MCP server ready"
    return 0
  fi
  printf '%s\n' "$out" | tail -n 5 >&2
  rdk_warn "could not prepare the Blender MCP server; the first MCP session may time out while uvx downloads it"
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

# Project-level configs belong to the project the scripts work on: RDK_PROJECT_DIR (set by
# mcp-config.sh --project and by the doctor inside a project), else the current directory. Paths
# are physical: Claude Code keys its local scope by the real path, not a symlinked one.
rdk_project_dir() {
  if [ -n "${RDK_PROJECT_DIR:-}" ]; then printf '%s\n' "$RDK_PROJECT_DIR"; else pwd -P; fi
}
rdk_codex_project_config() { printf '%s/.codex/config.toml\n' "$(rdk_project_dir)"; }
rdk_pi_project_mcp_json() { printf '%s/.pi/mcp.json\n' "$(rdk_project_dir)"; }
rdk_omp_project_mcp_json() { printf '%s/.omp/mcp.json\n' "$(rdk_project_dir)"; }

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

# --- MCP registrations ---------------------------------------------------------
# Launch lines are "name<TAB>command args..." and feed the duplicate check.

# rdk_json_launch_lines FILE FILTER: launch lines for the server map that jq FILTER selects
# ($cwd is bound to the project directory). Needs jq.
rdk_json_launch_lines() {
  [ -f "$1" ] || return 0
  rdk_has_jq || return 1
  jq -r --arg cwd "$(rdk_project_dir)" "$2"' | to_entries[]
    | "\(.key)\t\(.value.command // .value.url // "") \((.value.args // []) | join(" "))"' "$1"
}

# rdk_toml_launch_lines FILE: launch lines for the MCP servers a Codex-style config.toml defines.
# A server counts when it has its own table ([mcp_servers.<name>]) or, inline or with dotted keys,
# a command or url: `<name> = { command = ... }` or `<name>.command = ...` under [mcp_servers],
# or `mcp_servers.<name>.command = ...` at the top, or a one-line `mcp_servers = { <name> = {...} }`.
# Subtables such as [mcp_servers.<name>.env] belong to their server but do not define it.
rdk_toml_launch_lines() {
  [ -f "$1" ] || return 0
  awk '
    function unquote(s) { gsub(/["'\''[:space:]]/, "", s); return s }
    function note(name, text) {
      if (!(name in seen)) { seen[name] = 1; order[++n] = name }
      if (text != "") launch[name] = launch[name] " " text
    }
    # key_line NAME_INDEX: a "a.b.c = value" line seen from a table; parts[NAME_INDEX] is the server.
    function key_line(i,    k, parts, cnt, key) {
      k = $0; sub(/=.*/, "", k); k = unquote(k)
      cnt = split(k, parts, ".")
      if (cnt < i) return
      key = (cnt == i) ? "" : parts[i + 1]
      if (key == "" || key == "command" || key == "url") { note(parts[i], $0); defined[parts[i]] = 1 }
      else if (key == "args" && cnt == i + 1) note(parts[i], $0)
    }
    # inline_servers TEXT: names at brace depth 1 of a one-line `mcp_servers = { a = {...}, b = {...} }`.
    function inline_servers(text,    i, c, depth, tok, name) {
      depth = 0; tok = ""
      for (i = 1; i <= length(text); i++) {
        c = substr(text, i, 1)
        if (c == "{") {
          if (depth == 1) { name = tok; sub(/=.*/, "", name); name = unquote(name); if (name != "") { note(name, text); defined[name] = 1 } }
          depth++; tok = ""
        } else if (c == "}") { depth--; tok = "" }
        else if (c == ",") tok = ""
        else tok = tok c
      }
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ {
      h = $0; sub(/^[[:space:]]*\[+/, "", h); sub(/\].*$/, "", h); h = unquote(h)
      table = h; cur = ""
      if (h ~ /^mcp_servers\.[^.]+$/) { cur = substr(h, 13); note(cur, ""); defined[cur] = 1 }
      next
    }
    !/=/ { next }
    table == "" && /^[[:space:]]*"?mcp_servers"?[[:space:]]*\./ { key_line(2); next }
    table == "" && /^[[:space:]]*"?mcp_servers"?[[:space:]]*=/ { inline_servers($0); next }
    table == "mcp_servers" { key_line(1); next }
    cur != "" && /^[[:space:]]*(command|args)[[:space:]]*=/ { launch[cur] = launch[cur] " " $0 }
    END { for (i = 1; i <= n; i++) if (order[i] in defined) print order[i] "\t" launch[order[i]] }
  ' "$1"
}

# rdk_json_has_server FILE FILTER NAME. Without jq it greps the whole file, which may also
# match a same-named server in another scope of that file.
rdk_json_has_server() {
  [ -f "$1" ] || return 1
  if rdk_has_jq; then
    jq -e --arg cwd "$(rdk_project_dir)" --arg n "$3" "$2"' | has($n)' "$1" >/dev/null 2>&1
  else
    grep -Eq "\"$3\"[[:space:]]*:[[:space:]]*\\{" "$1"
  fi
}

rdk_toml_has_server() { rdk_toml_launch_lines "$1" | cut -f1 | grep -Fxq -- "$2"; }

# rdk_project_mcp_json: the project's .mcp.json. A .mcp.json next to .claude-plugin/plugin.json
# is a plugin's bundled config (this kit's own repo), not a project's.
rdk_project_mcp_json() {
  local d
  d=$(rdk_project_dir)
  [ -f "$d/.claude-plugin/plugin.json" ] && return 1
  printf '%s\n' "$d/.mcp.json"
}

# rdk_mcp_launch_lines HARNESS: every server the harness's own configs define, at user scope and
# for the project. Claude Code: user scope, local scope for the project and its .mcp.json.
# Codex, pi and OMP: the user file and the project's .codex/config.toml, .pi/mcp.json or
# .omp/mcp.json (OMP's imports of other tools' files are not listed).
rdk_mcp_launch_lines() {
  local f
  case $1 in
    claude)
      rdk_json_launch_lines "$(rdk_claude_json)" '[(.mcpServers // {}), (.projects[$cwd].mcpServers // {})] | add' || return 1
      if f=$(rdk_project_mcp_json); then rdk_json_launch_lines "$f" '(.mcpServers // {})'; fi
      ;;
    codex)
      rdk_toml_launch_lines "$(rdk_codex_config)"
      # In the home directory the "project" file is the user config itself.
      [ "$(rdk_codex_project_config)" -ef "$(rdk_codex_config)" ] || rdk_toml_launch_lines "$(rdk_codex_project_config)"
      ;;
    pi)
      rdk_json_launch_lines "$(rdk_pi_mcp_json)" '(.mcpServers // {})' || return 1
      rdk_json_launch_lines "$(rdk_pi_project_mcp_json)" '(.mcpServers // {})'
      ;;
    omp)
      rdk_json_launch_lines "$(rdk_omp_mcp_json)" '(.mcpServers // {})' || return 1
      rdk_json_launch_lines "$(rdk_omp_project_mcp_json)" '(.mcpServers // {})'
      ;;
    *) return 1 ;;
  esac
}

# rdk_mcp_where HARNESS NAME: print where the harness gets server NAME from; fails if it doesn't.
rdk_mcp_where() {
  local h=$1 n=$2 f
  case $h in
    claude)
      f=$(rdk_claude_json)
      if rdk_json_has_server "$f" '(.mcpServers // {})' "$n"; then
        rdk_tilde "$f"
      elif rdk_json_has_server "$f" '(.projects[$cwd].mcpServers // {})' "$n"; then
        printf '%s, local scope for this directory\n' "$(rdk_tilde "$f")"
      elif f=$(rdk_project_mcp_json) && rdk_json_has_server "$f" '(.mcpServers // {})' "$n"; then
        printf './.mcp.json, project scope\n'
      else
        return 1
      fi
      ;;
    codex)
      f=$(rdk_codex_config)
      if rdk_toml_has_server "$f" "$n"; then
        rdk_tilde "$f"
      elif rdk_toml_has_server "$(rdk_codex_project_config)" "$n"; then
        printf './.codex/config.toml, project scope (trusted projects only)\n'
      else
        return 1
      fi
      ;;
    pi)
      f=$(rdk_pi_mcp_json)
      if rdk_json_has_server "$f" '(.mcpServers // {})' "$n"; then
        rdk_tilde "$f"
      elif rdk_json_has_server "$(rdk_pi_project_mcp_json)" '(.mcpServers // {})' "$n"; then
        printf './.pi/mcp.json, project scope (trusted projects only)\n'
      else
        return 1
      fi
      ;;
    omp) rdk_omp_where "$n" ;;
    *) return 1 ;;
  esac
}

rdk_mcp_has() { rdk_mcp_where "$1" "$2" >/dev/null; }

# rdk_mcp_names_matching HARNESS ERE: names whose command/args match ERE.
rdk_mcp_names_matching() {
  rdk_mcp_launch_lines "$1" | awk -F '\t' -v re="$2" '$2 ~ re { print $1 }'
}

# --- Oh My Pi imports ----------------------------------------------------------
# OMP reads its own mcp.json first, then other tools' configs; across sources the first
# definition of a name wins. Project-level sources (<project>/.mcp.json, .codex/config.toml)
# load unless `mcp.enableProjectConfig: false`. Foreign user-level sources (~/.claude.json,
# ~/.codex/config.toml, Claude Code's plugins) load only when `enabledProviders` lists them
# (default []); `disabledProviders` wins; a set CLAUDE_CONFIG_DIR opts Claude Code in.

rdk_omp_config_yml() { printf '%s\n' "$RDK_HOME/.omp/agent/config.yml"; }

# rdk_omp_list_setting KEY: plain entries of a top-level YAML list (block or [inline]).
# Path-scoped entries ({path: ..., providers: [...]}) are not evaluated.
rdk_omp_list_setting() {
  local f
  f=$(rdk_omp_config_yml)
  [ -f "$f" ] || return 0
  awk -v key="$1" '
    function emit(v) { gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", v); if (v != "") print v }
    $0 ~ "^" key ":" {
      rest = $0
      sub("^" key ":[[:space:]]*", "", rest)
      sub(/[[:space:]]*#.*/, "", rest)
      if (rest ~ /^\[/) {
        gsub(/[][]/, "", rest)
        n = split(rest, parts, ",")
        for (i = 1; i <= n; i++) emit(parts[i])
        exit
      }
      in_list = 1
      next
    }
    in_list && /^[^[:space:]#-]/ { exit }
    in_list && /^[[:space:]]*-[[:space:]]*[^[:space:]:#]+[[:space:]]*(#.*)?$/ {
      v = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", v)
      sub(/[[:space:]]*#.*/, "", v)
      emit(v)
    }
  ' "$f"
}

# rdk_omp_user_source_enabled PROVIDER: true when OMP loads that foreign user-level source.
rdk_omp_user_source_enabled() {
  rdk_omp_list_setting disabledProviders | grep -Fxq -- "$1" && return 1
  if [ "$1" = claude ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then return 0; fi
  if [ "$1" = claude-plugins ]; then
    rdk_omp_list_setting disabledProviders | grep -Fxq claude && return 1
    rdk_omp_user_source_enabled claude && return 0
  fi
  rdk_omp_list_setting enabledProviders | grep -Exq -- "$1|\*|all"
}

rdk_omp_project_sources_enabled() {
  local f
  f=$(rdk_omp_config_yml)
  [ -f "$f" ] || return 0
  ! awk '
    /^mcp:/ { in_mcp = 1; next }
    in_mcp && /^[^[:space:]#]/ { in_mcp = 0 }
    in_mcp && /^[[:space:]]+enableProjectConfig:[[:space:]]*false/ { found = 1 }
    END { exit !found }
  ' "$f"
}

# rdk_omp_where NAME: OMP's source for server NAME, in OMP's precedence order.
rdk_omp_where() {
  local n=$1 f d
  d=$(rdk_project_dir)
  f=$(rdk_omp_mcp_json)
  if rdk_json_has_server "$f" '(.mcpServers // {})' "$n"; then
    rdk_tilde "$f"
    return 0
  fi
  if rdk_omp_project_sources_enabled; then
    for f in "$(rdk_omp_project_mcp_json)" "$(rdk_project_mcp_json || true)"; do
      [ -n "$f" ] || continue
      if rdk_json_has_server "$f" '(.mcpServers // {})' "$n"; then
        printf 'project file ./%s (imported by default)\n' "${f#"$d"/}"
        return 0
      fi
    done
    if rdk_toml_has_server "$(rdk_codex_project_config)" "$n"; then
      printf 'project file ./.codex/config.toml (imported by default)\n'
      return 0
    fi
  fi
  if rdk_omp_user_source_enabled claude; then
    f=$(rdk_claude_json)
    if rdk_json_has_server "$f" '[(.mcpServers // {}), (.projects[$cwd].mcpServers // {})] | add' "$n"; then
      printf 'imported from Claude Code (%s; enabledProviders)\n' "$(rdk_tilde "$f")"
      return 0
    fi
  fi
  if [ "$n" = "$RDK_BLENDER_SERVER" ] && rdk_omp_user_source_enabled claude-plugins && rdk_claude_plugin_enabled; then
    printf 'imported from the %s Claude Code plugin (enabledProviders)\n' "$RDK_PLUGIN_NAME"
    return 0
  fi
  if rdk_omp_user_source_enabled codex; then
    f=$(rdk_codex_config)
    if rdk_toml_has_server "$f" "$n"; then
      printf 'imported from Codex (%s; enabledProviders)\n' "$(rdk_tilde "$f")"
      return 0
    fi
  fi
  return 1
}

# rdk_claude_plugin_enabled: whether Claude Code enables the roblox plugin for the project.
# `claude plugin install --scope local|project|user` writes enabledPlugins "roblox@<marketplace>" to
# .claude/settings.local.json, .claude/settings.json or ~/.claude/settings.json; the most specific
# file that mentions the plugin decides, in that order (code.claude.com/docs/en/plugins/loading.md).
# The --settings flag, --add-dir and managed settings are not read.
rdk_claude_plugin_enabled() {
  local f d v
  d=$(rdk_project_dir)
  for f in "$d/.claude/settings.local.json" "$d/.claude/settings.json" "$(rdk_claude_dir)/settings.json"; do
    [ -f "$f" ] || continue
    if rdk_has_jq; then
      # "true", "false", or nothing when this file does not mention the plugin.
      v=$(jq -r --arg p "$RDK_PLUGIN_NAME@" \
        '[(.enabledPlugins // {}) | to_entries[] | select(.key | startswith($p)) | .value == true]
         | if length == 0 then empty elif any then "true" else "false" end' "$f" 2>/dev/null || true)
    elif grep -Eq "\"$RDK_PLUGIN_NAME@[^\"]+\"[[:space:]]*:[[:space:]]*true" "$f"; then
      v=true
    elif grep -Eq "\"$RDK_PLUGIN_NAME@[^\"]+\"[[:space:]]*:" "$f"; then
      v=false
    else
      v=''
    fi
    case $v in
      true) return 0 ;;
      false) return 1 ;;
    esac
  done
  return 1
}
