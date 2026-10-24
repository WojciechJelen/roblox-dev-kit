# Official Blender MCP server: tools

Server 1.0.3 (Blender Lab, https://projects.blender.org/lab/blender_mcp, tag `v1.0.3`). The list is
the upstream tool listing (`docs/upstream/blender-mcp-readme_tools-v1.0.3.rst` in the kit's repo);
parameters and behaviour were read from the tool sources in `mcp/blmcp/tools/` at that tag. In
Claude Code with the `roblox` plugin the tools appear under the server `plugin_roblox_blender`;
elsewhere under `blender`.

Two kinds of tools:
- **live** tools talk to the add-on in a running Blender (TCP `localhost:9876`; the add-on must be
  enabled, Auto Start on, and Blender's "Allow Online Access" on);
- **`*_for_cli`** tools take a `blend_file`, run `BLENDER_PATH` (default `blender` on PATH)
  `--background <blend_file> --python-expr ...` and need no running Blender. If a live Blender has
  that same file open with unsaved changes, the server first saves a numbered copy
  (`<name>_mcp_0001.blend`, deleted afterwards) so the background process sees the changes. The
  background run times out after 120 s and does not save the file unless your code does.

## Tools

| Tool | What it does | Used by this skill for |
|---|---|---|
| `execute_blender_code(code)` | runs Python in the live Blender; assign a JSON-serialisable dict to `result` to return data | running `check_mesh.check`, `export_fbx.export` and your fix scripts |
| `execute_blender_code_for_cli(blend_file, code)` | the same in a background Blender | checks and exports on a saved file without a live session |
| `get_objects_summary()` | collection hierarchy with each object's name, type, parent, data, selection, visibility | first look at a scene |
| `get_object_detail_summary(name)` | one object's type, transforms, parent, children, modifiers, constraints, materials, visibility, data, collections | before changing an object |
| `get_blendfile_summary_datablocks` (+`_for_cli`) | data-block counts, active workspace, render engine | sizing up an unfamiliar file |
| `get_blendfile_summary_missing_files` (+`_for_cli`) | external files (images, libraries, …) missing on disk | before exporting textures |
| `get_blendfile_summary_of_linked_libraries` (+`_for_cli`) | tree of linked libraries | files that link assets |
| `get_blendfile_summary_path_info` (+`_for_cli`) | the file's path, save state, age, backups | whether the open file has unsaved changes |
| `get_blendfile_summary_usage_guess` (+`_for_cli`) | guesses what the file is for (scored 0–100) | |
| `render_thumbnail_to_path(output_path)` | low-quality render (longest side 320 px) with the scene camera; writes to `<Blender temp dir>/blender_mcp/<basename of output_path>` and returns that `filepath` | the visual check |
| `render_viewport_to_path(output_path)` | render with the scene's current render settings | a full-quality look when needed |
| `get_screenshot_of_window_as_image()` / `get_screenshot_of_area_as_image(...)` | PNG screenshot of the Blender window or one area | seeing what the user sees |
| `get_screenshot_of_window_as_json()` | the window layout, areas, active object and selection as JSON | |
| `jump_to_tab_by_name`, `jump_to_tab_by_space_type`, `jump_to_view3d_object_by_name`, `jump_to_view3d_object_data_by_name` | switch workspace tab or frame an object in the 3D viewport | showing the user a result |
| `get_python_api_docs(identifier)`, `search_api_docs(query)`, `search_manual_docs(query)` | the bundled Blender Python API reference and user manual | checking an API before using it |

## Notes

- `render_thumbnail_to_path` ignores the directory part of `output_path`; read the returned
  `filepath`. It renders through the scene camera, so a scene without one fails; headless,
  `render_preview.py` frames the objects with a temporary camera instead.
- `execute_blender_code` runs with full access to `bpy` and the file system and no sandbox. Keep
  checkpoints of scenes you change.
- From `execute_blender_code`, import the skill's scripts rather than pasting them:
  `import sys; sys.path.insert(0, "<SKILL_DIR>/scripts"); import check_mesh` (add
  `importlib.reload(check_mesh)` after editing a script during a session).
- Never call `sys.exit` or Blender's quit operator from `execute_blender_code`: the code runs inside
  the user's Blender.
- The community server (`ahujasid/blender-mcp`) has different tools and uses the same port; it is
  not covered here.
