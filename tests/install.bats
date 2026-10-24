#!/usr/bin/env bats
# install/install.sh and install/uninstall.sh.

load helpers

setup() {
  setup_fake_machine
  INSTALL="$KIT_ROOT/install/install.sh"
  UNINSTALL="$KIT_ROOT/install/uninstall.sh"
  SKILLS=$(cd "$KIT_ROOT/skills" && for d in */SKILL.md; do printf '%s ' "${d%/SKILL.md}"; done)
}

@test "codex: links every skill into ~/.agents/skills" {
  fake_logging_cmd codex
  run bash "$INSTALL" --harness codex --no-mcp
  [ "$status" -eq 0 ]
  for s in $SKILLS; do
    [ -L "$HOME/.agents/skills/$s" ]
    [ "$(readlink "$HOME/.agents/skills/$s")" = "$KIT_ROOT/skills/$s" ]
  done
}

@test "re-running is idempotent" {
  fake_logging_cmd pi
  bash "$INSTALL" --harness pi --no-mcp
  run bash "$INSTALL" --harness pi --no-mcp
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok      ~/.agents/skills/roblox-setup"* ]]
}

@test "claude: links into ~/.claude/skills unless the plugin provides them" {
  fake_logging_cmd claude
  run bash "$INSTALL" --harness claude --no-mcp
  [ "$status" -eq 0 ]
  [ -L "$HOME/.claude/skills/roblox-doctor" ]
  rm -rf "$HOME/.claude/skills"
  echo '{"enabledPlugins":{"roblox@roblox-dev-kit":true}}' >"$HOME/.claude/settings.json"
  run bash "$INSTALL" --harness claude --no-mcp
  [[ "$output" == *"plugin is enabled"* ]]
  [ ! -e "$HOME/.claude/skills/roblox-doctor" ]
}

@test "--project installs into the project's skill folders" {
  fake_logging_cmd claude
  fake_logging_cmd omp
  mkdir -p "$FAKE/game"
  run bash "$INSTALL" --harness all --project "$FAKE/game" --no-mcp --no-plugin
  [ "$status" -eq 0 ]
  [ -L "$FAKE/game/.agents/skills/roblox-setup" ]
  [ -L "$FAKE/game/.claude/skills/roblox-setup" ]
  [ ! -e "$HOME/.agents" ]
  [ ! -e "$HOME/.claude/skills" ]
}

@test "--project: Claude Code gets the project-scope plugin commands (printed, not run) and only Studio's MCP server" {
  fake_studio
  fake_blender
  fake_cmd uvx 'exit 0'
  fake_cmd claude "{ printf '%s:' \"\$PWD\"; printf ' [%s]' \"\$@\"; echo; } >>\"$FAKE/calls.log\""
  mkdir -p "$FAKE/game"
  run bash "$INSTALL" --harness claude --project "$FAKE/game" --no-warm
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd $FAKE/game && claude plugin marketplace add $KIT_ROOT --scope project"* ]]
  [[ "$output" == *"cd $FAKE/game && claude plugin install roblox@roblox-dev-kit --scope project"* ]]
  [ ! -e "$FAKE/game/.claude/skills" ]
  run ! grep -q 'plugin' "$FAKE/calls.log" # printed only
  [ "$(wc -l <"$FAKE/calls.log" | tr -d ' ')" -eq 1 ]
  grep -qF "$FAKE/game: [mcp] [add-json] [-s] [project] [Roblox_Studio]" "$FAKE/calls.log"
}

@test "--project: an already enabled plugin is not offered again, and --no-plugin registers both servers" {
  fake_studio
  fake_blender
  fake_cmd uvx 'exit 0'
  fake_logging_cmd claude
  mkdir -p "$FAKE/game/.claude"
  echo '{"enabledPlugins":{"roblox@roblox-dev-kit":true}}' >"$FAKE/game/.claude/settings.json"
  run bash "$INSTALL" --harness claude --project "$FAKE/game" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin is enabled and already provides these skills"* ]]
  [[ "$output" != *"claude plugin install"* ]]
  [[ "$output" == *"claude mcp add-json -s project Roblox_Studio"* ]]
  [[ "$output" != *"add-json -s project blender"* ]]
  rm "$FAKE/game/.claude/settings.json"
  run bash "$INSTALL" --harness claude --project "$FAKE/game" --no-plugin --dry-run
  [[ "$output" == *"would link    $FAKE/game/.claude/skills/roblox-setup"* ]]
  [[ "$output" == *"claude mcp add-json -s project Roblox_Studio"* ]]
  [[ "$output" == *"claude mcp add-json -s project blender"* ]]
  [ ! -e "$FAKE/calls.log" ]
}

