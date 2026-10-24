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

Limits and their sources are in references/export-rules.md:
20,000 triangles per mesh (https://create.roblox.com/docs/art/modeling/specifications) and
1024x1024 texture maps (https://create.roblox.com/docs/art/modeling/texture-specifications).
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
DEFAULT_MAX_TEXTURE = 1024
EPSILON = 1e-4


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
                raise UsageError("%r is a %s, not a mesh" % (name, obj.type.lower()))
            objects.append(obj)
        return objects, "objects"
    meshes = [o for o in scene.objects if o.type == "MESH"]
    chosen = [] if scope == "all" else [o for o in meshes if o.select_get()]
    if scope == "selected" and not chosen:
        raise UsageError("no mesh objects are selected")
    if chosen:
        return chosen, "selection"
    if not meshes:
        raise UsageError("scene %r has no mesh objects" % scene.name)
    return meshes, "all"


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
        for node in _image_nodes(mat.node_tree):
            image = node.image
            if any(t["image"] == image.name for t in textures):
                continue
            width, height = image.size
            textures.append({"image": image.name, "width": width, "height": height, "material": mat.name})

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
    )


def judge(info, max_tris, max_texture, use_modifiers):
    """(violations, warnings) for one inspected object: lists of {code, message}."""
    violations, warnings = [], []

    def add(target, code, message):
        target.append({"object": info["name"], "code": code, "message": message})

    if info["triangles"] > max_tris:
        add(violations, "tris", "%d triangles, over the %d limit" % (info["triangles"], max_tris))
    for tex in info["textures"]:
        if tex["width"] == 0 or tex["height"] == 0:
            add(warnings, "missing-image", "image %r has no pixels (missing file?)" % tex["image"])
        elif max(tex["width"], tex["height"]) > max_texture:
            add(violations, "texture", "image %r is %dx%d, over %dx%d" % (
                tex["image"], tex["width"], tex["height"], max_texture, max_texture))
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
    if info["modifiers"] and not use_modifiers:
        add(warnings, "modifiers", "%d modifier(s) not included (export with --apply-modifiers)" % len(info["modifiers"]))
    return violations, warnings


def check(names=None, scope=None, max_tris=DEFAULT_MAX_TRIS, max_texture=DEFAULT_MAX_TEXTURE,
          use_modifiers=True, scale=1.0, require_names=None, require_count=1):
    """Check mesh objects and return the report dict. Raises UsageError for bad input."""
    import bpy

    if max_tris < 1 or max_texture < 1 or scale <= 0 or require_count < 1:
        raise UsageError("--max-tris, --max-texture, --scale and --require-count must be positive")
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
        bad, meh = judge(info, max_tris, max_texture, use_modifiers)
        info["violations"] = [v["message"] for v in bad]
        info["warnings"] = [w["message"] for w in meh]
        infos.append(info)
        violations.extend(bad)
        warnings.extend(meh)

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
        "limits": {"max_tris": max_tris, "max_texture": max_texture},
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
    lines.append("check_mesh: %d object(s) (%s) in %s; limits: %d triangles per mesh, %d px textures" % (
        report["summary"]["objects"], report["scope"], report["blend_file"] or "unsaved scene",
        limits["max_tris"], limits["max_texture"]))
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
    for v in report["violations"]:
        if v["object"] is None:
            lines.append("x   violation: %s" % v["message"])
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
                        help="largest allowed texture side in pixels (default %(default)s)")
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
                 max_texture=args.max_texture, use_modifiers=use_modifiers, scale=args.scale,
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
