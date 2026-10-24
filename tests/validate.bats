#!/usr/bin/env bats
# scripts/validate-skills.sh on the real skills and on broken copies.

load helpers

setup() {
  setup_fake_machine
  T="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$T/scripts" "$T/.claude-plugin" "$T/skills/good-skill/references"
  cp "$KIT_ROOT/scripts/validate-skills.sh" "$T/scripts/"
  echo '{"name":"roblox","version":"0.1.0"}' >"$T/.claude-plugin/plugin.json"
  echo ok >"$T/skills/good-skill/references/notes.md"
}

# write_skill DIR NAME DESCRIPTION [BODY]
write_skill() {
  mkdir -p "$T/skills/$1"
  {
    printf -- '---\nname: %s\ndescription: %s\nmetadata:\n  version: "0.1.0"\n---\n\n' "$2" "$3"
    printf '%s\n' "${4:-See [notes](references/notes.md).}"
  } >"$T/skills/$1/SKILL.md"
}

@test "the repository's skills pass" {
  run bash "$KIT_ROOT/scripts/validate-skills.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"validate-skills: ok"* ]]
}

@test "a well-formed skill passes" {
  write_skill good-skill good-skill "Does a thing. Use it when the user asks for the thing."
  run bash "$T/scripts/validate-skills.sh"
  [ "$status" -eq 0 ]
}

@test "name, description and version problems are reported" {
  write_skill good-skill other-name "Does a thing. Use it when asked."
  run bash "$T/scripts/validate-skills.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must equal the directory name"* ]]

  write_skill good-skill good-skill "Does a thing for the user."
  run bash "$T/scripts/validate-skills.sh"
  [[ "$output" == *"must say when to use the skill"* ]]

  write_skill good-skill good-skill "Use this when you need a thing."
  run bash "$T/scripts/validate-skills.sh"
  [[ "$output" == *"third person"* ]]

  write_skill good-skill good-skill "$(printf 'x%.0s' $(seq 1 1030)) when"
  run bash "$T/scripts/validate-skills.sh"
  [[ "$output" == *"max 1024"* ]]

  write_skill good-skill good-skill "Does a thing when asked."
  sed -i.bak 's/version: "0.1.0"/version: "0.0.9"/' "$T/skills/good-skill/SKILL.md"
  run bash "$T/scripts/validate-skills.sh"
  [[ "$output" == *"differs from plugin.json version 0.1.0"* ]]
}

@test "missing referenced files and unknown scripts are reported" {
  write_skill good-skill good-skill "Does a thing when asked." \
    "Read [this](references/missing.md), run \`scripts/gone.sh\` and nothing-here.sh."
  run bash "$T/scripts/validate-skills.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"references missing file: references/missing.md"* ]]
  [[ "$output" == *"references missing file: scripts/gone.sh"* ]]
  [[ "$output" == *"mentions nothing-here.sh, which no skill ships"* ]]
}

@test "a body over 500 lines fails" {
  write_skill good-skill good-skill "Does a thing when asked." "$(seq 1 501)"
  run bash "$T/scripts/validate-skills.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"max 500"* ]]
}

@test "scripts must be executable and have the vendored lib" {
  write_skill good-skill good-skill "Does a thing when asked."
  mkdir -p "$T/skills/good-skill/scripts"
  printf '#!/usr/bin/env bash\n' >"$T/skills/good-skill/scripts/run.sh"
  run bash "$T/scripts/validate-skills.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run.sh is not executable"* ]]
  [[ "$output" == *"scripts/lib/common.sh is missing"* ]]
}
