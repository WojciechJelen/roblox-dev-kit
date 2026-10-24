#!/usr/bin/env bash
# Install the kit's skills for Codex, pi, Oh My Pi or Claude Code, at user scope or into one
# project (--project), then register the MCP servers with mcp-config.sh at the same scope.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

usage() {
  cat <<EOF
usage: install.sh --harness codex|pi|omp|claude|all [--project DIR] [--no-plugin] [--copy] [--no-mcp] [--no-warm] [--dry-run]

Links every skill in $(rdk_tilde "$ROOT")/skills into:
  codex, pi, omp  ~/.agents/skills/   (all three read it)
  claude          ~/.claude/skills/   (prefer the plugin: claude plugin marketplace add $(rdk_tilde "$ROOT"))
'all' means every harness that is installed. Then runs mcp-config.sh for each harness.

  --project DIR  install into one project instead of user scope: skills into DIR/.agents/skills/,
                 MCP servers into the project's own config files (mcp-config.sh --project DIR).
                 Claude Code gets the roblox plugin at project scope: the script prints the two
                 claude plugin commands to run (they write DIR/.claude/settings.json) and registers
                 only Roblox Studio's server, because the plugin bundles Blender's.
  --no-plugin    with --project, give Claude Code loose skills in DIR/.claude/skills/ and both MCP
                 servers in DIR/.mcp.json instead of the plugin
  --copy         copy the skill folders instead of symlinking (for machines where this repo won't stay)
  --no-mcp       skip MCP registration
  --no-warm      passed to mcp-config.sh: do not pre-download the Blender MCP server
  --dry-run      print what would change
EOF
}

harness='' project='' copy=0 mcp=1 dry_run=0 plugin=1 warm=1
while [ $# -gt 0 ]; do
  case $1 in
    --harness | --project)
      [ $# -ge 2 ] || rdk_die "$1 needs a value"
      if [ "$1" = --harness ]; then harness=$2; else project=$2; fi
      shift
      ;;
    --copy) copy=1 ;;
    --no-plugin) plugin=0 ;;
    --no-mcp) mcp=0 ;;
    --no-warm) warm=0 ;;
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
  project=$(cd "$project" && pwd)
  # Plugin and MCP lookups read this project's settings and config files.
  RDK_PROJECT_DIR=$project
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

# claude_plugin_route: Claude Code in a project gets the plugin at project scope (unless --no-plugin).
claude_plugin_route() { [ -n "$project" ] && [ $plugin = 1 ]; }

done_dirs=' '
for h in $harnesses; do
  if [ "$h" = claude ] && rdk_claude_plugin_enabled; then
    rdk_info "claude: the $RDK_PLUGIN_NAME plugin is enabled and already provides these skills; not linking them again"
    continue
  fi
  if [ "$h" = claude ] && claude_plugin_route; then
    rdk_info "claude: install the $RDK_PLUGIN_NAME plugin for this project. Run these yourself (they record it in"
    rdk_info "  $(rdk_tilde "$project")/.claude/settings.json, which the project shares; --scope local keeps it to you):"
    rdk_info "  cd $(rdk_quote "$project") && claude plugin marketplace add $(rdk_quote "$ROOT") --scope project"
    rdk_info "  cd $(rdk_quote "$project") && claude plugin install $RDK_PLUGIN_NAME@$RDK_MARKETPLACE_NAME --scope project"
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
    [ -z "$project" ] || flags+=(--project "$project")
    # The plugin brings the Blender server; only Studio's goes into the project's .mcp.json.
    if [ "$h" = claude ] && claude_plugin_route; then flags+=(--server "$RDK_STUDIO_SERVER"); fi
    [ $warm = 1 ] || flags+=(--no-warm)
    [ $dry_run = 0 ] || flags+=(--dry-run)
    "$ROOT/skills/roblox-setup/scripts/mcp-config.sh" "${flags[@]}" || status=1
  done
fi

rdk_info "next: run the roblox-doctor skill (or $(rdk_tilde "$ROOT")/skills/roblox-doctor/scripts/doctor.sh) to see what is left"
exit $status
