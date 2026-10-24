# Steps only the user can do

Walk the user through these after the scripts have run. Give one step at a time and wait for
confirmation; most happen in a GUI the agent cannot see.

## PATH lines

The scripts never edit shell profiles. When one prints a line such as
`export PATH="$HOME/.rokit/bin:$PATH"`, the user adds it to `~/.zshrc` (zsh, the macOS default) or
`~/.bashrc` (bash) and opens a new terminal. Until then, call tools by absolute path
(`~/.rokit/bin/rojo`). The same applies to `~/.local/bin` for the `blender` symlink.

## Rojo Studio plugin

Either:
- run `rojo plugin install` (writes `RojoManagedPlugin.rbxm` into `~/Documents/Roblox/Plugins` on
  macOS); the doctor's `--fix` does this when rojo is on PATH; or
- install "Rojo" from the Creator Store inside Studio.

Then restart Studio. To connect: run `rojo serve` in the project folder, open the place in Studio,
click **Rojo** in the Plugins tab, then **Connect** (default `localhost:34872`).

The plugin version should match the CLI's major and minor version (7.7 with `rojo 7.7.1`); the
plugin warns when they differ.

## Roblox Studio MCP

Source: https://create.roblox.com/docs/studio/mcp (checked 2026-10-24; menu names may change).

1. In Studio, open **Assistant**, click **…** → **Manage MCP Servers**.
2. Turn on **Enable Studio as MCP server**.
3. Either use **Quick connect** (Claude Code, Codex CLI, Claude Desktop, Cursor, Gemini CLI, VS Code,
   Antigravity) or rely on `mcp-config.sh`, which registers the same command under the same name
   (`Roblox_Studio`). Do not do both under different names.
4. Restart the agent. In Studio, a green indicator under the toggle shows connected clients.

The server binary on macOS is `/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP`; on Windows
it is started with `cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat`. With several Studio windows open,
every tool takes a `studio_id`; `list_roblox_studios` lists them.

## Blender add-on

`setup-blender.sh` does all of this. To do it by hand, or to check what it did:

1. Download `mcp-1.0.3.zip` from https://projects.blender.org/lab/blender_mcp/releases (the zip is
   the add-on; ignore the `.mcpb` file, which is for Claude Desktop).
2. Blender → **Edit › Preferences › Get Extensions** → the drop-down menu → **Install from Disk…**
   → pick the zip. It lands in the "User Default" repository, folder
   `~/Library/Application Support/Blender/<version>/extensions/user_default/mcp` on macOS.
3. In **Add-ons**, expand **MCP**: keep **Auto Start** on; host `localhost`, port `9876`.
4. **Preferences › System › Network › Allow Online Access** must be on, or the add-on refuses to
   start its server ("Online access must be enabled in the system preferences").
5. Restart Blender. With Blender open, the doctor's `blender.port` check turns green.

For headless use the add-on also serves without a window:
`blender --background scene.blend --command blender_mcp` (add `--port N` to change the port).

Security: the server executes Python written by the model inside Blender without a sandbox. Work on
copies of important `.blend` files and keep backups.

The community add-on (`ahujasid/blender-mcp`, "MCP for Blender") also uses port 9876. If both are
installed, disable one in **Preferences › Add-ons**.

## Open Cloud API key (asset uploads)

Only needed to upload meshes, images or sounds from scripts (Asphalt, or the `blender-to-roblox`
skill).

1. Go to https://create.roblox.com/dashboard/credentials → **Create API Key**.
2. Add the **Assets** API with read and write access. Restrict the key to the experience or group it
   is for, and set an expiry and an IP allow-list if the user's network allows it.
3. Store the key outside the repository and export it in the shell profile or a git-ignored env file:
   `ROBLOX_API_KEY`, plus `ROBLOX_CREATOR_TYPE` (`User` or `Group`) and `ROBLOX_CREATOR_ID`.
   Upload assets as the same user or group that owns the experience.
4. Never paste the key into chat, commit it, or put it in `AGENTS.md`.
