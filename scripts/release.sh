#!/usr/bin/env bash
# Cut a release: bump every version field, date the changelog, run the checks, commit and tag.
# Never pushes; prints the push command instead.
# shellcheck disable=SC2016  # jq programs use $variables literally
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$ROOT"

usage() {
  echo "usage: scripts/release.sh <version> [--dry-run]   (version: X.Y.Z)"
}

version='' dry_run=0
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) version=$arg ;;
  esac
done
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  usage >&2
  exit 2
}
command -v jq >/dev/null || {
  echo "error: release.sh needs jq" >&2
  exit 1
}
grep -q '^## \[Unreleased\]' CHANGELOG.md || {
  echo "error: CHANGELOG.md has no '## [Unreleased]' section" >&2
  exit 1
}
if [ $dry_run = 0 ] && [ -n "$(git status --porcelain)" ]; then
  echo "error: the working tree is not clean" >&2
  exit 1
fi

tag="roblox--v$version"
today=$(date +%Y-%m-%d)
if [ $dry_run = 1 ]; then
  echo "would set version $version in: .claude-plugin/plugin.json, .claude-plugin/marketplace.json, lib/common.sh, skills/*/SKILL.md"
  echo "would rename '## [Unreleased]' to '## [$version] - $today' in CHANGELOG.md"
  echo "would run: make sync-lib all; git commit -m 'Release $version'; git tag $tag"
  exit 0
fi

rewrite() { # rewrite FILE COMMAND...: replace FILE with the command's output
  local f=$1
  shift
  "$@" <"$f" >"$f.tmp"
  mv "$f.tmp" "$f"
}

rewrite .claude-plugin/plugin.json jq --arg v "$version" '.version = $v'
rewrite .claude-plugin/marketplace.json jq --arg v "$version" '(.plugins[] | select(.name == "roblox") | .version) = $v'
rewrite lib/common.sh sed "s/^RDK_KIT_VERSION=\".*\"/RDK_KIT_VERSION=\"$version\"/"
for f in skills/*/SKILL.md; do
  # Only the frontmatter's metadata.version line.
  rewrite "$f" awk -v v="$version" '
    NR == 1 && /^---/ { fm = 1; print; next }
    fm && /^---/ { fm = 0 }
    fm && /^  version:/ { print "  version: \"" v "\""; next }
    { print }'
done
rewrite CHANGELOG.md awk -v v="$version" -v d="$today" '
  !done && /^## \[Unreleased\]/ { print "## [Unreleased]"; print ""; print "## [" v "] - " d; done = 1; next }
  { print }'

make sync-lib all
git add -A
git commit -m "Release $version"
if command -v claude >/dev/null && claude plugin tag --help >/dev/null 2>&1; then
  claude plugin tag -m "roblox %s" .
else
  git tag -a "$tag" -m "roblox $version"
fi
echo "released $version. Push with: git push && git push origin $tag"
