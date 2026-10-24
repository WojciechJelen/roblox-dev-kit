# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

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
- `RDK_ROJO_PORT` and `RDK_UVX` are overridable, so tests never depend on a running `rojo serve`
  or the real uvx; the kit's CI authenticates Rokit before downloading tools.
