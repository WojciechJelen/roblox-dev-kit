#!/usr/bin/env bash
# Create a new Rojo project from assets/template.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TEMPLATE_DIR=$(cd "$SCRIPT_DIR/../assets/template" && pwd)

usage() {
  cat <<EOF
usage: scaffold.sh <dir> <name> [--force] [--no-git] [--install-kit[=HARNESS] [--install-kit-args "OPTIONS"]]

Copies the project template into <dir> (created if missing) and names the project <name>.
  --force        write into a non-empty directory, overwriting files with the same names
  --no-git       do not run git init
  --install-kit  then install this kit into the new project for HARNESS (codex, pi, omp, claude or
                 all; default all installed harnesses): skills in <dir>/.agents/skills, MCP servers
                 in the project's own config files, and for Claude Code the project-scope plugin
                 commands to run (install/install.sh --harness HARNESS --project <dir>). Never done
                 without this flag. Registering the Blender server downloads it into uv's cache
                 (about 200 MB, a minute) unless --install-kit-args has --no-warm.
  --install-kit-args "OPTIONS"
                 install.sh options to add, from: --dry-run --no-warm --no-plugin --copy --no-mcp.
                 For anything else, run install/install.sh --project <dir> yourself.
EOF
}

force=0 git=1 dir='' name='' install_kit='' install_args=''
while [ $# -gt 0 ]; do
  case $1 in
    --force) force=1 ;;
    --no-git) git=0 ;;
    --install-kit) install_kit=all ;;
    --install-kit=*)
      install_kit=${1#--install-kit=}
      [ -n "$install_kit" ] || {
        rdk_err "--install-kit= needs a harness"
        exit 2
      }
      ;;
    --install-kit-args)
      [ $# -ge 2 ] || {
        rdk_err "--install-kit-args needs a value"
        exit 2
      }
      install_args=$2
      shift
      ;;
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

# Check the install options before creating anything.
if [ -n "$install_args" ] && [ -z "$install_kit" ]; then
  rdk_err "--install-kit-args needs --install-kit"
  exit 2
fi
for a in $install_args; do
  case $a in
    --dry-run | --no-warm | --no-plugin | --copy | --no-mcp) ;;
    *)
      rdk_err "--install-kit-args: $a is not one of --dry-run --no-warm --no-plugin --copy --no-mcp"
      exit 2
      ;;
  esac
done
case $install_kit in
  '') ;;
  all)
    any=0
    for h in $RDK_HARNESSES; do rdk_harness_installed "$h" && any=1; done
    [ $any = 1 ] || rdk_die "--install-kit: none of these harnesses is installed: $RDK_HARNESSES"
    ;;
  *)
    rdk_is_harness "$install_kit" || {
      rdk_err "--install-kit=$install_kit: expected codex, pi, omp, claude or all"
      exit 2
    }
    rdk_harness_installed "$install_kit" || rdk_die "--install-kit=$install_kit: $install_kit is not installed (not found on PATH)"
    ;;
esac
# The kit's installer lives at the root of the kit, three levels above this script's real location
# (the skill folder may be a symlink into the kit, or the Claude Code plugin's copy of it).
kit_root=$(cd "$(cd "$SCRIPT_DIR" && pwd -P)/../../.." && pwd)
installer="$kit_root/install/install.sh"
if [ -n "$install_kit" ] && [ ! -f "$installer" ]; then
  rdk_die "--install-kit needs the kit's install/install.sh, which this copy of the skill does not include. Scaffold without it, then from a checkout of roblox-dev-kit run: install/install.sh --harness $install_kit --project $(rdk_quote "$dir")"
fi

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

if [ -n "$install_kit" ]; then
  # shellcheck disable=SC2086  # the options were checked word by word above
  rdk_info "installing the kit into the project: $(rdk_quote "$installer" --harness "$install_kit" --project "$dir" $install_args)"
  # shellcheck disable=SC2086
  bash "$installer" --harness "$install_kit" --project "$dir" $install_args ||
    rdk_die "the per-project install did not finish (output above); the project itself is complete"
elif [ -f "$installer" ]; then
  rdk_info "to make it ready for every agent harness: $(rdk_quote "$installer" --harness all --project "$dir") (or re-run with --install-kit)"
fi
rdk_info "next: install-toolchain.sh --project $(rdk_quote "$dir"), then 'rojo serve' and connect the Rojo plugin in Studio"
