"""bg_steel: an early industrial steelworks at dusk (Steel chapter).

A cleaner, cooler workshop than the earlier chapters: brick walls with
riveted steel wainscot, a concrete floor and tall multi-pane steel windows
letting in a cold blue dusk light.
The warm focal point (~48-60 % down the frame) is a crucible hanging from
chains, tipping a white-hot stream of steel into a row of ingot moulds.
A brick cupola furnace glows on the left; heat-blued bars and blades hang
on a rack on the right; a polished steel anvil stands in the foreground.

Top ~45 % (windows' upper panes, roof truss, chains) and the bottom (floor)
stay calm and dark.

    blender -b --factory-startup -P scene_steel.py -- [--samples 64] [--scale 0.667]
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import common as C  # noqa: E402
import forge_kit as K  # noqa: E402
import props as P  # noqa: E402

SAMPLES = C.arg("samples", 64)
SCALE = C.arg("scale", 0.667)
NAME = "bg_steel"

W_HALF, BACK, FRONT, HEIGHT = 3.2, 4.4, -6.0, 6.0
WIN = [(-1.25, 0.95), (1.25, 0.95)]          # (centre x, width) of the two windows
WIN_Z0, WIN_Z1 = 1.35, 3.7


def materials():
    return dict(
        brick=K.tex_material("Brick", "Bricks094", scale=0.9, value=0.3, sat=0.35,
                             tint="#8A96A8", tint_fac=0.45, rough=(0.7, 1.0), soot=0.6,
                             soot_range=(3.5, 6.0)),
        plates=K.tex_material("Plates", "MetalPlates006", scale=0.8, value=0.35, sat=0.5,
                              rough=(0.35, 0.7), normal=0.8),
        floor=K.tex_material("Floor", "Concrete031", scale=0.35, value=0.26, sat=0.3,
                             rough=(0.45, 0.9), normal=0.6),
        furnace=K.tex_material("Furnace", "Bricks094", scale=1.4, value=0.42, sat=0.8,
                               rough=(0.7, 1.0), soot=0.7, soot_range=(1.5, 4.0)),
        steel=K.metal_material("Steel", "#9AA6B2", rough=(0.18, 0.32), bump=0.04),
        cast=P.iron_material("CastIron", base="#3E4248", rough=(0.4, 0.65), bump=0.15),
        blued=K.blued_steel_material("Blued"),
        frame=K.flat_material("WinFrame", "#15181C", rough=0.5, metallic=0.8),
        sky=K.flat_material("DuskSky", "#000000", emission=(C.hex_lin("#34507E"), 0.55)),
        molten=K.glow_material("MoltenSteel", "#FF8A24", 16.0),
        ingot_hot=K.glow_material("IngotHot", "#FF5A14", 6.0),
        ingot_warm=K.glow_material("IngotWarm", "#8A1E08", 2.5),
        wood=P.wood_material("Wood", value=0.45, scale=1.2),
    )


def window(cx, w, M):
    """Steel-framed industrial window: emissive dusk 'sky' behind a grid of panes."""
    h = WIN_Z1 - WIN_Z0
    sky = K.plane(f"Sky{cx}", (cx, BACK + 0.6, (WIN_Z0 + WIN_Z1) / 2), (w + 0.4, h + 0.4), rot=(90, 0, 0),
                  mat=M["sky"])
    sky.visible_shadow = False            # let the low sun through, for the shafts
    t = 0.035
    K.box(f"WinFrameL{cx}", (cx - w / 2, BACK + 0.12, (WIN_Z0 + WIN_Z1) / 2), (0.07, 0.1, h), M["frame"], 0.005)
    K.box(f"WinFrameR{cx}", (cx + w / 2, BACK + 0.12, (WIN_Z0 + WIN_Z1) / 2), (0.07, 0.1, h), M["frame"], 0.005)
    for i in range(1, 4):
        x = cx - w / 2 + w * i / 4
        K.box(f"WinV{cx}_{i}", (x, BACK + 0.12, (WIN_Z0 + WIN_Z1) / 2), (t, 0.05, h), M["frame"], 0)
    for i in range(0, 9):
        z = WIN_Z0 + h * i / 8
        K.box(f"WinH{cx}_{i}", (cx, BACK + 0.12, z), (w, 0.05, t if 0 < i < 8 else 0.07), M["frame"], 0)
    # a couple of panes propped open (tilted), catching the light
    for k, z in enumerate((WIN_Z0 + h * 2.5 / 8,)):
        pane = K.box(f"WinOpen{cx}_{k}", (cx - w / 8, BACK + 0.04, z), (w / 4 - 0.04, 0.02, h / 8 - 0.04),
                     M["frame"], 0)
        pane.rotation_euler = (math.radians(-25), 0, 0)


def build(M):
    # shell: concrete floor, brick walls with steel wainscot, windows ---------
    K.plane("Floor", (0, (BACK + FRONT) / 2, 0), (2 * W_HALF, BACK - FRONT), mat=M["floor"])
    K.box("FrontWall", (0, FRONT - 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT), M["brick"], 0)
    for sx in (-1, 1):
        K.box(f"SideWall{sx}", (sx * (W_HALF + 0.15), (BACK + FRONT) / 2, HEIGHT / 2),
              (0.3, BACK - FRONT, HEIGHT), M["brick"], 0)
    # back wall pieces around the two window openings
    T, yb = 0.3, BACK + 0.15
    xs = [-W_HALF - 0.3] + [v for cx, w in WIN for v in (cx - w / 2, cx + w / 2)] + [W_HALF + 0.3]
    for i in range(0, len(xs), 2):
        a, b = xs[i], xs[i + 1]
        K.box(f"BackPier{i}", ((a + b) / 2, yb, HEIGHT / 2), (b - a, T, HEIGHT), M["brick"], 0)
    for cx, w in WIN:
        K.box(f"Sill{cx}", (cx, yb, WIN_Z0 / 2), (w, T, WIN_Z0), M["brick"], 0)
        K.box(f"Head{cx}", (cx, yb, (WIN_Z1 + HEIGHT) / 2), (w, T, HEIGHT - WIN_Z1), M["brick"], 0)
        K.box(f"SillStone{cx}", (cx, BACK - 0.02, WIN_Z0 - 0.04), (w + 0.2, 0.18, 0.08), M["cast"], 0.01)
        window(cx, w, M)
    K.box("Wainscot", (0, BACK - 0.03, 0.55), (2 * W_HALF, 0.04, 1.1), M["plates"], 0)
    K.box("Ceiling", (0, (BACK + FRONT) / 2, HEIGHT + 0.1), (2 * W_HALF + 0.6, BACK - FRONT, 0.2),
          M["brick"], 0)
    # steel roof truss / hoist beam
    for i, y in enumerate((2.2, -0.2)):
        K.box(f"Girder{i}", (0, y, 4.6), (2 * W_HALF, 0.22, 0.34), M["cast"], 0.01)
    K.box("HoistBeam", (0.2, 1.0, 4.35), (0.2, 4.0, 0.26), M["cast"], 0.01)

    # the pour: crucible on chains tipping into ingot moulds -------------------
    PX, PY = 0.18, 2.0
    cr = K.turned("Crucible", "crucible", (0, 0, 0), 0.5, M["cast"], segments=48)
    cr.location = (PX + 0.2, PY, 1.42)
    cr.rotation_euler = (0, math.radians(-55), 0)
    melt = K.turned("Melt", [(0.0, 0.0), (0.19, 0.0), (0.0, 0.004)], (0, 0, 0.3), 1.0, M["molten"],
                    segments=32)
    melt.parent = cr
    for sy in (-1, 1):                    # bail + chains up to the hoist
        K.chain(f"PourChain{sy}", (PX + 0.2, PY + sy * 0.26, 1.75), (PX + 0.2, 1.0 + sy * 0.05, 4.25),
                M["cast"], link=0.12, thick=0.016)
    K.box("Bail", (PX + 0.2, PY, 1.72), (0.04, 0.56, 0.04), M["cast"], 0.005)
    sx0, sz0, sz1 = PX - 0.12, 1.45, 0.86
    K.cylinder("Stream", (sx0, PY, (sz0 + sz1) / 2), 0.022, sz0 - sz1, M["molten"], verts=12)
    # ingot moulds on a cast-iron bench: the first one filling, the rest cooling
    K.box("MouldBench", (PX - 0.2, PY - 0.05, 0.38), (1.6, 0.6, 0.76), M["cast"], 0.02)
    for i in range(5):
        x = sx0 - 0.02 - i * 0.3
        K.box(f"Mould{i}", (x, PY, 0.82), (0.24, 0.4, 0.12), M["cast"], 0.01)
        mat = M["molten"] if i == 0 else (M["ingot_hot"] if i == 1 else
                                          (M["ingot_warm"] if i == 2 else M["steel"]))
        K.box(f"Ingot{i}", (x, PY, 0.875), (0.17, 0.32, 0.02), mat, 0.004)
    C.point_light("PourLight", (sx0, PY - 0.35, 1.05), 70, radius=0.1, color=(1.0, 0.55, 0.2))
    K.flame_volume((sx0, PY - 0.05, 1.05), size=(0.35, 0.3, 0.35), strength=1.6, name="PourGlow")
    C.point_light("PourLight2", (sx0 + 0.1, PY - 0.2, 1.5), 12, radius=0.1, color=(1.0, 0.7, 0.35))
    P.sparks((sx0, PY - 0.02, 0.9), count=26, seed=5, direction=(0, -0.4, 1), spread=80,
             length=(0.05, 0.16), dist=(0.08, 0.6), radius=0.005, gravity=0.6)

    # cupola furnace, left back: glowing tap hole + runner ---------------------
    FX, FY, FR = -2.15, 3.3, 0.6
    K.cylinder("Cupola", (FX, FY, HEIGHT / 2), FR, HEIGHT, M["furnace"], verts=48)
    for i, z in enumerate((0.6, 1.6, 2.6, 3.6)):
        bpy.ops.mesh.primitive_torus_add(major_radius=FR + 0.02, minor_radius=0.03, major_segments=64,
                                         minor_segments=8, location=(FX, FY, z))
        C.assign(bpy.context.active_object, M["cast"])
    K.box("TapHole", (FX + 0.12, FY - FR + 0.02, 0.85), (0.24, 0.08, 0.2), M["molten"], 0.02)
    C.point_light("TapLight", (FX + 0.12, FY - FR - 0.25, 0.9), 70, radius=0.12, color=(1.0, 0.5, 0.18))
    K.flame_volume((FX + 0.12, FY - FR - 0.1, 0.9), size=(0.25, 0.2, 0.25), strength=1.5, name="TapGlow")
    K.box("Runner", (FX + 0.3, FY - FR - 0.25, 0.72), (0.14, 0.5, 0.06), M["cast"], 0.01,
          rot=(8, 0, -25))

    # blued steel: rack of bars and two blades on the right ---------------------
    RX = 1.75
    K.box("Rack", (RX, BACK - 0.08, 1.95), (1.0, 0.06, 0.1), M["wood"], 0.01)
    for i in range(7):
        K.box(f"BluedBar{i}", (RX - 0.4 + i * 0.13, BACK - 0.13, 1.35), (0.03, 0.03, 1.15), M["blued"],
              0.004, rot=(0, (i - 3) * 1.2, 0))
    for i, x in enumerate((RX - 0.25, RX + 0.25)):
        K.blade(f"Blade{i}", (x, BACK - 0.2, 2.1), 0.75, 0.08, M["blued"], rot=(90, -90, 0),
                guard=M["steel"], handle=M["wood"])
    # a big flywheel on the right wall, half lost in the dark
    bpy.ops.mesh.primitive_torus_add(major_radius=0.85, minor_radius=0.07, major_segments=96,
                                     minor_segments=10, location=(2.55, BACK - 0.3, 3.0),
                                     rotation=(math.pi / 2, 0, 0))
    C.assign(bpy.context.active_object, M["cast"])
    for k in range(6):
        a = math.pi * k / 3
        K.box(f"Spoke{k}", (2.55 + 0.42 * math.cos(a), BACK - 0.3, 3.0 + 0.42 * math.sin(a)),
              (0.85, 0.06, 0.07), M["cast"], 0.005, rot=(0, -math.degrees(a), 0))

    # foreground: polished steel anvil on a cast stand, chain on the floor -------
    AX, AY = 0.85, 0.3
    K.cylinder("AnvilStand", (AX, AY, 0.25), 0.3, 0.5, M["cast"], verts=32, bevel=0.02)
    anv = P.anvil("Anvil", M["steel"], depth=1.15, location=(AX, AY, 0.5), rot_z=math.radians(-25))
    anv.scale = (0.27, 0.27, 0.27)
    K.chain("FloorChain", (-1.3, 0.2, 0.02), (-0.6, 0.9, 0.02), M["cast"], link=0.12, thick=0.016)

    # light: cool dusk through the windows, faint fills -------------------------
    sun = C.sun_light("Dusk", (0, 0, 0), 6.0, angle=2.0, color=(0.6, 0.72, 1.0))
    sun.rotation_euler = Vector((-0.18, -1.0, -0.45)).to_track_quat("-Z", "Y").to_euler()
    for cx, w in WIN:
        C.area_light(f"WinLight{cx}", (cx, BACK + 0.4, (WIN_Z0 + WIN_Z1) / 2), (cx * 0.6, 0.0, 0.5), 45,
                     size=w, size_y=WIN_Z1 - WIN_Z0, shape="RECTANGLE", color=(0.6, 0.72, 1.0))
    C.area_light("RimAnvil", (0.3, 2.0, 1.5), (AX, AY, 0.85), 18, size=0.8, color=(1.0, 0.55, 0.25))
    C.area_light("RackLight", (0.9, 2.4, 2.6), (RX, BACK - 0.1, 1.7), 22, size=1.0, color=(0.65, 0.75, 1.0))
    C.area_light("CoolFill", (-2.0, -3.0, 3.5), (0, 2, 1), 22, size=3.0, color=(0.5, 0.62, 1.0))

    K.haze((-W_HALF + 0.05, FRONT + 2, 0.05), (W_HALF - 0.05, BACK - 0.05, HEIGHT - 0.1),
           density=0.012, color=(0.92, 0.95, 1.0), anisotropy=0.6)



def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="Filmic",
                        look="High Contrast", exposure=0.0, bounces=5)
    sc.cycles.volume_step_rate = 8.0
    sc.cycles.volume_max_steps = 256
    C.world_color(C.hex_lin("#020306"), 1.0)
    M = materials()
    build(M)
    cam = C.persp_camera((0.1, -2.9, 1.45), (0.0, 2.4, 1.4), lens=26)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 4.9
    cam.data.dof.aperture_fstop = 2.8
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
