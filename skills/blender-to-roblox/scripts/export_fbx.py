"""Export mesh objects to FBX with the settings Roblox documents for Blender, after checking them.

Runs inside Blender's Python (needs bpy):

    run_blender.sh --blend car.blend export_fbx.py -- --out build/car.fbx --objects Body
    run_blender.sh --blend car.blend export_fbx.py -- --out build/wheels --per-object \\
        --objects Wheel_FL,Wheel_FR,Wheel_RL,Wheel_RR

or from code already running in Blender (execute_blender_code):

    import sys; sys.path.insert(0, "<skill dir>/scripts")
    import export_fbx
    result = export_fbx.export("/abs/path/car.fbx", names=["Body"])

The objects are checked first with check_mesh.py's rules; violations stop the export unless
--force. Only MESH objects are exported (convert curves, text and metaballs first). Nothing in the
scene changes: hidden or unselectable objects are shown and unlocked only while the exporter runs
(it skips them otherwise), the selection is restored afterwards, and modifiers are only applied to
the exported copy. Objects in a collection excluded from the view layer cannot be exported (exit 2).
Exit codes: 0 exported, 1 violations or export failure, 2 usage error.

Export settings (https://create.roblox.com/docs/art/modeling/export-requirements and
https://create.roblox.com/docs/art/blender, see references/export-rules.md): Path Mode Copy with
embedded textures, Apply Scalings "FBX Unit Scale" with every other scale at 1.0, Forward Z,
Up Y, no leaf bones, no baked animation, selected objects only.
"""

from __future__ import annotations

import argparse
import contextlib
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_mesh  # noqa: E402  # pylint: disable=wrong-import-position

ROBLOX_FBX_SETTINGS = {
    "use_selection": True,
    "apply_unit_scale": True,
    "apply_scale_options": "FBX_SCALE_UNITS",
    "axis_forward": "Z",
    "axis_up": "Y",
    "path_mode": "COPY",
    "embed_textures": True,
    "add_leaf_bones": False,
    "bake_anim": False,
}


def fbx_settings(apply_modifiers=False, triangulate=False, with_armature=False, scale=1.0):
    """Keyword arguments for bpy.ops.export_scene.fbx (without filepath)."""
    return dict(
        ROBLOX_FBX_SETTINGS,
        global_scale=scale,
        object_types={"MESH", "ARMATURE"} if with_armature else {"MESH"},
        use_mesh_modifiers=apply_modifiers,
        use_triangles=triangulate,
    )


def _file_name(name):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", name) + ".fbx"


def plan_outputs(out, objects, per_object):
    """[(path, [objects])] for the requested layout."""
    out = os.path.abspath(out)
    if per_object:
        if out.lower().endswith(".fbx"):
            raise check_mesh.UsageError("with --per-object, --out is a directory, not %s" % out)
        plan = [(os.path.join(out, _file_name(o.name)), [o]) for o in objects]
        paths = [p for p, _ in plan]
        clashes = sorted({p for p in paths if paths.count(p) > 1})
        if clashes:
            raise check_mesh.UsageError("object names map to the same file: %s" % ", ".join(clashes))
        return plan
    if not out.lower().endswith(".fbx"):
        raise check_mesh.UsageError("--out must end in .fbx (or pass --per-object for a directory)")
    return [(out, list(objects))]


def _armatures_for(objects):
    import bpy

    found = []
    for obj in objects:
        candidates = [obj.parent] + [m.object for m in obj.modifiers if m.type == "ARMATURE"]
        for arm in candidates:
            if arm is not None and arm.type == "ARMATURE" and arm not in found:
                found.append(arm)
    return [a for a in found if a.name in bpy.context.view_layer.objects]


def _require_view_layer(objects):
    import bpy

    outside = [o.name for o in objects if o.name not in bpy.context.view_layer.objects]
    if outside:
        raise check_mesh.UsageError(
            "%s %s not in the view layer (an excluded collection); tick the collection in the Outliner "
            "and run again" % (", ".join(outside), "is" if len(outside) == 1 else "are"))


@contextlib.contextmanager
def _selection(objects):
    """Select exactly OBJECTS (active: the first) for the FBX exporter, which exports
    context.selected_objects: hidden or unselectable objects are never in that list, so they are
    shown and unlocked for the duration. Visibility, selectability and the previous selection
    are restored afterwards."""
    import bpy

    view_layer = bpy.context.view_layer
    before = [o for o in view_layer.objects if o.select_get()]
    active = view_layer.objects.active
    flags = [(o, o.hide_get(), o.hide_viewport, o.hide_select) for o in objects]
    try:
        for obj in before:
            obj.select_set(False)
        for obj, hidden, hidden_viewport, unselectable in flags:
            # Only touch flags that are set, so a visible scene is not marked as modified.
            if hidden_viewport:
                obj.hide_viewport = False
            if hidden:
                obj.hide_set(False)
            if unselectable:
                obj.hide_select = False
            obj.select_set(True)
        view_layer.objects.active = objects[0]
        selected = set(o.name for o in bpy.context.selected_objects)
        missing = [o.name for o in objects if o.name not in selected]
        if missing:
            raise check_mesh.UsageError(
                "%s could not be selected for the export (in a hidden or unselectable collection?); "
                "show the collection and run again" % ", ".join(missing))
        yield
    finally:
        for obj in view_layer.objects:
            obj.select_set(obj in before)
        for obj, hidden, hidden_viewport, unselectable in flags:
            if hidden_viewport:
                obj.hide_viewport = True
            if hidden:
                obj.hide_set(True)
            if unselectable:
                obj.hide_select = True
        view_layer.objects.active = active


