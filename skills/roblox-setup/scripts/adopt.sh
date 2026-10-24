#!/usr/bin/env bash
# Turn an existing project's loose scripts into a Rojo project, keeping their DataModel paths.
# Dry run by default; --apply moves the files and writes default.project.json.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TEMPLATE_DIR="$SCRIPT_DIR/../assets/template"
CONFIG_FILES="rokit.toml wally.toml selene.toml stylua.toml .luaurc .gitignore .vscode/settings.json .vscode/extensions.json"
SERVICES=" ReplicatedStorage ReplicatedFirst ServerScriptService ServerStorage StarterGui StarterPack StarterPlayer Workspace Lighting SoundService Teams TextChatService Chat "

usage() {
  cat <<EOF
usage: adopt.sh <dir> --mapping <file> [--name NAME] [--with-config] [--apply] [--force]

Mapping file: one script per line, tab-separated, '#' starts a comment:
  <source file>  <DataModel path>  <class>
  src/Factory.lua	ReplicatedStorage/RivalsFactory	ModuleScript
Paths use '/' (or '.' when there is no '/'); class is Script, LocalScript or ModuleScript.

Each file moves to src/<service>/.../<Name><suffix> (.server / .client / none, extension kept),
and default.project.json gets one node per script. Services keep instances Rojo does not know
about (\$ignoreUnknownInstances), so Studio-made content is left alone.

  --name NAME    project name (default: the directory name)
  --with-config  also copy missing tool configs from the template (never overwrites):
                 $CONFIG_FILES
  --apply        make the changes (default is a dry run that prints the plan)
  --force        replace an existing default.project.json (a .bak copy is kept)
EOF
}

dir='' mapping='' name='' with_config=0 apply=0 force=0
while [ $# -gt 0 ]; do
  case $1 in
    --mapping | --name)
      [ $# -ge 2 ] || rdk_die "$1 needs a value"
      if [ "$1" = --mapping ]; then mapping=$2; else name=$2; fi
      shift
      ;;
    --with-config) with_config=1 ;;
    --apply) apply=1 ;;
    --force) force=1 ;;
    --dry-run) apply=0 ;;
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
      [ -z "$dir" ] || rdk_die "unexpected argument: $1"
      dir=$1
      ;;
  esac
  shift
done
if [ -z "$dir" ] || [ -z "$mapping" ]; then
  usage >&2
  exit 2
fi
[ -d "$dir" ] || rdk_die "not a directory: $dir"
[ -f "$mapping" ] || rdk_die "mapping file not found: $mapping"
rdk_has jq || rdk_die "adopt.sh needs jq to write default.project.json"
dir=$(cd "$dir" && pwd -P)
name=${name:-$(basename "$dir")}
rdk_check_project_name "$name"

if [ -f "$dir/default.project.json" ] && [ $force = 0 ]; then
  rdk_die "$dir/default.project.json already exists (use --force to replace it; a .bak copy is kept)"
fi

# --- parse and validate the mapping ------------------------------------------------

rows=''      # source<TAB>target<TAB>dm path<TAB>class, one per line
targets=' '
dm_paths=$'\n'
errors=0 warnings=0 line_no=0

bad() {
  rdk_err "mapping line $line_no: $*"
  errors=$((errors + 1))
}

note() {
  rdk_warn "mapping line $line_no: $*"
  warnings=$((warnings + 1))
}

