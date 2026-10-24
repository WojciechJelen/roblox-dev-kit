#!/usr/bin/env bash
# Register the Roblox Studio and Blender MCP servers with a harness, using the harness's own CLI
# (claude, codex, pi) or, for Oh My Pi, its mcp.json. Idempotent: a server that is already
# registered under the expected name is left untouched.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SERVERS_JSON="$SCRIPT_DIR/../assets/mcp-servers.json"
OMP_SCHEMA="https://raw.githubusercontent.com/can1357/oh-my-pi/main/packages/coding-agent/src/config/mcp-schema.json"

usage() {
  cat <<EOF
usage: mcp-config.sh --harness claude|codex|pi|omp|all [--server NAME]... [--no-warm] [--dry-run]

Registers these MCP servers (user scope) unless already present:
  $RDK_STUDIO_SERVER  Roblox Studio's built-in server (the name Studio's Quick connect uses)
  $RDK_BLENDER_SERVER        official Blender MCP server $RDK_BLENDER_MCP_VERSION (skipped for Claude Code when the
                 $RDK_PLUGIN_NAME plugin is enabled, because the plugin bundles it)

  --harness  which harness to configure; 'all' means every installed one
  --server   only this server (repeatable)
  --no-warm  do not pre-download the Blender server into uv's cache (a cold first start takes
             ~45 s, longer than MCP clients wait)
  --dry-run  print the commands / JSON instead of applying them

A server counts as present when the harness already gets it from somewhere: for Claude Code also
the local scope and ./.mcp.json; for Oh My Pi also ./.mcp.json, ./.codex/config.toml and the
Claude Code / Codex user configs that its enabledProviders setting imports.
EOF
}

harness='' only='' dry_run=0 warm=1
while [ $# -gt 0 ]; do
  case $1 in
    --harness | --server)
      [ $# -ge 2 ] || rdk_die "$1 needs a value"
      if [ "$1" = --harness ]; then harness=$2; else only="$only $2"; fi
      shift
      ;;
    --dry-run) dry_run=1 ;;
    --no-warm) warm=0 ;;
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
[ -n "$harness" ] || {
  usage >&2
  exit 2
}
rdk_has jq || rdk_die "mcp-config.sh needs jq (macOS 15+ ships it; otherwise: brew install jq)"
[ -f "$SERVERS_JSON" ] || rdk_die "missing $SERVERS_JSON"

if [ "$harness" = all ]; then
  harnesses=''
  for h in $RDK_HARNESSES; do rdk_harness_installed "$h" && harnesses="$harnesses $h"; done
  [ -n "$harnesses" ] || rdk_die "none of these harnesses is installed: $RDK_HARNESSES"
else
  rdk_is_harness "$harness" || rdk_die "unknown harness: $harness (expected claude, codex, pi, omp or all)"
  rdk_harness_installed "$harness" || rdk_die "$harness is not installed (not found on PATH)"
  harnesses=$harness
fi

names=$(jq -r '.servers | keys_unsorted[]' "$SERVERS_JSON")
if [ -n "$only" ]; then
  for n in $only; do
    printf '%s\n' "$names" | grep -Fxq -- "$n" || rdk_die "unknown server: $n"
  done
  # shellcheck disable=SC2086  # split the space-separated list into lines
  names=$(printf '%s\n' $only)
fi

