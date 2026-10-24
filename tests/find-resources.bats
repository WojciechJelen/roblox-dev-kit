#!/usr/bin/env bats
# find-resources: search.sh, fetch.sh and credit.sh against a fake curl that replays answers captured
# from the real APIs (tests/fixtures/find-resources, see its README), and scan-model.sh on hand-written
# models with the real Lune (skipped without it). No network.

load helpers

FS_KEY="fs-SECRET-key-1"
PX_KEY="px-SECRET-key-2"
PP_KEY="pp-SECRET-key-3"

setup() {
  setup_fake_machine
  FIX="$KIT_ROOT/tests/fixtures/find-resources"
  SEARCH="$FIND_SCRIPTS/search.sh"
  FETCH="$FIND_SCRIPTS/fetch.sh"
  CREDIT="$FIND_SCRIPTS/credit.sh"
  SCAN="$FIND_SCRIPTS/scan-model.sh"
  unset FREESOUND_API_KEY PIXABAY_API_KEY POLY_PIZZA_API_KEY CURL_FAIL CURL_TIMEOUT CURL_BADJSON RDK_LUNE_BIN
  mkdir -p "$FAKE/routes"
  # The fake logs its argv (calls.log), each URL (urls.log), each config file's mode and contents,
  # and any API key in its environment (leaks.log). It answers by URL from the fixtures; CURL_FAIL,
  # CURL_TIMEOUT and CURL_BADJSON (space-separated URL parts) make matching requests fail.
  cat >"$FAKE/bin/curl" <<EOF
#!/usr/bin/env bash
dir="$FAKE" fix="$FIX"
EOF
  cat >>"$FAKE/bin/curl" <<'EOF'
{ printf 'curl'; printf ' [%s]' "$@"; echo; } >>"$dir/calls.log"
out='' cfg='' url=''
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    -K | --config) cfg=$2; shift ;;
    -w | -m | --connect-timeout) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
if [ -n "$cfg" ]; then
  echo "$(ls -l "$cfg" | cut -c1-10) $cfg" >>"$dir/configs.log"
  cat "$cfg" >>"$dir/config-contents.log"
  u=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
  [ -z "$u" ] || url=$u
fi
for v in FREESOUND_API_KEY PIXABAY_API_KEY POLY_PIZZA_API_KEY; do
  [ -z "${!v:-}" ] || echo "curl saw $v" >>"$dir/leaks.log"
