#!/usr/bin/env bash
# Search free game-asset sources that have an API (Poly Haven, ambientCG, Sketchfab, the Roblox
# Creator Store's toolbox API, and Freesound, Pixabay and Poly Pizza when their key is set), print
# the results with license, size facts and links, then the browse links for sources without an API.
# API keys are read from the environment and handed to curl in a private, temporary config file:
# they never appear in a command line, in a child's environment or in the output.
# shellcheck disable=SC2016,SC2329  # jq programs use $names literally; src_* functions are called as "src_$name"
set -euo pipefail
freesound_key=${FREESOUND_API_KEY:-} pixabay_key=${PIXABAY_API_KEY:-} polypizza_key=${POLY_PIZZA_API_KEY:-}
unset FREESOUND_API_KEY PIXABAY_API_KEY POLY_PIZZA_API_KEY

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ALL_SOURCES="roblox polyhaven ambientcg sketchfab polypizza freesound pixabay"
TYPES="model texture hdri sound music image icon all"
MAX_TRIS=20000 # Roblox's limit per mesh

usage() {
  cat <<EOF
usage: search.sh QUERY [--type TYPE] [--source a,b] [--license cc0|by|any] [--limit N]
                 [--json] [--dry-run] [--no-manual]

Searches the free asset sources that have an API and prints one row per result: source, name,
license, size facts (triangles, resolution, duration), page URL, and how to get it. Then it prints
browse links for sources that have no API (Kenney, KayKit, Quaternius, itch.io, OpenGameArt, ...).

  --type     model, texture, hdri, sound, music, image, icon or all (default all)
  --source   comma-separated subset of: ${ALL_SOURCES// /, }
  --license  cc0  CC0 only
             by   CC0, CC-BY and licenses that allow use in a game without credit (Creator Store,
                  Pixabay); the default
             any  everything, with NC, SA and ND results marked
  --limit    results per source (default 5, at most 50; with --type all, per source and kind)
  --json     print one JSON object (results, sources, browse links) instead of the table
  --dry-run  print the requests without sending anything
  --no-manual  leave out the browse links

Sources by type:
  model    roblox (toolbox API, undocumented), polyhaven, ambientcg, sketchfab, polypizza*
  texture  polyhaven, ambientcg, roblox (decals)
  hdri     polyhaven, ambientcg
  sound    roblox (Creator Store audio), freesound*      music  roblox, freesound*
  image    roblox (decals), pixabay*                     icon   roblox (decals), pixabay* (vectors)
  * only when FREESOUND_API_KEY, PIXABAY_API_KEY or POLY_PIZZA_API_KEY is set (free keys).
With Roblox Studio connected, prefer the Studio MCP tool search_asset for Creator Store assets.
Pixabay answers are cached for 24 hours (its API terms), under \${XDG_CACHE_HOME:-~/.cache}/roblox-dev-kit.

Exit codes: 0 at least one source answered, 1 none did, 2 usage error.
EOF
}

usage_error() {
  rdk_err "$1"
  usage >&2
  exit 2
}

query='' type=all sources_opt='' license=by limit=5 json=0 dry_run=0 manual=1
while [ $# -gt 0 ]; do
  case $1 in
    --type | --source | --license | --limit)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      case $1 in
        --type) type=$2 ;;
        --source) sources_opt=$2 ;;
        --license) license=$2 ;;
        --limit) limit=$2 ;;
      esac
      shift
      ;;
    --json) json=1 ;;
    --dry-run) dry_run=1 ;;
    --no-manual) manual=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) usage_error "unknown option: $1" ;;
    *)
      [ -z "$query" ] || usage_error "give the query as one argument (quote it): got '$query' and '$1'"
      query=$1
      ;;
  esac
  shift
done

query=$(printf '%s' "$query" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
[ -n "$query" ] || usage_error "no query given"
[ ${#query} -le 100 ] || usage_error "the query is longer than 100 characters"
case " $TYPES " in *" $type "*) ;; *) usage_error "unknown --type $type (expected ${TYPES// /, })" ;; esac
case $license in cc0 | by | any) ;; *) usage_error "unknown --license $license (expected cc0, by or any)" ;; esac
case $limit in '' | *[!0-9]*) usage_error "--limit must be a whole number" ;; esac
[ "$limit" -ge 1 ] && [ "$limit" -le 50 ] || usage_error "--limit must be between 1 and 50"
rdk_has jq || rdk_die "search.sh needs jq (macOS 15+ ships it; otherwise: brew install jq or apt install jq)"
[ "$dry_run" = 1 ] || rdk_has curl || rdk_die "search.sh needs curl"

# applies SOURCE: whether SOURCE has assets of the requested type.
applies() {
  case $1:$type in
    *:all) return 0 ;;
    roblox:model | roblox:texture | roblox:sound | roblox:music | roblox:image | roblox:icon) return 0 ;;
    polyhaven:model | polyhaven:texture | polyhaven:hdri) return 0 ;;
    ambientcg:model | ambientcg:texture | ambientcg:hdri) return 0 ;;
    sketchfab:model | polypizza:model) return 0 ;;
    freesound:sound | freesound:music) return 0 ;;
    pixabay:image | pixabay:icon) return 0 ;;
  esac
  return 1
}

