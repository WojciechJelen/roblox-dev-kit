#!/usr/bin/env bats
# mcp-config.sh: per-harness registration of Roblox_Studio and blender.

load helpers

setup() {
  setup_fake_machine
  MCP="$SETUP_SCRIPTS/mcp-config.sh"
  fake_studio
  fake_blender
  fake_cmd uvx 'exit 0'
  STUDIO="$RDK_STUDIO_APP/Contents/MacOS/StudioMCP"
  BLENDER="$RDK_BLENDER_APP/Contents/MacOS/Blender"
  SPEC="git+https://projects.blender.org/lab/blender_mcp.git@v1.0.3#subdirectory=mcp"
}

@test "claude --dry-run prints add-json commands at user scope" {
  fake_logging_cmd claude
  run bash "$MCP" --harness claude --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: would run: claude mcp add-json -s user Roblox_Studio '{\"type\":\"stdio\",\"command\":\"$STUDIO\",\"args\":[],\"env\":{}}'"* ]]
  [[ "$output" == *"claude: would run: claude mcp add-json -s user blender '{\"type\":\"stdio\",\"command\":\"$FAKE/bin/uvx\",\"args\":[\"--from\",\"$SPEC\",\"blender-mcp\"],\"env\":{\"BLENDER_PATH\":\"$BLENDER\"}}'"* ]]
  [ ! -e "$FAKE/calls.log" ]
}

@test "codex --dry-run prints codex mcp add with --env and the command after --" {
  fake_logging_cmd codex
  run bash "$MCP" --harness codex --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: would run: codex mcp add Roblox_Studio -- $STUDIO"* ]]
  [[ "$output" == *"codex: would run: codex mcp add blender --env BLENDER_PATH=$BLENDER -- $FAKE/bin/uvx --from '$SPEC' blender-mcp"* ]]
}

@test "pi --dry-run includes a description" {
  fake_logging_cmd pi
  run bash "$MCP" --harness pi --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi: would run: pi mcp add Roblox_Studio --description 'Roblox Studio'\\''s built-in MCP server"* ]]
  [[ "$output" == *"pi: would run: pi mcp add blender --description "*"--env BLENDER_PATH=$BLENDER -- $FAKE/bin/uvx --from '$SPEC' blender-mcp"* ]]
}

@test "omp --dry-run prints the JSON entries and writes nothing" {
  fake_logging_cmd omp
  run bash "$MCP" --harness omp --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"omp: would add to ~/.omp/agent/mcp.json: \"Roblox_Studio\": {\"type\":\"stdio\",\"command\":\"$STUDIO\"}"* ]]
  [[ "$output" == *"\"blender\": {\"type\":\"stdio\",\"command\":\"$FAKE/bin/uvx\",\"args\":[\"--from\",\"$SPEC\",\"blender-mcp\"],\"env\":{\"BLENDER_PATH\":\"$BLENDER\"}}"* ]]
  [ ! -e "$HOME/.omp/agent/mcp.json" ]
}

@test "servers already registered under the expected name are skipped" {
  fake_logging_cmd codex
  mkdir -p "$HOME/.codex"
  printf '[mcp_servers.Roblox_Studio]\ncommand = "%s"\n' "$STUDIO" >"$HOME/.codex/config.toml"
  run bash "$MCP" --harness codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"Roblox_Studio already registered"* ]]
  [ "$(wc -l <"$FAKE/calls.log" | tr -d ' ')" -eq 1 ]
  grep -q "^codex \[mcp\] \[add\] \[blender\] \[--env\] \[BLENDER_PATH=$BLENDER\] \[--\] \[$FAKE/bin/uvx\] \[--from\] \[$SPEC\] \[blender-mcp\]$" "$FAKE/calls.log"
}

@test "claude skips blender when the roblox plugin is enabled" {
  fake_logging_cmd claude
  mkdir -p "$HOME/.claude"
  echo '{"enabledPlugins":{"roblox@roblox-dev-kit":true}}' >"$HOME/.claude/settings.json"
  run bash "$MCP" --harness claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"blender is provided by the roblox plugin"* ]]
  grep -q '^claude \[mcp\] \[add-json\] \[-s\] \[user\] \[Roblox_Studio\]' "$FAKE/calls.log"
  run ! grep -q 'blender' "$FAKE/calls.log"
}

