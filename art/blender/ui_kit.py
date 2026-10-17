"""Metal UI kit: plates (menu buttons), panels (cards), round buttons and a
pill chip, as polished bronze / gold / steel frames around dark forged-iron
or molten faces. All 9-slice images at 3x (see ui_geom.PIECES for sizes and
centre slices); post.py downsamples, masks and writes app/assets/ui/*.png.

Each piece is a heightfield mesh from ui_geom.py (the same functions post.py
uses for the masks), rendered top-down orthographic with Cycles at 2x the final
size. Lighting comes only from a procedural studio environment (softbox strips
at fixed directions), never from lamps: a straight bevel then reflects exactly
the same thing along its whole length, so the long runs stretch cleanly in a
9-slice while the curved corners, rivets and rings pick up crisp highlights.

    blender -b --factory-startup -P ui_kit.py -- [--samples 384] [--ss 2] [--only plate,round]
Outputs: _renders/ui/<piece>.png  (2x the final size, RGBA)
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402
import numpy as np  # noqa: E402

import common as C  # noqa: E402
import ui_geom as G  # noqa: E402

SAMPLES = C.arg("samples", 384)
SS = C.arg("ss", 2)                 # render at SS x the final size
ONLY = C.arg("only", "")

# metal F0 colours (linear); the dark faces get their body from base colour + coat
BRONZE = (0.72, 0.43, 0.21, 1)
BRONZE_BRIGHT = (0.86, 0.57, 0.30, 1)
GOLD = (1.00, 0.75, 0.29, 1)
GOLD_PALE = (1.00, 0.86, 0.52, 1)
STEEL = (0.60, 0.61, 0.64, 1)
BLACKENED = (0.045, 0.038, 0.034, 1)

STYLE = {   # rim, rim2 (outer steel band of the panel), bracket, rivet, face
    "plate":         dict(rim=BRONZE, rim2=BRONZE, brk=BRONZE, rivet=BRONZE_BRIGHT, face="iron"),
    "plate_primary": dict(rim=GOLD, rim2=GOLD, brk=GOLD, rivet=GOLD_PALE, face="molten"),
    "panel":         dict(rim=BRONZE, rim2=STEEL, brk=BRONZE, rivet=BRONZE_BRIGHT, face="panel"),
    "panel_gold":    dict(rim=GOLD, rim2=GOLD_PALE, brk=GOLD, rivet=GOLD_PALE, face="panel_warm"),
    "round":         dict(rim=BRONZE, rim2=BRONZE, brk=BRONZE, rivet=BRONZE_BRIGHT, face="dish"),
    "round_active":  dict(rim=GOLD, rim2=GOLD, brk=GOLD, rivet=GOLD_PALE, face="dish_hot"),
    "tab":           dict(rim=BRONZE, rim2=BRONZE, brk=BRONZE, rivet=BRONZE_BRIGHT, face="iron"),
}
ATTRS = ("w_rim", "w_rim2", "w_groove", "w_face", "w_brk", "w_rivet", "fy", "rd", "top", "edge")


# --------------------------------------------------------------------------
# geometry
# --------------------------------------------------------------------------
def build_mesh(name):
    """Heightfield grid with one vertex per render pixel corner; quads fully
    outside the silhouette are dropped. Material weights become attributes."""
    w, h = G.PIECES[name]["size"]
    nx, ny = w * SS, h * SS
    xs = np.arange(nx + 1, dtype=np.float64) / SS
    ys = np.arange(ny + 1, dtype=np.float64) / SS
    X, Y = np.meshgrid(xs, ys)
    f = G.evaluate(name, X, Y)
    co = np.stack([X - w / 2, h / 2 - Y, f["z"]], -1).reshape(-1, 3)
    idx = np.arange((nx + 1) * (ny + 1)).reshape(ny + 1, nx + 1)
    # quad (j, i) -> verts, counter-clockwise seen from +Z (y grows downwards)
    a = idx[1:, :-1]
    b = idx[1:, 1:]
    c = idx[:-1, 1:]
    d = idx[:-1, :-1]
    quads = np.stack([a, b, c, d], -1).reshape(-1, 4)
    dmax = np.maximum.reduce([f["d"].ravel()[quads[:, k]] for k in range(4)])
    quads = quads[dmax > -1.5]
    used = np.unique(quads)
    remap = np.full(co.shape[0], -1, np.int64)
    remap[used] = np.arange(used.size)
    co = co[used]
    quads = remap[quads]

    me = bpy.data.meshes.new(name)
    me.vertices.add(co.shape[0])
    me.vertices.foreach_set("co", co.astype(np.float32).ravel())
    me.loops.add(quads.size)
    me.loops.foreach_set("vertex_index", quads.astype(np.int32).ravel())
    me.polygons.add(quads.shape[0])
    me.polygons.foreach_set("loop_start", np.arange(0, quads.size, 4, dtype=np.int32))
    me.update(calc_edges=True)
    me.polygons.foreach_set("use_smooth", np.ones(quads.shape[0], dtype=bool))
    for key in ATTRS:
        vals = f.get(key)
        if vals is None:
            vals = np.zeros_like(f["z"])
        at = me.attributes.new(key, "FLOAT", "POINT")
        at.data.foreach_set("value", np.asarray(vals, np.float32).ravel()[used])
    me.update()
    ob = bpy.data.objects.new(name, me)
    C.link(ob)
    return ob


# --------------------------------------------------------------------------
# studio environment (the only light)
# --------------------------------------------------------------------------
def studio_world(warm=1.0):
    """Procedural 'HDRI': a dark dome with softbox strips. Directions: +Y is
    up the screen, +Z towards the camera. A surface tilted by t degrees
    reflects elevation 90 - 2t, so each strip lights one band of bevel slopes."""
    w = bpy.context.scene.world
    w.cycles.sampling_method = "MANUAL"
    w.cycles.sample_map_resolution = 2048
    n = C.NT(w)
    tc = n.node("ShaderNodeTexCoord")
    nrm = n.node("ShaderNodeVectorMath", _operation="NORMALIZE")
    n.link(tc.outputs["Generated"], nrm.inputs[0])
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(nrm.outputs[0], sep.inputs[0])
    dz = sep.outputs[2]
    el = n.math("DEGREES", n.math("ARCSINE", dz))
    az = n.math("ABSOLUTE", n.math("DEGREES", n.math("ARCTAN2", sep.outputs[0], sep.outputs[1])))
    # faint large-scale variation so curved metal never looks CG-perfect
    nz = n.node("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 2.2
    nz.inputs["Detail"].default_value = 2.0
    n.link(nrm.outputs[0], nz.inputs["Vector"])
    var = n.maprange(nz.outputs[0], 0.3, 0.7, 0.82, 1.15)

    def win(v, a, b, soft):
        up = n.maprange(v, a - soft, a + soft, 0.0, 1.0, interp="SMOOTHSTEP")
        dn = n.maprange(v, b - soft, b + soft, 0.0, 1.0, interp="SMOOTHSTEP")
        return n.math("MULTIPLY", up, n.math("SUBTRACT", 1.0, dn))

    shaders = []

    def light(col, strength, weight):
        bg = n.node("ShaderNodeBackground")
        bg.inputs["Color"].default_value = (*col, 1)
        n.link(n.math("MULTIPLY", n.math("MULTIPLY", weight, var), strength), bg.inputs["Strength"])
        shaders.append(bg.outputs[0])

    wcol = (1.0, 0.86 + 0.07 * (1 - warm), 0.70 + 0.15 * (1 - warm))
    # dome: dark zenith (flat faces stay dark), warmer towards the horizon
    dome = n.ramp(n.maprange(dz, -1.0, 1.0, 0.0, 1.0),
                  [(0.0, (0, 0, 0, 1)), (0.49, (0.0, 0.0, 0.0, 1)),
                   (0.5, (0.20, 0.15, 0.11, 1)), (0.56, (0.11, 0.085, 0.07, 1)),
                   (0.75, (0.085, 0.07, 0.058, 1)), (1.0, (0.075, 0.064, 0.055, 1))])
    bgd = n.node("ShaderNodeBackground")
    n.link(dome, bgd.inputs["Color"])
    n.link(var, bgd.inputs["Strength"])
    shaders.append(bgd.outputs[0])
    # key strip up-screen: the bright line along the top bevels
    light(wcol, 8.0, n.math("MULTIPLY", win(el, 24, 40, 2.0), win(az, -90, 58, 6)))
    # small hot spot up-left: a specular glint that only curved corners, rivets
    # and rings can see (straight runs face exactly up/down/left/right)
    az_signed = n.math("DEGREES", n.math("ARCTAN2", sep.outputs[0], sep.outputs[1]))
    light((1.0, 0.96, 0.9), 14.0, n.math("MULTIPLY", win(el, 26, 44, 3),
                                         win(az_signed, -52, -30, 4)))
    # big soft top light up-screen: sheen on the faces' upper slopes, crowns
    light((1.0, 0.87, 0.70), 1.3, n.math("MULTIPLY", win(el, 52, 84, 7), win(az, -90, 35, 30)))
    # side strips, slightly cool: the ends of the plates still shine
    light((0.86, 0.91, 1.0), 2.2, n.math("MULTIPLY", win(el, 20, 46, 3), win(az, 66, 114, 6)))
    # low warm kicker from below (the forge): an ember edge on the bottom bevels
    light((1.0, 0.55, 0.26), 1.1, n.math("MULTIPLY", win(el, 12, 38, 4), win(az, 142, 200, 8)))
    # thin horizon ring: a faint line on every outer roll
    light((1.0, 0.82, 0.62), 0.5, win(el, 1, 8, 2))
    acc = shaders[0]
    for s in shaders[1:]:
        add = n.node("ShaderNodeAddShader")
        n.link(acc, add.inputs[0])
        n.link(s, add.inputs[1])
        acc = add.outputs[0]
    out = n.node("ShaderNodeOutputWorld")
    n.link(acc, out.inputs["Surface"])


# --------------------------------------------------------------------------
# materials
# --------------------------------------------------------------------------
def attr(n, key):
    a = n.node("ShaderNodeAttribute", _attribute_type="GEOMETRY", _attribute_name=key)
    return a.outputs["Fac"]


def micro_normal(n, scale=0.9, strength=0.05, hammer=0.0, hammer_cell=7.0):
    """Fine grain (+ optional hammer-peen facets) as a bump normal. Object
    coordinates are image pixels, so scales are in px."""
    tc = n.texcoord()
    grain = n.node("ShaderNodeTexNoise")
    grain.inputs["Scale"].default_value = scale
    grain.inputs["Detail"].default_value = 4.0
    grain.inputs["Roughness"].default_value = 0.6
    n.link(tc.outputs["Object"], grain.inputs["Vector"])
    b = n.node("ShaderNodeBump")
    b.inputs["Strength"].default_value = strength
    b.inputs["Distance"].default_value = 0.4
    n.link(grain.outputs[0], b.inputs["Height"])
    if hammer > 0:
        vor = n.node("ShaderNodeTexVoronoi", _feature="SMOOTH_F1")
        vor.inputs["Scale"].default_value = 1.0 / hammer_cell
        vor.inputs["Smoothness"].default_value = 0.7
        n.link(tc.outputs["Object"], vor.inputs["Vector"])
        hb = n.node("ShaderNodeBump")
        hb.inputs["Strength"].default_value = hammer
        hb.inputs["Distance"].default_value = 1.5
        n.link(vor.outputs["Distance"], hb.inputs["Height"])
        n.link(hb.outputs[0], b.inputs["Normal"])
    return b.outputs[0]


def metal_bsdf(n, color, rough=0.14, grain=0.03):
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = color
    p.inputs["Metallic"].default_value = 1.0
    tc = n.texcoord()
    rn = n.node("ShaderNodeTexNoise")
    rn.inputs["Scale"].default_value = 0.08
    rn.inputs["Detail"].default_value = 3.0
    n.link(tc.outputs["Object"], rn.inputs["Vector"])
    n.link(n.maprange(rn.outputs[0], 0.3, 0.7, rough * 0.85, rough * 1.2), p.inputs["Roughness"])
    if grain > 0:
        n.link(micro_normal(n, scale=1.1, strength=grain), p.inputs["Normal"])
    return p.outputs[0]


def face_bsdf(n, kind):
    p = n.node("ShaderNodeBsdfPrincipled")
    fy = attr(n, "fy")
    if kind in ("iron", "panel", "panel_warm", "dish"):
        base = {"iron": "#1F1712", "panel": "#100B08", "panel_warm": "#1C120B",
                "dish": "#1A1410"}[kind]
        col = C.hex_lin(base)
        if kind in ("panel", "panel_warm"):
            lift = C.hex_lin("#2C2119" if kind == "panel" else "#3C2A1A")
            col = n.mix(col, lift, attr(n, "top"))
        else:
            # forged face: a touch lighter towards the top, sootier at the bottom
            col = n.ramp(fy, [(0.0, C.hex_lin("#33261C")), (0.45, C.hex_lin(base)),
                              (1.0, C.hex_lin("#140F0C"))])
        n.link(col, p.inputs["Base Color"])
        panel = kind in ("panel", "panel_warm")
        p.inputs["Metallic"].default_value = 0.3 if panel else 0.5
        p.inputs["Specular IOR Level"].default_value = 0.22 if panel else 0.35
        p.inputs["Roughness"].default_value = 0.42
        p.inputs["Coat Weight"].default_value = 0.6 if panel else 1.0
        p.inputs["Coat Roughness"].default_value = 0.09 if kind != "dish" else 0.16
        p.inputs["Coat IOR"].default_value = 1.8 if kind == "dish" else 1.55
        hammer = 0.15 if kind in ("iron", "dish") else 0.0
        n.link(micro_normal(n, scale=1.0, strength=0.05, hammer=hammer, hammer_cell=4.0),
               p.inputs["Normal"])
        return p.outputs[0]
    # molten faces: emission in palette colours + a glassy coat for real specular
    p.inputs["Base Color"].default_value = C.hex_lin("#5A1A06")
    p.inputs["Metallic"].default_value = 0.0
    p.inputs["Roughness"].default_value = 0.5
    if kind == "molten":
        heat = n.ramp(fy, [(0.0, C.hex_lin("#FFC45E")), (0.48, C.hex_lin("#FFB23F")),
                           (1.0, C.hex_lin("#FF6A13"))])
    else:   # dish_hot: radial, hottest in the middle
        heat = n.ramp(attr(n, "rd"), [(0.0, C.hex_lin("#FFC65E")), (0.45, C.hex_lin("#FFB23F")),
                                      (0.85, C.hex_lin("#FF7A1A")), (1.0, C.hex_lin("#E8550E"))])
    # very faint molten shimmer (low contrast, fine: survives a 9-slice stretch)
    tc = n.texcoord()
    sh = n.node("ShaderNodeTexNoise")
    sh.inputs["Scale"].default_value = 0.12
    sh.inputs["Detail"].default_value = 3.0
    n.link(tc.outputs["Object"], sh.inputs["Vector"])
    heat = n.mix(heat, n.mix(heat, C.hex_lin("#FFE2A0"), 0.5), n.maprange(sh.outputs[0], 0.55, 0.8, 0.0, 0.08))
    if kind == "molten":
        # cooler ember where the cushion dips into the groove (fixed border bands only)
        cool = n.math("SUBTRACT", 1.0, attr(n, "edge"))
        heat = n.mix(heat, C.hex_lin("#E0480C"), n.math("MULTIPLY", cool, 0.5))
        stren = n.maprange(cool, 0.0, 1.0, 1.0, 0.8)
    else:
        stren = n.maprange(attr(n, "rd"), 0.75, 1.0, 1.0, 0.8)
    n.link(heat, p.inputs["Emission Color"])
    n.link(stren, p.inputs["Emission Strength"])
    p.inputs["Coat Weight"].default_value = 1.0
    p.inputs["Coat Roughness"].default_value = 0.05
    p.inputs["Coat IOR"].default_value = 2.2
    return p.outputs[0]


def piece_material(name):
    st = STYLE[name]
    m = C.new_material(name + "Mat")
    n = C.NT(m)
    sh = face_bsdf(n, st["face"])
    layers = [
        ("w_groove", metal_bsdf(n, BLACKENED, rough=0.38, grain=0.0)),
        ("w_rim", metal_bsdf(n, st["rim"], rough=0.13)),
        ("w_rim2", metal_bsdf(n, st["rim2"], rough=0.11)),
        ("w_brk", metal_bsdf(n, st["brk"], rough=0.17, grain=0.05)),
        ("w_rivet", metal_bsdf(n, st["rivet"], rough=0.1, grain=0.0)),
    ]
    for key, bsdf in layers:
        mix = n.node("ShaderNodeMixShader")
        n.link(attr(n, key), mix.inputs[0])
        n.link(sh, mix.inputs[1])
        n.link(bsdf, mix.inputs[2])
        sh = mix.outputs[0]
    n.output(sh)
    return m


# --------------------------------------------------------------------------
def render_piece(name):
    C.reset()
    w, h = G.PIECES[name]["size"]
    sc = C.setup_cycles((w * SS, h * SS), samples=SAMPLES, transparent=True,
                        view="Standard", bounces=8, clamp=20.0, adaptive_threshold=0.004)
    sc.cycles.glossy_bounces = 6
    sc.cycles.filter_width = 1.2
    studio_world(warm=1.0 if "gold" not in name and "primary" not in name else 0.8)
    ob = build_mesh(name)
    C.assign(ob, piece_material(name))
    C.ortho_camera(float(max(w, h)), loc=(0, 0, 60))
    C.render(name, "ui")


def main():
    for name in G.PIECES:
        if ONLY and name not in ONLY.split(","):
            continue
        render_piece(name)


if __name__ == "__main__":
    main()
