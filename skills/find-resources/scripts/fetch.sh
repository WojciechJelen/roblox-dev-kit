#!/usr/bin/env bash
# Download a CC0 texture set (or an ambientCG low-poly model) into the project, write SOURCE.json
# next to the files and record the asset in CREDITS.md. Supports polyhaven:<id> and ambientcg:<id>;
# for other sources it prints how to download by hand.
# shellcheck disable=SC2016  # jq programs use $names literally
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CC0_URL="https://creativecommons.org/publicdomain/zero/1.0/"
# Names and authors come from the APIs: control characters (terminal escapes) never pass.
JQ_CLEAN='def clean: tostring | gsub("[[:cntrl:]]"; "") | gsub("^ +| +$"; ""); '

# Largest file unpacked from a zip (ambientCG's 8K maps are far smaller); RDK_MAX_ZIP_MEMBER overrides it.
MAX_MEMBER_BYTES=${RDK_MAX_ZIP_MEMBER:-$((200 * 1024 * 1024))}

usage() {
  cat <<EOF
usage: fetch.sh SOURCE:ID [--res 1k|2k] [--out DIR] [--credits FILE] [--force] [--json]

Downloads into OUT/SOURCE/ID/ (default OUT: assets/third-party), checks each file, writes
SOURCE.json (source, id, name, authors, license, page, date, files) and adds a CREDITS.md row
with credit.sh.

  polyhaven:<id>   a Poly Haven texture: color (Diffuse), OpenGL normal (nor_gl), roughness and
                   metalness (Metal) as JPG, MD5 checked. Sets without a Metal map (not metallic,
                   in the sets checked) get the packed arm map instead (AO red, roughness green,
                   metalness blue) and a note on checking its blue channel
  ambientcg:<id>   an ambientCG material, decal or atlas (the <res>-JPG zip; keeps Color, NormalGL,
                   Roughness, Metalness, Opacity) or 3D model (the LQ-<res>-JPG zip; also keeps
                   the .obj and .mtl)
  sketchfab:, freesound:, roblox:, pixabay:, polypizza:
                   prints how to get the asset by hand (downloads need a login or Studio)

  --res      texture resolution, 1k (default; Roblox's PBR maps are at most 1024x1024) or 2k
  --out      folder for third-party assets (default assets/third-party)
  --credits  credits file (default CREDITS.md in the current directory)
  --force    download again even when the folder already has these files
  --json     print SOURCE.json plus the folder and credits file as JSON

Roblox reads OpenGL-style (tangent space) normal maps only, which is why the GL maps are used.
Exit codes: 0 downloaded or already there, 1 failed or nothing to download, 2 usage error.
EOF
}

usage_error() {
  rdk_err "$1"
  usage >&2
  exit 2
}

ref='' res=1k out=assets/third-party credits=CREDITS.md force=0 json=0
while [ $# -gt 0 ]; do
  case $1 in
    --res | --out | --credits)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      case $1 in
        --res) res=$2 ;;
        --out) out=$2 ;;
        --credits) credits=$2 ;;
      esac
      shift
      ;;
    --force) force=1 ;;
    --json) json=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) usage_error "unknown option: $1" ;;
    *)
      [ -z "$ref" ] || usage_error "one asset per run (got $ref and $1)"
      ref=$1
      ;;
  esac
  shift
done

[ -n "$ref" ] || usage_error "no asset given (SOURCE:ID, for example polyhaven:brick_4)"
case $ref in *:*) ;; *) usage_error "expected SOURCE:ID, for example polyhaven:brick_4 (got $ref)" ;; esac
src=${ref%%:*} id=${ref#*:}
case $id in
  [!A-Za-z0-9]* | *[!A-Za-z0-9_.-]* | *..*) usage_error "not a valid asset id: $id (letters, digits, _ . -, starting with a letter or digit)" ;;
esac
case $res in 1k | 2k) ;; *) usage_error "--res must be 1k or 2k" ;; esac
[ -n "$out" ] || usage_error "--out must not be empty"
case $MAX_MEMBER_BYTES in '' | *[!0-9]*) usage_error "RDK_MAX_ZIP_MEMBER must be a number of bytes" ;; esac

