"""Reusable stylised props (bpy): anvil, hammer, tongs, sparks, materials.

Chunky, rounded hard-surface shapes built from code so every scene and the
app icon share the same look. Units: metres-ish (anvil ~3.5 long).
"""
import math
import random

import bpy
from mathutils import Matrix, Vector

import common as C


# --------------------------------------------------------------------------
# materials
# --------------------------------------------------------------------------
def iron_material(name="Iron", base="#6E6C6A", rough=(0.38, 0.6), bump=0.18,
                  facet_scale=4.0, heat=None):
    """Dark forged iron: bright-ish specular colour (reads dark in a dark
    room), hammer-facet bump, ambientCG roughness/normal detail.
    heat=(color_lin, strength, mask_node_fn) optionally adds emission."""
    t = C.tex_set("Metal052C")
    m = C.new_material(name)
    n = C.NT(m)
    tc = n.texcoord()
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (0.6, 0.6, 0.6)
    n.link(tc.outputs["Object"], mp.inputs[0])
    rimg = n.image(t["Roughness"], mp.outputs[0], "Non-Color", proj="BOX").outputs[0]
    nimg = n.image(t["NormalGL"], mp.outputs[0], "Non-Color", proj="BOX").outputs[0]
    nm = n.node("ShaderNodeNormalMap")
    nm.inputs["Strength"].default_value = 0.5
    n.link(nimg, nm.inputs["Color"])
    vor = n.node("ShaderNodeTexVoronoi", _feature="SMOOTH_F1")
    vor.inputs["Scale"].default_value = facet_scale
    vor.inputs["Smoothness"].default_value = 0.5
    n.link(tc.outputs["Object"], vor.inputs["Vector"])
    b = n.node("ShaderNodeBump")
    b.inputs["Strength"].default_value = bump
    b.inputs["Distance"].default_value = 0.05
    n.link(vor.outputs["Distance"], b.inputs["Height"])
    n.link(nm.outputs[0], b.inputs["Normal"])
    p = n.node("ShaderNodeBsdfPrincipled")
    mott = n.node("ShaderNodeTexNoise")
    mott.inputs["Scale"].default_value = 2.5
    mott.inputs["Detail"].default_value = 6
    n.link(tc.outputs["Object"], mott.inputs["Vector"])
    bc = C.hex_lin(base)
    dark = tuple(c * 0.55 for c in bc[:3]) + (1,)
    col = n.ramp(mott.outputs[0], [(0.35, dark), (0.7, bc)])
    n.link(col, p.inputs["Base Color"])
    p.inputs["Metallic"].default_value = 0.9
    n.link(n.maprange(rimg, 0, 1, rough[0], rough[1]), p.inputs["Roughness"])
    n.link(b.outputs[0], p.inputs["Normal"])
    n.output(p.outputs[0])
    return m


def wood_material(name="Wood", value=0.55, scale=1.0, tint="#6A4428"):
    t = C.tex_set("Planks023A")
    m = C.new_material(name)
    n = C.NT(m)
    tc = n.texcoord()
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (scale, scale, scale)
    n.link(tc.outputs["Object"], mp.inputs[0])
    col = n.image(t["Color"], mp.outputs[0], proj="BOX").outputs[0]
    hsv = n.node("ShaderNodeHueSaturation")
    n.set(hsv, "Color", col)
    hsv.inputs["Value"].default_value = value
    hsv.inputs["Saturation"].default_value = 1.15
    col = n.mix(hsv.outputs[0], C.hex_lin(tint), 0.35, blend="MULTIPLY")
    p = n.node("ShaderNodeBsdfPrincipled")
    n.link(col, p.inputs["Base Color"])
    r = n.image(t["Roughness"], mp.outputs[0], "Non-Color", proj="BOX").outputs[0]
    n.link(n.maprange(r, 0, 1, 0.55, 0.85), p.inputs["Roughness"])
    nm = n.node("ShaderNodeNormalMap")
    nm.inputs["Strength"].default_value = 0.6
    n.link(n.image(t["NormalGL"], mp.outputs[0], "Non-Color", proj="BOX").outputs[0],
           nm.inputs["Color"])
    n.link(nm.outputs[0], p.inputs["Normal"])
    n.output(p.outputs[0])
    return m


