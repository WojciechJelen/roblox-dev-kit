---
type: llm
focus: trace
weight: 1
---

PASS if the final reply says that Blender is installed (in the machine's Applications folder) but the `blender` command is not on PATH, and gives the fix of linking the Blender binary into ~/.local/bin (for example `ln -s <path to Blender.app/Contents/MacOS/Blender> ~/.local/bin/blender`, possibly with `mkdir -p ~/.local/bin`), or offers to let the doctor's `--fix` create that link.
FAIL if it does not mention the PATH problem, gives a different fix for it (such as editing a shell profile to add the Blender.app folder), or says it already created the link.
