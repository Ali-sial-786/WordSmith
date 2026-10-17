"""bg_tin: a village smithy at dawn (Tin chapter).

Inside a small timber-framed smithy: an open brick hearth with a heap of
hot coals and live flames under a sooty hood is the main light (left/centre,
~45-60 % down the frame). Secondary light: the door on the right stands open
on a pink-and-peach dawn sky; low sun spills in across the floor through a
little morning haze. A couple of chickens peck about outside, horseshoes
hang on the wall, an anvil stands in silhouette in the foreground.

Top ~45 % (beams, hood, upper wall) and the bottom (floor) stay calm.

    blender -b --factory-startup -P scene_tin.py -- [--samples 80] [--scale 0.667]
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
SCALE = C.arg("scale", 0.667)
NAME = "bg_tin"

W_HALF, BACK, FRONT, HEIGHT = 2.6, 4.0, -5.0, 4.6
DOOR_X0, DOOR_X1, DOOR_H = 0.75, 1.85, 2.25


def materials():
    return dict(
        plaster=K.tex_material("Plaster", "Plaster007", scale=0.5, value=0.42, sat=0.8,
                               tint="#C8A88A", tint_fac=0.6, rough=(0.8, 1.0),
                               soot=0.7, soot_range=(2.2, 4.6), soot_color="#1A120C"),
        timber=K.tex_material("Timber", "Planks023A", scale=0.7, value=0.25, sat=0.9,
                              rough=(0.7, 0.95)),
        floor=K.tex_material("Floor", "PavingStones142", scale=0.9, value=0.2, sat=0.5,
                             tint="#7A6252", tint_fac=0.3, rough=(0.55, 0.95), normal=0.6),
        brick=K.tex_material("HearthBrick", "Bricks094", scale=1.0, value=0.5, sat=0.9,
                             rough=(0.7, 1.0), soot=0.6, soot_range=(0.4, 0.95)),
        hood=K.tex_material("Hood", "Bricks094", scale=1.0, value=0.18, sat=0.4,
                            rough=(0.8, 1.0), soot=0.6, soot_range=(2.0, 3.5)),
        ground=K.tex_material("Ground", "Ground037", scale=0.4, value=0.55, sat=0.8,
                              rough=(0.8, 1.0)),
        roof=K.tex_material("Roof", "RoofingTiles014B", scale=0.6, value=0.5, sat=0.8,
                            rough=(0.7, 1.0)),
        cottage=K.tex_material("Cottage", "Plaster007", scale=0.6, value=0.55, sat=0.8,
                               tint="#E0C0A0", tint_fac=0.5),
        door=K.tex_material("Door", "Planks023A", scale=1.0, value=0.4, sat=1.0,
                            tint="#9A6A44", tint_fac=0.4),
        stump=K.tex_material("Stump", "Planks023A", scale=1.4, value=0.42, sat=1.0,
                             tint="#8A5A38", tint_fac=0.5),
        iron=P.iron_material("Iron", base="#62646A", rough=(0.3, 0.5), bump=0.12),
        wood=P.wood_material("Wood", value=0.55, scale=1.2),
        handle=P.wood_material("Handle", value=0.8, scale=3.0),
        water=K.water_material("Water"),
    )


def chicken(name, loc, rot_z=0.0, white=True, peck=False):
    """Chunky low-poly chicken (~0.35 tall)."""
    body_m = K.flat_material(name + "Body", "#EDE6DA" if white else "#9A5A2E", rough=0.9)
    red = K.flat_material(name + "Comb", "#C8302A", rough=0.7)
    beak_m = K.flat_material(name + "Beak", "#E0A030", rough=0.6)
    root = bpy.data.objects.new(name, None)
    C.link(root)
    parts = []
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=2, radius=1.0, location=(0, 0, 0.17))
    b = bpy.context.active_object
    b.scale = (0.17, 0.11, 0.12)
    C.assign(b, body_m)
    parts.append(b)
    hz = 0.2 if peck else 0.32
    hx = 0.2 if peck else 0.13
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=2, radius=0.065, location=(hx, 0, hz))
    h = bpy.context.active_object
    C.assign(h, body_m)
    parts.append(h)
    bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=0.022, depth=0.06,
                                    location=(hx + 0.08, 0, hz - 0.01), rotation=(0, math.pi / 2, 0))
    k = bpy.context.active_object
    C.assign(k, beak_m)
    parts.append(k)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.03,
                                          location=(hx, 0, hz + 0.06))
    cm = bpy.context.active_object
    cm.scale = (1.3, 0.5, 1.0)
    C.assign(cm, red)
    parts.append(cm)
    bpy.ops.mesh.primitive_cone_add(vertices=6, radius1=0.08, depth=0.16,
                                    location=(-0.17, 0, 0.27), rotation=(0, -0.6, 0))
    t = bpy.context.active_object
    t.scale = (1, 0.45, 1)
    C.assign(t, body_m)
    parts.append(t)
    for sy in (-0.04, 0.04):
        bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=0.008, depth=0.08,
                                            location=(0.0, sy, 0.04))
        lg = bpy.context.active_object
        C.assign(lg, beak_m)
        parts.append(lg)
    for p_ in parts:
        C.shade_smooth(p_)
        p_.parent = root
    root.location = loc
    root.rotation_euler = (0, 0, rot_z)
    return root


def horseshoe(name, loc, mat, size=0.11):
    bpy.ops.mesh.primitive_torus_add(major_radius=size, minor_radius=size * 0.18,
                                     major_segments=32, minor_segments=8, location=(0, 0, 0))
    ob = bpy.context.active_object
    ob.name = name
    # open the bottom of the ring: delete verts in the lower 70 degrees
    me = ob.data
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(me)
    kill = [v for v in bm.verts if math.atan2(v.co.y, v.co.x) < -math.pi / 2 + 0.6 and
            math.atan2(v.co.y, v.co.x) > -math.pi / 2 - 0.6]
    bmesh.ops.delete(bm, geom=kill, context="VERTS")
    bm.to_mesh(me)
    bm.free()
    ob.rotation_euler = (math.pi / 2, 0, 0)
    ob.location = loc
    C.assign(ob, mat)
    C.shade_smooth(ob)
    return ob


def build(M):
    # shell: floor, side walls, back wall with a door opening --------------
    K.plane("Floor", (0, (BACK + FRONT) / 2, 0), (2 * W_HALF, BACK - FRONT), mat=M["floor"])
    K.box("FrontWall", (0, FRONT - 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT),
          M["plaster"], bevel=0)      # behind the camera: keeps the sky out
    for sx in (-1, 1):
        K.box(f"SideWall{sx}", (sx * (W_HALF + 0.15), (BACK + FRONT) / 2, HEIGHT / 2),
              (0.3, BACK - FRONT, HEIGHT), M["plaster"], bevel=0)
    K.box("BackL", ((-W_HALF + DOOR_X0) / 2, BACK + 0.15, HEIGHT / 2),
          (DOOR_X0 + W_HALF, 0.3, HEIGHT), M["plaster"], bevel=0)
    K.box("BackR", ((W_HALF + DOOR_X1) / 2 + 0.15, BACK + 0.15, HEIGHT / 2),
          (W_HALF - DOOR_X1 + 0.3, 0.3, HEIGHT), M["plaster"], bevel=0)
    K.box("BackTop", ((DOOR_X0 + DOOR_X1) / 2, BACK + 0.15, (DOOR_H + HEIGHT) / 2),
          (DOOR_X1 - DOOR_X0, 0.3, HEIGHT - DOOR_H), M["plaster"], bevel=0)
    K.box("Ceiling", (0, (BACK + FRONT) / 2, HEIGHT + 0.1), (2 * W_HALF + 0.6, BACK - FRONT, 0.2),
          M["timber"], bevel=0)
    # timber framing
    for i, y in enumerate((3.2, 1.4, -0.4)):
        K.box(f"Beam{i}", (0, y, 3.55), (2 * W_HALF, 0.28, 0.3), M["timber"], bevel=0.03)
    for i, x in enumerate((-W_HALF + 0.12, -0.1, DOOR_X0 - 0.09, DOOR_X1 + 0.09, W_HALF - 0.12)):
        K.box(f"Post{i}", (x, BACK - 0.02, HEIGHT / 2), (0.18, 0.12, HEIGHT), M["timber"],
              bevel=0.02)
    K.box("Lintel", ((DOOR_X0 + DOOR_X1) / 2, BACK - 0.02, DOOR_H + 0.09),
          (DOOR_X1 - DOOR_X0 + 0.36, 0.14, 0.18), M["timber"], bevel=0.02)
    K.box("Rail", (-1.3, BACK - 0.02, 2.75), (2.6, 0.12, 0.16), M["timber"], bevel=0.02)
    # door leaf, swung open inwards against the right wall
    leaf = K.box("DoorLeaf", (DOOR_X1 + 0.02, BACK - 0.55, DOOR_H / 2 - 0.02),
                 (0.07, DOOR_X1 - DOOR_X0 - 0.04, DOOR_H - 0.06), M["door"], bevel=0.015)
    leaf.rotation_euler = (0, 0, math.radians(-12))

    # open hearth with live flames (left of centre) ------------------------
    HX, HY = -0.75, 3.15
    K.hearth((HX, HY, 0), w=1.8, d=1.2, h=0.8, brick=M["brick"], hood=M["hood"],
             coal_strength=6.0, light_energy=330, hood_top=3.3, flue_top=HEIGHT)
    K.fire((HX, HY - 0.05, 0.86), spread=(0.45, 0.18), count=9, height=0.85, width=0.17,
           seed=8, strength=6.5, name="HearthFire")
    K.flame_volume((HX, HY - 0.05, 1.2), size=(0.6, 0.35, 0.45), strength=4.0,
                   name="HearthGlow")

    # horseshoes on the rail, anvil + stump, barrel -------------------------
    for i in range(5):
        horseshoe(f"Shoe{i}", (-2.25 + i * 0.27, BACK - 0.1, 2.55), M["iron"])
    AX, AY = 1.2, 0.5
    K.stump("Stump", (AX, AY, 0), radius=0.34, height=0.45, mat=M["stump"])
    anv = P.anvil("Anvil", M["iron"], depth=1.15, location=(AX, AY, 0.45),
                  rot_z=math.radians(-160))
    anv.scale = (0.27, 0.27, 0.27)
    K.barrel("Barrel", (-1.95, 1.35, 0), radius=0.38, height=0.82, wood=M["wood"],
             iron=M["iron"], water=M["water"])

    # outside: ground, a cottage, a fence, hills, chickens ------------------
    K.plane("Ground", (0, 14, -0.01), (60, 20), mat=M["ground"])
    K.box("Cottage", (5.6, 30.0, 1.3), (3.2, 2.6, 2.6), M["cottage"], bevel=0.05)
    bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=2.6, depth=1.6,
                                    location=(5.6, 30.0, 3.4), rotation=(0, 0, math.pi / 4))
    rf = bpy.context.active_object
    rf.scale = (1.0, 0.75, 1.0)
    C.assign(rf, M["roof"])
    K.box("Cottage2", (9.5, 38.0, 1.2), (2.6, 2.4, 2.4), M["cottage"], bevel=0.05)
    bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=2.2, depth=1.4,
                                    location=(9.5, 38.0, 3.1), rotation=(0, 0, math.pi / 4))
    C.assign(bpy.context.active_object, M["roof"])
    for i in range(9):
        K.box(f"Fence{i}", (-0.6 + i * 0.55, 7.2, 0.45), (0.08, 0.08, 0.9), M["timber"], bevel=0.01)
    K.box("FenceRail", (1.6, 7.2, 0.65), (4.6, 0.06, 0.08), M["timber"], bevel=0.01)
    for i, (x, y, s) in enumerate(((-8, 60, 9), (6, 70, 12), (20, 75, 10))):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, radius=s, location=(x, y, -s * 0.75))
        hill = bpy.context.active_object
        hill.scale = (1.6, 1.0, 1.0)
        C.shade_smooth(hill)
        C.assign(hill, M["ground"])
    chicken("Hen1", (1.15, 4.75, 0), rot_z=math.radians(200), white=True, peck=True)
    chicken("Hen2", (1.6, 5.4, 0), rot_z=math.radians(150), white=False)
    chicken("Hen3", (0.95, 6.0, 0), rot_z=math.radians(-30), white=True)

    # dawn light: low warm sun through the door, sky fill -------------------
    sun = C.sun_light("Sun", (-70.7, 0, -57.9), 6.0, angle=3, color=(1.0, 0.6, 0.45))
    C.area_light("DoorSky", ((DOOR_X0 + DOOR_X1) / 2, BACK + 0.4, 1.4),
                 ((DOOR_X0 + DOOR_X1) / 2 - 0.6, 2.0, 1.2), 12, size=1.1, size_y=2.2,
                 shape="RECTANGLE", color=(0.75, 0.7, 0.95))
    C.area_light("RimAnvil", (-0.2, 2.4, 1.3), (AX, AY, 0.8), 25, size=0.8,
                 color=(1.0, 0.5, 0.2))

    # haze (indoors only, so the sun shaft shows) + embers over the fire ----
    K.haze((-W_HALF, FRONT + 1.5, 0), (W_HALF, BACK, HEIGHT), density=0.008,
           color=(1.0, 0.92, 0.88), anisotropy=0.5)
    K.embers((HX - 0.5, HY - 0.5, 1.4), (HX + 0.5, HY + 0.1, 2.6), count=16, seed=7,
             radius=0.011)


def dawn_world():
    w = bpy.context.scene.world
    n = C.NT(w)
    tc = n.node("ShaderNodeTexCoord")
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Generated"], sep.inputs[0])
    col = n.ramp(sep.outputs[2], [(0.0, C.hex_lin("#3A2A30")), (0.5, C.hex_lin("#F2A276")),
                                  (0.54, C.hex_lin("#E8907C")), (0.62, C.hex_lin("#A879A6")),
                                  (0.78, C.hex_lin("#40507E")), (1.0, C.hex_lin("#1C2444"))])
    bg = n.node("ShaderNodeBackground")
    n.link(col, bg.inputs[0])
    bg.inputs[1].default_value = 2.6
    out = n.node("ShaderNodeOutputWorld")
    n.link(bg.outputs[0], out.inputs[0])


def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="Filmic",
                        look="High Contrast", exposure=0.0, bounces=5)
    sc.cycles.volume_step_rate = 4.0
    sc.cycles.volume_max_steps = 256
    dawn_world()
    M = materials()
    build(M)
    cam = C.persp_camera((0.2, -2.6, 1.45), (0.05, BACK, 1.38), lens=26)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 5.8
    cam.data.dof.aperture_fstop = 2.8
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
