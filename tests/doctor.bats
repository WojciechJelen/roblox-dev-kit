#!/usr/bin/env bats
# roblox-doctor: table and JSON output, exit codes, and each section on fake machines.

load helpers

setup() {
  setup_fake_machine
}

doctor_json() {
  run --separate-stderr bash "$DOCTOR" --json "$@"
}

# A machine where everything the doctor checks is in place.
green_machine() {
  fake_full_toolchain
  fake_cmd uvx 'exit 0'
  fake_studio
  mkdir -p "$HOME/Documents/Roblox/Plugins"
  : >"$HOME/Documents/Roblox/Plugins/RojoManagedPlugin.rbxm"
  fake_blender
  ln -s "$RDK_BLENDER_APP/Contents/MacOS/Blender" "$FAKE/bin/blender"
  install_fake_addon
  fake_logging_cmd claude
  fake_logging_cmd codex
  echo '{"mcpServers":{"Roblox_Studio":{"command":"/S/StudioMCP"},"blender":{"command":"/x/uvx","args":["--from","git+https://projects.blender.org/lab/blender_mcp.git@v1.0.3#subdirectory=mcp","blender-mcp"]}}}' >"$HOME/.claude.json"
  mkdir -p "$HOME/.codex"
  printf '[mcp_servers.Roblox_Studio]\ncommand = "/S/StudioMCP"\n[mcp_servers.blender]\ncommand = "uvx"\n' >"$HOME/.codex/config.toml"
  export ROBLOX_API_KEY=secret-key-value ROBLOX_CREATOR_TYPE=User ROBLOX_CREATOR_ID=42
  scaffold_project "$FAKE/game"
  git -C "$FAKE/game" init -q
  touch "$FAKE/game/sourcemap.json"
  cd "$FAKE/game"
}

@test "an empty machine fails with exit 1 and actionable fixes" {
  doctor_json
  [ "$status" -eq 1 ]
  [ "$(status_of toolchain.rokit)" = fail ]
  [ "$(status_of toolchain.rokit-path)" = warn ]
  [ "$(status_of toolchain.tool.rojo)" = fail ]
  [ "$(status_of project.detect)" = skip ]
  [ "$(status_of studio.app)" = fail ]
  [ "$(status_of studio.mcp-binary)" = fail ]
  [ "$(status_of blender.binary)" = fail ]
  [ "$(status_of mcp.claude)" = skip ]
  [ "$(status_of mcp.omp)" = skip ]
  [ "$(status_of cloud.api-key)" = warn ]
  printf '%s' "$output" | jq -e '.checks | map(select(.status == "fail")) | all(.fix != "")' >/dev/null
}

@test "a fully set-up machine and project pass with exit 0" {
  green_machine
  doctor_json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.summary.fail == 0' >/dev/null
  [ "$(status_of toolchain.tool.luau-lsp)" = ok ]
  [ "$(status_of project.detect)" = ok ]
  [ "$(status_of project.sourcemap)" = ok ]
  [ "$(status_of studio.rojo-plugin)" = ok ]
  [ "$(status_of blender.addon)" = ok ]
  [ "$(status_of mcp.claude.blender)" = ok ]
  [ "$(status_of mcp.codex.studio)" = ok ]
  [ "$(status_of mcp.pi)" = skip ]
  [ "$(status_of cloud.creator)" = ok ]
}

@test "JSON has the documented schema and consistent summary" {
  green_machine
  doctor_json
  printf '%s' "$output" | jq -e '
    (keys == ["checks", "summary"])
    and (.checks | all(keys == ["detail", "fix", "id", "section", "status"]))
    and (.checks | all(.status | IN("ok", "warn", "fail", "skip")))
    and (.checks | all(.section == (.id | split(".")[0])))
    and (.summary == (reduce .checks[] as $c ({ok: 0, warn: 0, fail: 0, skip: 0}; .[$c.status] += 1)))' >/dev/null
}

@test "JSON without jq matches JSON built with jq" {
  green_machine
  doctor_json --section toolchain,project,studio,blender,cloud
  with_jq=$(printf '%s' "$output" | jq -S .)
  RDK_NO_JQ=1 doctor_json --section toolchain,project,studio,blender,cloud
  [ "$status" -eq 0 ]
  without_jq=$(printf '%s' "$output" | jq -S .)
  [ "$with_jq" = "$without_jq" ]
}

@test "the API key is never printed" {
  green_machine
  run bash "$DOCTOR" --section cloud
  [[ "$output" != *secret-key-value* ]]
  doctor_json --section cloud
  [[ "$output" != *secret-key-value* ]]
  [ "$(detail_of cloud.api-key)" = "ROBLOX_API_KEY is set (value hidden)" ]
}

