---
name: blender-to-roblox
description: Gets 3D models from Blender into a Roblox game. It checks meshes against Roblox's import limits (20,000 triangles per mesh, texture sizes, n-gons, UVs, unapplied transforms, hidden objects, required part names such as a car's four wheels), exports FBX with the Blender settings Roblox documents, renders a preview to look at, uploads models, images and sounds through the Open Cloud Assets API, and inserts the result in Studio. It works with a live Blender through the official Blender MCP server or headless through Blender's command line. Use this skill whenever the user wants a car, vehicle, prop, building or any other model from Blender in their Roblox place, asks whether a mesh or .blend file is ready for Roblox or within the limits, wants an FBX exported for Studio, wants an asset uploaded or needs an asset id, or edits Blender scenes for a Roblox game, even if they never mention FBX, Open Cloud or this skill.
compatibility: Requires bash and Blender (tested with 5.2.1; the official Blender MCP add-on needs 5.1 or newer). Uploads need curl, jq and an Open Cloud API key. The live path needs the official Blender MCP server; the headless path does not.
metadata:
  version: "0.1.0"
---

# Blender to Roblox

`SKILL_DIR` is the directory that contains this SKILL.md: your harness shows it when the skill loads
(Oh My Pi appends `[Skill directory: <path>]`, and `skill://blender-to-roblox` resolves to it in bash).
Run scripts by absolute path. Every script has `--help`.

| Script | Does |
|---|---|
| `"$SKILL_DIR/scripts/run_blender.sh" [--blend F] SCRIPT.py [ARGS]` | runs a Python script in a headless Blender and passes its exit code through |
| `scripts/check_mesh.py` | read-only check of mesh objects against Roblox's limits (exit 0 ok, 1 violations, 2 usage) |
| `scripts/export_fbx.py` | checks, then exports FBX with Roblox's settings; refuses violations unless `--force` |
| `scripts/render_preview.py` | renders a PNG of the objects (Workbench) and leaves the scene as it was |
| `"$SKILL_DIR/scripts/upload-asset.sh" FILE --name N` | Open Cloud upload, waits for the operation, prints the asset id |

The limits, the export settings and where each fact comes from are in
[references/export-rules.md](references/export-rules.md). Read it before changing a model's scale,
axes, textures or collision.

No model yet? The **find-resources** skill looks for a free one first (Creator Store, Kenney, Poly
Haven, Sketchfab), checks its license and scans its scripts; bring the file it finds back here.

## Pick the path

- **Live Blender** (the user has the scene open and the Blender MCP tools such as
  `get_objects_summary` and `execute_blender_code` are available): work in their open scene.
  `execute_blender_code_for_cli` and the `get_blendfile_summary_*_for_cli` tools open a saved
  `.blend` in a background Blender instead.
- **Headless** (no MCP tools, Blender closed, scripted or repeated runs, or you need exit codes):
  `run_blender.sh --blend scene.blend <script>.py -- <args>`.

[references/workflow.md](references/workflow.md) has the full loop and when to choose which;
[references/blender-mcp-tools.md](references/blender-mcp-tools.md) lists the MCP tools.

## Rules

These keep the user's work safe and make results repeatable:

- **Inspect before editing.** Summarize the scene and the objects involved (`get_objects_summary`,
  `get_object_detail_summary`, or `check_mesh.py`) before running code that changes anything.
- **Keep reusable operations in `.py` files** in the user's project (for example
  `blender/fix_wheels.py`) and run those, rather than long one-off snippets; the next session can
  read and rerun them.
- **Make scripts idempotent.** Look objects up by name and update them; a rerun must never create
  duplicates (`bpy.data.objects.get(name)` before creating, reuse materials and images by name).
- **Checkpoint before substantial changes**:
  `bpy.ops.wm.save_as_mainfile(filepath="<name>.checkpoint-<n>.blend", copy=True)` keeps the open
  file as it is and writes a copy.
- **Look before you say it is done.** Render a preview (`render_thumbnail_to_path` live,
  `render_preview.py` headless), open the image and check it yourself before declaring visual work
  finished.
- **One writer per open scene.** Do not edit a scene the user (or another agent) is editing at the
  same time, and never run headless scripts that save over a `.blend` that is open in Blender.
- The Blender MCP server runs model-written Python in Blender with no sandbox. Say so if the user
  has not heard it, and keep checkpoints of scenes you change.

## 1. Check against Roblox's limits

Headless:

```sh
"$SKILL_DIR/scripts/run_blender.sh" --blend car.blend check_mesh.py -- --json
```

Live (`execute_blender_code`; the tool returns whatever you assign to `result`):

```python
import sys; sys.path.insert(0, "<SKILL_DIR>/scripts")
import importlib, check_mesh; importlib.reload(check_mesh)
result = check_mesh.check(names=None)   # or names=["Body"], scope="selected", max_tris=...
```

