# roblox-dev-kit — plan and specification

One repo that is, at the same time:

1. a **Claude Code plugin** (`roblox`) — skills + bundled MCP + `/roblox:setup`, `/roblox:doctor`;
2. a **portable set of Agent Skills** (`skills/*/SKILL.md`) usable from Codex CLI, pi, Oh My Pi (OMP) and any harness that reads `~/.agents/skills/` or `.agents/skills/`.

Organizing rule: **`skills/` is the product; everything else is a thin adapter for one harness.**
Deterministic work lives in scripts; `SKILL.md` holds only judgment (when, which option, what to verify).

The stack being set up is described in `skills/roblox-setup/references/stack.md`.

---

## 1. Verified environment facts (macOS, 2026-10-24)

Use these; do not re-derive or guess. Where something is marked *verify*, check it on the machine or the source before relying on it.

### Harnesses installed
| Harness | Version | Skills dirs | MCP config | Notes |
|---|---|---|---|---|
| Claude Code | 2.1.310 | plugin `skills/`; `~/.claude/skills/` | `~/.claude.json` (user/project scope), plugin `.mcp.json` | CLI: `claude plugin validate|install|eval|init`, `claude mcp add|add-json|get|list|remove` |
| Codex CLI | 0.163.0 | `.agents/skills/` (repo), `~/.agents/skills/`, `~/.codex/skills/` | `~/.codex/config.toml` `[mcp_servers.<name>]` | already has `[mcp_servers.Roblox_Studio]`; `codex mcp add` exists (*verify flags*) |
| pi | 1.1.0 | `~/.pi/agent/skills/`, `~/.agents/skills/`, `.pi/skills/` | `~/.pi/agent/mcp.json`, project `.pi/mcp.json` (after trust) | native MCP: stdio + streamable HTTP, `pi mcp add|remove|list`, `/mcp`, `/reload` (*verify file format via `pi mcp add --help`*) |
| Oh My Pi (`omp`) | 18.12.6 | likely same as pi (*verify*) | `~/.omp/agent/mcp.json` (exists), project `.omp/mcp.json`; imports `~/.claude.json`, `~/.codex/config.toml`, installed Claude marketplace plugins | `/mcp add|list|reload|test` |

`~/.agents/skills/` exists and already holds many skills → it is the shared install target for Codex + pi (+ probably OMP).

### Roblox Studio
- App: `/Applications/RobloxStudio.app`
- Built-in MCP server binary (stdio, no args): `/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP`
- Registered in Claude Code (user scope) and Codex under the name **`Roblox_Studio`** — this is the name Studio's own "Quick connect" uses. Reuse it; never create a second Studio server.
- Studio plugins folder (macOS): `~/Documents/Roblox/Plugins` (does not exist yet → Rojo Studio plugin not installed). `rojo plugin install` creates it.
- Official docs: https://create.roblox.com/docs/studio/mcp

### Blender
- Binary: `/Applications/Blender.app/Contents/MacOS/Blender`, **5.2.1 LTS**, bundled Python 3.13. **Not on PATH.**
- `~/.local/bin` exists and **is on PATH** → `blender` symlink target for `--fix`.
- Headless probe confirmed: `bpy.ops.extensions.package_install_files` and `bpy.ops.preferences.extension_repo_add` exist.
- User extensions dir: `~/Library/Application Support/Blender/5.2/extensions` (not created yet). Repos: `extensions.blender.org` (module `blender_org`), `User Default` (module `user_default`), `System`.
- Blender honours `BLENDER_USER_RESOURCES` / `BLENDER_USER_CONFIG` / `BLENDER_USER_EXTENSIONS` env vars → use them to test add-on installation in a temp dir.
- No GNU `timeout`/`gtimeout` on this Mac → do not use `timeout` in scripts.

