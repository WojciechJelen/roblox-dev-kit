# Free models and backdoors

Free models from the Creator Store, and `.rbxm`/`.rbxmx` files from anywhere, can carry scripts that
give a stranger control of the game ("backdoors"): they load more code from the website when the
game runs, open an admin console for the author, prompt players to buy the author's game passes, or
teleport players away. A tree, a car or a building needs no script at all, or one small, readable
one.

Roblox restricts these practices on the Creator Store, which is also the list of what to look for
(https://create.roblox.com/docs/production/creator-store): obscuring engine features (LuaVMs,
`getfenv()`, `setfenv()`); requiring remote assets (`require(assetId)`, `loadstring()`,
`InsertService:LoadAsset()`, `AssetService:LoadAssetAsync()`, `ModuleScript.LinkedSource`),
because "assets that may look useful on the surface could load another 'virus' asset at runtime";
obfuscated code; extremely large scripts. Restricted is not the same as removed: check anyway.

## The rule

Every community model is scanned **before** it is used or play-tested, because a play-test runs its
scripts. Scripts the model does not need are deleted, not just disabled.

- A file on disk (`.rbxm`, `.rbxmx`, or a place `.rbxl`/`.rbxlx`):
  `"$SKILL_DIR/scripts/scan-model.sh" FILE` (add `--json` for the agent's own use).
- A model already inserted in Studio: run the same checks with the Studio MCP tools, or save the
  model as a file from its right-click menu (Save / Export) and scan that. `script_grep` takes a
  string or Luau pattern and searches **every** script in the place (at most 50 matches), so keep
  the matches whose path is inside the model, then `script_read` each script there in full
  (`target_file` like `game.Workspace.FreeTree.Weld`). Patterns worth one call each:
  `require%s*%(%s*%d`, `getfenv`, `setfenv`, `loadstring`, `LoadAsset`, `HttpService`,
  `string%.char`, `reverse`, `Prompt%a*Purchase`, `TeleportService`. Studio's right-click
  **Disable Scripts** stops a model's scripts from running while you look.
- The toolbox results from `search.sh` say "contains scripts" when the Creator Store reports any
  (`hasScripts`); the store's asset page shows the script count.

## What the scanner flags

`scan-model.sh` lists every `LuaSourceContainer` (full name, class, enabled, run context, lines,
bytes) and checks each line of each script. Nothing in the file is run: Lune only parses it.
Every pattern runs in time proportional to the script's length (an 18 MB model takes seconds), and
a scan that needs more than `RDK_SCAN_BUDGET` seconds of work (default 120) stops: treat such a
file as unsafe. Exit 0 means nothing was found, 1 findings, 2 a usage error, an unreadable file,
no Lune, or a scan stopped by the budget.

| Severity | Rule | Pattern | Why |
|---|---|---|---|
| high | `require-id` | `require(...)` whose argument holds a 4+ digit number or a hex number anywhere (`require(-(-4201337000))`, `require(select(1, ...))`, `require(({...})[1])`, `require("4201337000")`), `require(tonumber(...))`, `require(id)` where the script sets `id` to such a number, `(require)(<id>)`, and `require` passed as a value on a line with a 6+ digit number (`pcall(require, <id>)`). Calls split over lines count too | Loads a module from the website at run time: the classic loader |
| high | `require-computed` | `require(...)` of a concatenation, arithmetic, `string.*`, `math.*`, `getfenv`, `select(...)`, or a table index | Hides which asset is loaded |
| high | `require-flood` | `require` more than 5,000 times in one script | Generated or obfuscated code |
| high | `linked-source` | a script whose `LinkedSource` is set | Its code comes from another asset |
| high | `getfenv` | `getfenv`, `setfenv` | Rewrites the environment, used to hide `require` and `loadstring` |
| high | `loadstring` | `loadstring` | Runs code from a string (needs `LoadStringEnabled`, which backdoors ask for) |
| high | `string-char` | `string.char(` with 4+ numbers or `unpack`, or 3+ `.char(` calls on a line | Builds hidden text from character codes |
| high | `escape-run` | 8+ `\ddd` or `\xHH` escapes in a row | Hidden text |
| high | `string-reverse` | `string.reverse`, `:reverse(` | Common decoder for hidden ids and URLs |
| high | `obfuscator` | Luraph, IronBrew, MoonSec, PSU, Prometheus, Synapse Xen markers | Obfuscated code cannot be reviewed |
| high | `http` | `HttpService` `GetAsync`/`PostAsync`/`RequestAsync` (also through a local alias, `game.HttpService` or `game:GetService("HttpService"):...`, and `pcall(HS.GetAsync, HS, url)`), `GetAsync("http...")`, `PostAsync`/`RequestAsync` in a script that names HttpService, `HttpGet`/`HttpPost` | Downloads code or sends data out; `game:HttpGet` exists only in exploit tools |
| high | `long-line` | a line longer than `--max-line` (default 500) characters | Minified or obfuscated code |
| medium | `purchase-prompt` | `Prompt...Purchase(` | Sells the author's products in your game |
| medium | `teleport` | `TeleportService` | Sends players to another place |
| medium | `insert-service` | `LoadAsset(`, `LoadAssetAsync(`, `LoadAssetVersion(` | Loads another asset by id while the game runs |
| medium | `script-context` | `ScriptContext` | Watches or hides script errors |
| medium | `http` | `:GetAsync(` on anything else (an HttpService request or a DataStore read), `PostAsync`/`RequestAsync` without HttpService in sight, and these methods used as values | A web request may hide behind an unknown name |
| medium | `service-name` | `GetService(...)` or `game[...]` with a name built by `..` (`"Http".."Service"`) | Hides which service is used |
| medium | `require-value` | `require` used as a value: `local r = require`, `(require)`, `{require}`, `pcall(require, ...)` | Hides what is loaded |
| medium | `odd-parent` | a script inside a Sound, Decal, Texture, Weld, Attachment, Motor6D or value object | Hiding place: nobody opens those |
| medium | `odd-name` | an empty script name, leading or trailing spaces, control or non-ASCII characters | Names made to look like "Weld" or "Script" |

At most three findings per rule and script are listed; the last says how many more lines match.
The excerpt shown is the matching line with control characters replaced and cut to 120 characters.

## Known false positives

- **Admin and framework loaders** (for example the loaders of well-known admin systems) use
  `require(<asset id>)` on purpose. That is still remote code the author can change at any time:
  only keep it when the user chose that system and the id matches its official documentation.
- **Comments and strings** are scanned like code, so `-- never use loadstring` or
  `print("require(123)")` is a finding. Read the line.
- **DataStores** read with `:GetAsync(key)`, which is also an HttpService method, so a script with a
  DataStore gets a medium `http` finding. Check that the object is a DataStore.
- `require(script.Parent.Modules["Loader" .. n])` builds a child name and counts as
  `require-computed`; read what it can load.
- `rawget(_G, "require")(id)` and similar lookups through tables are not recognised; the review
  checklist below still applies.
- **Minified libraries** (JSON or compression modules) trip `long-line`; `--max-line 2000` shows
  whether anything else is there.
- **Lobby and hub games** use `TeleportService`; **donation boards** use purchase prompts. Check the
  place ids and product ids belong to the user.
- `string.reverse` and `string.char` appear in text effects and serializers; one call with a few
  numbers is fine, long chains are not.
- A clean scan does not prove a script is safe. Read every script the model keeps.

## Review checklist

1. Run the scanner; report the verdict, every high finding with its script and line, then the
   medium ones.
2. Does the model need scripts at all? A prop needs none: delete them all. Keep only scripts whose
   purpose is obvious (an animation, a light flicker) and short enough to read.
3. Read each kept script in full. No `require` of an id, no web requests, no loading other assets,
   no purchase prompts or teleports you did not ask for.
4. Look for hiding places the scanner may miss: scripts named like built-in objects, scripts deep in
   meshes, `Disabled` scripts another script enables, `ModuleScript`s nobody requires (yet).
5. After inserting, run the game in Studio with the Output window open, and check
   `ServerScriptService`, `ReplicatedFirst` and `StarterPlayer` for anything new.
6. Never turn on `HttpService.HttpEnabled` or `LoadStringEnabled` because a free model asks for it.
