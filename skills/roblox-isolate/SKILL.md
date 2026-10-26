---
name: roblox-isolate
description: Creates and operates separate Roblox development environments for parallel agents, with a Git worktree and branch, local Studio place copy, verified studio_id, dedicated Rojo server, headless Blender workspace and reproducible review images. Use when agents need to work on different biomes, models or features concurrently, or when a task needs an isolated Studio verification environment.
metadata:
  version: "0.1.0"
---

# Isolated Roblox environments

Requires Python 3.9+, git and Rojo on macOS or Linux; automatic Studio launch needs macOS and
Studio MCP with `studio_id` routing. Blender work needs a headless Blender binary. No extra
Python packages are needed.

Give each worker its own environment manifest. All paths and the Studio assignment come from that
manifest, never from the coordinator's current directory or whichever window is focused. This is
working-state isolation, not a filesystem or account sandbox: MCP can still address other Studios,
and scripts still run with the user's permissions.

`SKILL_DIR` is the directory containing this file. Run
`python3 "$SKILL_DIR/scripts/environment.py" --help` for the commands; each command has `--help`.
The helper is self-contained and does not require the kit's other skills.

## Prepare and assign

1. Inspect the game's instructions, Git state, Rojo project and saved place. If the sibling
   `roblox-doctor` is available, use its project/toolchain checks. Resolve setup failures before
   creating workers. A worktree starts from a commit: checkpoint intended changes first, or use
   `--committed-only` only when the task intentionally excludes the dirty working tree. Never
   silently discard the changes from the worker's starting state.
2. Use a saved `.rbxl` or `.rbxlx` that contains the current map. Save the intended Studio session
   to a local file if necessary. A Rojo build alone may omit map content that lives only in Studio.
   Every environment copies this file; no worker opens the original or a shared Team Create place.
3. Choose each worker's ownership (biome, model files, shared files it may edit) and commit. Create
   one environment per worker, reusing an existing manifest for that worker on retries:

   ```sh
   python3 "$SKILL_DIR/scripts/environment.py" create backyard \
     --repo /path/to/game --place /path/to/saved-map.rbxl \
     --cameras /path/to/cameras.json --dry-run
   python3 "$SKILL_DIR/scripts/environment.py" create backyard \
     --repo /path/to/game --place /path/to/saved-map.rbxl \
     --cameras /path/to/cameras.json
   ```

   `--ref` selects a commit/ref; `--project` selects a project-relative Rojo project. `--copy PATH`
   explicitly copies an untracked/ignored dependency, such as `Packages`, `ServerPackages`, an
   untracked Blender texture folder or type definitions. Tracked assets already have independent
   copies in the worktree. Do not copy credentials, symlink asset directories to another worktree,
   or reuse the same `.blend` for multiple writers. Install missing dependencies **in the returned
   worktree**, according to the project's instructions. Conventional linked skill installations
   are listed as `shared_tooling`; read/run them but never edit those shared copies from a worker.

   Environment directories default to `~/.local/share/roblox-dev-kit/environments/`; `--root`
   overrides that. Use the same root for workers on this machine so port and Studio assignments
   are coordinated. Ports are allocated under a lock; an occupied port is never taken over.

4. Pass the worker the absolute manifest path, its file ownership, task and required review views.
   A harness's subagents may share the coordinator's cwd: require explicit `cwd=manifest.worktree`
   for file and Git commands. Do not switch branches in the main checkout. Delegate only within
   the user's requested scope and the harness's available parallelism.

For the resource layout, camera JSON and restart/failure handling, read
[references/environment.md](references/environment.md).

## Connect and prove the Studio assignment

Use `ENV_DIR` below for the returned `directory` (not the worktree).

```sh
python3 "$SKILL_DIR/scripts/environment.py" start "$ENV_DIR"
python3 "$SKILL_DIR/scripts/environment.py" open-studio "$ENV_DIR"
```

`start` waits for the actual Rojo HTTP server; its log is in `logs/rojo.log`. `open-studio` opens
the uniquely named local place in a new macOS Studio instance. It tracks a waiting launcher through
login/loading and also checks for a Studio process using that file. Repeating it (even with
`--reopen`) does not start another while either is alive. After deliberately closing that instance,
use `--reopen` to launch it again. Never bypass this guard with a separate OS launch command.

1. Call `list_roblox_studios` and find the **exact local filename stem** from `manifest.place` in
   the returned name. Never choose by a shared cloud place ID, list order, or an old active-instance
   tool. If no unique match exists, resolve the local window identity before continuing.