### Official Blender MCP (Blender Lab) — the default Blender server
- Repo: https://projects.blender.org/lab/blender_mcp (Gitea). HTML pages are behind a Cloudflare challenge for curl (403); **raw files, the API (`/api/v1/repos/lab/blender_mcp/...`) and release downloads work** with a browser-like `User-Agent`.
- Latest release **v1.0.3**. Assets:
  - `mcp-1.0.3.zip` (18 KB) = **the Blender add-on** (extension zip; `blender_manifest.toml`: id `mcp`, `blender_version_min = "5.1.0"`, permission `network`). URL: `https://projects.blender.org/lab/blender_mcp/releases/download/v1.0.3/mcp-1.0.3.zip`
  - `blender-1.0.3.mcpb` = server bundle for `.mcpb` clients (Claude Desktop). Not needed.
- Server: Python package in `mcp/` subdirectory, entry point `blender-mcp` (`blmcp:main`), `requires-python >= 3.10`, deps `mcp[cli]`, `docutils`, `pyyaml`. Launch:
  `uvx --from "git+https://projects.blender.org/lab/blender_mcp.git@v1.0.3#subdirectory=mcp" blender-mcp`
- Add-on ↔ server: TCP `localhost:9876` (env `BLENDER_MCP_HOST`, `BLENDER_MCP_PORT` on the server side). Add-on prefs: host, port, **Auto Start**, start/stop operators, polling intervals.
- Tools (from `readme_tools.rst`): `execute_blender_code`, `get_blendfile_summary_*`, `get_object_detail_summary`, `get_objects_summary`, `get_python_api_docs`, `search_api_docs`, `search_manual_docs`, `get_screenshot_of_area_as_image`, `get_screenshot_of_window_as_image|json`, `jump_to_*`, `render_thumbnail_to_path`, `render_viewport_to_path`. Every summary/execute tool has a `*_for_cli` variant that opens a `.blend` in a **background Blender process** (no live Blender needed).
- Security: executes LLM-generated Python in Blender without guards. Say so in docs.
- Community alternative `ahujasid/blender-mcp` (PyPI `blender-mcp`, `uvx blender-mcp`, `addon.py`; Poly Haven, Sketchfab, Hyper3D Rodin, Hunyuan3D) uses the **same port 9876** → optional only, never both at once.

