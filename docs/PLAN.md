# roblox-dev-kit — plan and specification

One repo that is, at the same time:

1. a **Claude Code plugin** (`roblox`) — skills + bundled MCP + `/roblox:setup`, `/roblox:doctor`;
2. a **portable set of Agent Skills** (`skills/*/SKILL.md`) usable from Codex CLI, pi, Oh My Pi (OMP) and any harness that reads `~/.agents/skills/` or `.agents/skills/`.

Organizing rule: **`skills/` is the product; everything else is a thin adapter for one harness.**
Deterministic work lives in scripts; `SKILL.md` holds only judgment (when, which option, what to verify).

The stack being set up is described in `skills/roblox-setup/references/stack.md`.

---

## 1. Verified environment facts (macOS, 2026-10-24)

Use these; do not re-derive or guess. Everything below was checked on this machine or in the upstream source during Phase 1 (the former *verify* items are resolved).

### Harnesses installed
| Harness | Version | Skills dirs | MCP config | Notes |
|---|---|---|---|---|
| Claude Code | 2.1.310 | plugin `skills/`; `~/.claude/skills/` | user and local scope in `~/.claude.json` (`$CLAUDE_CONFIG_DIR/.claude.json` when that is set), project `./.mcp.json`, plugin `.mcp.json` | `claude mcp add-json [-s local\|user\|project] <name> '<json>'` with `{"type":"stdio","command","args","env"}`; `claude plugin validate\|install\|tag\|init` |
| Codex CLI | 0.163.0 | `.agents/skills/` (repo), `~/.agents/skills/`, `~/.codex/skills/` | `${CODEX_HOME:-~/.codex}/config.toml` `[mcp_servers.<name>]` + `[mcp_servers.<name>.env]` | `codex mcp add <NAME> [--env K=V]... -- <COMMAND> [ARGS...]` (or `--url`); **silently replaces** an existing entry; already has `Roblox_Studio` |
| pi | 1.1.0 | `~/.pi/agent/skills/`, `~/.agents/skills/`, `.pi/skills/` | `~/.pi/agent/mcp.json` `{"mcpServers":{"<n>":{"command","args","env","description"}}}`, project `.pi/mcp.json` (after trust) | `pi mcp add <server> [--description T] [--env K=V]... [--cwd D] [-l] -- <command> [args...]`; **silently replaces**; `pi mcp list\|remove`, `/reload` |
| Oh My Pi (`omp`) | 18.12.6 | native `.omp` roots plus `~/.agents/skills/` (`.agents` roots are native, no opt-in) | `~/.omp/agent/mcp.json` `{"$schema": ".../oh-my-pi/.../mcp-schema.json", "mcpServers": {"<n>": {"type":"stdio","command","args","env","cwd"}}}` (http: `{"type":"http","url"}`); project `.omp/mcp.json` | **no `mcp` CLI subcommand** (only `/mcp add\|list\|reload\|test` in the TUI). Imports: see below |

`~/.agents/skills/` exists and already holds many skills → it is the shared install target for Codex, pi and OMP.

**Project scope** (checked 2026-10-24 for the per-project install; the user installs skills, plugins and MCP servers per project, never at user scope):
- Claude Code: `claude mcp add-json -s project` writes `.mcp.json` in the **current directory** (a subdirectory gets its own; checked with a scratch `HOME`/`CLAUDE_CONFIG_DIR`). `claude plugin marketplace add <src> --scope user|project|local` and `claude plugin install <p> --scope user|project|local` exist (`--help`); project scope writes `.claude/settings.json` (`extraKnownMarketplaces`, `enabledPlugins` `"roblox@roblox-dev-kit": true`), local `.claude/settings.local.json` (https://code.claude.com/docs/en/plugins/loading.md, cli-reference.md). Project-scope plugins load after the workspace trust dialog; their MCP servers and a project `.mcp.json` need one-time per-server approval.
- Codex: project `.codex/config.toml` with `[mcp_servers.<name>]`, loaded only for **trusted** projects, closest file wins (learn.chatgpt.com/docs/config-file/config-basic, /docs/extend/mcp). `codex mcp add` has no scope option and writes the user config only → the kit writes the project TOML itself.
- pi: `pi mcp add <name> -l` writes `.pi/mcp.json` in the current directory; pi reads it only after the project is trusted (`pi mcp add --help`, checked with a scratch `HOME`).
- OMP: project `.omp/mcp.json` (native), plus the default imports of `./.mcp.json` and `./.codex/config.toml` (above). No CLI → JSON written with jq.

**OMP MCP imports** (OMP `docs/settings.md`, `docs/mcp-config.md`, `model-settings.ts`): OMP reads its native `mcp.json` first, then other tools' configs; across sources the first definition of a name wins and duplicates are not merged. *Project-level* sources (`<project>/.mcp.json`, `<project>/.codex/config.toml`, `.claude/.mcp.json`) are imported by default unless `mcp.enableProjectConfig: false`. *Foreign user-level* sources (`~/.claude.json`, `~/.codex/config.toml`, Claude Code's user plugin registry) are imported only when `enabledProviders` in `~/.omp/agent/config.yml` lists them (`claude`, `codex`, `*`/`all`; default `[]`; `claude` also enables `claude-plugins`; a set `CLAUDE_CONFIG_DIR` opts Claude in); `disabledProviders` wins. This machine's `config.yml` has no `enabledProviders`, so OMP does **not** see the Claude/Codex `Roblox_Studio` entries.

