# Open Cloud Assets API (what upload-asset.sh does)

Checked 2026-10-24 against:
- usage guide: https://create.roblox.com/docs/cloud/guides/usage-assets
- API reference: https://create.roblox.com/docs/cloud/reference/features/assets (rendered from the
  OpenAPI files `content/en-us/reference/cloud/assets/v1.json` and `reference/cloud/openapi.json`
  in https://github.com/Roblox/creator-docs; the field names, scopes and rate limits below come
  from those files)
- API keys: https://create.roblox.com/docs/cloud/auth/api-keys
- long-running operations: https://create.roblox.com/docs/cloud/reference/patterns#long-running-operations
- rate limits: https://create.roblox.com/docs/cloud/reference/rate-limits
- errors: https://create.roblox.com/docs/cloud/reference/errors

The Assets API is marked **beta** ("might be subject to changes").

## Endpoints

| Call | Request | Returns |
|---|---|---|
| Create Asset | `POST https://apis.roblox.com/assets/v1/assets`, `multipart/form-data` with `request` (the asset JSON) and `fileContent` (the file, with its content type) | an `Operation` |
| Get Operation | `GET https://apis.roblox.com/assets/v1/operations/{operationId}` | the `Operation`, with `response` (the asset) or `error` once `done` |

Every request carries the API key in the `x-api-key` header. The request JSON:

```json
{
  "assetType": "Model",
  "displayName": "Car body",
  "description": "Car body",
  "creationContext": { "creator": { "userId": "1234567" } }
}
```

`assetType`, `displayName`, `description` (at most 1000 characters) and `creationContext.creator`
are required for Create Asset; the creator is `userId` for the user's own assets or `groupId` for a
group's. `creationContext.expectedPrice` (Robux) makes the call fail with 400 when the upload would
cost more. Roblox's examples send the ids as strings; the schema types them as int64.
`upload-asset.sh` sends strings, as in the examples.

The create response is `{"path": "operations/<operationId>", ...}`; `upload-asset.sh` also accepts
an `operationId` field. A finished operation:

```json
{
  "path": "operations/{operationId}",
  "done": true,
  "response": {
    "path": "assets/2205400862",
    "assetId": "2205400862",
    "displayName": "Name",
    "assetType": "ASSET_TYPE_DECAL",
    "creationContext": { "creator": { "userId": "11112938575" } },
    "moderationResult": { "moderationState": "MODERATION_STATE_APPROVED" }
  }
}
```

The schema describes `moderationState` as `Reviewing`, `Rejected` or `Approved`; the example shows
`MODERATION_STATE_APPROVED`. The script accepts both spellings. A failed operation has
`error: {code, message}` instead of `response`.

## API key and creator

- Create the key at https://create.roblox.com/dashboard/credentials: add the **Assets** API
  ("assets" in Access Permissions) with **Read** and **Write**. Create Asset needs the scopes
  `asset:read` and `asset:write`, Get Operation `asset:read`.
- To create group assets, the key's owner needs the matching group permissions; Roblox recommends a
  dedicated alternate account with only the group permissions the automation needs.
- Restrict the key: minimum permissions, an IP allow-list where possible, an expiry for short-term
  use. A key unused (and not updated) for 60 days expires on its own.
- Never put the key in source code or version control.
- `upload-asset.sh` reads `ROBLOX_API_KEY`, `ROBLOX_CREATOR_TYPE` (`User` or `Group`) and
  `ROBLOX_CREATOR_ID`. The key goes to curl through a temporary config file readable only by the
  user, so it never appears in the process list, the script's output or its `--dry-run`.

## File types and limits (Create Asset)

One asset per call, file at most **20 MB**.

| `assetType` | Files (content type) | Limits |
|---|---|---|
| `Model` | `.fbx` (`model/fbx`), `.gltf` (`model/gltf+json`), `.glb` (`model/gltf-binary`), `.rbxm`/`.rbxmx` (`model/x-rbxm`) | imported as a `Model` holding one or more `MeshPart`s; **uploaded as a package**; `.rbxm`/`.rbxmx` edited outside Studio may fail |
| `Decal`, `Image` | `.png`, `.jpeg`, `.bmp`, `.tga` (`image/png`, `image/jpeg`, `image/bmp`, `image/tga`) | smaller than 8000×8000 px; cannot be updated |
| `Audio` | `.mp3`, `.ogg`, `.wav`, `.flac` (`audio/mpeg`, `audio/ogg`, `audio/wav`, `audio/flac`) | up to 7 minutes; 100 uploads a month when ID-verified, 10 otherwise; cannot be updated |
| `Mesh` | only content downloaded from the Asset Delivery API | use the Importer for meshes |
| `Animation`, `Video` | not supported by `upload-asset.sh` | see the usage guide |

The usage guide also notes that the Importer gives a 3D preview, error checks and import settings
that an upload does not, so a person may prefer it for the first import of a model. Only `.fbx`
content can be updated in place (Update Asset, `PATCH .../assets/{assetId}`, creates a new version);
`upload-asset.sh` always creates a new asset.

## Polling

Create Asset returns an operation at once; the asset is ready when `done` is true. Roblox's pattern:
poll immediately, then back off exponentially (1 s, 2 s, 4 s, …). `upload-asset.sh` does that, with
waits capped at 30 s, and gives up after `--timeout` seconds (default 300), printing the operation
id so it can be checked later.

## Rate limits and retries

- Create Asset: 120 requests a minute per API key owner (and per OAuth authorization); Get
  Operation: 300 a minute. Limits for API keys apply across all keys of the same owner (user or
  group).
- Responses may carry `x-ratelimit-limit`, `x-ratelimit-remaining` and `x-ratelimit-reset`.
  Undocumented limits can also apply.
- On **429**, wait for `retry-after` when the header is present, otherwise back off exponentially.
  `upload-asset.sh` retries 429, 5xx and network errors up to 5 times per request.

## Errors

| Status | Meaning | What to do |
|---|---|---|
| 400 | invalid argument: the request JSON or the file could not be parsed, wrong type for the file, `expectedPrice` too low | read the message; check `--type` against the file |
| 401 / 403 | the key is invalid, expired, IP-restricted, or lacks the Assets read/write permission for this creator | fix the key on the Credentials page |
| 429 | rate limited | retried automatically |
| 500 / 503 | server error | retried automatically; try again later |

Error bodies vary between `{"message"}`, `{"error", "message"}`, gateway errors
`{"errors": [{"code", "message"}]}` and validation errors `{"title", "errors": {field: [...]}}`;
the script prints whichever message it finds.

## Using the asset

- An uploaded asset belongs to the creator in `creationContext` and is available in Studio like any
  other asset of theirs: Toolbox › Inventory › My Packages for models (Creations › Group Packages
  for groups), or the Asset Manager.
- In a property: `rbxassetid://<assetId>`; in a script, a string property such as
  `AudioPlayer.Asset = "rbxassetid://<id>"`, or `Content.fromAssetId(<id>)` for a `Content`
  property such as `Decal.ColorMapContent`.
- Into the open place: the Studio MCP tool `insert_asset` (`assetId`, `assetName`, optional
  `parentPath`), or `game:GetService("InsertService"):LoadAsset(<id>)`, which returns a `Model`
  containing the asset; the asset must be accessible to the experience's creator
  (https://create.roblox.com/docs/reference/engine/classes/InsertService).
- Moderation: the docs name the states (`Reviewing`, `Rejected`, `Approved`) but not what each
  means for loading or how long review takes (**unverified**). `upload-asset.sh` treats `Rejected`
  as a failure (exit 1) and warns that a `Reviewing` asset may not load yet.
