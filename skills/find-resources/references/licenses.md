# Licenses for assets in a Roblox game

What each license found on free asset sites means for a Roblox experience, and how to credit.
This is the kit's reading of the license texts, checked 2026-10-24; it is not legal advice. When a
license is unclear, or the asset page and the download disagree, do not use the asset.

Treat every game as **commercial**: game passes, developer products, Premium Payouts and paid access
all earn Robux, and most games add one of them sooner or later.

## The gate

| License | Use it? | Conditions in a Roblox game |
|---|---|---|
| CC0 (public domain dedication) | **Yes, preferred** | None. Record it in `CREDITS.md` anyway (where it came from, for the next person). |
| CC-BY 3.0 / 4.0, OGA-BY | Yes, **with a credit** | Credit title, author, source and license (TASL) in `CREDITS.md` and on an in-game credits screen; with 4.0, say if you changed it ("modified"). |
| Creator Store (free) | Yes | Roblox's terms: assets on the Creator Store are there "for others to use within their game development". Scan models for scripts first ([safety.md](safety.md)). Stays inside Roblox. |
| Pixabay Content License | Yes | Free, no attribution needed, may be modified. Not allowed: selling or distributing the content "on a Standalone basis" (unmodified, in substantially the same form), commercial use of recognisable trademarks or logos, misleading or immoral use (https://pixabay.com/service/license-summary/). |
| Unsplash License | Yes | Free for commercial use, no permission or attribution needed. Not allowed: selling images "without significant modification", or compiling them into a similar or competing service (https://unsplash.com/license). |
| Quaternius Asset License (QAL) v1.0 | Yes, for the game | Free for personal, educational and commercial games, no attribution; no reselling or redistributing the assets themselves, so never upload them to the Creator Store as a pack or model of their own. |
| Fab Standard License | Read it first | Not Creative Commons. Only the free Fab "starter" Megascans and assets bought under it; legacy Quixel assets obtained under the old "free for Unreal Engine" terms may not be used in Roblox. |
| Mixamo (Adobe) | Yes, but prefer Roblox's animations | Royalty-free in commercial games; the raw files may not be redistributed. Rigs are not R15. |
| MIT, ISC, Apache-2.0 (icon sets such as Lucide, Phosphor, Material Symbols) | Yes | Keep the copyright and license notice: a `CREDITS.md` row naming the license, with the license file's link. Apache-2.0 also asks you to state changes. |
| CC-BY-NC (any NC variant) | **No** | Non-commercial only; a game that earns Robux is commercial. |
| CC-BY-SA | Avoid | Adaptations must carry the same license; how far that reaches into a game is unclear. |
| CC-BY-ND | Avoid | No adaptations: rescaling, decimating, recolouring or re-texturing can count. |
| GPL (on OpenGameArt) | Avoid | Copyleft terms written for software; unclear for a closed game. |
| Unknown, "free", "royalty free" without a text | No | Ask the author or find another asset. |

`search.sh` shows CC0, CC-BY, Creator Store and Pixabay results by default (`--license by`),
CC0 only with `--license cc0`, and everything with `--license any`, where NC, SA, ND and unclear
licenses carry a warning.

Sources: Creative Commons license deeds (https://creativecommons.org/licenses/by/4.0/ and siblings);
Creative Commons' attribution guide (https://wiki.creativecommons.org/wiki/Recommended_practices_for_attribution);
Roblox Creator Store (https://create.roblox.com/docs/production/creator-store); each site's own
license page for the rest ([sources.md](sources.md) lists them).

## Per source

- **Kenney, KayKit, Poly Haven, ambientCG**: CC0 throughout. Poly Haven also asks tools that show
  its live API results to say "Powered by Poly Haven"; that is a rule for `search.sh`, not for the
  game.
- **Sketchfab, Freesound, Poly Pizza, OpenGameArt, itch.io**: the license is per item. Read it on
  the item's page; the search result's license is a hint, the page decides.
- **Creator Store audio**: Roblox's licensed library ("more than 100,000 professionally-produced
  sound effects and music tracks") is free to use in experiences. Music you upload yourself must be
  yours or licensed for it.
- **game-icons.net**: CC BY 3.0 (a few contributors CC0). Credit each author, in their example's
  form: `Icons made by {author}. Available on https://game-icons.net`.
- **Fonts**: Roblox has no custom font upload. Use the fonts in Studio or the Creator Store's font
  catalog; a font's license does not matter for a font you cannot upload.

## Credits: where and how

1. **`CREDITS.md` in the repository** (one table row per asset, added by `scripts/credit.sh`,
   which `fetch.sh` calls itself):

   ```sh
   "$SKILL_DIR/scripts/credit.sh" --name "Pine Tree" --author "Jane Doe" --license "CC-BY 4.0" \
     --source https://sketchfab.com/3d-models/pine-tree-0123abcd
   ```

   Write the license with its version (`CC-BY 3.0` and `CC-BY 4.0` differ), and add "(modified)"
   to the name when you changed a CC-BY 4.0 asset. Rerunning it for the same name and source
   changes nothing.
2. **An in-game credits screen** for every CC-BY, OGA-BY and MIT/ISC/Apache-2.0 asset: a button in
   the menu that opens a list, built from the same rows (for example a `Credits` module in
   `ReplicatedStorage` that a credits `ScreenGui` reads). A line per asset in the TASL form:

   ```text
   "Pine Tree" by Jane Doe (sketchfab.com/3d-models/pine-tree-0123abcd), CC BY 4.0, modified
   Icons made by Lorc. Available on https://game-icons.net (CC BY 3.0)
   ```

   Creative Commons recommends Title, Author, Source and License; link the license where the
   medium allows it. An experience cannot open web links, so write the addresses out.
3. CC0, Creator Store, Pixabay, Unsplash and QAL assets need no in-game credit; keep their rows in
   `CREDITS.md` so anyone can see where each asset came from.

Never upload a third-party asset to the Creator Store as your own distributed asset: QAL, Pixabay
("standalone"), Mixamo and most CC-BY-ND/SA terms forbid it, and Roblox's IP rules apply to it.
Uploading an asset to use inside your own game is fine.
