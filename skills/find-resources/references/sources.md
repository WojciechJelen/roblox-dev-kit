# Free asset sources

Checked on 2026-10-24. "API" means `scripts/search.sh` queries it; "browse" means the script prints a
link and a person (or the agent, with a browser) looks. Licenses are summarised here and explained
for a Roblox game in [licenses.md](licenses.md). Every source page or API named below answered when
checked; anything that could not be checked says so.

Roblox's limits that decide the fit (from the blender-to-roblox skill's export rules): at most
20,000 triangles per mesh, PBR maps up to 1024×1024, other textures up to 4096×4096; no SVG (icons
must be PNG); no custom font upload (fonts come from the Creator Store's font catalog).

## Roblox first

| Source | How to search | License | Fit | API / key |
|---|---|---|---|---|
| Creator Store, https://create.roblox.com/store (Studio: Toolbox) | Studio MCP `search_asset` with `scope=creator_store`, `priceFilter=free`, `verifiedCreatorsOnly=true` and the `assetType`; or the store's search box with the Advanced Filter (free, verified creators) | Roblox's terms; free assets are meant for use in experiences | Already in Roblox's formats; models may carry scripts (scan them) | `search.sh` falls back to the toolbox API (below) |
| Creator Store audio library | `search_asset` with `assetType=Audio` (duration filters exist), or Toolbox › Audio | "more than 100,000 professionally-produced sound effects and music tracks" from Roblox's audio partners, free to use in experiences | Best source for sound and music: own uploads are limited (see below) | same |
| Creator Store fonts | Studio's Toolbox, font items install into the font library | Roblox's terms | The only way to get a custom-looking font: Roblox has no font upload | none |
| Roblox's own animations | the default R15 animations and Roblox's animation packs | Roblox's terms | R15-ready, unlike Mixamo | none |

- Studio MCP `search_asset` parameters (verified schema): `query`, `assetType` (Model, Audio,
  Mesh, MeshPart, Image, Decal, Video, Package), `scope` (`auto`, `creator_store`, user, group,
  universe), `priceFilter` (`free`, paid, all; needs `scope=creator_store`), `verifiedCreatorsOnly`,
  `tags`, `facets`, `maxResults` (1-20) and audio duration filters. Results carry name, type,
  source, price, creator and `thumbnailUrl`. Insert with `insert_asset(assetId, assetName,
  assetType, parentPath)`.
- The toolbox API (undocumented, used by the store's website; may change):
  `GET https://apis.roblox.com/toolbox-service/v1/marketplace/<category>?keyword=<q>&limit=<n>`
  returns `{totalResults, data: [{id}]}`; categories checked against the details endpoint's
  `typeId`: 10 = models, 3 = audio, 13 = decals (1, 2, 4, 5, 6, 8, 9, 11, 12, 14, 15, 16 answer
  400). `GET https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=<id,id>` returns
  `data[].asset` (`id`, `name`, `typeId`, `hasScripts`, `duration`,
  `audioDetails.audioType` = `SoundEffect` or `Music`,
  `modelTechnicalDetails.objectMeshSummary.triangles`), `data[].creator` (`name`,
  `isVerifiedCreator`) and the price as `data[].fiatProduct.isFree` / `purchasePrice` (USD). Paid
  items appear in searches, so `search.sh` drops every item whose `isFree` is false.
- Asset pages: `https://create.roblox.com/store/asset/<id>` (`https://www.roblox.com/library/<id>`
  redirects there). The store's `?keyword=` URL parameter is not verified, so the kit links the
  store's front page and its search box instead.
- Own audio uploads: .mp3, .ogg, .wav or .flac, under 20 MB and 7 minutes, at most 48 kHz; per 30
  days, ID-verified accounts may import 2,000 audio assets and unverified accounts 100; new audio
  is private to the uploader until shared (https://create.roblox.com/docs/audio/assets).

## 3D models

| Source | How to search | License | Fit for Roblox | API / key |
|---|---|---|---|---|
| Kenney, https://kenney.nl/assets/category:3D | browse; kits such as https://kenney.nl/assets/car-kit | CC0 on every asset page | Low poly, FBX/OBJ/glTF in most kits: very good | browse |
| KayKit, https://kaylousberg.itch.io | browse; e.g. https://kaylousberg.itch.io/kaykit-platformer | "Creative Commons Zero v1.0 Universal" | Low poly FBX/GLTF/OBJ; base tiers "name your own price" (0 works) | browse |
| Quaternius, https://quaternius.com | browse packs at `/packs/<name>.html` | Quaternius Asset License (QAL) v1.0 since 2026: free for personal, educational and commercial games, no attribution, no reselling or redistributing the assets themselves | Low poly, good; never upload them as a Creator Store pack | browse |
| Poly Pizza, https://poly.pizza/search/<q> | `search.sh --source polypizza` with a key, or the site | CC0 or CC-BY per model | Low poly GLB | `GET https://api.poly.pizza/v1.1/search/<q>` with header `x-auth-token` (`POLY_PIZZA_API_KEY`); no key → 401. The answer's shape is unverified, so `search.sh` reads it defensively |
| Sketchfab, https://sketchfab.com | `search.sh --source sketchfab` | per model: CC0, CC-BY, CC-BY-SA, CC-BY-ND, CC-BY-NC, ... | Mixed; many are too dense. `search.sh` asks for at most 20,000 faces | `GET https://api.sketchfab.com/v3/search?type=models&q=<q>&downloadable=true&license=<slug>&max_face_count=<n>&count=<n>`, no key. Downloads need a logged-in account |
| Poly Haven, https://polyhaven.com/models | `search.sh --source polyhaven` | CC0 | Photoscanned and dense (e.g. Pine Tree 01: 17,427,094 polys, a 648 MB FBX at 1k): only for decimation in Blender | see Textures |
| ambientCG, https://ambientcg.com | `search.sh --source ambientcg --type model` | CC0 | Few models (34 on 2026-10-24); the low-quality (LQ) zip has an OBJ with maps | see Textures |
| itch.io, https://itch.io/search?q=<q>&classification=assets | browse; also https://itch.io/game-assets/free/tag-low-poly, `/tag-3d` | per item, stated on each page | Varies | browse |
| OpenGameArt, https://opengameart.org | `art-search-advanced?keys=<q>&field_art_type_tid[]=10&field_art_licenses_tid[]=<id>` | per item | Varies, often older | browse |
| Mixamo, https://www.mixamo.com | browse (Adobe account) | royalty-free for commercial games; raw files may not be redistributed | Rigs are not Roblox R15; retargeting through Blender is real work, so prefer Roblox's animation packs | browse |
| Fab / Megascans, https://www.fab.com | browse | Fab Standard License (not Creative Commons; read it). The 2024 free-for-all ended; a free "starter" selection of about 1,500 Megascans stays usable in any engine. Legacy Quixel assets from the old "free for Unreal Engine" terms may not be used in Roblox | Dense photoscans | browse |

Sketchfab details: license slugs `cc0`, `by`, `by-sa`, `by-nd`, `by-nc`, `by-nc-sa`, `by-nc-nd`,
plus Sketchfab's store licenses `free-st` (Free Standard), `st` (Standard) and `ed` (Editorial)
(all from `GET https://api.sketchfab.com/v3/licenses`). The store licenses are not Creative
Commons; `search.sh --license any` shows them as "other: Free Standard" and the like, with a
warning to read the terms. A license uid in that parameter is rejected; a repeated `license=` keeps
only the last, so `search.sh` sends one request per license. `max_face_count` works. Results give
`uid`, `name`, `viewerUrl`, `license.label`, `faceCount`, `user.username`, and `archives` (`glb`,
`gltf`, `source`, `usdz`) with `faceCount` and `textureMaxResolution`. `viewerUrl` uses the slug
`none-<uid>` for titles without Latin letters, so `search.sh` links
`https://sketchfab.com/3d-models/<uid>`, which redirects (301) to the titled page.

OpenGameArt ids: type 2D Art 9, 3D Art 10, Textures 14, Music 12, Sound Effects 13, Concept Art 7273,
Documents 11; license CC0 4, CC-BY 3.0 2, CC-BY 4.0 17981, CC-BY-SA 3.0 3, CC-BY-SA 4.0 17982,
OGA-BY 3.0 10310, OGA-BY 4.0 31772, GPL 2.0 5, GPL 3.0 6; `sort_by=count&sort_order=DESC` sorts by
favourites.

## Textures and materials (PBR)

| Source | How to search | License | Fit | API / key |
|---|---|---|---|---|
| Poly Haven, https://polyhaven.com/textures | `search.sh --type texture`; `fetch.sh polyhaven:<id>` | CC0 | Excellent PBR sets | no key |
| ambientCG, https://ambientcg.com/list?q=<q> | `search.sh --type texture`; `fetch.sh ambientcg:<id>` | CC0 | Excellent PBR sets, decals, leaf atlases | no key |
| Kenney, https://kenney.nl/assets/category:Textures | browse | CC0 | Stylised | browse |
| OpenGameArt (type 14) | browse | per item | Varies | browse |
| Creator Store decals | `search_asset` with `assetType=Decal` | Roblox's terms | 2D images only, no PBR maps | toolbox fallback, category 13 |

**Normal maps: Roblox only reads OpenGL-format, tangent-space normal maps** ("Roblox only supports
OpenGL format - Tangent Space normal maps", https://create.roblox.com/docs/art/modeling/surface-appearance).
So `fetch.sh` downloads Poly Haven's `nor_gl` and ambientCG's `_NormalGL` map, never the DirectX
(`nor_dx`, `_NormalDX`) one. SurfaceAppearance takes ColorMap, NormalMap, RoughnessMap and
MetalnessMap as separate grayscale/colour images, so packed maps do not fit as they are. Poly
Haven's `arm` packs AO (red), roughness (green) and metalness (blue). Some sets in the "metal"
category have no separate `Metal` map (on 2026-10-24, 5 of the first 8: blue_metal_plate,
container_side, corrugated_iron_03, factory_wall, green_metal_rust), and measured, their `arm`
blue channel is black (mean 0.001-0.005, max at most 0.11: painted or rusty surfaces), while
corrugated_iron, which has a `Metal` map, has a blue channel matching it (mean 0.99). So a missing
`Metal` map means "not metallic". `fetch.sh` downloads `arm` for those sets anyway, records it in
`SOURCE.json` as `ARM (ambient occlusion R, roughness G, metalness B)`, and prints how to check the
blue channel (`magick in.jpg -channel B -separate out.png`, or Blender's Separate Color node). AO
and displacement are not used.

Poly Haven API (`https://api.polyhaven.com`, Swagger at `/api-docs/swagger.json`):
- `GET /assets?t=textures|models|hdris|all` returns an object keyed by asset id with `name`, `type`
  (0 HDRI, 1 texture, 2 model), `tags`, `categories`, `authors`, `download_count`,
  `max_resolution`, `polycount` (models), `thumbnail_url`.
- `GET /search?q=<q>&t=<type>&limit=<n>` ranks slugs ("hybrid semantic + keyword search", synonyms
  and any language; scores are not a "nothing found" signal). It is in the Swagger file but was not
  in the kit's first notes; if it fails, `search.sh` matches names, tags and categories itself.
- `GET /files/<id>` returns map → resolution (`1k` … `8k`) → format (`jpg`, `png`, `exr`) →
  `{url, size, md5}`; texture maps include `Diffuse`, `nor_gl`, `nor_dx`, `Rough`, `AO`,
  `Displacement`, `arm`, `Metal` (metallic sets only). `GET /info/<id>` gives one asset.
- API terms (https://github.com/Poly-Haven/Public-API/blob/master/ToS.md): free for any use; calls
  must carry a unique user agent or Referer naming the software (the kit sends
  `roblox-dev-kit/<version>`); a tool that shows live API results must say where they come from,
  for example "Powered by Poly Haven". The assets themselves need no attribution.
- Asset page: `https://polyhaven.com/a/<id>`.

ambientCG API (`https://ambientcg.com/api/v2/full_json`, docs at https://docs.ambientcg.com/api/; run
by one person, "potentially not as reliable or stable" as an enterprise service):
- `?q=<q>&limit=<n>&include=downloadData,tagData[&type=<types>]` returns
  `{numberOfResults, nextPageHttp, foundAssets: [...]}` with `assetId`, `displayName`, `dataType`,
  `tags`, `downloadCount`, `shortLink` and `downloadFolders.default.downloadFiletypeCategories.zip.downloads[]`
  (`attribute` such as `1K-JPG`, `fileName`, `size`, `downloadLink`). `?id=<assetId>` returns one.
- `type` values that filter (case-insensitive, comma-separated): `Material`, `Decal`, `Atlas`,
  `HDRI`, `HDRI-Element`, `Substance`, `Terrain`, `Brush`, and **`3D-Model`** for the `3DModel`
  data type. The API docs (https://docs.ambientcg.com/api/v2/full_json/) list `3DModel` as a
  valid type, but only `type=3D-Model` filters live today. `3DModel`, `PlainTexture` and unknown
  values are silently ignored (all assets come back). Data types seen: Material 2037, HDRI 434, Substance 211, Decal 127, Atlas 61, 3DModel 34,
  PlainTexture 9, Terrain 5, Brush 5, HDRIElement 4.
- `downloadLink` (`https://ambientcg.com/get?file=<file>`) redirects to a CDN. A material's
  `1K-JPG` zip holds `<id>_1K-JPG_Color.jpg`, `_NormalGL.jpg`, `_NormalDX.jpg`, `_Roughness.jpg`,
  `_AmbientOcclusion.jpg`, `_Displacement.jpg` (plus `_Metalness`, `_Opacity` when the set has
  them), a `.usdc`, `.blend`, `.mtlx`, `.tres` and a preview `.png`. 3D models come as
  `LQ-`/`SQ-`/`HQ-<res>-JPG` zips; the LQ zip holds an `.obj`, `.mtl` and the maps.
- Asset page: `https://ambientcg.com/view?id=<assetId>`. License: CC0 (https://docs.ambientcg.com/license/).

## Sound effects and music

| Source | How to search | License | Fit | API / key |
|---|---|---|---|---|
| Creator Store audio | `search_asset` `assetType=Audio`, Toolbox | free in experiences | Best: no upload limits apply | toolbox fallback, category 3 |
| Freesound, https://freesound.org/search/?q=<q> | `search.sh --type sound` with a key | per sound: CC0, CC-BY, CC-BY-NC | Huge; originals need a login | `GET https://freesound.org/apiv2/search/?query=<q>&filter=...&fields=id,name,username,license,duration,previews,url&page_size=<n>` with `Authorization: Token` (`FREESOUND_API_KEY`); `previews["preview-hq-mp3"]` is a 128 kbps preview; sound page `https://freesound.org/people/<user>/sounds/<id>/` (`https://freesound.org/s/<id>/` redirects there) |
| Pixabay sound effects / music | https://pixabay.com/sound-effects/search/<q>/, https://pixabay.com/music/search/<q>/ (checked in a browser; curl gets a Cloudflare challenge) | Pixabay Content License | Good | no API for audio |
| Kenney, https://kenney.nl/assets/category:Audio | browse | CC0 | UI and game sounds | browse |
| OpenGameArt (types 12, 13) | browse | per item | Varies | browse |

Freesound license filter values are the license names: `license:"Creative Commons 0"`,
`"Attribution"`, `"Attribution NonCommercial"`; `search.sh` sends
`license:("Creative Commons 0" OR "Attribution")` by default (the documented Solr OR syntax) and
adds `category:Music` for music (the documented category filter). The `license` field of a result
is documented as the license name; the kit also understands license URLs.

## Images and icons

| Source | How to search | License | Fit | API / key |
|---|---|---|---|---|
| Pixabay images, https://pixabay.com/images/search/<q>/ | `search.sh --type image` with a key | Pixabay Content License | Photos, illustrations, vectors | `GET https://pixabay.com/api/?key=<key>&q=<q>&image_type=all|photo|illustration|vector&per_page=3-200&safesearch=true` (`PIXABAY_API_KEY`); 100 requests per 60 s; answers must be cached 24 h; no mass downloads; image URLs are for showing results only (no hotlinking) |
| Unsplash, https://unsplash.com/s/photos/<q> | browse (checked in a browser; curl gets a bot check) | Unsplash License | Photos | browse |
| game-icons.net, https://game-icons.net | browse; tag pages `https://game-icons.net/tags/<tag>.html` exist for animal, arrow, blade, body, building, creature, food, gui, head, liquid, spike, symbol, tool, vehicle, weapon (others 404) | CC BY 3.0 (a few CC0): credit required | About 4,000 game icons, SVG: rasterise to PNG | browse; mirror github.com/game-icons/icons |
| Kenney UI, https://kenney.nl/assets/tag:interface | browse (UI pack, Input Prompts pack with controller and keyboard glyphs) | CC0 | PNG ready | browse |
| Lucide, https://lucide.dev/icons/ | browse | ISC (some icons MIT, from Feather): https://github.com/lucide-icons/lucide/blob/main/LICENSE | UI icons, SVG | browse |
| Phosphor, https://phosphoricons.com | browse | MIT: https://github.com/phosphor-icons/core/blob/main/LICENSE | UI icons, SVG | browse |
| Material Symbols, https://fonts.google.com/icons | browse | Apache-2.0: https://github.com/google/material-design-icons/blob/master/LICENSE | UI icons, SVG/PNG | browse |
| Creator Store decals | `search_asset` `assetType=Decal`/`Image` | Roblox's terms | Already uploaded | toolbox fallback, category 13 |

## HDRIs and skies

Poly Haven (https://polyhaven.com/hdris) and ambientCG have CC0 HDRIs, but Roblox has no HDRI sky: a
`Sky` takes six cube-face images (SkyboxBk, SkyboxDn, SkyboxFt, SkyboxLf, SkyboxRt, SkyboxUp).
Converting an HDRI to six faces is work for Blender or an image tool; Creator Store skyboxes are
usually the quicker choice.