done
echo "$url" >>"$dir/urls.log"
for p in ${CURL_TIMEOUT:-}; do case $url in *"$p"*) echo "curl: (28) Operation timed out" >&2; printf 000; exit 28 ;; esac; done
for p in ${CURL_FAIL:-}; do case $url in *"$p"*) printf 'unavailable' >"$out"; printf 503; exit 0 ;; esac; done
for p in ${CURL_BADJSON:-}; do case $url in *"$p"*) printf '<html>' >"$out"; printf 200; exit 0 ;; esac; done
f=''
case $url in
  *api.polyhaven.com/search*t=models*) f=polyhaven-search-models.json ;;
  *api.polyhaven.com/search*) f=polyhaven-search-textures.json ;;
  *api.polyhaven.com/assets*t=models*) f=polyhaven-assets-models.json ;;
  *api.polyhaven.com/assets*) f=polyhaven-assets-textures.json ;;
  *api.polyhaven.com/info/*) f="$dir/routes/polyhaven-info-${url##*/}.json" ;;
  *api.polyhaven.com/files/brick_4) f="$dir/routes/polyhaven-files-brick_4.json" ;;
  *dl.polyhaven.org/*) printf 'fake %s' "${url##*/}" >"$out"; printf 200; exit 0 ;;
  *ambientcg.com/api/v2/full_json*id=Bricks100*) f="$dir/routes/ambientcg-asset-Bricks100.json" ;;
  *ambientcg.com/api/v2/full_json*id=*) f=empty-ambientcg ;;
  *ambientcg.com/api/v2/full_json*) f=ambientcg-search-texture.json ;;
  *ambientcg.com/get?file=Bricks100_1K-JPG.zip) f="$dir/routes/Bricks100_1K-JPG.zip" ;;
  *api.sketchfab.com/v3/search*license=cc0*) f=sketchfab-cc0.json ;;
  *api.sketchfab.com/v3/search*) f=sketchfab-by.json ;;
  *toolbox-service/v1/marketplace/10*) f=roblox-marketplace-10.json ;;
  *toolbox-service/v1/marketplace/3*) f=roblox-marketplace-3.json ;;
  *toolbox-service/v1/marketplace/13*) f=roblox-marketplace-13.json ;;
  *toolbox-service/v1/items/details*124879875206878*) f=roblox-details-10.json ;;
  *toolbox-service/v1/items/details*139162107746216*) f=roblox-details-3.json ;;
  *toolbox-service/v1/items/details*2182197135*) f=roblox-details-13.json ;;
  *freesound.org/apiv2/search/*) f=freesound-search.json ;;
  *pixabay.com/api/*) f=pixabay-search.json ;;
  *api.poly.pizza/v1.1/search/*) f=polypizza-search.json ;;
esac
case $f in
  '') echo "curl: (6) fake curl has no answer for $url" >&2; printf 000; exit 6 ;;
  empty-ambientcg) printf '{"numberOfResults":0,"foundAssets":[]}' >"$out" ;;
  /*) [ -f "$f" ] || { printf '{"error":"not found"}' >"$out"; printf 404; exit 0; }; cp "$f" "$out" ;;
  *) cp "$fix/$f" "$out" ;;
esac
printf 200
EOF
  chmod +x "$FAKE/bin/curl"
  [ -z "$REAL_PYTHON" ] || ln -sf "$REAL_PYTHON" "$FAKE/bin/python3"
}

# url_calls PATTERN: how many requests went to URLs containing PATTERN.
url_calls() { if [ -f "$FAKE/urls.log" ]; then grep -cF -- "$1" "$FAKE/urls.log" || true; else echo 0; fi; }

# polyhaven_routes: /info answers for brick_4 and pine_tree_01, and a /files answer whose sizes and
# MD5s match what the fake serves for each file ("fake <file name>").
polyhaven_routes() {
  local url content sums='{}'
  cp "$FIX/polyhaven-info-brick_4.json" "$FAKE/routes/polyhaven-info-brick_4.json"
  jq '.pine_tree_01' "$FIX/polyhaven-assets-models.json" >"$FAKE/routes/polyhaven-info-pine_tree_01.json"
  while IFS= read -r url; do
    content="fake ${url##*/}"
    printf '%s' "$content" >"$BATS_TEST_TMPDIR/sum"
    sums=$(jq --arg u "$url" --argjson s "${#content}" --arg m "$(rdk_md5_of "$BATS_TEST_TMPDIR/sum")" '. + {($u): {size: $s, md5: $m}}' <<<"$sums")
  done <<<"$(jq -r '.. | objects | select(has("url") and has("md5")) | .url' "$FIX/polyhaven-files-brick_4.json")"
  jq --argjson sums "$sums" '(.. | objects | select(has("url") and has("md5"))) |= (. + $sums[.url])' \
    "$FIX/polyhaven-files-brick_4.json" >"$FAKE/routes/polyhaven-files-brick_4.json"
}

rdk_md5_of() { if command -v md5sum >/dev/null; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }

# ambientcg_routes: a small zip shaped like ambientCG's 1K-JPG download (plus a file whose path
# tries to leave the folder), and the asset answer with that zip's size.
ambientcg_routes() {
  [ -n "$REAL_PYTHON" ] || skip "python3 is needed to build the test zip"
  "$REAL_PYTHON" -I -c '
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
for m in ["Color.jpg", "NormalGL.jpg", "NormalDX.jpg", "Roughness.jpg", "AmbientOcclusion.jpg", "Displacement.jpg"]:
    z.writestr("Bricks100_1K-JPG_" + m, "fake " + m)
z.writestr("Bricks100_1K-JPG.usdc", "usd")
z.writestr("Bricks100.png", "preview")
z.writestr("../Bricks100_1K-JPG_Metalness.jpg", "escape attempt")
z.close()' "$FAKE/routes/Bricks100_1K-JPG.zip"
  local size
  size=$(wc -c <"$FAKE/routes/Bricks100_1K-JPG.zip" | tr -d ' ')
  jq --argjson s "$size" '(.foundAssets[0].downloadFolders.default.downloadFiletypeCategories.zip.downloads[] | select(.attribute == "1K-JPG") | .size) = $s' \
    "$FIX/ambientcg-asset-Bricks100.json" >"$FAKE/routes/ambientcg-asset-Bricks100.json"
}

# --- search.sh ---------------------------------------------------------------------------------