2. Enable Studio's MCP server if necessary. In **that instance's** Rojo plugin, connect to
   `127.0.0.1` and `manifest.rojo.port`. Check the sync preview before accepting it. This plugin
   connection is a Studio UI step: use supported UI tools if available, otherwise tell the user
   the exact filename and port to connect. The helper does not claim to automate the plugin.
3. Use `execute_luau(studio_id=<selected id>, datamodel_type="Edit", code=<verify-studio.luau>)`.
   Read the script from the environment directory. It only reads the Rojo-synced marker and asserts
   the environment ID. If it fails, fix the port/window assignment; **never set the marker manually
   to make verification pass**.
4. Save the fresh listing's JSON object and the verification call's returned JSON object into
   files, then bind them:

   ```sh
   python3 "$SKILL_DIR/scripts/environment.py" bind-studio "$ENV_DIR" \
     --studio-id '<id from listing>' --studios /path/to/studios.json --proof /path/to/proof.json
   ```

   The helper refuses a wrong filename, wrong marker or ID assigned to another worker. These JSON
   files are evidence supplied by the agent, not an authentication boundary; never fabricate them.
5. Before the first edit/playtest, and after any reconnect/restart, repeat the live verification.
   Supply the bound `studio_id` on **every** Studio call, including play/stop, console reads,
   navigation and screenshots. If it disappears, stop Studio work and discover/rebind it. A stored
   ID or successful OS launch alone does not mean the environment is connected or ready.

Keep source-code edits in the worktree's files so Rojo does not overwrite them. Studio content
edits belong to this worker's local place; save it before closing.

## Model and review loop

Run reusable project scripts in a separate headless Blender process:

```sh
python3 "$SKILL_DIR/scripts/environment.py" blender "$ENV_DIR" \
  --blend blender/props.blend blender/build_props.py -- --project-specific-options
```

The script and optional scene must be inside this environment. The helper sets cwd to the worktree,
uses private Blender preferences/extensions/temp folders, disables automatic execution of embedded
scripts, and serializes Blender writers **within that environment only**. Set `RDK_BLENDER_BIN` to
the real executable when PATH has a shim without bundled Python. Different environments can render
at the same time. Do not use the shared live Blender MCP scene for these workers. Inspect `.blend`
linked libraries and texture paths: pack them or copy and relink external dependencies into the
worktree before edits. Project scripts must also put checkpoints and outputs in this environment;
absolute paths in scripts are not rewritten or sandboxed.

Follow the game's modelling/export budgets and checkpoint rules (or `blender-to-roblox` when
available). For Studio review:

- Define `--cameras` before creating the environment. Capture **before** changing models, then
  **after** with the same camera manifest, viewport size, lighting, animation time and play mode.
  For games with an `EnvClock` hook, freeze it identically. Do not assume other games have that hook.
- `capture-plan "$ENV_DIR" --phase before` (or `after`) emits `screen_capture` arguments with the
  assigned Studio ID and identical camera vectors. Execute those MCP calls and inspect the returned
  images. Save the actual image bytes as PNG using the harness's image/file facility, then run
  `record-capture "$ENV_DIR" --phase before --view overview --image /path/to/capture.png`.
  Recording stores dimensions/hashes; it refuses changed cameras, duplicate captures and mismatched
  before/after dimensions. A successful capture call can still return a blank/loading viewport:
  inspect the pixels, wait for the intended scene and render to be ready, and use a serialized UI
  focus/capture step if background rendering is unavailable. Never accept a blank image as evidence.
  If the harness cannot save image results, report that evidence as inline
  only; do not invent an image file or claim the review folder is complete.
- Worktrees do not isolate uploads or Studio's application content folder. Coordinate Asphalt
  local sync and any other shared content writes, or use distinct paths. Cloud uploads require
  the task's authorization and separate asset versions/IDs when workers need different variants.
  Never concurrently update the same cloud asset or publish the game as part of isolation setup.

## Handoff and stop

Return the manifest, branch, changed source/assets, local place and before/after review images,
plus what passed in Studio and any missing verification. The coordinator integrates source changes
and regenerates shared manifests/atlases; binary `.blend` and place files cannot be text-merged.
Transfer the intended models/content explicitly and verify the combined game in an integration
Studio instance before publishing.

`status "$ENV_DIR"` reports resources and whether the recorded Rojo process is still owned/running.
It does not poll Studio. `stop "$ENV_DIR"` stops only that owned Rojo process and clears the binding;
it retains all files, branches and reviews and never kills Studio or Blender. Save and close the
assigned Studio instance separately. Remove worktrees and environment directories only after their
changes, ignored assets, local place and evidence have been integrated or archived; no automatic
deletion or branch deletion is performed by this skill.
