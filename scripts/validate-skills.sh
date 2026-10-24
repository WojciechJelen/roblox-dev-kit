#!/usr/bin/env bash
# Check every skills/*/SKILL.md against the Agent Skills spec and this repo's conventions.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
PLUGIN_VERSION=$(awk 'match($0, /"version"[[:space:]]*:[[:space:]]*"[^"]*"/) {
  s = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", s); sub(/"$/, "", s); print s; exit
}' "$ROOT/.claude-plugin/plugin.json")
errors=0

fail() {
  printf 'error: %s: %s\n' "$skill" "$*" >&2
  errors=$((errors + 1))
}

# frontmatter_value FILE KEY: value of a top-level key ("metadata.version" for one nested level).
frontmatter_value() {
  awk -v want="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    /^---[[:space:]]*$/ { exit }
    {
      if ($0 ~ /^[^[:space:]]/) { parent = $0; sub(/:.*/, "", parent) }
      line = $0
      key = line; sub(/^[[:space:]]*/, "", key); sub(/:.*/, "", key)
      full = ($0 ~ /^[[:space:]]/) ? parent "." key : key
      if (full == want) {
        sub(/^[^:]*:[[:space:]]*/, "", line)
        gsub(/^["'\'']|["'\'']$/, "", line)
        print line
        exit
      }
    }
  ' "$1"
}

count=0
for skill_md in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  count=$((count + 1))
  dir=$(dirname "$skill_md")
  skill=$(basename "$dir")

  [ "$(head -n 1 "$skill_md")" = "---" ] || fail "SKILL.md must start with YAML frontmatter (---)"
  name=$(frontmatter_value "$skill_md" name)
  description=$(frontmatter_value "$skill_md" description)
  compatibility=$(frontmatter_value "$skill_md" compatibility)
  version=$(frontmatter_value "$skill_md" metadata.version)

  [ "$name" = "$skill" ] || fail "frontmatter name '$name' must equal the directory name"
  printf '%s' "$name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || fail "name must be lowercase kebab-case"
  [ ${#name} -le 64 ] || fail "name is longer than 64 characters"

  if [ -z "$description" ]; then
    fail "description is missing"
  else
    [ ${#description} -le 1024 ] || fail "description is ${#description} characters (max 1024)"
    printf '%s' "$description" | grep -iq 'when' || fail "description must say when to use the skill"
    case $description in
      "I "* | "I'm "* | You* | "We "* | Our* | "Use "* | "Let "*) fail "description must be written in the third person" ;;
    esac
  fi
  [ ${#compatibility} -le 500 ] || fail "compatibility is longer than 500 characters"
  [ -n "$version" ] || fail "metadata.version is missing"
  [ -z "$PLUGIN_VERSION" ] || [ "$version" = "$PLUGIN_VERSION" ] ||
    fail "metadata.version $version differs from plugin.json version $PLUGIN_VERSION"

  body_lines=$(awk 'NR == 1 && /^---/ { fm = 1; next } fm && /^---/ { fm = 0; next } !fm { n++ } END { print n + 0 }' "$skill_md")
  [ "$body_lines" -le 500 ] || fail "body is $body_lines lines (max 500)"

  # Files the skill points at must exist: markdown links and "$SKILL_DIR/..." / scripts|references|assets paths.
  # shellcheck disable=SC2016  # the patterns match a literal $SKILL_DIR and backticks
  refs=$(
    {
      grep -oE '\]\([^)#]*' "$skill_md" | sed 's/^](//' | grep -v -E '^(https?:|mailto:)' || true
      grep -oE '\$SKILL_DIR/[A-Za-z0-9_./-]*' "$skill_md" | sed 's|^\$SKILL_DIR/||' || true
      grep -oE '`(scripts|references|assets)/[A-Za-z0-9_./-]*`' "$skill_md" | tr -d '`' || true
    } | sort -u
  )
  for ref in $refs; do
    case $ref in ../*) continue ;; esac # sibling skills are optional at runtime
    [ -e "$dir/$ref" ] || fail "references missing file: $ref"
  done

  # Script names mentioned in prose must exist in this skill or a sibling skill.
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    ls "$ROOT"/skills/*/scripts/"$script" >/dev/null 2>&1 || fail "mentions $script, which no skill ships"
  done <<<"$(grep -oE '[a-z][a-z0-9_-]*\.sh' "$skill_md" | sort -u)"

  for script in "$dir"/scripts/*.sh; do
    [ -f "$script" ] || continue
    [ -x "$script" ] || fail "$(basename "$script") is not executable"
    head -n 1 "$script" | grep -q '^#!/usr/bin/env bash' || fail "$(basename "$script") must start with #!/usr/bin/env bash"
  done
  if [ -d "$dir/scripts" ] && [ ! -f "$dir/scripts/lib/common.sh" ]; then
    fail "scripts/lib/common.sh is missing (run make sync-lib)"
  fi

  [ $errors -gt 0 ] || printf 'ok: %s\n' "$skill"
done

[ $count -gt 0 ] || {
  echo "error: no skills found under $ROOT/skills" >&2
  exit 1
}
if [ $errors -gt 0 ]; then
  echo "validate-skills: $errors problem(s)" >&2
  exit 1
fi
echo "validate-skills: ok ($count skills)"
