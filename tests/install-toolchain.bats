#!/usr/bin/env bats
# install-toolchain.sh with a fake rokit; one opt-in test installs the real Rokit into a temp HOME.

load helpers

setup() {
  setup_fake_machine
  TOOLCHAIN="$SETUP_SCRIPTS/install-toolchain.sh"
}

# fake_rokit [BIN_DIR]: a rokit that logs "rokit [args...] in <cwd> root=<ROKIT_ROOT>".
fake_rokit() {
  local dir=${1:-$FAKE/home/.rokit/bin}
  mkdir -p "$dir"
  cat >"$dir/rokit" <<EOF
#!/usr/bin/env bash
[ "\$1" = --version ] && { echo "rokit 1.2.0"; exit 0; }
{ printf 'rokit'; printf ' [%s]' "\$@"; printf ' in %s root=%s\n' "\$PWD" "\$ROKIT_ROOT"; } >>"$FAKE/calls.log"
EOF
  chmod +x "$dir/rokit"
}

TRUSTED='[rojo-rbx/rojo] [UpliftGames/wally] [lune-org/lune] [JohnnyMorganz/StyLua] [Kampfkarren/selene] [JohnnyMorganz/luau-lsp] [red-blox/zap] [jacktabscode/asphalt]'

@test "--trust records trust with rokit trust, then runs a plain rokit install" {
  fake_rokit
  scaffold_project "$FAKE/game"
  run bash "$TOOLCHAIN" --project "$FAKE/game" --trust
  [ "$status" -eq 0 ]
  game=$(cd "$FAKE/game" && pwd -P)
  [ "$(sed -n 1p "$FAKE/calls.log")" = "rokit [trust] $TRUSTED in $PWD root=$HOME/.rokit" ]
  [ "$(sed -n 2p "$FAKE/calls.log")" = "rokit [install] in $game root=$HOME/.rokit" ]
  run ! grep -q -- '--no-trust-check' "$FAKE/calls.log"
}

@test "without --trust outside a terminal it explains instead of hanging" {
  fake_rokit
  scaffold_project "$FAKE/game"
  run bash "$TOOLCHAIN" --project "$FAKE/game"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pass --trust"* ]]
  [ ! -e "$FAKE/calls.log" ]
}

@test "the current directory's rokit.toml is used by default" {
  fake_rokit
  scaffold_project "$FAKE/game"
  cd "$FAKE/game"
  run bash "$TOOLCHAIN" --trust
  [ "$status" -eq 0 ]
  grep -q '^rokit \[install\] in' "$FAKE/calls.log"
}

@test "global mode trusts the pinned tools and adds each missing one once" {
  fake_rokit
  : >"$FAKE/home/.rokit/bin/rojo"
  chmod +x "$FAKE/home/.rokit/bin/rojo"
  run bash "$TOOLCHAIN" --global --trust
  [ "$status" -eq 0 ]
  [[ "$output" == *"rojo: already linked"* ]]
  grep -qF "rokit [trust] $TRUSTED in" "$FAKE/calls.log"
  [ "$(grep -c '^rokit \[add\] \[--global\] \[' "$FAKE/calls.log")" -eq 7 ]
  grep -q '^rokit \[add\] \[--global\] \[JohnnyMorganz/luau-lsp@1.70.1\] \[luau-lsp\] in' "$FAKE/calls.log"
  run ! grep -q -- '--force' "$FAKE/calls.log"
  run ! grep -q 'add.*rojo-rbx/rojo' "$FAKE/calls.log"
}

@test "a custom RDK_ROKIT_BIN_DIR is the ROKIT_ROOT for every rokit call" {
  export RDK_ROKIT_BIN_DIR="$FAKE/opt/rokit/bin"
  fake_rokit "$RDK_ROKIT_BIN_DIR"
  scaffold_project "$FAKE/game"
  run bash "$TOOLCHAIN" --project "$FAKE/game" --trust
  [ "$status" -eq 0 ]
  [ "$(grep -c "root=$FAKE/opt/rokit\$" "$FAKE/calls.log")" -eq 2 ]
  [[ "$output" == *"export PATH=\"$FAKE/opt/rokit/bin:\$PATH\""* ]]
}

@test "--rokit-only stops after Rokit itself" {
  fake_rokit
  run bash "$TOOLCHAIN" --rokit-only
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE/calls.log" ]
}

@test "prints the PATH line and never edits shell profiles" {
  fake_rokit
  run bash "$TOOLCHAIN" --global --trust
  [[ "$output" == *'export PATH="$HOME/.rokit/bin:$PATH"'* ]]
  for f in .zshrc .zshenv .bashrc .profile .bash_profile; do [ ! -e "$HOME/$f" ]; done
}

@test "with Rokit missing, --dry-run shows the pinned official installer" {
  fake_logging_cmd curl
  fake_cmd unzip 'exit 0'
  run bash "$TOOLCHAIN" --global --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://raw.githubusercontent.com/rojo-rbx/rokit/v1.2.0/scripts/install.sh | bash -s -- 1.2.0"* ]]
  [ ! -e "$FAKE/calls.log" ]
}

@test "usage errors" {
  run bash "$TOOLCHAIN" --project "$FAKE/nowhere"
  [ "$status" -eq 1 ]
  run bash "$TOOLCHAIN" --bogus
  [ "$status" -eq 2 ]
}

# Opt-in network test: installs Rokit 1.2.0 and the template's tools into the fake HOME only.
@test "network: real Rokit install into a temp HOME leaves shell profiles alone" {
  [ "$NETWORK_TESTS" = 1 ] || skip "set RDK_NETWORK_TESTS=1 to download Rokit and the tools"
  for t in curl unzip; do command -v "$t" >/dev/null || skip "$t missing"; done
  scaffold_project "$FAKE/game"
  export SHELL=/bin/zsh
  run bash "$TOOLCHAIN" --project "$FAKE/game" --trust
  [ "$status" -eq 0 ]
  [ -x "$HOME/.rokit/bin/rokit" ]
  [ -x "$HOME/.rokit/bin/rojo" ]
  for f in .zshrc .zshenv .bashrc .profile; do [ ! -e "$HOME/$f" ]; done
  (cd "$FAKE/game" && "$HOME/.rokit/bin/rojo" --version) | grep -q '7.7.1'
  # Trust was recorded, so a later plain install works without a terminal.
  (cd "$FAKE/game" && "$HOME/.rokit/bin/rokit" install </dev/null 2>&1)
}
