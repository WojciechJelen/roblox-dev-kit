# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `roblox-isolate` skill and `/roblox:isolate`: per-agent worktree/branch, saved local place copy,
  locked Rojo port allocation and owned-process lifecycle, Studio ID binding verified through a
  Rojo-synced marker, separate headless Blender resources, and immutable camera plans with paired
  before/after image records. Lifecycle tests cover concurrent creation, wrong-instance rejection,
  restart/stop, path escape, private Blender resources and review consistency.
- `roblox-setup` skill: `install-toolchain.sh` (Rokit 1.2.0 plus the pinned toolchain, without
  editing shell profiles), `scaffold.sh` (strict-Luau Rojo template with services/controllers,
  Wally, StyLua, Selene, luau-lsp, CI, `AGENTS.md`), `adopt.sh` (existing scripts to Rojo with the
  same DataModel paths), `mcp-config.sh` (Roblox_Studio and blender for Claude Code, Codex, pi and
  Oh My Pi), `setup-blender.sh` (official Blender MCP add-on 1.0.3 with Auto Start).
- `roblox-doctor` skill: `doctor.sh` with toolchain, project, studio, blender, mcp and cloud
  sections, table and JSON output, and `--fix` for safe fixes.
- Claude Code plugin `roblox` with `/roblox:setup`, `/roblox:doctor` and the bundled Blender MCP
  server; marketplace manifest.
- `install/install.sh` and `install/uninstall.sh` for Codex, pi and Oh My Pi.
- bats-core test suites, `scripts/validate-skills.sh`, `scripts/release.sh` and CI on macOS and
  Linux.
- `blender-to-roblox` skill: `run_blender.sh` (headless Blender, exit code passed through, never
  `--factory-startup` by default), `check_mesh.py` (triangles after modifiers, textures, n-gons,
  loose geometry, UVs, materials, transforms, sizes in studs and required names against Roblox's
  limits), `export_fbx.py` (checks first, then FBX with Roblox's documented Blender settings, one
  file or one per object), `render_preview.py` (Workbench preview that leaves the scene as it was)
  and `upload-asset.sh` (Open Cloud Assets API with operation polling, retries on 429 and 5xx, the
  key kept out of argv and output), plus references on Roblox's export rules, the workflow, the
  Blender MCP tools and the Open Cloud Assets API, each fact with its source.
- `evals/`: four `claude plugin eval` cases (`setup-empty-dir`, `doctor-missing-blender`,
  `adopt-existing`, `check-mesh-report`) and `scripts/validate-evals.sh`, which checks their
  structure in `make validate` without running them.
- Opt-in real-Blender suites for `check_mesh.py` and `export_fbx.py` (`RDK_BLENDER_TESTS=1`).
- Per-project install, the default the setup skill offers: `mcp-config.sh --project DIR` writes the
  project's own `.mcp.json` (`claude mcp add-json -s project`), `.codex/config.toml`, `.pi/mcp.json`
  (`pi mcp add -l`) or `.omp/mcp.json`, skipping servers the harness already reads for that project;
  `install.sh --project DIR` passes it through and prints the Claude Code project-scope plugin
  commands (`--no-plugin` for loose skills); `scaffold.sh --install-kit` installs into a new
  project when asked; the doctor judges MCP registrations for the project it runs in and only
  warns about a missing user-scope server outside a project.
- Per-project review fixes: Codex project TOML is only ever extended into valid TOML (inline and
  dotted server definitions count, results are checked with `tomllib` when available, risky forms
  are left to the user); an empty or broken `.omp/mcp.json` no longer ends up empty or aborts the
  run, and its mode is kept; plugin enablement follows Claude Code's local > project > user
  precedence; `--project` uses physical paths and refuses Rojo subfolders (without `--force`) and
  plugin folders; the doctor treats `--project` as a project and offers the plugin before a loose
  Blender server; `uninstall.sh --project` shows project-scope removal commands; `scaffold.sh`
  validates `--install-kit` first and passes `--install-kit-args` on.
- `find-resources` skill and `/roblox:find-resources`: a "find before you build" rule for things
  that are laborious or poor when built from parts (trees, vehicles, PBR materials, sounds, icons),
  the Creator Store through Studio MCP `search_asset` first, then `search.sh` (Poly Haven,
  ambientCG, Sketchfab and the Creator Store's toolbox API without keys; Freesound, Pixabay and Poly
  Pizza with free keys kept out of argv and output), a license gate (CC0 preferred, CC-BY with a
  credit, no NC), `fetch.sh` for CC0 texture sets with OpenGL normal maps, checksums, `SOURCE.json`
  and a `CREDITS.md` row via `credit.sh`, and `scan-model.sh` (Lune) that lists a model's scripts
  and flags backdoor patterns such as `require(<id>)`, `loadstring`, `getfenv`, web requests,
  obfuscation and hidden purchase prompts. References on every source, the licenses and the
  scanner's patterns; the template's `AGENTS.md` gained an "Assets: find before you build" section;
  two eval cases (`find-tree-model`, `scan-free-model`).
