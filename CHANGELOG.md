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
