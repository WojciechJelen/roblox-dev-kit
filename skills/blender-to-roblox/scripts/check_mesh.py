"""Check Blender mesh objects against Roblox's import limits.

Runs inside Blender's Python (needs bpy):

    run_blender.sh --blend car.blend check_mesh.py -- --json
    blender --background car.blend --python check_mesh.py -- --objects Body,Wheel_FL

or, from code already running in Blender (the Blender MCP server's execute_blender_code):

    import sys; sys.path.insert(0, "<skill dir>/scripts")
    import check_mesh
    result = check_mesh.check(names=["Body"])      # a JSON-serialisable dict

Read-only: it never changes the scene. Exit codes: 0 no violations (warnings allowed),
1 violations, 2 usage error. With --json the report is printed as one line that starts with
"{" (Blender prints its own status lines around it); --report FILE also writes it to a file.

Limits and their sources are in references/export-rules.md: 20,000 triangles per mesh
(https://create.roblox.com/docs/art/modeling/specifications) and textures up to 4096x4096, with
1024x1024 the largest size documented for PBR maps
(https://create.roblox.com/docs/art/modeling/texture-specifications). Larger than 4096 (or
--max-texture) is a violation; larger than 1024 (--texture-budget) a warning. Only images connected
to a material's output count, because the FBX exporter writes no others. Only MESH objects are
checked; curves, text and metaballs are reported so they can be converted first.
Sizes are in studs: the kit exports FBX with "FBX Unit Scale" and a global scale of 1.0, which
Roblox documents as importing at the same scale, so 1 Blender unit = 1 stud (times --scale).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from array import array

DEFAULT_MAX_TRIS = 20000
DEFAULT_MAX_TEXTURE = 4096     # the largest texture Roblox supports
DEFAULT_TEXTURE_BUDGET = 1024  # the largest size Roblox documents for PBR maps
EPSILON = 1e-4
# Object types that look like geometry in Blender but are not exported as meshes until converted.
CONVERTIBLE_TYPES = ("CURVE", "SURFACE", "FONT", "META")


class UsageError(Exception):
    """Bad arguments or objects that do not exist (exit code 2)."""


def script_args(argv=None):
    """Arguments meant for this script: those after "--" inside Blender, else argv[1:]."""
    argv = sys.argv if argv is None else argv
    if "--" in argv:
        return argv[argv.index("--") + 1:]
    return [] if "bpy" in sys.modules else argv[1:]


def split_names(value):
    return [n.strip() for n in value.split(",") if n.strip()] if value else []


def resolve_objects(names=None, scope=None):
    """The mesh objects to work on and how they were chosen ("objects", "selection" or "all").

    NAMES wins; scope "selected" means the selection only, "all" every mesh in the scene;
    otherwise the selection if anything is selected, else every mesh.
    """
    import bpy

    scene = bpy.context.scene
    if names:
        objects = []
        for name in names:
            obj = scene.objects.get(name)
            if obj is None:
                raise UsageError("no object named %r in scene %r" % (name, scene.name))
            if obj.type != "MESH":
                raise UsageError("%r is a %s, not a mesh; convert it first (Object > Convert > Mesh)" % (
                    name, obj.type.lower()))
            objects.append(obj)
        return objects, "objects"
    meshes = [o for o in scene.objects if o.type == "MESH"]
    chosen = [] if scope == "all" else [o for o in meshes if _selected(o)]
    if scope == "selected" and not chosen:
        raise UsageError("no mesh objects are selected")
    if chosen:
        return chosen, "selection"
    if not meshes:
        raise UsageError("scene %r has no mesh objects" % scene.name)
    return meshes, "all"


def _selected(obj):
    """select_get() raises for objects outside the view layer (in an excluded collection)."""
    import bpy

    return obj.name in bpy.context.view_layer.objects and obj.select_get()


def _image_nodes(tree, seen=None):
    """Image texture nodes in a node tree, including inside node groups."""
    seen = set() if seen is None else seen
    if tree is None or tree.name in seen:
        return
    seen.add(tree.name)
    for node in tree.nodes:
        if node.type == "TEX_IMAGE" and node.image is not None:
            yield node
        elif node.type == "GROUP":
            yield from _image_nodes(node.node_tree, seen)


def _feeding_output(tree):
    """Pointers of the nodes that feed the material output (the active one, else every output),
    following links backwards and into node groups. Unconnected nodes are not exported."""
    outputs = [n for n in tree.nodes if n.type == "OUTPUT_MATERIAL"]
    stack = [n for n in outputs if getattr(n, "is_active_output", False)] or outputs
    found = set()
    while stack:
        node = stack.pop()
        if node.as_pointer() in found:
            continue
        found.add(node.as_pointer())
        for socket in node.inputs:
            stack.extend(link.from_node for link in socket.links if not link.is_muted)
        if node.type == "GROUP" and node.node_tree is not None:
            stack.extend(n for n in node.node_tree.nodes if n.type == "GROUP_OUTPUT")
    return found


def _geometry(mesh):
    """Counts and the local bounding box of a mesh datablock, using bulk foreach_get reads."""
    n_polys = len(mesh.polygons)
    totals = array("i", [0]) * n_polys
    mesh.polygons.foreach_get("loop_total", totals)
    used = array("i", [0]) * len(mesh.loops)
    mesh.loops.foreach_get("vertex_index", used)
    loose_edges = array("b", [0]) * len(mesh.edges)
    mesh.edges.foreach_get("is_loose", loose_edges)
    co = array("f", [0.0]) * (3 * len(mesh.vertices))
    mesh.vertices.foreach_get("co", co)
    if co:
        lo = [min(co[i::3]) for i in range(3)]
        hi = [max(co[i::3]) for i in range(3)]
    else:
        lo = hi = [0.0, 0.0, 0.0]
    return {
        # Triangulating an n-sided face gives n - 2 triangles; Roblox counts triangles.
        "triangles": sum(totals) - 2 * n_polys,
        "vertices": len(mesh.vertices),
        "faces": n_polys,
        "ngons": sum(1 for t in totals if t > 4),
        "loose_vertices": len(mesh.vertices) - len(set(used)),
        "loose_edges": sum(loose_edges),
        "uv_layers": len(mesh.uv_layers),
        "bbox": (lo, hi),
    }


def inspect_object(obj, depsgraph, use_modifiers=True, scale=1.0):
    """Facts about one mesh object, as a JSON-serialisable dict (without verdicts)."""
    import bpy

    in_view_layer = obj.name in bpy.context.view_layer.objects
    if use_modifiers:
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        try:
            geo = _geometry(mesh)
        finally:
            evaluated.to_mesh_clear()
    else:
        geo = _geometry(obj.data)

    _, rotation, basis_scale = obj.matrix_basis.decompose()
    world_scale = obj.matrix_world.to_scale()
    lo, hi = geo.pop("bbox")
    dims = [abs((hi[i] - lo[i]) * world_scale[i]) * scale for i in range(3)]
    centre = [(hi[i] + lo[i]) / 2 * world_scale[i] * scale for i in range(3)]

    unapplied = []
    if rotation.angle > EPSILON:
        unapplied.append("rotation")
    if any(abs(s - 1.0) > EPSILON for s in basis_scale):
        unapplied.append("scale")

    materials = []
    textures = []
    for slot in obj.material_slots:
        mat = slot.material
        if mat is None or mat.name in materials:
            continue
        materials.append(mat.name)
        if mat.node_tree is None:
            continue
        feeding = _feeding_output(mat.node_tree)
        for node in _image_nodes(mat.node_tree):
            image = node.image
            linked = node.as_pointer() in feeding
            known = next((t for t in textures if t["image"] == image.name), None)
            if known is not None:
                known["linked"] = known["linked"] or linked
                continue
            width, height = image.size
            textures.append({"image": image.name, "width": width, "height": height, "material": mat.name,
                             "linked": linked})

    return dict(
        geo,
        name=obj.name,
        data=obj.data.name,
        dimensions_studs=[round(d, 3) for d in dims],
        origin_offset_studs=round(sum(c * c for c in centre) ** 0.5, 3),
        has_uvs=geo["uv_layers"] > 0,
        unapplied_transforms=unapplied,
        negative_scale=any(s < 0 for s in world_scale),
        materials=materials,
        textures=textures,
        modifiers=[m.name for m in obj.modifiers],
        in_view_layer=in_view_layer,
        hidden=bool(in_view_layer and obj.hide_get()),
        hidden_viewport=obj.hide_viewport,
        unselectable=obj.hide_select,
    )


def judge(info, max_tris, max_texture, texture_budget, use_modifiers):
    """(violations, warnings) for one inspected object: lists of {code, message}."""
    violations, warnings = [], []

    def add(target, code, message):
        target.append({"object": info["name"], "code": code, "message": message})

    if info["triangles"] > max_tris:
        add(violations, "tris", "%d triangles, over the %d limit" % (info["triangles"], max_tris))
    for tex in info["textures"]:
        side = max(tex["width"], tex["height"])
        size = "%dx%d" % (tex["width"], tex["height"])
        if not tex["linked"]:
            if side > texture_budget:
                add(warnings, "unlinked-texture", "image %r (%s) is not connected to the material output, "
                    "so it is not exported" % (tex["image"], size))
        elif side == 0:
            add(warnings, "missing-image", "image %r has no pixels (missing file?)" % tex["image"])
        elif side > max_texture:
            add(violations, "texture", "image %r is %s, over the %d px limit" % (tex["image"], size, max_texture))
        elif side > texture_budget:
            add(warnings, "texture-budget", "image %r is %s, over the %d px budget (the largest size Roblox "
                "documents for PBR maps)" % (tex["image"], size, texture_budget))
    if info["faces"] == 0:
        add(warnings, "no-faces", "has no faces, so nothing would import")
    if info["ngons"]:
        add(warnings, "ngons", "%d n-gon(s); Roblox asks for quads where possible" % info["ngons"])
    if info["loose_vertices"] or info["loose_edges"]:
        add(warnings, "loose", "loose geometry: %d vertices, %d edges outside any face" % (
            info["loose_vertices"], info["loose_edges"]))
    if not info["has_uvs"]:
        add(warnings, "no-uvs", "no UV map, so textures cannot be applied")
    elif info["uv_layers"] > 1:
        add(warnings, "uv-sets", "%d UV maps; Studio uses a single UV set" % info["uv_layers"])
    if len(info["materials"]) > 1:
        add(warnings, "materials", "%d materials; Roblox mesh objects take one material each" % len(info["materials"]))
    if info["unapplied_transforms"]:
        add(warnings, "transforms", "%s not applied (Ctrl+A > All Transforms)" % " and ".join(info["unapplied_transforms"]))
    if info["negative_scale"]:
        add(warnings, "negative-scale", "negative scale (mirrored); normals may import flipped")
    if info["faces"] and min(info["dimensions_studs"]) < EPSILON:
        add(warnings, "flat", "zero thickness; Roblox meshes need some volume")
    if not info["in_view_layer"]:
        add(warnings, "excluded", "not in the view layer (its collection is excluded), so it cannot be "
            "exported; tick the collection in the Outliner first")
    elif info["hidden"] or info["hidden_viewport"]:
        add(warnings, "hidden", "hidden; the FBX exporter skips hidden objects (export_fbx.py shows it "
            "while it exports)")
    if info["unselectable"]:
        add(warnings, "unselectable", "not selectable; the FBX exporter skips it (export_fbx.py unlocks it "
            "while it exports)")
    if info["modifiers"] and not use_modifiers:
        add(warnings, "modifiers", "%d modifier(s) not included (export with --apply-modifiers)" % len(info["modifiers"]))
    return violations, warnings


def check(names=None, scope=None, max_tris=DEFAULT_MAX_TRIS, max_texture=DEFAULT_MAX_TEXTURE,
          texture_budget=DEFAULT_TEXTURE_BUDGET, use_modifiers=True, scale=1.0, require_names=None,
          require_count=1):
    """Check mesh objects and return the report dict. Raises UsageError for bad input."""
    import bpy

    if max_tris < 1 or max_texture < 1 or texture_budget < 1 or scale <= 0 or require_count < 1:
        raise UsageError("--max-tris, --max-texture, --texture-budget, --scale and --require-count must be positive")
    pattern = None
    if require_names:
        try:
            pattern = re.compile(require_names)
        except re.error as ex:
            raise UsageError("bad --require-names pattern: %s" % ex) from None

    objects, scope = resolve_objects(names, scope)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    infos, violations, warnings = [], [], []
    for obj in objects:
        info = inspect_object(obj, depsgraph, use_modifiers, scale)
        bad, meh = judge(info, max_tris, max_texture, texture_budget, use_modifiers)
        info["violations"] = [v["message"] for v in bad]
        info["warnings"] = [w["message"] for w in meh]
        infos.append(info)
        violations.extend(bad)
        warnings.extend(meh)

    if not names:
        # Curves, text and metaballs in the same scope are skipped; say so, they may be part of the model.
        pool = [o for o in bpy.context.scene.objects if o.type in CONVERTIBLE_TYPES]
        if scope == "selection":
            pool = [o for o in pool if _selected(o)]
        for obj in pool:
            warnings.append({"object": obj.name, "code": "not-mesh", "message": "%s is a %s, not a mesh, so it "
                             "is not checked or exported; convert it (Object > Convert > Mesh)" % (
                                 obj.name, obj.type.lower())})

    if pattern is not None:
        matched = [i["name"] for i in infos if pattern.search(i["name"])]
        if len(matched) < require_count:
            violations.append({"object": None, "code": "require-names", "message": "%d object(s) match %r (%s), expected at least %d" % (
                len(matched), require_names, ", ".join(matched) or "none", require_count)})

    return {
        "tool": "check_mesh",
        "blender": bpy.app.version_string,
        "blend_file": bpy.data.filepath,
        "scope": scope,
        "limits": {"max_tris": max_tris, "max_texture": max_texture, "texture_budget": texture_budget},
        "modifiers": use_modifiers,
        "scale": scale,
        "objects": infos,
        "violations": violations,
        "warnings": warnings,
        "summary": {
            "objects": len(infos),
            "triangles": sum(i["triangles"] for i in infos),
            "violations": len(violations),
            "warnings": len(warnings),
        },
        "ok": not violations,
    }


def format_table(report):
    """The report as a table for people."""
    lines = []
    limits = report["limits"]
    lines.append("check_mesh: %d object(s) (%s) in %s; limits: %d triangles per mesh, %d px textures "
                 "(%d px budget)" % (report["summary"]["objects"], report["scope"],
                                     report["blend_file"] or "unsaved scene", limits["max_tris"],
                                     limits["max_texture"], limits["texture_budget"]))
    width = max([len("object")] + [len(o["name"]) for o in report["objects"]])
    lines.append("")
    lines.append("    %-*s  %7s  %7s  %-24s  %3s  %s" % (width, "object", "tris", "verts", "size in studs (x y z)", "mat", "uv"))
    for o in report["objects"]:
        mark = "x" if o["violations"] else ("!" if o["warnings"] else "ok")
        size = " x ".join("%g" % d for d in o["dimensions_studs"])
        lines.append("%-2s  %-*s  %7d  %7d  %-24s  %3d  %s" % (
            mark, width, o["name"], o["triangles"], o["vertices"], size, len(o["materials"]),
            "yes" if o["has_uvs"] else "no"))
        for message in o["violations"]:
            lines.append("    %*s  violation: %s" % (width, "", message))
        for message in o["warnings"]:
            lines.append("    %*s  warning: %s" % (width, "", message))
    checked = {o["name"] for o in report["objects"]}
    for v in report["violations"]:
        if v["object"] not in checked:
            lines.append("x   violation: %s" % v["message"])
    for w in report["warnings"]:
        if w["object"] not in checked:
            lines.append("!   warning: %s" % w["message"])
    s = report["summary"]
    lines.append("")
    lines.append("%d triangles in total; %d violation(s), %d warning(s)" % (s["triangles"], s["violations"], s["warnings"]))
    return "\n".join(lines)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="check_mesh.py",
        description="Check mesh objects against Roblox's import limits (run inside Blender, "
                    "for example with run_blender.sh). Exit 0 ok, 1 violations, 2 usage error.")
    add_check_arguments(parser)
    parser.add_argument("--no-modifiers", action="store_true",
                        help="count the mesh data without modifiers (default: as evaluated, with modifiers)")
    parser.add_argument("--json", action="store_true", help="print the report as one line of JSON")
    parser.add_argument("--report", metavar="FILE", help="also write the JSON report to FILE")
    return parser


def add_check_arguments(parser):
    """Options shared with export_fbx.py."""
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--objects", metavar="A,B", help="these mesh objects (default: the selection, else all meshes)")
    scope.add_argument("--selected", action="store_true", help="only the selected mesh objects")
    scope.add_argument("--all", action="store_true", help="every mesh object in the scene, ignoring the selection")
    parser.add_argument("--max-tris", type=int, default=DEFAULT_MAX_TRIS, metavar="N",
                        help="triangle limit per mesh (default %(default)s, Roblox's documented limit)")
    parser.add_argument("--max-texture", type=int, default=DEFAULT_MAX_TEXTURE, metavar="PX",
                        help="a connected texture with a longer side is a violation (default %(default)s, "
                             "the largest Roblox supports)")
    parser.add_argument("--texture-budget", type=int, default=DEFAULT_TEXTURE_BUDGET, metavar="PX",
                        help="a connected texture with a longer side gets a warning (default %(default)s, "
                             "the largest size Roblox documents for PBR maps)")
    parser.add_argument("--scale", type=float, default=1.0,
                        help="studs per Blender unit, the FBX export scale (default %(default)s)")
    parser.add_argument("--require-names", metavar="REGEX",
                        help="at least --require-count checked objects must match REGEX "
                             "(e.g. '^Wheel_(FL|FR|RL|RR)$' with --require-count 4)")
    parser.add_argument("--require-count", type=int, default=1, metavar="N",
                        help="how many objects --require-names must match (default %(default)s)")


def run_check(args, use_modifiers):
    """check() with parsed options (shared with export_fbx.py)."""
    scope = "selected" if args.selected else ("all" if args.all else None)
    return check(names=split_names(args.objects), scope=scope, max_tris=args.max_tris,
                 max_texture=args.max_texture, texture_budget=args.texture_budget,
                 use_modifiers=use_modifiers, scale=args.scale,
                 require_names=args.require_names, require_count=args.require_count)


def write_report(report, args):
    if args.report:
        with open(args.report, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
            f.write("\n")
    if args.json:
        print(json.dumps(report, separators=(",", ":")))


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(script_args(argv))
    try:
        import bpy  # noqa: F401  # pylint: disable=import-outside-toplevel,unused-import
    except ImportError:
        print("check_mesh.py: run it inside Blender, e.g. run_blender.sh --blend FILE check_mesh.py", file=sys.stderr)
        return 2
    try:
        report = run_check(args, use_modifiers=not args.no_modifiers)
    except UsageError as ex:
        print("check_mesh.py: error: %s" % ex, file=sys.stderr)
        return 2
    write_report(report, args)
    if not args.json:
        print(format_table(report))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