case $src in
  polyhaven | ambientcg) ;;
  sketchfab)
    printf 'Sketchfab downloads need a logged-in account. Open https://sketchfab.com/3d-models/%s, log in,\n' "$id"
    printf 'choose Download 3D Model (glTF or FBX), then check it with blender-to-roblox (check_mesh.py).\n'
    printf 'Record the credit: credit.sh --name "<title>" --author "<user>" --license "<license from the page>" --source https://sketchfab.com/3d-models/%s\n' "$id"
    exit 1
    ;;
  freesound)
    printf 'Freesound originals need a logged-in account (the API needs OAuth2). Open https://freesound.org/s/%s/,\n' "$id"
    printf 'log in, download, and upload it as Roblox audio (under 20 MB and 7 minutes). Credit CC-BY sounds:\n'
    printf 'credit.sh --name "<title>" --author "<user>" --license "<license>" --source https://freesound.org/s/%s/\n' "$id"
    exit 1
    ;;
  roblox)
    printf 'Creator Store assets are inserted, not downloaded: Studio MCP insert_asset with assetId %s, or the\n' "$id"
    printf "Toolbox. Scan models first: save the model to a .rbxm and run scan-model.sh, or check its scripts with script_grep.\n"
    exit 1
    ;;
  pixabay | polypizza)
    printf 'Download %s:%s from its page (the search result shows it); record it with credit.sh.\n' "$src" "$id"
    exit 1
    ;;
  *) usage_error "unknown source $src (polyhaven, ambientcg; or sketchfab, freesound, roblox, pixabay, polypizza for instructions)" ;;
esac

rdk_has jq || rdk_die "fetch.sh needs jq (macOS 15+ ships it; otherwise: brew install jq or apt install jq)"
rdk_has curl || rdk_die "fetch.sh needs curl"
[ "$src" != ambientcg ] || rdk_has unzip || rdk_die "fetch.sh needs unzip for ambientCG downloads"

dest="$out/$src/$id"
tmp=$(umask 077 && mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'user-agent = "%s"\n' "$RDK_USER_AGENT" >"$tmp/curl.conf"

# api URL: GET a JSON document into $tmp/api.json; dies with the reason when it fails.
api() {
  local code rc=0
  code=$(curl -sS -m 20 -K "$tmp/curl.conf" -o "$tmp/api.json" -w '%{http_code}' "$1" 2>"$tmp/curl.err") || rc=$?
  [ $rc -eq 0 ] || rdk_die "could not reach $1 ($(head -n 1 "$tmp/curl.err"))"
  case $code in
    2??) ;;
    404) rdk_die "no such asset: $ref ($1 answered 404)" ;;
    *) rdk_die "$1 answered HTTP $code" ;;
  esac
  jq -e 'type == "object"' "$tmp/api.json" >/dev/null 2>&1 || rdk_die "$1 did not answer with JSON"
}

# download URL FILE [SIZE] [MD5]: fetch a file, following redirects; checks size and MD5 when given.
download() {
  local code rc=0
  code=$(curl -sS -L --connect-timeout 20 -m 900 -K "$tmp/curl.conf" -o "$2" -w '%{http_code}' "$1" 2>"$tmp/curl.err") || rc=$?
  [ $rc -eq 0 ] || rdk_die "download failed: $1 ($(head -n 1 "$tmp/curl.err"))"
  case $code in 2??) ;; *) rdk_die "download failed: $1 answered HTTP $code" ;; esac
  if [ -n "${3:-}" ] && [ "$3" != null ]; then
    local got
    got=$(wc -c <"$2" | tr -d ' ')
    [ "$got" = "$3" ] || rdk_die "download of $1 is $got bytes, expected $3"
  fi
  if [ -n "${4:-}" ] && [ "$4" != null ]; then
    [ "$(rdk_md5 "$2")" = "$4" ] || rdk_die "download of $1 does not match its MD5 checksum"
  fi
}

