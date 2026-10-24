# roblox-dev-kit

Agent skills for building Roblox games with AI coding agents. The kit sets up a professional
toolchain (Rokit, Rojo, Wally, StyLua, Selene, luau-lsp, Lune, Zap, Asphalt), a strict-Luau project
template, a way to move an existing Studio game into Rojo without breaking it, the Roblox Studio and
Blender MCP servers, and a doctor that says exactly what is still missing. A third skill takes models
from Blender into the game: it checks them against Roblox's limits, exports FBX with Roblox's
settings and uploads them through Open Cloud.

It is two things at once:

- a **Claude Code plugin** named `roblox` (skills, `/roblox:setup`, `/roblox:doctor`, and the
  Blender MCP server);
- a set of portable **Agent Skills** in `skills/` that Codex CLI, pi and Oh My Pi load from
  `~/.agents/skills/`.

The reasoning behind the stack is in [skills/roblox-setup/references/stack.md](skills/roblox-setup/references/stack.md).

## Skills

| Skill | What it does |
|---|---|
| `roblox-setup` | Installs the toolchain, scaffolds a new project or adopts an existing one, registers the MCP servers, installs the Blender MCP add-on |
| `roblox-doctor` | Read-only checks of toolchain, project, Studio, Blender, MCP registration and Open Cloud credentials; `--json` for agents, `--fix` for safe fixes |
| `blender-to-roblox` | Checks meshes against Roblox's limits (triangles, textures, n-gons, UVs, transforms, wheel names), renders previews, exports FBX with Roblox's documented settings, uploads assets through the Open Cloud Assets API and inserts them in Studio; works with a live Blender (Blender MCP) or headless |

The agent decides which steps apply; shell scripts in each skill do the actual work, so every step
can also be run by hand (each script has `--help`, most have `--dry-run`).

## Install

Get the kit (the scripts below run from this clone):

```sh
git clone https://github.com/WojciechJelen/roblox-dev-kit.git
cd roblox-dev-kit
```

### Per project (recommended)

Everything goes into the game's own folder, so each project carries its agent setup in its
repository and nothing changes for other projects:

```sh
install/install.sh --harness all --project path/to/game --dry-run   # look first
install/install.sh --harness all --project path/to/game
```

- Codex, pi and Oh My Pi: skills in `game/.agents/skills/`; MCP servers in the project's
  `.codex/config.toml`, `.pi/mcp.json` and `.omp/mcp.json` (Oh My Pi imports `.mcp.json` and
  `.codex/config.toml` itself, so it usually needs no file of its own).
- Claude Code: the script prints the project-scope plugin commands to run from the game folder,
  `claude plugin marketplace add /path/to/roblox-dev-kit --scope project` (or
  `WojciechJelen/roblox-dev-kit` to fetch it from GitHub) and
  `claude plugin install roblox@roblox-dev-kit --scope project` (they write `.claude/settings.json`),
  and puts Roblox Studio's server in `.mcp.json`; the plugin brings the Blender server. `--no-plugin`
  links loose skills into `.claude/skills/` instead.
- A new game: `skills/roblox-setup/scripts/scaffold.sh path/to/game "My Game" --install-kit`
  (`--install-kit-args "--dry-run --no-warm"` passes options on; the Blender server download is
  about 200 MB unless `--no-warm`).
- `--project` must be the project's root folder (the one with `default.project.json`), because
  agents read project files from the folder they start in; a subfolder needs `--force`.
- MCP only: `skills/roblox-setup/scripts/mcp-config.sh --harness <h> --project path/to/game`.

Codex and pi read project MCP files only once you trust the project, and Claude Code asks once to
approve servers from a project `.mcp.json`. Run the doctor from inside the project to check it.

The sections below install at user scope instead.

### Claude Code (user scope)

```sh
claude plugin marketplace add WojciechJelen/roblox-dev-kit    # or the path of a local clone
claude plugin install roblox@roblox-dev-kit
```

Then ask "set up this Roblox project" or run `/roblox:doctor`. The plugin bundles the official
Blender MCP server (it shows up as `plugin_roblox_blender`). It does **not** bundle Roblox Studio's
server: Studio's own Quick connect registers it as `Roblox_Studio`, and a second copy would show
every Studio tool twice. If it is missing, the setup skill adds it.

The Blender server is fetched by `uvx` on first start, which takes about 45 s (a ~200 MB download),
longer than MCP clients wait. Run the setup skill's Blender step (or
`uvx --from "git+https://projects.blender.org/lab/blender_mcp.git@v1.0.3#subdirectory=mcp" blender-mcp --help`)
once before the first session; `setup-blender.sh` and `mcp-config.sh` do this for you.

### Codex CLI, pi, Oh My Pi (user scope)

```sh
install/install.sh --harness codex     # or pi, omp, all
```

This symlinks each skill into `~/.agents/skills/` (all three harnesses read it) and registers the
MCP servers with that harness's own CLI (`codex mcp add`, `pi mcp add`) or, for Oh My Pi, in
`~/.omp/agent/mcp.json`. Oh My Pi imports project-level `.mcp.json` / `.codex/config.toml` by
default but the Claude Code and Codex *user* configs only when its `enabledProviders` setting lists
them; servers it already imports are not added again. Options: `--project DIR` (see above),
`--copy` copies instead of linking, `--no-mcp` skips MCP registration, `--dry-run` shows what would
happen. `install/uninstall.sh` removes only what this repo installed.

### Any other harness

Copy or link each folder under `skills/` wherever the harness looks for Agent Skills. Each skill
folder is self-contained (it carries its own copy of the shared shell library).

