---
type: llm
focus: trace
weight: 1
---

PASS if the mapping the agent wrote for adopt.sh sends all four scripts to the locations and classes in README.md: src/Factory.lua to ReplicatedStorage/RivalsFactory as a ModuleScript, src/FX.lua to ReplicatedStorage/RivalsFX as a ModuleScript, src/Server.server.lua to ServerScriptService/RivalsServer as a Script, and src/Client.client.lua to StarterPlayer/StarterPlayerScripts/RivalsClient as a LocalScript.
FAIL if any script is missing, mapped to a different path or name, or given the wrong class.
