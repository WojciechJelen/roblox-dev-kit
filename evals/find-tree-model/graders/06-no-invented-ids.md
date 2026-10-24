---
type: llm
focus: trace
weight: 1
---

PASS if every asset id, asset page URL and download link in the final reply appears in a tool result earlier in the trace (search.sh output, a dry run's request list, a reference file), or the reply gives none and says what a search would return.
FAIL if the final reply names a Creator Store asset id, a model page or a download link that no tool returned, or presents guessed search results as real ones.
