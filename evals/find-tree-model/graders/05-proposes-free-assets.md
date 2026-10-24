---
type: llm
focus: last_message
weight: 1
---

PASS if the reply proposes free pine-tree assets before building any: it names candidate sources (for example the Creator Store, Kenney, KayKit, Quaternius, Poly Pizza or Sketchfab), gives the license of each candidate or source (CC0 preferred; CC-BY only with a credit; nothing non-commercial), mentions Roblox's limit of 20,000 triangles per mesh, offers the Creator Store through the Studio MCP search_asset tool when Studio is connected (or the Toolbox), and asks the user which option to use or whether to build instead.
FAIL if it builds or starts building trees from parts without proposing assets first, recommends a non-commercial (NC) asset, or gives no licenses.