@test "table output groups sections, shows symbols and fixes" {
  fake_studio
  run bash "$DOCTOR"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'\ntoolchain\n'* ]]
  [[ "$output" == *"✗ rokit"* ]]
  [[ "$output" == *"✓ mcp-binary"* ]]
  [[ "$output" == *"! rokit-path"* ]]
  [[ "$output" == *"- detect"* ]]
  [[ "$output" == *"fix: roblox-setup: scripts/install-toolchain.sh"* ]]
  [[ "$output" =~ [0-9]+\ ok,\ [0-9]+\ warn,\ [0-9]+\ fail,\ [0-9]+\ skip ]]
}

@test "--quiet hides passing checks" {
  fake_studio
  run bash "$DOCTOR" --quiet
  [[ "$output" != *"✓ mcp-binary"* ]]
  [[ "$output" == *"✗ rokit"* ]]
}

@test "usage errors exit 2" {
  run bash "$DOCTOR" --bogus
  [ "$status" -eq 2 ]
  run bash "$DOCTOR" --section nope
  [ "$status" -eq 2 ]
  run bash "$DOCTOR" --project /does/not/exist
  [ "$status" -eq 2 ]
  run bash "$DOCTOR" --section
  [ "$status" -eq 2 ]
}

@test "--section limits the run" {
  doctor_json --section cloud
  [ "$(printf '%s' "$output" | jq -r '[.checks[].section] | unique | join(",")')" = cloud ]
  doctor_json --section=studio,cloud
  [ "$(printf '%s' "$output" | jq -r '[.checks[].section] | unique | join(",")')" = cloud,studio ]
}

@test "toolchain: rokit present but not on PATH, and a pinned version mismatch" {
  fake_tool rokit "rokit 1.2.0"
  doctor_json --section toolchain
  [ "$(status_of toolchain.rokit)" = fail ]
  [[ "$(detail_of toolchain.rokit)" == *"not on PATH"* ]]

  fake_full_toolchain
  fake_tool rojo "Rojo 7.6.0"
  scaffold_project "$FAKE/game"
  doctor_json --section toolchain --project "$FAKE/game"
  [ "$(status_of toolchain.rokit)" = ok ]
  [ "$(status_of toolchain.tool.rojo)" = warn ]
  [[ "$(detail_of toolchain.tool.rojo)" == *"pins 7.7.1"* ]]
  [ "$status" -eq 0 ]
}

@test "toolchain: a tool pinned in rokit.toml but not installed fails with rokit install" {
  fake_tool rokit "rokit 1.2.0"
  export PATH="$FAKE/home/.rokit/bin:$PATH"
  scaffold_project "$FAKE/game"
  doctor_json --section toolchain --project "$FAKE/game"
  [ "$(status_of toolchain.tool.zap)" = fail ]
  [ "$(printf '%s' "$output" | jq -r '.checks[] | select(.id == "toolchain.tool.zap") | .fix')" = "rokit install" ]
}

@test "project: missing configs, missing packages and a stale sourcemap warn" {
  scaffold_project "$FAKE/game"
  rm "$FAKE/game/selene.toml"
  printf '\n[dependencies]\nCharm = "littensy/charm@0.11.1"\n' >>"$FAKE/game/wally.toml"
  touch "$FAKE/game/sourcemap.json"
  touch -t 203001010000 "$FAKE/game/src/ReplicatedStorage/Shared/Example.luau"
  mkdir -p "$FAKE/game/src/deep"
  cd "$FAKE/game/src/deep"
  doctor_json --section project
  [ "$(status_of project.detect)" = ok ]
  [ "$(status_of project.file.selene.toml)" = warn ]
  [ "$(status_of project.file.rokit.toml)" = ok ]
  [ "$(status_of project.packages)" = warn ]
  [ "$(status_of project.sourcemap)" = warn ]
  [ "$(status_of project.git)" = warn ]
  [ "$status" -eq 0 ]
}

@test "project: wally.toml without dependencies needs no Packages" {
  scaffold_project "$FAKE/game"
  doctor_json --section project --project "$FAKE/game"
  [ "$(status_of project.packages)" = ok ]
  [ "$(status_of project.sourcemap)" = warn ]
}

@test "studio: Linux skips the Studio checks" {
  RDK_OS=linux doctor_json --section studio
  [ "$status" -eq 0 ]
  [ "$(status_of studio.app)" = skip ]
}

@test "blender: too old, wrong add-on version, community add-on" {
  fake_blender 5.0.1
  doctor_json --section blender
  [ "$(status_of blender.version)" = fail ]
  [ "$(status_of blender.path)" = fail ]

  fake_blender 5.2.1
  install_fake_addon 1.0.2
  doctor_json --section blender
  [ "$(status_of blender.version)" = ok ]
  [ "$(status_of blender.addon)" = warn ]

  addons="$FAKE/home/Library/Application Support/Blender/5.2/scripts/addons"
  mkdir -p "$addons"
  echo 'scene.blendermcp_port = 9876' >"$addons/addon.py"
  doctor_json --section blender
  [ "$(status_of blender.community-addon)" = warn ]
  [ "$(status_of blender.port)" = warn ]
  [ "$(status_of blender.server)" = skip ]
}

