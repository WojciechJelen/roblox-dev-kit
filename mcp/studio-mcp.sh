#!/usr/bin/env bash
# Launch Roblox Studio's built-in MCP server (stdio, no arguments).
# stdout belongs to the MCP protocol: everything else goes to stderr.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"

if ! bin=$(rdk_find_studio_mcp); then
  case "$(rdk_os)" in
    macos) rdk_die "StudioMCP not found in $RDK_STUDIO_APP. Install Roblox Studio or set RDK_STUDIO_MCP_BIN." ;;
    windows) rdk_die "%LOCALAPPDATA%\\Roblox\\mcp.bat not found. Install Roblox Studio or set RDK_STUDIO_MCP_BIN." ;;
    *) rdk_die "Roblox Studio (and its MCP server) is only available on macOS and Windows." ;;
  esac
fi
case $bin in
  *.bat) exec cmd.exe /c "$bin" "$@" ;;
esac
exec "$bin" "$@"
