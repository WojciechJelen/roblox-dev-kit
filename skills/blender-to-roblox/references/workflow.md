# Workflow: from a Blender scene to a part in the Roblox place

## The loop

1. **Inspect.** Live: `get_objects_summary`, then `get_object_detail_summary` for the objects you
   will touch. Headless: `run_blender.sh --blend F check_mesh.py` (the table lists every mesh with
   triangles, size in studs, materials and UVs). Say what you found before changing anything.
2. **Write or update a `.py` file** for the change, in the user's project (`blender/` next to the
   `.blend` is a good default). Make it idempotent: find objects by name, create only what is
   missing, update the rest; reuse materials and images by name. Put the work in a
   `main(...)` function and parse options only under `if __name__ == "__main__":` (from the
   arguments after `--`), so the same file runs headless and can be imported live:

   ```python
   import sys
   import bpy

   def main(radius=1.0):
       wheel = bpy.data.objects.get("Wheel_FL")  # look up, never blindly create
       ...

   if __name__ == "__main__":
       args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
       main(radius=float(args[0]) if args else 1.0)
   ```
3. **Checkpoint** before anything substantial:
   `bpy.ops.wm.save_as_mainfile(filepath=..., copy=True)` (a copy; the open file stays as it is).
4. **Run it.**
   - Live: `execute_blender_code` with
     `import sys, importlib; sys.path.insert(0, "<folder>"); import fix_wheels; importlib.reload(fix_wheels); fix_wheels.main(...)`.
   - Headless: `run_blender.sh --blend F fix.py -- ARGS`. The script saves with
     `bpy.ops.wm.save_mainfile()` only if the change should persist, and only when no Blender has
     the file open (two writers lose one side's changes).
5. **Check** with `check_mesh.py` again: no violations, and the warnings you expect.
6. **Render a preview** and look at it: `render_thumbnail_to_path` live (read the returned path),
   `render_preview.py` headless. Compare with the request (proportions, wheel positions and
   alignment, missing faces, parts that ended up inside each other).
7. **Save** (live: ask the user, or save a copy) and **export** with `export_fbx.py`.
8. Repeat from 2 until the preview and the check are both right.

## Live MCP tools or run_blender.sh?

| Situation | Use |
|---|---|
| The user has the scene open and wants to watch or keep working in it | live tools (`execute_blender_code`, `render_thumbnail_to_path`) |
| A saved `.blend`, no live Blender, and the harness has the Blender MCP server | `execute_blender_code_for_cli` / `get_blendfile_summary_*_for_cli` work; `run_blender.sh` works as well |
| No Blender MCP server, CI, batch work over many files, or you need an exit code (0/1/2) | `run_blender.sh` |
| The live file has unsaved changes and you want to run a headless check on them | `*_for_cli` (it snapshots unsaved changes to a temporary copy), or ask the user to save |
| Long jobs (heavy renders, big exports) | `run_blender.sh`; the `*_for_cli` tools time out after 120 s |

`run_blender.sh` never uses `--factory-startup` unless asked, so the user's add-ons and preferences
load as usual; a script that saved preferences under factory settings would overwrite theirs.

## Getting the asset into Roblox

1. **Choose the route** with the user:
   - Studio's **Importer** (File › Import, or the Asset Manager): a person picks the FBX, sees a
     preview and the importer's warnings, and Studio uploads it. Keep the defaults that match the
     export (World Forward Front, World Up Top, Scale Unit Stud). Good for the first import.
   - **Open Cloud** (`upload-asset.sh`): scripted, no Studio needed. Run `--dry-run` first and get
     the user's go-ahead. Models become a `Model` of `MeshPart`s saved as a package.
2. **Wait for the operation and moderation.** `upload-asset.sh` polls until the operation is done
   and prints the moderation state (`Approved`, `Reviewing` or `Rejected`).
3. **Insert** into the open place: the Studio MCP tool `insert_asset` (`assetId`, `assetName`,
   optional `parentPath` such as `game.ServerStorage.Cars`), or Luau
   `game:GetService("InsertService"):LoadAsset(<id>)`. For a game, store the template where the
   code expects it (often `ServerStorage` or `ReplicatedStorage`) rather than in `Workspace`.
4. **Set what the FBX does not carry**:
   - `CollisionFidelity`: Box or Hull for most props and vehicle parts (cheap); Default when
     players must collide with concave shapes; PreciseConvexDecomposition sparingly.
   - `Anchored` for static props; leave vehicle parts unanchored and joined (welds or constraints)
     as the game's vehicle code expects.
   - `SurfaceAppearance` when the material should be PBR: upload the maps as images, then set
     `ColorMap`, `NormalMap`, `RoughnessMap`, `MetalnessMap` (they cannot be changed by scripts at
     run time); otherwise `MeshPart.TextureID` for a single colour texture.
   - A `PrimaryPart` and sensible pivot for models the code moves with `PivotTo`.
5. **Look at it in Studio** (`screen_capture` with the Studio MCP, or ask the user) and play-test
   when it is a vehicle.
6. **Record asset ids in code**, in a Luau module of the Rojo project (for example
   `src/ReplicatedStorage/Shared/Assets.luau`), so code refers to names rather than raw numbers.
   For whole folders of images, sounds or models, the template's toolchain also pins Asphalt, which
   syncs them to Roblox and generates such a module (https://github.com/jacktabscode/asphalt).

## Common problems

| Symptom | Likely cause |
|---|---|
| Model imports far too big | exported with Apply Scalings "All Local" (the exporter's default, which puts a ×100 unit factor on the root objects' transforms, `Lcl Scaling` and `Lcl Translation`, while the vertex coordinates stay as they are) instead of FBX Unit Scale; `export_fbx.py` always sets FBX Unit Scale |
| Model is tiny | it was modelled in metres (a 4.5 m car as 4.5 units); 1 Blender unit is 1 stud (28 cm), so scale it up in Blender or export with `--scale` |
| Lying on its side or facing backwards | axes; export with Forward Z / Up Y and keep the importer's defaults; fix orientation in Blender |
| Dark or see-through faces | flipped normals (negative scale, mirrored without applying) or one-sided faces seen from behind |
| Upload rejected with 400 | wrong `--type` for the file, or a corrupt file; read the message |
| A wheel spins around the wrong point | its origin is not at the wheel centre (`origin_offset_studs` in the check) |
