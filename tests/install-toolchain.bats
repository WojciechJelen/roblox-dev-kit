#!/usr/bin/env bats
# install-toolchain.sh with a fake rokit; one opt-in test installs the real Rokit into a temp HOME.

load helpers

setup() {
  setup_fake_machine
  TOOLCHAIN="$SETUP_SCRIPTS/install-toolchain.sh"
}

fake_rokit() {
  mkdir -p "$FAKE/home/.rokit/bin"
  cat >"$FAKE/home/.rokit/bin/rokit" <<EOF
#!/usr/bin/env bash
[ "\$1" = --version ] && { echo "rokit 1.2.0"; exit 0; }
{ printf 'rokit'; printf ' [%s]' "\$@"; printf ' in %s\n' "\$PWD"; } >>"$FAKE/calls.log"
EOF
  chmod +x "$FAKE/home/.rokit/bin/rokit"
}

@test "project mode runs rokit install in the project, --trust skips the prompt" {
  fake_rokit
  scaffold_project "$FAKE/game"
  run bash "$TOOLCHAIN" --project "$FAKE/game" --trust
  [ "$status" -eq 0 ]
  grep -qx "rokit \[install\] \[--no-trust-check\] in $(cd "$FAKE/game" && pwd -P)" "$FAKE/calls.log"
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
  grep -q '^rokit \[install\]' "$FAKE/calls.log"
}

@test "global mode adds every pinned tool once" {
  fake_rokit
  : >"$FAKE/home/.rokit/bin/rojo"
  chmod +x "$FAKE/home/.rokit/bin/rojo"
  run bash "$TOOLCHAIN" --global --trust
  [ "$status" -eq 0 ]
  [[ "$output" == *"rojo: already linked"* ]]
  [ "$(grep -c '^rokit \[add\] \[--global\] \[--force\]' "$FAKE/calls.log")" -eq 7 ]
  grep -q '^rokit \[add\] \[--global\] \[--force\] \[JohnnyMorganz/luau-lsp@1.70.1\] \[luau-lsp\]' "$FAKE/calls.log"
  run ! grep -q 'rojo-rbx/rojo' "$FAKE/calls.log"
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
}
