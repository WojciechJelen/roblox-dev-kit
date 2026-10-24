"""Render a quick preview image of mesh objects (run inside Blender), for a visual check.

    run_blender.sh --blend car.blend render_preview.py -- --out /tmp/car.png [--objects Body,Wheel_FL]

Uses the Workbench engine (fast, no lighting setup needed) and a temporary camera that frames the
objects from the front-right and above; --scene-camera uses the scene's camera instead. Hidden in
the render: every mesh not being previewed. The temporary camera is removed and the scene camera,
engine, resolution, output path, file format and visibility are set back afterwards; other output
settings (such as colour depth) are left as Blender's render leaves them. A missing .png extension
is added to --out.
In a live Blender the Blender MCP server's render_thumbnail_to_path does a similar job.
Exit codes: 0 rendered, 1 render failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import contextlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_mesh  # noqa: E402  # pylint: disable=wrong-import-position


@contextlib.contextmanager
def _restored(obj, **values):
    """Set attributes on OBJ for the duration of the block."""
    old = {k: getattr(obj, k) for k in values}
    try:
        for k, v in values.items():
            setattr(obj, k, v)
        yield
    finally:
        for k, v in old.items():
            setattr(obj, k, v)


def render(out, names=None, scope=None, size=512, scene_camera=False):
    """Render OUT (a .png path); returns a JSON-serialisable dict."""
    import bpy
    from mathutils import Vector

    objects, chosen = check_mesh.resolve_objects(names, scope)
    scene = bpy.context.scene
    out = os.path.abspath(out)
    if not out.lower().endswith(".png"):
        out += ".png"  # Blender adds the extension itself; keep the path we report and check the same
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if scene_camera and scene.camera is None:
        raise check_mesh.UsageError("the scene has no camera (drop --scene-camera to frame the objects)")

    others = [o for o in scene.objects if o.type == "MESH" and o not in objects and not o.hide_render]
    cam_data = cam_obj = None
    try:
        if not scene_camera:
            cam_data = bpy.data.cameras.new("rdk_preview_camera")
            cam_obj = bpy.data.objects.new("rdk_preview_camera", cam_data)
            scene.collection.objects.link(cam_obj)
            # Look from front-right and above (Blender: -Y is front, +Z is up).
            direction = Vector((1.0, -1.4, 0.9)).normalized()
            cam_obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
            bpy.context.view_layer.update()
            corners = []
            for obj in objects:
                for corner in obj.bound_box:
                    corners.extend(obj.matrix_world @ Vector(corner))
            location, _ = cam_obj.camera_fit_coords(bpy.context.evaluated_depsgraph_get(), corners)
            # Step back 10% so the objects do not touch the frame.
            centre = sum((Vector(corners[i:i + 3]) for i in range(0, len(corners), 3)), Vector()) / (len(corners) / 3)
            cam_obj.location = centre + (Vector(location) - centre) * 1.1
        render_settings = scene.render
        with contextlib.ExitStack() as stack:
            stack.enter_context(_restored(scene, camera=cam_obj or scene.camera))
            stack.enter_context(_restored(render_settings, engine="BLENDER_WORKBENCH", resolution_x=size,
                                          resolution_y=size, resolution_percentage=100, filepath=out))
            stack.enter_context(_restored(render_settings.image_settings, file_format="PNG"))
            for obj in others:
                stack.enter_context(_restored(obj, hide_render=True))
            with contextlib.redirect_stdout(sys.stderr):
                bpy.ops.render.render(write_still=True)
    finally:
        if cam_obj is not None:
            bpy.data.objects.remove(cam_obj)
        if cam_data is not None:
            bpy.data.cameras.remove(cam_data)
    if not os.path.isfile(out):
        raise RuntimeError("Blender did not write %s" % out)
    return {"tool": "render_preview", "path": out, "objects": [o.name for o in objects], "scope": chosen,
            "size": size, "camera": "scene" if scene_camera else "framed"}


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="render_preview.py",
        description="Render a PNG preview of mesh objects with the Workbench engine (run inside Blender, "
                    "for example with run_blender.sh). Exit 0 rendered, 1 failed, 2 usage error.")
    parser.add_argument("--out", required=True, metavar="PNG", help="image file to write (.png is added when missing)")
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--objects", metavar="A,B", help="these mesh objects (default: the selection, else all meshes)")
    scope.add_argument("--selected", action="store_true", help="only the selected mesh objects")
    scope.add_argument("--all", action="store_true", help="every mesh object, ignoring the selection")
    parser.add_argument("--size", type=int, default=512, metavar="PX", help="image width and height (default %(default)s)")
    parser.add_argument("--scene-camera", action="store_true", help="use the scene's camera instead of framing the objects")
    args = parser.parse_args(check_mesh.script_args(argv))
    try:
        import bpy  # noqa: F401  # pylint: disable=import-outside-toplevel,unused-import
    except ImportError:
        print("render_preview.py: run it inside Blender, e.g. run_blender.sh --blend FILE render_preview.py -- --out X.png",
              file=sys.stderr)
        return 2
    if args.size < 16:
        print("render_preview.py: error: --size must be at least 16", file=sys.stderr)
        return 2
    scope_name = "selected" if args.selected else ("all" if args.all else None)
    try:
        result = render(args.out, check_mesh.split_names(args.objects), scope_name, args.size, args.scene_camera)
    except check_mesh.UsageError as ex:
        print("render_preview.py: error: %s" % ex, file=sys.stderr)
        return 2
    except RuntimeError as ex:
        print("render_preview.py: error: %s" % ex, file=sys.stderr)
        return 1
    print("rendered %s (%s)" % (result["path"], ", ".join(result["objects"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
