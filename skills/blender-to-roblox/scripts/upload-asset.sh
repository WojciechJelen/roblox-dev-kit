#!/usr/bin/env bash
# Upload a model, image or sound with the Roblox Open Cloud Assets API, wait for the upload
# operation to finish, and print the asset id and how to insert it.
# The API key comes from ROBLOX_API_KEY. It is never printed, never put on a command line and
# never passed to child processes: the script moves it into an unexported variable first, and
# curl reads it from a private, temporary config file. RDK_UPLOAD_MAX_DELAY caps every wait in
# seconds (default 30; the tests use 0).
# shellcheck disable=SC2016  # jq programs use $names literally
set -euo pipefail
api_key=${ROBLOX_API_KEY:-}
unset ROBLOX_API_KEY

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

API="https://apis.roblox.com/assets/v1"
MAX_BYTES=$((20 * 1024 * 1024)) # per upload, from the Open Cloud assets usage guide
MAX_ATTEMPTS=5                  # per request, for 429, 5xx and network errors
MAX_DELAY=${RDK_UPLOAD_MAX_DELAY:-30}

usage() {
  cat <<EOF
usage: upload-asset.sh FILE --name NAME [--description TEXT] [--type Model|Decal|Image|Audio]
                       [--timeout SECONDS] [--dry-run] [--json]

Creates a Roblox asset from FILE (Open Cloud: POST $API/assets), polls the returned
operation until it is done, and prints the asset id, its rbxassetid:// form, the moderation state
and how to insert it in Studio.

  --name         display name of the asset (required)
  --description  description (default: the name; at most 1000 characters)
  --type         asset type; by default from the extension:
                   Model  .fbx .gltf .glb .rbxm .rbxmx   (imports as a Model of MeshParts)
                   Decal  .png .jpg .jpeg .bmp .tga      (Image takes the same files)
                   Audio  .mp3 .ogg .wav .flac
  --timeout      give up waiting for the operation after this many seconds (default 300)
  --dry-run      print the request without sending anything (works without an API key)
  --json         print the result as JSON

Environment: ROBLOX_API_KEY (Assets API, read and write), ROBLOX_CREATOR_TYPE (User or Group) and
ROBLOX_CREATOR_ID (the user or group that will own the asset). Files are limited to 20 MB.
Exit codes: 0 uploaded, 1 failed (HTTP error, rejected, timed out), 2 usage error.
EOF
}

usage_error() {
  rdk_err "$1"
  usage >&2
  exit 2
}

file='' name='' description='' type='' timeout=300 dry_run=0 json=0
while [ $# -gt 0 ]; do
  case $1 in
    --name | --description | --type | --timeout)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      case $1 in
        --name) name=$2 ;;
        --description) description=$2 ;;
        --type) type=$2 ;;
        --timeout) timeout=$2 ;;
      esac
      shift
      ;;
    --dry-run) dry_run=1 ;;
    --json) json=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) usage_error "unknown option: $1" ;;
    *)
      [ -z "$file" ] || usage_error "only one file per upload (got $file and $1)"
      file=$1
      ;;
  esac
  shift
done

[ -n "$file" ] || usage_error "no file given"
[ -n "$name" ] || usage_error "--name is required"
[ -f "$file" ] || usage_error "not a file: $file"
case $file in *'"'* | *$'\n'*) usage_error "the file path must not contain double quotes or newlines: $file" ;; esac
case $timeout in '' | *[!0-9]*) usage_error "--timeout must be a whole number of seconds" ;; esac
case $MAX_DELAY in '' | *[!0-9]*) usage_error "RDK_UPLOAD_MAX_DELAY must be a whole number of seconds" ;; esac
description=${description:-$name}
[ ${#description} -le 1000 ] || usage_error "--description is longer than 1000 characters"
rdk_has jq || rdk_die "upload-asset.sh needs jq (macOS 15+ ships it; otherwise: brew install jq)"

ext=$(printf '%s' "${file##*.}" | tr '[:upper:]' '[:lower:]')
case $ext in
  fbx) ctype=model/fbx kind=Model ;;
  gltf) ctype=model/gltf+json kind=Model ;;
  glb) ctype=model/gltf-binary kind=Model ;;
  rbxm | rbxmx) ctype=model/x-rbxm kind=Model ;;
  png) ctype=image/png kind=Decal ;;
  jpg | jpeg) ctype=image/jpeg kind=Decal ;;
  bmp) ctype=image/bmp kind=Decal ;;
  tga) ctype=image/tga kind=Decal ;;
  mp3) ctype=audio/mpeg kind=Audio ;;
  ogg) ctype=audio/ogg kind=Audio ;;
  wav) ctype=audio/wav kind=Audio ;;
  flac) ctype=audio/flac kind=Audio ;;
  *) usage_error "unsupported file type .$ext (see --help for what Open Cloud accepts)" ;;
