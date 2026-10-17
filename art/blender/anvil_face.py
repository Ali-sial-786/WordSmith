"""Anvil face (base of the letter ring): anvil_face + anvil_face_glow.

Orthographic top-down view of a round, hammered dark-iron striking face:
a softly hammered face, a smoother concentric wear ring at ~70 % radius
(where the letter tiles sit), an engraved line, a thin inlaid bronze band
with a few rivets, and a bevelled rim. Deliberately low contrast so tiles
and the molten trail read on top.

Two renders from the same camera:
  anvil_face.png       the lit iron face (RGBA, transparent outside)
  anvil_face_glow.png  emission only: the rim heating up (post.py turns it
                       into an additive layer + a little bloom)

    blender -b --factory-startup -P anvil_face.py -- [--samples 80] [--res 1152]
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402
import common as C  # noqa: E402

RES = C.arg("res", 1152)
SAMPLES = C.arg("samples", 80)
ONLY = C.arg("only", "")

# Plate radius 1.0 spans DIAM_PX of the 1024 canvas; the rest is margin for
# the soft drop shadow added in post.py.
DIAM_PX = 952.0
ORTHO = 2.0 * 1024.0 / DIAM_PX

R_WEAR = 0.70          # centre of the tile ring
BAND_IN, BAND_OUT = 0.885, 0.915
N_RIVETS = 8


# --------------------------------------------------------------------------
# geometry
# --------------------------------------------------------------------------
def plate_profile():
    pts = []
    # face: barely domed, with a whisper-shallow dish where tiles sit
    for i in range(0, 121):
        r = 0.86 * i / 120
        z = 0.300 - 0.010 * (r / 0.86) ** 2
        dish = 0.0025 * math.exp(-((r - R_WEAR) / 0.09) ** 2)
        pts.append((r, z - dish))
    # engraved line
    pts += [(0.862, 0.2895), (0.866, 0.2855), (0.870, 0.2855), (0.874, 0.289)]
    # step down into the band channel (band is a separate object)
    pts += [(0.878, 0.289), (0.880, 0.276), (BAND_IN - 0.002, 0.272),
            (BAND_OUT + 0.002, 0.272), (0.920, 0.276), (0.922, 0.287)]
    # outer iron rim, flat then a generous rounded bevel to the side
    pts += [(0.93, 0.288), (0.94, 0.2875)]
    cx, cz, rad = 0.94, 0.2275, 0.06
    for i in range(1, 21):
        a = (math.pi / 2) * i / 20
        pts.append((cx + rad * math.sin(a), cz + rad * math.cos(a)))
    pts += [(1.0, 0.12), (0.995, 0.02), (0.97, 0.0), (0.0, 0.0)]
    return pts


def band_profile():
    pts = []
    for i in range(0, 13):
        t = i / 12
        r = BAND_IN + (BAND_OUT - BAND_IN) * t
        z = 0.281 + 0.0035 * math.sin(math.pi * t)
        pts.append((r, z))
    pts += [(BAND_OUT, 0.27), (BAND_IN, 0.27), (BAND_IN, 0.281)]
    return pts


def build():
    plate = C.lathe("Plate", plate_profile(), segments=512)
    wob = bpy.data.textures.new("plate_wobble", "CLOUDS")
    wob.noise_scale = 0.6
    d = plate.modifiers.new("Wobble", "DISPLACE")
    d.texture = wob
    d.strength = 0.004
    d.texture_coords = "LOCAL"
    band = C.lathe("Band", band_profile(), segments=512, cap_center=False)
    rivets = []
    rr = (BAND_IN + BAND_OUT) / 2
    for i in range(N_RIVETS):
        a = 2 * math.pi * (i + 0.5) / N_RIVETS
        bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16,
                                             radius=0.019,
                                             location=(rr * math.cos(a),
                                                       rr * math.sin(a), 0.282))
        rv = bpy.context.active_object
        rv.name = f"Rivet{i}"
        rv.scale = (1, 1, 0.45)
        C.shade_smooth(rv)
        rivets.append(rv)
    return plate, band, rivets


# --------------------------------------------------------------------------
# materials
# --------------------------------------------------------------------------
def radial(n):
    """Distance from the plate centre, in world space (plate is at origin)."""
    tc = n.texcoord()
    geo = n.node("ShaderNodeNewGeometry")
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(geo.outputs["Position"], sep.inputs[0])
    x2 = n.math("MULTIPLY", sep.outputs[0], sep.outputs[0])
    y2 = n.math("MULTIPLY", sep.outputs[1], sep.outputs[1])
    return n.math("SQRT", n.math("ADD", x2, y2)), tc, sep


def iron_face(heat=False):
    m = C.new_material("AnvilIronHot" if heat else "AnvilIron")
    n = C.NT(m)
    r, tc, sep = radial(n)
    t = C.tex_set("Metal052C")
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (0.75, 0.75, 0.75)
    n.link(tc.outputs["Object"], mp.inputs[0])
    rough_img = n.image(t["Roughness"], mp.outputs[0], "Non-Color").outputs[0]
    nimg = n.image(t["NormalGL"], mp.outputs[0], "Non-Color").outputs[0]
    nm = n.node("ShaderNodeNormalMap")
    nm.inputs["Strength"].default_value = 0.35
    n.link(nimg, nm.inputs["Color"])

    # wear ring mask (smooth band around R_WEAR)
    dr = n.math("ABSOLUTE", n.math("SUBTRACT", r, R_WEAR))
    wear = n.maprange(dr, 0.05, 0.13, 1.0, 0.0, interp="SMOOTHSTEP")

    # big soft hammer facets, weaker inside the wear ring (polished flat)
    vor = n.node("ShaderNodeTexVoronoi", _feature="SMOOTH_F1")
    vor.inputs["Scale"].default_value = 9.0
    vor.inputs["Smoothness"].default_value = 0.45
    vor.inputs["Randomness"].default_value = 1.0
    n.link(tc.outputs["Object"], vor.inputs["Vector"])
    h = n.math("POWER", vor.outputs["Distance"], 1.5)
    # fine concentric polishing scratches in the wear ring
    ang_noise = n.node("ShaderNodeTexNoise")
    ang_noise.inputs["Scale"].default_value = 1.0
    ang_noise.inputs["Detail"].default_value = 2.0
    radv = n.node("ShaderNodeCombineXYZ")
    n.link(n.math("MULTIPLY", r, 260.0), radv.inputs[0])
    n.link(n.math("MULTIPLY", sep.outputs[0], 1.5), radv.inputs[1])
    n.link(radv.outputs[0], ang_noise.inputs["Vector"])
    scratch = n.math("MULTIPLY", ang_noise.outputs[0], wear)
    hb = n.math("MULTIPLY", h, n.maprange(wear, 0, 1, 1.0, 0.38))
    hb = n.math("ADD", hb, n.math("MULTIPLY", scratch, 0.10))
    bump = n.node("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.21
    bump.inputs["Distance"].default_value = 0.05
    n.link(hb, bump.inputs["Height"])
    n.link(nm.outputs[0], bump.inputs["Normal"])

    p = n.node("ShaderNodeBsdfPrincipled")
    # sooty mottling of the specular colour
    mott = n.node("ShaderNodeTexNoise")
    mott.inputs["Scale"].default_value = 3.0
    mott.inputs["Detail"].default_value = 8.0
    mott.inputs["Roughness"].default_value = 0.6
    n.link(tc.outputs["Object"], mott.inputs["Vector"])
    base = n.ramp(mott.outputs[0], [(0.3, C.hex_lin("#5A5856")),
                                    (0.7, C.hex_lin("#716F6D"))])
    base = n.mix(base, C.hex_lin("#84868A"), n.math("MULTIPLY", wear, 0.6))
    # rim slightly sootier/warmer
    rimf = n.maprange(r, 0.86, 1.0, 0.0, 1.0)
    base = n.mix(base, C.hex_lin("#6A625A"), rimf)
    n.link(base, p.inputs["Base Color"])
    p.inputs["Metallic"].default_value = 0.9
    rough = n.maprange(rough_img, 0, 1, 0.36, 0.50)
    rough = n.mix(rough, n.maprange(rough_img, 0, 1, 0.27, 0.36), wear,
                  dtype="FLOAT")
    # rim bevel polished a bit -> crisp ring-light line
    rough = n.mix(rough, 0.24, n.maprange(r, 0.925, 0.95, 0.0, 1.0), dtype="FLOAT")
    n.link(rough, p.inputs["Roughness"])
    n.link(bump.outputs[0], p.inputs["Normal"])
    if heat:
        add_heat(n, p, r, tc)
    n.output(p.outputs[0])
    return m


def add_heat(n, p, r, tc, rim_only=False):
    """Emission: rim heated to ember/molten, fading towards the centre."""
    noise = n.node("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 5.0
    noise.inputs["Detail"].default_value = 6.0
    n.link(tc.outputs["Object"], noise.inputs["Vector"])
    brk = n.maprange(noise.outputs[0], 0.3, 0.7, 0.7, 1.15)
    heat = n.ramp(r, [
        (0.00, (0, 0, 0, 1)),
        (0.66, (0, 0, 0, 1)),
        (0.80, C.hex_lin("#240A04")),
        (0.88, C.hex_lin("#6E1E0A")),
        (0.94, C.hex_lin("#D24E10")),
        (0.985, C.hex_lin("#FF7A1C")),
        (1.00, C.hex_lin("#FFA23A")),
    ], interp="EASE")
    n.link(heat, p.inputs["Emission Color"])
    n.link(brk, p.inputs["Emission Strength"])


def bronze(heat=False):
    m = C.new_material("BronzeHot" if heat else "Bronze")
    n = C.NT(m)
    r, tc, sep = radial(n)
    p = n.node("ShaderNodeBsdfPrincipled")
    noise = n.node("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 30.0
    noise.inputs["Detail"].default_value = 6.0
    n.link(tc.outputs["Object"], noise.inputs["Vector"])
    col = n.ramp(noise.outputs[0], [(0.35, C.hex_lin("#6E4A2A")),
                                    (0.65, C.hex_lin("#9A6A3C"))])
    n.link(col, p.inputs["Base Color"])
    p.inputs["Metallic"].default_value = 1.0
    p.inputs["Roughness"].default_value = 0.33
    if heat:
        add_heat(n, p, r, tc)
    n.output(p.outputs[0])
    return m


def rivet_mat(heat=False):
    m = C.new_material("RivetHot" if heat else "Rivet")
    n = C.NT(m)
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = C.hex_lin("#77736E")
    p.inputs["Metallic"].default_value = 0.95
    p.inputs["Roughness"].default_value = 0.3
    if heat:
        r, tc, sep = radial(n)
        add_heat(n, p, r, tc)
    n.output(p.outputs[0])
    return m


# --------------------------------------------------------------------------
def lights():
    C.world_gradient(C.hex_lin("#080706"), C.hex_lin("#2A211B"),
                     C.hex_lin("#0E0B09"), 1.0)
    C.area_light("Top", (-1.5, 2.0, 9.0), (0, 0, 0), 60, size=7.0,
                 color=(0.80, 0.86, 0.96))
    C.area_light("Wash", (0.0, 5.0, 2.8), (0, 0, 0.2), 14, size=5.0,
                 color=(1.0, 0.72, 0.48))
    C.area_light("Key", (-3.6, 3.6, 2.0), (0, 0, 0.2), 140, size=1.4,
                 color=(1.0, 0.66, 0.38))
    C.area_light("Kick", (3.8, -3.8, 1.6), (0, 0, 0.2), 25, size=3.0,
                 color=(0.62, 0.72, 0.9))
    C.ring_light("RingWarm", 4.0, 2.4, C.hex_lin("#FFB878"), 10.0, 0.5,
                 focus=3.0, thickness=0.08)
    C.ring_light("RingLow", 4.0, 0.8, C.hex_lin("#FF9A50"), 4.0, 0.2,
                 focus=4.0, thickness=0.08)


def glow_materials(plate, band, rivets):
    """Emission-only versions (black, non-reflective bodies)."""
    def emit_only(m):
        # strip reflections: make the BSDF black & rough
        for nd in m.node_tree.nodes:
            if nd.type == "BSDF_PRINCIPLED":
                for lk in list(nd.inputs["Base Color"].links):
                    m.node_tree.links.remove(lk)
                nd.inputs["Base Color"].default_value = (0, 0, 0, 1)
                nd.inputs["Specular IOR Level"].default_value = 0.0
                for lk in list(nd.inputs["Roughness"].links):
                    m.node_tree.links.remove(lk)
                nd.inputs["Roughness"].default_value = 1.0
        return m
    C.assign(plate, emit_only(iron_face(heat=True)))
    C.assign(band, emit_only(bronze(heat=True)))
    rm = emit_only(rivet_mat(heat=True))
    for rv in rivets:
        C.assign(rv, rm)


def main():
    C.reset()
    C.setup_cycles((RES, RES), samples=SAMPLES, transparent=True,
                   view="Standard", bounces=4)
    C.ortho_camera(ORTHO, loc=(0, 0, 5))
    plate, band, rivets = build()
    if not ONLY or "face" in ONLY:
        C.assign(plate, iron_face())
        C.assign(band, bronze())
        rm = rivet_mat()
        for rv in rivets:
            C.assign(rv, rm)
        lights()
        C.render("anvil_face", "anvil")
    if not ONLY or "glow" in ONLY:
        for ob in [o for o in bpy.data.objects
                   if o.type == "LIGHT" or o.name.startswith("Ring")]:
            bpy.data.objects.remove(ob)
        C.world_color((0, 0, 0, 1), 0.0)
        glow_materials(plate, band, rivets)
        C.render("anvil_face_glow", "anvil")


if __name__ == "__main__":
    main()
