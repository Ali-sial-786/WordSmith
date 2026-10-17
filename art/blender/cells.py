"""Mold cells: cell_empty (recessed slot in dark casting sand) and cell_metal
(bevelled plate, neutral light grey for tinting by multiply).

Both are heightfield meshes built from the same rounded-square signed
distance function, rendered top-down orthographic with the same camera, so
their footprints match exactly (post.py also applies one shared SDF mask).

    blender -b --factory-startup -P cells.py -- [--samples 128] [--res 512]
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402
import common as C  # noqa: E402

RES = C.arg("res", 512)
SAMPLES = C.arg("samples", 128)
ONLY = C.arg("only", "")
GRID = C.arg("grid", 320)

# The cell is the square [-0.5, 0.5]^2; it fills FOOT_PX of the 128 canvas.
FOOT_PX = 124.0
ORTHO = 128.0 / FOOT_PX
HALF = 0.5
CORNER = 0.13          # corner radius (keep in sync with post.py)


def sdf(x, y):
    """Signed distance to the rounded square (negative inside)."""
    qx = abs(x) - (HALF - CORNER)
    qy = abs(y) - (HALF - CORNER)
    ox, oy = max(qx, 0.0), max(qy, 0.0)
    return math.hypot(ox, oy) + min(max(qx, qy), 0.0) - CORNER


def smoothstep(e0, e1, v):
    t = min(max((v - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def heightfield(name, fn, extent=0.56):
    n = GRID
    verts, faces = [], []
    for j in range(n + 1):
        y = -extent + 2 * extent * j / n
        for i in range(n + 1):
            x = -extent + 2 * extent * i / n
            verts.append((x, y, fn(x, y)))
    for j in range(n):
        for i in range(n):
            a = j * (n + 1) + i
            faces.append((a, a + 1, a + n + 2, a + n + 1))
    return C.mesh_object(name, verts, faces, smooth=True)


# slot: thin flat lip at the very edge, sloped (drafted) walls, sandy floor
DEPTH = 0.075
LIP = 0.018
WALL = 0.10


def slot_height(x, y):
    d = -sdf(x, y)                  # distance inside the edge
    if d <= LIP:
        return 0.0
    return -DEPTH * smoothstep(LIP, LIP + WALL, d) ** 0.85


PLATE_H = 0.06
BEVEL = 0.075


def plate_height(x, y):
    d = -sdf(x, y)
    if d <= 0:
        return 0.0
    t = min(d / BEVEL, 1.0)
    # quarter-round bevel
    return PLATE_H * math.sqrt(max(0.0, 1 - (1 - t) ** 2)) + 0.004 * smoothstep(0.1, 0.5, d)


# --------------------------------------------------------------------------
def sand_material():
    t = C.tex_set("Ground054")
    m = C.new_material("CastingSand")
    n = C.NT(m)
    tc = n.texcoord()
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (2.2, 2.2, 2.2)
    mp.inputs["Location"].default_value = (0.31, 0.17, 0)
    n.link(tc.outputs["Object"], mp.inputs[0])
    col = n.image(t["Color"], mp.outputs[0]).outputs[0]
    # dark, slightly warm moulding sand (palette "Ash" #3A2F28 territory)
    hsv = n.node("ShaderNodeHueSaturation")
    n.set(hsv, "Color", col)
    hsv.inputs["Saturation"].default_value = 0.45
    hsv.inputs["Value"].default_value = 0.42
    tint = n.mix(hsv.outputs[0], C.hex_lin("#3A2F28"), 0.55)
    # floor of the slot slightly darker / sootier than the walls and lip
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Object"], sep.inputs[0])
    deep = n.maprange(sep.outputs[2], -DEPTH, -0.01, 1.0, 0.0)
    tint = n.mix(tint, C.hex_lin("#1E1814"), n.math("MULTIPLY", deep, 0.45))
    p = n.node("ShaderNodeBsdfPrincipled")
    n.link(tint, p.inputs["Base Color"])
    r = n.image(t["Roughness"], mp.outputs[0], "Non-Color").outputs[0]
    n.link(n.maprange(r, 0, 1, 0.8, 1.0), p.inputs["Roughness"])
    nm = n.node("ShaderNodeNormalMap")
    nm.inputs["Strength"].default_value = 0.9
    n.link(n.image(t["NormalGL"], mp.outputs[0], "Non-Color").outputs[0],
           nm.inputs["Color"])
    # extra fine grain
    grain = n.node("ShaderNodeTexNoise")
    grain.inputs["Scale"].default_value = 160.0
    grain.inputs["Detail"].default_value = 2.0
    n.link(tc.outputs["Object"], grain.inputs["Vector"])
    bump = n.node("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.25
    bump.inputs["Distance"].default_value = 0.002
    n.link(grain.outputs[0], bump.inputs["Height"])
    n.link(nm.outputs[0], bump.inputs["Normal"])
    n.link(bump.outputs[0], p.inputs["Normal"])
    n.output(p.outputs[0])
    return m


def plate_material():
    m = C.new_material("GreyPlate")
    n = C.NT(m)
    tc = n.texcoord()
    t = C.tex_set("Metal052C")
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (0.8, 0.8, 0.8)
    n.link(tc.outputs["Object"], mp.inputs[0])
    rough_img = n.image(t["Roughness"], mp.outputs[0], "Non-Color").outputs[0]
    # very soft hammer facets
    vor = n.node("ShaderNodeTexVoronoi", _feature="SMOOTH_F1")
    vor.inputs["Scale"].default_value = 5.0
    vor.inputs["Smoothness"].default_value = 0.8
    n.link(tc.outputs["Object"], vor.inputs["Vector"])
    bump = n.node("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.05
    bump.inputs["Distance"].default_value = 0.02
    n.link(vor.outputs["Distance"], bump.inputs["Height"])
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = C.hex_lin("#D6D6D6")
    p.inputs["Metallic"].default_value = 0.0
    p.inputs["Specular IOR Level"].default_value = 0.6
    n.link(n.maprange(rough_img, 0, 1, 0.35, 0.5), p.inputs["Roughness"])
    p.inputs["Coat Weight"].default_value = 0.0
    n.link(bump.outputs[0], p.inputs["Normal"])
    n.output(p.outputs[0])
    return m


def lights(kind):
    for ob in [o for o in bpy.data.objects if o.type == "LIGHT"]:
        bpy.data.objects.remove(ob)
    if kind == "empty":
        C.world_color(C.hex_lin("#120D0A"), 1.0)
        C.area_light("Key", (-2.2, 2.6, 2.4), (0, 0, 0), 60, size=1.2,
                     color=(1.0, 0.78, 0.58))
        C.area_light("Fill", (0, 0, 6), (0, 0, 0), 12, size=6, color=(0.9, 0.9, 1.0))
    else:
        C.world_color((0.18, 0.18, 0.18, 1), 1.0)
        C.area_light("Key", (-2.2, 2.6, 2.6), (0, 0, 0), 70, size=2.0)
        C.area_light("Fill", (0, 0, 6), (0, 0, 0), 55, size=6)


def main():
    C.reset()
    C.setup_cycles((RES, RES), samples=SAMPLES, transparent=True,
                   view="Standard", bounces=4)
    C.ortho_camera(ORTHO, loc=(0, 0, 5))
    if not ONLY or "empty" in ONLY:
        slot = heightfield("Slot", slot_height)
        C.assign(slot, sand_material())
        lights("empty")
        C.render("cell_empty", "cells")
        bpy.data.objects.remove(slot)
    if not ONLY or "metal" in ONLY:
        plate = heightfield("Plate", plate_height)
        C.assign(plate, plate_material())
        lights("metal")
        C.render("cell_metal", "cells")


if __name__ == "__main__":
    main()
