#!/usr/bin/env bats
# adopt.sh: loose scripts -> Rojo project with the same DataModel paths.

load helpers

setup() {
  setup_fake_machine
  ADOPT="$SETUP_SCRIPTS/adopt.sh"
  GAME="$FAKE/rivals"
  mkdir -p "$GAME/src"
  for f in Factory.lua FX.lua Server.server.lua Client.client.lua; do echo "-- $f" >"$GAME/src/$f"; done
  MAP="$FAKE/mapping.tsv"
  printf '%s\n' \
    '# source	DataModel path	class' \
    'src/Factory.lua	ReplicatedStorage/RivalsFactory	ModuleScript' \
    'src/FX.lua	ReplicatedStorage/RivalsFX	ModuleScript' \
    'src/Server.server.lua	ServerScriptService/RivalsServer	Script' \
    '' \
    'src/Client.client.lua	StarterPlayer/StarterPlayerScripts/RivalsClient	LocalScript   # entry point' >"$MAP"
}

project_json() { # the JSON block that adopt.sh prints after "default.project.json:"
  printf '%s\n' "$output" | awk '/^default.project.json:$/ { on = 1; next } on && /^$/ { exit } on'
}

@test "dry run prints the plan and changes nothing" {
  before=$(cd "$GAME" && find . | sort)
  run bash "$ADOPT" "$GAME" --mapping "$MAP" --name "Motor Rivals"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run"* ]]
  [[ "$output" == *"move   src/Factory.lua -> src/ReplicatedStorage/RivalsFactory.lua  (ReplicatedStorage.RivalsFactory, ModuleScript)"* ]]
  [[ "$output" == *"move   src/Server.server.lua -> src/ServerScriptService/RivalsServer.server.lua  (ServerScriptService.RivalsServer, Script)"* ]]
  [[ "$output" == *"move   src/Client.client.lua -> src/StarterPlayerScripts/RivalsClient.client.lua"* ]]
  [ "$(cd "$GAME" && find . | sort)" = "$before" ]
}

@test "the generated project keeps unknown Studio instances and maps one node per script" {
  run bash "$ADOPT" "$GAME" --mapping "$MAP" --name "Motor Rivals"
  json=$(project_json)
  [ "$(jq -r .name <<<"$json")" = "Motor Rivals" ]
  [ "$(jq -r '.tree."$className"' <<<"$json")" = DataModel ]
  [ "$(jq -r '.tree.ReplicatedStorage."$ignoreUnknownInstances"' <<<"$json")" = true ]
  [ "$(jq -r '.tree.ReplicatedStorage."$path" // "none"' <<<"$json")" = none ]
  [ "$(jq -r '.tree.ReplicatedStorage.RivalsFactory."$path"' <<<"$json")" = src/ReplicatedStorage/RivalsFactory.lua ]
  [ "$(jq -r '.tree.ServerScriptService.RivalsServer."$path"' <<<"$json")" = src/ServerScriptService/RivalsServer.server.lua ]
  [ "$(jq -r '.tree.StarterPlayer.StarterPlayerScripts."$ignoreUnknownInstances"' <<<"$json")" = true ]
  [ "$(jq -r '.tree.StarterPlayer.StarterPlayerScripts.RivalsClient."$path"' <<<"$json")" = src/StarterPlayerScripts/RivalsClient.client.lua ]
}

@test "--apply moves the files and writes default.project.json" {
  run bash "$ADOPT" "$GAME" --mapping "$MAP" --name "Motor Rivals" --apply
  [ "$status" -eq 0 ]
  [ "$(cat "$GAME/src/ReplicatedStorage/RivalsFactory.lua")" = "-- Factory.lua" ]
  [ -f "$GAME/src/ReplicatedStorage/RivalsFX.lua" ]
  [ -f "$GAME/src/ServerScriptService/RivalsServer.server.lua" ]
  [ "$(cat "$GAME/src/StarterPlayerScripts/RivalsClient.client.lua")" = "-- Client.client.lua" ]
  [ ! -e "$GAME/src/Factory.lua" ]
  [ "$(jq -S . "$GAME/default.project.json")" = "$(project_json | jq -S .)" ]
  [ ! -e "$GAME/rokit.toml" ]
}

@test "--with-config adds missing tool configs without overwriting, non-strict .luaurc" {
  echo 'keep' >"$GAME/stylua.toml"
  run bash "$ADOPT" "$GAME" --mapping "$MAP" --with-config --apply
  [ "$status" -eq 0 ]
  [ "$(cat "$GAME/stylua.toml")" = keep ]
  grep -q '^name = "local/rivals"$' "$GAME/wally.toml"
  [ "$(jq -r .languageMode "$GAME/.luaurc")" = nonstrict ]
  [ -f "$GAME/rokit.toml" ]
  [ -f "$GAME/.vscode/settings.json" ]
}