def hot_metal_material(name="HotMetal", core="#FFC24A", edge="#FF6A13",
                       strength=3.0, radius=1.0):
    """Glowing metal: radial colour from core to edge in object space."""
    m = C.new_material(name)
    n = C.NT(m)
    tc = n.texcoord()
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Object"], sep.inputs[0])
    r = n.math("SQRT", n.math("ADD", n.math("MULTIPLY", sep.outputs[0], sep.outputs[0]),
                              n.math("MULTIPLY", sep.outputs[1], sep.outputs[1])))
    r = n.math("DIVIDE", r, radius)
    col = n.ramp(r, [(0.0, C.hex_lin(core)), (0.6, C.hex_lin(core)),
                     (0.92, C.hex_lin(edge)), (1.0, C.hex_lin("#C8341A"))])
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = C.hex_lin("#2A0E06")
    p.inputs["Roughness"].default_value = 0.4
    n.link(col, p.inputs["Emission Color"])
    p.inputs["Emission Strength"].default_value = strength
    n.output(p.outputs[0])
    return m


def spark_material(name="Spark", strength=12.0):
    """Emissive streak: white-hot head fading to orange tail (along local Z)."""
    m = C.new_material(name)
    n = C.NT(m)
    tc = n.texcoord()
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Generated"], sep.inputs[0])
    col = n.ramp(sep.outputs[2], [(0.0, C.hex_lin("#FF5A10")), (0.6, C.hex_lin("#FFB23F")),
                                  (1.0, C.hex_lin("#FFF1D0"))])
    stren = n.maprange(sep.outputs[2], 0.0, 1.0, strength * 0.25, strength)
    e = n.node("ShaderNodeEmission")
    n.link(col, e.inputs["Color"])
    n.link(stren, e.inputs["Strength"])
    n.output(e.outputs[0])
    return m


# --------------------------------------------------------------------------
# anvil
# --------------------------------------------------------------------------
ANVIL_PROFILE = [
    (-1.15, 0.00), (1.15, 0.00), (1.15, 0.20), (0.82, 0.34), (0.52, 0.62),
    (0.52, 0.92), (0.80, 1.16), (1.25, 1.30), (1.62, 1.36), (1.66, 1.62),
    (-1.00, 1.62), (-1.00, 1.36), (-0.74, 1.16), (-0.52, 0.92), (-0.52, 0.62),
    (-0.82, 0.34), (-1.15, 0.20),
]


def _densify(pts, step=0.05):
    out = []
    for i in range(len(pts)):
        a, b = Vector(pts[i]), Vector(pts[(i + 1) % len(pts)])
        k = max(1, int((b - a).length / step))
        for j in range(k):
            out.append(a.lerp(b, j / k))
    return out


