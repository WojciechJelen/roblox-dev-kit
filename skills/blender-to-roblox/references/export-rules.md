# Roblox mesh rules and Blender export settings

Checked against the Roblox Creator Hub on 2026-10-24 (the source repository
`github.com/Roblox/creator-docs`, `content/en-us/...`, which the site renders). Each fact names its
page. Lines marked **kit** are this kit's choices; lines marked **unverified** could not be
confirmed in the docs or on this machine.

Sources, cited below by name:
- specifications: https://create.roblox.com/docs/art/modeling/specifications
- export: https://create.roblox.com/docs/art/modeling/export-requirements
- blender: https://create.roblox.com/docs/art/blender
- textures: https://create.roblox.com/docs/art/modeling/texture-specifications
- pbr: https://create.roblox.com/docs/art/modeling/surface-appearance
- assign: https://create.roblox.com/docs/art/modeling/assign-textures
- importer: https://create.roblox.com/docs/studio/importer
- meshes: https://create.roblox.com/docs/parts/meshes
- units: https://create.roblox.com/docs/physics/units

## Limits

| Rule | Value | Source |
|---|---|---|
| Triangles per mesh | at most 20,000 ("Individual meshes can not exceed 20,000 triangles"); avatar items have their own budgets | [specifications] |
| Vertices per mesh | no general limit documented; `check_mesh.py` reports the count only | **unverified** (none found) |
| Topology | watertight, no exposed holes or backfaces; quads where possible (no n-gons); no zero-thickness meshes | [specifications] |
| Texture size | up to 4096×4096 for textures in general; "up to 1024×1024 pixel spaces for texture maps" in the UV rules and 1024×1024 as the PBR maximum | [textures] |
| Texture size guidance | 256×256 for ~5×5 stud objects, 512×512 for ~10×10, 1024×1024 for ~20×20 | [textures] |
| Texture files uploaded on their own | `.png`, `.jpg`, `.tga`, `.bmp` | [textures] |
| Materials | "Mesh objects can only have one material assigned" | [textures] |
| UVs | one UV set per component, coordinates inside 0–1, overlaps allowed | [textures] |
| Rigs | bones frozen (scale 1, rotation 0), root bone at 0,0,0, at most 4 influences per vertex, no influences on the root | [specifications] |
| Animation | one animation track per `.fbx` export | [specifications] |
| 3D file formats | `.fbx`, `.obj`, `.gltf` in Studio's Importer; `.fbx` and `.gltf` carry several meshes, PBR textures, cages, rigs, animation and vertex colours | [importer] |

**kit**: `check_mesh.py` makes the triangle limit and textures over 4096 px (`--max-texture`)
violations, and textures over 1024 px (`--texture-budget`, the PBR maximum) warnings; the rest are
warnings too. Only images connected to a material's output count: the FBX exporter writes no others,
so a stray, unconnected bake image only gets a warning. Only MESH objects are checked and exported;
curves, text and metaballs need Object › Convert › Mesh first.

## Units and scale

- Blender and Studio measure length differently; Roblox asks you to set Blender's
  **Scene › Units › Unit System** to **None** (and Rotation to Degrees) so Blender units match
  studs. [blender] "Configure units"
- For FBX, the recommended export is **Transform › Apply Scalings: FBX Unit Scale**, with every other
  scale in the project and the exporter left at 1.0; models exported this way "import into Studio or
  back into Blender at the same scale". Alternatives: export Scale 0.01, or scene Unit Scale 0.01.
  glTF needs none of this. [blender] "Adjust scale (FBX)"
- In Studio's Importer, **File Geometry › Scale Unit** says what unit the file was modelled in; it
  defaults to Studs, and Roblox's Blender guide says to keep it on Stud. [importer], [blender]
- What the exporter writes (checked on Blender 5.2.1 by decoding an export with Blender's
  `fbx2json.py`): with FBX Unit Scale and global scale 1.0 the vertex coordinates are the Blender
  values unchanged and the file declares `UnitScaleFactor` 100. Blender's exporter ignores the scene's
  Unit Scale while the Unit System is None (`io_scene_fbx/fbx_utils.py`,
  `units_blender_to_fbx_factor`), so the "Unit Scale 0.01" alternative only works with Metric or
  Imperial units.
- **kit**: `export_fbx.py` always uses FBX Unit Scale with `--scale` (default 1.0) as the global
  scale, and `check_mesh.py` reports sizes as Blender units × `--scale`, that is
  **1 Blender unit = 1 stud**. That equality is Roblox's documented outcome; it was **not verified**
  by importing into Studio on this machine.
- Physical size: Roblox's physics treats 1 stud as 28 cm. [units] A 4.5 m car is therefore about
  16 studs long; model it 16 Blender units long, not 4.5.

## Axes

- Blender is Z-up, Studio is Y-up. [blender] "Import settings"
- Export: **Forward: Z Forward**, **Up: Y Up**. [blender] "Export settings"
- Studio's Importer: **World Forward: Front** and **World Up: Top** (both the defaults). [importer], [blender]
- **kit**: model vehicles facing Blender's −Y (the side Blender's Front view looks at), as Blender
  usually does. How that maps to the car's `LookVector` in Studio was **not verified**; check the
  first import and turn the model in Blender, not in Studio, if it faces the wrong way.

## Export dialog → `bpy.ops.export_scene.fbx`