@test "search: every keyless source is parsed into the table, with Poly Haven's credit line" {
  run bash "$SEARCH" "pine tree" --type model --no-manual
  [ "$status" -eq 0 ]
  [[ "$output" == *"Results for \"pine tree\" (type model"* ]]
  # Roblox: the paid set is left out, the free ones carry triangles, scripts are flagged.
  [[ "$output" == *"Realistic Pine Tree"*"Creator Store"*"model, 10,048 triangles in all"*"https://create.roblox.com/store/asset/5392132809"* ]]
  [[ "$output" == *"get: Studio MCP insert_asset with assetId 5392132809"* ]]
  [[ "$output" != *"Stylized Pine Tree Set"* ]]
  [[ "$output" == *"left out 1 paid Creator Store item(s)"* ]]
  [[ "$output" == *"Tree House"*"contains scripts: scan it before use"* ]]
  [[ "$output" == *"undocumented, may change"* ]]
  # Poly Haven: polycount over the cap gets the Blender hint; the credit line follows its rows.
  [[ "$output" == *"Pine Tree 01"*"CC0"*"model, 17,427,094 polys"*"https://polyhaven.com/a/pine_tree_01"* ]]
  [[ "$output" == *"over the 20,000-triangle cap per mesh"* ]]
  [[ "$output" == *"Powered by Poly Haven"* ]]
  # ambientCG answered (texture fixture) and Sketchfab: CC0 first, then CC-BY.
  [[ "$output" == *"ambientcg"*"Bricks 097"*"CC0"* ]]
  [[ "$output" == *"sketchfab"*"CC0"*"15,526 faces, textures 2048 px"* ]]
  [[ "$output" == *"sketchfab  Pine tree"*"CC-BY"*"2,173 faces"* ]]
  [[ "$output" == *"log in to Sketchfab, then Download 3D Model"* ]]
  [[ "$output" == *"skipped polypizza: set POLY_PIZZA_API_KEY"* ]]
  [ "$(url_calls api.poly.pizza)" -eq 0 ]
}

@test "search: --json is valid and carries results, sources, credits and browse links" {
  run --separate-stderr bash "$SEARCH" "brick wall" --type texture --json
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
  [ "$(jq -r '.credits[0]' <<<"$output")" = "Powered by Poly Haven" ]
  [ "$(jq -r '[.results[] | select(.source == "polyhaven")][0].id' <<<"$output")" = dark_brick_wall ]
  [ "$(jq -r '[.results[] | select(.source == "polyhaven")][0].get' <<<"$output")" = "fetch.sh polyhaven:dark_brick_wall" ]
  [ "$(jq -r '[.results[] | select(.source == "ambientcg")][0].download' <<<"$output")" = "https://ambientcg.com/get?file=Bricks097_1K-JPG.zip" ]
  [ "$(jq -r '[.results[] | select(.source == "roblox")][0].type' <<<"$output")" = image ]
  [ "$(jq -r '[.sources[] | select(.status == "ok") | .name] | sort | join(",")' <<<"$output")" = ambientcg,polyhaven,roblox ]
  [ "$(jq -r '.browse | map(.name) | index("Kenney (textures)") != null' <<<"$output")" = true ]
  [ "$(jq -r '.results | map(.license) | unique | join(",")' <<<"$output")" = "CC0,Creator Store" ]
}

@test "search: the default license filter hides NC; cc0 keeps CC0 only; any shows and marks the rest" {
  export FREESOUND_API_KEY=$FS_KEY
  run --separate-stderr bash "$SEARCH" jump --type sound --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.results[] | select(.source == "freesound") | .license] | join(",")' <<<"$output")" = "CC0,CC-BY" ]
  [ "$(jq -r '.sources[] | select(.name == "freesound") | .hidden' <<<"$output")" = 1 ]
  grep -qF 'filter=license%3A%28%22Creative%20Commons%200%22%20OR%20%22Attribution%22%29' "$FAKE/urls.log"

  run --separate-stderr bash "$SEARCH" jump --type sound --json --license cc0
  [ "$(jq -r '.results | map(.license) | unique | join(",")' <<<"$output")" = CC0 ]
  [ "$(jq -r '.sources[] | select(.name == "roblox") | .hidden' <<<"$output")" = 3 ]

  run --separate-stderr bash "$SEARCH" jump --type sound --json --license any
  [ "$(jq -r '[.results[] | select(.license == "CC-BY-NC")][0].warnings[0]' <<<"$output")" = "non-commercial: not in a game that earns Robux" ]
  [ "$(tail -n 1 "$FAKE/urls.log" | grep -c 'filter=')" -eq 0 ]
}