# already_there: true when dest has a SOURCE.json for this resolution and every file it lists.
already_there() {
  local f
  [ "$force" = 0 ] && [ -f "$dest/SOURCE.json" ] || return 1
  [ "$(jq -r '.resolution // ""' "$dest/SOURCE.json" 2>/dev/null)" = "$res" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$dest/$f" ] || return 1
  done <<<"$(jq -r '.files[]?.file' "$dest/SOURCE.json")"
  return 0
}

mkdir -p "$tmp/stage"
printf '[]' >"$tmp/files.json"
add_file() { # add_file NAME MAP SURFACE_APPEARANCE_PROPERTY
  jq --arg f "$1" --arg m "$2" --arg p "$3" '. + [{file: $f, map: $m, use: $p}]' "$tmp/files.json" >"$tmp/files.next"
  mv "$tmp/files.next" "$tmp/files.json"
}

if already_there; then
  rdk_info "$ref is already in $dest at $res (--force downloads it again)"
  cp "$dest/SOURCE.json" "$tmp/source.json"
else
  case $src in
    polyhaven)
      api "https://api.polyhaven.com/info/$id"
      kind=$(jq -r '.type // -1' "$tmp/api.json")
      name=$(jq -r "$JQ_CLEAN"'.name // empty | clean' "$tmp/api.json")
      authors=$(jq -r "$JQ_CLEAN"'(.authors // {}) | keys | map(clean) | join(", ")' "$tmp/api.json")
      case $kind in
        1) ;;
        2)
          polys=$(jq -r '.polycount // "?"' "$tmp/api.json")
          rdk_err "$ref is a Poly Haven model ($polys polys); fetch.sh downloads Poly Haven textures only."
          rdk_info "Poly Haven models are dense photoscans (often far over Roblox's 20,000 triangles per mesh)."
          rdk_info "If it is worth decimating, download the FBX or glTF from https://polyhaven.com/a/$id and use blender-to-roblox."
          exit 1
          ;;
        0)
          rdk_err "$ref is an HDRI. Roblox has no HDRI skies: a Sky takes six cube-face images (SkyboxBk, Dn, Ft, Lf, Rt, Up)."
          exit 1
          ;;
        *) rdk_die "Poly Haven did not say what kind of asset $id is" ;;
      esac
      api "https://api.polyhaven.com/files/$id"
      # Sets without a Metal map get the packed arm map (AO red, roughness green, metalness blue)
      # instead, so that metalness can be checked. In the sets measured (2026-10-24) its blue channel
      # was black whenever the Metal map was missing: Poly Haven ships Metal for metallic sets.
      for pair in Diffuse:ColorMap nor_gl:NormalMap Rough:RoughnessMap Metal:MetalnessMap arm:ARM; do
        map=${pair%%:*} prop=${pair#*:}
        [ "$map" != arm ] || [ -z "$(jq -r '.[] | select(.map == "Metal") | .file' "$tmp/files.json")" ] || continue
        entry=$(jq -c --arg m "$map" --arg r "$res" '.[$m][$r].jpg // empty' "$tmp/api.json")
        if [ -z "$entry" ]; then
          case $map in
            Metal | arm) ;; # most sets are not metallic
            Diffuse) rdk_die "Poly Haven has no $res color map for $id" ;;
            *) rdk_warn "Poly Haven has no $res $map map for $id; leaving $prop empty" ;;
          esac
          continue
        fi
        url=$(jq -r '.url' <<<"$entry")
        file=$(basename "$url")
        case $file in '' | -* | *[!A-Za-z0-9_.-]*) rdk_die "unexpected file name in $url" ;; esac
        rdk_info "downloading $file"
        download "$url" "$tmp/stage/$file" "$(jq -r '.size // empty' <<<"$entry")" "$(jq -r '.md5 // empty' <<<"$entry")"
        if [ "$map" = arm ]; then
          add_file "$file" "$map" "ARM (ambient occlusion R, roughness G, metalness B): its blue channel is the MetalnessMap"
        else
          add_file "$file" "$map" "SurfaceAppearance.$prop"
        fi
      done
      page="https://polyhaven.com/a/$id"
      kind=texture
      ;;
    ambientcg)
      api "https://ambientcg.com/api/v2/full_json?id=$(rdk_uri "$id")&include=downloadData,tagData"
      jq -e --arg id "$id" '.foundAssets[0].assetId == $id' "$tmp/api.json" >/dev/null 2>&1 ||
        rdk_die "no such asset: $ref (ambientCG found nothing with that id)"
      data_type=$(jq -r '.foundAssets[0].dataType // ""' "$tmp/api.json")
      name=$(jq -r "$JQ_CLEAN"'.foundAssets[0].displayName // empty | clean' "$tmp/api.json")
      authors=ambientCG
      res_upper=$(printf '%s' "$res" | tr '[:lower:]' '[:upper:]')
      case $data_type in
        Material | Atlas | Decal) attribute="$res_upper-JPG" kind=texture ;;
        3DModel) attribute="LQ-$res_upper-JPG" kind=model ;;
        *) rdk_die "$ref is an ambientCG $data_type; fetch.sh handles materials, decals, atlases and 3D models (download it from https://ambientcg.com/view?id=$id)" ;;
      esac
      zip_entry=$(jq -c --arg a "$attribute" '[.foundAssets[0].downloadFolders.default.downloadFiletypeCategories.zip.downloads[]? | select(.attribute == $a)] | first // empty' "$tmp/api.json")
      [ -n "$zip_entry" ] || rdk_die "ambientCG has no $attribute download for $id"
      rdk_info "downloading $(jq -r '.fileName // "the zip"' <<<"$zip_entry") ($(jq -r '(.size // 0) / 1048576 * 10 | round / 10' <<<"$zip_entry") MB)"
      download "$(jq -r '.downloadLink' <<<"$zip_entry")" "$tmp/asset.zip" "$(jq -r '.size // empty' <<<"$zip_entry")"
      # Pick members by name; -j drops any folder part, so nothing lands outside the stage folder.
      # Names come from the exact listing (-Z1), type and size from the long one (-Z), in the same order.
      members=$(unzip -Z1 "$tmp/asset.zip" 2>/dev/null) || rdk_die "the ambientCG download is not a readable zip"
      details=$(unzip -Z "$tmp/asset.zip" 2>/dev/null | awk '$2 ~ /^[0-9]+\.[0-9]+$/ && NF >= 9 { print substr($1, 1, 1) "\t" $4 }')
      [ "$(printf '%s\n' "$members" | wc -l)" -eq "$(printf '%s\n' "$details" | wc -l)" ] ||
        rdk_die "could not read the ambientCG zip's file list"
      wanted='' seen=''
      while IFS= read -r m && IFS=$'\t' read -r type size <&3; do
        case $m in
          /* | ../* | */../* | *\\*)
            rdk_warn "skipping $m in the zip (its path leaves the folder)"
            continue
            ;;
        esac
        base=${m##*/}
        case $base in '' | -* | *[!A-Za-z0-9_.-]*) continue ;; esac
        case " $seen " in *" $base "*) continue ;; esac # first copy wins
        case $base in "$id"_*) ;; *) continue ;; esac # every file of the set starts with its id
        case $base in
          *_Color.jpg) prop=SurfaceAppearance.ColorMap map=Color ;;
          *_NormalGL.jpg) prop=SurfaceAppearance.NormalMap map=NormalGL ;;
          *_Roughness.jpg) prop=SurfaceAppearance.RoughnessMap map=Roughness ;;
          *_Metalness.jpg) prop=SurfaceAppearance.MetalnessMap map=Metalness ;;
          *_Opacity.jpg) prop="alpha of the ColorMap (merge into a PNG)" map=Opacity ;;
          *.obj | *.mtl) [ "$kind" = model ] || continue; prop="mesh (Studio 3D Importer or blender-to-roblox)" map=mesh ;;
          *) continue ;;
        esac
        # A link (on macOS unzip would recreate it) or a directory is never a texture.
        if [ "$type" = l ] || [ "$type" = d ]; then
          rdk_warn "skipping $m in the zip (it is a link or a folder, not a file)"
          continue
        fi
        case $size in '' | *[!0-9]*) rdk_die "could not read the size of $m in the zip" ;; esac
        [ "$size" -le "$MAX_MEMBER_BYTES" ] ||
          rdk_die "refusing $m in the zip: it unpacks to $size bytes, more than the $MAX_MEMBER_BYTES allowed per file"
        wanted="$wanted$m"$'\t'"$size"$'\n' seen="$seen $base"
        add_file "$base" "$map" "$prop"
      done <<<"$members" 3<<<"$details"
      [ -n "$wanted" ] || rdk_die "the ambientCG zip has none of the expected maps"
      [ "$kind" != texture ] || jq -e 'any(.[]; .map == "Color")' "$tmp/files.json" >/dev/null ||
        rdk_die "the ambientCG zip has no usable color map"
      # unzip -p writes a member's bytes to stdout: nothing it unpacks can become a link. Its member
      # argument is a pattern, so [, * and ? are escaped with brackets.
      while IFS=$'\t' read -r m size; do
        [ -n "$m" ] || continue
        pattern=$(printf '%s' "$m" | sed -e 's/\[/[[]/g' -e 's/\*/[*]/g' -e 's/?/[?]/g')
        unzip -p "$tmp/asset.zip" "$pattern" >"$tmp/stage/${m##*/}" 2>"$tmp/unzip.err" ||
          rdk_die "could not unpack $m ($(head -n 1 "$tmp/unzip.err"))"
        [ "$(wc -c <"$tmp/stage/${m##*/}" | tr -d ' ')" = "$size" ] || rdk_die "$m did not unpack to the size the zip lists"
      done <<<"$wanted"
      page="https://ambientcg.com/view?id=$id"
      ;;
  esac

  name=${name:-$id}
  jq -n --arg source "$src" --arg id "$id" --arg name "$name" --arg kind "$kind" --arg authors "$authors" \
    --arg page "$page" --arg res "$res" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cc0 "$CC0_URL" \
    --slurpfile files "$tmp/files.json" '
    {source: $source, id: $id, name: $name, type: $kind, authors: ($authors | split(", ")),
     license: "CC0", licenseUrl: $cc0, page: $page, resolution: $res, downloaded: $date, files: $files[0]}' >"$tmp/source.json"

  for f in "$tmp/stage"/*; do
    [ ! -L "$f" ] || rdk_die "refusing $(basename "$f"): it is a link"
  done
  # Replace the folder's previous copy only once everything downloaded: first the files the old
  # SOURCE.json lists (another resolution leaves other names), then the new set.
  mkdir -p "$dest"
  if [ -f "$dest/SOURCE.json" ]; then
    while IFS= read -r f; do
      case $f in '' | -* | *[!A-Za-z0-9_.-]* | SOURCE.json) continue ;; esac
      rm -f "$dest/$f"
    done <<<"$(jq -r '.files[]?.file? | strings' "$dest/SOURCE.json" 2>/dev/null || true)"
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mv -f "$tmp/stage/$f" "$dest/$f"
  done <<<"$(jq -r '.files[].file' "$tmp/source.json")"
  cp "$tmp/source.json" "$dest/SOURCE.json"
fi

name=$(jq -r "$JQ_CLEAN"'.name | clean' "$tmp/source.json")
page=$(jq -r '.page' "$tmp/source.json")
authors=$(jq -r "$JQ_CLEAN"'.authors | map(clean) | join(", ")' "$tmp/source.json")
credit_out=$("$SCRIPT_DIR/credit.sh" --name "$name" --source "$page" --license CC0 --author "$authors" --file "$credits" 2>&1) ||
  rdk_die "could not record the credit: $credit_out"

if [ "$json" = 1 ]; then
  jq --arg dir "$dest" --arg credits "$credits" '. + {dir: $dir, credits: $credits}' "$tmp/source.json"
else
  printf '%s "%s" (CC0) is in %s:\n' "$ref" "$name" "$dest"
  jq -r '.files[] | "  \(.file)  ->  \(.use)"' "$tmp/source.json"
  arm=$(jq -r '.files[] | select(.map == "arm") | .file' "$tmp/source.json")
  if [ -n "$arm" ]; then
    printf 'metalness: Poly Haven has no Metal map for this set, which in the sets checked means it is not\n'
    printf '  metallic: leave MetalnessMap empty. Its metalness is the blue channel of %s; to check it\n' "$arm"
    printf '  (black = not metal) or use it, split it with ImageMagick:\n'
    printf '    magick %s -channel B -separate %s\n' "$(rdk_quote "$dest/$arm")" "$(rdk_quote "$dest/${id}_metal_$res.png")"
    printf "  or in Blender with a Separate Color node (its Blue output).\n"
  fi
  printf '%s\n' "$credit_out"
  if [ "$res" = 2k ]; then
    printf 'note: Roblox uses PBR maps up to 1024x1024; scale 2k maps down before uploading.\n'
  fi
  if [ "$(jq -r .type "$tmp/source.json")" = model ]; then
    printf 'next: check the mesh against the 20,000-triangle cap (blender-to-roblox: check_mesh.py), then\n'
    printf "      import the .obj with Studio's 3D Importer; CC0 needs no credit in the game.\n"
  else
    printf 'next: upload the maps (Asphalt, or upload-asset.sh FILE --name N --type Image) and set the\n'
    printf '      SurfaceAppearance properties above on the MeshPart; CC0 needs no credit in the game.\n'
  fi
fi
