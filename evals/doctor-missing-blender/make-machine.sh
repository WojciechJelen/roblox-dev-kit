#!/usr/bin/env bash
# A fake macOS machine inside the eval workspace: Blender 5.2.1 in Applications, nothing on PATH,
# no add-on. machine.env points the kit's RDK_* overrides at it.
set -euo pipefail
root="$PWD/machine"
mkdir -p "$root/home/.local" "$root/bin" "$root/Applications/Blender.app/Contents/MacOS"
cat >"$root/Applications/Blender.app/Contents/MacOS/Blender" <<'BLENDER'
#!/bin/sh
if [ "$1" = --version ]; then echo "Blender 5.2.1 LTS"; exit 0; fi
exit 0
BLENDER
chmod +x "$root/Applications/Blender.app/Contents/MacOS/Blender"
cat >machine.env <<ENV
# This test machine's layout. Load it in the same shell command as the doctor:
#   set -a; . ./machine.env; set +a; <command>
RDK_HOME="$root/home"
RDK_OS=macos
RDK_BLENDER_APP="$root/Applications/Blender.app"
RDK_STUDIO_APP="$root/Applications/RobloxStudio.app"
RDK_LOCAL_BIN="$root/home/.local/bin"
RDK_UVX="$root/bin/uvx"
RDK_BLENDER_MCP_PORT=1
RDK_ROJO_PORT=1
NO_COLOR=1
PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ENV
