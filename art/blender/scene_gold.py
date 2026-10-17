"""bg_gold: the royal goldsmith's vault (Gold chapter).

A rich, warm treasury: stone walls hung with red banners, a chequered marble
floor and tall shelves crowded with gold goblets, plates, urns, ingots and
coin heaps. The focal point (~45-58 % down the frame) is the goldsmith's
round stone hearth in the middle of the vault, its coals and flames
cradling a crucible of molten gold. A jewelled crown rests on a red cushion
on a pedestal, an open chest spills coins and gold bars are stacked in the
foreground.

Top ~45 % (upper shelves, banners, vault) and the bottom (floor) stay calm.

    blender -b --factory-startup -P scene_gold.py -- [--samples 64] [--scale 0.667]
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402

import common as C  # noqa: E402
import forge_kit as K  # noqa: E402
import props as P  # noqa: E402

SAMPLES = C.arg("samples", 64)
SCALE = C.arg("scale", 0.667)
NAME = "bg_gold"

W_HALF, BACK, FRONT, HEIGHT = 3.0, 4.2, -6.0, 5.6
HX, HY = 0.0, 2.1          # the round hearth


def materials():
    return dict(
        wall=K.tex_material("StoneWall", "Bricks102", scale=0.45, value=0.3, sat=0.8,
                            tint="#B08458", tint_fac=0.45, rough=(0.75, 1.0), soot=0.6,
                            soot_range=(3.2, 5.6)),
        floor=K.tex_material("Chequer", "Tiles074", scale=0.55, value=0.28, sat=0.7,
                             tint="#C89A6A", tint_fac=0.35, rough=(0.6, 0.85), normal=0.4),
        stone=K.tex_material("Stone", "Bricks102", scale=1.3, value=0.42, sat=0.6, rough=(0.6, 0.95)),
        shelf=K.tex_material("Shelf", "Planks023A", scale=0.8, value=0.26, sat=0.9,
                             tint="#6A3E24", tint_fac=0.45, rough=(0.45, 0.8)),
        gold=K.metal_material("Gold", "#E8B840", rough=(0.12, 0.28), bump=0.03),
        gold_old=K.metal_material("GoldOld", "#C8962E", rough=(0.25, 0.45), bump=0.08),
        velvet=K.flat_material("Velvet", "#6A0E14", rough=0.65),
        trim=K.metal_material("Trim", "#D8A838", rough=(0.25, 0.4), bump=0.02),
        ruby=K.flat_material("Ruby", "#B0101C", rough=0.05, emission=(C.hex_lin("#FF2030"), 0.6)),
        sapphire=K.flat_material("Sapphire", "#1030B0", rough=0.05, emission=(C.hex_lin("#3050FF"), 0.5)),
        iron=P.iron_material("Iron", base="#5A5C62", rough=(0.3, 0.5), bump=0.12),
        crucible=K.tex_material("CrucibleClay", "Plaster007", scale=1.5, value=0.1, sat=0.6,
                                tint="#5A4A40", tint_fac=0.6, rough=(0.8, 1.0)),
        molten=K.glow_material("MoltenGold", "#FFB030", 18.0),
        chest=K.tex_material("Chest", "Planks023A", scale=1.4, value=0.35, sat=1.0, tint="#7A4A28",
                             tint_fac=0.4, rough=(0.5, 0.85)),
    )


def crown(name, loc, size, M):
    """Open jewelled crown: a band with five points topped by pearls, gems around."""
    x, y, z = loc
    r = size * 0.5
    bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=r, depth=size * 0.32,
                                        location=(x, y, z + size * 0.16), end_fill_type="NOTHING")
    band = bpy.context.active_object
    band.name = name + "Band"
    so = band.modifiers.new("Thick", "SOLIDIFY")
    so.thickness = size * 0.04
    C.shade_smooth(band)
    C.assign(band, M["gold"])
    objs = [band]
    for k in range(5):
        a = 2 * math.pi * k / 5 + 0.3
        px, py = x + r * math.cos(a), y + r * math.sin(a)
        bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=size * 0.14, depth=size * 0.4,
                                        location=(px, py, z + size * 0.5),
                                        rotation=(0, 0, a + math.pi / 4))
        sp = bpy.context.active_object
        sp.scale = (1.0, 0.35, 1.0)
        C.assign(sp, M["gold"])
        bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=size * 0.045,
                                             location=(px, py, z + size * 0.72))
        C.shade_smooth(bpy.context.active_object)
        C.assign(bpy.context.active_object, M["trim"])
        bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=size * 0.05,
                                             location=(x + (r + 0.01) * math.cos(a + 0.63),
                                                       y + (r + 0.01) * math.sin(a + 0.63), z + size * 0.16))
        gem = bpy.context.active_object
        C.shade_smooth(gem)
        C.assign(gem, M["ruby"] if k % 2 else M["sapphire"])
        objs += [sp, gem]
    return objs


def banner(name, x, M):
    """Red velvet banner with a gold fringe bar, hanging on the back wall."""
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=12, y_subdivisions=24, size=1,
                                    location=(x, BACK - 0.06, 3.35), rotation=(math.pi / 2, 0, 0))
    b = bpy.context.active_object
    b.name = name
    b.scale = (0.8, 2.1, 1)
    C.apply_transform(b)
    for v in b.data.vertices:            # swallowtail cut + soft folds
        u = (v.co.x) / 0.4
        if v.co.z < -0.85:
            v.co.z = max(v.co.z, -1.05 + 0.25 * (1 - abs(u)))
        v.co.y += 0.03 * math.sin(v.co.x * 14.0)
    C.shade_smooth(b)
    C.assign(b, M["velvet"])
    K.box(name + "Rod", (x, BACK - 0.08, 4.42), (1.0, 0.04, 0.04), M["trim"], 0.01)
    K.box(name + "Band", (x, BACK - 0.08, 4.0), (0.8, 0.03, 0.08), M["trim"], 0.005)
    return b


def shelves(M, seed=5):
    """Two tall shelf units either side of the vault, crowded with gold."""
    rnd = random.Random(seed)
    kinds = ["goblet", "urn", "jug", "goblet", "candlestick", "cauldron"]
    for side in (-1, 1):
        cx = side * 1.75
        w = 1.6
        K.box(f"ShelfBack{side}", (cx, BACK - 0.03, 1.55), (w + 0.1, 0.04, 3.1), M["shelf"], 0.005)
        for sx in (-1, 1):
            K.box(f"ShelfSide{side}{sx}", (cx + sx * w / 2, BACK - 0.25, 1.55), (0.06, 0.5, 3.1), M["shelf"], 0.01)
        for j, z in enumerate((0.35, 1.0, 1.65, 2.3, 2.95)):
            K.box(f"Shelf{side}_{j}", (cx, BACK - 0.25, z), (w, 0.48, 0.05), M["shelf"], 0.008)
            if j == 4:
                continue
            x = cx - w / 2 + 0.15
            while x < cx + w / 2 - 0.15:
                pick = rnd.random()
                mat = M["gold"] if rnd.random() < 0.65 else M["gold_old"]
                if pick < 0.55:
                    h = rnd.uniform(0.22, 0.42)
                    K.turned(f"Treasure{side}{j}{x:.2f}", rnd.choice(kinds), (x, BACK - 0.25 + rnd.uniform(-0.08, 0.08),
                                                                            z + 0.025), h, mat, segments=32)
                    x += h * 0.75 + 0.06
                elif pick < 0.75:
                    p = K.turned(f"Plate{side}{j}{x:.2f}", "plate", (0, 0, 0), 0.34, mat, segments=48)
                    p.location = (x, BACK - 0.12, z + 0.17)
                    p.rotation_euler = (math.radians(80), 0, 0)
                    x += 0.38
                else:
                    for k in range(3):
                        K.ingot(f"Bar{side}{j}{x:.2f}_{k}", (x + (k - 1) * 0.04 * 0, BACK - 0.25 + (k - 1) * 0.1,
                                                               z + 0.055), M["gold"], size=(0.2, 0.08, 0.05))
                    x += 0.28


def build(M):
    # shell -------------------------------------------------------------------
    K.plane("Floor", (0, (BACK + FRONT) / 2, 0), (2 * W_HALF, BACK - FRONT), mat=M["floor"])
    K.box("FrontWall", (0, FRONT - 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT), M["wall"], 0)
    K.box("BackWall", (0, BACK + 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT), M["wall"], 0)
    for sx in (-1, 1):
        K.box(f"SideWall{sx}", (sx * (W_HALF + 0.15), (BACK + FRONT) / 2, HEIGHT / 2),
              (0.3, BACK - FRONT, HEIGHT), M["wall"], 0)
    K.box("Ceiling", (0, (BACK + FRONT) / 2, HEIGHT + 0.1), (2 * W_HALF + 0.6, BACK - FRONT, 0.2), M["wall"], 0)
    # vault ribs: stone arches across the room
    import bmesh
    for i, y in enumerate((3.4, 1.0, -1.4)):          # half-ring arches springing from the side walls
        bpy.ops.mesh.primitive_torus_add(major_radius=W_HALF, minor_radius=0.16, major_segments=64,
                                         minor_segments=8, location=(0, y, 2.6),
                                         rotation=(math.pi / 2, 0, 0))
        rib = bpy.context.active_object
        rib.name = f"Rib{i}"
        bm = bmesh.new()
        bm.from_mesh(rib.data)
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.y < -0.01], context="VERTS")
        bm.to_mesh(rib.data)
        bm.free()
        rib.scale = (1, 0.95, 1)
        C.assign(rib, M["stone"])
    shelves(M)
    banner("BannerC", 0.0, M)

    # the goldsmith's round hearth with a crucible of molten gold ---------------
    K.cylinder("HearthBase", (HX, HY, 0.42), 0.62, 0.84, M["stone"], verts=48, bevel=0.03)
    bpy.ops.mesh.primitive_torus_add(major_radius=0.6, minor_radius=0.06, major_segments=64,
                                     minor_segments=10, location=(HX, HY, 0.86))
    C.assign(bpy.context.active_object, M["trim"])
    K.coal_heap("HearthCoals", (HX, HY, 0.86), radius=(0.48, 0.42), height=0.12, strength=6.5)
    K.fire((HX, HY + 0.12, 0.9), spread=(0.36, 0.1), count=7, height=0.55, width=0.13, seed=31,
           strength=6.5, name="HearthFire")
    cr = K.turned("Crucible", "crucible", (HX - 0.05, HY - 0.08, 0.88), 0.34, M["crucible"], segments=48)
    K.turned("Melt", [(0.0, 0.0), (0.13, 0.0), (0.0, 0.004)], (HX - 0.05, HY - 0.08, 0.88 + 0.34 * 0.66), 1.0,
             M["molten"], segments=32)
    K.flame_volume((HX, HY, 1.15), size=(0.5, 0.4, 0.35), strength=2.0, name="HearthGlow")
    C.point_light("HearthLight", (HX, HY - 0.1, 1.35), 150, radius=0.3, color=(1.0, 0.55, 0.2))
    C.point_light("MeltLight", (HX - 0.05, HY - 0.3, 1.2), 25, radius=0.08, color=(1.0, 0.75, 0.35))
    K.embers((HX - 0.4, HY - 0.3, 1.5), (HX + 0.4, HY + 0.2, 2.6), count=10, seed=31, radius=0.01)

    # crown on a cushion on a pedestal (right) ------------------------------------
    PX, PY = 0.85, 0.95
    K.box("Pedestal", (PX, PY, 0.5), (0.36, 0.36, 1.0), M["stone"], 0.02)
    K.box("PedestalCap", (PX, PY, 1.02), (0.44, 0.44, 0.05), M["trim"], 0.01)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(PX, PY, 1.1))
    cu = bpy.context.active_object
    cu.scale = (0.34, 0.34, 0.1)
    b = cu.modifiers.new("Bevel", "BEVEL")
    b.width = 0.04
    b.segments = 4
    s = cu.modifiers.new("Sub", "SUBSURF")
    s.levels = s.render_levels = 2
    C.assign(cu, M["velvet"])
    crown("Crown", (PX, PY, 1.13), 0.36, M)

    # foreground: open chest spilling coins, stacked bars --------------------------
    CX, CY = -0.85, 0.55
    K.box("Chest", (CX, CY, 0.2), (0.7, 0.45, 0.4), M["chest"], 0.02, rot=(0, 0, 12))
    lid = K.box("ChestLid", (CX + 0.03, CY + 0.32, 0.55), (0.7, 0.08, 0.4), M["chest"], 0.02, rot=(-20, 0, 12))
    for i, dz in enumerate((0.08, 0.32)):
        K.box(f"ChestBand{i}", (CX, CY, dz), (0.72, 0.47, 0.04), M["trim"], 0.005, rot=(0, 0, 12))
    K.coin_pile("ChestCoins", (CX, CY, 0.36), 0.28, 0.14, 160, M["gold"], seed=3)
    K.coin_pile("FloorCoins", (CX + 0.45, CY - 0.25, 0.0), 0.32, 0.08, 120, M["gold"], seed=4)
    K.coin_pile("FloorCoins2", (0.4, 0.2, 0.0), 0.2, 0.05, 50, M["gold_old"], seed=8)
    for row in range(3):                 # a little pyramid of gold bars
        for k in range(3 - row):
            K.ingot(f"Stack{row}{k}", (1.25 + (k - (2 - row) / 2) * 0.13, 0.25, 0.03 + row * 0.06),
                    M["gold"], size=(0.12, 0.24, 0.06), rot_z=math.radians(90))
    K.turned("FrontGoblet", "goblet", (0.55, 0.35, 0.0), 0.3, M["gold"], segments=48)

    # warm lamps, rims ----------------------------------------------------------------
    for sx in (-1, 1):
        K.torch(f"Lamp{sx}", (sx * 0.85, BACK - 0.15, 2.45), wood=M["trim"], iron=M["trim"],
                strength=6.0, light=35.0, lean=(0.0, 0.25))
    C.area_light("ShelfWash", (0.0, 1.4, 2.2), (0.0, BACK, 1.0), 45, size=2.5, color=(1.0, 0.7, 0.4))
    C.area_light("RimCrown", (0.3, 2.4, 1.8), (PX, PY, 1.2), 20, size=0.5, color=(1.0, 0.75, 0.45))
    C.area_light("CoolFill", (-2.0, -3.0, 3.5), (0, 2, 1), 4, size=3.0, color=(0.6, 0.6, 0.8))
    K.haze((-W_HALF + 0.05, FRONT + 2, 0.05), (W_HALF - 0.05, BACK - 0.55, HEIGHT - 0.1),
           density=0.004, color=(1.0, 0.9, 0.75), anisotropy=0.45)


def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="Filmic",
                        look="High Contrast", exposure=0.0, bounces=5)
    sc.cycles.volume_step_rate = 8.0
    sc.cycles.volume_max_steps = 256
    C.world_color(C.hex_lin("#030202"), 1.0)
    M = materials()
    build(M)
    cam = C.persp_camera((0.1, -2.9, 1.5), (0.0, HY, 1.38), lens=26)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 5.0
    cam.data.dof.aperture_fstop = 2.8
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
