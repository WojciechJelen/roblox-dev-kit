#!/usr/bin/env bats
# lib/common.sh helpers and the files that must agree with it.

load helpers

setup() {
  setup_fake_machine
  # shellcheck source=../lib/common.sh
  source "$KIT_ROOT/lib/common.sh"
}

@test "rdk_version_ge compares dotted versions numerically" {
  rdk_version_ge 5.2.1 5.1
  rdk_version_ge 5.1 5.1.0
  rdk_version_ge 10.0 9.9
  rdk_version_ge 5.10 5.9
  run ! rdk_version_ge 5.0.9 5.1
  run ! rdk_version_ge 4.5 5.1
}

@test "rdk_json_escape produces valid JSON strings" {
  s=$(rdk_json_escape $'quote " backslash \\ tab \t newline \n bell \a end')
  run jq -r . <<<"\"$s\""
  [ "$status" -eq 0 ]
  [ "$output" = $'quote " backslash \\ tab \t newline \n bell  end' ]
}

@test "rdk_quote output survives a round trip through the shell" {
  line=$(rdk_quote cmd "a b" "it's" '' 'x=$HOME' '{"k":"v"}' --flag)
  eval "set -- $line"
  [ "$#" -eq 7 ]
  [ "$2" = "a b" ]
  [ "$3" = "it's" ]
  [ "$4" = "" ]
  [ "$5" = 'x=$HOME' ]
  [ "$6" = '{"k":"v"}' ]
}

@test "rdk_os honours RDK_OS" {
  RDK_OS=linux
  [ "$(rdk_os)" = linux ]
}

@test "rdk_path_line uses \$HOME and never touches rc files" {
  [ "$(rdk_path_line "$RDK_HOME/.rokit/bin")" = 'export PATH="$HOME/.rokit/bin:$PATH"' ]
  [ "$(rdk_path_line /opt/tools)" = 'export PATH="/opt/tools:$PATH"' ]
  [ ! -e "$HOME/.zshrc" ]
  [ ! -e "$HOME/.bashrc" ]
}

@test "rdk_package_name makes Wally-safe names" {
  [ "$(rdk_package_name "Motor Rivals")" = motor-rivals ]
  [ "$(rdk_package_name "My_Game 2")" = my-game-2 ]
  [ "$(rdk_package_name "--Odd  Name--")" = odd-name ]
}

@test "rdk_check_project_name rejects characters that would need escaping" {
  run rdk_check_project_name 'bad/name'
  [ "$status" -ne 0 ]
  run rdk_check_project_name '&evil'
  [ "$status" -ne 0 ]
  run rdk_check_project_name 'Good Name_1-2'
  [ "$status" -eq 0 ]
}

@test "Blender paths follow Blender's own overrides" {
  [ "$(rdk_blender_series 5.2.1)" = 5.2 ]
  [ "$(rdk_blender_ext_dir 5.2)" = "$RDK_HOME/Library/Application Support/Blender/5.2/extensions" ]
  [ "$(rdk_blender_addon_dir 5.2)" = "$RDK_HOME/Library/Application Support/Blender/5.2/extensions/user_default/mcp" ]
  BLENDER_USER_RESOURCES=/r
  [ "$(rdk_blender_ext_dir 5.2)" = /r/extensions ]
  BLENDER_USER_EXTENSIONS=/e
  [ "$(rdk_blender_ext_dir 5.2)" = /e ]
  RDK_OS=linux
  unset BLENDER_USER_RESOURCES BLENDER_USER_EXTENSIONS
  [ "$(rdk_blender_ext_dir 5.2)" = "$RDK_HOME/.config/blender/5.2/extensions" ]
}

@test "rdk_find_blender prefers RDK_BLENDER_BIN, then PATH, then the app bundle" {
  run rdk_find_blender
  [ "$status" -ne 0 ]
  fake_blender
  [ "$(rdk_find_blender)" = "$RDK_BLENDER_APP/Contents/MacOS/Blender" ]
  [ "$(rdk_blender_version "$(rdk_find_blender)")" = 5.2.1 ]
  fake_cmd blender 'echo "Blender 5.1.0"'
  [ "$(rdk_find_blender)" = "$FAKE/bin/blender" ]
  RDK_BLENDER_BIN="$RDK_BLENDER_APP/Contents/MacOS/Blender"
  [ "$(rdk_find_blender)" = "$RDK_BLENDER_BIN" ]
}

@test "rdk_find_studio_mcp finds StudioMCP in the app bundle" {
  run rdk_find_studio_mcp
  [ "$status" -ne 0 ]
  fake_studio
  [ "$(rdk_find_studio_mcp)" = "$RDK_STUDIO_APP/Contents/MacOS/StudioMCP" ]
  RDK_OS=linux
  run rdk_find_studio_mcp
  [ "$status" -ne 0 ]
}

@test "harness config paths honour CLAUDE_CONFIG_DIR and CODEX_HOME" {
  [ "$(rdk_claude_json)" = "$RDK_HOME/.claude.json" ]
  [ "$(rdk_codex_config)" = "$RDK_HOME/.codex/config.toml" ]
  [ "$(rdk_harness_skills_dir codex)" = "$RDK_HOME/.agents/skills" ]
  [ "$(rdk_harness_skills_dir claude)" = "$RDK_HOME/.claude/skills" ]
  CLAUDE_CONFIG_DIR=/c CODEX_HOME=/x
  [ "$(rdk_claude_json)" = /c/.claude.json ]
  [ "$(rdk_codex_config)" = /x/config.toml ]
}

