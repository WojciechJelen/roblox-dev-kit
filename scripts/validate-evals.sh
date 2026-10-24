#!/usr/bin/env bash
# Check the structure of the `claude plugin eval` cases under evals/ without running them.
# `claude plugin eval` has no validate or list mode (every run is a paid model run), so this
# checks the documented file format (https://code.claude.com/docs/en/plugin-evals.md): a case
# is a folder with prompt.md or case.yaml and at least one grader; frontmatter keys come from
# the documented lists, and unknown prompt.md keys fail a run.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
EVALS=${1:-$ROOT/evals}
errors=0

PROMPT_KEYS="schema_version name description tags plugins runs expected_outcome model max_turns timeout_seconds allowed_tools append_system_prompt env"
CASE_KEYS="schema_version name description tags plugins runs expected_outcome execution context graders"
CONTEXT_KEYS="scaffold_script history_file add_dirs"
GRADER_COMMON="type weight arm"

fail() {
  printf 'error: %s: %s\n' "$case_name" "$*" >&2
  errors=$((errors + 1))
}

# frontmatter FILE: the YAML between the first two --- lines (nothing if the file has none).
frontmatter() { awk 'NR == 1 { if ($0 != "---") exit; next } /^---[[:space:]]*$/ { exit } { print }' "$1"; }

# body FILE: what follows the frontmatter.
body() { awk 'NR == 1 && /^---/ { fm = 1; next } fm && /^---[[:space:]]*$/ { fm = 0; next } !fm { print }' "$1"; }

# top_keys: top-level keys of the YAML on stdin.
top_keys() { sed -n 's/^\([A-Za-z_][A-Za-z0-9_-]*\):.*/\1/p'; }

# child_keys PARENT: keys indented directly under PARENT: in the YAML on stdin.
child_keys() {
  awk -v p="$1" '
    $0 ~ "^" p ":" { on = 1; next }
    on && /^[^[:space:]#]/ { on = 0 }
    on && /^[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*:/ { k = $0; sub(/^[[:space:]]+/, "", k); sub(/:.*/, "", k); print k }
  '
}

value_of() { sed -n "s/^$1:[[:space:]]*//p" | head -n 1; }

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

check_keys() { # check_keys WHAT ALLOWED KEYS...
  local what=$1 allowed=$2 k
  shift 2
  for k in "$@"; do in_list "$k" "$allowed" || fail "$what: unknown key '$k'"; done
}

check_grader() {
  local f=$1 g fm type keys allowed
  g="graders/$(basename "$f")"
  fm=$(frontmatter "$f")
  if [ -z "$fm" ]; then
    fail "$g has no frontmatter, so the CLI ignores it"
    return
  fi
  type=$(value_of type <<<"$fm")
  # shellcheck disable=SC2046  # one key per word
  set -- $(top_keys <<<"$fm")
  case $type in
    llm) allowed="criteria focus" ;;
    regex) allowed="pattern flags match target" ;;
    tool_used) allowed="tool input_match min max" ;;
    tool_order) allowed="before after" ;;
    file_exists) allowed="path exists" ;;
    baseline) allowed="baseline_file criteria" ;;
    '') fail "$g has no type" && return ;;
    *) fail "$g: unknown type '$type'" && return ;;
  esac
  check_keys "$g" "$GRADER_COMMON $allowed" "$@"
  keys=" $* "
  case $type in
    regex) [[ $keys == *" pattern "* ]] || [ -n "$(body "$f" | tr -d '[:space:]')" ] || fail "$g: regex grader needs a pattern" ;;
    tool_used) [[ $keys == *" tool "* ]] || fail "$g: tool_used grader needs tool" ;;
    tool_order) [[ $keys == *" before "* && $keys == *" after "* ]] || fail "$g: tool_order grader needs before and after" ;;
    file_exists) [[ $keys == *" path "* ]] || fail "$g: file_exists grader needs path" ;;
    baseline) [[ $keys == *" baseline_file "* ]] || fail "$g: baseline grader needs baseline_file" ;;
    llm) [[ $keys == *" criteria "* ]] || [ -n "$(body "$f" | tr -d '[:space:]')" ] || fail "$g: llm grader needs criteria (or a body)" ;;
  esac
}

check_case() {
  local dir=$1 fm name script n=0 f k
  case_name=$(basename "$dir")
  printf '%s' "$case_name" | grep -Eq '^[a-z][a-z0-9-]*$' || fail "case names are lowercase letters, digits and hyphens"
  case $case_name in results | mocks | node_modules | files | true | false | null) fail "'$case_name' is a reserved name" ;; esac

  if [ -f "$dir/prompt.md" ]; then
    fm=$(frontmatter "$dir/prompt.md")
    # shellcheck disable=SC2046
    check_keys prompt.md "$PROMPT_KEYS" $(top_keys <<<"$fm")
    for k in $(child_keys env <<<"$fm"); do
      printf '%s' "$k" | grep -Eq '^EVAL_[A-Z0-9_]*$' || fail "prompt.md: env key $k must match EVAL_[A-Z0-9_]*"
    done
    [ -n "$(body "$dir/prompt.md" | tr -d '[:space:]')" ] || fail "prompt.md has no prompt"
  fi
  if [ -f "$dir/case.yaml" ]; then
    fm=$(cat "$dir/case.yaml")
    [ "$(value_of schema_version <<<"$fm")" = '"1.1"' ] || fail 'case.yaml: schema_version must be "1.1" (quoted)'
    name=$(value_of name <<<"$fm")
    [ "$name" = "$case_name" ] || fail "case.yaml: name '$name' must equal the folder name"
    # shellcheck disable=SC2046
    check_keys case.yaml "$CASE_KEYS" $(top_keys <<<"$fm")
    # shellcheck disable=SC2046
    check_keys "case.yaml context" "$CONTEXT_KEYS" $(child_keys context <<<"$fm")
    script=$(sed -n 's/^[[:space:]]*scaffold_script:[[:space:]]*//p' "$dir/case.yaml" | tr -d '"'\''')
    if [ -n "$script" ]; then
      if [ ! -f "$dir/$script" ]; then
        fail "scaffold_script $script is missing"
      else
        [ -x "$dir/$script" ] || fail "scaffold_script $script is not executable"
        head -n 1 "$dir/$script" | grep -q '^#!/usr/bin/env bash' || fail "scaffold_script $script must start with #!/usr/bin/env bash"
      fi
    fi
  elif [ ! -f "$dir/prompt.md" ]; then
    return
  fi
  for f in "$dir"/graders/*.md; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    check_grader "$f"
  done
  grep -q '^graders:' "$dir/case.yaml" 2>/dev/null && n=$((n + 1))
  [ $n -gt 0 ] || fail "no graders (graders/*.md or graders: in case.yaml)"
}

[ -d "$EVALS" ] || {
  echo "error: no eval directory at $EVALS" >&2
  exit 1
}
count=0
for dir in "$EVALS"/*/; do
  dir=${dir%/}
  [ -f "$dir/prompt.md" ] || [ -f "$dir/case.yaml" ] || continue
  count=$((count + 1))
  before=$errors
  check_case "$dir"
  [ $errors -gt $before ] || printf 'ok: %s\n' "$(basename "$dir")"
done
[ $count -gt 0 ] || {
  echo "error: no eval cases under $EVALS" >&2
  exit 1
}
if [ $errors -gt 0 ]; then
  echo "validate-evals: $errors problem(s)" >&2
  exit 1
fi
echo "validate-evals: ok ($count cases)"
