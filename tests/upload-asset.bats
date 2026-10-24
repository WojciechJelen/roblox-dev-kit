#!/usr/bin/env bats
# upload-asset.sh against a fake curl that replays canned Open Cloud responses. No network.

load helpers

KEY="rbx-test-SECRET-key-42"

setup() {
  setup_fake_machine
  UPLOAD="$BLENDER_SCRIPTS/upload-asset.sh"
  export ROBLOX_API_KEY=$KEY ROBLOX_CREATOR_TYPE=User ROBLOX_CREATOR_ID=1234567 RDK_UPLOAD_MAX_DELAY=0
  mkdir -p "$FAKE/responses" "$FAKE/assets"
  printf 'Kaydara FBX Binary  \0fake' >"$FAKE/assets/car.fbx"
  printf 'png' >"$FAKE/assets/paint.png"
  # The fake logs its argv, whether the --config file sends the key (and is private), the request
  # JSON, and answers with responses/<n>.{status,headers,body}, where n counts the calls.
  cat >"$FAKE/bin/curl" <<EOF
#!/usr/bin/env bash
dir="$FAKE" key="$KEY"
EOF
  cat >>"$FAKE/bin/curl" <<'EOF'
{ printf 'curl'; printf ' [%s]' "$@"; echo; } >>"$dir/calls.log"
out='' hdr='' cfg='' url=''
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    -D) hdr=$2; shift ;;
    --config) cfg=$2; shift ;;
    -F)
      case $2 in request=\<*) cp "${2#request=<}" "$dir/request.json" ;; esac
      shift
      ;;
    -w) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
echo "$cfg" >>"$dir/configs.log"
if grep -qxF "header = \"x-api-key: $key\"" "$cfg" && [ "$(ls -l "$cfg" | cut -c1-10)" = "-rw-------" ]; then
  echo "auth ok $url" >>"$dir/auth.log"
fi
[ -z "${ROBLOX_API_KEY:-}" ] || echo "curl inherited ROBLOX_API_KEY" >>"$dir/leaks.log"
n=$(( $(cat "$dir/n" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$dir/n"
r="$dir/responses/$n"
[ -f "$r.status" ] || { echo "curl: (7) no canned response $n" >&2; printf 000; exit 7; }
cp "$r.body" "$out"
{ echo "HTTP/2 $(cat "$r.status")"; cat "$r.headers" 2>/dev/null; } >"$hdr"
cat "$r.status"
EOF
  chmod +x "$FAKE/bin/curl"
}

# respond N STATUS BODY [HEADER]: the Nth curl call gets this response.
respond() {
  printf '%s' "$2" >"$FAKE/responses/$1.status"
  printf '%s' "$3" >"$FAKE/responses/$1.body"
  [ -z "${4:-}" ] || printf '%s\r\n' "$4" >"$FAKE/responses/$1.headers"
}

pending='{"path":"operations/op-77","done":false}'
done_ok() { # done_ok ASSET_ID [MODERATION_STATE]
  printf '{"path":"operations/op-77","done":true,"response":{"@type":"type.googleapis.com/roblox.open_cloud.assets.v1.Asset","path":"assets/%s","revisionId":"1","assetId":"%s","displayName":"Car body","assetType":"ASSET_TYPE_MODEL","moderationResult":{"moderationState":"%s"}}}' \
    "$1" "$1" "${2:-MODERATION_STATE_APPROVED}"
}

calls() { if [ -f "$FAKE/calls.log" ]; then wc -l <"$FAKE/calls.log" | tr -d ' '; else echo 0; fi; }

@test "uploads, polls a pending operation until done, and prints the asset id and insert hints" {
  respond 1 200 "$pending"
  respond 2 200 "$pending"
  respond 3 200 "$(done_ok 9876543)"
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body"
  [ "$status" -eq 0 ]
  [[ "$output" == *'uploaded Model "Car body": asset id 9876543'* ]]
  [[ "$output" == *"rbxassetid://9876543"* ]]
  [[ "$output" == *"moderation: Approved"* ]]
  [[ "$output" == *'insert_asset with assetId "9876543" and assetName "Car body"'* ]]
  [[ "$output" == *'game:GetService("InsertService"):LoadAsset(9876543).Parent = workspace'* ]]
  [ "$(calls)" -eq 3 ]
  sed -n 1p "$FAKE/calls.log" | grep -qF "[https://apis.roblox.com/assets/v1/assets]"
  sed -n 1p "$FAKE/calls.log" | grep -qF "[fileContent=@\"$FAKE/assets/car.fbx\";type=model/fbx]"
  sed -n 2p "$FAKE/calls.log" | grep -qF "[https://apis.roblox.com/assets/v1/operations/op-77]"
  sed -n 3p "$FAKE/calls.log" | grep -qF "[https://apis.roblox.com/assets/v1/operations/op-77]"
  [ "$(wc -l <"$FAKE/auth.log" | tr -d ' ')" -eq 3 ] # every request sent the key, from a private file
  [ "$(jq -c . "$FAKE/request.json")" = '{"assetType":"Model","displayName":"Car body","description":"Car body","creationContext":{"creator":{"userId":"1234567"}}}' ]
}

@test "the API key never appears in arguments, environment or output, and its config file is removed" {
  respond 1 200 "$(done_ok 1)"
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body"
  [ "$status" -eq 0 ]
  [ -s "$FAKE/auth.log" ]
  [ ! -e "$FAKE/leaks.log" ]
  run ! grep -qF "$KEY" "$FAKE/calls.log"
  [[ "$output" != *"$KEY"* ]]
  cfg=$(cat "$FAKE/configs.log")
  [ -n "$cfg" ]
  [ ! -e "$cfg" ]
}

@test "a 429 is retried after retry-after, then the upload succeeds" {
  respond 1 429 '{"errors":[{"code":0,"message":"Too many requests"}]}' "retry-after: 3"
  respond 2 200 "$(done_ok 55)"
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HTTP 429 from https://apis.roblox.com/assets/v1/assets; retrying in 0s (1/5)"* ]]
  [[ "$output" == *"asset id 55"* ]]
  [ "$(calls)" -eq 2 ]
}

@test "5xx answers are retried and then reported" {
  for n in 1 2 3 4 5; do respond $n 503 'upstream unavailable'; done
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body"
  [ "$status" -eq 1 ]
  [ "$(calls)" -eq 5 ]
  [[ "$output" == *"upload failed: HTTP 503"* ]]
}

@test "a rejected key explains what the key needs" {
  respond 1 401 '{"errors":[{"code":0,"message":"Invalid API Key"}]}'
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 401 (Invalid API Key)"* ]]
  [[ "$output" == *"Assets API with read and write access"* ]]
  [ "$(calls)" -eq 1 ]
}

@test "a failed operation exits 1 with its message" {
  respond 1 200 '{"path":"operations/op-77","done":true,"error":{"code":3,"message":"The file could not be parsed"}}'
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"The file could not be parsed (code 3)"* ]]
}