@test "codex TOML parsing maps subsections to their server" {
  mkdir -p "$HOME/.codex"
  cat >"$HOME/.codex/config.toml" <<'EOF'
model = "x"
[mcp_servers.chrome-devtools]
command = "npx"
args = ["chrome-devtools-mcp@latest"]
[mcp_servers.chrome-devtools.tools.click]
approval_mode = "approve"
[mcp_servers.Roblox_Studio]
command = "/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP"
[mcp_servers."blender"]
command = "uvx"
[mcp_servers.blender.env]
BLENDER_PATH = "/b"
[profiles.default]
command = "not-a-server"
EOF
  run rdk_mcp_launch_lines codex
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | tr '\n' ' ')" = "chrome-devtools Roblox_Studio blender " ]
  rdk_mcp_has codex Roblox_Studio
  rdk_mcp_has codex blender
  run ! rdk_mcp_has codex profiles
  [ "$(rdk_mcp_names_matching codex StudioMCP)" = Roblox_Studio ]
}

@test "JSON MCP configs are read with and without jq" {
  mkdir -p "$HOME/.pi/agent"
  echo '{"mcpServers":{"Roblox_Studio":{"command":"/S/StudioMCP"}}}' >"$HOME/.pi/agent/mcp.json"
  rdk_mcp_has pi Roblox_Studio
  run ! rdk_mcp_has pi blender
  RDK_NO_JQ=1
  rdk_mcp_has pi Roblox_Studio
  run ! rdk_mcp_has pi blender
}

@test "Claude plugin detection reads enabledPlugins" {
  run ! rdk_claude_plugin_enabled
  mkdir -p "$HOME/.claude"
  echo '{"enabledPlugins":{"roblox@roblox-dev-kit":false}}' >"$HOME/.claude/settings.json"
  run ! rdk_claude_plugin_enabled
  echo '{"enabledPlugins":{"roblox@roblox-dev-kit":true}}' >"$HOME/.claude/settings.json"
  rdk_claude_plugin_enabled
  RDK_NO_JQ=1
  rdk_claude_plugin_enabled
}

@test "rdk_port_open tells open from closed ports" {
  [ -n "$REAL_PYTHON" ] || skip "python3 needed for the listener"
  run ! rdk_port_open localhost 1
  listen_on_free_port
  rdk_port_open localhost "$LISTEN_PORT"
  kill "$LISTEN_PID"
}

@test "vendored lib copies match lib/common.sh (make check-sync)" {
  run make -C "$KIT_ROOT" --no-print-directory check-sync
  [ "$status" -eq 0 ]
  for copy in "$KIT_ROOT"/skills/*/scripts/lib/common.sh; do
    sed -n 2p "$copy" | grep -q 'vendored from /lib/common.sh'
  done
}

@test "pinned Blender MCP version agrees everywhere" {
  v=$RDK_BLENDER_MCP_VERSION
  jq -e --arg v "$v" '.servers.blender.args | index("git+https://projects.blender.org/lab/blender_mcp.git@v" + $v + "#subdirectory=mcp")' \
    "$KIT_ROOT/mcp/servers.json" >/dev/null
  grep -q "v$v" <<<"$RDK_BLENDER_MCP_SPEC"
  jq -e '.mcpServers.blender.command == "${CLAUDE_PLUGIN_ROOT}/mcp/blender-mcp.sh"' "$KIT_ROOT/.mcp.json" >/dev/null
  # The plugin bundles only Blender; Studio is registered per harness (see PLAN §5).
  [ "$(jq '.mcpServers | length' "$KIT_ROOT/.mcp.json")" -eq 1 ]
}

@test "plugin, marketplace, lib and skills carry the same version" {
  v=$(jq -r .version "$KIT_ROOT/.claude-plugin/plugin.json")
  [ "$(jq -r '.plugins[] | select(.name == "roblox") | .version' "$KIT_ROOT/.claude-plugin/marketplace.json")" = "$v" ]
  [ "$RDK_KIT_VERSION" = "$v" ]
  for f in "$KIT_ROOT"/skills/*/SKILL.md; do
    grep -q "^  version: \"$v\"" "$f"
  done
}

@test "mcp wrappers exec the located binaries" {
  fake_studio
  run "$KIT_ROOT/mcp/studio-mcp.sh" --probe
  [ "$status" -eq 0 ]
  [ "$output" = "studio-mcp --probe" ]

  fake_blender
  fake_cmd uvx 'echo "uvx $* BLENDER_PATH=$BLENDER_PATH BLENDER_MCP_PORT=$BLENDER_MCP_PORT"'
  RDK_BLENDER_MCP_PORT=9876 run "$KIT_ROOT/mcp/blender-mcp.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "uvx --from $RDK_BLENDER_MCP_SPEC blender-mcp BLENDER_PATH=$RDK_BLENDER_APP/Contents/MacOS/Blender BLENDER_MCP_PORT=9876" ]
}

@test "studio wrapper explains a missing Studio" {
  run "$KIT_ROOT/mcp/studio-mcp.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"StudioMCP not found"* ]]
}
