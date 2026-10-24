# Optional libraries

Add a library only when the game needs it. Every coordinate below was checked on 2026-10-24 against
the Wally registry API (`https://api.wally.run/v1/package-metadata/<scope>/<name>`) and the
project's own repository; the version is the newest published one on that date. The registry also
holds many forks under other scopes; use these exact scopes.

Shared packages go in `[dependencies]` (installed to `Packages/` → `ReplicatedStorage.Packages`),
server-only packages in `[server-dependencies]` (`ServerPackages/` →
`ServerScriptService.ServerPackages`), test-only packages in `[dev-dependencies]` (`DevPackages/`).
Run `wally install` afterwards and commit `wally.toml` and `wally.lock`.

| Library | wally.toml line | Section | Verified against |
|---|---|---|---|
| ProfileStore | `ProfileStore = "lm-loleris/profilestore@1.0.3"` | `[server-dependencies]` | registry (realm `server`) and `wally.toml` in MadStudioRoblox/ProfileStore |
| Zap | not a Wally package: `zap = "red-blox/zap@0.6.29"` in `rokit.toml` (already in the template) | n/a | GitHub releases of red-blox/zap |
| React-lua | `React = "roblox/react@17.3.13"` and `ReactRoblox = "roblox/react-roblox@17.3.13"` | `[dependencies]` | registry; the Roblox/react-lua README links `wally.run/package/roblox/react` |
| Charm | `Charm = "littensy/charm@0.11.1"` | `[dependencies]` | registry and the littensy/charm README |
| Vide | `Vide = "centau/vide@0.4.1"` | `[dependencies]` | registry and `wally.toml` in centau/vide |
| Trove | `Trove = "sleitnick/trove@1.8.0"` | `[dependencies]` | registry and the Sleitnick/RbxUtil README |
| Promise | `Promise = "evaera/promise@4.0.0"` | `[dependencies]` | registry and `wally.toml` in evaera/roblox-lua-promise |
| GoodSignal | `GoodSignal = "stravant/goodsignal@0.3.1"` | `[dependencies]` | registry and `wally.toml` in stravant/goodsignal |
| Jest-lua | `Jest = "roblox/jest@3.20.1"` and `JestGlobals = "roblox/jest-globals@3.20.1"` | `[dev-dependencies]` | registry; the Roblox/jest-roblox README (which pins with `@=`) |

Not verified: whether each version works with the newest Luau type solver. Several forks
(for example of ProfileStore and Vide) exist only to fix new-solver type errors; if luau-lsp reports
errors inside `Packages/`, check the upstream issue tracker before switching to a fork.

## When to add each

**ProfileStore** (player data). Add it when the game first saves progress between sessions. It
handles session locking, so a player who rejoins quickly cannot load stale data or duplicate items.
Server only.

**Zap** (networking). Add it as soon as the game has more than a couple of RemoteEvents. You write
the messages in a `.zap` schema and run `zap` to generate typed client and server modules that
validate and pack the data into buffers. This replaces raw `RemoteEvent:FireServer(...)` calls.
Commit the generated files or generate them in CI; pick one and document it in `AGENTS.md`.

**React-lua** (UI). Add it when the HUD and menus outgrow a single client script. It needs both
`React` and `ReactRoblox`. Pair it with Charm for state. If nobody on the team knows React, consider
Vide instead.

**Charm** (state). Atoms and computed values for client state, usable from React-lua or Vide. Add it
together with the UI library, or earlier if several controllers share mutable state.

**Vide** (UI, lighter). A small reactive UI library with no virtual DOM. Choose either Vide or
React-lua, not both.

**Trove** (cleanup). Collects connections, instances and threads so one `:Destroy()` cleans them
all. Add it the first time a feature leaks connections when a player leaves or a round ends.

**Promise** (async). Chains asynchronous work with cancellation and error propagation. Add it when
`task.spawn` plus callbacks become hard to follow, for example around DataStore or HTTP calls.

**GoodSignal** (events). A fast pure-Luau signal with the `RBXScriptSignal` API, for events between
modules on the same side. Use RemoteEvents (or Zap) across the network, not signals.

**Jest-lua** (tests). Add it when the project gets logic worth unit-testing (economy, matchmaking,
damage formulas). Tests run inside Roblox, so CI needs Roblox's Open Cloud Luau Execution API or a
Studio-based runner; set that up only when the tests exist.
