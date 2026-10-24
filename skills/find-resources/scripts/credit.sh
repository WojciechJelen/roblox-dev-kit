#!/usr/bin/env bash
# Record a third-party asset in the project's CREDITS.md: one Markdown table row with the asset,
# its author, its license and where it came from. Running it again for the same asset (same name
# and source) changes nothing.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

HEADER_ROW='| Asset | Author | License | Source |'

usage() {
  cat <<EOF
usage: credit.sh --name NAME --source URL --license LICENSE [--author AUTHOR] [--file FILE]

Adds a row for one third-party asset to FILE (default: CREDITS.md in the current directory),
creating the file with its table header when needed. The row is skipped when FILE already has
one with the same name and source, so it is safe to run again.

  --name     the asset's title as its source shows it (e.g. "Brick 4")
  --source   the asset's page (e.g. https://polyhaven.com/a/brick_4)
  --license  the license, written the way licenses.md lists them: CC0, CC-BY 4.0, CC-BY 3.0,
             Pixabay Content License, Quaternius Asset License, Roblox Creator Store, ...
  --author   who made it (CC-BY requires it; default: "unknown")
  --file     the credits file (default: CREDITS.md)

Exit codes: 0 added or already present, 1 the file cannot be written, 2 usage error.
EOF
}

usage_error() {
  rdk_err "$1"
  usage >&2
  exit 2
}

name='' source_url='' license='' author='' file=CREDITS.md
while [ $# -gt 0 ]; do
  case $1 in
    --name | --source | --license | --author | --file)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      case $1 in
        --name) name=$2 ;;
        --source) source_url=$2 ;;
        --license) license=$2 ;;
        --author) author=$2 ;;
        --file) file=$2 ;;
      esac
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
  shift
done

# cell TEXT: TEXT as one Markdown table cell (no line breaks or other control characters, such as
# terminal escapes; pipes escaped; spaces trimmed).
cell() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -d '\000-\037\177' |
    sed -e 's/|/\\|/g' -e 's/^ *//' -e 's/ *$//' -e 's/   */ /g'
}

name=$(cell "$name")
source_url=$(cell "$source_url")
license=$(cell "$license")
author=$(cell "${author:-unknown}")
[ -n "$name" ] || usage_error "--name is required"
[ -n "$source_url" ] || usage_error "--source is required"
[ -n "$license" ] || usage_error "--license is required"
[ -n "$file" ] || usage_error "--file must not be empty"
[ ! -d "$file" ] || usage_error "--file is a directory: $file"

row="| $name | $author | $license | $source_url |"

if [ -f "$file" ]; then
  # Same name and source already listed (author or license spelled differently still counts).
  # ENVIRON, unlike awk -v, keeps backslashes (escaped pipes) as they are.
  if CREDIT_HEAD="| $name | " CREDIT_TAIL=" | $source_url |" awk '
      BEGIN { h = ENVIRON["CREDIT_HEAD"]; t = ENVIRON["CREDIT_TAIL"] }
      { sub(/[[:space:]]+$/, "") }
      length($0) >= length(h) + length(t) && index($0, h) == 1 && substr($0, length($0) - length(t) + 1) == t { found = 1 }
      END { exit !found }' "$file"; then
    rdk_info "already credited: $name ($source_url) in $file"
    exit 0
  fi
fi

new=1 has_header=0 needs_newline=0
if [ -s "$file" ]; then
  new=0
  grep -qxF "$HEADER_ROW" "$file" && has_header=1
  # A file that does not end in a newline would glue the new row onto its last line.
  [ -z "$(tail -c 1 "$file")" ] || needs_newline=1
fi
if [ $has_header = 1 ]; then
  # Insert after the table's last row, so a row never lands below text that follows the table.
  # (ENVIRON keeps the row's escaped pipes; awk -v would rewrite them.)
  next_file=$(mktemp "${TMPDIR:-/tmp}/credit.XXXXXX") || rdk_die "cannot create a temporary file"
  if ! CREDIT_HEADER=$HEADER_ROW CREDIT_ROW=$row awk '
    BEGIN { header = ENVIRON["CREDIT_HEADER"]; row = ENVIRON["CREDIT_ROW"] }
    { line[NR] = $0 }
    $0 == header { in_table = 1; last = NR; next }
    in_table && /^\|/ { last = NR; next }
    { in_table = 0 }
    END { for (i = 1; i <= NR; i++) { print line[i]; if (i == last) print row } }
  ' "$file" >"$next_file" || ! cat "$next_file" >"$file"; then
    rm -f "$next_file"
    rdk_die "cannot write $file"
  fi
  rm -f "$next_file"
else
  {
    [ $needs_newline = 0 ] || printf '\n'
    if [ $new = 1 ]; then
      printf '# Credits\n\n'
      printf 'Third-party assets used in this game. Keep one row per asset, and show the same list on the\n'
      printf "game's credits screen. The find-resources skill's credit.sh adds rows.\n\n"
    else
      printf '\n'
    fi
    printf '%s\n|---|---|---|---|\n%s\n' "$HEADER_ROW" "$row"
  } >>"$file" || rdk_die "cannot write $file"
fi
rdk_info "credited $name in $file"
