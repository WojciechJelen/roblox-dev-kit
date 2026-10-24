#!/usr/bin/env bash
# Install Rokit (if missing) and the Roblox toolchain it pins. Idempotent.
# Never edits shell rc files: it prints the PATH line for the user to add.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROKIT_VERSION="${RDK_ROKIT_VERSION:-1.2.0}"   # latest release on 2026-10-24
ROKIT_INSTALLER_URL="https://raw.githubusercontent.com/rojo-rbx/rokit/v${ROKIT_VERSION}/scripts/install.sh"
TEMPLATE_MANIFEST="$SCRIPT_DIR/../assets/template/rokit.toml"

usage() {
  cat <<EOF
usage: install-toolchain.sh [--project DIR | --global | --rokit-only] [--trust] [--dry-run]

Installs Rokit $ROKIT_VERSION when it is missing, then the tools:
  --project DIR  run 'rokit install' for DIR/rokit.toml (default: current directory if it has one)
  --global       add the kit's pinned tool set to Rokit's global manifest (when there is no project)
  --rokit-only   install Rokit and stop (e.g. to run 'rokit authenticate' before the downloads)
  --trust        record trust for the pinned tools with 'rokit trust' instead of Rokit's
                 interactive prompt (required when not running in a terminal, e.g. from an agent)
  --dry-run      print what would happen
EOF
}

mode='' project_dir='' trust=0 dry_run=0
while [ $# -gt 0 ]; do
  case $1 in
    --project)
      [ $# -ge 2 ] || rdk_die "--project needs a directory"
      mode=project project_dir=$2
      shift
      ;;
    --global) mode=global ;;
    --rokit-only) mode="rokit-only" ;;
    --trust) trust=1 ;;
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

if [ -z "$mode" ]; then
  if [ -f "$PWD/rokit.toml" ]; then mode=project project_dir=$PWD; else mode=global; fi
fi
if [ "$mode" = project ]; then
  [ -f "$project_dir/rokit.toml" ] || rdk_die "no rokit.toml in $project_dir"
  project_dir=$(cd "$project_dir" && pwd -P)
  manifest="$project_dir/rokit.toml"
else
  manifest=$TEMPLATE_MANIFEST
  [ -f "$manifest" ] || rdk_die "missing $manifest"
fi

# Every rokit call below (the installer, trust, install, add) must use the same store.
export ROKIT_ROOT="${RDK_ROKIT_BIN_DIR%/bin}"

run() {
  rdk_info "+ $(rdk_quote "$@")"
  [ $dry_run = 1 ] || "$@"
}

# --- 1. Rokit itself ---------------------------------------------------------------

rokit=$(command -v rokit 2>/dev/null || true)
if [ -z "$rokit" ] && [ -x "$RDK_ROKIT_BIN_DIR/rokit" ]; then rokit="$RDK_ROKIT_BIN_DIR/rokit"; fi

if [ -n "$rokit" ]; then
  rdk_info "rokit: $("$rokit" --version 2>/dev/null || echo present) ($(rdk_tilde "$rokit"))"
else
  for dep in curl unzip; do rdk_has "$dep" || rdk_die "$dep is required to install Rokit"; done
  rdk_info "installing Rokit $ROKIT_VERSION into $(rdk_tilde "$ROKIT_ROOT")"
  if [ $dry_run = 1 ]; then
    rdk_info "+ curl -fsSL $ROKIT_INSTALLER_URL | bash -s -- $ROKIT_VERSION   (with a throwaway HOME, see below)"
  else
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/work" "$tmp/profile"
    curl -fsSL "$ROKIT_INSTALLER_URL" -o "$tmp/install.sh"
    # `rokit self-install` (run by the official installer) appends to ~/.profile, ~/.bashrc and
    # ~/.zshenv and has no opt-out. ROKIT_ROOT keeps the real install location while HOME points
    # at a throwaway directory, so those appends land there instead of in the user's files.
    (cd "$tmp/work" && HOME="$tmp/profile" bash "$tmp/install.sh" "$ROKIT_VERSION")
  fi
  rokit="$RDK_ROKIT_BIN_DIR/rokit"
fi

# --- 2. Tools ----------------------------------------------------------------------

if [ "$mode" != rokit-only ]; then
  # Rokit asks before trusting each new tool and bails when stderr is not a terminal.
  if [ $trust = 0 ] && [ ! -t 2 ] && [ $dry_run = 0 ]; then
    rdk_die "Rokit confirms each new tool interactively and this is not a terminal. Re-run in a terminal, or pass --trust to trust the tools pinned in rokit.toml."
  fi

  tools=$(rdk_rokit_tools "$manifest")
  [ -n "$tools" ] || rdk_die "no tools in $manifest"

  # `rokit install --no-trust-check` would install without recording trust, so every later plain
  # `rokit install` (after a version bump, or the doctor's --fix) would prompt again.
  if [ $trust = 1 ]; then
    ids=()
    while IFS=$'\t' read -r alias spec; do ids+=("${spec%@*}"); done <<<"$tools"
    run "$rokit" trust "${ids[@]}"
  fi

  if [ "$mode" = project ]; then
    rdk_info "installing the tools pinned in $(rdk_tilde "$manifest")"
    (cd "$project_dir" && run "$rokit" install)
  else
    rdk_info "adding the kit's pinned tools to Rokit's global manifest"
    while IFS=$'\t' read -r alias spec; do
      if [ -e "$RDK_ROKIT_BIN_DIR/$alias" ]; then
        rdk_info "$alias: already linked in $(rdk_tilde "$RDK_ROKIT_BIN_DIR"), skipping"
        continue
      fi
      run "$rokit" add --global "$spec" "$alias"
    done <<<"$tools"
  fi
fi

# --- 3. PATH -----------------------------------------------------------------------

if ! rdk_path_has "$RDK_ROKIT_BIN_DIR"; then
  rdk_info ""
  rdk_info "Rokit's bin directory is not on PATH yet. Add this line to your shell profile"
  rdk_info "(~/.zshrc for zsh, ~/.bashrc for bash), then open a new terminal:"
  rdk_info ""
  rdk_info "  $(rdk_path_line "$RDK_ROKIT_BIN_DIR")"
fi
