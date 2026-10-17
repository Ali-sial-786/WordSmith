"""bg_copper: a riverside workshop with a water wheel, warm afternoon
(Copper chapter).

Seen from across the river: a timber-and-plaster workshop on the far bank
with its big doors open on a glowing arched forge (the fire sits ~45-60 %
down the frame and is the focal point); a big wooden water wheel turns in
the river on the left; chunky trees frame the sides. Secondary light: low
golden afternoon sun from behind-right, rim-lighting roof, wheel and trees.

Top ~45 % = soft golden sky + tiled roof (calm); bottom = dark river with
warm reflections (the app draws its flame band over the bottom 40 %).

    blender -b --factory-startup -P scene_copper.py -- [--samples 80] [--scale 1.0]
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

SAMPLES = C.arg("samples", 80)
SCALE = C.arg("scale", 1.0)           # 1.0 = native 1080x2340 (post.py never upscales)
NAME = "bg_copper"

BANK_Z = 0.5          # bank height above the water
BANK_Y = 3.2          # river edge
BX, BY = 0.4, 5.0     # building front-centre
BW, BD, BH = 5.6, 5.4, 3.1
DOOR_W, DOOR_H = 2.3, 2.45


def materials():
    return dict(
        plaster=K.tex_material("Plaster", "Plaster007", scale=0.5, value=0.62, sat=0.8,
                               tint="#E8C49A", tint_fac=0.55, rough=(0.8, 1.0)),
        timber=K.tex_material("Timber", "Planks023A", scale=0.7, value=0.3, sat=0.9,
                              rough=(0.7, 0.95)),
        roof=K.tex_material("Roof", "RoofingTiles014B", scale=0.55, value=0.55, sat=0.85,
                            rough=(0.6, 0.95)),
        stone=K.tex_material("Stone", "Bricks102", scale=0.6, value=0.45, sat=0.7,
                             rough=(0.7, 1.0)),
        ground=K.tex_material("Ground", "Ground037", scale=0.35, value=0.5, sat=0.85,
                              rough=(0.8, 1.0)),
        floor=K.tex_material("Floor", "PavingStones142", scale=0.9, value=0.2, sat=0.5),
        wheel=K.tex_material("WheelWood", "Planks023A", scale=1.2, value=0.35, sat=0.9,
                             tint="#6A4A30", tint_fac=0.4, rough=(0.5, 0.85)),
        brick=K.tex_material("ForgeBrick", "Bricks094", scale=1.0, value=0.55, sat=0.9,
                             rough=(0.7, 1.0), soot=0.75, soot_range=(BANK_Z + 1.4, BANK_Z + 2.2)),
        chimney=K.tex_material("ChimneyBrick", "Bricks094", scale=1.0, value=0.3, sat=0.6),
        iron=P.iron_material("Iron", base="#62646A", rough=(0.3, 0.5), bump=0.12),
        door=K.tex_material("Door", "Planks023A", scale=1.0, value=0.42, sat=1.0,
                            tint="#9A6A44", tint_fac=0.4),
        leaves=K.flat_material("Leaves", "#3E5A26", rough=0.9),
        leaves2=K.flat_material("Leaves2", "#56702E", rough=0.9),
        bark=K.flat_material("Bark", "#3A2A1E", rough=0.9),
        water=river_material(),
    )


def river_material():
    m = C.new_material("River")
    n = C.NT(m)
    tc = n.texcoord()
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (0.35, 3.5, 1.0)     # ripples stretched across
    n.link(tc.outputs["Object"], mp.inputs[0])
    nz = n.node("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 9.0
    nz.inputs["Detail"].default_value = 8.0
    n.link(mp.outputs[0], nz.inputs["Vector"])
    bump = n.node("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.6
    n.link(nz.outputs[0], bump.inputs["Height"])
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = C.hex_lin("#0A100D")
    p.inputs["Roughness"].default_value = 0.3
    p.inputs["Specular IOR Level"].default_value = 0.6
    n.link(bump.outputs[0], p.inputs["Normal"])
    n.output(p.outputs[0])
    return m


def water_wheel(loc, radius=1.5, width=0.7, paddles=16, mat=None, iron=None):
    """Undershot wheel, face-on to the camera (axle along Y)."""
    x, y, z = loc
    objs = []
    for side in (-1, 1):
        bpy.ops.mesh.primitive_torus_add(major_radius=radius, minor_radius=0.07,
                                         major_segments=96, minor_segments=8,
                                         location=(x, y + side * width / 2, z),
                                         rotation=(math.pi / 2, 0, 0))
        rim = bpy.context.active_object
        rim.name = f"WheelRim{side}"
        rim.scale = (1, 1, 1.6)
        C.assign(rim, mat)
        objs.append(rim)
        bpy.ops.mesh.primitive_torus_add(major_radius=radius * 0.55, minor_radius=0.05,
                                         major_segments=64, minor_segments=8,
                                         location=(x, y + side * width / 2, z),
                                         rotation=(math.pi / 2, 0, 0))
        C.assign(bpy.context.active_object, mat)
        for k in range(8):
            a = 2 * math.pi * k / 8
            sp = K.box(f"Spoke{side}_{k}", (x + math.cos(a) * radius / 2, y + side * width / 2,
                                            z + math.sin(a) * radius / 2),
                       (radius, 0.08, 0.1), mat, bevel=0.01, rot=(0, -math.degrees(a), 0))
            objs.append(sp)
    for k in range(paddles):
        a = 2 * math.pi * k / paddles
        pd = K.box(f"Paddle{k}", (x + math.cos(a) * (radius + 0.08), y,
                                  z + math.sin(a) * (radius + 0.08)),
                   (0.42, width + 0.1, 0.05), mat, bevel=0.01,
                   rot=(0, -math.degrees(a) + 90, 0))
        objs.append(pd)
    hub = K.cylinder("Hub", (x, y, z), 0.22, width + 0.3, iron or mat, verts=24,
                     rot=(90, 0, 0))
    axle = K.cylinder("Axle", (x, y + 1.3, z), 0.09, 2.2, iron or mat, verts=16,
                      rot=(90, 0, 0))
    objs += [hub, axle]
    return objs


def tree(name, loc, size=2.0, seed=1, mats=None):
    rnd = random.Random(seed)
    x, y, z = loc
    trunk = K.cylinder(name + "Trunk", (x, y, z + size * 0.5), size * 0.08, size, mats["bark"],
                       verts=12)
    objs = [trunk]
    for i in range(5):
        r = size * rnd.uniform(0.38, 0.55)
        cx = x + rnd.uniform(-0.45, 0.45) * size
        cy = y + rnd.uniform(-0.3, 0.3) * size
        cz = z + size * rnd.uniform(1.0, 1.55)
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=3, radius=r, location=(cx, cy, cz))
        b = bpy.context.active_object
        b.name = f"{name}Blob{i}"
        tex = bpy.data.textures.new(f"{name}_n{i}", "CLOUDS")
        tex.noise_scale = 0.6
        d = b.modifiers.new("Lumpy", "DISPLACE")
        d.texture = tex
        d.strength = r * 0.25
        C.shade_smooth(b)
        C.assign(b, mats["leaves"] if i % 2 else mats["leaves2"])
        objs.append(b)
    return objs


def build(M):
    # river + banks ---------------------------------------------------------
    K.plane("River", (0, -10, 0), (80, 30), mat=M["water"])
    K.plane("Riverbed", (0, -10, -1.2), (80, 30), mat=K.flat_material("Bed", "#0A0C08"))
    K.box("Bank", (0, BANK_Y + 15, BANK_Z / 2 - 0.5), (80, 30, BANK_Z + 1.0), M["ground"], bevel=0)
    K.box("Embankment", (0, BANK_Y - 0.15, BANK_Z / 2 - 0.4), (80, 0.3, BANK_Z + 0.8),
          M["stone"], bevel=0.02)
    # near bank strip (bottom of frame), very dark
    K.box("NearBank", (0, -6.2, -0.3), (40, 1.6, 0.8), M["ground"], bevel=0.1)

    # the workshop ------------------------------------------------------------
    z0 = BANK_Z
    yc = BY + BD / 2
    K.box("Plinth", (BX, yc, z0 + 0.25), (BW + 0.2, BD + 0.2, 0.5), M["stone"], bevel=0.03)
    # front wall with the door opening
    side_w = (BW - DOOR_W) / 2
    for sx in (-1, 1):
        K.box(f"Front{sx}", (BX + sx * (DOOR_W / 2 + side_w / 2), BY, z0 + 0.5 + BH / 2),
              (side_w, 0.25, BH), M["plaster"], bevel=0)
        K.box(f"Side{sx}", (BX + sx * BW / 2, yc, z0 + 0.5 + BH / 2), (0.25, BD, BH),
              M["plaster"], bevel=0)
    K.box("FrontTop", (BX, BY, z0 + 0.5 + (DOOR_H + BH) / 2), (DOOR_W, 0.25, BH - DOOR_H),
          M["plaster"], bevel=0)
    K.box("BackWallB", (BX, BY + BD, z0 + 0.5 + BH / 2), (BW, 0.25, BH), M["plaster"], bevel=0)
    # gable (triangle) on the front and back
    ridge = BH + (BW / 2) * math.tan(math.radians(38))
    for gy in (BY, BY + BD):
        verts = [(BX - BW / 2, gy - 0.12, z0 + 0.5 + BH), (BX + BW / 2, gy - 0.12, z0 + 0.5 + BH),
                 (BX, gy - 0.12, z0 + 0.5 + ridge), (BX - BW / 2, gy + 0.12, z0 + 0.5 + BH),
                 (BX + BW / 2, gy + 0.12, z0 + 0.5 + BH), (BX, gy + 0.12, z0 + 0.5 + ridge)]
        g = C.mesh_object(f"Gable{gy}", verts, [(0, 1, 2), (5, 4, 3), (0, 3, 4, 1), (1, 4, 5, 2),
                                                (2, 5, 3, 0)], smooth=False)
        C.assign(g, M["plaster"])
    # timber frame on the front
    for i, x in enumerate((-BW / 2 + 0.1, -DOOR_W / 2 - 0.1, DOOR_W / 2 + 0.1, BW / 2 - 0.1)):
        K.box(f"FPost{i}", (BX + x, BY - 0.14, z0 + 0.5 + BH / 2), (0.2, 0.08, BH), M["timber"],
              bevel=0.02)
    K.box("FBeam", (BX, BY - 0.14, z0 + 0.5 + BH - 0.1), (BW, 0.08, 0.2), M["timber"], bevel=0.02)
    K.box("FLintel", (BX, BY - 0.14, z0 + 0.5 + DOOR_H + 0.1), (DOOR_W + 0.4, 0.08, 0.2),
          M["timber"], bevel=0.02)
    for sx in (-1, 1):   # diagonal braces
        K.box(f"Brace{sx}", (BX + sx * (BW / 2 - side_w / 2 - 0.05), BY - 0.14, z0 + 0.5 + 1.9),
              (0.14, 0.07, 1.6), M["timber"], bevel=0.01, rot=(0, sx * 35, 0))
    # roof: two slabs + ridge
    slope = math.radians(38)
    half = (BW / 2 + 0.45) / math.cos(slope)
    for sx in (-1, 1):
        K.box(f"Roof{sx}", (BX + sx * (BW / 4 + 0.22), yc, z0 + 0.5 + BH + (ridge - BH) / 2 + 0.12),
              (half, BD + 0.9, 0.14), M["roof"], bevel=0.02,
              rot=(0, sx * math.degrees(slope), 0))
    K.box("Ridge", (BX, yc, z0 + 0.5 + ridge + 0.18), (0.25, BD + 0.9, 0.18), M["roof"], bevel=0.03)
    # chimney
    K.box("Chimney", (BX + 0.0, BY + BD - 0.9, z0 + 0.5 + ridge + 0.4), (0.8, 0.8, 2.2),
          M["chimney"], bevel=0.02)
    # door leaves swung open outwards
    for sx in (-1, 1):
        lf = K.box(f"Leaf{sx}", (BX + sx * (DOOR_W / 2 + 0.25), BY - 0.55, z0 + 0.5 + DOOR_H / 2),
                   (0.07, DOOR_W / 2, DOOR_H - 0.05), M["door"], bevel=0.01,
                   rot=(0, 0, sx * 20))
    # interior: floor, the forge on the back wall, an anvil
    K.plane("ShopFloor", (BX, yc, z0 + 0.51), (BW - 0.3, BD - 0.3), mat=M["floor"])
    K.arched_forge((BX, BY + BD - 1.6, z0 + 0.5), w=2.5, d=1.45, h=2.0, mouth_w=1.5,
                   mouth_h=1.1, mouth_z=0.7, brick=M["brick"], iron=M["iron"],
                   stone=M["stone"], chimney=M["chimney"], chimney_top=z0 + 0.5 + ridge,
                   fire_strength=8.0, light=320.0, seed=5)
    K.stump("Stump", (BX + 0.75, BY + 1.6, z0 + 0.5), radius=0.32, height=0.42,
            mat=M["wheel"])
    anv = P.anvil("Anvil", M["iron"], depth=1.15, location=(BX + 0.75, BY + 1.6, z0 + 0.92),
                  rot_z=math.radians(-20))
    anv.scale = (0.26, 0.26, 0.26)
    # a lantern hanging beside the door
    lx, ly, lz = BX + DOOR_W / 2 + 0.45, BY - 0.35, z0 + 0.5 + DOOR_H + 0.05
    K.box("LanternArm", (lx, ly + 0.17, lz + 0.32), (0.04, 0.38, 0.04), M["iron"], bevel=0.005)
    K.box("LanternTop", (lx, ly, lz + 0.2), (0.2, 0.2, 0.06), M["iron"], bevel=0.01)
    K.box("LanternGlass", (lx, ly, lz), (0.16, 0.16, 0.3),
          K.flat_material("LanternGlow", "#000000", emission=(C.hex_lin("#FFB04A"), 6.0)),
          bevel=0.01)
    K.box("LanternBase", (lx, ly, lz - 0.18), (0.2, 0.2, 0.05), M["iron"], bevel=0.01)
    C.point_light("LanternLight", (lx, ly - 0.1, lz), 25, radius=0.1, color=(1.0, 0.6, 0.25))
    # warm glow spilling out of the door onto the yard + water
    C.area_light("DoorGlow", (BX, BY + 0.3, z0 + 1.6), (BX, BY - 4, z0), 110,
                 size=DOOR_W * 0.9, size_y=DOOR_H * 0.8, shape="RECTANGLE",
                 color=(1.0, 0.45, 0.15))

    # water wheel (left, in the river) on a stone pier -----------------------
    water_wheel((BX - 3.3, BANK_Y - 0.7, 1.0), radius=1.55, width=0.75, mat=M["wheel"],
                iron=M["iron"])
    K.box("Pier", (BX - 3.3, BANK_Y + 0.5, 0.6), (0.9, 1.4, 1.6), M["stone"], bevel=0.04)

    # trees and a wooden jetty --------------------------------------------------
    tree("TreeL", (-5.6, 7.5, BANK_Z), size=3.4, seed=2, mats=M)
    tree("TreeR", (4.6, 8.5, BANK_Z), size=3.0, seed=5, mats=M)
    tree("TreeR2", (6.5, 13.0, BANK_Z), size=3.8, seed=9, mats=M)
    K.box("Jetty", (BX + 1.2, BANK_Y - 0.4, BANK_Z - 0.05), (2.2, 0.8, 0.08), M["timber"],
          bevel=0.01)
    for i, x in enumerate((BX + 0.25, BX + 2.15)):
        K.cylinder(f"JettyPost{i}", (x, BANK_Y - 0.75, 0.0), 0.07, 1.2, M["timber"], verts=10)
    K.barrel("JettyBarrel", (BX + 1.9, BANK_Y - 0.35, BANK_Z), radius=0.25, height=0.55,
             wood=M["door"], iron=M["iron"])

    # light: low golden sun from behind-right + sky ---------------------------
    C.sun_light("Sun", (-72, 0, -32), 3.5, angle=2.5, color=(1.0, 0.72, 0.45))


def sky_world():
    """Golden-hour sky: deep blue-violet zenith -> peach -> gold horizon, a warm
    glow towards the (off-frame, right) sun and faint cloud bands."""
    w = bpy.context.scene.world
    n = C.NT(w)
    tc = n.node("ShaderNodeTexCoord")
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Generated"], sep.inputs[0])
    # note: for the world, Generated is the raw view direction (z = sin elevation)
    col = n.ramp(sep.outputs[2], [(0.0, C.hex_lin("#F4C27C")), (0.07, C.hex_lin("#EAAE72")),
                                  (0.2, C.hex_lin("#C88E72")), (0.4, C.hex_lin("#6A5A6E")),
                                  (0.7, C.hex_lin("#26283E"))])
    # sun glow
    norm = n.node("ShaderNodeVectorMath", _operation="NORMALIZE")
    n.link(tc.outputs["Generated"], norm.inputs[0])
    dot = n.node("ShaderNodeVectorMath", _operation="DOT_PRODUCT")
    n.link(norm.outputs[0], dot.inputs[0])
    dot.inputs[1].default_value = (0.5, 0.8, 0.31)
    glow = n.math("POWER", n.maprange(dot.outputs["Value"], 0.5, 1.0, 0.0, 1.0), 3.0)
    col = n.mix(col, C.hex_lin("#FFD08A"), n.math("MULTIPLY", glow, 0.8), blend="ADD")
    # faint cloud bands (stretched noise) in the upper sky
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (1.2, 1.2, 9.0)
    n.link(norm.outputs[0], mp.inputs[0])
    nz = n.node("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 2.0
    nz.inputs["Detail"].default_value = 5.0
    n.link(mp.outputs[0], nz.inputs["Vector"])
    cloud = n.maprange(nz.outputs[0], 0.5, 0.75, 0.0, 1.0)
    band = n.maprange(sep.outputs[2], 0.04, 0.12, 0.0, 1.0)
    band = n.math("MULTIPLY", band, n.maprange(sep.outputs[2], 0.3, 0.5, 1.0, 0.0))
    col = n.mix(col, C.hex_lin("#F2B48A"), n.math("MULTIPLY", n.math("MULTIPLY", cloud, band), 0.5))
    bg = n.node("ShaderNodeBackground")
    n.link(col, bg.inputs[0])
    bg.inputs[1].default_value = 0.55
    out = n.node("ShaderNodeOutputWorld")
    n.link(bg.outputs[0], out.inputs[0])


def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="Filmic",
                        look="High Contrast", exposure=0.0, bounces=5)
    sky_world()
    M = materials()
    build(M)
    cam = C.persp_camera((0.6, -6.6, 2.2), (-0.35, 6.0, 2.2), lens=28)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 12.5
    cam.data.dof.aperture_fstop = 4.0
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