@test "search: Sketchfab asks once per license, and once without a license for --license any" {
  run bash "$SEARCH" tree --type model --source sketchfab
  [ "$status" -eq 0 ]
  [ "$(url_calls 'license=cc0')" -eq 1 ]
  [ "$(url_calls 'license=by&')" -eq 1 ]
  grep -qF 'max_face_count=20000' "$FAKE/urls.log"
  rm "$FAKE/urls.log"
  run bash "$SEARCH" tree --type model --source sketchfab --license any
  [ "$(url_calls 'license=')" -eq 0 ]
  [ "$(url_calls api.sketchfab.com)" -eq 1 ]
}

@test "search: --dry-run sends nothing and hides the keys" {
  export FREESOUND_API_KEY=$FS_KEY PIXABAY_API_KEY=$PX_KEY POLY_PIZZA_API_KEY=$PP_KEY
  run bash "$SEARCH" "pine tree" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run: nothing is sent"* ]]
  [[ "$output" == *"GET https://api.polyhaven.com/assets?t=all"* ]]
  [[ "$output" == *"GET https://api.polyhaven.com/search?q=pine%20tree&t=all&limit=5"* ]]
  [[ "$output" == *"GET https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=<ids from the search above>"* ]]
  [[ "$output" == *"key=<PIXABAY_API_KEY, hidden>"* ]]
  [[ "$output" == *"header Authorization: Token <FREESOUND_API_KEY, hidden>"* ]]
  [[ "$output" == *"header x-auth-token: <POLY_PIZZA_API_KEY, hidden>"* ]]
  [[ "$output" != *"SECRET"* ]]
  [ ! -e "$FAKE/calls.log" ]
  run --separate-stderr bash "$SEARCH" "pine tree" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .dryRun <<<"$output")" = true ]
  [ "$(jq -r '[.sources[].status] | unique | join(",")' <<<"$output")" = dry-run ]
  [ ! -e "$FAKE/calls.log" ]
}

@test "search: a missing key is one skipped line and the run still succeeds" {
  run bash "$SEARCH" jump --type sound
  [ "$status" -eq 0 ]
  [ "$(grep -c 'skipped freesound: set FREESOUND_API_KEY' <<<"$output")" -eq 1 ]
  [[ "$output" == *"Jump Sound"*"sound, 1 s"* ]]
  [[ "$output" == *"Classic Roblox Jump"*"sound, under 1 s"* ]]
  [ "$(url_calls freesound.org)" -eq 0 ]
}

@test "search: a failing source is a warning; when every source fails the run exits 1" {
  CURL_FAIL=api.sketchfab.com CURL_BADJSON=ambientcg.com run bash "$SEARCH" tree --type model --no-manual
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: sketchfab: cc0: HTTP 503; by: HTTP 503"* ]]
  [[ "$output" == *"warning: ambientcg: the answer is not JSON"* ]]
  [[ "$output" == *"Realistic Pine Tree"* ]]
  CURL_TIMEOUT="apis.roblox.com api.polyhaven.com ambientcg.com api.sketchfab.com" run bash "$SEARCH" tree --type model
  [ "$status" -eq 1 ]
  [[ "$output" == *"warning: polyhaven: no answer within 20 s"* ]]
  [[ "$output" == *"no source answered"* ]]
  [[ "$output" == *"Browse by hand"*"https://kenney.nl/assets/category:3D"* ]]
  [[ "$output" == *"Fab (free Megascans)"*"Fab Standard License (not CC)"* ]]
}

@test "search: Poly Haven's search failing falls back to matching names and tags locally" {
  CURL_FAIL=api.polyhaven.com/search run bash "$SEARCH" "brick wall" --type texture --source polyhaven
  [ "$status" -eq 0 ]
  [[ "$output" == *"matched names, tags and categories locally"* ]]
  [[ "$output" == *"Brick Wall 02"* ]]
  [[ "$output" == *"Powered by Poly Haven"* ]]
}

@test "search: queries with spaces and & are URL-encoded" {
  run bash "$SEARCH" "Rock & Stone" --type texture --no-manual
  grep -qF 'https://ambientcg.com/api/v2/full_json?q=Rock%20%26%20Stone&type=Material,Atlas,Decal&limit=5' "$FAKE/urls.log"
  grep -qF 'https://api.polyhaven.com/search?q=rock%20%26%20stone&t=textures&limit=5' "$FAKE/urls.log"
  grep -qF 'marketplace/13?keyword=Rock%20%26%20Stone&limit=10' "$FAKE/urls.log"
  run bash "$SEARCH" "Rock & Stone" --type sound --source roblox
  [[ "$output" == *"https://pixabay.com/sound-effects/search/rock%20%26%20stone/"* ]]
  [[ "$output" == *"https://freesound.org/search/?q=Rock%20%26%20Stone"* ]]
}

