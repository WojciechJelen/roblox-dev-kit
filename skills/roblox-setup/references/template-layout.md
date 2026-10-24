# Project layout

## New projects (scaffold.sh)

`default.project.json` maps folders to the DataModel:

| Folder | DataModel | Notes |
|---|---|---|
| `src/ServerScriptService/` | `ServerScriptService` | Server entry `Server.server.luau` and `Services/` |
| `src/StarterPlayerScripts/` | `StarterPlayer.StarterPlayerScripts` | Client entry `Client.client.luau` and `Controllers/` |
| `src/ReplicatedStorage/Shared/` | `ReplicatedStorage.Shared` | Code used by both sides |
| `Packages/` | `ReplicatedStorage.Packages` | Wally `[dependencies]`; optional until `wally install` |
| `ServerPackages/` | `ServerScriptService.ServerPackages` | Wally `[server-dependencies]`; optional |
| (none) | `HttpService.HttpEnabled = false` | Turn on only when the game calls external HTTP |

`Packages` and `ServerPackages` use `"$path": { "optional": "..." }`, so `rojo build` and
`rojo serve` work before the first `wally install`.

Because `ServerScriptService` and `StarterPlayerScripts` are mapped with `$path`, Rojo owns them:
instances created there in Studio are removed on sync. `ReplicatedStorage` itself has no `$path`,
so Studio-made instances there (models, sounds, remotes created by hand) survive. Put Studio-made
assets in `ReplicatedStorage`, `ServerStorage` or `Workspace`, not in the Rojo-owned folders.

### File name → instance

| File | Instance |
|---|---|
| `Name.server.luau` | `Script` named `Name` |
| `Name.client.luau` | `LocalScript` named `Name` |
| `Name.luau` | `ModuleScript` named `Name` |
| `Folder/init.luau` (or `init.server.luau`, `init.client.luau`) | `Folder` becomes that script; other files in it become its children |
| any other folder | `Folder` |

`.lua` works the same as `.luau`.

### Where code goes

- **Service** (server logic: data, combat, matchmaking): `src/ServerScriptService/Services/<Name>Service.luau`.
- **Controller** (client logic: input, camera, UI): `src/StarterPlayerScripts/Controllers/<Name>Controller.luau`.
- **Shared module** (types, constants, pure functions): `src/ReplicatedStorage/Shared/<Name>.luau`.

Each service or controller is a module table with optional `init()` and `start()`. The entry
script requires every module in its folder in name order, calls all `init()` functions, then runs
each `start()` in its own thread. Keep `init()` free of yields and cross-module calls; anything
that needs another module goes in `start()`.

Require shared code by instance path: `require(ReplicatedStorage.Shared.Example)` on the server and
`require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Example"))` on the client. luau-lsp
resolves both through `sourcemap.json`. The `.luaurc` aliases (`@Shared`, `@Packages`) serve tools
that read files directly, such as Lune scripts.

### Tooling files

| File | Purpose |
|---|---|
| `rokit.toml` | Exact tool versions; `rokit install` |
| `wally.toml` / `wally.lock` | Packages; commit the lock file |
| `.luaurc` | `languageMode: strict`, require aliases |
| `selene.toml`, `stylua.toml` | Lint and format rules |
| `sourcemap.json` | Generated (`rojo sourcemap`), git-ignored; luau-lsp needs it |
| `.vscode/` | luau-lsp, StyLua and Selene settings and recommended extensions |
| `.github/workflows/ci.yml` | StyLua check, Selene, luau-lsp analyze, `rojo build` |
| `AGENTS.md`, `CLAUDE.md` | Instructions for coding agents (`CLAUDE.md` imports `AGENTS.md`) |

## Adopted projects

`adopt.sh` keeps each script at its existing DataModel path and writes one project node per script:

```json
"ReplicatedStorage": {
  "$ignoreUnknownInstances": true,
  "RivalsFactory": { "$path": "src/ReplicatedStorage/RivalsFactory.lua" }
}
```

It does not map whole services to folders. Rojo sets `$ignoreUnknownInstances` to false for any
node with a `$path`, so a mapped service would lose every instance that is not in a file, which
for an existing game means its maps, models and hand-made remotes. Per-script nodes under services
that ignore unknown instances change only the scripts in the mapping.

Files are moved to `src/<service>/<folders...>/<Name><suffix>` so the tree on disk mirrors the
DataModel, and renamed so the suffix matches the class (`.server` for Script, `.client` for
LocalScript, none for ModuleScript). The extension (`.lua` or `.luau`) is kept. In a git repository
tracked files are moved with `git mv` so history follows them.

Intermediate folders in a DataModel path (`ReplicatedStorage/Modules/X`) become `Folder` nodes that
also ignore unknown instances. A script that has mapped children is not supported; convert it to
the `init.lua` layout by hand.

The `.luaurc` that `--with-config` writes for an adopted project uses `languageMode: nonstrict`,
because existing code was not written for strict mode. Move files to strict one at a time by adding
`--!strict` at the top.

To add code to an adopted project later, either edit `default.project.json` by hand following the
same pattern, or keep the mapping file: point every source column at the file's current path (those
lines print as `keep`), add the new line, and re-run `adopt.sh --force`, which rewrites
`default.project.json` from the whole mapping.