@test "moderation states: reviewing warns, rejected fails" {
  respond 1 200 "$(done_ok 8 MODERATION_STATE_REVIEWING)"
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"moderation: Reviewing"* ]]
  [[ "$output" == *"still in moderation review"* ]]
  rm -f "$FAKE/n" "$FAKE/responses"/*
  respond 1 200 "$(done_ok 9 Rejected)"
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"moderation: Rejected"* ]]
}

@test "--json prints the result; a group owns the asset when ROBLOX_CREATOR_TYPE=Group" {
  respond 1 200 '{"operationId":"op-9","path":"operations/op-9","done":false}'
  respond 2 200 "$(done_ok 42)"
  ROBLOX_CREATOR_TYPE=Group ROBLOX_CREATOR_ID=7654321 run --separate-stderr \
    bash "$UPLOAD" "$FAKE/assets/paint.png" --name "Car paint" --description "Red paint" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .assetId <<<"$output")" = 42 ]
  [ "$(jq -r .assetUri <<<"$output")" = rbxassetid://42 ]
  [ "$(jq -r .assetType <<<"$output")" = Decal ]
  [ "$(jq -r .moderationState <<<"$output")" = Approved ]
  [ "$(jq -r .insert.mcp.tool <<<"$output")" = insert_asset ]
  [ "$(jq -r .creationContext.creator.groupId "$FAKE/request.json")" = 7654321 ]
  [ "$(jq -r .description "$FAKE/request.json")" = "Red paint" ]
  sed -n 1p "$FAKE/calls.log" | grep -qF ";type=image/png]"
  sed -n 2p "$FAKE/calls.log" | grep -qF "[https://apis.roblox.com/assets/v1/operations/op-9]"
}

@test "--dry-run sends nothing, writes nothing and works without a key" {
  unset ROBLOX_API_KEY
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run: nothing is sent"* ]]
  [[ "$output" == *"POST https://apis.roblox.com/assets/v1/assets"* ]]
  [[ "$output" == *'"assetType":"Model"'* ]]
  [[ "$output" == *"ROBLOX_API_KEY is not set; a real upload would stop here"* ]]
  [ ! -e "$FAKE/calls.log" ]
  run --separate-stderr bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .request.creationContext.creator.userId <<<"$output")" = 1234567 ]
  [ "$(jq -r .contentType <<<"$output")" = model/fbx ]
  [ ! -e "$FAKE/calls.log" ]
}

@test "missing credentials stop before any request" {
  unset ROBLOX_API_KEY
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ROBLOX_API_KEY is not set"* ]]
  ROBLOX_API_KEY=$KEY ROBLOX_CREATOR_TYPE=Team run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ROBLOX_CREATOR_TYPE must be User or Group"* ]]
  [ ! -e "$FAKE/calls.log" ]
}

@test "usage errors exit 2" {
  run bash "$UPLOAD" "$FAKE/assets/car.fbx"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--name is required"* ]]
  run bash "$UPLOAD" "$FAKE/assets/paint.png" --name P --type Model
  [ "$status" -eq 2 ]
  [[ "$output" == *"a .png file cannot be uploaded as Model"* ]]
  printf 'x' >"$FAKE/assets/notes.txt"
  run bash "$UPLOAD" "$FAKE/assets/notes.txt" --name N
  [ "$status" -eq 2 ]
  run bash "$UPLOAD" "$FAKE/assets/missing.fbx" --name M
  [ "$status" -eq 2 ]
  [ ! -e "$FAKE/calls.log" ]
}

@test "files over 20 MB are refused" {
  dd if=/dev/zero of="$FAKE/assets/big.fbx" bs=1048576 count=0 seek=21 2>/dev/null
  run bash "$UPLOAD" "$FAKE/assets/big.fbx" --name Big
  [ "$status" -eq 1 ]
  [[ "$output" == *"at most 20 MB"* ]]
  [ ! -e "$FAKE/calls.log" ]
}

@test "gives up when the operation is still running at the timeout" {
  respond 1 200 "$pending"
  run bash "$UPLOAD" "$FAKE/assets/car.fbx" --name "Car body" --timeout 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"operation op-77 is still running after 0s"* ]]
}