- `lib/common.sh`: `rdk_find_lune` (skips a Rokit shim that cannot resolve outside a project),
  `rdk_md5`, `rdk_uri`, and a `RDK_USER_AGENT` for web requests.

### Fixed (pre-release review)

- Oh My Pi: servers it imports (project `.mcp.json` / `.codex/config.toml` by default; Claude Code
  and Codex user configs and Claude Code plugins via `enabledProviders`) count as registered in the
  doctor and are not registered again by `mcp-config.sh`.
- The Blender MCP server is fetched into uv's cache by `setup-blender.sh` and `mcp-config.sh`
  (`--no-warm` to skip), so the first MCP session no longer times out on a ~45 s cold start.
  The plugin launches the wrapper through `bash`.
- `adopt.sh` rejects `.`, `..` and backslash segments in DataModel paths, which could move files
  outside the project.
- `install-toolchain.sh --trust` records trust with `rokit trust` and runs a plain `rokit install`,
  so later installs (and the doctor's `--fix`) do not prompt again; `ROKIT_ROOT` is exported for
  every rokit call; new `--rokit-only`.
- Claude Code's project `.mcp.json` counts as a registration and feeds the duplicate check (a
  plugin's own bundled `.mcp.json`, next to `.claude-plugin/plugin.json`, does not).
- Wally and rokit.toml table headers with trailing comments are recognised.
- `validate-skills.sh` also checks script names that contain underscores.
- `export_fbx.py` exported an empty FBX for hidden, viewport-disabled or unselectable objects
  (Blender's exporter only writes `context.selected_objects`); it now shows and unlocks them for
  the export, restores them afterwards, and fails with a usage error when a target still is not
  selected. Objects in a collection excluded from the view layer are a usage error (exit 2)
  instead of a crash. `check_mesh.py` warns about all of these.
- `check_mesh.py` counted image nodes connected to nothing (which the exporter never writes) as
  textures; only images feeding the material output count now, others get a warning. Textures
  over 4096 px are violations and over 1024 px (the PBR maximum, `--texture-budget`) warnings,
  instead of treating 1024 as Roblox's import limit. Curves, text and metaballs in the checked
  scope get a "convert to mesh" warning.
- `render_preview.py` adds a missing `.png` to `--out` (Blender did, and the script then failed).
- `upload-asset.sh` removes `ROBLOX_API_KEY` from its environment before running anything, so no
  child process inherits it, and accepts any 2xx answer.
- Eval graders that forbid a command no longer run past the end of that command in the
  JSON-encoded tool input; `validate-evals.sh` also checks `execution:` keys; the README shows
  `--allow-tools Bash Write`.
- The export tests re-import every FBX in a fresh Blender and compare the objects.
- `scan-model.sh` no longer stalls on long words (two alias patterns were quadratic: a 5 MB line
  never finished); every pattern is linear, `require` floods are one finding, and a CPU budget
  (`RDK_SCAN_BUDGET`) stops any scan with exit 2.
- `scan-model.sh` catches the loader's common disguises: `require(-(-id))`, `select`, a table index,
  `(require)(id)`, `{require}`, calls split over lines, a variable set to the id,
  `"Http".."Service"` and `pcall(HS.GetAsync, ...)`; `require` used as a value is `require-value`.
- `fetch.sh` unpacks zip members with `unzip -p`, so a symlink member can no longer land in the
  asset folder (it pointed a "ColorMap" at `/etc/passwd`); links, folders and members over 200 MB
  are refused, member names with `[`, `*` or `?` unpack, and a set without a color map is refused.
- `fetch.sh` downloads Poly Haven's packed `arm` map when a set has no `Metal` map, and says that
  such sets are not metallic (their metalness channel is black) and how to check it.
- `fetch.sh` and `credit.sh` strip control characters from names; `fetch.sh` refuses ids that do
  not start with a letter or digit and removes the old files when a set is downloaded again at
  another resolution; `credit.sh` adds rows inside the table even when text follows it.
- `search.sh` marks a source failed when its answer has an unexpected shape, instead of breaking
  the summary; Sketchfab links use the bare uid.
- `RDK_ROJO_PORT` and `RDK_UVX` are overridable, so tests never depend on a running `rojo serve`
  or the real uvx; the kit's CI authenticates Rokit before downloading tools.
