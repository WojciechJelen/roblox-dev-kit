---
name: roblox-setup
description: Sets up a professional Roblox development environment for working with AI agents. It installs the Rokit-pinned toolchain (Rojo, Wally, Lune, StyLua, Selene, luau-lsp, Zap, Asphalt), scaffolds a new strict-Luau Rojo project, moves an existing game's loose scripts into a Rojo project ("adopt"), registers the Roblox Studio and Blender MCP servers with Claude Code, Codex, pi or Oh My Pi, and installs the official Blender MCP add-on. Use this skill whenever the user wants to start or set up a Roblox game or project, mentions Rojo, Rokit, Wally or luau-lsp, asks to connect Roblox Studio or Blender to the agent, wants their existing Studio scripts in git, or asks to get their Roblox dev machine ready, even if they never say "setup".
compatibility: Requires macOS or Linux with bash, git, curl and jq. Roblox Studio steps need macOS (Windows paths are stubs). Blender steps need Blender 5.1 or newer; the Blender MCP server needs uv.
metadata:
  version: "0.1.0"
---

# Roblox setup

Scripts do the deterministic work; this file says when to run which one and what to check.
`SKILL_DIR` below is the directory that contains this SKILL.md: your harness shows it when the
skill loads (Oh My Pi appends `[Skill directory: <path>]`, and `skill://roblox-setup` resolves to it
in bash). Run scripts by absolute path: `"$SKILL_DIR/scripts/<name>.sh"`. Every script has
`--help`; most have `--dry-run`.

The opinionated stack and the reasons behind it are in [references/stack.md](references/stack.md).

## 1. Start from the doctor

If the sibling `roblox-doctor` skill is installed, run
`"$SKILL_DIR/../roblox-doctor/scripts/doctor.sh" --json` (in Oh My Pi, where `../` cannot follow a
`skill://` path: `skill://roblox-doctor/scripts/doctor.sh --json`) from the project directory if
there is one, and plan from its failures. Otherwise check the same things by hand as you go. Setup is done
when the doctor has no failures.

## 2. Choose the scope: per project (default) or user

