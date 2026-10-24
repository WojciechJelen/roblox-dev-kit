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
    "Read [this](references/missing.md), run \`scripts/gone.sh\`, nothing-here.sh and run_nothing.sh."
  run bash "$T/scripts/validate-skills.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"references missing file: references/missing.md"* ]]
  [[ "$output" == *"references missing file: scripts/gone.sh"* ]]
  [[ "$output" == *"mentions nothing-here.sh, which no skill ships"* ]]
  [[ "$output" == *"mentions run_nothing.sh, which no skill ships"* ]]
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

# --- scripts/validate-evals.sh -------------------------------------------------------------

# write_case NAME PROMPT_FRONTMATTER: a minimal valid case under $T/evals with one llm grader.
write_case() {
  mkdir -p "$T/evals/$1/graders"
  printf -- '---\n%s\n---\n\nDo the thing.\n' "$2" >"$T/evals/$1/prompt.md"
  printf 'schema_version: "1.1"\nname: %s\n' "$1" >"$T/evals/$1/case.yaml"
  printf -- '---\ntype: llm\n---\n\nPASS if the thing is done.\n' >"$T/evals/$1/graders/01-done.md"
}

@test "the repository's eval cases pass" {
  run bash "$KIT_ROOT/scripts/validate-evals.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"validate-evals: ok (6 cases)"* ]]
}

@test "a well-formed eval case passes" {
  write_case good-case 'max_turns: 5
allowed_tools: [Read, Bash]
env:
  EVAL_MODE: fast'
  run bash "$KIT_ROOT/scripts/validate-evals.sh" "$T/evals"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: good-case"* ]]
}

@test "eval case problems are reported" {
  write_case bad-case 'max_turns: 5
disallowed_tools: [Agent]
env:
  RDK_HOME: /tmp/x'
  printf 'schema_version: 1.1\nname: other\ncontext:\n  scaffold_script: setup.sh\n  setup_env: x\nexecution:\n  max_turns: 5\n  bogus: 1\n' >"$T/evals/bad-case/case.yaml"
  printf 'echo hi\n' >"$T/evals/bad-case/setup.sh"
  printf 'no frontmatter\n' >"$T/evals/bad-case/graders/02-plain.md"
  printf -- '---\ntype: regex\nflags: i\n---\n\n' >"$T/evals/bad-case/graders/03-empty-regex.md"
  printf -- '---\ntype: custom\n---\nx\n' >"$T/evals/bad-case/graders/04-custom.md"
  printf -- '---\ntype: tool_used\ninput_match: x\n---\n' >"$T/evals/bad-case/graders/05-no-tool.md"
  mkdir -p "$T/evals/no-graders"
  printf -- '---\nmax_turns: 3\n---\n\nHi.\n' >"$T/evals/no-graders/prompt.md"
  run bash "$KIT_ROOT/scripts/validate-evals.sh" "$T/evals"
  [ "$status" -eq 1 ]
  [[ "$output" == *"prompt.md: unknown key 'disallowed_tools'"* ]]
  [[ "$output" == *"env key RDK_HOME must match EVAL_"* ]]
  [[ "$output" == *'schema_version must be "1.1" (quoted)'* ]]
  [[ "$output" == *"name 'other' must equal the folder name"* ]]
  [[ "$output" == *"case.yaml context: unknown key 'setup_env'"* ]]
  [[ "$output" == *"case.yaml execution: unknown key 'bogus'"* ]]
  [[ "$output" != *"unknown key 'max_turns'"* ]]
  [[ "$output" == *"scaffold_script setup.sh is not executable"* ]]
  [[ "$output" == *"graders/02-plain.md has no frontmatter"* ]]
  [[ "$output" == *"graders/03-empty-regex.md: regex grader needs a pattern"* ]]
  [[ "$output" == *"graders/04-custom.md: unknown type 'custom'"* ]]
  [[ "$output" == *"graders/05-no-tool.md: tool_used grader needs tool"* ]]
  [[ "$output" == *"no-graders: no graders"* ]]
}

# grader_matches GRADER COMMAND: whether GRADER's input_match finds COMMAND in a Bash tool input,
# which the eval runner sees JSON-encoded (a newline is the two characters \n, quotes are \").
grader_matches() {
  local pattern
  pattern=$(sed -n "s/^input_match: '\(.*\)'\$/\1/p" "$KIT_ROOT/evals/$1")
  [ -n "$pattern" ] || return 2
  python3 -I -c 'import json, re, sys
sys.exit(0 if re.search(sys.argv[1], json.dumps({"command": sys.argv[2], "description": "x"})) else 1)' "$pattern" "$2"
}

@test "eval graders that forbid a command stop at the end of that command" {
  never=adopt-existing/graders/03-never-applies.md
  grader_matches $never 'bash /k/adopt.sh . --mapping mapping.tsv --apply'
  grader_matches $never 'bash "$SKILL/scripts/adopt.sh" "$PWD" --mapping "map.tsv" --apply --with-config'
  grader_matches $never 'mv src/Factory.lua src/ReplicatedStorage/RivalsFactory.lua'
  run ! grader_matches $never "$(printf 'bash /k/adopt.sh . --mapping m.tsv\necho "re-run with --apply to make the changes"')"
  run ! grader_matches $never 'bash /k/adopt.sh . --mapping m.tsv && echo "then --apply"'
  run ! grader_matches $never 'bash /k/adopt.sh . --mapping m.tsv | tee plan.txt; grep -c -- --apply plan.txt'

  dry=adopt-existing/graders/02-runs-adopt-dry-run.md
  grader_matches $dry 'cd /w && bash "/k/adopt.sh" . --mapping mapping.tsv --name "Motor Rivals"'
  run ! grader_matches $dry "$(printf 'bash /k/adopt.sh --help\nprintf "x --mapping y"')"

  fixes=doctor-missing-blender/graders/03-does-not-apply-fixes.md
  grader_matches $fixes 'set -a; . ./machine.env; set +a; bash /k/doctor.sh --json --fix'
  grader_matches $fixes 'ln -s /m/Blender.app/Contents/MacOS/Blender ~/.local/bin/blender'
  run ! grader_matches $fixes "$(printf 'set -a; . ./machine.env; set +a; bash /k/doctor.sh --json\necho "--fix would add the link"')"
}

@test "the README documents --allow-tools with space-separated tools" {
  grep -q -- '--allow-tools Bash Write' "$KIT_ROOT/README.md"
  run ! grep -q -- '--allow-tools [A-Za-z]*,' "$KIT_ROOT/README.md"
}