@test "omp: merges into an existing mcp.json, keeps other servers, and is idempotent" {
  fake_logging_cmd omp
  mkdir -p "$HOME/.omp/agent"
  echo '{"$schema":"s","mcpServers":{"linear":{"type":"http","url":"https://mcp.linear.app/mcp"}}}' >"$HOME/.omp/agent/mcp.json"
  run bash "$MCP" --harness omp
  [ "$status" -eq 0 ]
  f="$HOME/.omp/agent/mcp.json"
  [ "$(jq -r '.mcpServers | keys | join(",")' "$f")" = "Roblox_Studio,blender,linear" ]
  [ "$(jq -r '.mcpServers.linear.url' "$f")" = https://mcp.linear.app/mcp ]
  [ "$(jq -r '."$schema"' "$f")" = s ]
  [ "$(jq -r '.mcpServers.Roblox_Studio.command' "$f")" = "$STUDIO" ]
  [ "$(jq -r '.mcpServers.blender.env.BLENDER_PATH' "$f")" = "$BLENDER" ]
  [ "$(jq -r '.mcpServers.linear.url' "$f.bak")" = https://mcp.linear.app/mcp ]
  before=$(cat "$f")
  run bash "$MCP" --harness omp
  [ "$status" -eq 0 ]
  [ "$(cat "$f")" = "$before" ]
  [[ "$output" == *"Roblox_Studio already registered"* ]]
  [[ "$output" == *"blender already registered"* ]]
}

@test "omp: creates mcp.json with the schema when missing" {
  fake_logging_cmd omp
  run bash "$MCP" --harness omp --server blender
  [ "$status" -eq 0 ]
  f="$HOME/.omp/agent/mcp.json"
  jq -e '."$schema" | test("oh-my-pi")' "$f" >/dev/null
  [ "$(jq -r '.mcpServers | keys | join(",")' "$f")" = blender ]
}

@test "blender env is dropped when Blender is not installed" {
  fake_logging_cmd codex
  rm -rf "$RDK_BLENDER_APP"
  run bash "$MCP" --harness codex --server blender --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex mcp add blender -- $FAKE/bin/uvx --from"* ]]
}

@test "missing StudioMCP or uvx is an error but the other server is still handled" {
  fake_logging_cmd codex
  rm -rf "$RDK_STUDIO_APP"
  rm "$FAKE/bin/uvx"
  run bash "$MCP" --harness codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot register Roblox_Studio: StudioMCP not found"* ]]
  [[ "$output" == *"cannot register blender: uvx not found"* ]]
}

@test "all means every installed harness" {
  fake_logging_cmd codex
  fake_logging_cmd pi
  run bash "$MCP" --harness all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: would run"* ]]
  [[ "$output" == *"pi: would run"* ]]
  [[ "$output" != *"claude:"* ]]
  [[ "$output" != *"omp:"* ]]
}

@test "usage errors" {
  run bash "$MCP"
  [ "$status" -eq 2 ]
  run bash "$MCP" --harness vscode
  [ "$status" -eq 1 ]
  run bash "$MCP" --harness codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex is not installed"* ]]
  fake_logging_cmd codex
  run bash "$MCP" --harness codex --server nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown server: nope"* ]]
}

@test "after registering blender the server is fetched into uv's cache, once" {
  fake_logging_cmd codex
  fake_logging_cmd pi
  fake_logging_cmd uvx
  run bash "$MCP" --harness all
  [ "$status" -eq 0 ]
  [ "$(grep -c '^uvx ' "$FAKE/calls.log")" -eq 1 ]
  grep -qx "uvx \[--from\] \[$SPEC\] \[blender-mcp\] \[--help\]" "$FAKE/calls.log"
  [[ "$output" == *"Blender MCP server ready"* ]]
}

@test "--no-warm and --dry-run do not run uvx" {
  fake_logging_cmd codex
  fake_logging_cmd uvx
  run bash "$MCP" --harness codex --no-warm
  [ "$status" -eq 0 ]
  run ! grep -q '^uvx' "$FAKE/calls.log"
  rm -f "$FAKE/calls.log" "$HOME/.codex/config.toml"
  run bash "$MCP" --harness codex --dry-run
  [[ "$output" == *"would run: uvx --from '$SPEC' blender-mcp --help"* ]]
  [ ! -e "$FAKE/calls.log" ]
}

@test "claude: a server in the project's .mcp.json is not added again at user scope" {
  fake_logging_cmd claude
  mkdir -p "$FAKE/proj"
  cd "$FAKE/proj"
  echo '{"mcpServers":{"blender":{"command":"bash","args":["/k/mcp/blender-mcp.sh"]}}}' >.mcp.json
  run bash "$MCP" --harness claude --no-warm
  [ "$status" -eq 0 ]
  [[ "$output" == *"blender already registered (./.mcp.json, project scope), skipping"* ]]
  run ! grep -q 'blender' "$FAKE/calls.log"
}

@test "omp: servers it already imports via enabledProviders are skipped" {
  fake_logging_cmd omp
  mkdir -p "$HOME/.omp/agent"
  echo '{"mcpServers":{"Roblox_Studio":{"command":"/S/StudioMCP"}}}' >"$HOME/.claude.json"
  printf 'enabledProviders: [claude]\n' >"$HOME/.omp/agent/config.yml"
  run bash "$MCP" --harness omp --no-warm
  [ "$status" -eq 0 ]
  [[ "$output" == *"Roblox_Studio already registered (imported from Claude Code"* ]]
  [ "$(jq -r '.mcpServers | keys | join(",")' "$HOME/.omp/agent/mcp.json")" = blender ]
}

# --- --project: the project's own config files -------------------------------------------------

# fake_cwd_cmd NAME: NAME records "cwd: argv" (one line per call) in $FAKE/calls.log.
fake_cwd_cmd() {
  fake_cmd "$1" "{ printf '%s:' \"\$PWD\"; printf ' [%s]' \"\$@\"; echo; } >>\"$FAKE/calls.log\""
}

@test "--project claude: claude mcp add-json -s project, run in the project" {
  fake_cwd_cmd claude
  mkdir -p "$FAKE/game"
  run bash "$MCP" --harness claude --project "$FAKE/game" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: would run in $FAKE/game: claude mcp add-json -s project Roblox_Studio '{\"type\":\"stdio\",\"command\":\"$STUDIO\",\"args\":[],\"env\":{}}'"* ]]
  [ ! -e "$FAKE/calls.log" ]
  run bash "$MCP" --harness claude --project "$FAKE/game" --no-warm
  [ "$status" -eq 0 ]
  grep -qF "$FAKE/game: [mcp] [add-json] [-s] [project] [Roblox_Studio]" "$FAKE/calls.log"
  grep -qF "$FAKE/game: [mcp] [add-json] [-s] [project] [blender]" "$FAKE/calls.log"
  [[ "$output" == *"approve the servers from .mcp.json"* ]]
}

@test "--project claude: servers at user scope, in the project's .mcp.json or from a project-scope plugin are skipped" {
  fake_cwd_cmd claude
  mkdir -p "$FAKE/game/.claude"
  echo '{"mcpServers":{"Roblox_Studio":{"command":"/S/StudioMCP"}}}' >"$HOME/.claude.json"
  echo '{"enabledPlugins":{"roblox@roblox-dev-kit":true}}' >"$FAKE/game/.claude/settings.json"
  run bash "$MCP" --harness claude --project "$FAKE/game" --no-warm
  [ "$status" -eq 0 ]
  [[ "$output" == *"Roblox_Studio already registered (~/.claude.json)"* ]]
  [[ "$output" == *"blender is provided by the roblox plugin"* ]]
  [ ! -e "$FAKE/calls.log" ]
  rm "$FAKE/game/.claude/settings.json" "$HOME/.claude.json"
  echo '{"mcpServers":{"Roblox_Studio":{"command":"/S/StudioMCP"},"blender":{"command":"uvx"}}}' >"$FAKE/game/.mcp.json"
  run bash "$MCP" --harness claude --project "$FAKE/game" --no-warm
  [[ "$output" == *"Roblox_Studio already registered (./.mcp.json, project scope)"* ]]
  [ ! -e "$FAKE/calls.log" ]
}

@test "--project codex: writes .codex/config.toml tables, keeps what is there, and is idempotent" {
  fake_cwd_cmd codex
  mkdir -p "$FAKE/game/.codex"
  printf 'model = "o3"\n\n[mcp_servers.linear]\nurl = "https://mcp.linear.app/mcp"\n' >"$FAKE/game/.codex/config.toml"
  run bash "$MCP" --harness codex --project "$FAKE/game" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: would add to $FAKE/game/.codex/config.toml:"* ]]
  [[ "$output" == *"[mcp_servers.blender.env]"* ]]
  [ "$(grep -c mcp_servers "$FAKE/game/.codex/config.toml")" -eq 1 ]
  run bash "$MCP" --harness codex --project "$FAKE/game" --no-warm
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE/calls.log" ] # codex mcp add only writes the user config
  [ ! -e "$HOME/.codex/config.toml" ]
  run python3 -c 'import json, sys, tomllib
print(json.dumps(tomllib.load(open(sys.argv[1], "rb")), sort_keys=True))' "$FAKE/game/.codex/config.toml"
  [ "$status" -eq 0 ]
  [ "$(jq -r .model <<<"$output")" = o3 ]
  [ "$(jq -r '.mcp_servers | keys | join(",")' <<<"$output")" = "Roblox_Studio,blender,linear" ]
  [ "$(jq -r .mcp_servers.Roblox_Studio.command <<<"$output")" = "$STUDIO" ]
  [ "$(jq -c .mcp_servers.blender.args <<<"$output")" = "[\"--from\",\"$SPEC\",\"blender-mcp\"]" ]
  [ "$(jq -r .mcp_servers.blender.env.BLENDER_PATH <<<"$output")" = "$BLENDER" ]
  before=$(cat "$FAKE/game/.codex/config.toml")
  run bash "$MCP" --harness codex --project "$FAKE/game" --no-warm
  [[ "$output" == *"blender already registered (./.codex/config.toml, project scope (trusted projects only))"* ]]
  [ "$(cat "$FAKE/game/.codex/config.toml")" = "$before" ]
  [ ! -e "$FAKE/game/.codex/config.toml.bak" ]
}

@test "--project codex: a server in the user config is not added to the project" {
  mkdir -p "$HOME/.codex" "$FAKE/game"
  printf '[mcp_servers.Roblox_Studio]\ncommand = "%s"\n' "$STUDIO" >"$HOME/.codex/config.toml"
  fake_cwd_cmd codex
  run bash "$MCP" --harness codex --project "$FAKE/game" --no-warm
  [ "$status" -eq 0 ]
  [[ "$output" == *"Roblox_Studio already registered (~/.codex/config.toml)"* ]]
  run ! grep -q Roblox_Studio "$FAKE/game/.codex/config.toml"
  grep -q '^\[mcp_servers.blender\]$' "$FAKE/game/.codex/config.toml"
}

@test "--project pi: pi mcp add -l, run in the project; .pi/mcp.json entries count" {
  fake_cwd_cmd pi
  mkdir -p "$FAKE/game"
  run bash "$MCP" --harness pi --project "$FAKE/game" --no-warm
  [ "$status" -eq 0 ]
  grep -qF "$FAKE/game: [mcp] [add] [Roblox_Studio] [-l] [--description]" "$FAKE/calls.log"
  grep -qF "$FAKE/game: [mcp] [add] [blender] [-l] [--description]" "$FAKE/calls.log"
  grep -qF "[--env] [BLENDER_PATH=$BLENDER] [--] [$FAKE/bin/uvx] [--from] [$SPEC] [blender-mcp]" "$FAKE/calls.log"
  [[ "$output" == *"pi reads .pi/mcp.json only in trusted projects"* ]]
  rm "$FAKE/calls.log"
  mkdir -p "$FAKE/game/.pi"
  echo '{"mcpServers":{"Roblox_Studio":{"command":"/S/StudioMCP"},"blender":{"command":"uvx"}}}' >"$FAKE/game/.pi/mcp.json"
  run bash "$MCP" --harness pi --project "$FAKE/game" --no-warm
  [[ "$output" == *"blender already registered (./.pi/mcp.json, project scope (trusted projects only))"* ]]
  [ ! -e "$FAKE/calls.log" ]
}

@test "--project omp: writes .omp/mcp.json (no .bak), keeps other servers; imported project files count" {
  fake_logging_cmd omp
  mkdir -p "$FAKE/game/.omp"
  echo '{"mcpServers":{"linear":{"type":"http","url":"https://x"}}}' >"$FAKE/game/.omp/mcp.json"
  run bash "$MCP" --harness omp --project "$FAKE/game" --no-warm
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mcpServers | keys | join(",")' "$FAKE/game/.omp/mcp.json")" = "Roblox_Studio,blender,linear" ]
  [ ! -e "$FAKE/game/.omp/mcp.json.bak" ]
  [ ! -e "$HOME/.omp/agent/mcp.json" ]
  rm -r "$FAKE/game/.omp"
  echo '{"mcpServers":{"Roblox_Studio":{"command":"/S/StudioMCP"},"blender":{"command":"uvx"}}}' >"$FAKE/game/.mcp.json"
  run bash "$MCP" --harness omp --project "$FAKE/game" --no-warm
  [[ "$output" == *"Roblox_Studio already registered (project file ./.mcp.json (imported by default))"* ]]
  [ ! -e "$FAKE/game/.omp" ]
}

@test "--project --dry-run writes nothing, and the project must exist" {
  fake_cwd_cmd claude
  fake_cwd_cmd codex
  fake_cwd_cmd pi
  fake_logging_cmd omp
  mkdir -p "$FAKE/game"
  run bash "$MCP" --harness all --project "$FAKE/game" --dry-run
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FAKE/game")" ]
  [ ! -e "$FAKE/calls.log" ]
  run bash "$MCP" --harness codex --project "$FAKE/nope"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a directory"* ]]
}