@test "search: keys never appear in arguments, environments or output; config files are private and removed" {
  export FREESOUND_API_KEY=$FS_KEY PIXABAY_API_KEY=$PX_KEY POLY_PIZZA_API_KEY=$PP_KEY
  # jq runs in every source; its wrapper records any key it sees in its environment.
  rm "$FAKE/bin/jq"
  printf '#!/usr/bin/env bash\nfor v in FREESOUND_API_KEY PIXABAY_API_KEY POLY_PIZZA_API_KEY; do [ -z "${!v:-}" ] || echo "jq saw $v" >>"%s/leaks.log"; done\nexec "%s" "$@"\n' \
    "$FAKE" "$REAL_JQ" >"$FAKE/bin/jq"
  chmod +x "$FAKE/bin/jq"
  FREESOUND_API_KEY=probe jq -n 1 >/dev/null # the wrapper itself notices a key
  [ -s "$FAKE/leaks.log" ]
  rm "$FAKE/leaks.log"
  run bash "$SEARCH" "pine tree" --type all
  [ "$status" -eq 0 ]
  result=$output
  [ ! -e "$FAKE/leaks.log" ]
  run ! grep -qE 'SECRET' "$FAKE/calls.log"
  [[ "$result" != *"SECRET"* ]]
  # The keys did reach curl, through its config files.
  grep -qxF "header = \"Authorization: Token $FS_KEY\"" "$FAKE/config-contents.log"
  grep -qxF "header = \"x-auth-token: $PP_KEY\"" "$FAKE/config-contents.log"
  grep -qF "url = \"https://pixabay.com/api/?key=$PX_KEY&q=pine%20tree&image_type=all" "$FAKE/config-contents.log"
  grep -qF 'user-agent = "roblox-dev-kit/' "$FAKE/config-contents.log"
  run ! grep -v '^-rw------- ' "$FAKE/configs.log"
  while read -r _ cfg; do [ ! -e "$cfg" ]; done <"$FAKE/configs.log"
  # Keyed sources parsed: Freesound sound, Pixabay images, Poly Pizza models (64k triangles flagged).
  [[ "$result" == *"freesound  fixture jump cc0.wav"*"sound, 0.4 s"* ]]
  [[ "$result" == *"pixabay    blossom, bloom, flower"*"Pixabay"*"photo 4000x2250"* ]]
  [[ "$result" == *"a vector (SVG/AI): rasterise it to PNG for Roblox"* ]]
  [[ "$result" == *"polypizza  Fixture Pine"*"CC-BY"*"model, 1,200 triangles"*"https://poly.pizza/m/fixture01"* ]]
  [[ "$result" == *"download: https://static.poly.pizza/fixture02.glb"* ]]
}

@test "search: Pixabay answers are cached for 24 hours, without the key" {
  export PIXABAY_API_KEY=$PX_KEY
  run bash "$SEARCH" flower --type image --source pixabay
  [ "$status" -eq 0 ]
  run bash "$SEARCH" flower --type image --source pixabay
  [ "$status" -eq 0 ]
  [[ "$output" == *"from the 24-hour cache"* ]]
  [ "$(url_calls pixabay.com/api)" -eq 1 ]
  run ! grep -rqF "$PX_KEY" "$FAKE/home/.cache/roblox-dev-kit/pixabay"
  [ "$(ls -ld "$FAKE/home/.cache/roblox-dev-kit/pixabay" | cut -c1-10)" = drwx------ ]
}

@test "search: icons point at the icon sets and a matching game-icons.net tag page" {
  run bash "$SEARCH" "weapon slot" --type icon --source roblox
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://game-icons.net/tags/weapon.html"* ]]
  [[ "$output" == *"CC BY 3.0: credit required"* ]]
  [[ "$output" == *"https://lucide.dev/icons/"*"ISC"* ]]
  [[ "$output" == *"https://kenney.nl/assets/tag:interface"* ]]
}

@test "search: usage errors exit 2 before any request" {
  run bash "$SEARCH"
  [ "$status" -eq 2 ]
  run bash "$SEARCH" tree --type car
  [ "$status" -eq 2 ]
  run bash "$SEARCH" tree --license nc
  [ "$status" -eq 2 ]
  run bash "$SEARCH" tree --limit 0
  [ "$status" -eq 2 ]
  run bash "$SEARCH" tree --source nowhere
  [ "$status" -eq 2 ]
  run bash "$SEARCH" tree --type sound --source polyhaven
  [ "$status" -eq 2 ]
  [[ "$output" == *"none of the chosen sources has assets of type sound"* ]]
  run bash "$SEARCH" pine tree
  [ "$status" -eq 2 ]
  [[ "$output" == *"quote it"* ]]
  [ ! -e "$FAKE/calls.log" ]
}

