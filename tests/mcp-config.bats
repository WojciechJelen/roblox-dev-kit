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