def anvil(name="Anvil", mat=None, depth=1.0, location=(0, 0, 0), rot_z=0.0,
          bevel=0.06, horn_len=1.55):
    """Classic London-pattern anvil: extruded rounded side profile (face,
    heel, waist, feet) + a conical horn. Origin at floor centre."""
    cu = bpy.data.curves.new(name + "Curve", "CURVE")
    cu.dimensions = "2D"
    cu.fill_mode = "BOTH"
    cu.extrude = depth / 2 - bevel
    cu.bevel_depth = bevel
    cu.bevel_resolution = 4
    cu.resolution_u = 2
    sp = cu.splines.new("POLY")
    pts = _densify(ANVIL_PROFILE, 0.06)
    sp.points.add(len(pts) - 1)
    for p, v in zip(sp.points, pts):
        p.co = (v.x, v.y, 0, 1)
    sp.use_cyclic_u = True
    ob = bpy.data.objects.new(name, cu)
    C.link(ob)
    ob.rotation_euler = (math.pi / 2, 0, 0)       # profile X-Y -> X-Z
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.ops.object.convert(target="MESH")
    ob = bpy.context.active_object
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    # pinch the waist in depth (Y) for the classic silhouette
    for v in ob.data.vertices:
        z = v.co.z
        if z < 0.2:
            f = 1.0
        elif z < 0.55:
            f = 1.0 - 0.32 * (z - 0.2) / 0.35
        elif z < 1.0:
            f = 0.68
        elif z < 1.3:
            f = 0.68 + 0.32 * (z - 1.0) / 0.3
        else:
            f = 1.0
        v.co.y *= f
    C.shade_smooth(ob, auto_angle=40)
    # horn: cone along -X, top roughly flush with the face
    hr = 0.36
    bpy.ops.mesh.primitive_cone_add(vertices=48, radius1=hr, radius2=0.025,
                                    depth=horn_len,
                                    location=(-1.0 - horn_len / 2 + 0.06, 0, 1.62 - hr),
                                    rotation=(0, -math.pi / 2, 0))
    horn = bpy.context.active_object
    horn.name = name + "Horn"
    horn.scale = (1.0, depth / (2 * hr) * 0.9, 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    # bend the tip slightly up
    for v in horn.data.vertices:
        t = max(0.0, (-v.co.x - 0.0) / (horn_len / 2))
        v.co.z += 0.06 * t * t
    C.shade_smooth(horn)
    sub = horn.modifiers.new("Sub", "SUBSURF")
    sub.levels = sub.render_levels = 1
    # merge
    bpy.ops.object.select_all(action="DESELECT")
    horn.select_set(True)
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.convert(target="MESH")
    bpy.ops.object.join()
    ob = bpy.context.active_object
    ob.name = name
    if mat is not None:
        C.assign(ob, mat)
    ob.location = location
    ob.rotation_euler = (0, 0, rot_z)
    return ob


# --------------------------------------------------------------------------
# hammer
# --------------------------------------------------------------------------
def hammer(name="Hammer", head_mat=None, handle_mat=None, head_len=1.0,
           head_w=0.36, handle_len=2.3, pein_axis="z", handle_r=0.075):
    """Blacksmith's cross-pein hammer. Returns the root empty; the hammer
    head's striking face points -X at the root origin, handle along +Z."""
    root = bpy.data.objects.new(name, None)
    C.link(root)
    # head: box with chamfer, one end slightly domed (face), other a wedge pein
    bpy.ops.mesh.primitive_cube_add(size=1)
    head = bpy.context.active_object
    head.name = name + "Head"
    head.scale = (head_len, head_w, head_w)
    bpy.ops.object.transform_apply(scale=True)
    me = head.data
    for v in me.vertices:
        if v.co.x > 0:               # pein end: taper to a wedge
            if pein_axis == "z":
                v.co.z *= 0.35
            elif pein_axis == "y":
                v.co.y *= 0.35
    bv = head.modifiers.new("Bevel", "BEVEL")
    bv.width = 0.05 if pein_axis != "none" else head_w * 0.16
    bv.segments = 4
    sub = head.modifiers.new("Sub", "SUBSURF")
    sub.levels = sub.render_levels = 1
    C.shade_smooth(head)
    head.location = (head_len / 2, 0, 0)    # striking face at x=0
    if head_mat:
        C.assign(head, head_mat)
    head.parent = root
    # handle
    bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=handle_r, depth=handle_len)
    hd = bpy.context.active_object
    hd.name = name + "Handle"
    for v in hd.data.vertices:          # slight taper + oval
        t = (v.co.z / handle_len) + 0.5   # 0 bottom .. 1 top (at head)
        s = 1.0 + 0.25 * (1 - t)
        v.co.x *= s * 0.85
        v.co.y *= s
    bv = hd.modifiers.new("Bevel", "BEVEL")
    bv.width = 0.03
    bv.segments = 3
    C.shade_smooth(hd)
    hd.location = (head_len * 0.42, 0, -handle_len / 2 + 0.12)
    if handle_mat:
        C.assign(hd, handle_mat)
    hd.parent = root
    return root