@test "search: runs under /bin/bash (3.2 on macOS)" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run /bin/bash "$SEARCH" "brick wall" --type texture --no-manual
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dark Brick Wall"* ]]
}

# --- fetch.sh ----------------------------------------------------------------------------------

@test "fetch: a Poly Haven texture lands with SOURCE.json and a credit, and a rerun downloads nothing" {
  polyhaven_routes
  run bash "$FETCH" polyhaven:brick_4
  [ "$status" -eq 0 ]
  d="$FAKE/home/assets/third-party/polyhaven/brick_4"
  [ "$(cat "$d/brick_4_diff_1k.jpg")" = "fake brick_4_diff_1k.jpg" ]
  [ -f "$d/brick_4_nor_gl_1k.jpg" ]
  [ -f "$d/brick_4_rough_1k.jpg" ]
  [ ! -e "$d/brick_4_nor_dx_1k.jpg" ] # Roblox reads OpenGL normal maps
  [ "$(jq -r '.license, .name, .page, .resolution, (.authors | join(","))' "$d/SOURCE.json" | tr '\n' ' ')" = \
    "CC0 Brick 4 https://polyhaven.com/a/brick_4 1k Rob Tuytel " ]
  [ "$(jq -r '[.files[] | .use] | join(",")' "$d/SOURCE.json")" = \
    "SurfaceAppearance.ColorMap,SurfaceAppearance.NormalMap,SurfaceAppearance.RoughnessMap" ]
  grep -qxF '| Brick 4 | Rob Tuytel | CC0 | https://polyhaven.com/a/brick_4 |' "$FAKE/home/CREDITS.md"
  [ "$(url_calls dl.polyhaven.org)" -eq 3 ]
  [[ "$output" == *"brick_4_diff_1k.jpg  ->  SurfaceAppearance.ColorMap"* ]]
  run bash "$FETCH" polyhaven:brick_4
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in"* ]]
  [ "$(url_calls dl.polyhaven.org)" -eq 3 ]
  [ "$(grep -c 'Brick 4' "$FAKE/home/CREDITS.md")" -eq 1 ]
  run --separate-stderr bash "$FETCH" polyhaven:brick_4 --res 2k --out "$FAKE/game/assets" --credits "$FAKE/game/CREDITS.md" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .dir <<<"$output")" = "$FAKE/game/assets/polyhaven/brick_4" ]
  [ -f "$FAKE/game/assets/polyhaven/brick_4/brick_4_diff_2k.jpg" ]
  [ -f "$FAKE/game/CREDITS.md" ]
}

@test "fetch: a checksum mismatch fails and leaves no files" {
  polyhaven_routes
  jq '.Rough["1k"].jpg.md5 = "0000"' "$FAKE/routes/polyhaven-files-brick_4.json" >"$FAKE/routes/x" && mv "$FAKE/routes/x" "$FAKE/routes/polyhaven-files-brick_4.json"
  run bash "$FETCH" polyhaven:brick_4
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match its MD5 checksum"* ]]
  [ ! -e "$FAKE/home/assets/third-party/polyhaven/brick_4" ]
  [ ! -e "$FAKE/home/CREDITS.md" ]
}

@test "fetch: Poly Haven models and unknown ids are refused with the reason" {
  polyhaven_routes
  run bash "$FETCH" polyhaven:pine_tree_01
  [ "$status" -eq 1 ]
  [[ "$output" == *"Poly Haven model (17427094 polys)"* ]]
  run bash "$FETCH" polyhaven:nothing_here
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such asset: polyhaven:nothing_here"* ]]
  run bash "$FETCH" ambientcg:Nothing001
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambientCG found nothing"* ]]
}

@test "fetch: an ambientCG zip is unpacked to the Roblox maps only, nothing outside the folder" {
  ambientcg_routes
  run bash "$FETCH" ambientcg:Bricks100 --out "$FAKE/home/game/assets"
  [ "$status" -eq 0 ]
  d="$FAKE/home/game/assets/ambientcg/Bricks100"
  [ "$(ls "$d" | tr '\n' ' ')" = "Bricks100_1K-JPG_Color.jpg Bricks100_1K-JPG_NormalGL.jpg Bricks100_1K-JPG_Roughness.jpg SOURCE.json " ]
  [[ "$output" == *"skipping ../Bricks100_1K-JPG_Metalness.jpg"* ]]
  [ ! -e "$FAKE/home/game/assets/ambientcg/Bricks100_1K-JPG_Metalness.jpg" ]
  [ "$(find "$FAKE" -name '*Metalness*' | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(jq -r '.files[] | select(.map == "NormalGL") | .use' "$d/SOURCE.json")" = SurfaceAppearance.NormalMap ]
  grep -qxF '| Bricks 100 | ambientCG | CC0 | https://ambientcg.com/view?id=Bricks100 |' "$FAKE/home/CREDITS.md"
  grep -qF 'ambientcg.com/get?file=Bricks100_1K-JPG.zip' "$FAKE/urls.log"
}

