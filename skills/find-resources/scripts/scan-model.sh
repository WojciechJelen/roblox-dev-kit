#!/usr/bin/env bash
# Scan a Roblox model (.rbxm, .rbxmx) or place (.rbxl, .rbxlx) for backdoor patterns before it is
# used or play-tested. It lists every script and reports findings by severity. Nothing in the file
# is run: Lune only parses it (scan-model.luau). Patterns and false positives: references/safety.md.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
usage: scan-model.sh FILE [--json] [--max-line N]

Lists every script in FILE (full name, class, enabled, run context, lines, bytes) and reports:
  high    require() of an asset id (also hidden in arithmetic, select, a table, a variable set
          to a number, or split over lines) or of a computed value, getfenv/setfenv,
          loadstring, string.char() chains, long \\ddd escape runs, string.reverse decoders,
          obfuscator markers (Luraph, IronBrew, MoonSec, PSU), HttpService GetAsync/PostAsync/
          RequestAsync, a LinkedSource, lines longer than --max-line characters
  medium  purchase prompts (MarketplaceService:Prompt*Purchase), TeleportService,
          InsertService:LoadAsset, AssetService:LoadAssetAsync, ScriptContext, require used as
          a value, GetAsync on an unknown object, service names built with "..", scripts inside
          a Sound, Decal, Texture, Weld, Attachment, Motor6D or value object, script names with
          leading/trailing spaces or non-ASCII characters

  --json        print one JSON object: file, instances, verdict, summary, scripts, findings
  --max-line N  lines longer than N characters count as obfuscated (default 500)

Needs Lune (lune on PATH, ~/.rokit/bin/lune, or RDK_LUNE_BIN). A scan that takes more than
RDK_SCAN_BUDGET seconds of work (default 120) stops with exit 2. Exit codes: 0 nothing found,
1 findings (verdict review or unsafe), 2 usage error, unreadable file, no Lune or scan stopped.
EOF
}

usage_error() {
  rdk_err "$1"
  usage >&2
  exit 2
}

file='' format=table max_line=500
while [ $# -gt 0 ]; do
  case $1 in
    --json) format=json ;;
    --max-line)
      [ $# -ge 2 ] || usage_error "--max-line needs a value"
      max_line=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) usage_error "unknown option: $1" ;;
    *)
      [ -z "$file" ] || usage_error "only one file per scan (got $file and $1)"
      file=$1
      ;;
  esac
  shift
done

[ -n "$file" ] || usage_error "no file given"
case $max_line in '' | *[!0-9]* | 0) usage_error "--max-line must be a positive whole number" ;; esac
[ -f "$file" ] || usage_error "not a file: $file"
[ -r "$file" ] || usage_error "cannot read $file"
ext=$(printf '%s' "${file##*.}" | tr '[:upper:]' '[:lower:]')
case $ext in
  rbxm | rbxmx | rbxl | rbxlx) ;;
  *) usage_error "expected a .rbxm, .rbxmx, .rbxl or .rbxlx file: $file" ;;
esac

if ! lune=$(rdk_find_lune); then
  rdk_err "Lune not found. It comes with the project toolchain (roblox-setup: install-toolchain.sh, then ~/.rokit/bin/lune); RDK_LUNE_BIN points at another binary."
  exit 2
fi

status=0
budget=${RDK_SCAN_BUDGET:-120}
case $budget in '' | *[!0-9]*) usage_error "RDK_SCAN_BUDGET must be a whole number of seconds" ;; esac
"$lune" run "$SCRIPT_DIR/scan-model.luau" "$file" "$format" "$max_line" "$budget" || status=$?
case $status in
  0 | 1 | 2) exit $status ;;
  *)
    rdk_err "the scan failed (lune exited with $status)"
    exit 2
    ;;
esac