while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  line=${line%%#*}
  case $line in *[![:space:]]*) ;; *) continue ;; esac
  case $line in
    *$'\t'*) IFS=$'\t' read -r src dm class extra <<<"$line" ;;
    *) read -r src dm class extra <<<"$line" ;;
  esac
  src=$(printf '%s' "$src" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  dm=$(printf '%s' "$dm" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  class=$(printf '%s' "${class:-}" | tr -d '[:space:]')
  if [ -z "$src" ] || [ -z "$dm" ] || [ -z "$class" ] || [ -n "${extra// /}" ]; then
    bad "expected 3 columns: <source> <DataModel path> <class>"
    continue
  fi

  case $src in
    /* | ../* | */../* | *..) bad "source must be a path inside $dir: $src"; continue ;;
  esac
  src=${src#./}
  [ -f "$dir/$src" ] || { bad "source file not found: $src"; continue; }
  case $src in
    *.lua | *.luau) ;;
    *) bad "source must be a .lua or .luau file: $src"; continue ;;
  esac
  ext=.${src##*.}

  case $dm in */*) ;; *) dm=${dm//./\/} ;; esac
  dm=${dm#game/}
  dm=${dm#/}
  dm=${dm%/}
  IFS=/ read -r -a segs <<<"$dm"
  if [ ${#segs[@]} -lt 2 ]; then
    bad "DataModel path needs a service and a name: $dm"
    continue
  fi
  case $dm in *//*) bad "empty name in DataModel path: $dm"; continue ;; esac
  case "$SERVICES" in
    *" ${segs[0]} "*) ;;
    *) bad "unknown service '${segs[0]}' (expected one of:$SERVICES)"; continue ;;
  esac
  mount_len=1
  if [ "${segs[0]}" = StarterPlayer ]; then
    case ${segs[1]} in
      StarterPlayerScripts | StarterCharacterScripts) mount_len=2 ;;
      *) bad "under StarterPlayer, use StarterPlayerScripts or StarterCharacterScripts: $dm"; continue ;;
    esac
    [ ${#segs[@]} -ge 3 ] || { bad "DataModel path needs a name after ${segs[1]}: $dm"; continue; }
  fi

  case $class in
    Script) suffix=.server ;;
    LocalScript) suffix=.client ;;
    ModuleScript) suffix='' ;;
    *) bad "class must be Script, LocalScript or ModuleScript, not '$class'"; continue ;;
  esac

  # Scripts only run in some containers; a mismatch is legal but almost always a mistake.
  where=${segs[mount_len - 1]}
  case "$class:$where" in
    LocalScript:StarterPlayerScripts | LocalScript:StarterCharacterScripts | LocalScript:StarterGui | \
      LocalScript:StarterPack | LocalScript:ReplicatedFirst | LocalScript:Workspace) ;;
    LocalScript:*) note "a LocalScript in $where will not run" ;;
    Script:ServerScriptService | Script:Workspace | Script:StarterCharacterScripts | Script:StarterPack) ;;
    Script:*) note "a Script in $where will not run" ;;
  esac

  # src/<mount folder>/<containers...>/<Name><suffix><ext>
  target="src/${segs[mount_len - 1]}"
  i=$mount_len
  while [ $i -lt $((${#segs[@]} - 1)) ]; do
    target="$target/${segs[$i]}"
    i=$((i + 1))
  done
  target="$target/${segs[${#segs[@]} - 1]}$suffix$ext"

  case $targets in *" $target "*) bad "two scripts map to $target"; continue ;; esac
  if [ "$target" != "$src" ] && [ -e "$dir/$target" ]; then
    bad "$target already exists and is not the source of this line"
    continue
  fi
  case $dm_paths in *$'\n'"$dm"$'\n'*) bad "DataModel path mapped twice: $dm"; continue ;; esac
  targets="$targets$target "
  dm_paths="$dm_paths$dm"$'\n'
  rows="$rows$src"$'\t'"$target"$'\t'"$dm"$'\t'"$class"$'\n'
done <"$mapping"

# A script nested under another mapped script would need Rojo's init.lua layout.
while IFS= read -r dm; do
  [ -n "$dm" ] || continue
  case $dm_paths in *$'\n'"$dm"/*) rdk_err "$dm is mapped as a script and also has mapped children; adopt does not support that"; errors=$((errors + 1)) ;; esac
done <<<"$dm_paths"

[ -n "$rows" ] || [ $errors -gt 0 ] || rdk_die "the mapping file has no entries"
[ $errors -eq 0 ] || rdk_die "$errors problem(s) in $(rdk_tilde "$mapping"); nothing was changed"

# --- build default.project.json ------------------------------------------------------

project_json=$(printf '%s' "$rows" | jq -R -s --arg name "$name" '
  def mount_len: if .[0] == "StarterPlayer" then 2 else 1 end;
  split("\n") | map(select(length > 0) | split("\t") | {file: .[1], segs: (.[2] | split("/"))})
  | reduce .[] as $r ({name: $name, tree: {"$className": "DataModel"}};
      ($r.segs | length) as $n
      | ($r.segs | mount_len) as $m
      | reduce range(1; $n) as $i (.;
          if $i <= $m then .tree |= setpath($r.segs[0:$i] + ["$ignoreUnknownInstances"]; true)
          else .tree |= (setpath($r.segs[0:$i] + ["$className"]; "Folder")
                         | setpath($r.segs[0:$i] + ["$ignoreUnknownInstances"]; true))
          end)
      | .tree |= setpath($r.segs + ["$path"]; $r.file))')

# --- report / apply --------------------------------------------------------------------

in_git=0
if rdk_has git && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then in_git=1; fi

if [ $apply = 1 ]; then
  echo "adopting $(rdk_tilde "$dir")"
else
  echo "adopt plan for $(rdk_tilde "$dir") (dry run; re-run with --apply to make these changes)"
fi
echo

while IFS=$'\t' read -r src target dm class; do
  [ -n "$src" ] || continue
  if [ "$src" = "$target" ]; then
    printf '  keep   %s  (%s, %s)\n' "$src" "${dm//\//.}" "$class"
    continue
  fi
  printf '  move   %s -> %s  (%s, %s)\n' "$src" "$target" "${dm//\//.}" "$class"
  if [ $apply = 1 ]; then
    mkdir -p "$dir/$(dirname "$target")"
    if [ $in_git = 1 ] && git -C "$dir" ls-files --error-unmatch -- "$src" >/dev/null 2>&1; then
      git -C "$dir" mv -- "$src" "$target"
    else
      mv -- "$dir/$src" "$dir/$target"
    fi
  fi
done <<<"$rows"

if [ -f "$dir/default.project.json" ]; then
  printf '  write  default.project.json (existing file kept as default.project.json.bak)\n'
  [ $apply = 0 ] || cp "$dir/default.project.json" "$dir/default.project.json.bak"
else
  printf '  write  default.project.json\n'
fi
[ $apply = 0 ] || printf '%s\n' "$project_json" >"$dir/default.project.json"

missing_config=''
for f in $CONFIG_FILES; do
  [ -e "$dir/$f" ] || missing_config="$missing_config $f"
done
if [ -n "$missing_config" ]; then
  if [ $with_config = 1 ]; then
    for f in $missing_config; do
      if [ "$f" = .luaurc ]; then
        printf '  write  .luaurc (languageMode nonstrict)\n'
      else
        printf '  copy   %s (from the template)\n' "$f"
      fi
      [ $apply = 1 ] || continue
      mkdir -p "$dir/$(dirname "$f")"
      if [ "$f" = .luaurc ]; then
        # Existing code was not written for strict mode; opt files in one at a time with --!strict.
        printf '{\n  "languageMode": "nonstrict"\n}\n' >"$dir/$f"
      else
        sed -e "s/{{PROJECT_NAME}}/$name/g" -e "s/{{PACKAGE_NAME}}/$(rdk_package_name "$name")/g" \
          "$TEMPLATE_DIR/$f" >"$dir/$f"
      fi
    done
  else
    printf '  note   missing tool configs:%s (add them with --with-config)\n' "$missing_config"
  fi
fi

echo
echo "default.project.json:"
printf '%s\n' "$project_json"
echo
cat <<EOF
Before the first 'rojo serve': Rojo replaces each mapped script in Studio with its file, so make sure
the files hold the latest code (save any Studio-only edits into them first). Everything else in Studio,
including unmapped scripts, stays as it is.
EOF
[ $warnings -eq 0 ] || echo "$warnings warning(s) above: check the classes and locations."

if [ $apply = 1 ] && rdk_has rojo; then
  if (cd "$dir" && rojo sourcemap default.project.json -o sourcemap.json >/dev/null 2>&1); then
    echo "rojo accepted the project (sourcemap.json written)"
  else
    rdk_warn "rojo could not read the new project; run: rojo sourcemap default.project.json"
  fi
fi