active=''
if [ -n "$sources_opt" ]; then
  for s in $(printf '%s' "$sources_opt" | tr ',' ' '); do
    case " $ALL_SOURCES " in *" $s "*) ;; *) usage_error "unknown source $s (expected ${ALL_SOURCES// /, })" ;; esac
    if applies "$s"; then
      case " $active " in *" $s "*) ;; *) active="$active $s" ;; esac
    else
      rdk_info "$s has no assets of type $type; left out"
    fi
  done
  [ -n "$active" ] || usage_error "none of the chosen sources has assets of type $type"
else
  for s in $ALL_SOURCES; do applies "$s" && active="$active $s"; done
fi

tmp=$(umask 077 && mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '{}' >"$tmp/empty.json"
q_uri=$(rdk_uri "$query")
q_lower=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')

# --- requests ------------------------------------------------------------------------------------

# conf_quote TEXT: TEXT escaped for a double-quoted curl config value.
conf_quote() {
  local s=${1//\\/\\\\}
  printf '%s' "${s//\"/\\\"}"
}

REQ_N=0
# http_get SOURCE URL [AUTH]: GET URL; on success BODY is the file with the JSON answer. AUTH names
# the key to send (freesound, polypizza; pixabay puts its key in the URL in place of @KEY@). Keys go
# into a 0600 config file that only curl reads; printf is a builtin, so they never reach a command
# line. In a dry run the request is only recorded and BODY is an empty object. Returns 1 with
# FAIL_REASON set when the request fails, is not 2xx, or the answer is not JSON.
http_get() {
  local src=$1 url=$2 auth=${3:-} shown cfg rc=0 code
  REQ_N=$((REQ_N + 1))
  BODY="$tmp/$src.$REQ_N.json" cfg="$tmp/$src.$REQ_N.conf" shown=$url
  case $auth in pixabay) shown=${url//@KEY@/<PIXABAY_API_KEY, hidden>} ;; esac
  if [ "$dry_run" = 1 ]; then
    {
      printf 'GET %s\n' "$shown"
      case $auth in
        freesound) printf '    header Authorization: Token <FREESOUND_API_KEY, hidden>\n' ;;
        polypizza) printf '    header x-auth-token: <POLY_PIZZA_API_KEY, hidden>\n' ;;
      esac
    } >>"$tmp/$src.requests"
    BODY="$tmp/empty.json"
    return 0
  fi
  (
    umask 077
    {
      printf 'user-agent = "%s"\n' "$(conf_quote "$RDK_USER_AGENT")"
      case $auth in
        freesound) printf 'header = "Authorization: Token %s"\n' "$(conf_quote "$freesound_key")" ;;
        polypizza) printf 'header = "x-auth-token: %s"\n' "$(conf_quote "$polypizza_key")" ;;
        pixabay) printf 'url = "%s"\n' "$(conf_quote "${url//@KEY@/$pixabay_key}")" ;;
      esac
    } >"$cfg"
  )
  if [ "$auth" = pixabay ]; then
    code=$(curl -sS -m 20 -K "$cfg" -o "$BODY" -w '%{http_code}' 2>"$tmp/$src.$REQ_N.err") || rc=$?
  else
    code=$(curl -sS -m 20 -K "$cfg" -o "$BODY" -w '%{http_code}' "$url" 2>"$tmp/$src.$REQ_N.err") || rc=$?
  fi
  rm -f "$cfg"
  if [ "$rc" -ne 0 ]; then
    case $rc in
      28) FAIL_REASON="no answer within 20 s" ;;
      6 | 7) FAIL_REASON="could not connect (curl exit $rc)" ;;
      *) FAIL_REASON="request failed (curl exit $rc)" ;;
    esac
    return 1
  fi
  case $code in
    2??) ;;
    *)
      FAIL_REASON="HTTP $code"
      return 1
      ;;
  esac
  if ! jq -e 'type == "object" or type == "array"' "$BODY" >/dev/null 2>&1; then
    FAIL_REASON="the answer is not JSON"
    return 1
  fi
}

# Per-source results: $tmp/<src>.results (JSON array), $tmp/<src>.status (ok, failed, skipped or
# dry-run, then a tab and the detail), $tmp/<src>.notes (lines for the reader).
set_status() { printf '%s\t%s\n' "$2" "${3:-}" >"$tmp/$1.status"; }
note() { printf '%s\n' "$2" >>"$tmp/$1.notes"; }
# accept SOURCE: the parsed answer becomes the results when it is a JSON array; anything else (jq
# failed on a shape it did not expect) makes the source failed with an empty list, so one odd answer
# never breaks the summary.
accept() {
  local why
  if jq -e 'type == "array"' "$tmp/$1.parsed" >/dev/null 2>&1; then
    mv "$tmp/$1.parsed" "$tmp/$1.results"
    return 0
  fi
  printf '[]' >"$tmp/$1.results"
  why=$(sed -n '1{s/^jq: error ([^)]*): //;p;}' "$tmp/$1.jqerr" 2>/dev/null | cut -c1-120)
  set_status "$1" failed "unexpected answer${why:+ ($why)}"
}
finish() { # finish SOURCE: record ok (or dry-run) unless something already set the status
  [ -f "$tmp/$1.status" ] && return 0
  if [ "$dry_run" = 1 ]; then set_status "$1" dry-run; else set_status "$1" ok; fi
}