def export(out, names=None, scope=None, apply_modifiers=False, triangulate=False, per_object=False,
           with_armature=False, scale=1.0, max_tris=check_mesh.DEFAULT_MAX_TRIS,
           max_texture=check_mesh.DEFAULT_MAX_TEXTURE, texture_budget=check_mesh.DEFAULT_TEXTURE_BUDGET,
           require_names=None, require_count=1, force=False, dry_run=False):
    """Check, then export. Returns a JSON-serialisable dict; raises check_mesh.UsageError."""
    import bpy

    report = check_mesh.check(names=names, scope=scope, max_tris=max_tris, max_texture=max_texture,
                              texture_budget=texture_budget, use_modifiers=apply_modifiers, scale=scale,
                              require_names=require_names, require_count=require_count)
    objects, _ = check_mesh.resolve_objects([o["name"] for o in report["objects"]])
    _require_view_layer(objects)
    plan = plan_outputs(out, objects, per_object)
    settings = fbx_settings(apply_modifiers, triangulate, with_armature, scale)
    result = {
        "tool": "export_fbx",
        "check": report,
        "settings": dict(settings, object_types=sorted(settings["object_types"])),
        "planned": [{"path": p, "objects": [o.name for o in objs]} for p, objs in plan],
        "exported": [],
        "refused": False,
        "dry_run": dry_run,
    }
    if report["violations"] and not force:
        result["refused"] = True
        return result
    if dry_run:
        return result

    for path, objs in plan:
        targets = objs + (_armatures_for(objs) if with_armature else [])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # The FBX exporter prints progress on stdout; keep stdout for this script's own output.
        with _selection(targets), contextlib.redirect_stdout(sys.stderr):
            outcome = bpy.ops.export_scene.fbx(filepath=path, **settings)
        if "FINISHED" not in outcome or not os.path.isfile(path):
            raise RuntimeError("FBX export of %s did not finish (%s)" % (path, ", ".join(sorted(outcome))))
        result["exported"].append({"path": path, "objects": [o.name for o in targets], "bytes": os.path.getsize(path)})
    return result


def format_summary(result):
    lines = [check_mesh.format_table(result["check"]), ""]
    if result["refused"]:
        lines.append("refusing to export: %d violation(s). Fix them, or pass --force to export anyway."
                     % len(result["check"]["violations"]))
    elif result["dry_run"]:
        for item in result["planned"]:
            lines.append("would export %s -> %s" % (", ".join(item["objects"]), item["path"]))
    else:
        if result["check"]["violations"]:
            lines.append("exporting despite %d violation(s) (--force)" % len(result["check"]["violations"]))
        for item in result["exported"]:
            lines.append("exported %s -> %s (%d bytes)" % (", ".join(item["objects"]), item["path"], item["bytes"]))
    return "\n".join(lines)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="export_fbx.py",
        description="Check mesh objects against Roblox's limits, then export them to FBX with "
                    "Roblox's documented Blender settings (run inside Blender, for example with "
                    "run_blender.sh). Exit 0 exported, 1 violations or failure, 2 usage error.")
    parser.add_argument("--out", required=True, metavar="PATH",
                        help="the .fbx file to write, or a directory with --per-object")
    check_mesh.add_check_arguments(parser)
    parser.add_argument("--apply-modifiers", action="store_true",
                        help="export the meshes with their modifiers applied (the scene keeps them)")
    parser.add_argument("--triangulate", action="store_true", help="write triangles instead of quads/n-gons")
    parser.add_argument("--per-object", action="store_true",
                        help="one FBX per object in the --out directory, named after the object (e.g. wheels)")
    parser.add_argument("--with-armature", action="store_true",
                        help="also export the armatures the meshes are parented or deformed by")
    parser.add_argument("--force", action="store_true", help="export even when the check finds violations")
    parser.add_argument("--dry-run", action="store_true", help="check and print the plan without writing files")
    parser.add_argument("--json", action="store_true", help="print the result as one line of JSON")
    parser.add_argument("--report", metavar="FILE", help="also write the JSON result to FILE")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(check_mesh.script_args(argv))
    try:
        import bpy  # noqa: F401  # pylint: disable=import-outside-toplevel,unused-import
    except ImportError:
        print("export_fbx.py: run it inside Blender, e.g. run_blender.sh --blend FILE export_fbx.py -- --out X.fbx",
              file=sys.stderr)
        return 2
    scope = "selected" if args.selected else ("all" if args.all else None)
    try:
        result = export(args.out, names=check_mesh.split_names(args.objects), scope=scope,
                        apply_modifiers=args.apply_modifiers, triangulate=args.triangulate,
                        per_object=args.per_object, with_armature=args.with_armature, scale=args.scale,
                        max_tris=args.max_tris, max_texture=args.max_texture,
                        texture_budget=args.texture_budget,
                        require_names=args.require_names, require_count=args.require_count,
                        force=args.force, dry_run=args.dry_run)
    except check_mesh.UsageError as ex:
        print("export_fbx.py: error: %s" % ex, file=sys.stderr)
        return 2
    except RuntimeError as ex:
        print("export_fbx.py: error: %s" % ex, file=sys.stderr)
        return 1
    check_mesh.write_report(result, args)
    if not args.json:
        print(format_summary(result))
    return 1 if result["refused"] else 0


if __name__ == "__main__":
    sys.exit(main())