@test "--project registers MCP servers in the project's files for the other harnesses" {
  fake_studio
  fake_blender
  fake_cmd uvx 'exit 0'
  fake_logging_cmd codex
  fake_logging_cmd omp
  mkdir -p "$FAKE/game"
  run bash "$INSTALL" --harness all --project "$FAKE/game" --no-warm
  [ "$status" -eq 0 ]
  grep -q '^\[mcp_servers.Roblox_Studio\]$' "$FAKE/game/.codex/config.toml"
  # Oh My Pi imports the project's .codex/config.toml by default, so it needs no copy of its own.
  [[ "$output" == *"omp: Roblox_Studio already registered (project file ./.codex/config.toml (imported by default))"* ]]
  [ ! -e "$FAKE/game/.omp" ]
  [ ! -e "$HOME/.codex/config.toml" ]
  [ ! -e "$HOME/.omp/agent/mcp.json" ]
  [ ! -e "$FAKE/calls.log" ]
}

@test "--copy copies and marks the copy as ours" {
  fake_logging_cmd codex
  run bash "$INSTALL" --harness codex --copy --no-mcp
  [ "$status" -eq 0 ]
  d="$HOME/.agents/skills/roblox-doctor"
  [ -d "$d" ]
  [ ! -L "$d" ]
  [ -x "$d/scripts/doctor.sh" ]
  [ -f "$d/scripts/lib/common.sh" ]
  [ "$(cat "$d/.rdk-source")" = "$KIT_ROOT" ]
  bash "$d/scripts/doctor.sh" --section cloud >/dev/null
}

@test "never replaces skills that belong to someone else" {
  fake_logging_cmd codex
  mkdir -p "$HOME/.agents/skills/roblox-setup" "$FAKE/elsewhere"
  echo mine >"$HOME/.agents/skills/roblox-setup/SKILL.md"
  ln -s "$FAKE/elsewhere" "$HOME/.agents/skills/roblox-doctor"
  run bash "$INSTALL" --harness codex --no-mcp
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed by this kit; leaving it alone"* ]]
  [[ "$output" == *"links to $FAKE/elsewhere, not this kit"* ]]
  [ "$(cat "$HOME/.agents/skills/roblox-setup/SKILL.md")" = mine ]
  [ "$(readlink "$HOME/.agents/skills/roblox-doctor")" = "$FAKE/elsewhere" ]
}

@test "runs mcp-config.sh for each harness" {
  fake_logging_cmd codex
  fake_studio
  fake_cmd uvx 'exit 0'
  run bash "$INSTALL" --harness codex
  [ "$status" -eq 0 ]
  grep -q '^codex \[mcp\] \[add\] \[Roblox_Studio\]' "$FAKE/calls.log"
  grep -q '^codex \[mcp\] \[add\] \[blender\]' "$FAKE/calls.log"
}

@test "--dry-run changes nothing" {
  fake_logging_cmd codex
  fake_studio
  fake_cmd uvx 'exit 0'
  run bash "$INSTALL" --harness codex --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would link"* ]]
  [[ "$output" == *"codex: would run: codex mcp add"* ]]
  [ ! -e "$HOME/.agents" ]
  [ ! -e "$FAKE/calls.log" ]
}

@test "uninstall removes only this kit's links and copies" {
  fake_logging_cmd codex
  fake_logging_cmd claude
  bash "$INSTALL" --harness codex --no-mcp
  bash "$INSTALL" --harness claude --copy --no-mcp
  mkdir -p "$HOME/.agents/skills/other"
  ln -s "$FAKE" "$HOME/.agents/skills/foreign-link"
  run bash "$UNINSTALL" --harness all
  [ "$status" -eq 0 ]
  for s in $SKILLS; do
    [ ! -e "$HOME/.agents/skills/$s" ]
    [ ! -e "$HOME/.claude/skills/$s" ]
  done
  [ -d "$HOME/.agents/skills/other" ]
  [ -L "$HOME/.agents/skills/foreign-link" ]
  [[ "$output" == *"codex mcp remove blender"* ]]
}

@test "uninstall --dry-run keeps everything" {
  fake_logging_cmd codex
  bash "$INSTALL" --harness codex --no-mcp
  run bash "$UNINSTALL" --harness codex --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would be removed"* ]]
  [ -L "$HOME/.agents/skills/roblox-setup" ]
}

@test "usage errors" {
  run bash "$INSTALL"
  [ "$status" -eq 2 ]
  run bash "$INSTALL" --harness codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex is not installed"* ]]
  run bash "$INSTALL" --harness all
  [ "$status" -eq 1 ]
}