### Toolchain state
Present: `uv`/`uvx` (`/opt/homebrew/bin`), node 24, git 2.50, `shellcheck`, `jq`, `python3`, Homebrew.
Missing: `rokit`, `rojo`, `wally`, `lune`, `stylua`, `selene`, `luau-lsp`, `zap`, `asphalt`, `bats`.

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
│   └── blender-to-roblox/                    # PHASE 2
│       ├── SKILL.md
│       ├── scripts/lib/common.sh · run_blender.sh · check_mesh.py · export_fbx.py · upload-asset.sh
│       └── references/export-rules.md · workflow.md · open-cloud-assets.md · blender-mcp-tools.md
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
├── commands/setup.md · doctor.md  # CC-only aliases → /roblox:setup, /roblox:doctor
│
├── install/install.sh · uninstall.sh   # ── OTHER HARNESSES (symlink skills, then mcp-config)
│
├── tests/                         # bats-core; no network unless RDK_NETWORK_TESTS=1
├── evals/                         # `claude plugin eval` cases (PHASE 2)
├── .github/workflows/ci.yml
└── scripts/validate-skills.sh · release.sh
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
1. **toolchain** — `install-toolchain.sh`: install Rokit via its official installer if missing (read the installer options from the Rokit README; use the no-modify-path option if one exists), then `rokit install` in the project (or `rokit add --global` for a global toolchain when no project). Prints the PATH line the user must add; **never edits `~/.zshrc`/`~/.bashrc`**.
2. **new** — `scaffold.sh <dir> <name>`: copy `assets/template`, substitute `{{PROJECT_NAME}}`, `git init` if not a repo, generate `sourcemap.json` if rojo is available. Refuses to overwrite a non-empty dir unless `--force`.
3. **adopt** — `adopt.sh <dir> --mapping <tsv>`: for an existing project with loose scripts (e.g. Motor Rivals: `src/Factory.lua → ReplicatedStorage.RivalsFactory (ModuleScript)`). The **agent** writes the mapping file (from README/Studio tree); the **script** turns it into `default.project.json` + moves/renames files (`.server.lua` / `.client.lua` / ModuleScript rules). Keeps `.lua` extensions as-is. Dry-run by default, `--apply` to execute.
4. **mcp** — `mcp-config.sh --harness <h>`: registers servers per §5 using the harness's own CLI when it exists (`claude mcp add-json`, `codex mcp add`, `pi mcp add`), writing JSON only for OMP. Idempotent: skips servers already present under the expected name. `--dry-run` prints what it would do.
5. **blender** — `setup-blender.sh`: download `mcp-<ver>.zip` (pinned, checksum recorded in the script once known), install with `Blender --background --python-expr` using `bpy.ops.extensions.package_install_files(filepath=…, repo='user_default', enable_on_install=True)` (*verify exact args on 5.2*), enable Auto Start in the add-on preferences and save prefs; create `~/.local/bin/blender` symlink if `blender` not on PATH. Refuse if Blender < 5.1. Warn if the community `blender-mcp` add-on is also installed (port clash).
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
| Roblox Studio | `Roblox_Studio` | per harness by `mcp-config.sh`, **only if missing** | Studio's Quick connect already creates it under this name in Claude Code and Codex; a plugin-bundled copy would duplicate every Studio tool |
| Blender (official) | `blender` | Claude Code: bundled in plugin `.mcp.json` (appears as `plugin_roblox_blender`); other harnesses: `mcp-config.sh` | plugin users get it on enable; `mcp-config.sh --harness claude` adds it only when the plugin is not installed |

`mcp/servers.json` is the single description (`command`, `args`, `env`, `description`, `homepage`), consumed by `mcp-config.sh` and mirrored by `.mcp.json`. Wrapper scripts (`mcp/*.sh`) exist so `.mcp.json` can use `${CLAUDE_PLUGIN_ROOT}` and so the Studio binary can be located per OS.

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
| blender | `blender` on PATH (fail; fix = symlink into `~/.local/bin`); version ≥ 5.1 (fail; official add-on needs it); official add-on dir present under `<ext dir>/user_default/mcp` (*verify actual path after one real install*) (fail); add-on TCP port reachable (warn: "Blender not running or Auto Start off"); community add-on also installed (warn: port clash); uvx can resolve the server — only with `RDK_NETWORK_TESTS=1`/`--online` (skip otherwise) |
| mcp | for each **installed** harness: `Roblox_Studio` registered (fail), `blender` registered or plugin enabled (fail); duplicates (warn). Harness not installed → `skip` |
| cloud | `ROBLOX_API_KEY` set (warn; never print value); `ROBLOX_CREATOR_TYPE`/`ROBLOX_CREATOR_ID` set (warn) |

