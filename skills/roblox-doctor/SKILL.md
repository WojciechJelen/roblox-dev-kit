---
name: roblox-doctor
description: Checks whether a machine and project are ready for Roblox development with AI agents, and reports exactly what is missing. It covers the Rokit toolchain and pinned tool versions, the Rojo project files, Roblox Studio and its MCP server, the Rojo Studio plugin, Blender and the official Blender MCP add-on, MCP registration in Claude Code, Codex, pi and Oh My Pi, and Open Cloud credentials. Use this skill when the user asks whether their Roblox environment is ready or working, says something like "run the doctor", "why can't you see Studio", "rojo isn't working", "Blender MCP doesn't connect", or "check my setup", and before and after any Roblox setup work, even if they do not name the skill.
compatibility: Requires bash and git; jq is optional. Read-only unless --fix is passed. Network checks run only with --online.
metadata:
  version: "0.1.0"
---

# Roblox doctor

`SKILL_DIR` is the directory that contains this SKILL.md (Oh My Pi shows it as
`[Skill directory: <path>]`; `skill://roblox-doctor` resolves to it in bash).

## Run it

```sh
"$SKILL_DIR/scripts/doctor.sh" --json            # from the project directory, if there is one
```

- `--project DIR` looks for `default.project.json` upward from DIR instead of the current directory.
- `--section toolchain,project,studio,blender,mcp,cloud` limits the run.
- `--online` adds checks that need the network (whether uvx can fetch the Blender MCP server).
- Without `--json` it prints a table for people; use it when showing results to the user.

Exit code 0 means no failures, 1 means at least one failure, 2 means a usage error.
Each check has `id`, `section`, `status` (`ok`, `warn`, `fail`, `skip`), `detail` and `fix`.
`skip` means "not applicable here" (no project, harness not installed, offline), not a problem.

## Read the result

Report failures first, then warnings, in plain language, each with its fix. Do not paste the whole
table back unless asked. Group fixes by who does them:

- **Safe fixes the doctor can do itself**: `doctor.sh --fix` creates the `blender` symlink in
  `~/.local/bin`, and runs `rokit install`, `wally install`, `rojo sourcemap` and
  `rojo plugin install` when they are the fix. It never edits shell profiles or harness configs.
  Say what `--fix` will do and get the user's go-ahead before running it.
- **Setup work**: a fix that names a `roblox-setup` script (toolchain, MCP registration, the Blender
  add-on) belongs to the `roblox-setup` skill; use it.
- **Things only the user can do**: adding a PATH line to their shell profile, turning on Studio's MCP
  server, "Allow Online Access" in Blender, creating an Open Cloud API key. Give the exact steps.

Points that are easy to get wrong:
- MCP registrations are judged for the project the doctor runs in (found upward from the current
  directory, or `--project DIR`): the user config plus the project's own files (`.mcp.json` and a
  project-scope `roblox` plugin in `.claude/settings.json`, `.codex/config.toml`, `.pi/mcp.json`,
  `.omp/mcp.json`). Inside a project a server registered nowhere visible fails; outside any project
  it is only a warning, because per-project registration is the kit's default. Run the doctor from
  the game's folder before calling an MCP setup broken.
- `mcp.<harness>.studio` failing for a harness the user does not use is noise; say so and move on.
- For Oh My Pi a server counts as registered when OMP would import it: from `./.mcp.json` or
  `./.codex/config.toml` by default, and from the Claude Code / Codex user configs only when its
  `enabledProviders` setting lists them. The detail says which source was used.
- `blender.port` is a warning because it only passes while Blender is open with the add-on running.
- `mcp.<harness>.duplicates` means the same app is registered twice (for example the `roblox`
  plugin's Blender server plus a manual `blender` entry); every tool then appears twice.
- `cloud.*` checks only matter for Open Cloud asset uploads. The doctor never prints the key.

After fixes, run the doctor again and confirm the failures are gone before saying the setup works.
