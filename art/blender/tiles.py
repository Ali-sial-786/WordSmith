"""Letter tiles: tile_cold / tile_hot / tile_used (blank forged-iron studs).

Orthographic top-down render of one lathe-modelled, slightly domed iron
stud. The geometry and camera never change between the three states, only
the material and lights, so the three PNGs swap pixel-perfectly (post.py
additionally forces one shared alpha mask).

    blender -b --factory-startup -P tiles.py -- [--samples 128] [--res 768]
Outputs: _renders/tiles/tile_{cold,hot,used}.png  (res x res, RGBA)
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402
import common as C  # noqa: E402

RES = C.arg("res", 768)
SAMPLES = C.arg("samples", 128)
ONLY = C.arg("only", "")

# Tile radius is 1.0 world unit; it spans DIAM_PX of a 256 px canvas.
DIAM_PX = 246.0
ORTHO = 2.0 * 256.0 / DIAM_PX


# --------------------------------------------------------------------------
# geometry
# --------------------------------------------------------------------------
def tile_profile():
    """(r, z) from the centre outwards, over the rim and back underneath."""
    pts = []
    # domed centre field
    R_FIELD = 0.70
    for i in range(0, 41):
        r = R_FIELD * i / 40
        z = 0.215 + 0.045 * (1 - (r / R_FIELD) ** 2)
        pts.append((r, z))
    # small incised groove that frames the letter
    groove = [(0.715, 0.211), (0.728, 0.200), (0.742, 0.196), (0.756, 0.200),
              (0.768, 0.210)]
    pts += groove
    # raised bead ring
    for i in range(1, 15):
        t = i / 14
        r = 0.768 + 0.10 * t
        z = 0.210 + 0.028 * math.sin(math.pi * t) ** 0.8 + 0.002 * t
        pts.append((r, z))
    # rounded outer edge (quarter-ish circle) down to the base
    cx, cz, rad = 0.875, 0.095, 0.125
    for i in range(1, 25):
        a = (math.pi / 2) * i / 24          # 0 -> 90 deg
        pts.append((cx + rad * math.sin(a), cz + rad * math.cos(a) + 0.0 * a))
    # straight-ish side, then a small round-under to the bottom
    pts += [(1.0, 0.06), (0.997, 0.03), (0.985, 0.008), (0.96, 0.0), (0.0, 0.0)]
    return pts


def build_tile():
    ob = C.lathe("Tile", tile_profile(), segments=384)
    # gentle irregularity so it reads as hand-forged, not machined
    tex = bpy.data.textures.new("forge_wobble", "CLOUDS")
    tex.noise_scale = 0.9
    d = ob.modifiers.new("Wobble", "DISPLACE")
    d.texture = tex
    d.strength = 0.006
    d.mid_level = 0.5
    d.texture_coords = "LOCAL"
    return ob


# --------------------------------------------------------------------------
# shared shader pieces
# --------------------------------------------------------------------------
def radial(n):
    """Node output: distance from tile centre in object space (0..1)."""
    tc = n.texcoord()
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Object"], sep.inputs[0])
    x2 = n.math("MULTIPLY", sep.outputs[0], sep.outputs[0])
    y2 = n.math("MULTIPLY", sep.outputs[1], sep.outputs[1])
    return n.math("SQRT", n.math("ADD", x2, y2)), tc


def hammer_bump(n, tc, strength, scale=5.5, extra=None):
    """Hammer-facet dents (smooth Voronoi) + fine ambientCG normal detail."""
    vor = n.node("ShaderNodeTexVoronoi", _feature="SMOOTH_F1",
                 _voronoi_dimensions="3D")
    vor.inputs["Scale"].default_value = scale
    vor.inputs["Smoothness"].default_value = 0.6
    vor.inputs["Randomness"].default_value = 1.0
    n.link(tc.outputs["Object"], vor.inputs["Vector"])
    h = n.math("POWER", vor.outputs["Distance"], 1.6)
    bump = n.node("ShaderNodeBump")
    bump.inputs["Strength"].default_value = strength
    bump.inputs["Distance"].default_value = 0.08
    n.link(h, bump.inputs["Height"])
    if extra is not None:
        n.link(extra, bump.inputs["Normal"])
    return bump.outputs[0]


def detail_normal(n, tc, strength):
    t = C.tex_set("Metal052C")
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (0.9, 0.9, 0.9)
    n.link(tc.outputs["Object"], mp.inputs[0])
    img = n.image(t["NormalGL"], mp.outputs[0], "Non-Color")
    nm = n.node("ShaderNodeNormalMap")
    nm.inputs["Strength"].default_value = strength
    n.link(img.outputs[0], nm.inputs["Color"])
    rough = n.image(t["Roughness"], mp.outputs[0], "Non-Color")
    return nm.outputs[0], rough.outputs[0]


# --------------------------------------------------------------------------
# materials
# --------------------------------------------------------------------------
def mat_cold():
    m = C.new_material("TileCold")
    n = C.NT(m)
    r, tc = radial(n)
    dn, rough_img = detail_normal(n, tc, 0.35)
    normal = hammer_bump(n, tc, 0.10, scale=5.0, extra=dn)
    p = n.node("ShaderNodeBsdfPrincipled")
    # dark iron, very slightly warmer/darker towards the rim (soot)
    # iron's specular colour is fairly bright; it reads dark because it
    # reflects a dark room. Slightly sootier towards the rim.
    base = n.ramp(r, [(0.0, C.hex_lin("#8C8F96")), (0.72, C.hex_lin("#868990")),
                      (0.9, C.hex_lin("#7A7876")), (1.0, C.hex_lin("#6A6662"))])
    n.link(base, p.inputs["Base Color"])
    p.inputs["Metallic"].default_value = 0.92
    rough = n.maprange(rough_img, 0, 1, 0.34, 0.52)
    # bevels and bead are worn smoother (polished by handling) -> crisper
    rim = n.maprange(r, 0.70, 0.76, 0.0, 1.0)
    rough = n.mix(rough, n.maprange(rough_img, 0, 1, 0.16, 0.26), rim,
                  dtype="FLOAT")
    n.link(rough, p.inputs["Roughness"])
    n.link(normal, p.inputs["Normal"])
    n.output(p.outputs[0])
    return m


def mat_used():
    m = C.new_material("TileUsed")
    n = C.NT(m)
    r, tc = radial(n)
    dn, rough_img = detail_normal(n, tc, 0.25)
    normal = hammer_bump(n, tc, 0.12, extra=dn)
    p = n.node("ShaderNodeBsdfPrincipled")
    base = n.ramp(r, [(0.0, C.hex_lin("#5A6370")), (0.75, C.hex_lin("#555E6A")),
                      (1.0, C.hex_lin("#454C57"))])
    n.link(base, p.inputs["Base Color"])
    p.inputs["Metallic"].default_value = 0.45
    rough = n.maprange(rough_img, 0, 1, 0.62, 0.78)
    n.link(rough, p.inputs["Roughness"])
    n.link(normal, p.inputs["Normal"])
    n.output(p.outputs[0])
    return m


def mat_hot():
    m = C.new_material("TileHot")
    n = C.NT(m)
    r, tc = radial(n)
    dn, rough_img = detail_normal(n, tc, 0.25)
    normal = hammer_bump(n, tc, 0.10, extra=dn)
    # heat colour: yellow-orange centre, ember rim, cherry at the very edge
    heat = n.ramp(r, [
        (0.00, C.hex_lin("#FFC24A")),
        (0.55, C.hex_lin("#FFB53D")),
        (0.70, C.hex_lin("#FFA634")),
        (0.80, C.hex_lin("#FF8A22")),
        (0.90, C.hex_lin("#FF6A13")),
        (1.00, C.hex_lin("#C8341A")),
    ])
    # faint oxide mottling, stronger on the rim, almost none in the centre
    noise = n.node("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 4.0
    noise.inputs["Detail"].default_value = 6.0
    n.link(tc.outputs["Object"], noise.inputs["Vector"])
    mott = n.maprange(noise.outputs[0], 0.35, 0.75, 0.0, 1.0)
    rimw = n.maprange(r, 0.6, 1.0, 0.04, 0.35)
    fac = n.math("MULTIPLY", mott, rimw)
    heat = n.mix(heat, C.hex_lin("#B8401A"), fac)
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = C.hex_lin("#2A0E06")
    p.inputs["Metallic"].default_value = 0.0
    p.inputs["Roughness"].default_value = 0.38
    p.inputs["Specular IOR Level"].default_value = 0.35
    n.link(heat, p.inputs["Emission Color"])
    p.inputs["Emission Strength"].default_value = 1.0
    n.link(normal, p.inputs["Normal"])
    n.output(p.outputs[0])
    return m


# --------------------------------------------------------------------------
# lighting rigs (camera looks down -Z; image up = +Y, image right = +X)
# --------------------------------------------------------------------------
def lights(kind):
    for ob in [o for o in bpy.data.objects
               if o.type == "LIGHT" or o.name.startswith("Ring")]:
        bpy.data.objects.remove(ob)
    warm = (1.0, 0.66, 0.38)
    if kind == "cold":
        C.world_gradient(C.hex_lin("#0A0908"), C.hex_lin("#2E241E"),
                       C.hex_lin("#100D0B"), 1.0)
        # big soft overhead panel: gives the iron face its dark-grey sheen
        C.area_light("Top", (0.0, 0.6, 7.0), (0, 0, 0), 30, size=7.0,
                     color=(0.80, 0.86, 0.96), shape="DISK")
        # warm forge key from upper-left, low: crisp rim highlight
        C.area_light("Key", (-3.0, 3.0, 1.5), (0, 0, 0.1), 120, size=1.0,
                     color=warm)
        # broad warm wash from the top edge (the forge is "up" the screen)
        C.area_light("Wash", (0.0, 4.0, 2.2), (0, 0, 0.1), 22, size=4.0,
                     color=(1.0, 0.72, 0.48))
        # faint cool kicker from lower-right so the far rim is not dead
        C.area_light("Kick", (3.4, -3.4, 1.4), (0, 0, 0.1), 18, size=2.5,
                     color=(0.62, 0.72, 0.9))
        # crisp warm rim line: strong upper-left, a whisper all the way round
        C.ring_light("RingWarm", 3.0, 1.75, C.hex_lin("#FFB878"), 14.0, 0.6,
                   focus=3.0, thickness=0.06)
        C.ring_light("RingLow", 3.0, 0.55, C.hex_lin("#FF9A50"), 6.0, 0.25,
                   focus=4.0, thickness=0.06)
    elif kind == "used":
        C.world_gradient(C.hex_lin("#121418"), C.hex_lin("#3C424C"),
                       C.hex_lin("#1A1D22"), 1.0)
        C.area_light("Top", (0.0, 0.5, 7.0), (0, 0, 0), 300, size=8.0,
                     color=(0.85, 0.9, 1.0))
        C.area_light("Key", (-3.2, 3.2, 2.2), (0, 0, 0.1), 60, size=3.0,
                     color=(0.92, 0.9, 0.95))
    else:  # hot
        C.world_gradient(C.hex_lin("#1A0A04"), C.hex_lin("#5A2A10"),
                       C.hex_lin("#1A0A04"), 1.0)
        C.area_light("Top", (0.0, 0.5, 7.0), (0, 0, 0), 60, size=7.0,
                     color=(1.0, 0.85, 0.6))
        C.area_light("Key", (-3.2, 3.2, 1.8), (0, 0, 0.1), 120, size=1.6,
                     color=(1.0, 0.95, 0.85))


def main():
    sc = C.reset()
    C.setup_cycles((RES, RES), samples=SAMPLES, transparent=True,
                   view="Standard", bounces=4)
    C.ortho_camera(ORTHO, loc=(0, 0, 5))
    tile = build_tile()
    mats = {"cold": mat_cold(), "hot": mat_hot(), "used": mat_used()}
    for kind in ("cold", "hot", "used"):
        if ONLY and kind not in ONLY.split(","):
            continue
        C.assign(tile, mats[kind])
        lights(kind)
        C.render(f"tile_{kind}", "tiles")


if __name__ == "__main__":
    main()