## Requirements

macOS (Linux works except for Roblox Studio), bash 3.2 or newer, git, curl, jq. Blender 5.1 or newer
for the Blender steps; [uv](https://docs.astral.sh/uv/) for the Blender MCP server. Windows paths
are stubs only.

## Working with Blender

The `blender-to-roblox` skill, and the `AGENTS.md` the setup skill writes into projects, hold agents
to a few rules:

- inspect the scene and the objects involved before changing anything;
- keep reusable operations in `.py` files in the project and run those, instead of long one-off
  snippets;
- make those scripts idempotent: find objects by name and update them, never create duplicates on a
  rerun;
- save a checkpoint copy of the `.blend` before substantial changes;
- render a preview and look at it before calling visual work done;
- one writer per open scene: never edit a scene the user or another agent is editing.

Roblox's own limits and export settings, each with its source page, are in
[skills/blender-to-roblox/references/export-rules.md](skills/blender-to-roblox/references/export-rules.md):
at most 20,000 triangles per mesh; textures up to 4096×4096, with 1024×1024 as the kit's default
budget because it is the largest size Roblox documents for PBR maps (larger gets a warning); FBX
exported with "FBX Unit Scale" (1 Blender unit = 1 stud), Forward Z and Up Y, textures copied and
embedded. Only mesh objects are checked and exported; convert curves, text and metaballs first.

## Security notes

- **Blender MCP runs model-written Python inside Blender with no sandbox** (`execute_blender_code`
  and its `_for_cli` variant execute whatever code the agent sends, with full file system access).
  Connect it only to scenes you have backed up. The add-on also requires Blender's "Allow Online
  Access" preference; `setup-blender.sh` turns that on only with `--allow-online-access`.
- The `blender-to-roblox` scripts run Blender headless with your normal preferences (never
  `--factory-startup` unless asked, so nothing can save factory settings over yours). The checks
  and the preview never change the scene; the export writes only the FBX files you name.
- **The Roblox Studio MCP server can read and change your open places**, run Luau and play-test.
  Connect only agents you trust.
- **Rokit trusts tools before installing them.** `install-toolchain.sh --trust` skips Rokit's
  per-tool prompt for the versions pinned in `rokit.toml`; the skill asks before using it.
- **Open Cloud API keys** are read from `ROBLOX_API_KEY`. The doctor reports only whether it is
  set and never prints it. `upload-asset.sh` hands it to curl through a temporary config file only
  you can read, so it never appears in the process list, in output or in `--dry-run`. Give the key
  only the Assets API (read and write), and keep it out of the repository. Uploads create assets on
  your account and go through Roblox moderation; the skill asks before uploading.
- The scripts never edit shell profiles or other harness configs on their own: they print the PATH
  line to add, and MCP registration happens only through `mcp-config.sh`, idempotently.

## Repository layout

```
skills/            the product: roblox-setup/, roblox-doctor/, blender-to-roblox/ (SKILL.md, scripts/, references/, assets/)
lib/common.sh      shared shell helpers; `make sync-lib` vendors it into each skill's scripts/lib/
mcp/               servers.json (single description of both servers) and launch wrappers
.claude-plugin/    Claude Code plugin and marketplace manifests
.mcp.json          the Blender server bundled with the plugin
commands/          /roblox:setup and /roblox:doctor
install/           install.sh / uninstall.sh for Codex, pi, Oh My Pi
tests/             bats-core suites (fake HOME, no network unless RDK_NETWORK_TESTS=1)
evals/             `claude plugin eval` cases (paid model runs; see Development)
scripts/           validate-skills.sh, validate-evals.sh, release.sh
docs/PLAN.md       design and specification
```

## Development

```sh
brew install bats-core shellcheck jq
make all          # check-sync, lint (shellcheck, JSON, py_compile), validate (skills, evals), test (bats)
```

- Edit `lib/common.sh`, never the vendored copies, then `make sync-lib`. `make check-sync` fails on
  drift; so does CI.
- Tests run every script against a fake machine under a temp directory (`RDK_HOME`, `RDK_OS`,
  `RDK_STUDIO_APP`, `RDK_BLENDER_APP` and friends; see `lib/common.sh`). They never touch the real
  HOME. Opt-in suites: `RDK_NETWORK_TESTS=1` downloads the real Rokit and tools into the fake HOME;
  `RDK_BLENDER_TESTS=1` runs `check_mesh.py`, `export_fbx.py` and `render_preview.py` in a real
  headless Blender on scenes built on the fly (`tests/fixtures/car_scene.py`), and (with
  `RDK_TEST_ADDON_ZIP=path/to/mcp-1.0.3.zip`, or network) installs the add-on, always with Blender's
  user folders in a temp directory (`RDK_REAL_BLENDER` picks the binary).
- `evals/` holds `claude plugin eval` cases (`setup-empty-dir`, `doctor-missing-blender`,
  `adopt-existing`, `check-mesh-report`). They are real, billed model runs, so they are not part of
  `make all`; `scripts/validate-evals.sh` checks their structure instead. Run them with
  `claude plugin eval . --scaffold --allow-tools Bash Write` (add `--case <name>` for one);
  `check-mesh-report` needs Blender on the machine (tag `requires-blender`).
- `claude plugin validate .claude-plugin/plugin.json` and `claude plugin validate .` check the
  manifests; `scripts/release.sh X.Y.Z` bumps every version, dates the changelog, runs `make all`,
  commits and tags (it never pushes).

## License

MIT, see [LICENSE](LICENSE).