@test "blender: the port check passes while something listens" {
  [ -n "$REAL_PYTHON" ] || skip "python3 needed for the listener"
  fake_blender
  listen_on_free_port
  RDK_BLENDER_MCP_PORT=$LISTEN_PORT doctor_json --section blender
  kill "$LISTEN_PID"
  [ "$(status_of blender.port)" = ok ]
}

@test "blender: --online asks uvx for the pinned server" {
  fake_blender
  fake_cmd uvx 'echo "$*" >"'"$FAKE"'/uvx.args"; exit 0'
  doctor_json --section blender --online
  [ "$(status_of blender.server)" = ok ]
  grep -q 'blender_mcp.git@v1.0.3#subdirectory=mcp blender-mcp --help' "$FAKE/uvx.args"
  fake_cmd uvx 'exit 1'
  RDK_NETWORK_TESTS=1 doctor_json --section blender
  [ "$(status_of blender.server)" = fail ]
}

@test "mcp: registered harnesses pass, missing entries fail, absent harnesses skip" {
  fake_logging_cmd pi
  fake_logging_cmd omp
  mkdir -p "$HOME/.pi/agent" "$HOME/.omp/agent"
  echo '{"mcpServers":{"Roblox_Studio":{"command":"/S/StudioMCP"},"blender":{"command":"uvx"}}}' >"$HOME/.pi/agent/mcp.json"
  echo '{"mcpServers":{"linear":{"type":"http","url":"https://x"}}}' >"$HOME/.omp/agent/mcp.json"
  doctor_json --section mcp
  [ "$status" -eq 1 ]
  [ "$(status_of mcp.pi.studio)" = ok ]
  [ "$(status_of mcp.pi.blender)" = ok ]
  [ "$(status_of mcp.omp.studio)" = fail ]
  [ "$(status_of mcp.omp.blender)" = fail ]
  [ "$(status_of mcp.claude)" = skip ]
  [ "$(status_of mcp.codex)" = skip ]
}

@test "mcp: the roblox plugin provides Blender for Claude Code; a second copy is a duplicate" {
  fake_logging_cmd claude
  mkdir -p "$HOME/.claude"
  echo '{"enabledPlugins":{"roblox@roblox-dev-kit":true}}' >"$HOME/.claude/settings.json"
  echo '{"mcpServers":{"Roblox_Studio":{"command":"/S/StudioMCP"}}}' >"$HOME/.claude.json"
  doctor_json --section mcp
  [ "$status" -eq 0 ]
  [[ "$(detail_of mcp.claude.blender)" == *"roblox plugin"* ]]
  [ "$(status_of mcp.claude.duplicates)" = ok ]

  echo '{"mcpServers":{"Roblox_Studio":{"command":"/S/StudioMCP"},"blender":{"command":"/k/mcp/blender-mcp.sh"}}}' >"$HOME/.claude.json"
  doctor_json --section mcp
  [ "$(status_of mcp.claude.duplicates)" = warn ]
}

@test "mcp: Studio registered twice under different names is a duplicate" {
  fake_logging_cmd codex
  mkdir -p "$HOME/.codex"
  printf '[mcp_servers.Roblox_Studio]\ncommand = "/A/StudioMCP"\n[mcp_servers.roblox-studio]\ncommand = "/A/StudioMCP"\n' >"$HOME/.codex/config.toml"
  doctor_json --section mcp
  [ "$(status_of mcp.codex.duplicates)" = warn ]
  [[ "$(detail_of mcp.codex.duplicates)" == *"Roblox_Studio roblox-studio"* ]]
}

@test "--fix creates the blender symlink and re-checks" {
  fake_blender
  install_fake_addon
  export PATH="$RDK_LOCAL_BIN:$PATH"
  doctor_json --section blender
  [ "$(status_of blender.path)" = fail ]
  doctor_json --section blender --fix
  [ -L "$RDK_LOCAL_BIN/blender" ]
  [ "$(readlink "$RDK_LOCAL_BIN/blender")" = "$RDK_BLENDER_APP/Contents/MacOS/Blender" ]
  [ "$(status_of blender.path)" = ok ]
  [ "$status" -eq 0 ]
}

@test "--fix regenerates the sourcemap with rojo and leaves other files alone" {
  scaffold_project "$FAKE/game"
  fake_cmd rojo '[ "$1" = sourcemap ] && echo "{}" >sourcemap.json; exit 0'
  doctor_json --section project --project "$FAKE/game" --fix
  [ -f "$FAKE/game/sourcemap.json" ]
  [ "$(status_of project.sourcemap)" = ok ]
  [ ! -e "$HOME/.zshrc" ]
}

@test "--fix skips fixes whose tool is missing" {
  scaffold_project "$FAKE/game"
  doctor_json --section project --project "$FAKE/game" --fix
  [ "$(status_of project.sourcemap)" = warn ]
  [[ "$stderr" == *"rojo is not on PATH"* ]]
}
