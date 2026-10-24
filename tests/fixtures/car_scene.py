"""Build a small test car in an empty scene and save it (run inside Blender).

    blender --background --python car_scene.py -- OUT.blend [options]

Body: a 4 x 8 x 2 box (12 triangles). Wheel_FL/FR/RL/RR: 32-sided cylinders lying on their side
(124 triangles each, two 32-gon caps), origins at their centres, transforms applied.
--heavy NAME     add a level-4 Subdivision Surface modifier to NAME (Body: 12 * 256 = 3072 triangles
                 evaluated; a wheel: 124 faces -> well over 20,000 triangles evaluated)
--texture PX     give Body a material with a PX x PX image texture saved next to OUT.blend, wired to
                 Base Color
--stray-texture PX
                 add a PX x PX image node to Body's material that is connected to nothing
                 (a generated image, like a forgotten bake target)
--rotated NAME   leave a 30-degree rotation on NAME unapplied
--hidden NAME    hide NAME in the view layer (the eye icon); --hidden-viewport NAME disables it in
                 viewports (the monitor icon); --unselectable NAME makes it unselectable
--excluded NAME  move NAME into a collection that is excluded from the view layer
--text           add a text object named Logo (not a mesh)
"""

import argparse
import math
import os
import sys

import bpy

args = argparse.ArgumentParser()
args.add_argument("out")
args.add_argument("--heavy")
args.add_argument("--texture", type=int)
args.add_argument("--stray-texture", type=int)
args.add_argument("--rotated")
args.add_argument("--hidden")
args.add_argument("--hidden-viewport")
args.add_argument("--unselectable")
args.add_argument("--excluded")
args.add_argument("--text", action="store_true")
args = args.parse_args(sys.argv[sys.argv.index("--") + 1:])

# An empty factory scene; unlike read_factory_settings this leaves the preferences alone.
bpy.ops.wm.read_homefile(use_empty=True, use_factory_startup=True)

bpy.ops.mesh.primitive_cube_add(size=1)
body = bpy.context.active_object
body.name = body.data.name = "Body"
body.scale = (4, 8, 2)
body.location = (0, 0, 1.5)
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

for name, x, y in (("Wheel_FL", -2.2, 2.5), ("Wheel_FR", 2.2, 2.5), ("Wheel_RL", -2.2, -2.5), ("Wheel_RR", 2.2, -2.5)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=1, depth=0.6, location=(x, y, 1))
    wheel = bpy.context.active_object
    wheel.name = wheel.data.name = name
    wheel.rotation_euler = (0, math.radians(90), 0)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)

if args.heavy:
    mod = bpy.data.objects[args.heavy].modifiers.new("Subdivision", "SUBSURF")
    mod.levels = mod.render_levels = 4

if args.texture or args.stray_texture:
    mat = bpy.data.materials.new("BodyPaint")
    body.data.materials.append(mat)
    tree = mat.node_tree
if args.texture:
    image = bpy.data.images.new("BodyColor", args.texture, args.texture)
    image.filepath_raw = os.path.join(os.path.dirname(os.path.abspath(args.out)), "BodyColor.png")
    image.file_format = "PNG"
    image.save()
    tex = tree.nodes.new("ShaderNodeTexImage")
    tex.image = image
    bsdf = next(n for n in tree.nodes if n.type == "BSDF_PRINCIPLED")
    tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
if args.stray_texture:
    stray = tree.nodes.new("ShaderNodeTexImage")
    stray.image = bpy.data.images.new("BakeTarget", args.stray_texture, args.stray_texture)

if args.rotated:
    bpy.data.objects[args.rotated].rotation_euler[2] = math.radians(30)

if args.text:
    bpy.ops.object.text_add(location=(0, 0, 3))
    bpy.context.active_object.name = "Logo"

for obj in bpy.context.scene.objects:
    obj.select_set(False)
if args.hidden:
    bpy.data.objects[args.hidden].hide_set(True)
if args.hidden_viewport:
    bpy.data.objects[args.hidden_viewport].hide_viewport = True
if args.unselectable:
    bpy.data.objects[args.unselectable].hide_select = True
if args.excluded:
    obj = bpy.data.objects[args.excluded]
    shelf = bpy.data.collections.new("Shelf")
    bpy.context.scene.collection.children.link(shelf)
    for coll in list(obj.users_collection):
        coll.objects.unlink(obj)
    shelf.objects.link(obj)
    bpy.context.view_layer.layer_collection.children["Shelf"].exclude = True
bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.out))
print("built", args.out)
