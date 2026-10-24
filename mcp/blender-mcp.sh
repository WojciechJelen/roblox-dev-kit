#!/usr/bin/env bash
# Launch the official Blender MCP server (stdio), pinned to the kit's version.
# The server talks to the Blender add-on over TCP; BLENDER_MCP_HOST / BLENDER_MCP_PORT pass through.
# stdout belongs to the MCP protocol: everything else goes to stderr.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"

# Harnesses started from a GUI often have a minimal PATH, so look in the usual uv locations too.
uvx_bin=$(command -v uvx 2>/dev/null || true)
if [ -z "$uvx_bin" ]; then
  for candidate in /opt/homebrew/bin/uvx /usr/local/bin/uvx "$RDK_HOME/.local/bin/uvx" "$RDK_HOME/.cargo/bin/uvx"; do
    if [ -x "$candidate" ]; then
      uvx_bin=$candidate
      break
    fi
  done
fi
[ -n "$uvx_bin" ] || rdk_die "uvx not found. Install uv (macOS: brew install uv; elsewhere: https://docs.astral.sh/uv/)."

# The server's *_for_cli tools run a background Blender; BLENDER_PATH spares a PATH symlink.
if [ -z "${BLENDER_PATH:-}" ] && blender=$(rdk_find_blender); then
  export BLENDER_PATH=$blender
fi
export BLENDER_MCP_PORT="${BLENDER_MCP_PORT:-$RDK_BLENDER_MCP_PORT}"

exec "$uvx_bin" --from "$RDK_BLENDER_MCP_SPEC" blender-mcp "$@"
