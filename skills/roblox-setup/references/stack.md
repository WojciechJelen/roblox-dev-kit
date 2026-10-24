# Recommended Roblox Dev Stack

An opinionated stack for a small team building Roblox games, with much of the code written with AI help. The aim is the fewest moving parts that still give a professional workflow.

## Language: Luau with `--!strict` types

Skip roblox-ts unless the team already lives in TypeScript. Roblox's docs, community examples and the Studio AI/MCP tools all speak Luau.

## Toolchain

Every team member installs the same pinned versions with one command.

| Tool | Role |
|---|---|
| **Rokit** | Installs and pins versions of everything below |
| **Rojo** | Syncs files ↔ Studio |
| **Luau LSP** (VS Code) | Type checking, autocomplete |
| **StyLua** + **Selene** | Formatter + linter |
| **Wally** | Packages |
| **Lune** | Scripts for build, asset and data tasks |
| **Git + GitHub** | History and reviews (instead of `.rbxl` backup copies) |

## Runtime libraries

- **Networking: Zap.** You write a schema of client–server messages, and it generates typed code that checks the data and packs it into compact binary messages. Cheaper to send and harder to spoof than raw RemoteEvents.
- **Player data: ProfileStore.** The standard choice for saving progress between sessions.
- **UI: React-lua + Charm** for state. If you know React, it'll feel familiar. If not, **Vide** is lighter.
- **Utilities:** Trove (cleanup), Promise, GoodSignal.
- **Architecture:** plain modules split into server "services" and client "controllers", each with a clear `init()`/`start()` order. No Knit (no longer developed by its author), and no ECS (like jecs) until you have hundreds of entities.

## Quality and deployment

- **Tests:** Jest-lua, run in CI through the Open Cloud Luau Execution API.
- **CI (GitHub Actions):** StyLua check → Selene → Luau LSP analyze → tests → auto-publish to a **staging** experience. Publishing to **production** stays a manual step.
- **Two experiences:** dev/staging and prod, so you never test on live players.

## Assets

- **Blender** for models and animations. **Substance Painter** for textures, or the free **Material Maker**.
- Import via Studio's 3D Importer (`.fbx`, `.obj`, `.gltf`/`.glb`) or the Roblox Blender Plugin. Limits: at most 20,000 triangles per mesh, texture maps up to 1024×1024; with "FBX Unit Scale" 1 Blender unit = 1 stud (a stud is 28 cm in Roblox physics). The `blender-to-roblox` skill has the details and sources.
- PBR textures via `SurfaceAppearance`. Use simple collision (`CollisionFidelity = Box` or `Hull`).
- No direct Unreal import: export static meshes as FBX. Materials, Blueprints and Nanite don't transfer. Check that Fab/Megascans licenses allow use outside Unreal.
- **Asphalt** to upload images and sounds in bulk and get typed asset IDs in code.
- Meshes and the map live in the place file. Code lives in git.
- Upload assets under the same account or group that owns the experience.

## Live ops (once you have players)

- Roblox **AnalyticsService** custom events (where players quit, which options they pick).
- Roblox's built-in **A/B experiments**.

## AI on top

- **Claude Code + Roblox Studio MCP** for code, inspecting the game, and generating meshes, textures and materials.
- Rojo makes AI help better: it works on real files with types and git history, so changes can be reviewed and rolled back.

## Setup order

1. git + Rokit + Rojo + Luau LSP / StyLua / Selene. About an hour, no gameplay changes.
2. Zap for networking. Server-side input validation benefits right away.
3. ProfileStore when you add persistent progress.
4. CI + staging/prod once other people play regularly.
5. React-lua when HUD and menus outgrow a single client script.