@test "fetch: sources that need a login print the manual steps; usage errors exit 2" {
  run bash "$FETCH" sketchfab:abc123
  [ "$status" -eq 1 ]
  [[ "$output" == *"https://sketchfab.com/3d-models/abc123"* ]]
  run bash "$FETCH" freesound:900001
  [ "$status" -eq 1 ]
  [[ "$output" == *"https://freesound.org/s/900001/"* ]]
  run bash "$FETCH" roblox:5392132809
  [ "$status" -eq 1 ]
  [[ "$output" == *"insert_asset with assetId 5392132809"* ]]
  [ ! -e "$FAKE/calls.log" ]
  run bash "$FETCH" polyhaven:../../etc
  [ "$status" -eq 2 ]
  run bash "$FETCH" brick_4
  [ "$status" -eq 2 ]
  run bash "$FETCH" polyhaven:brick_4 --res 4k
  [ "$status" -eq 2 ]
  run bash "$FETCH" nowhere:x
  [ "$status" -eq 2 ]
  [ ! -e "$FAKE/calls.log" ]
}

# --- credit.sh ---------------------------------------------------------------------------------

@test "credit: creates the table, escapes pipes and is idempotent on name and source" {
  run bash "$CREDIT" --name "Brick 4" --source https://polyhaven.com/a/brick_4 --license CC0 --author "Rob Tuytel"
  [ "$status" -eq 0 ]
  run bash "$CREDIT" --name "Brick 4" --source https://polyhaven.com/a/brick_4 --license "CC0 1.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already credited"* ]]
  bash "$CREDIT" --name 'Swords | Shields' --source https://game-icons.net/1x1/lorc/sword.html --license "CC-BY 3.0" --author Lorc
  bash "$CREDIT" --name 'Swords | Shields' --source https://game-icons.net/1x1/lorc/sword.html --license "CC-BY 3.0" --author Lorc
  [ "$(head -n 1 CREDITS.md)" = "# Credits" ]
  [ "$(grep -c '^| Asset | Author | License | Source |$' CREDITS.md)" -eq 1 ]
  [ "$(grep -c '^| Brick 4 |' CREDITS.md)" -eq 1 ]
  [ "$(grep -cxF '| Swords \| Shields | Lorc | CC-BY 3.0 | https://game-icons.net/1x1/lorc/sword.html |' CREDITS.md)" -eq 1 ]
}

@test "credit: an existing file without the table gets one appended; usage errors exit 2" {
  printf '# Thanks\n\nMusic by a friend.' >NOTES.md
  run bash "$CREDIT" --name Tree --source https://kenney.nl/assets/nature-kit --license CC0 --author Kenney --file NOTES.md
  [ "$status" -eq 0 ]
  [ "$(sed -n 3p NOTES.md)" = "Music by a friend." ]
  grep -qxF '| Asset | Author | License | Source |' NOTES.md
  grep -qxF '| Tree | Kenney | CC0 | https://kenney.nl/assets/nature-kit |' NOTES.md
  run bash "$CREDIT" --name Tree --license CC0
  [ "$status" -eq 2 ]
  run bash "$CREDIT" --name Tree --source x --license CC0 --file "$FAKE"
  [ "$status" -eq 2 ]
}

# --- scan-model.sh -----------------------------------------------------------------------------

@test "scan: a model with harmless scripts lists them and exits 0" {
  require_lune
  run bash "$SCAN" "$FIX/benign.rbxmx"
  [ "$status" -eq 0 ]
  [[ "$output" == *"4 instances, 2 script(s) (1 ModuleScript, 1 Script)"* ]]
  [[ "$output" == *"Script        yes      Legacy       8"*"OakTree.Sway"* ]]
  [[ "$output" == *"No suspicious patterns found."* ]]
  [[ "$output" == *"Verdict: clean scan."* ]]
}