Skills, the Claude Code plugin and the MCP servers can be installed into one project or for the
whole user account. If the user has not said which, ask, and default to the project: a per-project
install lives in the game's repository, works the same for everyone who clones it, and changes
nothing for other projects. Details and the trust prompts each harness shows are in
[references/manual-steps.md](references/manual-steps.md#per-project-install).

The kit's root is two levels above this skill's real folder: `KIT=$(cd -P "$SKILL_DIR/../.." && pwd)`
(`$KIT/install/install.sh` exists in a checkout, a symlinked install and the plugin; a copied skill
folder has only `mcp-config.sh`).

- **Per project** (`<dir>` is the game's folder):
  - `"$KIT/install/install.sh" --harness all --project <dir>` links the skills into
    `<dir>/.agents/skills/` (Codex, pi, Oh My Pi) and registers the MCP servers in the project's
    own files: `.codex/config.toml`, `.pi/mcp.json`, `.omp/mcp.json` (`--dry-run` first).
  - Claude Code gets the `roblox` plugin at project scope. The installer prints the two commands;
    show them to the user and run them only with their agreement, from `<dir>`:
    `claude plugin marketplace add "$KIT" --scope project` and
    `claude plugin install roblox@roblox-dev-kit --scope project`. They write
    `<dir>/.claude/settings.json`; `--scope local` keeps the plugin to this user. Studio's server
    goes into `<dir>/.mcp.json` (the plugin brings Blender's). `--no-plugin` links loose skills into
    `<dir>/.claude/skills/` and puts both servers in `.mcp.json` instead.
  - MCP only: `mcp-config.sh --harness <h> --project <dir>`.
  - Codex and pi read project MCP files only after the user trusts the project; Claude Code asks
    once to approve servers from a project `.mcp.json`. Tell the user to expect that.
- **User scope** (the alternative): the same commands without `--project`; skills go to
  `~/.agents/skills/` or `~/.claude/skills/`, servers to each harness's user config.

## 3. Pick the modes

| Situation | Mode |
|---|---|
| Rokit or the tools are missing | toolchain |
| No project yet | new, then toolchain |
| Existing game whose scripts live in Studio or in loose files | adopt, then toolchain |
| The agent cannot see Studio or Blender tools | mcp |
| The user wants AI help with 3D models in Blender | blender, then mcp |

Run them in that order. Ask before anything that changes the user's machine beyond the project folder,
and show the dry run first when one exists.

### toolchain
`install-toolchain.sh [--project DIR | --global] [--trust]`
- Installs Rokit 1.2.0 if missing, then `rokit install` for the project (or the kit's pinned set
  globally when there is no project).
- Rokit asks the user to trust each tool and refuses when it is not attached to a terminal, which is
  the case for agents. Explain what will be trusted (the tools listed in `rokit.toml`) and pass
  `--trust` only after the user agrees; it records that trust (`rokit trust`), so later
  `rokit install` runs, including the doctor's `--fix`, do not ask again.
- The script never edits shell profiles. When it prints a PATH line, give it to the user to add
  themselves, and use `~/.rokit/bin/<tool>` by absolute path until they do.

### new
`scaffold.sh <dir> "<Project Name>"` copies `assets/template/`: strict Luau, services/controllers,
Wally, StyLua/Selene/luau-lsp config, GitHub Actions CI, `AGENTS.md` and `CLAUDE.md`. It refuses a
non-empty directory unless `--force`. The folder ↔ DataModel mapping is in
[references/template-layout.md](references/template-layout.md).
Right after scaffolding, offer the per-project install so the new game is ready for any harness:
`scaffold.sh <dir> "<Project Name>" --install-kit` (or `--install-kit=codex` for one harness) runs
`install.sh --harness all --project <dir>`; `--install-kit-args "--dry-run"` previews it, and
`--no-warm` there skips the ~200 MB Blender server download. It is never done without the flag;
ask first. `--project` always means the project's root folder; the scripts refuse a subfolder of
a Rojo project unless `--force`.

### adopt
For a game that already exists, the DataModel paths must stay the same so that nothing breaks.
1. Find where each script lives in Studio: the README, the Studio MCP tools
   (`search_game_tree`, `script_read`) or ask the user.
2. Write a mapping file (tab-separated: `source`, DataModel path, class), for example
   `src/Factory.lua	ReplicatedStorage/RivalsFactory	ModuleScript`.
3. Run `adopt.sh <dir> --mapping <file>` and show the user the plan. Re-run with `--apply` (plus
   `--with-config` to add the tool configs) once they agree.
4. Before the first `rojo serve`, the files must hold the latest code: Rojo replaces each mapped
   script in Studio with its file. Unmapped Studio content is left alone.
The generated project uses one node per script; the reasons are in
[references/template-layout.md](references/template-layout.md#adopted-projects).

### mcp
`mcp-config.sh --harness claude|codex|pi|omp|all [--project DIR] [--dry-run]` registers, in the
project's own files with `--project` (the default choice, see section 2) or else at user scope, and
only when the harness does not already get them from somewhere it reads for that project:
- `Roblox_Studio`: Studio's own server. Studio's Quick connect already uses this name in Claude Code
  and Codex; never add a second Studio server under another name, or every tool shows up twice.
- `blender`: the official Blender MCP server, pinned to 1.0.3. For Claude Code with the `roblox`
  plugin enabled the plugin already bundles it, so the script skips it.
Oh My Pi imports project-level configs (`./.mcp.json`, `./.codex/config.toml`) by default, but the
Claude Code and Codex user configs (`~/.claude.json`, `~/.codex/config.toml`, Claude Code plugins)
only when its `enabledProviders` setting lists `claude` or `codex` (default: none). When neither
applies, the script writes its own entries to `~/.omp/agent/mcp.json`. Across sources the first
definition of a name wins, so an import and a native entry do not duplicate tools.
After registering `blender` the script runs the server once to fill uv's cache: a cold start takes
about 45 s (a ~200 MB download), longer than MCP clients wait. The harness must be restarted (or
reloaded) to see new servers.
Studio itself must also have its MCP server turned on; see
[references/manual-steps.md](references/manual-steps.md#roblox-studio-mcp).

### blender
`setup-blender.sh [--allow-online-access]` installs the official add-on (checksum-verified) into
Blender's "User Default" extensions, enables it with Auto Start, saves preferences, links
`blender` into `~/.local/bin` when it is not on PATH, and pre-downloads the MCP server into uv's
cache (`--no-warm` skips that when offline). Blender must be closed.
- The add-on only starts its server while Blender's "Allow Online Access" preference is on. Ask the
  user before passing `--allow-online-access`; it is a Blender-wide privacy setting.
- If the community `blender-mcp` add-on is also installed, both want port 9876: tell the user to
  disable one.
- Tell the user plainly that the Blender MCP server runs model-written Python inside Blender with no
  sandbox, so they should keep backups of scenes they connect it to.

## 4. Finish

Run the doctor again and fix what it reports. Then walk the user through whatever only a person can do,
from [references/manual-steps.md](references/manual-steps.md): install the Rojo Studio plugin, turn on
Studio's MCP server, connect Rojo, and create an Open Cloud API key if they will upload assets.
Optional libraries (ProfileStore, Zap, React-lua, Charm, Vide, Trove, Promise, GoodSignal, Jest-lua)
are added only when the game needs them; [references/libraries.md](references/libraries.md) has the
verified Wally coordinates.
