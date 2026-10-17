"""bg_iron: a mountain forge cut into the rock, at night (Iron chapter).

A rugged smithy hewn out of a mountainside: an open hearth of rough stone
on the left, coals and flames under a rock hood, is the warm focal point
(~45-58 % down the frame). Beside it a ragged cave mouth looks out on a
cold blue night: snowy peaks, stars and a small moon, whose light falls in
as a pale blue shaft through the smoke. Rough iron
everywhere: a heavy anvil, a hanging chain and hook, bars leaning on the
wall and a heap of iron ore under the opening.

Top ~45 % (rock ceiling, chain, chimney) and the bottom (floor) stay dark.

    blender -b --factory-startup -P scene_iron.py -- [--samples 80] [--scale 0.667]
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
SCALE = C.arg("scale", 0.667)
NAME = "bg_iron"

W_HALF, BACK, FRONT, HEIGHT = 3.0, 4.0, -6.0, 5.5
HX, HY = -0.95, BACK - 0.75                 # open hearth, left of centre
OP_CX, OP_CZ, OP_RX, OP_RZ = 1.2, 1.5, 0.95, 1.0   # the cave mouth (ellipse) in the back wall


def materials():
    return dict(
        rock=K.tex_material("Rock", "Rock030", scale=0.22, value=0.45, sat=0.7,
                            rough=(0.7, 1.0), normal=1.2, soot=0.8, soot_range=(2.2, 5.0)),
        forge_rock=K.tex_material("ForgeRock", "Rock030", scale=0.6, value=0.5, sat=0.7,
                                  rough=(0.7, 1.0), normal=1.2, soot=0.85,
                                  soot_range=(1.5, 2.6)),
        hood=K.tex_material("Hood", "Rock030", scale=0.4, value=0.2, sat=0.5, rough=(0.8, 1.0),
                            soot=0.7, soot_range=(1.8, 3.2)),
        ledge=K.tex_material("Ledge", "Rock030", scale=0.12, value=0.3, sat=0.3, tint="#B8C4E0",
                             tint_fac=0.5, rough=(0.7, 1.0)),
        floor=K.tex_material("Floor", "PavingStones142", scale=0.7, value=0.16, sat=0.4,
                             tint="#6A6A70", tint_fac=0.3, rough=(0.55, 0.95), normal=0.7),
        snow=K.tex_material("Snow", "Rock030", scale=0.05, value=1.0, sat=0.2,
                            tint="#C8D4F0", tint_fac=0.6, rough=(0.6, 0.9),
                            emission=(C.hex_lin("#8EA4D8"), 0.12)),
        beam=K.tex_material("Beam", "Planks023A", scale=0.6, value=0.22, sat=0.7,
                            rough=(0.7, 0.95)),
        stump=K.tex_material("Stump", "Planks023A", scale=1.4, value=0.35, sat=0.9,
                             tint="#7A5038", tint_fac=0.5),
        iron=P.iron_material("Iron", base="#5A5C62", rough=(0.35, 0.6), bump=0.2),
        rough_iron=P.iron_material("RoughIron", base="#4A4440", rough=(0.55, 0.85), bump=0.35,
                                   facet_scale=9.0),
        ore=K.tex_material("Ore", "Rock030", scale=2.0, value=0.35, sat=1.2, tint="#8A4A30",
                           tint_fac=0.5, rough=(0.6, 1.0), normal=1.5),
        handle=P.wood_material("Handle", value=0.7, scale=3.0),
        wood=P.wood_material("Wood", value=0.45, scale=1.2),
    )


def rugged(ob, strength=0.12, scale=0.6, levels=4):
    """Subdivide and displace a slab so it reads as hewn rock, not a box."""
    sub = ob.modifiers.new("Sub", "SUBSURF")
    sub.subdivision_type = "SIMPLE"
    sub.levels = sub.render_levels = levels
    tex = bpy.data.textures.new(ob.name + "_rock", "CLOUDS")
    tex.noise_scale = scale
    tex.noise_depth = 3
    d = ob.modifiers.new("Rough", "DISPLACE")
    d.texture = tex
    d.strength = strength
    d.mid_level = 0.5
    d.texture_coords = "GLOBAL"
    return ob


def apply_all(ob):
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    for mod in list(ob.modifiers):
        bpy.ops.object.modifier_apply(modifier=mod.name)
    ob.select_set(False)


def mouth_r(a):
    """Ragged radius factor of the cave mouth at angle a."""
    return 1.0 + 0.12 * math.sin(3 * a + 0.7) + 0.07 * math.sin(7 * a + 2.1) + 0.04 * math.sin(13 * a)


def cave_wall(M):
    """The back wall: a dense grid with a ragged cave mouth removed, then
    displaced and solidified into a thick slab of hewn rock."""
    import bmesh
    T = 0.7
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=150, y_subdivisions=110, size=1,
                                    location=(0, BACK + 0.05, HEIGHT / 2),
                                    rotation=(math.pi / 2, 0, 0))
    wall = bpy.context.active_object
    wall.name = "BackWall"
    wall.scale = (2 * W_HALF + 0.6, HEIGHT + 0.4, 1)
    C.apply_transform(wall)
    bm = bmesh.new()
    bm.from_mesh(wall.data)
    kill = []
    for f in bm.faces:
        c = f.calc_center_median() + wall.location
        dx, dz = (c.x - OP_CX) / OP_RX, (c.z - OP_CZ) / OP_RZ
        a = math.atan2(dz, dx)
        if math.hypot(dx, dz) < mouth_r(a) and c.z > 0.55:
            kill.append(f)
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bm.to_mesh(wall.data)
    bm.free()
    tex = bpy.data.textures.new("backwall_rock", "CLOUDS")
    tex.noise_scale = 0.45
    tex.noise_depth = 4
    d = wall.modifiers.new("Rough", "DISPLACE")
    d.texture = tex
    d.strength = 0.35
    d.texture_coords = "GLOBAL"
    d.direction = "Y"
    so = wall.modifiers.new("Thick", "SOLIDIFY")
    so.thickness = T
    so.offset = -1.0
    C.shade_smooth(wall)
    C.assign(wall, M["rock"])
    return wall


def boulder(name, loc, size, mat, seed=1):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=3, radius=1.0, location=loc)
    ob = bpy.context.active_object
    ob.name = name
    rnd = random.Random(seed)
    ob.scale = (size * rnd.uniform(0.8, 1.3), size * rnd.uniform(0.7, 1.1), size * rnd.uniform(0.5, 0.8))
    ob.rotation_euler = (rnd.uniform(0, 3), rnd.uniform(0, 3), rnd.uniform(0, 3))
    tex = bpy.data.textures.new(name + "_n", "VORONOI")
    tex.noise_scale = 0.4
    d = ob.modifiers.new("Lumpy", "DISPLACE")
    d.texture = tex
    d.strength = size * 0.5
    C.shade_smooth(ob)
    C.assign(ob, mat)
    return ob


def build(M):
    # rock shell ---------------------------------------------------------------
    K.box("Floor", (0, (BACK + FRONT) / 2, -0.1), (2 * W_HALF, BACK - FRONT, 0.2), M["floor"],
          bevel=0)
    K.box("FrontWall", (0, FRONT - 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT),
          M["rock"], bevel=0)
    for sx in (-1, 1):
        rugged(K.box(f"SideWall{sx}", (sx * (W_HALF + 0.2), (BACK + FRONT) / 2, HEIGHT / 2),
                     (0.4, BACK - FRONT, HEIGHT), M["rock"], bevel=0), strength=0.3)
    rugged(K.box("Ceiling", (0, (BACK + FRONT) / 2, HEIGHT + 0.2), (2 * W_HALF + 0.6, BACK - FRONT, 0.4),
                 M["rock"], bevel=0), strength=0.5, scale=0.9)
    cave_wall(M)

    # open hearth of rough stone, left: coals, flames, a rock hood ---------------
    K.hearth((HX, HY, 0), w=1.6, d=1.1, h=0.8, brick=M["forge_rock"], hood=M["hood"],
             coal_strength=5.0, light_energy=200, hood_top=3.0, flue_top=HEIGHT)
    K.fire((HX, HY - 0.05, 0.86), spread=(0.42, 0.16), count=9, height=0.85, width=0.16,
           seed=21, strength=5.5, name="HearthFire")
    K.flame_volume((HX, HY - 0.05, 1.2), size=(0.55, 0.32, 0.45), strength=1.4, name="HearthGlow")
    K.box("Fireback", (HX, BACK - 0.12, 1.6), (1.7, 0.1, 1.8), M["hood"], bevel=0.01)
    bar = K.box("HotBar", (HX + 0.35, HY - 0.45, 0.9), (0.04, 1.0, 0.04), K.hot_bar_material("HotBar"),
                bevel=0.006, rot=(-6, 0, -22))

    # outside: snowy peaks under the night sky ----------------------------------
    K.plane("Ledge", (1.5, 14, 0.1), (40, 20), mat=M["ledge"])
    for i, (x, y, r, h) in enumerate(((6, 60, 14, 7.5), (14, 75, 18, 10.5), (3, 90, 22, 11),
                                      (22, 95, 24, 9), (10, 45, 8, 4.5))):
        bpy.ops.mesh.primitive_cone_add(vertices=7, radius1=r, depth=h, location=(x, y, h / 2 - 1),
                                        rotation=(0, 0, i * 0.7))
        pk = bpy.context.active_object
        pk.name = f"Peak{i}"
        sub = pk.modifiers.new("Sub", "SUBSURF")
        sub.subdivision_type = "SIMPLE"
        sub.levels = sub.render_levels = 4
        tex = bpy.data.textures.new(f"peak{i}", "CLOUDS")
        tex.noise_scale = 3.0
        d = pk.modifiers.new("Rough", "DISPLACE")
        d.texture = tex
        d.strength = 1.6
        C.assign(pk, M["snow"])

    # rough iron: anvil on a stump, chain + hook, bars, ore ------------------------
    AX, AY = -0.72, 0.3
    K.stump("Stump", (AX, AY, 0), radius=0.38, height=0.45, mat=M["stump"])
    anv = P.anvil("Anvil", M["rough_iron"], depth=1.15, location=(AX, AY, 0.45),
                  rot_z=math.radians(205))
    anv.scale = (0.3, 0.3, 0.3)
    hm = P.hammer("AnvilHammer", M["iron"], M["handle"], head_len=0.26, head_w=0.09,
                  handle_len=0.5, pein_axis="z", handle_r=0.02)
    hm.location = (AX + 0.05, AY - 0.05, 0.99)
    hm.rotation_euler = (math.radians(90), 0, math.radians(30))
    CX, CY = 0.85, 2.3                      # chain + hook, seen against the cave mouth
    K.chain("HangChain", (CX, CY, 1.85), (CX, CY, HEIGHT), M["rough_iron"], link=0.13, thick=0.02)
    bpy.ops.mesh.primitive_torus_add(major_radius=0.1, minor_radius=0.022, major_segments=32,
                                     minor_segments=8, location=(CX, CY, 1.73),
                                     rotation=(math.pi / 2, 0, 0))
    hook = bpy.context.active_object
    hook.name = "Hook"
    for v in hook.data.vertices:          # open the ring into a hook
        if v.co.x > 0.03 and v.co.y > 0.0:
            v.co.x = 0.03
    C.assign(hook, M["rough_iron"])
    for i in range(6):                    # bars leaning on the wall, right of the mouth
        x = 2.25 + i * 0.08
        K.box(f"Bar{i}", (x, BACK - 0.45, 0.95), (0.035, 0.035, 1.9), M["rough_iron"], bevel=0.006,
              rot=(-9 - i % 3, (i - 3) * 1.5, 0))
    for i in range(16):                   # iron ore heaped by the mouth
        rnd = random.Random(i)
        boulder(f"Ore{i}", (0.55 + rnd.uniform(-0.35, 0.35), BACK - 0.6 + rnd.uniform(-0.25, 0.2),
                            0.05 + rnd.uniform(0, 0.1)), rnd.uniform(0.06, 0.12), M["ore"], seed=40 + i)
    K.barrel("Barrel", (1.3, 0.6, 0), radius=0.36, height=0.8, wood=M["wood"],
             iron=M["rough_iron"], water=K.water_material("Water"))

    # light: cold moonlight through the mouth, warm rims, faint fill ---------------
    sun = C.sun_light("Moon", (0, 0, 0), 0.7, angle=1.0, color=(0.55, 0.68, 1.0))
    sun.rotation_euler = Vector((-0.22, -1.0, -0.5)).to_track_quat("-Z", "Y").to_euler()
    C.area_light("MouthSky", (OP_CX, BACK + 0.9, OP_CZ), (OP_CX - 0.5, 0.5, 0.6), 30,
                 size=OP_RX * 1.6, size_y=OP_RZ * 1.6, shape="RECTANGLE", color=(0.45, 0.6, 1.0))
    C.area_light("RimAnvil", (-0.3, 2.0, 1.4), (AX, AY, 0.85), 30, size=0.8,
                 color=(1.0, 0.5, 0.2))
    C.area_light("CoolFill", (1.5, -3.0, 3.0), (0, 2, 1), 5, size=3.0, color=(0.5, 0.6, 1.0))

    # smoke (shows the moon shaft) + embers ---------------------------------------
    K.haze((-W_HALF + 0.05, FRONT + 2, 0.05), (W_HALF - 0.05, BACK - 0.45, HEIGHT - 0.1),
           density=0.007, color=(0.9, 0.92, 1.0), anisotropy=0.5)
    K.embers((HX - 0.5, HY - 0.5, 1.5), (HX + 0.5, HY + 0.1, 2.6), count=12, seed=21,
             radius=0.011)


def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="Filmic",
                        look="High Contrast", exposure=0.0, bounces=5)
    sc.cycles.volume_step_rate = 8.0
    sc.cycles.volume_max_steps = 256
    K.night_world(zenith="#04060E", horizon="#1C2A50", ground="#05060A", strength=1.0,
                  stars=0.8, star_scale=260.0, moon=(0.105, 1.0, 0.115), moon_size=2.2,
                  moon_strength=5.0, glow_color="#4A6AB8", glow_dir=(0.2, 1.0, 0.0),
                  glow_power=6.0, glow_strength=0.8)
    M = materials()
    build(M)
    cam = C.persp_camera((0.15, -2.9, 1.45), (0.1, BACK - 1.5, 1.4), lens=26)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 5.4
    cam.data.dof.aperture_fstop = 2.8
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
