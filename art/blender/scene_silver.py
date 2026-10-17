"""bg_silver: a silversmith's studio by moonlight (Silver chapter).

A quiet, cool room: pale plaster walls and a marble floor, a tall arched
window on the back wall with a big moon in a deep blue sky. Its light falls
in a silvery shaft across the workbench, where goblets, a jug, plates and
candlesticks gleam (~45-60 % down the frame). Small warm accents keep it in
the same game: a little charcoal brazier glowing on the bench and a candle.
A silversmith's stake anvil and hammers sit in the foreground.

Top ~45 % (upper wall, arch, the moon's sky) and the bottom (floor) stay calm.

    blender -b --factory-startup -P scene_silver.py -- [--samples 64] [--scale 0.667]
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402
import bmesh  # noqa: E402
from mathutils import Vector  # noqa: E402

import common as C  # noqa: E402
import forge_kit as K  # noqa: E402
import props as P  # noqa: E402

SAMPLES = C.arg("samples", 64)
SCALE = C.arg("scale", 0.667)
NAME = "bg_silver"

W_HALF, BACK, FRONT, HEIGHT = 3.0, 4.2, -6.0, 5.4
WX, WW, WZ0, WZ1 = 0.35, 1.5, 1.2, 3.05      # window centre x, width, sill, top of the arch
MOON = (0.08, 1.0, 0.2)


def materials():
    return dict(
        plaster=K.tex_material("Plaster", "Plaster007", scale=0.5, value=0.42, sat=0.4,
                               tint="#A8B4C8", tint_fac=0.5, rough=(0.8, 1.0)),
        floor=K.tex_material("Marble", "Marble012", scale=0.5, value=0.36, sat=0.5,
                             tint="#9AA6BA", tint_fac=0.3, rough=(0.4, 0.65), normal=0.3),
        sill=K.tex_material("Sill", "Marble012", scale=1.2, value=0.6, sat=0.4, rough=(0.2, 0.45)),
        bench=K.tex_material("Bench", "Planks023A", scale=0.9, value=0.3, sat=0.7,
                             tint="#5A4636", tint_fac=0.4, rough=(0.5, 0.85)),
        beam=K.tex_material("Beam", "Planks023A", scale=0.6, value=0.2, sat=0.6, rough=(0.7, 0.95)),
        silver=K.metal_material("Silver", "#DDE2EA", rough=(0.1, 0.24), bump=0.03),
        silver_dull=K.metal_material("SilverDull", "#B8BEC8", rough=(0.25, 0.42), bump=0.06),
        steel=P.iron_material("Steel", base="#7C828A", rough=(0.25, 0.45), bump=0.08),
        frame=K.flat_material("Frame", "#1A1D22", rough=0.6),
        glass=K.flat_material("Glass", "#0A0E16", rough=0.05),
        handle=P.wood_material("Handle", value=0.6, scale=3.0),
        wax=K.flat_material("Wax", "#E8E0D0", rough=0.6),
        candle_flame=K.flame_material("CandleFlame", strength=8.0),
    )


def window_wall(M):
    """Back wall with a tall round-arched window (exact boolean cut), a stone
    surround and a dark frame with glazing bars."""
    r = WW / 2
    zs = WZ1 - r                                  # spring line of the arch
    wall = K.wall_with_openings("BackWall", (0, BACK + 0.24, HEIGHT / 2), (2 * W_HALF + 0.6, 0.45, HEIGHT + 0.2),
                                [K.arch_outline(WX, WW, WZ0, zs)], M["plaster"])
    # frame: jambs, sill, arch ring, glazing bars
    K.box("WinSill", (WX, BACK - 0.08, WZ0 - 0.05), (WW + 0.3, 0.32, 0.1), M["sill"], 0.02)
    bpy.ops.mesh.primitive_torus_add(major_radius=r, minor_radius=0.04, major_segments=64,
                                     minor_segments=8, location=(WX, BACK + 0.2, zs),
                                     rotation=(math.pi / 2, 0, 0))
    ring = bpy.context.active_object
    ring.name = "ArchRing"
    bm = bmesh.new()                              # keep only the upper half of the ring
    bm.from_mesh(ring.data)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.y < -0.01], context="VERTS")
    bm.to_mesh(ring.data)
    bm.free()
    C.assign(ring, M["frame"])
    for sx in (-1, 1):
        K.box(f"Jamb{sx}", (WX + sx * r, BACK + 0.2, (WZ0 + zs) / 2), (0.08, 0.08, zs - WZ0), M["frame"], 0)
    # stone surround on the wall face: hides the stepped edge of the cut-out
    bpy.ops.mesh.primitive_torus_add(major_radius=r + 0.04, minor_radius=0.075, major_segments=96,
                                     minor_segments=8, location=(WX, BACK + 0.01, zs),
                                     rotation=(math.pi / 2, 0, 0))
    sur = bpy.context.active_object
    sur.name = "Surround"
    sur.scale = (1, 1, 0.6)
    bm = bmesh.new()
    bm.from_mesh(sur.data)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.y < -0.01], context="VERTS")
    bm.to_mesh(sur.data)
    bm.free()
    C.assign(sur, M["sill"])
    for sx in (-1, 1):
        K.box(f"SurroundJamb{sx}", (WX + sx * (r + 0.04), BACK + 0.01, (WZ0 + zs) / 2), (0.15, 0.09, zs - WZ0),
              M["sill"], 0.01)
    K.box("Mullion", (WX, BACK + 0.2, (WZ0 + WZ1) / 2), (0.035, 0.05, WZ1 - WZ0), M["frame"], 0)
    for i in range(1, 5):
        z = WZ0 + (zs - WZ0) * i / 5
        K.box(f"Bar{i}", (WX, BACK + 0.2, z), (WW, 0.05, 0.03), M["frame"], 0)
    return wall


def build(M):
    # shell ----------------------------------------------------------------------
    K.plane("Floor", (0, (BACK + FRONT) / 2, 0), (2 * W_HALF, BACK - FRONT), mat=M["floor"])
    K.box("FrontWall", (0, FRONT - 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT), M["plaster"], 0)
    for sx in (-1, 1):
        K.box(f"SideWall{sx}", (sx * (W_HALF + 0.15), (BACK + FRONT) / 2, HEIGHT / 2),
              (0.3, BACK - FRONT, HEIGHT), M["plaster"], 0)
    K.box("Ceiling", (0, (BACK + FRONT) / 2, HEIGHT + 0.1), (2 * W_HALF + 0.6, BACK - FRONT, 0.2),
          M["beam"], 0)
    for i, y in enumerate((2.8, 0.6)):
        K.box(f"Beam{i}", (0, y, 4.2), (2 * W_HALF, 0.28, 0.3), M["beam"], 0.03)
    window_wall(M)
    # outside: a few far rooftops in silhouette under the sky
    roof = K.flat_material("Roofs", "#06080C", rough=0.9)
    for i, (x, w, h) in enumerate(((-6, 7, 1.6), (2.5, 5, 2.4), (8, 6, 1.2))):
        K.box(f"Roof{i}", (x, 40, h / 2 - 1.5), (w, 4, h), roof, 0)
        bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=w * 0.6, depth=1.4,
                                        location=(x, 40, h - 1.5 + 0.7), rotation=(0, 0, math.pi / 4))
        C.assign(bpy.context.active_object, roof)

    # workbench under the window with silverware -----------------------------------
    BY, BZ = BACK - 0.85, 0.92
    K.box("BenchTop", (WX - 0.1, BY, BZ - 0.04), (2.6, 0.85, 0.08), M["bench"], 0.015)
    for sx in (-1, 1):
        for sy in (-1, 1):
            K.box(f"BenchLeg{sx}{sy}", (WX - 0.1 + sx * 1.18, BY + sy * 0.32, (BZ - 0.08) / 2),
                  (0.08, 0.08, BZ - 0.08), M["bench"], 0.01)
    items = [("goblet", -0.75, 0.05, 0.36, "silver"), ("goblet", -0.52, -0.12, 0.3, "silver"),
             ("jug", 0.05, 0.12, 0.44, "silver"), ("candlestick", 0.72, 0.18, 0.52, "silver"),
             ("goblet", 0.42, -0.15, 0.26, "silver_dull"), ("urn", -1.1, 0.2, 0.38, "silver_dull")]
    for i, (kind, dx, dy, h, mat) in enumerate(items):
        K.turned(f"Ware{i}", kind, (WX + dx, BY + dy, BZ), h, M[mat], segments=64)
    plate = K.turned("Plate", "plate", (0, 0, 0), 0.5, M["silver"], segments=96)
    plate.location = (WX - 0.45, BY + 0.36, BZ + 0.2)
    plate.rotation_euler = (math.radians(78), 0, 0)          # leaning on the window reveal
    K.turned("Plate2", "plate", (WX + 0.3, BY - 0.05, BZ), 0.5, M["silver_dull"], segments=96)
    # candle in the tall candlestick
    cx, cy = WX + 0.72, BY + 0.18
    K.cylinder("Candle", (cx, cy, BZ + 0.52 + 0.1), 0.022, 0.2, M["wax"], verts=16)
    K.flame("CandleFlame", (cx, cy, BZ + 0.72), height=0.07, width=0.016, seed=3, mat=M["candle_flame"])
    C.point_light("CandleLight", (cx, cy - 0.05, BZ + 0.8), 6, radius=0.03, color=(1.0, 0.62, 0.3))
    # small charcoal brazier on the bench (the forge of a silversmith)
    bx, by = WX - 0.25, BY - 0.15
    K.turned("Brazier", "cauldron", (bx, by, BZ), 0.24, M["steel"], segments=48)
    K.coal_heap("BrazierCoals", (bx, by, BZ + 0.18), radius=(0.09, 0.09), height=0.04, strength=6.0)
    C.point_light("BrazierLight", (bx, by - 0.05, BZ + 0.32), 14, radius=0.06, color=(1.0, 0.45, 0.15))
    K.box("Ingot", (bx + 0.35, by - 0.1, BZ + 0.02), (0.14, 0.06, 0.035), M["silver"], 0.006)

    # wall shelf of silverware (left) and a rack of small hammers (right) ---------------
    K.box("WallShelf", (-1.35, BACK - 0.14, 1.95), (1.1, 0.26, 0.05), M["bench"], 0.01)
    for i, (kind, dx, h, mat) in enumerate((("urn", -0.35, 0.34, "silver_dull"), ("goblet", -0.05, 0.24, "silver"),
                                            ("jug", 0.25, 0.3, "silver"))):
        K.turned(f"ShelfWare{i}", kind, (-1.35 + dx, BACK - 0.14, 1.975), h, M[mat], segments=48)
    sp = K.turned("ShelfPlate", "plate", (0, 0, 0), 0.36, M["silver_dull"], segments=64)
    sp.location = (-1.0, BACK - 0.05, 2.15)
    sp.rotation_euler = (math.radians(82), 0, 0)
    K.tool_rack((1.75, BACK - 0.04, 1.95), along="X", length=0.8, wood=M["bench"], iron=M["steel"],
                handle=M["handle"], facing=-1, seed=6)

    # foreground: stake anvil on a stump, hammers --------------------------------------
    AX, AY = -0.9, 0.55
    K.stump("Stump", (AX, AY, 0), radius=0.3, height=0.62, mat=M["bench"])
    K.cylinder("StakePost", (AX, AY, 0.72), 0.04, 0.22, M["steel"], verts=16)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=0.1, location=(AX, AY, 0.86))
    stake = bpy.context.active_object
    stake.scale = (1.6, 1.0, 0.7)
    C.shade_smooth(stake)
    C.assign(stake, M["steel"])
    hm = P.hammer("Planish", M["silver_dull"], M["handle"], head_len=0.16, head_w=0.06,
                  handle_len=0.34, pein_axis="none", handle_r=0.014)
    hm.location = (AX + 0.12, AY - 0.12, 0.67)
    hm.rotation_euler = (math.radians(90), 0, math.radians(-35))

    # light: moonlight through the window, faint cool fill, warm accents -------------
    sun = C.sun_light("Moonlight", (0, 0, 0), 1.0, angle=0.8, color=(0.62, 0.74, 1.0))
    sun.rotation_euler = Vector((-0.06, -1.0, -1.15)).to_track_quat("-Z", "Y").to_euler()
    C.area_light("SilverKey", (WX + 0.2, BACK - 2.4, 2.4), (WX, BACK - 0.85, 1.05), 45, size=1.2,
                 color=(0.7, 0.8, 1.0))
    C.area_light("WindowSky", (WX, BACK + 0.6, (WZ0 + WZ1) / 2), (WX, 1.0, 0.8), 40, size=WW,
                 size_y=WZ1 - WZ0, shape="RECTANGLE", color=(0.55, 0.68, 1.0))
    C.area_light("RimStake", (0.4, 2.2, 1.6), (AX, AY, 0.85), 8, size=0.6, color=(0.7, 0.8, 1.0))
    C.area_light("CoolFill", (-2.0, -3.0, 3.5), (0, 2, 1), 14, size=3.0, color=(0.55, 0.65, 1.0))
    K.haze((-W_HALF + 0.05, FRONT + 2, 0.05), (W_HALF - 0.05, BACK - 0.5, HEIGHT - 0.1),
           density=0.006, color=(0.9, 0.94, 1.0), anisotropy=0.55)


def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="Filmic",
                        look="High Contrast", exposure=0.0, bounces=5)
    sc.cycles.volume_step_rate = 8.0
    sc.cycles.volume_max_steps = 256
    K.night_world(zenith="#060A18", horizon="#22325E", ground="#04050A", strength=1.0,
                  stars=0.7, star_scale=240.0, moon=MOON, moon_size=4.0, moon_strength=7.0,
                  moon_color="#EEF2FF", glow_color="#5A78C0", glow_dir=MOON, glow_power=10.0,
                  glow_strength=0.6)
    M = materials()
    build(M)
    cam = C.persp_camera((0.15, -2.9, 1.45), (0.15, BACK - 1.0, 1.42), lens=26)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 6.2
    cam.data.dof.aperture_fstop = 2.8
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
