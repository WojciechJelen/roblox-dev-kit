# roblox-dev-kit

Agent skills for building Roblox games with AI coding agents. The kit sets up a professional
toolchain (Rokit, Rojo, Wally, StyLua, Selene, luau-lsp, Lune, Zap, Asphalt), a strict-Luau project
template, a way to move an existing Studio game into Rojo without breaking it, the Roblox Studio and
Blender MCP servers, and a doctor that says exactly what is still missing.

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

The agent decides which steps apply; shell scripts in each skill do the actual work, so every step
can also be run by hand (each script has `--help`, most have `--dry-run`).

## Install

### Claude Code

```sh
claude plugin marketplace add /path/to/roblox-dev-kit    # or the GitHub repository once published
claude plugin install roblox@roblox-dev-kit
```

Then ask "set up this Roblox project" or run `/roblox:doctor`. The plugin bundles the official
Blender MCP server (it shows up as `plugin_roblox_blender`). It does **not** bundle Roblox Studio's
server: Studio's own Quick connect registers it as `Roblox_Studio`, and a second copy would show
every Studio tool twice. If it is missing, the setup skill adds it.

### Codex CLI, pi, Oh My Pi

```sh
install/install.sh --harness codex     # or pi, omp, all
```

This symlinks each skill into `~/.agents/skills/` (all three harnesses read it) and registers the
MCP servers with that harness's own CLI (`codex mcp add`, `pi mcp add`) or, for Oh My Pi, in
`~/.omp/agent/mcp.json`. Options: `--project DIR` installs into `DIR/.agents/skills/` instead,
`--copy` copies instead of linking, `--no-mcp` skips MCP registration, `--dry-run` shows what would
happen. `install/uninstall.sh` removes only what this repo installed.

### Any other harness

Copy or link `skills/roblox-setup` and `skills/roblox-doctor` wherever the harness looks for Agent
Skills. Each skill folder is self-contained (it carries its own copy of the shared shell library).

## Requirements

macOS (Linux works except for Roblox Studio), bash 3.2 or newer, git, curl, jq. Blender 5.1 or newer
for the Blender steps; [uv](https://docs.astral.sh/uv/) for the Blender MCP server. Windows paths
are stubs only.

## Security notes

- **Blender MCP runs model-written Python inside Blender with no sandbox.** Connect it only to
  scenes you have backed up. The add-on also requires Blender's "Allow Online Access" preference;
  `setup-blender.sh` turns that on only with `--allow-online-access`.
- **The Roblox Studio MCP server can read and change your open places**, run Luau and play-test.
  Connect only agents you trust.
- **Rokit trusts tools before installing them.** `install-toolchain.sh --trust` skips Rokit's
  per-tool prompt for the versions pinned in `rokit.toml`; the skill asks before using it.
- **Open Cloud API keys** are read from `ROBLOX_API_KEY`. The doctor reports only whether it is
  set and never prints it. Keep the key out of the repository.
- The scripts never edit shell profiles or other harness configs on their own: they print the PATH
  line to add, and MCP registration happens only through `mcp-config.sh`, idempotently.

## Repository layout

```
skills/            the product: roblox-setup/, roblox-doctor/ (SKILL.md, scripts/, references/, assets/)
lib/common.sh      shared shell helpers; `make sync-lib` vendors it into each skill's scripts/lib/
mcp/               servers.json (single description of both servers) and launch wrappers
.claude-plugin/    Claude Code plugin and marketplace manifests
.mcp.json          the Blender server bundled with the plugin
commands/          /roblox:setup and /roblox:doctor
install/           install.sh / uninstall.sh for Codex, pi, Oh My Pi
tests/             bats-core suites (fake HOME, no network unless RDK_NETWORK_TESTS=1)
scripts/           validate-skills.sh, release.sh
docs/PLAN.md       design and specification
```

## Development

```sh
brew install bats-core shellcheck jq
make all          # check-sync, lint (shellcheck, JSON), validate (skills), test (bats)
```

- Edit `lib/common.sh`, never the vendored copies, then `make sync-lib`. `make check-sync` fails on
  drift; so does CI.
- Tests run every script against a fake machine under a temp directory (`RDK_HOME`, `RDK_OS`,
  `RDK_STUDIO_APP`, `RDK_BLENDER_APP` and friends; see `lib/common.sh`). They never touch the real
  HOME. Opt-in suites: `RDK_NETWORK_TESTS=1` downloads the real Rokit and tools into the fake HOME;
  `RDK_BLENDER_TESTS=1` (with `RDK_TEST_ADDON_ZIP=path/to/mcp-1.0.3.zip`, or network) installs the
  add-on into a real Blender using temp user directories.
- `claude plugin validate .claude-plugin/plugin.json` and `claude plugin validate .` check the
  manifests; `scripts/release.sh X.Y.Z` bumps every version, dates the changelog, runs `make all`,
  commits and tags (it never pushes).

## License

MIT, see [LICENSE](LICENSE).
