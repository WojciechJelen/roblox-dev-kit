#!/usr/bin/env bash
# Create a new Rojo project from assets/template.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TEMPLATE_DIR=$(cd "$SCRIPT_DIR/../assets/template" && pwd)

usage() {
  cat <<EOF
usage: scaffold.sh <dir> <name> [--force] [--no-git]

Copies the project template into <dir> (created if missing) and names the project <name>.
  --force   write into a non-empty directory, overwriting files with the same names
  --no-git  do not run git init
EOF
}

force=0 git=1 dir='' name=''
while [ $# -gt 0 ]; do
  case $1 in
    --force) force=1 ;;
    --no-git) git=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      rdk_err "unknown option: $1"
      usage >&2
      exit 2
      ;;
    *)
      if [ -z "$dir" ]; then
        dir=$1
      elif [ -z "$name" ]; then
        name=$1
      else
        rdk_err "unexpected argument: $1"
        usage >&2
        exit 2
      fi
      ;;
  esac
  shift
done
if [ -z "$dir" ] || [ -z "$name" ]; then
  usage >&2
  exit 2
fi

rdk_check_project_name "$name"
package=$(rdk_package_name "$name")

if [ -d "$dir" ]; then
  existing=$(find "$dir" -mindepth 1 -maxdepth 1 ! -name .git ! -name .DS_Store)
  if [ -n "$existing" ] && [ $force = 0 ]; then
    rdk_die "$dir is not empty (use --force to write into it anyway)"
  fi
else
  mkdir -p "$dir"
fi
dir=$(cd "$dir" && pwd -P)

cp -R "$TEMPLATE_DIR/." "$dir/"

while IFS= read -r rel; do
  f="$dir/$rel"
  grep -q '{{' "$f" || continue
  sed -e "s/{{PROJECT_NAME}}/$name/g" -e "s/{{PACKAGE_NAME}}/$package/g" "$f" >"$f.rdk-tmp"
  mv "$f.rdk-tmp" "$f"
done < <(cd "$TEMPLATE_DIR" && find . -type f | sed 's|^\./||')

if [ $git = 1 ] && rdk_has git && ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$dir" init -q -b main 2>/dev/null || git -C "$dir" init -q
  rdk_info "initialised a git repository"
fi

if rdk_has rojo; then
  if (cd "$dir" && rojo sourcemap default.project.json -o sourcemap.json >/dev/null 2>&1); then
    rdk_info "generated sourcemap.json"
  else
    rdk_warn "rojo sourcemap failed; run it again after 'rokit install'"
  fi
fi

rdk_info "created $name in $(rdk_tilde "$dir")"
rdk_info "next: install-toolchain.sh --project $(rdk_quote "$dir"), then 'rojo serve' and connect the Rojo plugin in Studio"
