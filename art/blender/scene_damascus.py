"""bg_damascus: a desert bladesmith's workshop at sunset (Damascus chapter).

Adobe walls glowing ochre, a pointed Moorish arch in the back wall opening
onto dunes and palms under a hot dusk sky, with the huge low sun sitting on
the horizon (~48-55 % down the frame). Its light rakes in across the room
onto a rack of pattern-welded blades, their wavy damascus bands catching the
glow. A small clay hearth burns on the left, a brass lantern hangs from the
ceiling, and a big damascus blade lies on the anvil in the foreground.

Top ~45 % (upper wall, arch top, ceiling) and the bottom (floor) stay calm.

    blender -b --factory-startup -P scene_damascus.py -- [--samples 64] [--scale 1.0]
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import common as C  # noqa: E402
import forge_kit as K  # noqa: E402
import props as P  # noqa: E402

SAMPLES = C.arg("samples", 64)
SCALE = C.arg("scale", 1.0)           # 1.0 = native 1080x2340 (post.py never upscales)
NAME = "bg_damascus"

W_HALF, BACK, FRONT, HEIGHT = 3.0, 4.2, -6.0, 5.0
AX_, AW, AZ1 = 0.75, 1.7, 2.95          # arch centre x, width, apex height
SUN_DIR = (0.07, 1.0, 0.05)             # where the sun disc sits in the sky


def materials():
    return dict(
        adobe=K.tex_material("Adobe", "Plaster007", scale=0.45, value=0.5, sat=1.0,
                             tint="#C88A52", tint_fac=0.6, rough=(0.8, 1.0), soot=0.5,
                             soot_range=(3.0, 5.0), soot_color="#24140A"),
        floor=K.tex_material("Floor", "Ground080", scale=0.35, value=0.2, sat=0.9,
                             tint="#8A5A36", tint_fac=0.4, rough=(0.8, 1.0), normal=0.6),
        sand=K.tex_material("Dune", "Ground080", scale=0.06, value=0.55, sat=1.1,
                            tint="#D88A48", tint_fac=0.5, rough=(0.8, 1.0), normal=0.5),
        clay=K.tex_material("Clay", "Plaster007", scale=1.0, value=0.4, sat=1.0, tint="#9A5A3A",
                            tint_fac=0.6, rough=(0.8, 1.0), soot=0.7, soot_range=(1.0, 2.4)),
        beam=K.tex_material("Beam", "Planks023A", scale=0.6, value=0.25, sat=0.9, rough=(0.7, 0.95)),
        wood=K.tex_material("RackWood", "Planks023A", scale=1.0, value=0.35, sat=1.0,
                            tint="#7A4A2A", tint_fac=0.4, rough=(0.5, 0.85)),
        damascus=K.damascus_material("Damascus"),
        damascus2=K.damascus_material("Damascus2", scale=11.0, distortion=12.0),
        brass=K.metal_material("Brass", "#C89A4A", rough=(0.25, 0.42), bump=0.05),
        iron=P.iron_material("Iron", base="#5A5C62", rough=(0.3, 0.5), bump=0.12),
        handle=P.wood_material("Handle", value=0.6, scale=3.0, tint="#4A2A18"),
        palm=K.flat_material("Palm", "#120A08", rough=0.9),
        lantern_glow=K.flat_material("LanternGlow", "#000000", emission=(C.hex_lin("#FFB04A"), 5.0)),
        water=K.water_material("Water"),
    )


def arch_wall(M):
    """Back wall with a pointed (two-centred) arch doorway, cut exactly."""
    return K.wall_with_openings("BackWall", (0, BACK + 0.27, HEIGHT / 2), (2 * W_HALF + 0.6, 0.5, HEIGHT + 0.2),
                                [K.arch_outline(AX_, AW, -0.5, 1.75, apex=AZ1)], M["adobe"])


def palm(name, loc, h, M, lean=0.15, seed=1):
    rnd = random.Random(seed)
    x, y, z = loc
    cu = bpy.data.curves.new(name + "Trunk", "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = h * 0.035
    cu.bevel_resolution = 2
    sp = cu.splines.new("BEZIER")
    pts = [(x, y, z), (x + lean * h * 0.3, y, z + h * 0.5), (x + lean * h, y, z + h)]
    sp.bezier_points.add(len(pts) - 1)
    for bp, p in zip(sp.bezier_points, pts):
        bp.co = p
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    tr = bpy.data.objects.new(name + "Trunk", cu)
    C.link(tr)
    tr.data.materials.append(M["palm"])
    top = Vector(pts[-1])
    for k in range(8):
        a = 2 * math.pi * k / 8 + rnd.uniform(-0.2, 0.2)
        bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=h * 0.08, depth=h * 0.55,
                                        location=top + Vector((math.cos(a), math.sin(a), -0.3)) * h * 0.22)
        fr = bpy.context.active_object
        fr.scale = (1.0, 0.18, 1.0)
        fr.rotation_euler = (0, math.radians(100 + rnd.uniform(-15, 15)), a)
        C.assign(fr, M["palm"])


def build(M):
    # shell ------------------------------------------------------------------------
    K.plane("Floor", (0, (BACK + FRONT) / 2, 0), (2 * W_HALF, BACK - FRONT), mat=M["floor"])
    K.box("FrontWall", (0, FRONT - 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT), M["adobe"], 0)
    for sx in (-1, 1):
        K.box(f"SideWall{sx}", (sx * (W_HALF + 0.15), (BACK + FRONT) / 2, HEIGHT / 2),
              (0.3, BACK - FRONT, HEIGHT), M["adobe"], 0)
    K.box("Ceiling", (0, (BACK + FRONT) / 2, HEIGHT + 0.1), (2 * W_HALF + 0.6, BACK - FRONT, 0.2), M["beam"], 0)
    for i, y in enumerate((3.3, 1.5, -0.3)):
        K.cylinder(f"Viga{i}", (0, y, 3.9), 0.12, 2 * W_HALF, M["beam"], verts=12, rot=(0, 90, 0))
    arch_wall(M)
    K.box("Threshold", (AX_, BACK - 0.05, 0.04), (AW + 0.2, 0.55, 0.08), M["clay"], 0.02)

    # outside: dunes and palms against the sunset -------------------------------------
    K.plane("Terrace", (AX_, 12, -0.02), (40, 16), mat=M["sand"])
    for i, (x, y, rx, ry, h) in enumerate(((-10, 40, 30, 10, 3.0), (14, 55, 34, 12, 4.5),
                                           (-2, 75, 40, 14, 6.0), (30, 80, 30, 12, 5.0))):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=1.0, location=(x, y, 0))
        d = bpy.context.active_object
        d.name = f"Dune{i}"
        d.scale = (rx, ry, h)
        C.shade_smooth(d)
        C.assign(d, M["sand"])
    palm("PalmA", (1.0, 15, 0), 3.8, M, lean=0.18, seed=2)
    palm("PalmB", (2.6, 22, 0), 4.6, M, lean=-0.12, seed=5)
    palm("PalmC", (-0.3, 28, 0), 3.4, M, lean=-0.2, seed=9)

    # clay hearth on the left with fire ------------------------------------------------
    HX, HY = -1.35, BACK - 0.75
    K.hearth((HX, HY, 0), w=1.4, d=1.0, h=0.75, brick=M["clay"], hood=M["clay"],
             coal_strength=5.0, light_energy=150, hood_top=2.9, flue_top=HEIGHT)
    K.fire((HX, HY - 0.05, 0.8), spread=(0.36, 0.14), count=8, height=0.75, width=0.15,
           seed=41, strength=5.5, name="HearthFire")
    K.flame_volume((HX, HY - 0.05, 1.1), size=(0.5, 0.3, 0.4), strength=1.2, name="HearthGlow")
    K.box("Fireback", (HX, BACK - 0.12, 1.5), (1.5, 0.1, 1.6), M["clay"], 0.01)

    # free-standing rack of damascus blades, left mid-ground ------------------------------
    RX, RY = -0.75, 1.45
    for sx in (-1, 1):
        K.box(f"RackPost{sx}", (RX + sx * 0.55, RY, 0.75), (0.07, 0.07, 1.5), M["wood"], 0.01)
    K.box("RackTop", (RX, RY, 1.5), (1.25, 0.1, 0.07), M["wood"], 0.01)
    K.box("RackFoot", (RX, RY, 0.05), (1.25, 0.4, 0.1), M["wood"], 0.01)
    for i in range(5):
        x = RX - 0.42 + i * 0.21
        L = 0.72 + 0.08 * math.sin(i * 1.7)
        K.blade(f"RackBlade{i}", (x, RY - 0.07, 0.6), L, 0.07 + 0.01 * (i % 2),
                M["damascus"] if i % 2 else M["damascus2"], rot=(90, -90, 0), curve=0.06 * (i % 3),
                guard=M["brass"], handle=M["handle"], handle_len=0.24)

    # anvil foreground right with a big damascus blade on it ---------------------------
    AX, AY = 0.95, 0.35
    K.stump("Stump", (AX, AY, 0), radius=0.34, height=0.45, mat=M["wood"])
    anv = P.anvil("Anvil", M["iron"], depth=1.15, location=(AX, AY, 0.45), rot_z=math.radians(-15))
    anv.scale = (0.27, 0.27, 0.27)
    K.blade("HeroBlade", (AX - 0.32, AY - 0.02, 0.9), 0.85, 0.11, M["damascus"], rot=(0, 0, 10),
            curve=0.08, guard=M["brass"], handle=M["handle"], handle_len=0.26)
    K.box("QuenchTrough", (-0.35, 0.3, 0.2), (0.9, 0.35, 0.4), M["wood"], 0.02)
    K.box("QuenchOil", (-0.35, 0.3, 0.36), (0.82, 0.27, 0.02), M["water"], 0)

    # brass lantern hanging from the ceiling -------------------------------------------
    LX, LY, LZ = 0.1, 2.2, 2.6
    K.chain("LanternChain", (LX, LY, LZ + 0.32), (LX, LY, 3.8), M["brass"], link=0.08, thick=0.01)
    K.turned("LanternCap", [(0.0, 0.0), (0.13, 0.0), (0.04, 0.18), (0.0, 0.2)], (LX, LY, LZ + 0.14), 1.0,
             M["brass"], segments=8)
    K.cylinder("LanternBody", (LX, LY, LZ), 0.1, 0.28, M["lantern_glow"], verts=8)
    K.turned("LanternBase", [(0.0, 0.0), (0.03, 0.0), (0.12, 0.08), (0.0, 0.1)], (LX, LY, LZ - 0.22), 1.0,
             M["brass"], segments=8)
    C.point_light("LanternLight", (LX, LY - 0.05, LZ), 18, radius=0.08, color=(1.0, 0.6, 0.28))

    # sunset light raking in through the arch ---------------------------------------
    sun = C.sun_light("Sunset", (0, 0, 0), 4.5, angle=3.0, color=(1.0, 0.55, 0.28))
    sun.rotation_euler = Vector((-0.65, -1.0, -0.25)).to_track_quat("-Z", "Y").to_euler()
    C.area_light("ArchSky", (AX_, BACK + 0.8, 1.5), (AX_ - 0.3, 0.0, 0.8), 30, size=AW, size_y=2.8,
                 shape="RECTANGLE", color=(1.0, 0.55, 0.35))
    C.area_light("RimBlade", (0.2, 2.2, 1.6), (AX, AY, 0.95), 35, size=0.6, color=(1.0, 0.6, 0.35))
    C.area_light("BladeKey", (-0.55, 0.3, 1.3), (RX, RY, 1.0), 14, size=0.9, color=(1.0, 0.72, 0.5),
                 spread=60)
    C.area_light("HeroKey", (0.7, -0.2, 2.0), (AX - 0.1, AY, 0.9), 12, size=0.7, color=(1.0, 0.72, 0.5),
                 spread=60)
    C.area_light("DuskFill", (-2.0, -3.0, 3.5), (0, 2, 1), 3, size=3.0, color=(0.7, 0.5, 0.8))
    K.haze((-W_HALF + 0.05, FRONT + 2, 0.05), (W_HALF - 0.05, BACK - 0.5, HEIGHT - 0.1),
           density=0.008, color=(1.0, 0.85, 0.7), anisotropy=0.6)


def sunset_world():
    """Hot dusk: violet zenith -> rose -> orange -> gold horizon, with a huge
    low sun disc and its glow."""
    w = bpy.context.scene.world
    n = C.NT(w)
    tc = n.node("ShaderNodeTexCoord")
    norm = n.node("ShaderNodeVectorMath", _operation="NORMALIZE")
    n.link(tc.outputs["Generated"], norm.inputs[0])
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(norm.outputs[0], sep.inputs[0])
    col = n.ramp(sep.outputs[2], [(0.0, C.hex_lin("#FF9A44")), (0.03, C.hex_lin("#F06A3A")),
                                  (0.09, C.hex_lin("#B0405A")), (0.22, C.hex_lin("#4E2458")),
                                  (0.6, C.hex_lin("#160E28"))])
    sd = Vector(SUN_DIR).normalized()
    dot = n.node("ShaderNodeVectorMath", _operation="DOT_PRODUCT")
    n.link(norm.outputs[0], dot.inputs[0])
    dot.inputs[1].default_value = tuple(sd)
    glow = n.math("POWER", n.maprange(dot.outputs["Value"], 0.7, 1.0, 0.0, 1.0), 4.0)
    col = n.mix(col, C.hex_lin("#FFB060"), n.math("MULTIPLY", glow, 1.2), blend="ADD")
    c = math.cos(math.radians(3.2))
    disc = n.maprange(dot.outputs["Value"], c - 0.00005, c + 0.00005, 0.0, 1.0)
    col = n.mix(col, C.hex_lin("#FFE2A0"), n.math("MULTIPLY", disc, 6.0), blend="ADD")
    bg = n.node("ShaderNodeBackground")
    n.link(col, bg.inputs[0])
    bg.inputs[1].default_value = 0.75
    out = n.node("ShaderNodeOutputWorld")
    n.link(bg.outputs[0], out.inputs[0])


def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="Filmic",
                        look="High Contrast", exposure=0.0, bounces=5)
    sc.cycles.volume_step_rate = 8.0
    sc.cycles.volume_max_steps = 256
    sunset_world()
    M = materials()
    build(M)
    cam = C.persp_camera((0.15, -2.9, 1.45), (0.1, BACK - 1.5, 1.42), lens=26)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 5.6
    cam.data.dof.aperture_fstop = 2.8
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