With "Limit to Selected Objects" Blender's exporter writes `context.selected_objects`
(`io_scene_fbx/export_fbx_bin.py`, Blender 5.2.1), and that list never contains hidden (eye icon),
viewport-disabled (monitor icon) or unselectable objects, nor objects in a collection excluded from
the view layer. **kit**: `export_fbx.py` shows and unlocks the target objects only while it exports,
checks that every target really is selected, and refuses objects in excluded collections.

| Roblox's instruction | Operator argument (Blender 5.2.1) | Source |
|---|---|---|
| Limit to Selected Objects | `use_selection=True` | [blender] |
| Path Mode: Copy, Embed Textures on | `path_mode="COPY"`, `embed_textures=True` | [export] |
| Apply Scalings: FBX Unit Scale | `apply_scale_options="FBX_SCALE_UNITS"`, `global_scale=1.0`, `apply_unit_scale=True` | [export], [blender] |
| Forward Z, Up Y | `axis_forward="Z"`, `axis_up="Y"` | [blender] |
| Armature: Add Leaf Bones off | `add_leaf_bones=False` | [export] |
| Bake Animation off unless the file carries animation | `bake_anim=False` | [export] |
| **kit** | `object_types={"MESH"}` (plus `"ARMATURE"` with `--with-armature`), `use_mesh_modifiers` from `--apply-modifiers`, `use_triangles` from `--triangulate` | |

The argument names and enum values were read from the operator's RNA on Blender 5.2.1.

## Textures and PBR (`SurfaceAppearance`)

- Roblox supports a basic colour texture (`MeshPart.TextureID`) or up to five PBR maps on a
  `SurfaceAppearance`: `ColorMap` (albedo, RGB), `NormalMap` (RGB, **OpenGL tangent-space** only),
  `RoughnessMap`, `MetalnessMap` (8-bit greyscale each) and `EmissiveMaskContent`. Studio uses the
  metalness workflow. [pbr], [textures], [meshes]
- In Blender, give the mesh a Principled BSDF material and connect image nodes to it: colour →
  Base Color, metallic → Metallic, roughness → Roughness, normal map → a Normal Map node →
  Normal. Exported with Path Mode Copy and Embed Textures, the importer picks them up. [assign], [export]
- `SurfaceAppearance` properties generally cannot be changed by scripts while the game runs;
  `SurfaceAppearance.Color` tinting multiplies the colour map. [pbr]
- File names: the texture page says files "should include the appropriate name affix" but lists
  none. **kit** (**unverified** as a Roblox rule): `<Object>_Color.png`, `<Object>_Normal.png`,
  `<Object>_Roughness.png`, `<Object>_Metalness.png`, `<Object>_Emissive.png`.

## Pivots, origins and names

- Importer defaults: **Set Pivot to Scene Origin** on (the whole model's pivot at the scene
  origin), **Use Imported Pivot** on for each child (each MeshPart keeps its object's pivot),
  **Insert Using Scene Position** off, **Anchored** off, **Import Only As Model** on. [importer]
- Names the importer converts: objects ending in `_Att` become `Attachment`s, `_OuterCage` →
  `WrapTarget`, `_InnerCage` with `_OuterCage` → `WrapLayer`. Do not end ordinary part names with
  these. [meshes]
- **kit**: put each object's origin where it should pivot (a wheel's at its centre), apply rotation
  and scale (Ctrl+A › All Transforms), and give parts stable names, because the game's code finds
  them by name.

## Vehicle conventions (kit)

For cars in this user's game (Motor Rivals and similar); confirm against the game's vehicle code,
which decides the names it looks for:
- the body and each wheel are separate objects; wheels are `Wheel_FL`, `Wheel_FR`, `Wheel_RL`,
  `Wheel_RR` (front/rear, left/right as seen from the driver's seat);
- wheel origins at the wheel centre, axles along the same axis for all four, transforms applied;
- check with `check_mesh.py --require-names '^Wheel_(FL|FR|RL|RR)$' --require-count 4`;
- export the body with `--objects Body` and the wheels with `--per-object` when the game spins them
  as separate parts, or everything in one FBX when the importer's Model is used as is;
- every part under 20,000 triangles; a whole car is usually far below that.

## Collision and level of detail

- `MeshPart.CollisionFidelity`: **Box** (bounding box; small or non-interactive objects), **Hull**
  (convex hull; few cavities), **Default** (approximate, supports concavity),
  **PreciseConvexDecomposition** (most precise, most expensive), **Tunable** (a `CollisionPrecision`
  slider). [meshes]
- **kit**: Box or Hull for props and vehicle parts; Default only where players must collide with
  concave shapes; Precise sparingly.
- `RenderFidelity` Automatic: highest detail under 250 studs from the camera, medium at 250–500,
  lowest beyond. [meshes]

[specifications]: https://create.roblox.com/docs/art/modeling/specifications
[export]: https://create.roblox.com/docs/art/modeling/export-requirements
[blender]: https://create.roblox.com/docs/art/blender
[textures]: https://create.roblox.com/docs/art/modeling/texture-specifications
[pbr]: https://create.roblox.com/docs/art/modeling/surface-appearance
[assign]: https://create.roblox.com/docs/art/modeling/assign-textures
[importer]: https://create.roblox.com/docs/studio/importer
[meshes]: https://create.roblox.com/docs/parts/meshes
[units]: https://create.roblox.com/docs/physics/units