@test "scan: a backdoored model exits 1 and names the loader line" {
  require_lune
  run bash "$SCAN" "$FIX/backdoor.rbxmx"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HIGH   require-id      FreeTree.Trunk.Weld.Weld:4"* ]]
  [[ "$output" == *"> require(4201337000)"* ]]
  [[ "$output" == *"HIGH   loadstring"* ]]
  [[ "$output" == *"HIGH   http            FreeTree.Trunk.Weld.Weld:7"* ]]
  [[ "$output" == *"MEDIUM purchase-prompt FreeTree.Donate:3"* ]]
  [[ "$output" == *"Script hidden inside a Weld"* ]]
  [[ "$output" == *'script name "Weld " has leading or trailing spaces'* ]]
  [[ "$output" == *"Verdict: unsafe."* ]]
}

@test "scan: --json reports the findings with their lines" {
  require_lune
  run --separate-stderr bash "$SCAN" "$FIX/backdoor.rbxmx" --json
  [ "$status" -eq 1 ]
  [ "$(jq -r .verdict <<<"$output")" = unsafe ]
  [ "$(jq -r '[.findings[] | select(.rule == "require-id")][0] | "\(.severity) \(.line) \(.excerpt)"' <<<"$output")" = "high 4 require(4201337000)" ]
  [ "$(jq -r '.summary | "\(.scripts) \(.high) \(.medium)"' <<<"$output")" = "2 7 3" ]
  [ "$(jq -r '.scripts[] | select(.class == "Script" and .enabled == false) | .path' <<<"$output")" = FreeTree.Donate ]
  run --separate-stderr bash "$SCAN" "$FIX/benign.rbxmx" --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '.findings' <<<"$output")" = "[]" ]
}

@test "scan: --max-line flags long lines; a place file is scanned too" {
  require_lune
  run bash "$SCAN" "$FIX/benign.rbxmx" --max-line 40
  [ "$status" -eq 1 ]
  [[ "$output" == *"long-line"*"longer than 40 characters"* ]]
  cat >"$BATS_TEST_TMPDIR/place.rbxlx" <<'EOF'
<roblox version="4">
  <Item class="Workspace" referent="RBX0">
    <Properties><string name="Name">Workspace</string></Properties>
    <Item class="Script" referent="RBX1">
      <Properties>
        <string name="Name">Loader</string>
        <ProtectedString name="Source">require(1234567)</ProtectedString>
      </Properties>
    </Item>
  </Item>
</roblox>
EOF
  run bash "$SCAN" "$BATS_TEST_TMPDIR/place.rbxlx"
  [ "$status" -eq 1 ]
  [[ "$output" == *"require-id      Workspace.Loader:1"* ]]
}

@test "scan: a LinkedSource is a high finding even when the source is empty" {
  require_lune
  cat >"$BATS_TEST_TMPDIR/linked.rbxmx" <<'EOF'
<roblox version="4">
  <Item class="Model" referent="RBX0">
    <Properties><string name="Name">Lamp</string></Properties>
    <Item class="ModuleScript" referent="RBX1">
      <Properties>
        <string name="Name">Config</string>
        <Content name="LinkedSource"><url>rbxassetid://987654321</url></Content>
        <ProtectedString name="Source"></ProtectedString>
      </Properties>
    </Item>
  </Item>
</roblox>
EOF
  run --separate-stderr bash "$SCAN" "$BATS_TEST_TMPDIR/linked.rbxmx" --json
  [ "$status" -eq 1 ]
  [ "$(jq -r '.findings[0] | "\(.severity) \(.rule) \(.script)"' <<<"$output")" = "high linked-source Lamp.Config" ]
  [[ "$(jq -r '.findings[0].message' <<<"$output")" == *"rbxassetid://987654321"* ]]
}

@test "scan: unreadable input and usage errors exit 2" {
  require_lune
  run bash "$SCAN" "$FIX/garbage.rbxm"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a readable Roblox model or place file"* ]]
  run bash "$SCAN" "$FIX/README.md"
  [ "$status" -eq 2 ]
  run bash "$SCAN" "$FIX/missing.rbxm"
  [ "$status" -eq 2 ]
  run bash "$SCAN" "$FIX/benign.rbxmx" --max-line 0
  [ "$status" -eq 2 ]
}

@test "scan: without Lune it exits 2 and says how to get it" {
  run bash "$SCAN" "$FIX/benign.rbxmx"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Lune not found"*"install-toolchain.sh"* ]]
  RDK_LUNE_BIN="$FAKE/bin/nope" run bash "$SCAN" "$FIX/benign.rbxmx"
  [ "$status" -eq 2 ]
}