`--fix` applies only safe, idempotent fixes: blender symlink, `rokit install`, `wally install`, `rojo sourcemap`, `rojo plugin install`, `mkdir ~/.local/bin`. It never edits shell rc files or harness config files (that is `mcp-config.sh`'s job, invoked explicitly).

---

## 7. Claude Code adapter

- `.claude-plugin/plugin.json`: `name: "roblox"`, `version: "0.1.0"`, description, author, `skills: "./skills"` (check the current schema with `claude plugin init --help` / docs; validate with `claude plugin validate .`).
- `.claude-plugin/marketplace.json`: one plugin entry with `source: "./"` so `claude plugin marketplace add /path/or/github` works.
- `commands/setup.md`, `commands/doctor.md`: one-paragraph aliases that tell Claude to use the `roblox-setup` / `roblox-doctor` skill with `$ARGUMENTS`.
- `.mcp.json`: `{"mcpServers": {"blender": {"command": "${CLAUDE_PLUGIN_ROOT}/mcp/blender-mcp.sh"}}}`.

## 8. Other-harness adapter — `install/install.sh`

`install.sh --harness codex|pi|omp|claude|all [--project <dir>] [--copy] [--dry-run]`
- Default: symlink each `skills/<name>` into `~/.agents/skills/<name>` (Codex + pi + OMP) — `--harness claude` → `~/.claude/skills/`; `--project <dir>` → `<dir>/.agents/skills/` (and `.claude/skills/` for claude).
- `--copy` copies instead of symlinking (for machines where the repo won't stay).
- Then calls `mcp-config.sh --harness <h>` for each harness, printing what changed.
- `uninstall.sh` removes only links/copies that point into this repo.

## 9. Tests, CI, quality

- **bats-core** (`brew install bats-core` locally; `bats-core/bats-action` or `npm i -g bats` in CI). Tests fake the machine via `RDK_*` env vars and a temp `HOME`; **no test installs anything into the real user environment**. Network tests gated by `RDK_NETWORK_TESTS=1`.
- `tests/common.bats` (helpers), `tests/doctor.bats` (table + `--json` schema + exit codes + each section with fake pass/fail fixtures), `tests/scaffold.bats` (scaffold → files exist, placeholders replaced, refuses non-empty dir, valid JSON project file), `tests/adopt.bats` (mapping → project.json), `tests/mcp-config.bats` (`--dry-run` output per harness), `tests/install.bats` (symlinks, uninstall only removes own links).
- `scripts/validate-skills.sh`: every `skills/*/SKILL.md` has frontmatter `name` (== dir name, kebab-case ≤ 64) and `description` (≤ 1024 chars, third person, says *when* to use), body ≤ 500 lines, referenced files exist.
- `shellcheck` all `.sh`; `python3 -m py_compile` all `.py`.
- CI (`.github/workflows/ci.yml`): macos-latest + ubuntu-latest → shellcheck, `make check-sync`, validate-skills, bats. Optional job (allowed to fail): install rokit + scaffold + `rojo build`.
- `Makefile` targets: `sync-lib`, `check-sync`, `lint`, `test`, `validate`, `all`.

## 10. SKILL.md conventions

Follow the Agent Skills spec and the `skill-creator` skill's guidance: frontmatter `name`, `description` (what + when, third person, include trigger phrases like "set up a Roblox project", "rojo", "doctor", "is my Roblox environment ready"), optional `compatibility` ("Requires macOS or Linux, bash, git; Blender ≥ 5.1 for Blender steps"), `metadata.version`. Keep SKILL.md short and procedural; push detail into `references/`. Scripts are run with absolute paths relative to the skill dir (`"$SKILL_DIR/scripts/doctor.sh"`); SKILL.md explains how to locate `SKILL_DIR` in each harness (the directory containing SKILL.md).

## 11. Phasing

- **Phase 1**: everything in §2 except `skills/blender-to-roblox/` and `evals/`. Validate on this machine with fake-home tests; `claude plugin validate .` passes; `shellcheck`, bats and `validate-skills` green.
- **Phase 2**: `blender-to-roblox` (export rules, `check_mesh.py`, `export_fbx.py`, `run_blender.sh` with `--background --python-exit-code 1`, `upload-asset.sh` via Open Cloud Assets API with operation polling, `references/*`), plus `evals/`.
- **Then**: review (fresh reviewer), fix pass, real-machine setup run with the user (actual Rokit install, Blender add-on, MCP registration), adopt Motor Rivals (`~/workspace/antek-filip-rivals`).

## 12. Non-goals for v1
Windows support beyond path stubs; roblox-ts; publishing/CI for the *game* beyond the template workflow; custom pi/OMP extensions; the community Blender server beyond an optional profile.
