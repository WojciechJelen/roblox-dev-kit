# Environment resources and recovery

Each environment has its own directory outside the source checkout:

```text
environment.json                 ownership and lifecycle state
verify-studio.luau                read-only proof of the Rojo target
worktree/                        Git branch codex/<name>-<unique suffix>
  rdk-<unique suffix>.project.json  generated beside the selected Rojo project
studio/rdk-<name>-<suffix>.rbxl    independent copy of the input place
blender/                         private user resources, preferences and extensions
tmp/                             private Blender scratch files
logs/rojo.log                    output of the owned Rojo process
review/cameras.json              immutable review camera specification
review/before/<view>.png + .json  baseline image and provenance
review/after/<view>.png + .json   updated image and provenance
```

The manifest records absolute paths, the base commit, source place SHA-256, branch, reserved port,
process identity and verified Studio ID. The generated Rojo project preserves relative paths by
living beside the original project in the worktree. It adds only a `ReplicatedStorage.RDKEnvironmentId`
StringValue, uses loopback and the allocated port, and drops cloud place/game ID settings. The
source project is untouched. The generated file is excluded from Git. Changing the source project
mapping after setup requires a new environment; ordinary edits to the mapped source files sync live.

The helper checks explicit/nested Rojo paths and worktree symlinks for escape into another checkout.
The exception is the kit's conventional `.agents/skills/<name>` or `.claude/skills/<name>` link to
a directory containing `SKILL.md`: these are recorded as `shared_tooling` and must be treated as
read-only. Even those paths cannot be used as external Rojo inputs. Game dependencies must be
copied or installed in the worktree. The helper does not rewrite arbitrary
paths embedded in scripts, imported `.rbxm` files or binary `.blend` files. Inspect those before
running a project-specific asset pipeline.

## Camera specification

Use coordinates chosen for this game's biome, not generic example values. `views` is required;
each view has a unique lowercase name and two different finite three-number vectors:

```json
{
  "views": [
    {
      "name": "overview",
      "camera_position": [40, 30, 60],
      "look_at_position": [0, 5, 0]
    },
    {
      "name": "model-closeup",
      "camera_position": [8, 6, 12],
      "look_at_position": [0, 3, 0]
    }
  ],
  "conditions": {
    "mode": "Edit",
    "lighting": "Use the same Lighting settings for both captures",
    "animation": "Freeze any project-specific animation clock identically"
  }
}
```

`conditions` is optional prose for the worker; the helper does not apply it. The entire file is
hashed and copied once. `capture-plan` forwards just the supported camera arguments and Studio ID.
`record-capture` checks PNG dimensions, freezes the first image for each phase/view, and records
camera/image hashes; the worker must actually use the plan and inspect images. No automated visual
quality judgement is implied.

## Failures and retries

- A dirty source repo stops creation, unless `--committed-only` explicitly selects committed code.
  Saved map content is copied independently and can contain newer art than the commit. Check that
  the chosen pair is intentional. Untracked/ignored dependencies are not automatically copied.
- Repeating `create` with identical inputs returns the existing manifest without overwriting work.
  Different inputs with the same name are refused. Use another name for a new baseline. `--copy`
  seeds dependencies once; it does not refresh them on retries.
- Creation failures leave the directory, branch and manifest with `prepared: false` and an error.
  Inspect and preserve useful files before manually removing that failed worktree; retry with a new
  name after fixing the cause. No forced deletion is used to hide a partial failure.
- Port reservations persist even while stopped. Always use the same root for coordination. A
  process outside the kit can take a stopped port; `start` refuses to kill it. Free that port through
  its owner, or create another environment. Startup waits for Rojo's `/api/rojo` response and its
  process identity and unique project name, not just for an arbitrary TCP listener. JSON and
  MessagePack handshakes (Rojo 7.7+) are supported without Python dependencies.
- `start` is idempotent while its recorded process exists. `stop` checks PID, start time and command
  before signalling; a stale/reused PID is not killed. Restarting Rojo clears the Studio binding,
  so reconnect the plugin and reverify it. Stop retains all review and authoring files.
- `open-studio` records its `open -W` launcher PID/start identity and also checks Studio processes
  for the exact local file path. Repeated calls, including `--reopen`, do not launch another while
  either remains alive—even during login/loading before MCP discovery. This is launch ownership,
  not a ready-state claim. The local filename must appear in
  `list_roblox_studios`, the right Rojo port must be connected, and the marker proof must succeed
  before binding. If Studio kept a cloud name instead of the local filename, establish which local
  file is open via its UI and save/reopen the uniquely named local copy; do not bypass the filename
  or marker checks. After closing a window, `--reopen` requests a new one; rediscover its new ID.
  Startup/discovery can be slow while other Studio instances are busy. Do not relaunch just because
  MCP has not listed it yet: that can open the same local file twice. Binding refuses duplicate
  filename matches; save/close the extra instance before proceeding.
- Background Studio rendering varies by platform/version. Test two instances' captures before
  scaling up; a successful MCP capture response may still contain a blank/loading viewport. Inspect
  the image and scene readiness. If one needs focus for rendering, serialize only that UI/capture operation; model
  generation and source edits can still run concurrently. macOS Studio launch is supported; Linux
  can prepare files, serve Rojo and run Blender but cannot run Roblox Studio natively. Windows
  lifecycle automation is not implemented.

## Upstream interfaces

- [Roblox Studio MCP](https://create.roblox.com/docs/en-us/studio/mcp#use-multiple-studio-instances):
  one connection can address multiple Studios with `studio_id` on each call.
- [Rojo project format](https://rojo.space/docs/v7/project-format/): project-relative paths,
  serve address/port and place ID settings. The helper's injected marker uses ordinary
  `$className`/`$properties` fields.
- Blender's installed `--help` documents background execution, argument ordering and the
  `BLENDER_USER_RESOURCES`, `BLENDER_USER_CONFIG`, `BLENDER_USER_SCRIPTS`,
  `BLENDER_USER_EXTENSIONS`, `BLENDER_USER_DATAFILES` and `TMPDIR` overrides used here.
