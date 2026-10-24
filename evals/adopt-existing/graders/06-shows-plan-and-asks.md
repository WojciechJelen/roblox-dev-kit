---
type: llm
focus: last_message
weight: 1
---

PASS if the final reply shows the planned file moves (or the generated project tree) for the four scripts, says that nothing has been moved yet, and asks the user to confirm before applying (for example by re-running with --apply).
FAIL if it says the files were moved, or ends without asking for confirmation.