@test "class decides the suffix and the extension is kept" {
  mv "$GAME/src/FX.lua" "$GAME/src/FX.luau"
  printf 'src/FX.luau\tReplicatedFirst/Loading/Splash\tLocalScript\n' >"$MAP"
  run bash "$ADOPT" "$GAME" --mapping "$MAP" --apply
  [ "$status" -eq 0 ]
  [ -f "$GAME/src/ReplicatedFirst/Loading/Splash.client.luau" ]
  [ "$(jq -r '.tree.ReplicatedFirst.Loading."$className"' "$GAME/default.project.json")" = Folder ]
  [ "$(jq -r '.tree.ReplicatedFirst.Loading."$ignoreUnknownInstances"' "$GAME/default.project.json")" = true ]
}

@test "dot-separated DataModel paths work too" {
  printf 'src/Factory.lua\tReplicatedStorage.Modules.Factory\tModuleScript\n' >"$MAP"
  run bash "$ADOPT" "$GAME" --mapping "$MAP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-> src/ReplicatedStorage/Modules/Factory.lua  (ReplicatedStorage.Modules.Factory, ModuleScript)"* ]]
}

@test "uses git mv for tracked files" {
  [ -n "$REAL_GIT" ] || skip "git not available"
  git -C "$GAME" init -q
  git -C "$GAME" -c user.email=t@t -c user.name=t add -A
  git -C "$GAME" -c user.email=t@t -c user.name=t commit -qm init
  run bash "$ADOPT" "$GAME" --mapping "$MAP" --apply
  [ "$status" -eq 0 ]
  git -C "$GAME" status --porcelain | grep -q '^R  src/Factory.lua -> src/ReplicatedStorage/RivalsFactory.lua'
}

@test "mistakes in the mapping are reported and nothing changes" {
  printf '%s\n' \
    'src/Missing.lua	ReplicatedStorage/X	ModuleScript' \
    'src/Factory.lua	ReplicatedStorage/Y	Thing' \
    'src/FX.lua	Nowhere/Z	ModuleScript' \
    'src/Server.server.lua	ServerScriptService	Script' \
    '/etc/passwd	ReplicatedStorage/P	ModuleScript' \
    'only-two	columns' >"$MAP"
  run bash "$ADOPT" "$GAME" --mapping "$MAP" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 1: source file not found"* ]]
  [[ "$output" == *"line 2: class must be"* ]]
  [[ "$output" == *"line 3: unknown service 'Nowhere'"* ]]
  [[ "$output" == *"line 4: DataModel path needs a service and a name"* ]]
  [[ "$output" == *"line 5: source must be a path inside"* ]]
  [[ "$output" == *"line 6: expected 3 columns"* ]]
  [ -f "$GAME/src/Factory.lua" ]
  [ ! -e "$GAME/default.project.json" ]
}

@test "duplicate targets and scripts with mapped children are refused" {
  printf '%s\n' 'src/Factory.lua	ReplicatedStorage/Same	ModuleScript' 'src/FX.lua	ReplicatedStorage/Same	ModuleScript' >"$MAP"
  run bash "$ADOPT" "$GAME" --mapping "$MAP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"two scripts map to"* ]]
  printf '%s\n' 'src/Factory.lua	ReplicatedStorage/Lib	ModuleScript' 'src/FX.lua	ReplicatedStorage/Lib/Child	ModuleScript' >"$MAP"
  run bash "$ADOPT" "$GAME" --mapping "$MAP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has mapped children"* ]]
}

@test "warns about scripts that will not run where they are placed" {
  printf 'src/Client.client.lua\tServerScriptService/Oops\tLocalScript\n' >"$MAP"
  run bash "$ADOPT" "$GAME" --mapping "$MAP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a LocalScript in ServerScriptService will not run"* ]]
}

@test "an existing default.project.json needs --force and is backed up" {
  echo '{"name":"old","tree":{"$className":"DataModel"}}' >"$GAME/default.project.json"
  run bash "$ADOPT" "$GAME" --mapping "$MAP" --apply
  [ "$status" -eq 1 ]
  run bash "$ADOPT" "$GAME" --mapping "$MAP" --apply --force
  [ "$status" -eq 0 ]
  [ "$(jq -r .name "$GAME/default.project.json.bak")" = old ]
  [ "$(jq -r .name "$GAME/default.project.json")" = rivals ]
}

@test "re-running with the moved paths keeps files in place" {
  bash "$ADOPT" "$GAME" --mapping "$MAP" --apply >/dev/null
  printf 'src/ReplicatedStorage/RivalsFactory.lua\tReplicatedStorage/RivalsFactory\tModuleScript\n' >"$MAP"
  run bash "$ADOPT" "$GAME" --mapping "$MAP" --apply --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep   src/ReplicatedStorage/RivalsFactory.lua"* ]]
  [ -f "$GAME/src/ReplicatedStorage/RivalsFactory.lua" ]
}