esac
type=${type:-$kind}
case $type:$kind in
  Model:Model | Decal:Decal | Image:Decal | Audio:Audio) ;;
  Model:* | Decal:* | Image:* | Audio:*) usage_error "a .$ext file cannot be uploaded as $type" ;;
  *) usage_error "unknown --type $type (expected Model, Decal, Image or Audio)" ;;
esac
bytes=$(wc -c <"$file" | tr -d ' ')
[ "$bytes" -le $MAX_BYTES ] || rdk_die "$file is $bytes bytes; Open Cloud accepts at most 20 MB per upload"

creator_type=${ROBLOX_CREATOR_TYPE:-} creator_id=${ROBLOX_CREATOR_ID:-}
problems=''
[ -n "$api_key" ] || problems="ROBLOX_API_KEY is not set"
case $creator_type in
  User) creator_key=userId ;;
  Group) creator_key=groupId ;;
  *)
    creator_key=userId
    problems="${problems:+$problems; }ROBLOX_CREATOR_TYPE must be User or Group"
    ;;
esac
case $creator_id in
  '' | *[!0-9]*) problems="${problems:+$problems; }ROBLOX_CREATOR_ID must be the numeric user or group id" ;;
esac
if [ -n "$problems" ]; then
  [ $dry_run = 1 ] || rdk_die "$problems (create a key at https://create.roblox.com/dashboard/credentials; see roblox-setup references/manual-steps.md)"
  rdk_warn "$problems; a real upload would stop here"
  case $creator_id in '' | *[!0-9]*) creator_id='<ROBLOX_CREATOR_ID>' ;; esac
fi

# The creator id is a string, as in Roblox's own request examples.
request=$(jq -n --arg t "$type" --arg n "$name" --arg d "$description" --arg k "$creator_key" --arg id "$creator_id" \
  '{assetType: $t, displayName: $n, description: $d, creationContext: {creator: {($k): $id}}}')

if [ $dry_run = 1 ]; then
  if [ $json = 1 ]; then
    jq -n --arg url "$API/assets" --argjson request "$request" --arg file "$file" --arg ctype "$ctype" --argjson bytes "$bytes" \
      '{dryRun: true, url: $url, request: $request, file: $file, contentType: $ctype, bytes: $bytes}'
  else
    printf 'dry run: nothing is sent\n'
    printf 'POST %s/assets\n  header   x-api-key: <ROBLOX_API_KEY, hidden>\n' "$API"
    printf '  request  %s\n' "$(jq -c . <<<"$request")"
    printf '  file     %s (%s, %s bytes)\n' "$file" "$ctype" "$bytes"
    printf 'then GET %s/operations/<operationId> until it is done\n' "$API"
  fi
  exit 0
fi

tmp=$(umask 077 && mktemp -d)
trap 'rm -rf "$tmp"' EXIT
key=${api_key//\\/\\\\}
key=${key//\"/\\\"}
# printf is a shell builtin, so the key never appears in a process list.
(umask 077 && printf 'header = "x-api-key: %s"\n' "$key" >"$tmp/auth.conf")
unset key api_key
printf '%s\n' "$request" >"$tmp/request.json"

# pause SECONDS: sleep, capped at MAX_DELAY.
pause() {
  local s=$1
  [ "$s" -le "$MAX_DELAY" ] || s=$MAX_DELAY
  [ "$s" -eq 0 ] || sleep "$s"
}

# http URL [CURL ARGS...]: one API request, retried on 429, 5xx and network errors (honouring
# retry-after, else exponential backoff). Sets STATUS; the body is in $tmp/body.
http() {
  local url=$1 attempt=0 delay wait_s
  shift
  while :; do
    attempt=$((attempt + 1))
    rm -f "$tmp/body" "$tmp/headers"
    STATUS=$(curl -sS --config "$tmp/auth.conf" -o "$tmp/body" -D "$tmp/headers" -w '%{http_code}' "$@" "$url") || STATUS=000
    case $STATUS in
      429 | 5?? | 000) ;;
      *) return 0 ;;
    esac
    [ $attempt -lt $MAX_ATTEMPTS ] || return 0
    delay=$((1 << (attempt - 1)))
    wait_s=$(awk -F': *' 'tolower($1) == "retry-after" { gsub(/\r/, "", $2); print $2; exit }' "$tmp/headers" 2>/dev/null || true)
    case $wait_s in '' | *[!0-9]*) ;; *) delay=$wait_s ;; esac
    [ "$delay" -le "$MAX_DELAY" ] || delay=$MAX_DELAY
    rdk_warn "HTTP $STATUS from $url; retrying in ${delay}s ($attempt/$MAX_ATTEMPTS)"
    pause "$delay"
  done
}

is_2xx() { case $1 in 2??) return 0 ;; esac; return 1; }

