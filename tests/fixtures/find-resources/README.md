# find-resources fixtures

Answers that `tests/find-resources.bats` replays through a fake `curl`. Captured with curl on
2026-10-24 from the URLs below (the same URLs `search.sh` and `fetch.sh` build), then trimmed to two
to four results and to the fields the scripts read, so the files stay small. Nothing else was edited.

| File | Captured from |
|---|---|
| `polyhaven-search-textures.json` | `https://api.polyhaven.com/search?q=brick%20wall&t=textures&limit=3` |
| `polyhaven-assets-textures.json` | `https://api.polyhaven.com/assets?t=textures`, only `dark_brick_wall`, `brick_wall_02`, `brick_wall_07`, `brick_4` |
| `polyhaven-search-models.json` | `https://api.polyhaven.com/search?q=pine%20tree&t=models&limit=3` |
| `polyhaven-assets-models.json` | `https://api.polyhaven.com/assets?t=models`, only the three search results |
| `polyhaven-info-brick_4.json` | `https://api.polyhaven.com/info/brick_4` |
| `polyhaven-files-brick_4.json` | `https://api.polyhaven.com/files/brick_4`, maps Diffuse, nor_gl, nor_dx, Rough, arm, AO at 1k and 2k, JPG only (the tests replace size and md5 with those of their fake files) |
| `ambientcg-search-texture.json` | `https://ambientcg.com/api/v2/full_json?q=brick%20wall&type=Material,Atlas,Decal&limit=3&include=downloadData,tagData` |
| `ambientcg-asset-Bricks100.json` | `https://ambientcg.com/api/v2/full_json?id=Bricks100&include=downloadData,tagData` (the tests replace the 1K zip's size) |
| `sketchfab-cc0.json` | `https://api.sketchfab.com/v3/search?type=models&q=tree&downloadable=true&license=cc0&max_face_count=20000&count=3` |
| `sketchfab-by.json` | the same with `q=pine%20tree&license=by` |
| `roblox-marketplace-10.json` | `https://apis.roblox.com/toolbox-service/v1/marketplace/10?keyword=pine%20tree&limit=6`, with the ids of `roblox-details-10.json` |
| `roblox-details-10.json` | `https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=124879875206878,5392132809,183435411,125459331` (one paid item, one with scripts) |
| `roblox-marketplace-3.json`, `roblox-details-3.json` | category 3 (audio), `keyword=jump` |
| `roblox-marketplace-13.json`, `roblox-details-13.json` | category 13 (decals), `keyword=brick%20wall` |

Constructed, because their APIs need a key the kit does not have (marked `fixture` in names and ids):

- `freesound-search.json`: the documented sound-list format (count, next, results with the
  requested `fields`); one CC0, one CC-BY (license as a URL, as some answers give it), one NC.
- `pixabay-search.json`: the first hit is the example from https://pixabay.com/api/docs/; the second
  is a made-up vector.
- `polypizza-search.json`: a guess at the shape (the API's answer could not be checked);
  `search.sh` reads it defensively.

Model files: `benign.rbxmx` (a tree with a harmless sway script and its config module),
`backdoor.rbxmx` (a script named "Weld " hidden in a Weld that loads `require(4201337000)`, fetches
code over HTTP and decodes strings, plus a disabled purchase-prompt script) and `garbage.rbxm`
(not a model). They are hand-written XML; nothing in them is run by the tests.
