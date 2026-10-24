#!/usr/bin/env bash
# Install the kit's skills for Codex, pi, Oh My Pi or Claude Code (without the plugin),
# then register the MCP servers with mcp-config.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

usage() {
  cat <<EOF
usage: install.sh --harness codex|pi|omp|claude|all [--project DIR] [--copy] [--no-mcp] [--dry-run]

Links every skill in $(rdk_tilde "$ROOT")/skills into:
  codex, pi, omp  ~/.agents/skills/   (all three read it)
  claude          ~/.claude/skills/   (prefer the plugin: claude plugin marketplace add $(rdk_tilde "$ROOT"))
  --project DIR   DIR/.agents/skills/ (and DIR/.claude/skills/ for claude) instead
'all' means every harness that is installed. Then runs mcp-config.sh for each harness.

  --copy     copy the skill folders instead of symlinking (for machines where this repo won't stay)
  --no-mcp   skip MCP registration
  --dry-run  print what would change
EOF
}

harness='' project='' copy=0 mcp=1 dry_run=0
while [ $# -gt 0 ]; do
  case $1 in
    --harness | --project)
      [ $# -ge 2 ] || rdk_die "$1 needs a value"
      if [ "$1" = --harness ]; then harness=$2; else project=$2; fi
      shift
      ;;
    --copy) copy=1 ;;
    --no-mcp) mcp=0 ;;
    --dry-run) dry_run=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      rdk_err "unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done
[ -n "$harness" ] || {
  usage >&2
  exit 2
}
if [ -n "$project" ]; then
  [ -d "$project" ] || rdk_die "not a directory: $project"
  project=$(cd "$project" && pwd -P)
fi

if [ "$harness" = all ]; then
  harnesses=''
  for h in $RDK_HARNESSES; do rdk_harness_installed "$h" && harnesses="$harnesses $h"; done
  [ -n "$harnesses" ] || rdk_die "none of these harnesses is installed: $RDK_HARNESSES"
else
  rdk_is_harness "$harness" || rdk_die "unknown harness: $harness (expected codex, pi, omp, claude or all)"
  rdk_harness_installed "$harness" || rdk_die "$harness is not installed (not found on PATH)"
  harnesses=$harness
fi

skills=''
for f in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$f" ] && skills="$skills $(basename "$(dirname "$f")")"
done
[ -n "$skills" ] || rdk_die "no skills found in $ROOT/skills"

target_dir() {
  if [ -n "$project" ]; then
    if [ "$1" = claude ]; then echo "$project/.claude/skills"; else echo "$project/.agents/skills"; fi
  else
    rdk_harness_skills_dir "$1"
  fi
}

act() { [ $dry_run = 1 ] || "$@"; }

# install_skill SRC DEST: idempotent; never touches a DEST that does not belong to this repo.
install_skill() {
  local src=$1 dest=$2 current would=''
  [ $dry_run = 0 ] || would='would '
  if [ -L "$dest" ]; then
    current=$(readlink "$dest")
    if [ "$current" = "$src" ] && [ $copy = 0 ]; then
      rdk_info "ok      $(rdk_tilde "$dest") -> $(rdk_tilde "$src")"
      return 0
    fi
    case $current in
      "$ROOT"/skills/*) act rm "$dest" ;;
      *)
        rdk_warn "skip    $(rdk_tilde "$dest") links to $current, not this kit; leaving it alone"
        return 0
        ;;
    esac
  elif [ -e "$dest" ]; then
    if [ -f "$dest/.rdk-source" ] && [ "$(cat "$dest/.rdk-source")" = "$ROOT" ]; then
      act rm -rf "$dest"
    else
      rdk_warn "skip    $(rdk_tilde "$dest") already exists and was not installed by this kit; leaving it alone"
      return 0
    fi
  fi
  act mkdir -p "$(dirname "$dest")"
  if [ $copy = 1 ]; then
    act cp -R "$src" "$dest"
    if [ $dry_run = 0 ]; then printf '%s\n' "$ROOT" >"$dest/.rdk-source"; fi
    rdk_info "${would}copy    $(rdk_tilde "$src") -> $(rdk_tilde "$dest")"
  else
    act ln -s "$src" "$dest"
    rdk_info "${would}link    $(rdk_tilde "$dest") -> $(rdk_tilde "$src")"
  fi
}

done_dirs=' '
for h in $harnesses; do
  if [ "$h" = claude ] && [ -z "$project" ] && rdk_claude_plugin_enabled; then
    rdk_info "claude: the $RDK_PLUGIN_NAME plugin is enabled and already provides these skills; not linking them again"
    continue
  fi
  dir=$(target_dir "$h")
  case $done_dirs in *" $dir "*) continue ;; esac
  done_dirs="$done_dirs$dir "
  rdk_info "$h: skills -> $(rdk_tilde "$dir")"
  for s in $skills; do
    install_skill "$ROOT/skills/$s" "$dir/$s"
  done
done

status=0
if [ $mcp = 1 ]; then
  for h in $harnesses; do
    flags=(--harness "$h")
    [ $dry_run = 0 ] || flags+=(--dry-run)
    "$ROOT/skills/roblox-setup/scripts/mcp-config.sh" "${flags[@]}" || status=1
  done
fi

rdk_info "next: run the roblox-doctor skill (or $(rdk_tilde "$ROOT")/skills/roblox-doctor/scripts/doctor.sh) to see what is left"
exit $status
