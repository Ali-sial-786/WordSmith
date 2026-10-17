"""bg_starmetal: a forge on a volcanic ridge under a meteor shower (Starmetal chapter).

Night on a ridge of black volcanic rock. A great rock overhang and two
pillars frame an opening onto a violet starry sky with a faint nebula band
and streaking meteors; far off, a volcano's crater glows orange on the
horizon. Under the overhang a rough stone hearth burns orange on the left
(~45-58 % down the frame), and on the anvil lies a chunk of starmetal:
dark blue-violet meteorite iron, its veins and glints glowing. A larger
meteorite sits half-buried in its little crater further out, and faint lava
cracks thread the far ground.

Top ~45 % (overhang, sky) and the bottom (near rock) stay dark and calm.

    blender -b --factory-startup -P scene_starmetal.py -- [--samples 64] [--scale 0.667]
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
NAME = "bg_starmetal"

VOLCANO = (24.0, 120.0)        # x, y of the far volcano


def starmetal_material(name="Starmetal", glow=4.0):
    """Meteorite iron: dark blue-violet metal with a Widmanstatten-like
    crystalline sheen, glowing violet veins and bright star-like glints."""
    t = C.tex_set("Rock035")
    m = C.new_material(name)
    n = C.NT(m)
    tc = n.texcoord()
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (2.0, 2.0, 2.0)
    n.link(tc.outputs["Object"], mp.inputs[0])
    vor = n.node("ShaderNodeTexVoronoi", _feature="F1")
    vor.inputs["Scale"].default_value = 7.0
    n.link(tc.outputs["Object"], vor.inputs["Vector"])
    cell = n.node("ShaderNodeSeparateColor")
    n.link(vor.outputs["Color"], cell.inputs[0])
    base = n.mix(C.hex_lin("#120F22"), C.hex_lin("#2E2856"), cell.outputs[0])
    p = n.node("ShaderNodeBsdfPrincipled")
    n.link(base, p.inputs["Base Color"])
    p.inputs["Metallic"].default_value = 0.85
    n.link(n.maprange(cell.outputs[1], 0, 1, 0.18, 0.45), p.inputs["Roughness"])
    nm = n.node("ShaderNodeNormalMap")
    nm.inputs["Strength"].default_value = 1.0
    n.link(n.image(t["NormalGL"], mp.outputs[0], "Non-Color", proj="BOX").outputs[0], nm.inputs["Color"])
    n.link(nm.outputs[0], p.inputs["Normal"])
    # veins: thin ridges of a warped noise
    nz = n.node("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 4.0
    nz.inputs["Detail"].default_value = 6.0
    n.link(tc.outputs["Object"], nz.inputs["Vector"])
    ridge = n.maprange(n.math("ABSOLUTE", n.math("SUBTRACT", nz.outputs[0], 0.5)), 0.0, 0.006, 0.6, 0.0)
    # glints: a sparse scatter of tiny bright cells
    g = n.node("ShaderNodeTexVoronoi", _feature="F1")
    g.inputs["Scale"].default_value = 60.0
    n.link(tc.outputs["Object"], g.inputs["Vector"])
    gs = n.node("ShaderNodeSeparateColor")
    n.link(g.outputs["Color"], gs.inputs[0])
    glint = n.math("MULTIPLY", n.maprange(g.outputs["Distance"], 0.0, 0.12, 1.0, 0.0),
                   n.maprange(gs.outputs[0], 0.9, 1.0, 0.0, 1.0))
    emit = n.mix(C.hex_lin("#000000"), C.hex_lin("#9C7CFF"), ridge, blend="ADD")
    emit = n.mix(emit, C.hex_lin("#F2ECFF"), n.math("MULTIPLY", glint, 6.0), blend="ADD")
    n.link(emit, p.inputs["Emission Color"])
    p.inputs["Emission Strength"].default_value = glow
    n.output(p.outputs[0])
    return m


def lava_rock_material(name="LavaRock", lava=1.8):
    """Black volcanic rock (Rock035) with sparse glowing cracks, fading out
    toward the camera so the near ground stays dark."""
    m = K.tex_material(name, "Rock035", scale=0.25, value=0.35, sat=0.6, rough=(0.6, 1.0), normal=1.0)
    n = C.NT(m, clear=False)
    p = next(nd for nd in m.node_tree.nodes if nd.type == "BSDF_PRINCIPLED")
    tc = n.node("ShaderNodeTexCoord")
    vor = n.node("ShaderNodeTexVoronoi", _feature="DISTANCE_TO_EDGE")
    vor.inputs["Scale"].default_value = 0.9
    n.link(tc.outputs["Object"], vor.inputs["Vector"])
    crack = n.maprange(vor.outputs["Distance"], 0.0, 0.025, 1.0, 0.0)
    nz = n.node("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 0.35
    n.link(tc.outputs["Object"], nz.inputs["Vector"])
    patchy = n.maprange(nz.outputs[0], 0.5, 0.65, 0.0, 1.0)
    geo = n.node("ShaderNodeNewGeometry")
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(geo.outputs["Position"], sep.inputs[0])
    far = n.maprange(sep.outputs[1], 4.0, 9.0, 0.0, 1.0)
    heat = n.math("MULTIPLY", n.math("MULTIPLY", crack, patchy), far)
    col = n.ramp(heat, [(0.0, (0, 0, 0, 1)), (0.4, C.hex_lin("#8A1E06")), (1.0, C.hex_lin("#FF7A1E"))])
    n.link(col, p.inputs["Emission Color"])
    p.inputs["Emission Strength"].default_value = lava
    return m


def materials():
    return dict(
        rock=K.tex_material("Rock", "Rock035", scale=0.3, value=0.32, sat=0.6, rough=(0.6, 1.0),
                            normal=1.2),
        ground=lava_rock_material(),
        far=K.tex_material("FarRock", "Rock035", scale=0.04, value=0.1, sat=0.5, rough=(0.7, 1.0)),
        hearth=K.tex_material("HearthRock", "Rock035", scale=0.7, value=0.4, sat=0.6, rough=(0.6, 1.0),
                              soot=0.6, soot_range=(1.2, 2.6)),
        iron=P.iron_material("Iron", base="#565866", rough=(0.3, 0.5), bump=0.12),
        star=starmetal_material(glow=2.2),
        star_big=starmetal_material("StarmetalBig", glow=2.5),
        crater=K.glow_material("Crater", "#FF6A13", 14.0),
        handle=P.wood_material("Handle", value=0.5, scale=3.0),
    )


def slab(name, loc, size, mat, strength=0.35, scale=0.7, levels=5):
    ob = K.box(name, loc, size, mat, bevel=0)
    sub = ob.modifiers.new("Sub", "SUBSURF")
    sub.subdivision_type = "SIMPLE"
    sub.levels = sub.render_levels = levels
    tex = bpy.data.textures.new(name + "_rock", "CLOUDS")
    tex.noise_scale = scale
    tex.noise_depth = 3
    d = ob.modifiers.new("Rough", "DISPLACE")
    d.texture = tex
    d.strength = strength
    d.texture_coords = "GLOBAL"
    return ob


def rock_lump(name, loc, size, mat, seed=1, squash=0.7):
    rnd = random.Random(seed)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=4, radius=1.0, location=loc)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = (size * rnd.uniform(0.85, 1.2), size * rnd.uniform(0.8, 1.1), size * squash)
    ob.rotation_euler = (rnd.uniform(-0.3, 0.3), rnd.uniform(-0.3, 0.3), rnd.uniform(0, 6))
    tex = bpy.data.textures.new(name + "_n", "VORONOI")
    tex.noise_scale = 0.5
    d = ob.modifiers.new("Lumpy", "DISPLACE")
    d.texture = tex
    d.strength = size * 0.35
    C.shade_smooth(ob)
    C.assign(ob, mat)
    return ob


def build(M):
    # ground: a broad ridge of volcanic rock ------------------------------------------
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=160, y_subdivisions=160, size=1, location=(0, 12, 0))
    g = bpy.context.active_object
    g.name = "Ground"
    g.scale = (40, 40, 1)
    C.apply_transform(g)
    tex = bpy.data.textures.new("ground_undulate", "CLOUDS")
    tex.noise_scale = 3.0
    d = g.modifiers.new("Undulate", "DISPLACE")
    d.texture = tex
    d.strength = 0.5
    d.texture_coords = "GLOBAL"
    C.assign(g, M["ground"])
    # the ridge falls away beyond ~y=9: a dark far plain lower down
    K.plane("FarPlain", (0, 70, -6), (300, 100), mat=M["far"])

    # overhang + pillars framing the opening --------------------------------------------
    slab("Overhang", (0, -2.0, 4.2), (8.0, 8.4, 1.6), M["rock"], strength=0.6, scale=0.8)
    slab("PillarL", (-2.3, 1.2, 2.2), (1.4, 2.4, 4.6), M["rock"], strength=0.4)
    slab("PillarR", (2.45, 2.2, 2.2), (1.4, 2.0, 4.6), M["rock"], strength=0.4)
    slab("BackL", (-3.0, 3.2, 1.2), (2.4, 1.2, 2.6), M["rock"], strength=0.4)

    # far volcano with a glowing crater ----------------------------------
    vx, vy = VOLCANO
    bpy.ops.mesh.primitive_cone_add(vertices=48, radius1=42, radius2=4.0, depth=17, location=(vx, vy, 1.5))
    vol = bpy.context.active_object
    vol.name = "Volcano"
    sub = vol.modifiers.new("Sub", "SUBSURF")
    sub.subdivision_type = "SIMPLE"
    sub.levels = sub.render_levels = 3
    t2 = bpy.data.textures.new("volcano_n", "CLOUDS")
    t2.noise_scale = 6.0
    dd = vol.modifiers.new("Rough", "DISPLACE")
    dd.texture = t2
    dd.strength = 1.5
    C.assign(vol, M["far"])
    bpy.ops.mesh.primitive_circle_add(vertices=32, radius=3.6, fill_type="NGON", location=(vx, vy, 10.05))
    C.assign(bpy.context.active_object, M["crater"])
    C.point_light("CraterGlow", (vx, vy - 8, 14), 15000, radius=4.0, color=(1.0, 0.4, 0.12))

    # meteors streaking across the sky ---------------------------------------------------
    rnd = random.Random(12)
    streaks = []
    for i in range(8):
        az = math.radians(rnd.uniform(-15, 14))
        el = math.radians(rnd.uniform(5, 18))
        D = 220
        head = (D * math.sin(az), D * math.cos(az), 1.45 + D * math.tan(el))
        streaks.append((head, (-0.75 + rnd.uniform(-0.1, 0.1), 0.0, -0.5), rnd.uniform(8, 26)))
    K.meteors(streaks, K.meteor_material("Meteor", strength=9.0), radius=0.11)

    # the hearth under the overhang (left) ---------------------------------------------
    HX, HY = -1.0, 2.7
    K.hearth((HX, HY, 0), w=1.5, d=1.1, h=0.8, brick=M["hearth"], hood=M["hearth"],
             coal_strength=5.0, light_energy=200, hood_top=3.4, flue_top=4.4)
    K.fire((HX, HY - 0.05, 0.86), spread=(0.4, 0.15), count=9, height=0.85, width=0.16,
           seed=51, strength=5.5, name="HearthFire")
    K.flame_volume((HX, HY - 0.05, 1.2), size=(0.55, 0.32, 0.45), strength=1.4, name="HearthGlow")
    K.embers((HX - 0.5, HY - 0.5, 1.5), (HX + 0.5, HY + 0.1, 2.7), count=12, seed=51, radius=0.011)

    # the anvil on a rock with the starmetal chunk ---------------------------------------
    AX, AY = 0.7, 1.15
    rock_lump("AnvilRock", (AX, AY, 0.16), 0.5, M["rock"], seed=3, squash=0.36)
    anv = P.anvil("Anvil", M["iron"], depth=1.15, location=(AX, AY, 0.34), rot_z=math.radians(-25))
    anv.scale = (0.28, 0.28, 0.28)
    rock_lump("StarChunk", (AX + 0.02, AY - 0.02, 0.83), 0.085, M["star"], seed=7, squash=0.55)
    C.point_light("ChunkGlow", (AX, AY - 0.25, 1.05), 5, radius=0.08, color=(0.62, 0.48, 1.0))
    hm = P.hammer("AnvilHammer", M["iron"], M["handle"], head_len=0.26, head_w=0.09, handle_len=0.5,
                  pein_axis="z", handle_r=0.02)
    hm.location = (AX - 0.25, AY + 0.05, 0.84)
    hm.rotation_euler = (math.radians(90), 0, math.radians(150))

    # a bigger meteorite half-buried in its crater, further out -------------------------
    MX, MY = 1.35, 5.2
    bpy.ops.mesh.primitive_torus_add(major_radius=0.9, minor_radius=0.25, major_segments=48, minor_segments=12,
                                     location=(MX, MY, 0.05))
    rim = bpy.context.active_object
    rim.scale = (1, 1, 0.45)
    tx = bpy.data.textures.new("rim_n", "CLOUDS")
    tx.noise_scale = 0.4
    dm = rim.modifiers.new("Lumpy", "DISPLACE")
    dm.texture = tx
    dm.strength = 0.12
    C.assign(rim, M["rock"])
    rock_lump("Meteorite", (MX, MY, 0.2), 0.5, M["star_big"], seed=11, squash=0.65)
    C.point_light("MeteoriteGlow", (MX - 0.2, MY - 0.8, 0.9), 40, radius=0.2, color=(0.6, 0.45, 1.0))

    # light: violet starlight from the sky, faint fills ---------------------------------
    sky = C.sun_light("Starlight", (0, 0, 0), 0.25, angle=20.0, color=(0.62, 0.5, 1.0))
    sky.rotation_euler = Vector((-0.3, -1.0, -0.6)).to_track_quat("-Z", "Y").to_euler()
    C.area_light("OpeningSky", (0.2, 3.6, 3.4), (0.2, 0.5, 0.5), 40, size=3.0, size_y=1.5,
                 shape="RECTANGLE", color=(0.6, 0.48, 1.0))
    C.area_light("RimAnvil", (-0.2, 2.6, 1.6), (AX, AY, 0.85), 18, size=0.6, color=(1.0, 0.5, 0.2))
    C.area_light("CoolFill", (-2.0, -3.0, 3.0), (0, 2, 1), 4, size=3.0, color=(0.6, 0.5, 1.0))
    K.haze((-3.0, -3.0, 0.05), (3.0, 4.2, 3.2), density=0.004, color=(0.95, 0.9, 1.0), anisotropy=0.5)


def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="Filmic",
                        look="High Contrast", exposure=0.0, bounces=5)
    sc.cycles.volume_step_rate = 8.0
    sc.cycles.volume_max_steps = 256
    vx, vy = VOLCANO
    K.night_world(zenith="#070412", horizon="#1C0E30", ground="#040306", strength=1.0,
                  stars=1.0, star_scale=230.0, star_tint="#E8E0FF", nebula="#6A34B8",
                  nebula_strength=0.3, glow_color="#B04016", glow_dir=(vx, vy, 0.0),
                  glow_power=120.0, glow_strength=0.5)
    M = materials()
    build(M)
    cam = C.persp_camera((0.15, -2.9, 1.45), (0.1, 3.0, 1.45), lens=26)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 4.6
    cam.data.dof.aperture_fstop = 2.8
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