Objects: `--objects A,B`, else the selection, else every mesh (`--selected` / `--all` force one).
Only MESH objects are checked and exported: curves, text and metaballs are listed with a warning;
convert them first (Object › Convert › Mesh) if they belong to the model. Triangles are counted
after modifiers and triangulation (`--no-modifiers` for the raw mesh). With `--json` the report is
the one stdout line that starts with `{`; `--report FILE` writes it to a file.

- **Violations** block the export: over `--max-tris` (default 20000) triangles, a connected texture
  larger than `--max-texture` (default 4096 px, Roblox's maximum), or too few objects matching
  `--require-names`.
- **Warnings** are worth fixing but legal: a connected texture over `--texture-budget` (default
  1024 px, the kit's default because it is the largest size Roblox documents for PBR maps), an
  image connected to nothing (it is not exported), n-gons, loose geometry, missing or extra UV
  maps, several materials, unapplied rotation or scale, negative scale, zero thickness, unapplied
  modifiers, hidden or unselectable objects, objects in a collection excluded from the view layer
  (they cannot be exported).
- **Check what you will ship.** `check_mesh.py` counts with modifiers by default, while
  `export_fbx.py` applies them only with `--apply-modifiers` (and then checks with them). Export
  with `--apply-modifiers`, or check with `--no-modifiers`, so the mesh you checked and previewed is
  the mesh in the FBX.
- Vehicles: pass `--require-names '^Wheel_(FL|FR|RL|RR)$' --require-count 4` (or the names the
  game's code expects) so a missing or misnamed wheel fails the check. Wheels need their origin at
  the wheel centre: `origin_offset_studs` should be about 0.

Report the triangle count of each mesh against the limit, then every violation, then the warnings
that matter for this model, with the fix for each.

## 2. Fix the model

Write or update a `.py` file for the change: a `main(...)` function that does the work, plus an
`if __name__ == "__main__":` block that reads options after `--` and calls it. Checkpoint, then run
it: live, `execute_blender_code` imports the file (add its folder to `sys.path`,
`importlib.reload` after edits) and calls `main(...)`; headless, `run_blender.sh --blend F fix.py --
<options>`, where the script saves the file itself, and only while no Blender has it open. Then run
the check again. Typical fixes:
Decimate or a lower Subdivision level for triangle counts, Apply All Transforms, Separate by Material
or a baked atlas for several materials, smaller images for oversized textures.

## 3. Preview

Live: `render_thumbnail_to_path` (it writes into Blender's temp folder and returns the real path;
the scene needs a camera). Headless:
`run_blender.sh --blend F render_preview.py -- --out /tmp/preview.png [--objects A,B]`.
Open the image and compare it with what the user asked for.

## 4. Export FBX

```sh
"$SKILL_DIR/scripts/run_blender.sh" --blend car.blend export_fbx.py -- --out build/car_body.fbx --objects Body --apply-modifiers
"$SKILL_DIR/scripts/run_blender.sh" --blend car.blend export_fbx.py -- --out build/wheels --per-object \
  --objects Wheel_FL,Wheel_FR,Wheel_RL,Wheel_RR --apply-modifiers
```

It checks first and refuses violations unless `--force` (ask the user before forcing). Settings:
FBX Unit Scale with every other scale at 1.0 (1 Blender unit = 1 stud), Forward Z, Up Y, Path Mode
Copy with embedded textures, meshes only (`--with-armature` adds rigs), no leaf bones, no baked
animation. `--per-object` writes one file per object (wheels that spin on their own), `--triangulate`
writes triangles, `--scale` sets studs per Blender unit, `--dry-run` only plans. Hidden or
unselectable objects are shown and unlocked only while the exporter runs (it skips them otherwise);
objects in an excluded collection are refused (exit 2). The scene is not changed. Live: `export_fbx.export("/abs/out.fbx", names=[...], apply_modifiers=True)`.

## 5. Get it into Roblox

Two ways; ask the user which, and get a yes before uploading anything: an upload creates an asset
owned by their account or group, and it goes through Roblox moderation.

- **Studio's Importer** (File › Import): a person picks the file, sees a 3D preview and the
  importer's warnings. Best for the first import of a new model.
- **Open Cloud**: `upload-asset.sh build/car_body.fbx --name "Car body"` (`--dry-run` first). It
  needs `ROBLOX_API_KEY`, `ROBLOX_CREATOR_TYPE` and `ROBLOX_CREATOR_ID` (the roblox-doctor skill's
  `cloud` checks; never print or ask the user to paste the key). It prints the asset id,
  `rbxassetid://<id>`, the moderation state and how to insert it: the Studio MCP tool
  `insert_asset` (`assetId`, `assetName`), or `InsertService:LoadAsset(id)` in Luau. FBX uploads
  become a Model of MeshParts, saved as a package. Details, limits and errors:
  [references/open-cloud-assets.md](references/open-cloud-assets.md).

After inserting, set what the file cannot carry: `CollisionFidelity` (Box or Hull for most props and
vehicle parts), `Anchored`, and a `SurfaceAppearance` for PBR maps. Then look at it in Studio
(`screen_capture` with the Studio MCP) before calling it done. Asset ids that code uses belong in a
Luau module in the Rojo project, not pasted into scripts.
