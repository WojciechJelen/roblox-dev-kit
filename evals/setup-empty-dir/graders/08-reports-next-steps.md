---
type: llm
focus: trace
weight: 1
---

PASS if the final reply says the project was created in motor-arena/ (naming at least the Rojo project file and the src/ layout or AGENTS.md) and gives the next step of installing the pinned toolchain with the roblox-setup skill, presented as something to do once the user agrees rather than something already done.
FAIL if the reply claims tools were installed or MCP servers registered, or if it does not say where the project is.