# resolve VALUE: expand a placeholder or bare command; fails when it cannot be resolved.
resolve() {
  case $1 in
    '{studio_mcp_bin}') rdk_find_studio_mcp ;;
    '{blender_bin}') rdk_find_blender ;;
    */*) printf '%s\n' "$1" ;;
    uvx) rdk_find_uvx ;;
    *) command -v "$1" 2>/dev/null ;;
  esac
}

failures=0
needs_warm=0

# register HARNESS NAME
register() {
  local h=$1 name=$2 where raw cmd desc arg key value entry
  local args=() env_flags=() env_json='{}'

  if where=$(rdk_mcp_where "$h" "$name"); then
    rdk_info "$h: $name already registered ($where), skipping"
    return 0
  fi
  if [ "$h" = claude ] && [ "$(jq -r --arg n "$name" '.servers[$n].claudePlugin' "$SERVERS_JSON")" = true ] &&
    rdk_claude_plugin_enabled; then
    rdk_info "$h: $name is provided by the $RDK_PLUGIN_NAME plugin, skipping"
    [ "$name" != "$RDK_BLENDER_SERVER" ] || needs_warm=1
    return 0
  fi

  raw=$(jq -r --arg n "$name" '.servers[$n].command' "$SERVERS_JSON")
  if ! cmd=$(resolve "$raw"); then
    case $raw in
      '{studio_mcp_bin}') rdk_err "$h: cannot register $name: StudioMCP not found (install or update Roblox Studio)" ;;
      uvx) rdk_err "$h: cannot register $name: uvx not found (macOS: brew install uv)" ;;
      *) rdk_err "$h: cannot register $name: $raw not found" ;;
    esac
    failures=$((failures + 1))
    return 0
  fi
  desc=$(jq -r --arg n "$name" '.servers[$n].description' "$SERVERS_JSON")
  while IFS= read -r arg; do
    args+=("$arg")
  done < <(jq -r --arg n "$name" '.servers[$n].args[]' "$SERVERS_JSON")
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] || continue
    case $value in
      '{'*'}') value=$(resolve "$value") || continue ;;
    esac
    env_flags+=(--env "$key=$value")
    env_json=$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$env_json")
  done < <(jq -r --arg n "$name" '.servers[$n].env | to_entries[] | "\(.key)\t\(.value)"' "$SERVERS_JSON")

  entry=$(jq -c --arg n "$name" --arg c "$cmd" --argjson env "$env_json" \
    '{type: "stdio", command: $c, args: .servers[$n].args, env: $env}' "$SERVERS_JSON")

  case $h in
    claude) apply "$h" "$name" claude mcp add-json -s user "$name" "$entry" ;;
    codex) apply "$h" "$name" codex mcp add "$name" ${env_flags[@]+"${env_flags[@]}"} -- "$cmd" ${args[@]+"${args[@]}"} ;;
    pi) apply "$h" "$name" pi mcp add "$name" --description "$desc" ${env_flags[@]+"${env_flags[@]}"} -- "$cmd" ${args[@]+"${args[@]}"} ;;
    omp) omp_write "$name" "$(jq -c 'if .env == {} then del(.env) else . end | if .args == [] then del(.args) else . end' <<<"$entry")" ;;
  esac
}

# apply HARNESS NAME CMD...: run (or print) one harness CLI call.
apply() {
  local h=$1 name=$2
  shift 2
  if [ $dry_run = 1 ]; then
    rdk_info "$h: would run: $(rdk_quote "$@")"
    [ "$name" != "$RDK_BLENDER_SERVER" ] || needs_warm=1
    return 0
  fi
  rdk_info "$h: + $(rdk_quote "$@")"
  if "$@" >&2; then
    rdk_info "$h: registered $name"
    [ "$name" != "$RDK_BLENDER_SERVER" ] || needs_warm=1
  else
    rdk_err "$h: registering $name failed"
    failures=$((failures + 1))
  fi
}

# Oh My Pi has no `mcp add` CLI; merge the entry into its user mcp.json, keeping everything else.
omp_write() {
  local name=$1 entry=$2 f
  f=$(rdk_omp_mcp_json)
  if [ $dry_run = 1 ]; then
    rdk_info "omp: would add to $(rdk_tilde "$f"): \"$name\": $entry"
    [ "$name" != "$RDK_BLENDER_SERVER" ] || needs_warm=1
    return 0
  fi
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    cp "$f" "$f.bak"
  else
    jq -n --arg s "$OMP_SCHEMA" '{"$schema": $s, mcpServers: {}}' >"$f"
  fi
  jq --arg n "$name" --argjson e "$entry" '.mcpServers = ((.mcpServers // {}) + {($n): $e})' "$f" >"$f.tmp"
  mv "$f.tmp" "$f"
  rdk_info "omp: registered $name in $(rdk_tilde "$f")"
  [ "$name" != "$RDK_BLENDER_SERVER" ] || needs_warm=1
}

for h in $harnesses; do
  for name in $names; do
    register "$h" "$name"
  done
  if [ $dry_run = 0 ]; then
    case $h in
      claude) rdk_info "claude: restart Claude Code (or run /mcp) to load new servers" ;;
      codex) rdk_info "codex: new servers load in the next Codex session" ;;
      pi) rdk_info "pi: run /reload (or restart pi) to load new servers" ;;
      omp) rdk_info "omp: run /mcp reload (or restart omp) to load new servers" ;;
    esac
  fi
done

if [ $needs_warm = 1 ] && [ $warm = 1 ]; then
  if [ $dry_run = 1 ]; then
    rdk_info "would run: uvx --from '$RDK_BLENDER_MCP_SPEC' blender-mcp --help (prepares uv's cache)"
  else
    rdk_warm_blender_server || true
  fi
fi

[ $failures -eq 0 ] || exit 1
