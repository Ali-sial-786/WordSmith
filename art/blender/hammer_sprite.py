"""The Hammer Strike hint's hammer, as a sprite the app swings onto a cell.

The icon's hammer seen from the side, striking face to the left and handle
down, lit by forge light. Transparent background. Besides the render it
writes where the striking face's centre and the handle's end land in the
image (0–1, from the top left), which the app needs to swing it.

    blender -b --factory-startup -P hammer_sprite.py -- [--samples 128] [--res 768]

post.py hammer crops it and writes app/assets/images/hammer_strike.png.
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402
from bpy_extras.object_utils import world_to_camera_view  # noqa: E402
from mathutils import Vector  # noqa: E402

import common as C  # noqa: E402
import props as P  # noqa: E402

RES = C.arg("res", 768)
SAMPLES = C.arg("samples", 128)

HEAD_LEN = 1.05
HANDLE_LEN = 1.75


def build():
    head = P.iron_material("HammerIron", base="#7C7F85", rough=(0.22, 0.4), bump=0.08, facet_scale=6.0)
    wood = P.wood_material("Handle", value=1.1, scale=2.0, tint="#C08050")
    ham = P.hammer("Hammer", head, wood, head_len=HEAD_LEN, head_w=0.52, handle_len=HANDLE_LEN,
                   pein_axis="none", handle_r=0.1)
    # A little turned and tipped towards the camera, so the head reads as a
    # block, not a flat shape.
    ham.rotation_euler = (math.radians(-14), 0, math.radians(-24))
    bpy.context.view_layer.update()
    return ham


def lights():
    C.world_color(C.hex_lin("#120C09"), 0.6)
    # warm key, front-left high
    C.area_light("Key", (-4.0, -5.0, 4.5), (0.4, 0, -0.4), 480, size=3.0, color=(1.0, 0.86, 0.74))
    # orange forge rims from behind
    C.area_light("RimL", (-4.0, 4.5, 2.5), (0.4, 0, -0.4), 700, size=2.5, color=(1.0, 0.55, 0.3))
    C.area_light("RimR", (4.5, 4.0, 3.0), (0.4, 0, -0.4), 800, size=2.5, color=(1.0, 0.55, 0.22))
    # cool fill from the right-front, for a steel sheen
    C.area_light("Fill", (5.0, -4.0, 0.5), (0.4, 0, -0.4), 220, size=4.0, color=(0.6, 0.7, 0.95))
    # glow from below, as off hot metal on the anvil
    C.point_light("Glow", (-0.6, -0.8, -1.4), 160, radius=0.5, color=(1.0, 0.5, 0.18))


def main():
    C.reset()
    C.setup_cycles((RES, RES), samples=SAMPLES, transparent=True, view="Standard")
    ham = build()
    lights()
    cam = C.ortho_camera(3.0, loc=(0.4, -10, -0.55), rot=(math.radians(90), 0, 0))
    sc = bpy.context.scene
    bpy.context.view_layer.update()
    mw = ham.matrix_world
    face = mw @ Vector((0, 0, 0))
    grip = mw @ Vector((HEAD_LEN * 0.42, 0, -HANDLE_LEN + 0.12))
    out = {}
    for name, p in (("face", face), ("grip", grip)):
        v = world_to_camera_view(sc, cam, p)
        out[name] = [round(v.x, 4), round(1 - v.y, 4)]
    path = C.render("hammer_strike")
    with open(os.path.join(C.RAW, "hammer_strike.json"), "w") as f:
        json.dump(out, f)
    print("[hammer]", path, out, flush=True)


main()
