"""bg_bronze: an ancient bronze foundry by torchlight (Bronze chapter).

A stone casting hall: a round clay furnace with a roaring arched mouth sits
centre-back (~45-58 % down the frame). To its left a crucible of molten
bronze tips a thin bright stream into a clay mould on a stone bench. A big
finished bronze bell hangs on a chain on the right, a little bronze warrior
statuette stands on the bench, and two wall torches flank the furnace. Clay moulds and small cast bells sit about the sandy floor.

Top ~45 % (beams, bell, sooty wall) and the bottom (floor) stay dark and calm.

    blender -b --factory-startup -P scene_bronze.py -- [--samples 80] [--scale 0.667]
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402

import common as C  # noqa: E402
import forge_kit as K  # noqa: E402
import props as P  # noqa: E402

SAMPLES = C.arg("samples", 80)
SCALE = C.arg("scale", 0.667)
NAME = "bg_bronze"

W_HALF, BACK, FRONT, HEIGHT = 3.0, 4.0, -6.0, 6.0
FORGE_Y = BACK - 1.55


def materials():
    return dict(
        wall=K.tex_material("StoneWall", "Bricks102", scale=0.45, value=0.3, sat=0.8,
                            tint="#A07050", tint_fac=0.5, rough=(0.75, 1.0),
                            soot=0.9, soot_range=(2.4, 5.0)),
        floor=K.tex_material("Flagstones", "PavingStones142", scale=0.8, value=0.2, sat=0.6,
                             tint="#8A6A50", tint_fac=0.35, rough=(0.55, 0.95), normal=0.6),
        sand=K.tex_material("Sand", "Ground054", scale=0.7, value=0.32, sat=0.8,
                            tint="#A0785A", tint_fac=0.3, rough=(0.85, 1.0)),
        clay=K.tex_material("ClayBrick", "Bricks094", scale=1.0, value=0.5, sat=1.0,
                            tint="#B87050", tint_fac=0.35, rough=(0.7, 1.0),
                            soot=0.75, soot_range=(1.6, 2.5)),
        chimney=K.tex_material("Chimney", "Bricks094", scale=1.0, value=0.26, sat=0.6,
                               rough=(0.7, 1.0), soot=0.9, soot_range=(2.4, 4.5)),
        stone=K.tex_material("Apron", "Bricks102", scale=1.4, value=0.42, sat=0.6,
                             rough=(0.6, 0.95)),
        crucible=K.tex_material("CrucibleClay", "Plaster007", scale=1.5, value=0.2, sat=0.6,
                                tint="#6A5A50", tint_fac=0.5, rough=(0.8, 1.0)),
        mould=K.tex_material("Mould", "Plaster007", scale=1.2, value=0.42, sat=1.0,
                             tint="#9A5A3A", tint_fac=0.6, rough=(0.8, 1.0)),
        beam=K.tex_material("Beam", "Planks023A", scale=0.6, value=0.28, sat=0.8,
                            rough=(0.7, 0.95)),
        wood=P.wood_material("Wood", value=0.55, scale=1.2),
        bronze=K.metal_material("Bronze", "#B8874E", rough=(0.22, 0.42), bump=0.06),
        bronze_old=K.metal_material("BronzeOld", "#8A6036", rough=(0.35, 0.6), bump=0.1),
        iron=P.iron_material("Iron", base="#62646A", rough=(0.3, 0.5), bump=0.12),
        molten=K.glow_material("Molten", "#FF9A2A", 22.0),
    )


def statuette(name, loc, mat, h=0.62):
    """Small cast-bronze warrior on a little plinth: crested helmet, round
    shield and spear, so it reads as a statue even when tiny."""
    x, y, z = loc
    k = h / 0.62
    parts = [K.box(name + "Plinth", (x, y, z + 0.03 * k), (0.2 * k, 0.16 * k, 0.06 * k), None, 0.005)]
    for sx in (-1, 1):                    # legs
        parts.append(K.cylinder(f"{name}Leg{sx}", (x + sx * 0.03 * k, y, z + 0.17 * k), 0.022 * k,
                                0.22 * k, None, verts=12, rot=(0, sx * 4, 0)))
    bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=1.0,
                                         location=(x, y, z + 0.37 * k))
    torso = bpy.context.active_object
    torso.scale = (0.075 * k, 0.05 * k, 0.11 * k)
    parts.append(torso)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=0.042 * k,
                                         location=(x, y, z + 0.52 * k))
    parts.append(bpy.context.active_object)
    parts.append(K.box(name + "Crest", (x, y + 0.005 * k, z + 0.575 * k), (0.012 * k, 0.09 * k, 0.04 * k),
                       None, 0.004))
    parts.append(K.cylinder(name + "Arm", (x + 0.075 * k, y - 0.01 * k, z + 0.36 * k), 0.016 * k,
                            0.18 * k, None, verts=10, rot=(0, -15, 0)))
    parts.append(K.cylinder(name + "Shield", (x - 0.085 * k, y - 0.04 * k, z + 0.34 * k), 0.085 * k,
                            0.018 * k, None, verts=32, rot=(90, 0, 15)))
    parts.append(K.cylinder(name + "Spear", (x + 0.1 * k, y - 0.01 * k, z + 0.4 * k), 0.007 * k,
                            0.72 * k, None, verts=8))
    for i, ob in enumerate(parts):
        ob.name = f"{name}{i}"
        C.shade_smooth(ob)
        C.assign(ob, mat)
    return parts


def sand_patch(name, center, rx, ry, mat, seed=3):
    """Irregular disc of casting sand on the floor (no straight edges)."""
    import random
    rnd = random.Random(seed)
    n = 48
    verts = [(center[0], center[1], 0.004)]
    for i in range(n):
        a = 2 * math.pi * i / n
        k = 1.0 + 0.12 * math.sin(3 * a + 1.0) + 0.06 * math.sin(7 * a) + rnd.uniform(-0.04, 0.04)
        verts.append((center[0] + rx * k * math.cos(a), center[1] + ry * k * math.sin(a), 0.004))
    faces = [(0, 1 + i, 1 + (i + 1) % n) for i in range(n)]
    ob = C.mesh_object(name, verts, faces, smooth=False)
    C.assign(ob, mat)
    return ob


def dome_furnace(loc, M, radius=1.2, base_h=0.55, mouth_w=1.05, mouth_h=1.0, chimney_top=6.0,
                 fire_strength=6.5, light=170.0, seed=11):
    """Round clay bell-furnace on a stone plinth: an arched mouth full of coals
    and flames, a hollow fire chamber, and a chimney rising into the dark.
    loc = centre of the dome's footprint at floor level."""
    x, y, z = loc
    K.cylinder("FurnacePlinth", (x, y, z + base_h / 2), radius + 0.15, base_h, M["stone"],
               verts=64, bevel=0.03)
    zb = z + base_h
    prof = [(0.0, 0.0), (radius, 0.0), (radius, 0.45), (radius * 0.95, 0.95),
            (radius * 0.8, 1.4), (radius * 0.55, 1.78), (radius * 0.36, 2.0),
            (radius * 0.3, 2.2), (radius * 0.3, chimney_top - zb), (0.0, chimney_top - zb)]
    dome = C.lathe("Furnace", prof, segments=96)
    dome.location = (x, y, zb)
    # cutters: rectangular mouth + round arch (front, -Y) and a hollow chamber
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, y - radius * 0.7,
                                                      zb + (mouth_h - mouth_w / 2) / 2 - 0.01))
    c1 = bpy.context.active_object
    c1.scale = (mouth_w, radius * 1.2, mouth_h - mouth_w / 2 + 0.02)
    bpy.ops.mesh.primitive_cylinder_add(vertices=64, radius=mouth_w / 2, depth=radius * 1.2,
                                        location=(x, y - radius * 0.7, zb + mouth_h - mouth_w / 2),
                                        rotation=(math.pi / 2, 0, 0))
    c2 = bpy.context.active_object
    bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, radius=1.0,
                                         location=(x, y, zb + 0.15))
    c3 = bpy.context.active_object
    c3.scale = (radius * 0.72, radius * 0.72, 1.15)
    for c in (c1, c2, c3):
        mod = dome.modifiers.new("Cut", "BOOLEAN")
        mod.operation = "DIFFERENCE"
        mod.object = c
        mod.solver = "EXACT"
    bpy.context.view_layer.objects.active = dome
    for mod in list(dome.modifiers):
        bpy.ops.object.modifier_apply(modifier=mod.name)
    for c in (c1, c2, c3):
        bpy.data.objects.remove(c)
    C.assign(dome, M["clay"])
    # iron band round the dome + a bronze lintel plate over the mouth
    bpy.ops.mesh.primitive_torus_add(major_radius=radius * 0.97, minor_radius=0.035,
                                     major_segments=96, minor_segments=8,
                                     location=(x, y, zb + 1.18))
    band = bpy.context.active_object
    band.name = "FurnaceBand"
    band.scale = (1, 1, 1.6)
    C.assign(band, M["bronze_old"])
    # apron ledge in front of the mouth
    K.box("FurnaceApron", (x, y - radius - 0.12, zb - 0.06), (mouth_w + 0.5, 0.5, 0.12),
          M["stone"], bevel=0.03)
    # coals + flames inside the chamber
    fy = y - radius * 0.25
    K.coal_heap("FurnaceCoals", (x, fy, zb + 0.02), radius=(mouth_w * 0.45, radius * 0.4),
                height=0.18, strength=fire_strength * 0.8)
    K.fire((x, fy - 0.08, zb + 0.06), spread=(mouth_w * 0.3, 0.15), count=9,
           height=mouth_h * 0.78, width=0.16, seed=seed, strength=fire_strength, name="FurnaceFire")
    K.flame_volume((x, fy - 0.1, zb + 0.42), size=(mouth_w * 0.45, 0.4, mouth_h * 0.42),
                   strength=fire_strength * 0.5, name="FurnaceGlow")
    C.point_light("FurnaceFireLight", (x, fy, zb + 0.45), light, radius=0.4,
                  color=(1.0, 0.42, 0.12))
    C.area_light("FurnaceMouth", (x, y - radius + 0.05, zb + mouth_h * 0.45),
                 (x, y - radius - 4.0, z + 0.4), light * 0.25, size=mouth_w * 0.8,
                 size_y=mouth_h * 0.6, shape="RECTANGLE", color=(1.0, 0.45, 0.15))