# --------------------------------------------------------------------------
# tongs (simple, for walls)
# --------------------------------------------------------------------------
def tongs(name="Tongs", mat=None, length=1.6):
    root = bpy.data.objects.new(name, None)
    C.link(root)
    for side in (-1, 1):
        cu = bpy.data.curves.new(name + f"C{side}", "CURVE")
        cu.dimensions = "3D"
        cu.bevel_depth = 0.025
        cu.bevel_resolution = 3
        sp = cu.splines.new("BEZIER")
        pts = [(0.0, 0, 0), (0.05 * side, 0, length * 0.55), (0.0, 0, length * 0.7),
               (-0.08 * side, 0, length * 0.85), (-0.02 * side, 0, length)]
        sp.bezier_points.add(len(pts) - 1)
        for bp, p in zip(sp.bezier_points, pts):
            bp.co = p
            bp.handle_left_type = bp.handle_right_type = "AUTO"
        ob = bpy.data.objects.new(name + f"Arm{side}", cu)
        C.link(ob)
        ob.location = (0.06 * side, 0, 0)
        if mat:
            ob.data.materials.append(mat)
        ob.parent = root
    return root


# --------------------------------------------------------------------------
# sparks
# --------------------------------------------------------------------------
def sparks(origin, count=40, seed=1, direction=(0, 0, 1), spread=70.0,
           length=(0.15, 0.6), dist=(0.1, 1.6), radius=0.012, mat=None,
           name="Spark", gravity=0.0):
    """Thin emissive streaks flying out of `origin` (motion-blurred look)."""
    rnd = random.Random(seed)
    mat = mat or spark_material()
    d0 = Vector(direction).normalized()
    obs = []
    # one shared mesh: a capsule-ish cylinder from z=0..1 (Generated z grows)
    bpy.ops.mesh.primitive_cylinder_add(vertices=8, radius=1.0, depth=1.0,
                                        location=(0, 0, 0.5))
    base = bpy.context.active_object
    base.name = name + "Base"
    bpy.ops.object.transform_apply(location=True)
    for v in base.data.vertices:        # taper the tail
        v.co.x *= 0.35 + 0.65 * v.co.z
        v.co.y *= 0.35 + 0.65 * v.co.z
    C.assign(base, mat)
    base.hide_render = True
    base.hide_viewport = True
    for i in range(count):
        # random direction within a cone around d0
        while True:
            v = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(-1, 1)))
            if 0.05 < v.length <= 1.0:
                break
        v.normalize()
        ang = math.radians(spread) * rnd.random() ** 0.8
        axis = d0.cross(v)
        if axis.length < 1e-4:
            axis = Vector((1, 0, 0))
        axis.normalize()
        dirv = (Matrix.Rotation(ang, 3, axis) @ d0).normalized()
        dd = rnd.uniform(*dist)
        L = rnd.uniform(*length) * (0.6 + 0.6 * dd / dist[1])
        head_pos = Vector(origin) + dirv * dd
        head_pos.z -= gravity * dd * dd
        tail_pos = head_pos - dirv * L
        ob = bpy.data.objects.new(f"{name}{i}", base.data)
        C.link(ob)
        ob.location = tail_pos
        q = dirv.to_track_quat("Z", "Y")
        ob.rotation_euler = q.to_euler()
        rr = radius * rnd.uniform(0.6, 1.3)
        ob.scale = (rr, rr, L)
        ob.visible_shadow = False
        obs.append(ob)
    return obs