# Shared jq definitions: license names, number formatting.
JQ_DEFS='
def commas: tostring | if length > 3 then (.[:-3] | commas) + "," + .[-3:] else . end;
def clean: tostring | gsub("[[:cntrl:]]"; " ");
def norm_license:
  (. // "" | tostring) as $l | ($l | ascii_downcase) as $d
  | if $l == "" then "unknown"
    elif ($d | test("cc0|public ?domain|creative commons 0|publicdomain/zero")) then "CC0"
    elif ($d | test("noncommercial|non-commercial|by-nc")) then
      (if ($d | test("sharealike|-sa")) then "CC-BY-NC-SA" elif ($d | test("noderiv|-nd")) then "CC-BY-NC-ND" else "CC-BY-NC" end)
    elif ($d | test("sharealike|by-sa")) then "CC-BY-SA"
    elif ($d | test("noderiv|by-nd")) then "CC-BY-ND"
    elif ($d | test("attribution|cc-by|cc by|/by/")) then "CC-BY"
    else "other: " + $l end;
'

# --- sources -------------------------------------------------------------------------------------

src_polyhaven() {
  local t slugs assets
  case $type in texture) t=textures ;; model) t=models ;; hdri) t=hdris ;; *) t=all ;; esac
  # The asset list carries the metadata; /search ranks slugs (it understands synonyms).
  http_get polyhaven "https://api.polyhaven.com/assets?t=$t" || {
    set_status polyhaven failed "$FAIL_REASON"
    return 0
  }
  assets=$BODY
  if http_get polyhaven "https://api.polyhaven.com/search?q=$(rdk_uri "$q_lower")&t=$t&limit=$limit"; then
    slugs=$(jq -c '[.results[]? | .slug? | strings]' "$BODY")
  else
    note polyhaven "Poly Haven's search failed ($FAIL_REASON); matched names, tags and categories locally"
    slugs=$(jq -c --arg q "$q_lower" --argjson n "$limit" '
      ($q | split(" ") | map(select(. != ""))) as $words
      | to_entries
      | map(select(.value | type == "object")
          | select(([.key, .value.name, (.value.tags // [])[], (.value.categories // [])[]] | map(tostring) | join(" ") | ascii_downcase) as $hay
              | all($words[]; . as $w | $hay | contains($w))))
      | sort_by(-(.value.download_count // 0)) | .[:$n] | map(.key)' "$assets")
  fi
  jq --argjson slugs "$slugs" --argjson cap "$MAX_TRIS" "$JQ_DEFS"'
    . as $all
    | [$slugs[] | . as $id | ($all[$id] // empty) | select(type == "object")
      | (if .type == 0 then "hdri" elif .type == 1 then "texture" else "model" end) as $kind
      | ((.max_resolution // [0])[0] / 1024 | floor) as $k
      | {
          source: "polyhaven", id: $id, name: (.name // $id | clean), type: $kind,
          license: "CC0", licenseLabel: "CC0", author: ((.authors // {}) | keys | join(", ")),
          facts: (if $kind == "model" then "model, \(.polycount // 0 | commas) polys"
                  elif $kind == "texture" then "PBR texture, maps up to \($k)k"
                  else "HDRI, up to \($k)k" end),
          page: ("https://polyhaven.com/a/" + $id),
          download: null,
          get: (if $kind == "texture" then "fetch.sh polyhaven:" + $id
                else "download from the page" end),
          warnings: [
            (if $kind == "model" and (.polycount // 0) > $cap then "over the \($cap | commas)-triangle cap per mesh: decimate or split it in Blender (blender-to-roblox)" else empty end),
            (if $kind == "hdri" then "Roblox has no HDRI skies: a Sky takes six cube-face images" else empty end)
          ]
        }]' "$assets" >"$tmp/polyhaven.parsed" 2>"$tmp/polyhaven.jqerr" || :
  accept polyhaven
  finish polyhaven
}

src_ambientcg() {
  local filter=''
  case $type in
    texture) filter='&type=Material,Atlas,Decal' ;;
    model) filter='&type=3D-Model' ;;
    hdri) filter='&type=HDRI' ;;
  esac
  http_get ambientcg "https://ambientcg.com/api/v2/full_json?q=$q_uri$filter&limit=$limit&include=downloadData,tagData" || {
    set_status ambientcg failed "$FAIL_REASON"
    return 0
  }
  jq "$JQ_DEFS"'
    [.foundAssets[]? | select(type == "object" and (.assetId | type == "string"))
      | .assetId as $id | (.dataType // "") as $dt
      | ([.downloadFolders.default.downloadFiletypeCategories.zip.downloads[]?
          | select(.attribute == "1K-JPG" or .attribute == "LQ-1K-JPG")] | first) as $zip
      | (if ($dt | test("^(Material|Atlas|Decal|PlainTexture|Substance|Terrain)$")) then "texture"
         elif $dt == "3DModel" then "model" elif ($dt | startswith("HDRI")) then "hdri"
         else ($dt | ascii_downcase) end) as $kind
      | {
          source: "ambientcg", id: $id, name: (.displayName // $id | clean), type: $kind,
          license: "CC0", licenseLabel: "CC0", author: "ambientCG",
          facts: ($dt + (if $zip.size then ", 1K zip \($zip.size / 1048576 * 10 | round / 10) MB" else "" end)),
          page: ("https://ambientcg.com/view?id=" + $id),
          download: ($zip.downloadLink // null),
          get: (if ($dt | test("^(Material|Atlas|Decal|3DModel)$")) then "fetch.sh ambientcg:" + $id else "download from the page" end),
          warnings: [
            (if $kind == "hdri" then "Roblox has no HDRI skies: a Sky takes six cube-face images" else empty end),
            (if $dt == "Substance" then "a Substance (.sbsar) file: needs Substance tools to make maps" else empty end)
          ]
        }]' "$BODY" >"$tmp/ambientcg.parsed" 2>"$tmp/ambientcg.jqerr" || :
  accept ambientcg
  finish ambientcg
}

src_sketchfab() {
  local lic licenses answered=0 failed='' files=''
  case $license in cc0) licenses=cc0 ;; by) licenses='cc0 by' ;; *) licenses=any ;; esac
  # The license parameter takes one value (a repeated one: the last wins), so CC0 and CC-BY are two requests.
  for lic in $licenses; do
    local param="&license=$lic"
    [ "$lic" != any ] || param=''
    if http_get sketchfab "https://api.sketchfab.com/v3/search?type=models&q=$q_uri&downloadable=true$param&max_face_count=$MAX_TRIS&count=$limit"; then
      answered=1 files="$files $BODY"
    else
      failed="${failed:+$failed; }$lic: $FAIL_REASON"
    fi
  done
  if [ "$answered" = 0 ]; then
    set_status sketchfab failed "$failed"
    return 0
  fi
  [ -z "$failed" ] || note sketchfab "one Sketchfab request failed ($failed)"
  # shellcheck disable=SC2086  # one file per word
  jq -s --argjson n "$limit" "$JQ_DEFS"'
    [.[] | .results[]? | select(type == "object" and (.uid | type == "string"))]
    | reduce .[] as $r ([]; if any(.[]; .uid == $r.uid) then . else . + [$r] end) | .[:$n]
    | map({
        source: "sketchfab", id: .uid, name: (.name // .uid | clean), type: "model",
        license: (.license.label? // .license | norm_license), licenseLabel: (.license.label? // .license // "unknown" | tostring),
        author: (.user.username? // "unknown" | tostring),
        facts: ("\(.faceCount // 0 | commas) faces"
          + ([.archives[]? | .textureMaxResolution? | numbers] | max | if . then ", textures \(.) px" else "" end)),
        page: ("https://sketchfab.com/3d-models/" + .uid), # redirects to the titled page
        download: null,
        get: "log in to Sketchfab, then Download 3D Model on the page (glTF or FBX)",
        warnings: []
      })' $files >"$tmp/sketchfab.parsed" 2>"$tmp/sketchfab.jqerr" || :
  accept sketchfab
  finish sketchfab
}

src_roblox() {
  local cats cat n ids answered=0 failed='' files=''
  case $type in
    model) cats=10 ;;
    sound | music) cats=3 ;;
    texture | image | icon) cats=13 ;;
    *) cats='10 3 13' ;;
  esac
  # Ask for more than --limit: paid items (and, for sound or music, the other kind of audio) are dropped.
  n=$((limit * 2))
  [ "$n" -le 30 ] || n=30
  for cat in $cats; do
    if ! http_get roblox "https://apis.roblox.com/toolbox-service/v1/marketplace/$cat?keyword=$q_uri&limit=$n"; then
      failed="${failed:+$failed; }category $cat: $FAIL_REASON"
      continue
    fi
    ids=$(jq -r '[.data[]? | .id? | numbers | tostring] | join(",")' "$BODY")
    [ -n "$ids" ] || [ "$dry_run" = 0 ] || ids='<ids from the search above>'
    if [ -z "$ids" ]; then
      answered=1
      continue
    fi
    if http_get roblox "https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=$ids"; then
      answered=1
      cp "$BODY" "$tmp/roblox.cat$cat.json"
      files="$files $tmp/roblox.cat$cat.json"
    else
      failed="${failed:+$failed; }details for category $cat: $FAIL_REASON"
    fi
  done
  if [ "$answered" = 0 ]; then
    set_status roblox failed "$failed"
    return 0
  fi
  [ -z "$failed" ] || note roblox "some Creator Store requests failed ($failed)"
  note roblox "Creator Store results come from the toolbox API the store's website uses: undocumented, may change. With Studio connected, the Studio MCP tool search_asset is the supported way."
  if [ -z "$files" ]; then
    printf '[]' >"$tmp/roblox.results"
    finish roblox
    return 0
  fi
  # shellcheck disable=SC2086  # one file per word
  jq -s --arg want "$type" --argjson n "$limit" --argjson cap "$MAX_TRIS" "$JQ_DEFS"'
    def is_free: ((.fiatProduct | not) or .fiatProduct.isFree == true) and ((.product.price // 0) == 0);
    def audio_kind: if .asset.audioDetails.audioType == "Music" then "music" else "sound" end;
    def kind: if .asset.typeId == 10 then "model" elif .asset.typeId == 3 then audio_kind else "image" end;
    [.[] | [.data[]? | select(type == "object" and (.asset.id | type == "number"))]
      | map(select(is_free))
      | map(select($want == "all" or $want == kind or (($want == "texture" or $want == "icon") and kind == "image")))
      | .[:$n][]]
    | map(
        (.asset.id | tostring) as $id
        | (.asset.modelTechnicalDetails.objectMeshSummary.triangles // null) as $tris
        | kind as $kind
        | {
            source: "roblox", id: $id, name: (.asset.name // $id | clean), type: $kind,
            license: "Creator Store", licenseLabel: "Roblox Creator Store (free)",
            author: ((.creator.name // "unknown") + (if .creator.isVerifiedCreator then " (verified)" else "" end)),
            facts: (if $kind == "model" then (if $tris then "model, \($tris | commas) triangles in all" else "model" end)
                    elif $kind == "image" then "decal"
                    elif (.asset.duration // 0) < 1 then "\($kind), under 1 s"
                    else "\($kind), \(.asset.duration) s" end),
            page: ("https://create.roblox.com/store/asset/" + $id),
            download: null,
            assetId: $id,
            get: ("Studio MCP insert_asset with assetId " + $id + " (or the Toolbox)"),
            warnings: [
              (if .asset.hasScripts then "contains scripts: scan it before use (scan-model.sh, or script_grep after inserting)" else empty end),
              (if .creator.isVerifiedCreator != true then "creator is not verified" else empty end)
            ]
          })' $files >"$tmp/roblox.parsed" 2>"$tmp/roblox.jqerr" || :
  accept roblox
  # Count the paid items that were left out.
  # shellcheck disable=SC2086
  n=$(jq -s '[.[] | .data[]? | select(type == "object") | select(((.fiatProduct | not) or .fiatProduct.isFree == true) and ((.product.price // 0) == 0) | not)] | length' $files 2>/dev/null || echo 0)
  [ "$n" = 0 ] || note roblox "left out $n paid Creator Store item(s)"
  finish roblox
}

src_freesound() {
  local filter='' kind=sound
  if [ -z "$freesound_key" ]; then
    set_status freesound skipped "set FREESOUND_API_KEY (free key: https://freesound.org/apiv2/apply/)"
    return 0
  fi
  case $license in
    cc0) filter='license:"Creative Commons 0"' ;;
    by) filter='license:("Creative Commons 0" OR "Attribution")' ;;
  esac
  if [ "$type" = music ]; then
    kind=music
    filter="${filter:+$filter }category:Music"
  fi
  http_get freesound "https://freesound.org/apiv2/search/?query=$q_uri${filter:+&filter=$(rdk_uri "$filter")}&fields=id,name,username,license,duration,previews,url&page_size=$limit" freesound || {
    set_status freesound failed "$FAIL_REASON"
    return 0
  }
  jq --arg kind "$kind" --argjson n "$limit" "$JQ_DEFS"'
    [.results[]? | select(type == "object" and .id != null)] | .[:$n]
    | map((.id | tostring) as $id | {
        source: "freesound", id: $id, name: (.name // $id | clean), type: $kind,
        license: (.license | norm_license), licenseLabel: (.license // "unknown" | tostring),
        author: (.username // "unknown"),
        facts: ("\($kind), \((.duration // 0) * 10 | round / 10) s"),
        page: (.url // "https://freesound.org/people/\(.username)/sounds/\($id)/"),
        download: null,
        preview: (.previews["preview-hq-mp3"]? // null),
        get: "download the original on the page (free Freesound account; the API needs OAuth2 for originals)",
        warnings: []
      })' "$BODY" >"$tmp/freesound.parsed" 2>"$tmp/freesound.jqerr" || :
  accept freesound
  finish freesound
}

src_pixabay() {
  local image_type=all per_page cache_dir cache_file shown
  if [ -z "$pixabay_key" ]; then
    set_status pixabay skipped "set PIXABAY_API_KEY (free key: https://pixabay.com/api/docs/)"
    return 0
  fi
  [ "$type" != icon ] || image_type=vector
  per_page=$limit
  [ "$per_page" -ge 3 ] || per_page=3 # the API accepts 3 to 200
  local url="https://pixabay.com/api/?key=@KEY@&q=$q_uri&image_type=$image_type&per_page=$per_page&safesearch=true"
  # Pixabay's API terms: cache requests for 24 hours. The cache key is the URL without the key.
  cache_dir="${RDK_CACHE_DIR:-${XDG_CACHE_HOME:-$RDK_HOME/.cache}/roblox-dev-kit}/pixabay"
  shown=${url//@KEY@/}
  printf '%s' "$shown" >"$tmp/pixabay.cachekey"
  cache_file="$cache_dir/$(rdk_sha256 "$tmp/pixabay.cachekey").json"
  if [ "$dry_run" = 0 ] && [ -f "$cache_file" ] && [ -n "$(find "$cache_file" -mmin -1440 2>/dev/null)" ]; then
    BODY=$cache_file
    note pixabay "Pixabay answer from the 24-hour cache"
  else
    http_get pixabay "$url" pixabay || {
      set_status pixabay failed "$FAIL_REASON"
      return 0
    }
    if [ "$dry_run" = 0 ]; then
      (umask 077 && mkdir -p "$cache_dir" && cp "$BODY" "$cache_file") 2>/dev/null || true
    fi
  fi
  jq --argjson n "$limit" "$JQ_DEFS"'
    [.hits[]? | select(type == "object" and .id != null)] | .[:$n]
    | map((.id | tostring) as $id | ((.type // "") | test("vector")) as $vector | {
        source: "pixabay", id: $id,
        name: ((.tags // "") | tostring | split(", ") | .[:3] | join(", ") | clean | if . == "" then $id else . end),
        type: (if $vector then "icon" else "image" end),
        license: "Pixabay", licenseLabel: "Pixabay Content License", author: (.user // "unknown"),
        facts: ("\(.type // "image") \(.imageWidth // "?")x\(.imageHeight // "?")"),
        page: (.pageURL // null),
        download: null,
        get: "download from the page (the API image links expire after 24 hours)",
        warnings: [ (if $vector then "a vector (SVG/AI): rasterise it to PNG for Roblox" else empty end) ]
      })' "$BODY" >"$tmp/pixabay.parsed" 2>"$tmp/pixabay.jqerr" || :
  accept pixabay
  finish pixabay
}

src_polypizza() {
  if [ -z "$polypizza_key" ]; then
    set_status polypizza skipped "set POLY_PIZZA_API_KEY (free key: https://poly.pizza/settings/api)"
    return 0
  fi
  http_get polypizza "https://api.poly.pizza/v1.1/search/$q_uri" polypizza || {
    set_status polypizza failed "$FAIL_REASON"
    return 0
  }
  # The answer's shape is not documented anywhere this kit could check: read what is there.
  jq --argjson n "$limit" --argjson cap "$MAX_TRIS" "$JQ_DEFS"'
    def pick($o; keys): [keys[] as $k | $o[$k] | select(. != null and . != "")] | first;
    (if type == "array" then . else (.results // .Results // .models // .data // []) end)
    | [.[]? | objects] | .[:$n]
    | map(. as $m
        | (pick($m; ["ID", "id", "publicID", "PublicID"]) // "" | tostring) as $id
        | (pick($m; ["Tri Count", "TriCount", "triCount", "tris"])) as $tris
        | (pick($m; ["Creator", "creator", "Author", "author"])) as $creator
        | (pick($m; ["Licence", "License", "license", "licence"]) // "") as $lic
        | {
            source: "polypizza", id: $id, name: (pick($m; ["Title", "title", "Name", "name"]) // $id | clean), type: "model",
            license: ($lic | norm_license), licenseLabel: ($lic | tostring),
            author: (if ($creator | type) == "object" then ($creator.Username // $creator.username // $creator.name // "unknown") else ($creator // "unknown") end | tostring),
            facts: (if $tris then "model, \($tris | commas) triangles" else "model" end),
            page: (if $id != "" then "https://poly.pizza/m/" + $id else null end),
            download: (pick($m; ["Download", "download"])),
            get: "download the model file (GLB) from the page or the download link",
            warnings: [ (if ($tris | type) == "number" and $tris > $cap then "over the \($cap | commas)-triangle cap per mesh" else empty end) ]
          })' "$BODY" >"$tmp/polypizza.parsed" 2>"$tmp/polypizza.jqerr" || :
  accept polypizza
  finish polypizza
}

# --- browse links ----------------------------------------------------------------------------------

# Path segments for sites whose search lives in the URL path.
q_seg=$(rdk_uri "$q_lower")
oga() { # oga TYPE_ID: an OpenGameArt advanced-search URL for the query, type and license filter
  local url="https://opengameart.org/art-search-advanced?keys=$q_uri&field_art_type_tid%5B%5D=$1" id
  case $license in
    cc0) url="$url&field_art_licenses_tid%5B%5D=4" ;;
    by) for id in 4 2 17981 10310 31772; do url="$url&field_art_licenses_tid%5B%5D=$id"; done ;;
  esac
  printf '%s' "$url"
}

# game-icons.net has tag pages for a fixed set of tags; a query word that names one gets its page.
game_icons_url() {
  local w
  for w in $q_lower; do
    case $w in
      animal | arrow | blade | body | building | creature | food | gui | head | liquid | spike | symbol | tool | vehicle | weapon)
        printf 'https://game-icons.net/tags/%s.html' "$w"
        return 0
        ;;
    esac
  done
  printf 'https://game-icons.net'
}

# browse_links: "name<TAB>url<TAB>license" lines for the type.
browse_links() {
  local t types
  if [ "$type" = all ]; then types='model texture hdri sound music image icon'; else types=$type; fi
  for t in $types; do
    case $t in
      model)
        printf 'Creator Store\thttps://create.roblox.com/store\tRoblox terms; Studio Toolbox, filter free and verified creators\n'
        printf 'Kenney (3D kits)\thttps://kenney.nl/assets/category:3D\tCC0\n'
        printf 'KayKit\thttps://kaylousberg.itch.io\tCC0\n'
        printf 'Quaternius\thttps://quaternius.com\tQuaternius Asset License: games yes, redistribution no\n'
        printf 'Poly Pizza\thttps://poly.pizza/search/%s\tCC0 or CC-BY per model\n' "$q_seg"
        printf 'itch.io assets\thttps://itch.io/search?q=%s&classification=assets\tper item (see its page)\n' "$q_uri"
        printf 'OpenGameArt (3D)\t%s\tper item\n' "$(oga 10)"
        printf 'Fab (free Megascans)\thttps://www.fab.com\tFab Standard License (not CC): read it; no legacy Quixel assets\n'
        ;;
      texture)
        printf 'Poly Haven textures\thttps://polyhaven.com/textures\tCC0\n'
        printf 'ambientCG\thttps://ambientcg.com/list?q=%s\tCC0\n' "$q_uri"
        printf 'Kenney (textures)\thttps://kenney.nl/assets/category:Textures\tCC0\n'
        printf 'OpenGameArt (textures)\t%s\tper item\n' "$(oga 14)"
        printf 'Fab (free Megascans)\thttps://www.fab.com\tFab Standard License (not CC): read it; no legacy Quixel assets\n'
        ;;
      hdri)
        printf 'Poly Haven HDRIs\thttps://polyhaven.com/hdris\tCC0; Roblox skies need six cube faces\n'
        ;;
      sound)
        printf 'Creator Store audio\thttps://create.roblox.com/store\tRoblox audio library, free in experiences; Studio Toolbox > Audio\n'
        printf 'Pixabay sound effects\thttps://pixabay.com/sound-effects/search/%s/\tPixabay Content License\n' "$q_seg"
        printf 'Freesound\thttps://freesound.org/search/?q=%s\tper sound: CC0, CC-BY or CC-BY-NC\n' "$q_uri"
        printf 'Kenney (audio)\thttps://kenney.nl/assets/category:Audio\tCC0\n'
        printf 'OpenGameArt (sound effects)\t%s\tper item\n' "$(oga 13)"
        ;;
      music)
        printf 'Creator Store audio\thttps://create.roblox.com/store\tRoblox audio library, free in experiences; Studio Toolbox > Audio\n'
        printf 'Pixabay music\thttps://pixabay.com/music/search/%s/\tPixabay Content License\n' "$q_seg"
        printf 'OpenGameArt (music)\t%s\tper item\n' "$(oga 12)"
        printf 'itch.io free music\thttps://itch.io/game-assets/free/tag-music\tper item\n'
        ;;
      image)
        printf 'Unsplash\thttps://unsplash.com/s/photos/%s\tUnsplash License\n' "$q_seg"
        printf 'Pixabay images\thttps://pixabay.com/images/search/%s/\tPixabay Content License\n' "$q_seg"
        printf 'Kenney (2D)\thttps://kenney.nl/assets/category:2D\tCC0\n'
        printf 'OpenGameArt (2D)\t%s\tper item\n' "$(oga 9)"
        ;;
      icon)
        printf 'game-icons.net\t%s\tCC BY 3.0: credit required\n' "$(game_icons_url)"
        printf 'Kenney (UI, input prompts)\thttps://kenney.nl/assets/tag:interface\tCC0\n'
        printf 'Lucide\thttps://lucide.dev/icons/\tISC\n'
        printf 'Phosphor\thttps://phosphoricons.com\tMIT\n'
        printf 'Material Symbols\thttps://fonts.google.com/icons\tApache-2.0\n'
        printf 'itch.io free icons\thttps://itch.io/game-assets/free/tag-icons\tper item\n'
        ;;
    esac
  done | awk -F '\t' '!seen[$1]++'
}

# --- run -------------------------------------------------------------------------------------------

for s in $active; do
  # Each source runs in its own subshell; it reports only through its files in $tmp.
  ("src_$s") &
done
wait

# Licenses each --license value shows (null: all). bash 3.2 cannot parse a case inside $( ).
case $license in
  cc0) allowed='["CC0"]' ;;
  by) allowed='["CC0","CC-BY","Creator Store","Pixabay"]' ;;
  *) allowed=null ;;
esac

answered=0
printf '[]' >"$tmp/all.results"
printf '[]' >"$tmp/all.sources"
for s in $active; do
  [ -f "$tmp/$s.status" ] || set_status "$s" failed "the search stopped unexpectedly"
  IFS=$'\t' read -r state detail <"$tmp/$s.status" || true
  if ! jq -e 'type == "array"' "$tmp/$s.results" >/dev/null 2>&1; then
    printf '[]' >"$tmp/$s.results"
    if [ "$state" = ok ]; then state=failed detail="unexpected answer"; fi
  fi
  case $state in
    ok) answered=$((answered + 1)) ;;
    failed) rdk_warn "$s: $detail" ;;
    skipped) rdk_info "skipped $s: $detail" ;;
  esac
  notes='[]'
  [ ! -f "$tmp/$s.notes" ] || notes=$(jq -R . "$tmp/$s.notes" | jq -s .)
  requests='[]'
  [ ! -f "$tmp/$s.requests" ] || requests=$(jq -R . "$tmp/$s.requests" | jq -s .)
  jq --argjson allowed "$allowed" --slurpfile r "$tmp/$s.results" '
    . + ($r[0] | map(select($allowed == null or (.license as $l | $allowed | index($l)))
      | .warnings += (if .license | test("NC") then ["non-commercial: not in a game that earns Robux"]
                      elif .license | test("SA|ND") then ["share-alike or no-derivatives terms: avoid"]
                      elif .license | test("^(unknown|other)") then ["license unclear: read it on the page"]
                      else [] end)))' \
    "$tmp/all.results" >"$tmp/all.next" && mv "$tmp/all.next" "$tmp/all.results"
  jq --arg name "$s" --arg state "$state" --arg detail "$detail" --argjson notes "$notes" --argjson requests "$requests" \
    --argjson allowed "$allowed" --slurpfile r "$tmp/$s.results" '
    . + [{name: $name, status: $state, detail: $detail, notes: $notes, requests: $requests,
          results: ($r[0] | map(select($allowed == null or (.license as $l | $allowed | index($l)))) | length),
          hidden: ($r[0] | map(select($allowed != null and (.license as $l | $allowed | index($l) | not))) | length)}]' \
    "$tmp/all.sources" >"$tmp/all.next" && mv "$tmp/all.next" "$tmp/all.sources"
done

if [ $manual = 1 ]; then
  browse_links | jq -R 'split("\t") | {name: .[0], url: .[1], license: .[2]}' | jq -s . >"$tmp/browse.json"
else
  printf '[]' >"$tmp/browse.json"
fi

if [ $json = 1 ]; then
  jq -n --arg query "$query" --arg type "$type" --arg license "$license" --argjson limit "$limit" \
    --argjson dry "$([ "$dry_run" = 1 ] && echo true || echo false)" \
    --slurpfile results "$tmp/all.results" --slurpfile sources "$tmp/all.sources" --slurpfile browse "$tmp/browse.json" '
    {query: $query, type: $type, license: $license, limit: $limit, dryRun: $dry,
     credits: (if any($results[0][]; .source == "polyhaven") then ["Powered by Poly Haven"] else [] end),
     results: $results[0], sources: $sources[0], browse: $browse[0]}'
elif [ "$dry_run" = 1 ]; then
  printf 'dry run: nothing is sent\n'
  jq -r '.[] | select(.requests | length > 0) | "\(.name):", (.requests[] | "  " + .)' "$tmp/all.sources"
  jq -r '.[] | select(.status == "skipped") | "\(.name): skipped (\(.detail))"' "$tmp/all.sources"
else
  case $license in
    cc0) filter_text='CC0 only' ;;
    by) filter_text='CC0, CC-BY, Creator Store, Pixabay' ;;
    *) filter_text='any license' ;;
  esac
  printf 'Results for "%s" (type %s; licenses: %s)\n\n' "$query" "$type" "$filter_text"
  jq -r '
    def pad($n): tostring | if length > $n then .[:$n - 3] + "..." else . + (" " * ($n - length)) end;
    def indent: "           ";
    if length == 0 then "No results."
    else
      ("SOURCE" | pad(10)) + " " + ("NAME" | pad(32)) + " " + ("LICENSE" | pad(13)) + " " + ("FACTS" | pad(32)) + " PAGE",
      (. as $all | range(0; length) as $i | $all[$i]
        | ((.source | pad(10)) + " " + (.name | pad(32)) + " " + (.license | pad(13)) + " " + (.facts | pad(32)) + " " + (.page // "-")),
          (if .get then indent + "get: " + .get else empty end),
          (if .download then indent + "download: " + .download else empty end),
          (if .preview then indent + "preview: " + .preview else empty end),
          (.warnings[]? | indent + "! " + .),
          (if .source == "polyhaven" and ($all[$i + 1].source // "") != "polyhaven" then indent + "Powered by Poly Haven" else empty end))
    end' "$tmp/all.results"
  jq -r '
    [.[] | select(.hidden > 0) | "\(.hidden) from \(.name)"] as $h
    | [.[] | select(.status == "ok" and .results == 0 and .hidden == 0) | .name] as $none
    | (if ($none | length) > 0 then "\nNo results from: \($none | join(", "))." else empty end),
      (if ($h | length) > 0 then "\nHidden by the license filter: \($h | join(", ")) (--license any shows them)." else empty end),
      (.[] | .notes[] as $n | "note (\(.name)): \($n)")' "$tmp/all.sources"
  if [ "$(jq length "$tmp/browse.json")" -gt 0 ]; then
    printf '\nBrowse by hand (no API; check the license on each item'"'"'s page):\n'
    jq -r 'def pad($n): tostring | if length > $n then .[:$n - 3] + "..." else . + (" " * ($n - length)) end;
      .[] | "  " + (.name | pad(28)) + " " + .url + "\n  " + ("" | pad(28)) + " " + .license' "$tmp/browse.json"
  fi
fi

[ "$dry_run" = 1 ] || [ $answered -gt 0 ] || {
  rdk_err "no source answered"
  exit 1
}
exit 0