### Roblox Studio
- App: `/Applications/RobloxStudio.app`
- Built-in MCP server binary (stdio, no args): `/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP`. Windows (from the docs): `cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat`.
- Registered in Claude Code (user scope) and Codex under the name **`Roblox_Studio`** — this is the name Studio's own "Quick connect" uses. Reuse it; never create a second Studio server.
- Enabling it in Studio: Assistant → … → Manage MCP Servers → "Enable Studio as MCP server" (https://create.roblox.com/docs/studio/mcp).
- Studio plugins folder (macOS): `~/Documents/Roblox/Plugins` (does not exist yet → Rojo Studio plugin not installed). `rojo plugin install` creates it and writes **`RojoManagedPlugin.rbxm`** (Rojo 7.7.1 `src/cli/plugin.rs`).
- Process check: `pgrep -x RobloxStudio` (`pgrep -f` would also match `StudioMCP`).

### Blender
- Binary: `/Applications/Blender.app/Contents/MacOS/Blender`, **5.2.1 LTS**, bundled Python 3.13. **Not on PATH.**
- `~/.local/bin` exists and **is on PATH** → `blender` symlink target for `--fix`.
- User extensions dir: `~/Library/Application Support/Blender/5.2/extensions` (not created yet). Repos: `extensions.blender.org` (module `blender_org`), `User Default` (module `user_default`), `System`.
- Blender honours `BLENDER_USER_RESOURCES` / `BLENDER_USER_CONFIG` / `BLENDER_USER_EXTENSIONS` env vars → used to test add-on installation in a temp dir.
- Add-on install that works on 5.2.1 (background, normal prefs loaded, **never** `--factory-startup`, which would save factory prefs over the user's):
  `bpy.ops.extensions.package_install_files(filepath=ZIP, repo="user_default", enable_on_install=True, overwrite=True)` → `{'FINISHED'}`. Operator properties: `filter_glob`, `directory`, `files`, `filepath`, `repo` (dynamic enum), `enable_on_install` (default True), `target`, `overwrite` (default True), `url`. Then `prefs.addons["bl_ext.user_default.mcp"].preferences.use_autostart = True`, optionally `prefs.system.use_online_access = True`, `bpy.ops.wm.save_userpref()`; persists across processes.
- Result: add-on at **`<extensions>/user_default/mcp`**, module **`bl_ext.user_default.mcp`**.
- No GNU `timeout`/`gtimeout` on this Mac → do not use `timeout` in scripts.

### Official Blender MCP (Blender Lab) — the default Blender server
- Repo: https://projects.blender.org/lab/blender_mcp (Gitea). HTML pages are behind a Cloudflare challenge for curl (403); **raw files, the API (`/api/v1/repos/lab/blender_mcp/...`) and release downloads work** with a browser-like `User-Agent`.
- Latest release **v1.0.3** (tag → commit `2cea8d56`). Assets:
  - `mcp-1.0.3.zip` (17975 bytes, sha256 `a7a9da816192502e5a0a202a396444e266b47d8fc4f74ad4698048bd43040707`) = **the Blender add-on** (`blender_manifest.toml`: id `mcp`, `blender_version_min = "5.1.0"`, permission `network`). URL: `https://projects.blender.org/lab/blender_mcp/releases/download/v1.0.3/mcp-1.0.3.zip`
  - `blender-1.0.3.mcpb` = server bundle for `.mcpb` clients (Claude Desktop). Not needed.
- Server: Python package in `mcp/` subdirectory, entry point `blender-mcp` (`blmcp:main`, argparse: `--help` exits 0), `requires-python >= 3.10`, deps `mcp[cli]`, `docutils`, `pyyaml`. Launch:
  `uvx --from "git+https://projects.blender.org/lab/blender_mcp.git@v1.0.3#subdirectory=mcp" blender-mcp`
  **Cold start ≈ 46 s (≈ 210 MB clone), warm ≈ 4 s** → MCP clients time out on the first start unless uv's cache is warmed (`... blender-mcp --help`).
- Server env: `BLENDER_MCP_HOST`, `BLENDER_MCP_PORT` (add-on connection); `BLENDER_PATH` (Blender binary for the `*_for_cli` tools; default `blender` on PATH).
- Add-on ↔ server: TCP `localhost:9876`. Add-on prefs: `host`, `port`, `use_autostart` (**Auto Start, default on**), `autostart_delay`, polling intervals. The add-on **refuses to start its server while Preferences › System › Network › "Allow Online Access" is off** (`use_online_access`, off by default). Headless serving: `blender --background [file.blend] --command blender_mcp [--port N]`.
- Tools (26, confirmed end to end): `execute_blender_code`, `get_blendfile_summary_*`, `get_object_detail_summary`, `get_objects_summary`, `get_python_api_docs`, `search_api_docs`, `search_manual_docs`, `get_screenshot_of_area_as_image`, `get_screenshot_of_window_as_image|json`, `jump_to_*`, `render_thumbnail_to_path`, `render_viewport_to_path`. `execute_blender_code` and the five `get_blendfile_summary_*` tools have a `*_for_cli` variant that opens a `.blend` in a **background Blender process** (no live Blender needed; 120 s timeout; unsaved changes in a live Blender with the same file are snapshotted to `<file>_mcp_NNNN.blend` first); `get_objects_summary` and `get_object_detail_summary` do not (Phase 2, tool sources at `v1.0.3`). Code returns data by assigning a dict to `result`; `render_thumbnail_to_path` writes to `<Blender temp dir>/blender_mcp/<basename>` and returns that path.
- Security: executes LLM-generated Python in Blender without guards. Say so in docs.
- Community alternative `ahujasid/blender-mcp` ("MCP for Blender", `addon.py`, code uses `blendermcp_*` names) uses the **same port 9876** → optional only, never both at once. Its installer also registers a server named `blender`.

### Rokit
- Latest **1.2.0**. The official installer (`scripts/install.sh`, pinned via the `v1.2.0` tag URL) takes only a positional version (fetches tag `v$1`) and `GITHUB_PAT`; **there is no no-modify-path option**. It runs `rokit self-install`, which always appends `. "$HOME/.rokit/env"` to `~/.profile`, `~/.bashrc` and `~/.zshenv` (creating the one matching `$SHELL`). `ROKIT_ROOT` overrides the store location independently of `$HOME` → `install-toolchain.sh` runs the installer with `ROKIT_ROOT=<real store>` and `HOME=<throwaway dir>` so the appends land in the throwaway dir.
- Trust: `rokit install`/`add` prompt per untrusted tool and **bail when stderr is not a TTY**. `rokit install --no-trust-check` installs without recording trust (later plain installs prompt again); `rokit trust <owner/repo>...` records it. `rokit authenticate github --token T --skip-verify` avoids anonymous API limits.
- Pinned in the template `rokit.toml` (GitHub releases API, 2026-10-24): `rojo-rbx/rojo@7.7.1`, `UpliftGames/wally@0.3.2`, `lune-org/lune@0.11.1`, `JohnnyMorganz/StyLua@2.6.0`, `Kampfkarren/selene@0.32.0`, `JohnnyMorganz/luau-lsp@1.70.1`, `red-blox/zap@0.6.29`, `jacktabscode/asphalt@2.0.2`. All install and the template passes `stylua --check`, `selene`, strict `luau-lsp analyze` and `rojo build` with them.

### Rojo
- A project node with `$path` gets `$ignoreUnknownInstances = false` unless set (7.7.1 `snapshot_middleware/project.rs:285-291`): Rojo deletes instances it does not know about under it. `"$path": {"optional": "Packages"}` makes a missing folder legal.

### Toolchain state
Present: `uv`/`uvx` (`/opt/homebrew/bin`), node 24, git 2.50, `shellcheck`, `jq` (also `/usr/bin/jq` on macOS), `python3`, Homebrew, `bats` 1.14.0 (installed for Phase 1).
Missing: `rokit`, `rojo`, `wally`, `lune`, `stylua`, `selene`, `luau-lsp`, `zap`, `asphalt`.

---

## 2. Repository layout

```
roblox-dev-kit/
├── README.md                      # what it is; install for Claude Code / Codex / pi / OMP; security notes
├── LICENSE (MIT) · CHANGELOG.md · Makefile   (sync-lib, check-sync, lint, test, validate)
├── docs/PLAN.md                   # this file
│
├── skills/                        # ── PORTABLE CORE (Agent Skills spec)
│   ├── roblox-setup/
│   │   ├── SKILL.md
│   │   ├── scripts/
│   │   │   ├── lib/common.sh                 # vendored copy of /lib/common.sh
│   │   │   ├── install-toolchain.sh          # Rokit → `rokit install`; idempotent; never edits shell rc
│   │   │   ├── scaffold.sh <dir> <name>      # new project from assets/template
│   │   │   ├── adopt.sh <dir> --mapping <file> # existing loose scripts → Rojo tree (same DataModel paths)
│   │   │   ├── setup-blender.sh              # official add-on install + Auto Start; `blender` symlink
│   │   │   └── mcp-config.sh --harness claude|codex|pi|omp [--dry-run]
│   │   ├── assets/template/                  # see §4
│   │   └── references/
│   │       ├── stack.md                      # the "why" (already present)
│   │       ├── template-layout.md            # src/ ↔ DataModel mapping, where things go
│   │       ├── libraries.md                  # verified Wally coordinates / install notes for optional libs
│   │       └── manual-steps.md               # Rojo Studio plugin, Blender add-on, Open Cloud key, Studio Quick connect
│   ├── roblox-doctor/
│   │   ├── SKILL.md
│   │   └── scripts/lib/common.sh · doctor.sh
│   ├── blender-to-roblox/                    # PHASE 2
│   │   ├── SKILL.md
│   │   ├── scripts/lib/common.sh · run_blender.sh · check_mesh.py · export_fbx.py · render_preview.py · upload-asset.sh
│   │   └── references/export-rules.md · workflow.md · open-cloud-assets.md · blender-mcp-tools.md
│   └── find-resources/                       # §14
│       ├── SKILL.md
│       ├── scripts/lib/common.sh · search.sh · fetch.sh · credit.sh · scan-model.sh · scan-model.luau
│       └── references/sources.md · licenses.md · safety.md
│
├── lib/common.sh                  # SINGLE SOURCE of shared shell helpers; `make sync-lib` copies into each skill
│
├── mcp/
│   ├── servers.json               # neutral source of truth for both servers
│   ├── studio-mcp.sh              # locate StudioMCP (macOS now; Windows/Linux stubs) and exec it
│   └── blender-mcp.sh             # exec uvx … blender-mcp (pinned v1.0.3); honours BLENDER_MCP_HOST/PORT
│
├── .claude-plugin/plugin.json     # ── CLAUDE CODE ADAPTER (name "roblox")
├── .claude-plugin/marketplace.json
├── .mcp.json                      # bundles ONLY the Blender server (see §5)
├── commands/setup.md · doctor.md · find-resources.md  # CC-only aliases → /roblox:setup, /roblox:doctor, /roblox:find-resources
│
├── install/install.sh · uninstall.sh   # ── OTHER HARNESSES (symlink skills, then mcp-config)
│
├── tests/                         # bats-core; no network unless RDK_NETWORK_TESTS=1; fixtures/car_scene.py
├── evals/                         # `claude plugin eval` cases (PHASE 2)
├── .github/workflows/ci.yml
└── scripts/validate-skills.sh · validate-evals.sh · release.sh
```

---

## 3. Shared library: `lib/common.sh`

Sourced by every script (`source "$(dirname "$0")/lib/common.sh"`). Requirements:

- `#!/usr/bin/env bash`, `set -euo pipefail`, shellcheck-clean, works on macOS bash 3.2 **and** bash 5 (no associative arrays, no `mapfile`, no `${var,,}`).
- Every external path is **overridable by env var** so tests can fake the machine:
  `RDK_HOME` (default `$HOME`), `RDK_BLENDER_BIN`, `RDK_BLENDER_APP`, `RDK_STUDIO_APP`, `RDK_STUDIO_MCP_BIN`, `RDK_ROKIT_BIN_DIR` (`$RDK_HOME/.rokit/bin`), `RDK_BLENDER_MCP_PORT` (9876).
- Helpers: `rdk_os` (macos/linux/windows), `rdk_find_blender`, `rdk_blender_version`, `rdk_blender_ext_dir`, `rdk_find_studio_mcp`, `rdk_has <cmd>`, `rdk_port_open <host> <port>` (bash `/dev/tcp` or python fallback; no `nc` dependency), `rdk_json_escape`, logging (`rdk_info|warn|err`), colour only when stdout is a TTY and `NO_COLOR` unset.
- Harness detection: `rdk_harness_installed claude|codex|pi|omp`, and config path getters for each (from §1).
- `make sync-lib` copies `lib/common.sh` → `skills/*/scripts/lib/common.sh`; `make check-sync` diffs and fails CI on drift. Each copy carries a header line "vendored from /lib/common.sh — edit the source, run make sync-lib".

Why vendor: `npx skills add`, Codex, pi and OMP install skill folders individually, so a skill can't reference `../other-skill`.

---

## 4. `roblox-setup` skill

### Modes (SKILL.md decides, scripts execute)
1. **toolchain** — `install-toolchain.sh [--project DIR | --global | --rokit-only] [--trust]`: install Rokit 1.2.0 via its official installer if missing (no no-modify-path option exists, so the installer runs with a throwaway `HOME` and the real `ROKIT_ROOT`, §1), then `rokit install` in the project (or `rokit add --global` for a global toolchain when no project). `--trust` first records trust with `rokit trust <owner/repo>...` (needed without a TTY; the agent asks the user). Prints the PATH line the user must add; **never edits `~/.zshrc`/`~/.bashrc`**.
2. **new** — `scaffold.sh <dir> <name>`: copy `assets/template`, substitute `{{PROJECT_NAME}}`, `git init` if not a repo, generate `sourcemap.json` if rojo is available. Refuses to overwrite a non-empty dir unless `--force`.
3. **adopt** — `adopt.sh <dir> --mapping <tsv>`: for an existing project with loose scripts (e.g. Motor Rivals: `src/Factory.lua → ReplicatedStorage.RivalsFactory (ModuleScript)`). The **agent** writes the mapping file (from README/Studio tree); the **script** turns it into `default.project.json` + moves/renames files (`.server.lua` / `.client.lua` / ModuleScript rules). Keeps `.lua` extensions as-is. Dry-run by default, `--apply` to execute.
4. **mcp** — `mcp-config.sh --harness <h> [--project DIR]`: registers servers per §5 using the harness's own CLI when it has the scope (`claude mcp add-json -s user|project`, `codex mcp add` for user scope, `pi mcp add [-l]`), else writing the file (OMP JSON; Codex project TOML). Project CLI calls run in DIR. Idempotent: skips servers the harness already gets under the expected name from any scope it reads for the project (including the roblox plugin and OMP imports, §5). Warms uv's cache after registering `blender` (`--no-warm` skips). `--dry-run` prints what it would do.
5. **blender** — `setup-blender.sh`: download `mcp-<ver>.zip` (pinned, sha256 checked), install with `Blender --background --python-exit-code 1 --python-expr` using `bpy.ops.extensions.package_install_files(filepath=…, repo='user_default', enable_on_install=True, overwrite=True)` (verified on 5.2.1, §1), enable Auto Start in the add-on preferences (optionally "Allow Online Access" with `--allow-online-access`) and save prefs; create `~/.local/bin/blender` symlink if `blender` not on PATH; warm uv's cache for the server. Refuse if Blender < 5.1 or while Blender is running. Warn if the community `blender-mcp` add-on is also installed (port clash).
6. Finish: run `roblox-doctor`'s `doctor.sh` (if the sibling skill is installed) or print the equivalent checklist. **Setup is done when doctor is green.**

### Template (`assets/template/`)
- `rokit.toml` — pin **exact latest versions** looked up from GitHub releases at implementation time (`rojo-rbx/rojo`, `UpliftGames/wally`, `lune-org/lune`, `JohnnyMorganz/StyLua`, `Kampfkarren/selene`, `JohnnyMorganz/luau-lsp`, `red-blox/zap`, `jacktabscode/asphalt`). Record the lookup date in a comment.
- `default.project.json` — tree:
  `src/ServerScriptService → ServerScriptService`, `src/StarterPlayerScripts → StarterPlayer/StarterPlayerScripts`, `src/ReplicatedStorage/Shared → ReplicatedStorage/Shared`, `Packages → ReplicatedStorage/Packages`, `ServerPackages → ServerScriptService/ServerPackages`. Sensible `HttpService.HttpEnabled=false`, `Workspace` etc. only if needed.
- `wally.toml` — no dependencies by default; `[dependencies]`/`[server-dependencies]` sections present with comments pointing to `references/libraries.md`.
- `selene.toml` (`std = "roblox"`), `stylua.toml`, `.luaurc` (strict mode, aliases for `Shared`, `Packages`), `.gitignore` (`Packages/`, `ServerPackages/`, `sourcemap.json`, `roblox.yml`, `*.rbxl.lock`, `build.rbxl`).
- `.vscode/settings.json` (luau-lsp: sourcemap on, roblox types, project file) + `extensions.json` (luau-lsp, stylua, selene).
- `.github/workflows/ci.yml` — rokit install → `stylua --check` → `selene src` → `luau-lsp analyze` (with sourcemap + roblox types) → `rojo build -o build.rbxl`.
- `AGENTS.md` — project instructions for any harness: Rojo loop (`rojo serve`, Studio edits are not source of truth), strict Luau, services/controllers pattern, how to test, **Blender section**: inspect before editing, keep reusable ops in `.py` files, scripts idempotent (no duplicate objects), checkpoint before big changes, render preview before declaring visual work done, one writer per open scene.
- `CLAUDE.md` — single line `@AGENTS.md`.
- `src/ServerScriptService/Server.server.luau` (loads `Services/*`, `init()` then `start()`), `src/StarterPlayerScripts/Client.client.luau` (same for `Controllers/*`), `src/ReplicatedStorage/Shared/Example.luau`, one example service and controller. All `--!strict`.

### `references/libraries.md`
For each optional lib — ProfileStore, Zap (CLI, not Wally), React-lua, Charm, Vide, Trove, Promise, GoodSignal, Jest-lua — give the **verified** install coordinate (Wally scope/name via `https://api.wally.run/v1/package-search?query=…` or the project's README) and one paragraph on when to add it. Mark anything you could not verify.

---

## 5. MCP policy

| Server | Name | Where it is registered | Why |
|---|---|---|---|
| Roblox Studio | `Roblox_Studio` | per harness by `mcp-config.sh`, **only if the harness does not already get it** | Studio's Quick connect already creates it under this name in Claude Code and Codex; a plugin-bundled copy would duplicate every Studio tool |
| Blender (official) | `blender` | Claude Code: bundled in plugin `.mcp.json` (appears as `plugin_roblox_blender`); other harnesses: `mcp-config.sh` | plugin users get it on enable; `mcp-config.sh --harness claude` adds it only when the plugin is not enabled |

"Already gets it" means, for the project in question (`mcp-config.sh --project DIR`, the doctor's detected project or `--project`, else the current directory): Claude Code user scope, local scope for the project (keyed by its physical path), the project's `./.mcp.json`, or — for `blender` — the `roblox` plugin enabled by the most specific settings file that mentions it (`.claude/settings.local.json` > `.claude/settings.json` > `~/.claude/settings.json`); Codex its user config or the project's `.codex/config.toml` (a server counts with its own `[mcp_servers.<n>]` table, inline or with dotted keys — an `.env` subtable alone does not); pi its user config or the project's `.pi/mcp.json`; OMP its native user `mcp.json`, the project's `.omp/mcp.json`, the project files it imports by default (`./.mcp.json`, `./.codex/config.toml`), or the Claude Code / Codex user configs (and Claude Code plugins) when `enabledProviders` opts them in (§1). `doctor.sh` reports the source it found.

`mcp/servers.json` is the single description (`command`, `args`, `env`, `description`, `homepage`), vendored into `skills/roblox-setup/assets/mcp-servers.json` by `make sync-lib` (installed skill folders do not contain `mcp/`) and consumed by `mcp-config.sh`, which registers absolute commands (StudioMCP path; absolute `uvx` plus `BLENDER_PATH`). `.mcp.json` runs the wrapper through bash (`"command": "bash", "args": ["${CLAUDE_PLUGIN_ROOT}/mcp/blender-mcp.sh"]`) so it does not depend on the exec bit surviving plugin caching; wrapper scripts (`mcp/*.sh`) locate the binaries per OS.

Because a cold `uvx` start (≈ 46 s) exceeds MCP client start-up timeouts, `setup-blender.sh` and `mcp-config.sh` (after registering `blender`, or when the plugin provides it) run `uvx --from <spec> blender-mcp --help` once to warm uv's cache; `--no-warm` skips it.

---

## 6. `roblox-doctor` skill — `doctor.sh`

`doctor.sh [--json] [--fix] [--section toolchain|project|studio|blender|mcp|cloud] [--quiet]`
Exit 0 = no failures, 1 = at least one `fail`, 2 = usage error. Works with no project (global checks) and inside a Rojo project.

Each check: `id`, `section`, `status` (`ok|warn|fail|skip`), `detail`, `fix` (human command/instruction). Default output: aligned table with `✓ ! ✗ -`; `--json` emits `{ "checks": [...], "summary": {ok,warn,fail,skip} }` (build JSON with `jq` if present, else careful manual escaping; test both).

| Section | Checks (status if failing) |
|---|---|
| toolchain | rokit on PATH (fail); `~/.rokit/bin` on PATH (warn); each tool in `rokit.toml` (project) or the standard set (global) resolves (fail) and matches pinned version (warn); git (fail); uv/uvx (warn) |
| project (only if `default.project.json` found upward) | `rokit.toml`, `wally.toml`, `.luaurc`, `selene.toml`, `stylua.toml` present (warn); `Packages/` present when wally.toml has deps (warn); `sourcemap.json` newer than newest `src/**` file (warn); git repo (warn); `rojo serve` listening on 34872 (info → `ok`/`skip` with detail) |
| studio | Studio app installed (fail); StudioMCP binary found (fail); Rojo Studio plugin in `~/Documents/Roblox/Plugins` (warn); Studio running (info) |
| blender | `blender` on PATH (fail; fix = symlink into `~/.local/bin`); version ≥ 5.1 (fail; official add-on needs it); official add-on dir present under `<ext dir>/user_default/mcp` (confirmed by a real install) (fail); add-on TCP port reachable (warn: "Blender not running or Auto Start off"); community add-on also installed (warn: port clash); uvx can resolve the server — only with `RDK_NETWORK_TESTS=1`/`--online` (skip otherwise) |
| mcp | for each **installed** harness, judged for the project found upward (or `--project`): `Roblox_Studio` registered, `blender` registered or plugin enabled — user config or the project's files; missing → fail inside a project, warn outside one (per-project registration is the default); duplicates (warn). Harness not installed → `skip` |
| cloud | `ROBLOX_API_KEY` set (warn; never print value); `ROBLOX_CREATOR_TYPE`/`ROBLOX_CREATOR_ID` set (warn) |

`--fix` applies only safe, idempotent fixes: blender symlink, `rokit install`, `wally install`, `rojo sourcemap`, `rojo plugin install`, `mkdir ~/.local/bin`. It never edits shell rc files or harness config files (that is `mcp-config.sh`'s job, invoked explicitly).

---

## 7. Claude Code adapter

- `.claude-plugin/plugin.json`: `name: "roblox"`, `version: "0.1.0"`, description, author, `skills: "./skills"` (check the current schema with `claude plugin init --help` / docs; validate with `claude plugin validate .`).
- `.claude-plugin/marketplace.json`: one plugin entry with `source: "./"` so `claude plugin marketplace add /path/or/github` works.
- `commands/setup.md`, `commands/doctor.md`: one-paragraph aliases that tell Claude to use the `roblox-setup` / `roblox-doctor` skill with `$ARGUMENTS`.
- `.mcp.json`: `{"mcpServers": {"blender": {"command": "${CLAUDE_PLUGIN_ROOT}/mcp/blender-mcp.sh"}}}`.

## 8. Other-harness adapter — `install/install.sh`

`install.sh --harness codex|pi|omp|claude|all [--project <dir>] [--no-plugin] [--copy] [--no-warm] [--dry-run]`
- Default: symlink each `skills/<name>` into `~/.agents/skills/<name>` (Codex + pi + OMP) — `--harness claude` → `~/.claude/skills/`; `--project <dir>` → `<dir>/.agents/skills/`, MCP via `mcp-config.sh --project <dir>`, and for Claude Code the printed project-scope plugin commands (Studio's server only in `.mcp.json`); `--no-plugin` links `<dir>/.claude/skills/` and registers both servers instead.
- `--copy` copies instead of symlinking (for machines where the repo won't stay).
- Then calls `mcp-config.sh --harness <h>` for each harness, printing what changed.
- `uninstall.sh` removes only links/copies that point into this repo.

## 9. Tests, CI, quality

- **bats-core** (`brew install bats-core` locally; `bats-core/bats-action` or `npm i -g bats` in CI). Tests fake the machine via `RDK_*` env vars and a temp `HOME`; **no test installs anything into the real user environment**. Network tests gated by `RDK_NETWORK_TESTS=1`.
- `tests/common.bats` (helpers), `tests/doctor.bats` (table + `--json` schema + exit codes + each section with fake pass/fail fixtures), `tests/scaffold.bats` (scaffold → files exist, placeholders replaced, refuses non-empty dir, valid JSON project file), `tests/adopt.bats` (mapping → project.json), `tests/mcp-config.bats` (`--dry-run` output per harness), `tests/install.bats` (symlinks, uninstall only removes own links).
- Phase 2: `tests/run_blender.bats` (fake Blender: argument order, exit code, dry run), `tests/upload-asset.bats` (fake curl replaying Open Cloud responses: pending → done, 429 and 5xx retries, errors, moderation, the key never in argv or output), `tests/check_mesh.bats` and `tests/export_fbx.bats` (real headless Blender behind `RDK_BLENDER_TESTS=1`, scenes built by `tests/fixtures/car_scene.py`, Blender user folders in a temp dir); `scripts/validate-evals.sh` checks the `evals/` cases.
- `scripts/validate-skills.sh`: every `skills/*/SKILL.md` has frontmatter `name` (== dir name, kebab-case ≤ 64) and `description` (≤ 1024 chars, third person, says *when* to use), body ≤ 500 lines, referenced files exist.
- `shellcheck` all `.sh`; `python3 -m py_compile` all `.py`.
- CI (`.github/workflows/ci.yml`): macos-latest + ubuntu-latest → shellcheck, `make check-sync`, validate-skills, bats. Optional job (allowed to fail): install rokit + scaffold + `rojo build`.
- `Makefile` targets: `sync-lib`, `check-sync`, `lint`, `test`, `validate`, `all`.

## 10. SKILL.md conventions

Follow the Agent Skills spec and the `skill-creator` skill's guidance: frontmatter `name`, `description` (what + when, third person, include trigger phrases like "set up a Roblox project", "rojo", "doctor", "is my Roblox environment ready"), optional `compatibility` ("Requires macOS or Linux, bash, git; Blender ≥ 5.1 for Blender steps"), `metadata.version`. Keep SKILL.md short and procedural; push detail into `references/`. Scripts are run with absolute paths relative to the skill dir (`"$SKILL_DIR/scripts/doctor.sh"`); SKILL.md explains how to locate `SKILL_DIR` in each harness (the directory containing SKILL.md).

## 11. Phasing

- **Phase 1**: everything in §2 except `skills/blender-to-roblox/` and `evals/`. Validate on this machine with fake-home tests; `claude plugin validate .` passes; `shellcheck`, bats and `validate-skills` green.
- **Phase 2** (done 2026-10-24): `blender-to-roblox` (export rules, `check_mesh.py`, `export_fbx.py`, `run_blender.sh` with `--background --python-exit-code 1`, `upload-asset.sh` via Open Cloud Assets API with operation polling, `references/*`), plus `evals/`. Verified with the bats suites (fake Blender and fake curl), the opt-in real-Blender suites on Blender 5.2.1, a headless smoke export, and `scripts/validate-evals.sh` (the eval cases were not run: they are paid model runs).
- **Then**: review (fresh reviewer), fix pass, real-machine setup run with the user (actual Rokit install, Blender add-on, MCP registration), adopt Motor Rivals (`~/workspace/antek-filip-rivals`).

## 12. Non-goals for v1
Windows support beyond path stubs; roblox-ts; publishing/CI for the *game* beyond the template workflow; custom pi/OMP extensions; the community Blender server beyond an optional profile.

## 13. Deviations from the original plan

### Phase 1

- `plugin.json` has no `skills` key: the manifest key *adds* to the default `skills/` scan, so listing `./skills` would be redundant.
- `mcp-config.sh` registers absolute commands, not `mcp/*.sh`: installed skill folders do not contain the repo's `mcp/`; `servers.json` is vendored into the setup skill instead.
- OMP gets its own `mcp.json` entries unless it already imports the server (project files by default, user configs only via `enabledProviders`); the plan assumed automatic user-level imports.
- `install-toolchain.sh` swaps `HOME` while running the Rokit installer, because `self-install` edits shell profiles with no opt-out.
- `install-toolchain.sh --trust` runs `rokit trust` for the pinned tools and then a plain install (non-TTY Rokit refuses untrusted tools; `--no-trust-check` would not record trust). `--rokit-only` lets CI authenticate before the downloads.
- `setup-blender.sh` adds `--allow-online-access` (the add-on needs Blender's Online Access), refuses while Blender runs unless `--force`, adds `--zip`, `--no-symlink`, `--no-warm`, and warms uv's cache.
- `adopt.sh` writes one project node per script under services with `$ignoreUnknownInstances: true` instead of mapping services to folders (a `$path` service would delete Studio-made content); it rejects `.`/`..`/backslash path segments; `--with-config` writes a non-strict `.luaurc` for existing code.
- Template: `"$path": {"optional": ...}` for `Packages`/`ServerPackages`; `{{PACKAGE_NAME}}` placeholder (Wally needs kebab-case); `[dev-dependencies]`; extra `.gitignore` entries; template CI uses the official Rokit installer rather than a third-party action.
- Windows Studio stub uses the documented `%LOCALAPPDATA%\Roblox\mcp.bat`.
- Extra overrides (`RDK_OS`, `RDK_NO_JQ`, `RDK_LOCAL_BIN`, `RDK_STUDIO_PLUGINS_DIR`, `RDK_ROJO_PORT`, `RDK_UVX`), doctor `--project`, `install.sh --no-mcp`, and extra test suites (`setup-blender`, `install-toolchain`, `validate`).
- `claude plugin validate .` validates only the marketplace manifest when both manifests exist, so CI-style checks also run `claude plugin validate .claude-plugin/plugin.json --strict`, `skills` and `commands`.

### Phase 2

- Extra script `render_preview.py`: the skill's rule "render and look before calling it done" needs a headless way to render; `render_thumbnail_to_path` needs a live Blender (or a `_for_cli` session) and a scene camera. It frames the objects with a temporary camera (Workbench) and removes it again.
- `run_blender.sh`: `--factory-startup` exists but only as an opt-in; Blender runs with `--quiet` unless `--verbose`; a bare script name resolves to the skill's own scripts; one `--` right after the script is dropped (Blender's own `--python X -- args` habit).
- `check_mesh.py`: `--require-names REGEX` is paired with `--require-count N`, because a regex alone cannot require all four wheels; with Blender's unique object names, `'^Wheel_(FL|FR|RL|RR)$' --require-count 4` means exactly those four. Only triangles, textures and required names are violations; n-gons, loose geometry, UV problems, several materials ("one material per mesh object" in the texture specs), unapplied or negative transforms, zero thickness and unapplied modifiers are warnings, since Roblox words most of them as "where possible" and the importer accepts them. Extra options: `--no-modifiers`, `--scale`, `--report FILE`. `--json` prints one line, because Blender writes its own status lines to stdout in no fixed order.
- `export_fbx.py`: modifiers are applied only with `--apply-modifiers` (as briefed), and the check then counts the same mesh that is exported; without it a warning names the modifiers left out. Extra options: `--scale`, `--dry-run`, `--json`, `--report`. Both scripts are importable (`check_mesh.check`, `export_fbx.export`) for `execute_blender_code`.
- `upload-asset.sh`: also `--type Image` (the usage guide lists Decal and Image for the same files) and `--timeout`; `--description` defaults to the name (the API requires one); a `Rejected` moderation result exits 1; `RDK_UPLOAD_MAX_DELAY` caps waits so the tests run instantly.
- `scripts/validate-evals.sh` (run by `make validate`): `claude plugin eval` has no validate or list mode, so the case format is checked against the documented keys instead.
- Evals: `claude plugin eval` passes only `EVAL_*` variables to the agent and keeps HOME unreadable, so `doctor-missing-blender` scaffolds a fake machine plus a `machine.env` with the `RDK_*` overrides that the prompt tells the agent to load, and `check-mesh-report` writes a `blender.env` that keeps Blender's user folder in the workspace. Cases with input files need `--scaffold`.
- `validate-skills.sh` now also matches script names with underscores (`run_blender.sh`).
- The template's `AGENTS.md` and `references/stack.md` said "about 20k triangles … 1 stud ≈ 0.28 m"; they now state the documented limit and that 1 Blender unit = 1 stud with FBX Unit Scale (0.28 m is the physics unit).
- §1 said every summary tool has a `_for_cli` variant; `get_objects_summary` and `get_object_detail_summary` do not (corrected there).
- The doctor already had the `cloud` section; it is unchanged.

Per-project install (added after Phase 2 at the user's request: skills, plugins and MCP servers per project, never at user scope):
- `mcp-config.sh --project DIR`, `install.sh --project DIR` passing it through, `scaffold.sh --install-kit[=HARNESS]` (explicit only), and a project-aware doctor. User scope stays the default of the scripts; the setup skill asks and defaults to the project.
- `lib/common.sh` gained `RDK_PROJECT_DIR` (default `$PWD`): every project-level lookup (Claude local scope and `.mcp.json`, project plugin settings, Codex `.codex/config.toml`, pi `.pi/mcp.json`, OMP `.omp/mcp.json` and imports) reads that directory. The doctor sets it to the detected project; outside a project a missing server is a warning instead of a failure.
- For Claude Code in project mode the installer prints the plugin commands instead of running them (they change the shared `.claude/settings.json` and add a marketplace that records the kit's local path), and registers only Studio's server, because the plugin bundles Blender's.
- Project files get no `.bak` copies (they live in the user's repository); the Codex project TOML is appended, never rewritten.
- `validate-skills.sh` accepts script names from the kit's `install/` folder, which the setup skill now names as optional.

Review fix pass (per-project install):
- Codex project TOML: inline (`[mcp_servers]` + `name = {…}`), dotted (`mcp_servers.name.command`) and root inline forms count as registered, an `.env` subtable alone does not. With Python 3.11+ (`tomllib`) the file is validated before and the result after appending (written to a temp file, moved only when valid); without it, forms that cannot be extended safely are refused with the block to add by hand (`RDK_NO_TOMLLIB=1` simulates that in tests).
- OMP `mcp.json`: an empty file gets the skeleton, invalid JSON or a non-object root is reported per server without aborting the run, and rewrites keep the file's mode (user and project).
- Plugin enablement follows Claude Code's precedence (local > project > user, first file that mentions the plugin).
- `--project` targets: physical paths everywhere (`pwd -P`; Claude keys local scope by them); a subfolder of a Rojo project is refused unless `--force`; a plugin folder is refused (`rdk_check_project_target`, `rdk_find_project_root` moved into `lib/common.sh`).
- Doctor: an explicit `--project` counts as inside a project; Claude's missing Blender server suggests the project-scope plugin commands before `mcp-config.sh`.
- `uninstall.sh --project` prints project-scope removal commands; `scaffold.sh` validates `--install-kit` (harness installed, installer present) before creating anything and passes `--install-kit-args` (a fixed set of `install.sh` options) on.

Review fix pass (Phase 2):
- `export_fbx.py` shows and unlocks hidden or unselectable targets during the export (Blender's exporter writes only `context.selected_objects`) and asserts the selection; excluded collections are a usage error. Re-importing the FBX in a fresh Blender is now the standard assertion of the export tests.
- Texture rule changed: `--max-texture` defaults to 4096 (Roblox's maximum, violation) and the new `--texture-budget` to 1024 (the PBR-map maximum, warning); only images that feed the material output count.
- `upload-asset.sh` moves the key into an unexported variable as its first statement; any 2xx is success.

## 14. `find-resources` skill (added 2026-10-24)

A fourth skill, `skills/find-resources/`, with the plugin command `commands/find-resources.md`
(`/roblox:find-resources`). It finds **free game assets** (3D models, textures/materials, decals,
sounds, music, icons, fonts, animations) from a curated list of sources, checks their licenses,
scans community Roblox models for backdoors, and routes each asset into the game through the
existing skills. It also carries the rule the user asked for: **find before you build**. When an
agent is asked to make something that is laborious or looks poor when generated by code (trees,
rocks, foliage, vehicles, characters, furniture, PBR materials, sound effects, music, icon sets), it
should look for a free asset first and propose it, instead of building from primitives. Simple
geometry, UI layout and anything game-specific is still built.

### 14.1 Verified facts (2026-10-24; quote these, do not invent others)

Roblox:
- Creator Store (https://create.roblox.com/store, also Studio's Toolbox) has "millions of assets made
  by Roblox and independent creators": models, meshes, decals/images, audio, video, plugins, fonts.
  Its Advanced Filter can limit results to verified creators and to free assets. Verified accounts
  get default discoverability; unverified ones do not (docs/production/creator-store,
  docs/production/publishing/publishing-assets). The `?keyword=` URL parameter is **not** verified;
  do not print URLs with it, point at the store page and its search box instead.
- Studio MCP `search_asset` (verified schema): `query`, `assetType` (Model, Audio, Mesh, MeshPart,
  Image, Decal, Video, Package), `scope` (`auto` | `creator_store` | user | group | universe),
  `priceFilter` (`free` | paid | all, needs `scope=creator_store`), `verifiedCreatorsOnly`, `tags`,
  `facets`, `maxResults` (1-20), audio duration filters; results carry name, type, source, price,
  creator and a `thumbnailUrl`. `insert_asset(assetId, assetName, assetType, parentPath)`.
  This is the preferred Roblox search when Studio is connected.
- Undocumented but working without a key, used by the Creator Store website:
  `GET https://apis.roblox.com/toolbox-service/v1/marketplace/<category>?keyword=<q>&limit=<n>`
  returns `{totalResults, data: [{id}, …]}`; categories seen working: 10 (models), 3 (audio),
  13 (decals); 1 returns 400. `GET https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=<id,id>`
  returns `data[].asset.{id,name,typeId}`, `data[].creator.{name,isVerifiedCreator}`,
  `data[].product.price`. Use it only as the fallback when no Studio MCP is available, label it
  "undocumented, may change", and treat any non-200 as a warning. Verify the category→type mapping
  with the details endpoint before relying on more categories.
- Creator Store audio: "more than 100,000 professionally-produced sound effects and music tracks"
  from Roblox's audio partners, free to use in experiences. Own uploads: .mp3/.ogg/.wav/.flac,
  under 20 MB and under 7 minutes, ≤48 kHz; per 30 days ID-verified accounts may import 2,000
  audio assets, unverified 100; new audio is private to the uploader until shared
  (docs/audio/assets). So: prefer the Creator Store library for audio.
- Mesh limits (already in §1): 20,000 triangles per mesh, PBR maps ≤1024², other textures ≤4096².
  Roblox has no SVG support (rasterize icons to PNG) and no custom font upload (fonts come from the
  Creator Store font catalog, installed from Studio's Toolbox).

External sources with an API that needs no key:
- **Poly Haven** (CC0, https://polyhaven.com). API `https://api.polyhaven.com`:
  `GET /assets?t=textures|models|hdris[&c=<category>]` returns an object keyed by asset id with
  `name`, `tags`, `categories`, `authors`, `download_count`, `max_resolution`, `dimensions`,
  `date_published`, `thumbnail_url`; there is **no text query**: filter on name/tags/categories
  client-side. `GET /files/<id>` returns maps → resolution → format → `{url,size,md5}`; for
  textures the maps include `Diffuse`, `nor_gl`, `nor_dx`, `Rough`, `AO`, `Displacement`, `arm`,
  plus `blend`/`gltf`; resolutions `1k`,`2k`,`4k`,`8k`; formats `jpg`,`png`,`exr`. Example:
  `https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/brick_4/brick_4_diff_1k.jpg`.
  `GET /info/<id>` gives authors/categories/tags. Swagger: `/api-docs/swagger.json`. Assets need no
  attribution, but a tool that uses the live API must show "Powered by Poly Haven" (API ToS): print
  that line whenever Poly Haven results are shown. Asset page: `https://polyhaven.com/a/<id>`.
- **ambientCG** (CC0, https://ambientcg.com). `GET https://ambientcg.com/api/v2/full_json?q=<q>&limit=<n>&include=downloadData,tagData[&type=<dataType>]`
  returns `{searchQuery, numberOfResults, nextPageHttp, foundAssets: [...]}`; an asset has
  `assetId`, `displayName`, `dataType` ("Material" seen; verify the other values such as 3DModel,
  HDRI, PlainTexture, Decal before using `type=`), `creationMethod`, `tags`, `downloadCount`,
  `dimensionX/Y/Z`, `previewImage` (keys like `"512-PNG"`), and
  `downloadFolders.default.downloadFiletypeCategories.zip.downloads[]` with `attribute`
  (`"1K-JPG"`, `"8K-PNG"`, …), `fileName`, `size`, `filetype`, `downloadLink`. Asset page:
  `https://ambientcg.com/view?id=<assetId>`. Zips contain `<id>_<res>_Color.jpg`,
  `_NormalGL.jpg`, `_NormalDX.jpg`, `_Roughness.jpg`, `_Metalness.jpg`, `_Displacement.jpg`,
  `_AmbientOcclusion.jpg` (verify on the first real download).
- **Sketchfab** (per-model license). `GET https://api.sketchfab.com/v3/search?type=models&q=<q>&downloadable=true&license=<slug>&count=<n>`
  works without auth; `license` slugs verified: `cc0`, `by`, `by-sa` (others per Sketchfab:
  `by-nd`, `by-nc`, `by-nc-sa`, `by-nc-nd`); a license uid in that parameter is rejected. Results:
  `uid`, `name`, `viewerUrl`, `isDownloadable`, `license.{uid,label}`, `faceCount`, `vertexCount`,
  `user.username`, `thumbnails.images[].url`, `archives` (keys `glb`, `gltf`, `source`, `usdz`).
  Pagination via `next` URL. **Downloading needs a logged-in Sketchfab account** (API token), so the
  tool prints the page URL; `max_face_count` as a filter is unverified (filter on `faceCount` ≤ 20000
  client-side instead, or verify first).

External sources whose API needs a free key (read from the environment, never from arguments):
- **Freesound** (per-sound CC license). `GET https://freesound.org/apiv2/search/?query=<q>&filter=license:"Creative Commons 0"&fields=id,name,username,license,duration,previews,url&page_size=<n>`
  with `Authorization: Token $FREESOUND_API_KEY` (or `token=`); `fields` replaces the default
  list; `previews["preview-hq-mp3"]` is an mp3 preview URL; the original file needs OAuth2, so
  point at the sound page `https://freesound.org/people/<user>/sounds/<id>/`. License filter values
  are the license names (`"Creative Commons 0"`, `"Attribution"`, `"Attribution NonCommercial"`).
- **Pixabay** (Pixabay Content License: free commercial use, no attribution, no redistribution of
  unmodified content; API rule: cache results 24 h, no mass download, show where results come from).
  Images `GET https://pixabay.com/api/?key=$PIXABAY_API_KEY&q=<q>&image_type=photo|illustration|vector&per_page=<3-200>&safesearch=true`,
  videos `/api/videos/`; **no API for music or sound effects** (website only). Rate limit 100
  requests per 60 s per key.
- **Poly Pizza** (per-model CC0 or CC-BY). `GET https://api.poly.pizza/v1.1/search/<q>` with header
  `x-auth-token: $POLY_PIZZA_API_KEY` (verified: without a key → 401 `"You need an API key…"`,
  wrong key → `"API key not valid"`). The response shape is **unverified**: parse defensively and
  print what is there; website search `https://poly.pizza/search/<q>` works without a key.

Browse-only sources (print a filled-in URL; no API):
- **Kenney** (https://kenney.nl, CC0 on every asset page, e.g. https://kenney.nl/assets/car-kit;
  FBX/OBJ/glTF in most 3D kits). URL filters are path-style: `/assets/category:3D`,
  `/assets/category:Audio`, `/assets/category:Textures`, `/assets/tag:interface` (UI),
  `/assets/series:<name>`; no verified search URL. UI pack and Input Prompts pack cover
  controller/keyboard glyphs.
- **KayKit** (https://kaylousberg.itch.io, packs are "Creative Commons Zero v1.0 Universal", FBX,
  GLTF, OBJ; base tiers "name your own price"; e.g. https://kaylousberg.itch.io/kaykit-platformer).
- **Quaternius** (https://quaternius.com, packs at `/packs/<name>.html`). **Not CC0**: since
  2026 the "Quaternius Asset License (QAL) v1.0": free for personal, educational and commercial
  games, no attribution, but no reselling or redistributing the assets themselves. Treat like
  Kenney for games, not for re-publishing (so do not upload them to the Creator Store as a pack).
- **itch.io**: `https://itch.io/search?q=<q>&classification=assets` (verified 200 with results);
  browse `https://itch.io/game-assets/free/tag-low-poly`, `/tag-3d`, `/tag-pixel-art`,
  `/game-assets/newest/free`. License is per item (stated on each page).
- **OpenGameArt**: `https://opengameart.org/art-search-advanced?keys=<q>&field_art_type_tid[]=<type>&field_art_licenses_tid[]=<lic>`
  with type ids 2D Art 9, 3D Art 10, Textures 14, Music 12, Sound Effects 13, Concept Art 7273,
  Documents 11 and license ids CC0 4, CC-BY 3.0 2, CC-BY 4.0 17981, CC-BY-SA 3.0 3,
  CC-BY-SA 4.0 17982, OGA-BY 3.0 10310, OGA-BY 4.0 31772, GPL 2.0 5, GPL 3.0 6
  (`sort_by=count&sort_order=DESC` sorts by favourites).
- **game-icons.net**: about 4,000 SVG icons, "Creative Commons 3.0 BY"; required credit, their
  example: `Icons made by {author}. Available on https://game-icons.net`. Tag pages
  `https://game-icons.net/tags/<tag>.html` (verified 200); GitHub mirror github.com/game-icons/icons.
- **Icon sets**: Lucide (ISC), Phosphor (MIT), Material Symbols (Apache-2.0): verify each license
  file once while implementing and cite the URL.
- **Unsplash** (Unsplash License, free commercial use, no compiling into a competing service):
  `https://unsplash.com/s/photos/<q>`. Pixabay SFX/music: `https://pixabay.com/sound-effects/search/<q>/`,
  `https://pixabay.com/music/search/<q>/` (verify both URLs with curl before shipping).
- **Mixamo** (Adobe): royalty-free characters and animations for commercial games; raw files may
  not be redistributed. Rigs are not Roblox R15; retargeting through Blender is real work, so
  prefer Roblox's own animation packs and say so.
- **Fab / Megascans**: the free-for-all period ended in 2024; in 2025 Epic kept a free
  "starter" selection (about 1,500 Megascans) usable in any engine under the Fab Standard License,
  the rest is paid. The Fab Standard License is not Creative Commons; read it before use. Legacy
  Quixel assets obtained under the old "free for Unreal Engine" terms may not be used in Roblox.

Local tooling verified:
- Lune 0.11.1 (`~/.rokit/bin/lune`): `require("@lune/roblox").deserializeModel(fs.readFile(p))`
  reads `.rbxm` and `.rbxmx` and returns an array of root Instances; `serializeModel(instances)`
  writes binary; `readModelFile` does **not** exist in this version; `inst:GetDescendants()`,
  `inst:IsA("LuaSourceContainer")`, `inst.Source`, `inst.Disabled`, `inst:GetFullName()` work;
  `require("@lune/process").args` holds the arguments and `lune run script.luau a b` passes them
  (a `--` is passed through literally, so do not use one); `process.exit(n)` sets the exit code;
  bad input raises "Unknown document format". A hand-written `.rbxmx` (XML) is a valid fixture.

### 14.2 Deliverables

1. `skills/find-resources/SKILL.md` (body ≤ 500 lines, Agent Skills frontmatter like the others,
   `metadata.version "0.1.0"`). Description is the trigger: finding, downloading or checking free
   assets (models, meshes, textures, materials, decals, sounds, music, icons, fonts, animations),
   Creator Store, Kenney, Poly Haven, CC0, "is this free model safe", **and** requests to build an
   asset that is laborious or poor when generated by code (trees, rocks, foliage, vehicles,
   characters, furniture, PBR materials, SFX, music, icon sets): the skill is consulted first to
   decide build vs. find. Sections: (1) build or find: a short decision table and the rule to
   propose the found asset with its license before building; (2) Roblox first: Creator Store via
   `search_asset` (`scope=creator_store`, `priceFilter=free`, `verifiedCreatorsOnly=true`, the right
   `assetType`), `insert_asset` into a `Workspace` folder named after the source, audio from the
   Creator Store library because of the upload rules; (3) external search with
   `scripts/search.sh`; (4) license gate (`references/licenses.md`): CC0 preferred; CC-BY only with a
   credits entry; no NC in a monetised game; avoid SA/ND; special terms (QAL, Fab Standard, Pixabay,
   Unsplash, Mixamo, Creator Store); `scripts/credit.sh` records every third-party asset in the
   project's `CREDITS.md`; (5) safety: every community model is scanned with
   `scripts/scan-model.sh` before it is used or play-tested; models already inserted in Studio are
   checked with Studio MCP `script_grep`/`script_read` using the same patterns (`references/safety.md`);
   unused scripts are deleted; (6) import routes: 3D files → `blender-to-roblox` (check_mesh,
   export_fbx, upload) or Studio's 3D Importer, with the triangle cap and "split dense meshes in
   Blender" note; texture sets → SurfaceAppearance (ColorMap, NormalMap, RoughnessMap, MetalnessMap;
   ≤1024² each) uploaded with Asphalt or `upload-asset.sh --type Image`; icons → rasterised PNG;
   fonts → Creator Store only; animations → Roblox packs first. Cross-reference `blender-to-roblox`
   and `roblox-setup` with one line each, and add one line in those two SKILL.md files pointing
   back here (sourcing models; the AGENTS.md rule).
2. `references/sources.md` (the catalogue above as tables per category: source, URL, how to search,
   license, fit for Roblox, API/key), `references/licenses.md` (what each license means for a Roblox
   game, the attribution formats, where credits go: `CREDITS.md` in the repo and a credits screen in
   the game), `references/safety.md` (backdoor patterns and the review checklist; what the scanner
   flags and known false positives).
3. `scripts/search.sh QUERY [--type model|texture|hdri|sound|music|image|icon|all] [--source a,b]
   [--license cc0|by|any] [--limit N] [--json] [--dry-run] [--no-manual]`: queries every source that
   has an API (Poly Haven with client-side matching; ambientCG; Sketchfab; Roblox toolbox-service
   fallback; Freesound/Pixabay/Poly Pizza only when their key is set, otherwise one line
   "skipped: set FREESOUND_API_KEY"), prints a table (source, name, license, size facts such as
   triangles/resolution/duration, page URL, direct download when the source allows it) and then the
   browse links for the query (unless `--no-manual`). Default license filter: CC0 and CC-BY shown,
   others hidden. Keys never appear in argv: use a 0600 curl config file like `upload-asset.sh`.
   URL-encode with jq `@uri`. `curl -m 20`; a failing source is a warning, the run still exits 0
   when at least one source answered; usage errors exit 2. Print "Powered by Poly Haven" with
   Poly Haven results. `--dry-run` prints the requests it would make.
4. `scripts/fetch.sh SOURCE:ID [--res 1k|2k] [--out DIR] [--json]` for the CC0 sources with direct
   downloads: `polyhaven:<id>` (Diffuse, nor_gl, Rough, and `arm` or Metal when present, jpg,
   default 1k) and `ambientcg:<assetId>` (the `<res>-JPG` zip, unzipped, keeping Color, NormalGL,
   Roughness, Metalness). Files go to `<out>/<source>/<id>/` (default `assets/third-party/`),
   with a `SOURCE.json` (source, id, name, authors, license, page URL, download date, files) and a
   `CREDITS.md` entry via `credit.sh`. Verify Roblox's normal-map convention (OpenGL vs DirectX)
   in the SurfaceAppearance docs and download the matching map; say which in `references/sources.md`.
   Other sources print how to download by hand (Sketchfab and Freesound need a login).
5. `scripts/credit.sh --name N --source URL --license L [--author A] [--file CREDITS.md]`: appends
   one table row, idempotent on (name, source). Also used by `fetch.sh`.
6. `scripts/scan-model.luau` run through `scripts/scan-model.sh FILE [--json] [--max-line 500]`
   (finds `lune` via `RDK_LUNE_BIN`, PATH, `~/.rokit/bin`). Lists every `LuaSourceContainer`
   (full name, class, Disabled, source length) and reports findings with a severity:
   high: `require(<digits>)` or `require(` of a non-local expression, `getfenv`/`setfenv`,
   `loadstring`, `string.char(` chains / long `\ddd` escape runs / `string.reverse` decoders,
   obfuscator markers (Luraph, IronBrew, MoonSec, PSU), `HttpService` `GetAsync`/`PostAsync`/
   `RequestAsync`, lines longer than `--max-line`; medium: `MarketplaceService:Prompt*`,
   `TeleportService`, `InsertService:LoadAsset`, `game:GetService("ScriptContext")`, scripts
   parented to non-container classes (Sound, Decal, Texture, Weld, Attachment, Motor6D,
   ValueBase), names with leading/trailing whitespace or non-ASCII characters; info: counts.
   Exit 0 nothing found, 1 findings, 2 usage or unreadable file. Table and `--json`.
7. `commands/find-resources.md`: use the skill for `$ARGUMENTS`; with none, ask what the asset is
   for and whether Studio is connected (so `search_asset` can be used), then search.
8. Template `assets/template/AGENTS.md`: a short section "Assets: find before you build" with the
   rule, the license gate (CC0, credits for CC-BY, no NC), the scan-before-use rule, and the
   `find-resources` skill name. Keep it to about eight lines.
9. `README.md` (skills table row, one paragraph with an example), `CHANGELOG.md`,
   `.claude-plugin/plugin.json` and `marketplace.json` descriptions, `docs/PLAN.md` §14.3 for
   deviations, `install/uninstall.sh` if it names skills.
10. Evals: `evals/find-tree-model/` (prompt: "Build me a few low-poly pine trees for the forest
    level"; expected: the agent proposes free assets first with source, license and the triangle
    cap, runs `search.sh --dry-run` or a real search, offers the Creator Store via Studio MCP, and
    does not invent asset ids) and `evals/scan-free-model/` (scaffold script writes `FreeTree.rbxmx`
    with one benign and one backdoored script; prompt: "Is ./FreeTree.rbxmx safe to use in my
    game?"; expected: runs the scanner, names the `require(<id>)` loader, recommends removing that
    script or not using the model, changes nothing). Validate with `scripts/validate-evals.sh`.
11. Tests `tests/find-resources.bats` (fake curl replaying trimmed real fixtures captured with curl
    under `tests/fixtures/find-resources/`): every source parsed; license filter; `--json` valid
    (jq); `--dry-run` sends nothing; missing key → skipped line and exit 0; one source failing →
    warning, exit 0; all failing → exit 1; keys never in argv or environment of curl (reuse the
    upload tests' leak check); Poly Haven credit line; URL-encoding of a query with spaces and
    `&`; `fetch.sh` writes files + SOURCE.json + CREDITS row and is idempotent; `credit.sh`
    idempotent; `scan-model.sh` on a fixture with a benign script (exit 0), a backdoored one
    (exit 1, high finding names the line), garbage input (exit 2), `--json`; skipped when `lune`
    is missing. bash 3.2, shellcheck, `make all`, `claude plugin validate .` all green.

### 14.3 Deviations and notes from the implementation

Implemented 2026-10-24. Every check below was made that day with curl (or, where curl gets a bot
challenge, in a headless Chrome through DevTools), and the answers the tests replay are in
`tests/fixtures/find-resources/` (README there lists the capture URLs).

**Deviations from §14.1/§14.2**

- Poly Haven **has** a text search: `GET /search?q=<q>&t=<type>&limit=<n>` ("hybrid semantic +
  keyword search", in `/api-docs/swagger.json`; returns ranked slugs, `results[].slug`). `search.sh`
  uses it to rank and `/assets?t=<type>` for the metadata; when `/search` fails it falls back to
  matching name, tags and categories locally, as planned.
- Every request sends `User-Agent: roblox-dev-kit/<version> (+repo URL)` (`RDK_USER_AGENT` in
  `lib/common.sh`): Poly Haven's API terms §2.4 require "a unique Referer header or user-agent that
  matches your software name" (https://github.com/Poly-Haven/Public-API/blob/master/ToS.md).
- ambientCG `type=` values verified: `Material`, `Decal`, `Atlas`, `HDRI`, `HDRI-Element`,
  `Substance`, `Terrain`, `Brush` filter (case-insensitive, comma lists work); the 3D-model data type
  `3DModel` is filtered with **`type=3D-Model`**; `3DModel`, `PlainTexture`, `Plain-Texture` and
  unknown values are silently ignored (all 2,927 assets come back). Data types counted with
  `limit=3000`: Material 2037, HDRI 434, Substance 211, Decal 127, Atlas 61, 3DModel 34,
  PlainTexture 9, Terrain 5, Brush 5, HDRIElement 4. `search.sh` maps texture →
  `Material,Atlas,Decal`, model → `3D-Model`, hdri → `HDRI`.
- ambientCG zip member names are **`<id>_<res>-JPG_<Map>.jpg`** (`Bricks100_1K-JPG_Color.jpg`,
  `_NormalGL`, `_NormalDX`, `_Roughness`, `_AmbientOcclusion`, `_Displacement`), not
  `<id>_<res>_Color.jpg`; the zip also holds `.usdc`, `.blend`, `.mtlx`, `.tres` and a preview `.png`
  (checked by downloading `Bricks100_1K-JPG.zip`, 4,827,385 bytes). `downloadLink`
  (`https://ambientcg.com/get?file=...`) redirects to `acg-download.struffelproductions.com`, so
  downloads use `curl -L`. 3D models have `LQ-`/`SQ-`/`HQ-<res>-JPG` zips; `LQ-1K-JPG` of
  3DTreeStump001 holds an `.obj`, `.mtl`, Color, NormalGL, NormalDX and AO.
- `fetch.sh`: Poly Haven's `Metal` map is downloaded when the set has one; otherwise the packed
  `arm` map (AO red, roughness green, metalness blue), with a note on checking its blue channel
  (see the review fixes below; at first `arm` was skipped).
  Poly Haven **models are refused** with the reason (pine_tree_01: 17,427,094 polys, the 1k FBX is
  648 MB; only 358 of 521 models are under 20,000) and HDRIs are refused (Roblox skies are six
  images). ambientCG **3D models are supported** through the `LQ-<res>-JPG` zip, keeping the `.obj`
  and `.mtl`; `_Opacity` maps are kept too (atlases, decals). Checks: Poly Haven's `md5` and size,
  ambientCG's zip size; files are staged and moved only when all arrived. Extra options `--credits
  FILE` and `--force`. Zip members are extracted one by one with `unzip -p` (review fixes below),
  only names that start with `<id>_`; paths with `..`, absolute paths, backslashes, links and
  folders are skipped with a warning. API calls
  use `curl -sS -m 20`; file downloads `--connect-timeout 20 -m 900` (20 s would cut off the 5-10 MB
  zips on a slow line). For sketchfab/freesound/roblox/pixabay/polypizza it prints the manual steps
  and exits 1 (nothing was downloaded).
- `search.sh --license`: `cc0` = CC0 only; `by` (default) = CC0 and CC-BY plus the platform
  licenses that allow use in a game without credit (Creator Store, Pixabay); `any` = everything,
  NC/SA/ND/unclear marked. Sources run in parallel subshells (each writes only its own files).
  `--type all` applies `--limit` per source and kind. Queries longer than 100 characters are a
  usage error (Poly Haven's `q` and Pixabay's `q` limits).
- Sketchfab: a repeated `license=` parameter keeps only the last value (`license=cc0&license=by`
  returns only CC-BY, the reverse only CC0), so CC0 and CC-BY are two requests, CC0 first.
  `max_face_count` works (count 6 with `max_face_count=5000` returned 0-3,316 faces) and is sent as
  20,000. `archives.<fmt>.textureMaxResolution` is shown. Downloads need a login (unchanged).
- Roblox toolbox API: current items have `product: null`; the price is
  `fiatProduct.{isFree, purchasePrice.quantity}` in USD, and paid items do appear (3 of the first 6
  for "pine tree"), so items with `isFree: false` (or a `product.price` above 0) are dropped and
  counted. The details also give `asset.hasScripts`, `modelTechnicalDetails.objectMeshSummary.triangles`,
  `duration` and `audioDetails.audioType` (`SoundEffect`/`Music`), which `search.sh` shows and uses to
  split sound from music. Category 13 (decals) serves texture, image and icon.
  `https://www.roblox.com/library/<id>` redirects to `https://create.roblox.com/store/asset/<id>`,
  which is the page URL printed (the store is a client-side app that answers 200 for any path, so
  its pages cannot be checked with curl).
- Pixabay: the key is a query parameter, so its URL goes into the 0600 curl config (`url = ...`)
  instead of argv. Answers are cached 24 hours (Pixabay's API terms) in
  `${RDK_CACHE_DIR:-${XDG_CACHE_HOME:-~/.cache}/roblox-dev-kit}/pixabay/` (0700), keyed by the URL
  without the key; the key is never written there.
- Freesound: the default filter is `license:("Creative Commons 0" OR "Attribution")` (the documented
  Solr `type:(wav OR aiff)` syntax); music adds `category:Music` (documented example
  `category:Music subcategory:"Solo instrument"`). `https://freesound.org/s/<id>/` redirects to the
  sound page.
- Scanner extras: `linked-source` (high; a non-empty `LinkedSource`, which Lune reads as a string),
  `require-value` (medium; first `require-alias`), `AssetService:LoadAssetAsync` with `insert-service`, and
  `game:HttpGet`/`HttpPost` with `http`, because Roblox's Creator Store rules name them
  (https://create.roblox.com/docs/production/creator-store: getfenv/setfenv, `require(assetId)`,
  `loadstring()`, `InsertService:LoadAsset()`, `AssetService:LoadAssetAsync()`,
  `ModuleScript.LinkedSource`, obfuscated code, extremely large scripts). Also scans places
  (`.rbxl`/`.rbxlx` through `deserializePlace`); at most three findings per rule and script; exit 2
  also when Lune is missing. Lune's `serde` encodes an empty table as `{}`, so the JSON arrays are
  joined by hand. `ModuleScript` has no `Disabled` (reading it errors), `Script.Disabled` and
  `RunContext` read fine.
- `rdk_find_lune` (new in `lib/common.sh`, with `rdk_md5` and `rdk_uri`): Rokit's `~/.rokit/bin/lune`
  is a shim that fails ("Failed to find tool 'lune' in any project manifest file") when no
  `rokit.toml` lists lune, which includes every fake-HOME test, so each candidate is run with
  `--version` first and the newest `~/.rokit/tool-storage/lune-org/lune/<v>/lune` is the fallback.
  The scanner tests are skipped unless `command -v lune` or `~/.rokit/bin/lune` exists, and then use
  the tool-storage binary (`RDK_REAL_LUNE` overrides).
- Eval `scan-free-model` copies a working lune into `./.tools` and writes `lune.env`, because the
  agent cannot read HOME during `claude plugin eval` (as `check-mesh-report` does for Blender);
  tagged `requires-lune`. `find-tree-model` scaffolds a minimal Rojo project without `AGENTS.md`, so
  the skill's description has to trigger on its own.
- Browse links: game-icons.net has tag pages only for its 15 listed tags (animal, arrow, blade,
  body, building, creature, food, gui, head, liquid, spike, symbol, tool, vehicle, weapon;
  `/tags/sword.html` is 404), so a tag page is printed only when a query word is one of them, else
  the home page (its search is in-page). Fab is printed as https://www.fab.com (curl gets 403).
- `install/uninstall.sh` needed no change (it discovers skills). `tests/validate.bats` now expects
  six eval cases.

**Verified (with where)**

- Roblox reads only OpenGL normal maps: "Roblox only supports **OpenGL format - Tangent Space**
  normal maps" (https://create.roblox.com/docs/art/modeling/surface-appearance, creator-docs
  `content/en-us/art/modeling/surface-appearance.md`). `SurfaceAppearance` and `MaterialVariant`
  have `ColorMap`, `NormalMap`, `RoughnessMap`, `MetalnessMap` (and `*Content`); `MaterialVariant`
  also `StudsPerTile` (creator-docs `reference/engine/classes/*.yaml`). Studio's Importer reads
  `.fbx`, `.gltf`/`.glb` and `.obj` (https://create.roblox.com/docs/studio/importer).
- Pixabay sound-effect and music search URLs: curl gets 403 `cf-mitigated: challenge`; in a browser
  `https://pixabay.com/sound-effects/search/jump/` is "Free Jump Sound Effects Download - Pixabay"
  ("397 royalty-free jump sound effects") and `https://pixabay.com/music/search/calm%20forest/` is
  "Calm Forest Music | No Copyright Song & MP3 Free Downloads" (%20 works);
  `https://pixabay.com/images/search/brick%20wall/` too. Unsplash `/s/photos/brick-wall` and
  `/s/photos/brick%20wall` load in a browser (curl: 307 to a bot check, then 401). Both license
  pages were read in the browser (https://pixabay.com/service/license-summary/,
  https://unsplash.com/license) and are quoted in `references/licenses.md`.
- Icon licenses: Lucide ISC, with the icons derived from Feather under MIT
  (https://github.com/lucide-icons/lucide/blob/main/LICENSE); Phosphor MIT
  (https://github.com/phosphor-icons/core/blob/main/LICENSE); Material Symbols Apache-2.0
  (https://github.com/google/material-design-icons/blob/master/LICENSE); game-icons "Creative
  Commons 3.0 BY or CC0 if mentioned" (https://github.com/game-icons/icons/blob/master/license.txt).
- Creative Commons' attribution guide recommends Title, Author, Source, License ("TASL",
  https://wiki.creativecommons.org/wiki/Recommended_practices_for_attribution).
- Keyed APIs without a key: Freesound 401 `{"detail":"Authentication credentials were not
  provided."}`, Pixabay 400 `[ERROR 400] Invalid or missing API key`, Poly Pizza 401. Pixabay docs:
  `image_type` all (default), photo, illustration, vector; `per_page` 3-200; `q` at most 100
  characters; "requests must be cached for 24 hours"; show users where results come from.
- Toolbox categories: 10, 3 and 13 answer and their details carry `typeId` 10, 3 and 13; 1, 2, 4,
  5, 6, 8, 9, 11, 12, 14, 15, 16 answer 400 (40 and 38 answer with results, 62 and 73 with none;
  not used).
- Browse URLs answering 200 (curl): kenney.nl `/assets/category:3D|Textures|Audio|2D`,
  `/assets/tag:interface`; kaylousberg.itch.io; quaternius.com; poly.pizza/search/<q> and
  poly.pizza/m/<id>; itch.io search and `/game-assets/free/tag-low-poly|3d|music|icons|textures|sound-effects`;
  OpenGameArt advanced search with encoded `[]`; polyhaven.com `/textures`, `/models`, `/hdris`,
  `/a/<id>`; ambientcg.com `/list?q=`, `/view?id=`; freesound.org/search/?q=; lucide.dev/icons/;
  phosphoricons.com; fonts.google.com/icons; game-icons.net and its tag pages; mixamo.com.

**Not verified, and how the scripts behave**

- Live Freesound, Pixabay and Poly Pizza answers (no keys here). Their fixtures are built from the
  documented formats (Freesound, Pixabay's own example) or guessed (Poly Pizza: `poly.pizza/docs`
  answered with a server error); the parsers read several field spellings and skip what is missing.
  Freesound's `license` field is documented as a name; URLs are understood too. Whether
  `category:Music` narrows Freesound results as intended is untested.
- Sketchfab `faceCount` is shown as "faces" and Poly Haven `polycount` as "polys": neither is
  documented as triangles, so the 20,000 comparison is a hint, and `check_mesh.py` decides.
- Kenney, KayKit and Quaternius license terms are taken from §14.1, not re-read.
- The two eval cases were validated (`scripts/validate-evals.sh`) but not run: they are paid model
  runs. The Linux CI job was not run; the scripts use `md5sum`/`md5`, `unzip -Z1`/`-Z`/`-p` (Info-ZIP)
  and `find -mmin`, which ubuntu-latest has, and the zip-building tests need python3.

**Review fixes (after the Fable 5.1 review, 2026-10-24)**

Each fix has a regression test in `tests/find-resources.bats`; the scanner fixtures `evasive.rbxmx`
and `legit.rbxmx` come from the reviewer's samples.

- High: the scanner's two HttpService-alias patterns started with an unanchored `([%a_][%w_]*)`,
  quadratic on long words (20 KB: 9.7 s, 40 KB: 39 s, 5 MB: never finished, before the long-line
  rule could report it). They start with `%f[%w_]` now; call arguments are read at most 2,000
  characters ahead; `Prompt%a*Purchase` and `LoadAsset%a*` match in a 120-character window; a
  `require` flood (over 5,000 in a script) is one finding; and a CPU budget (`RDK_SCAN_BUDGET`,
  default 120 s) stops any scan with exit 2. Measured after the fix: 5 MB line 1.7 s, the review's
  18 MB model 7 s.
- `fetch.sh` used `unzip -j`, which recreates symlink members on macOS: a `<id>_1K-JPG_Color.jpg ->
  /etc/passwd` member landed in the asset folder as the ColorMap. Members are now written with
  `unzip -p` (bytes only), links and folders are skipped by their type in `unzip -Z`, the staging
  folder is checked for links, and a texture set without a color map is refused. Member names are
  passed with `[`, `*` and `?` bracket-escaped (unzip reads them as patterns), each must unpack to
  its listed size, and members over 200 MB (`RDK_MAX_ZIP_MEMBER`) are refused.
- Scanner evasions that passed as clean: `require(-(-id))`, `require(select(1, id))`,
  `require(({id})[1])`, `(require)(id)`, `{require}`, multi-line calls, `local id = <n>` then
  `require(id)`, `"Http".."Service"`, `pcall(HS.GetAsync, HS, url)`. The require checks now run over
  the whole source: a 4+ digit (or hex) number anywhere in the argument, `require(name)` where the
  script sets `name` to such a number, and `require` next to a 6+ digit number when used as a value
  are high; `require` used as a value is medium (`require-value`, replacing `require-alias`);
  `select(...)` and table indexing count as computed. HTTP: an alias's method used as a value is
  high; `:GetAsync(` on an unknown object (an HttpService request or a DataStore read) and
  `PostAsync`/`RequestAsync` without HttpService in sight are medium; a service name built with
  `..` is a medium `service-name` finding. Of the review's 69 samples, every evasion is now high or
  medium, every legitimate sample stays clean; `rawget(_G, "require")(id)` is still not recognised
  (documented in `references/safety.md`).
- `search.sh`: an answer jq could not read left an empty results file, the summary failed with
  "Cannot iterate over null" and the source vanished from `--json`. Every parse goes through
  `accept()`, which keeps only a JSON array and otherwise marks the source failed with jq's reason;
  Sketchfab's `license` and `user` are read as objects or strings.
- Poly Haven "metal" sets without a `Metal` map (5 of the first 8; checked live:
  blue_metal_plate and green_metal_rust have none, corrugated_iron has one) were reported as
  losing metalness silently. Measured with ImageMagick, it is not so: their `arm` blue channel is
  black (mean 0.001-0.005, max 0.04-0.11; painted or rusty metal is not metallic in PBR), while
  corrugated_iron's matches its `Metal` map (mean 0.99). As asked, `fetch.sh` now downloads `arm`
  for any set without `Metal` and records it in `SOURCE.json` as
  `ARM (ambient occlusion R, roughness G, metalness B)`, but the message it prints says the set is
  not metallic (leave `MetalnessMap` empty) and gives the ImageMagick / Blender step only to check
  or use the channel. Downloading `arm` mostly costs one file; dropping it again is an option.
- Control characters (terminal escapes) in API names reached the terminal and `CREDITS.md`; both
  scripts strip them. Ids must start with a letter or digit (`polyhaven:.` was accepted).
- `--force` at another `--res` left the old files beside the new ones; the files the previous
  `SOURCE.json` lists are removed first. `credit.sh` inserts a row after the table's last row
  instead of after any text that follows the table.
- Sketchfab page links are `https://sketchfab.com/3d-models/<uid>` (301 to the titled page) instead
  of `viewerUrl`, whose slug is `none-<uid>` for titles without Latin letters. Docs: every Studio
  MCP call needs a `studio_id` from `list_roblox_studios`; ambientCG's docs list `3DModel` but only
  `3D-Model` filters; Sketchfab's `free-st`, `st` and `ed` store licenses
  (`GET https://api.sketchfab.com/v3/licenses`) show as "other: ..." under `--license any`.