def build(M):
    # room shell -------------------------------------------------------------
    K.plane("Floor", (0, (BACK + FRONT) / 2, 0), (2 * W_HALF, BACK - FRONT), mat=M["floor"])
    K.box("FrontWall", (0, FRONT - 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT),
          M["wall"], bevel=0)
    K.box("BackWall", (0, BACK + 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT),
          M["wall"], bevel=0)
    for sx in (-1, 1):
        K.box(f"SideWall{sx}", (sx * (W_HALF + 0.15), (BACK + FRONT) / 2, HEIGHT / 2),
              (0.3, BACK - FRONT, HEIGHT), M["wall"], bevel=0)
    K.box("Ceiling", (0, (BACK + FRONT) / 2, HEIGHT + 0.1), (2 * W_HALF + 0.6, BACK - FRONT, 0.2),
          M["beam"], bevel=0)
    for i, y in enumerate((2.2, 0.2)):
        K.box(f"Beam{i}", (0, y, 4.5), (2 * W_HALF, 0.34, 0.38), M["beam"], bevel=0.04)

    # the round clay furnace, centre back ---------------------------------------
    FY = FORGE_Y + 0.55
    dome_furnace((0, FY, 0), M, radius=1.2, base_h=0.6, mouth_w=1.05, mouth_h=1.0,
                 chimney_top=HEIGHT, fire_strength=6.5, light=170.0, seed=11)

    # casting bench left of the furnace: crucible pouring into a clay mould ------
    BX, BY = -0.98, 1.6
    K.box("Bench", (BX, BY, 0.42), (0.95, 0.75, 0.84), M["stone"], bevel=0.04)
    K.box("BenchSand", (BX, BY, 0.87), (0.88, 0.68, 0.06), M["sand"], bevel=0.02)
    mx, my, mz, mh = BX - 0.05, BY + 0.1, 0.9, 0.4
    K.turned("PourMould", "mould", (mx, my, mz), mh, M["mould"])
    K.turned("PourCup", [(0.0, 0.0), (0.04, 0.0), (0.0, 0.004)], (mx, my, mz + mh * 1.07), 1.0,
             M["molten"], segments=24)
    cr = K.turned("Crucible", "crucible", (0, 0, 0), 0.32, M["crucible"], segments=48)
    cr.location = (mx - 0.33, my, mz + mh + 0.28)
    cr.rotation_euler = (0, math.radians(62), 0)
    melt = K.turned("Melt", [(0.0, 0.0), (0.125, 0.0), (0.0, 0.004)], (0, 0, 0.2), 1.0,
                    M["molten"], segments=32)
    melt.parent = cr
    stream_top = mz + mh + 0.3
    K.cylinder("PourStream", (mx - 0.02, my, (stream_top + mz + mh * 1.07) / 2), 0.02,
               stream_top - (mz + mh * 1.07), M["molten"], verts=12, rot=(0, 8, 0))
    K.box("CrucibleShank", (mx - 0.55, my, mz + mh + 0.2), (0.7, 0.04, 0.04), M["iron"],
          bevel=0.005, rot=(0, 28, 0))
    C.point_light("PourLight", (mx + 0.05, my - 0.25, mz + mh + 0.15), 25, radius=0.08,
                  color=(1.0, 0.55, 0.2))
    P.sparks((mx, my, mz + mh * 1.07), count=12, seed=13, direction=(0, -0.3, 1),
             spread=75, length=(0.03, 0.1), dist=(0.04, 0.26), radius=0.004)
    statuette("Statuette", (BX + 0.32, BY - 0.18, 0.9), M["bronze"], h=0.6)

    # big bronze bell hanging from the beam, right ----------------------------------
    GX, GY, GTOP, GH = 1.22, 1.6, 2.3, 0.92
    K.bell("Bell", (GX, GY, GTOP), GH, M["bronze"])
    K.chain("BellChain", (GX, GY, GTOP + 0.02), (GX, GY, 4.35), M["iron"], link=0.12,
            thick=0.016)
    # small finished bells and moulds on the floor (dark foreground)
    for i, (x, y, h) in enumerate(((0.75, 0.55, 0.3), (1.05, 0.2, 0.22))):
        K.turned(f"SmallBell{i}", "bell", (x, y, 0), h, M["bronze_old"], segments=48)
    for i, (x, y, h) in enumerate(((-0.7, 0.4, 0.34), (-0.3, 0.75, 0.26))):
        K.turned(f"Mould{i}", "mould", (x, y, 0), h, M["mould"], segments=48)
    sand_patch("SandPatch", (-0.35, 0.65), 1.05, 0.62, M["sand"])
    K.turned("Urn", "urn", (1.55, 2.1, 0), 0.6, M["bronze_old"], segments=48)

    # wall torches flanking the furnace ----------------------------------------
    for sx in (-1, 1):
        K.torch(f"Torch{sx}", (sx * 1.75, BACK - 0.25, 2.0), wood=M["wood"], iron=M["iron"],
                strength=7.0, light=45.0, lean=(0.0, 0.3))

    # rims on the bell + bench, a faint cool fill -----------------------------------
    C.area_light("RimBell", (0.4, 2.8, 1.9), (GX, GY, 1.7), 25, size=0.8,
                 color=(1.0, 0.55, 0.25))
    C.area_light("CoolFill", (-2.0, -3.0, 3.5), (0, 2, 1), 5, size=3.0, color=(0.6, 0.6, 0.8))

    # smoke + embers --------------------------------------------------------------
    K.haze((-W_HALF + 0.02, FRONT + 2, 0.03), (W_HALF - 0.02, BACK - 0.02, HEIGHT - 0.02),
           density=0.005, color=(1.0, 0.88, 0.75), anisotropy=0.45)
    K.embers((-0.7, FY - 1.6, 1.8), (0.7, FY - 0.9, 3.0), count=12, seed=11, radius=0.011)


def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="Filmic",
                        look="High Contrast", exposure=0.0, bounces=5)
    sc.cycles.volume_step_rate = 4.0
    sc.cycles.volume_max_steps = 256
    C.world_color(C.hex_lin("#020203"), 1.0)
    M = materials()
    build(M)
    cam = C.persp_camera((0.1, -2.9, 1.45), (0.05, FORGE_Y, 1.4), lens=26)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 5.2
    cam.data.dof.aperture_fstop = 2.8
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
