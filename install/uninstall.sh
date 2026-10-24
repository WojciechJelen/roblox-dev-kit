#!/usr/bin/env bash
# Remove the skills that install.sh put in place. Only links into this repo and copies marked
# with this repo's .rdk-source are removed; everything else is left alone.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

usage() {
  cat <<EOF
usage: uninstall.sh --harness codex|pi|omp|claude|all [--project DIR] [--dry-run]

Removes this kit's skills from ~/.agents/skills (codex, pi, omp) and/or ~/.claude/skills (claude),
or from DIR/.agents/skills and DIR/.claude/skills with --project. MCP registrations are not removed;
the commands to remove the Blender server are printed instead. Roblox_Studio is left in place
because Studio's own Quick connect manages it.
EOF
}

harness='' project='' dry_run=0
while [ $# -gt 0 ]; do
  case $1 in
    --harness | --project)
      [ $# -ge 2 ] || rdk_die "$1 needs a value"
      if [ "$1" = --harness ]; then harness=$2; else project=$2; fi
      shift
      ;;
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
if [ "$harness" = all ]; then
  harnesses=$RDK_HARNESSES
else
  rdk_is_harness "$harness" || rdk_die "unknown harness: $harness"
  harnesses=$harness
fi
if [ -n "$project" ]; then
  [ -d "$project" ] || rdk_die "not a directory: $project"
  project=$(cd "$project" && pwd -P)
fi

skills=''
for f in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$f" ] && skills="$skills $(basename "$(dirname "$f")")"
done

removed=0 done_dirs=' '
for h in $harnesses; do
  if [ -n "$project" ]; then
    if [ "$h" = claude ]; then dir="$project/.claude/skills"; else dir="$project/.agents/skills"; fi
  else
    dir=$(rdk_harness_skills_dir "$h")
  fi
  case $done_dirs in *" $dir "*) continue ;; esac
  done_dirs="$done_dirs$dir "
  for s in $skills; do
    dest="$dir/$s"
    if [ -L "$dest" ]; then
      case $(readlink "$dest") in
        "$ROOT"/skills/*) ;;
        *) continue ;;
      esac
      rdk_info "remove  $(rdk_tilde "$dest") (link)"
      [ $dry_run = 1 ] || rm "$dest"
    elif [ -f "$dest/.rdk-source" ] && [ "$(cat "$dest/.rdk-source")" = "$ROOT" ]; then
      rdk_info "remove  $(rdk_tilde "$dest") (copy)"
      [ $dry_run = 1 ] || rm -rf "$dest"
    else
      continue
    fi
    removed=$((removed + 1))
  done
done
if [ $dry_run = 1 ]; then
  rdk_info "$removed skill install(s) would be removed"
else
  rdk_info "$removed skill install(s) removed"
fi

rdk_info ""
if [ -n "$project" ]; then
  # Per-project installs registered both servers in the project's own files (and Claude Code may
  # have the plugin at project scope); show how to remove them from there.
  in_dir="cd $(rdk_quote "$project") &&"
  rdk_info "MCP servers are still registered in the project's files. To remove them too:"
  for h in $harnesses; do
    case $h in
      claude)
        rdk_info "  $in_dir claude mcp remove -s project $RDK_STUDIO_SERVER; claude mcp remove -s project $RDK_BLENDER_SERVER"
        rdk_info "  $in_dir claude plugin uninstall $RDK_PLUGIN_NAME@$RDK_MARKETPLACE_NAME --scope project   (if the plugin was installed there)"
        ;;
      codex) rdk_info "  codex: delete [mcp_servers.$RDK_STUDIO_SERVER] and [mcp_servers.$RDK_BLENDER_SERVER] (and their .env tables) from $(rdk_tilde "$project")/.codex/config.toml" ;;
      pi) rdk_info "  $in_dir pi mcp remove $RDK_STUDIO_SERVER -l; pi mcp remove $RDK_BLENDER_SERVER -l" ;;
      omp) rdk_info "  omp: delete the \"$RDK_STUDIO_SERVER\" and \"$RDK_BLENDER_SERVER\" entries from $(rdk_tilde "$project")/.omp/mcp.json" ;;
    esac
  done
else
  rdk_info "MCP servers are still registered. To remove the Blender server too:"
  for h in $harnesses; do
    case $h in
      claude) rdk_info "  claude mcp remove -s user $RDK_BLENDER_SERVER   (not needed if it comes from the $RDK_PLUGIN_NAME plugin)" ;;
      codex) rdk_info "  codex mcp remove $RDK_BLENDER_SERVER" ;;
      pi) rdk_info "  pi mcp remove $RDK_BLENDER_SERVER" ;;
      omp) rdk_info "  omp: delete the \"$RDK_BLENDER_SERVER\" entry from $(rdk_tilde "$(rdk_omp_mcp_json)") (or use /mcp in omp)" ;;
    esac
  done
fi
