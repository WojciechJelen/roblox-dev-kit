#!/usr/bin/env bats
# scaffold.sh: new projects from assets/template.

load helpers

setup() {
  setup_fake_machine
  SCAFFOLD="$SETUP_SCRIPTS/scaffold.sh"
}

@test "creates a complete project with every placeholder replaced" {
  run bash "$SCAFFOLD" "$FAKE/game" "Motor Rivals"
  [ "$status" -eq 0 ]
  for f in default.project.json rokit.toml wally.toml selene.toml stylua.toml .luaurc .gitignore \
    AGENTS.md CLAUDE.md .vscode/settings.json .vscode/extensions.json .github/workflows/ci.yml \
    src/ServerScriptService/Server.server.luau src/StarterPlayerScripts/Client.client.luau \
    src/ReplicatedStorage/Shared/Example.luau src/ServerScriptService/Services/ExampleService.luau \
    src/StarterPlayerScripts/Controllers/ExampleController.luau; do
    [ -f "$FAKE/game/$f" ] || { echo "missing $f"; return 1; }
  done
  run grep -rEl '\{\{[A-Z_]+\}\}' "$FAKE/game"
  [ "$status" -eq 1 ]
  [ "$(jq -r .name "$FAKE/game/default.project.json")" = "Motor Rivals" ]
  grep -q '^name = "local/motor-rivals"$' "$FAKE/game/wally.toml"
  grep -q '^# Motor Rivals: instructions for coding agents' "$FAKE/game/AGENTS.md"
  [ "$(cat "$FAKE/game/CLAUDE.md")" = "@AGENTS.md" ]
}

@test "the project file maps the template folders and keeps packages optional" {
  bash "$SCAFFOLD" "$FAKE/game" "Game" --no-git
  p="$FAKE/game/default.project.json"
  [ "$(jq -r '.tree.ServerScriptService."$path"' "$p")" = src/ServerScriptService ]
  [ "$(jq -r '.tree.StarterPlayer.StarterPlayerScripts."$path"' "$p")" = src/StarterPlayerScripts ]
  [ "$(jq -r '.tree.ReplicatedStorage.Shared."$path"' "$p")" = src/ReplicatedStorage/Shared ]
  [ "$(jq -r '.tree.ReplicatedStorage.Packages."$path".optional' "$p")" = Packages ]
  [ "$(jq -r '.tree.ServerScriptService.ServerPackages."$path".optional' "$p")" = ServerPackages ]
  [ "$(jq -r '.tree.HttpService."$properties".HttpEnabled' "$p")" = false ]
  for f in $(jq -r '.. | objects | ."$path"? | strings' "$p"); do
    [ -d "$FAKE/game/$f" ]
  done
}

@test "every Luau file is strict" {
  bash "$SCAFFOLD" "$FAKE/game" "Game" --no-git
  while IFS= read -r f; do
    [ "$(head -n 1 "$f")" = "--!strict" ] || { echo "$f is not strict"; return 1; }
  done < <(find "$FAKE/game/src" -name '*.luau')
}

@test "rokit.toml pins exact versions for the whole toolchain" {
  bash "$SCAFFOLD" "$FAKE/game" "Game" --no-git
  for tool in rojo wally lune stylua selene luau-lsp zap asphalt; do
    grep -Eq "^$tool = \"[A-Za-z0-9-]+/[A-Za-z0-9-]+@[0-9]+\.[0-9]+\.[0-9]+\"$" "$FAKE/game/rokit.toml" ||
      { echo "$tool is not pinned"; return 1; }
  done
  grep -q 'GitHub releases API on 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "$FAKE/game/rokit.toml"
}

@test "initialises git unless the directory is already in a repository" {
  [ -n "$REAL_GIT" ] || skip "git not available"
  bash "$SCAFFOLD" "$FAKE/game" "Game"
  [ -d "$FAKE/game/.git" ]
  mkdir -p "$FAKE/repo"
  git -C "$FAKE/repo" init -q
  bash "$SCAFFOLD" "$FAKE/repo/sub" "Game"
  [ ! -d "$FAKE/repo/sub/.git" ]
  bash "$SCAFFOLD" "$FAKE/nogit" "Game" --no-git
  [ ! -d "$FAKE/nogit/.git" ]
}

@test "refuses a non-empty directory unless --force" {
  mkdir -p "$FAKE/game"
  echo keep >"$FAKE/game/notes.txt"
  run bash "$SCAFFOLD" "$FAKE/game" "Game" --no-git
  [ "$status" -eq 1 ]
  [[ "$output" == *"not empty"* ]]
  [ ! -e "$FAKE/game/default.project.json" ]
  run bash "$SCAFFOLD" "$FAKE/game" "Game" --no-git --force
  [ "$status" -eq 0 ]
  [ -f "$FAKE/game/default.project.json" ]
  [ "$(cat "$FAKE/game/notes.txt")" = keep ]
}

@test "an empty git repository counts as empty" {
  [ -n "$REAL_GIT" ] || skip "git not available"
  mkdir -p "$FAKE/game"
  git -C "$FAKE/game" init -q
  run bash "$SCAFFOLD" "$FAKE/game" "Game"
  [ "$status" -eq 0 ]
}

@test "rejects unsafe project names and bad usage" {
  run bash "$SCAFFOLD" "$FAKE/game" 'a/b'
  [ "$status" -eq 1 ]
  run bash "$SCAFFOLD" "$FAKE/game" '-x'
  [ "$status" -eq 2 ]
  run bash "$SCAFFOLD" "$FAKE/game"
  [ "$status" -eq 2 ]
  [ ! -e "$FAKE/game" ]
}

@test "generates sourcemap.json when rojo is available" {
  fake_cmd rojo '[ "$1" = sourcemap ] && echo "{\"name\":\"x\"}" >sourcemap.json'
  run bash "$SCAFFOLD" "$FAKE/game" "Game" --no-git
  [ "$status" -eq 0 ]
  [ -f "$FAKE/game/sourcemap.json" ]
}