# api_error WHAT: explain a failed request and exit 1.
api_error() {
  local msg=''
  # Open Cloud v1 errors come in several shapes: {message}, {error: {message}}, {errors: [{message}]},
  # {title, errors: {field: [...]}}.
  [ ! -s "$tmp/body" ] || msg=$(jq -r '[.message?, (.error | objects | .message), (.errors | arrays | .[0].message?), .title?]
    | map(strings) | .[0] // empty' "$tmp/body" 2>/dev/null || head -c 300 "$tmp/body")
  case $STATUS in
    401 | 403) rdk_die "$1: HTTP $STATUS${msg:+ ($msg)}. Check that the key has the Assets API with read and write access for this creator, and that it is not expired or IP-restricted." ;;
    429) rdk_die "$1: still rate limited after $MAX_ATTEMPTS attempts (HTTP 429); wait a minute and try again" ;;
    000) rdk_die "$1: could not reach apis.roblox.com" ;;
    *) rdk_die "$1: HTTP $STATUS${msg:+ ($msg)}" ;;
  esac
}

rdk_info "uploading $file as $type \"$name\" ($ctype, $bytes bytes)"
http "$API/assets" -F "request=<$tmp/request.json" -F "fileContent=@\"$file\";type=$ctype"
is_2xx "$STATUS" || api_error "upload failed"
operation=$(jq -r '.operationId // ((.path // "") | sub("^operations/"; ""))' "$tmp/body")
[ -n "$operation" ] || rdk_die "the upload response has no operation id: $(head -c 300 "$tmp/body")"
cp "$tmp/body" "$tmp/operation.json"

# Poll right away, then back off 1 s, 2 s, 4 s ... (Open Cloud's long-running operation pattern).
delay=0 polls=0 deadline=$((SECONDS + timeout))
while [ "$(jq -r '.done // false' "$tmp/operation.json")" != true ]; do
  if [ $SECONDS -ge $deadline ] || [ $polls -ge 100 ]; then
    rdk_die "operation $operation is still running after ${timeout}s; check it later with GET $API/operations/$operation"
  fi
  pause $delay
  http "$API/operations/$operation"
  is_2xx "$STATUS" || api_error "checking operation $operation failed"
  cp "$tmp/body" "$tmp/operation.json"
  polls=$((polls + 1))
  if [ $delay -eq 0 ]; then delay=1; else delay=$((delay * 2)); fi
  [ $delay -le 30 ] || delay=30
done

if jq -e '.error' "$tmp/operation.json" >/dev/null; then
  rdk_die "the upload failed: $(jq -r '"\(.error.message // "no message") (code \(.error.code // "?"))"' "$tmp/operation.json")"
fi
asset_id=$(jq -r '.response.assetId // ((.response.path // "") | sub("^assets/"; ""))' "$tmp/operation.json")
[ -n "$asset_id" ] || rdk_die "the finished operation has no asset id: $(head -c 300 "$tmp/operation.json")"
state=$(jq -r '.response.moderationResult.moderationState // "unknown"' "$tmp/operation.json")
case $(printf '%s' "$state" | tr '[:lower:]' '[:upper:]') in
  *APPROVED*) moderation=Approved ;;
  *REVIEW*) moderation=Reviewing ;;
  *REJECTED*) moderation=Rejected ;;
  *) moderation=$state ;;
esac

case $type in
  Model) luau="game:GetService(\"InsertService\"):LoadAsset($asset_id).Parent = workspace" ;;
  Audio) luau="audioPlayer.Asset = \"rbxassetid://$asset_id\"" ;;
  *) luau="Content.fromAssetId($asset_id) for Content properties (e.g. SurfaceAppearance.ColorMapContent), or \"rbxassetid://$asset_id\" for string ones (e.g. MeshPart.TextureID)" ;;
esac

if [ $json = 1 ]; then
  jq -n --arg id "$asset_id" --arg type "$type" --arg name "$name" --arg moderation "$moderation" \
    --arg operation "$operation" --arg file "$file" --arg luau "$luau" '{
      assetId: $id, assetUri: ("rbxassetid://" + $id), assetType: $type, displayName: $name,
      moderationState: $moderation, operationId: $operation, file: $file,
      insert: {mcp: {tool: "insert_asset", assetId: $id, assetName: $name}, luau: $luau}}'
else
  printf 'uploaded %s "%s": asset id %s\n' "$type" "$name" "$asset_id"
  printf '  rbxassetid://%s\n' "$asset_id"
  printf '  moderation: %s\n' "$moderation"
  printf 'insert it in Studio:\n'
  printf '  Studio MCP: insert_asset with assetId "%s" and assetName "%s"\n' "$asset_id" "$name"
  printf '  Luau: %s\n' "$luau"
fi

case $moderation in
  Rejected)
    rdk_err "moderation rejected the asset; it cannot be used"
    exit 1
    ;;
  Reviewing) rdk_warn "the asset is still in moderation review; it may not load until it is approved" ;;
esac
exit 0
