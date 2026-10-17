"""Scene kit for the background renders (bpy): materials, room shell, brick
hearth with glowing coals, stump, barrel, tool rack, haze volume, embers.

Everything is chunky and slightly rounded (bevel modifiers), textured with
CC0 ambientCG sets from art/third_party/blender/ambientcg/.
"""
import math
import random

import bpy
from mathutils import Vector

import common as C
import props as P


# --------------------------------------------------------------------------
# materials
# --------------------------------------------------------------------------
def tex_material(name, asset, scale=1.0, value=1.0, sat=1.0, tint=None,
                 tint_fac=0.0, rough=(0.6, 1.0), normal=1.0, coord="Object",
                 proj="BOX", soot=0.0, soot_color="#120C08", soot_axis="Z",
                 soot_range=(0.0, 1.0), emission=None):
    """Principled material from an ambientCG set, with value/saturation,
    optional tint and an optional soot gradient along an axis (world space)."""
    t = C.tex_set(asset)
    m = C.new_material(name)
    n = C.NT(m)
    tc = n.texcoord()
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (scale, scale, scale)
    n.link(tc.outputs[coord], mp.inputs[0])
    vec = mp.outputs[0]
    col = n.image(t["Color"], vec, "sRGB", proj).outputs[0]
    hsv = n.node("ShaderNodeHueSaturation")
    n.set(hsv, "Color", col)
    hsv.inputs["Value"].default_value = value
    hsv.inputs["Saturation"].default_value = sat
    col = hsv.outputs[0]
    if tint is not None and tint_fac > 0:
        col = n.mix(col, C.hex_lin(tint), tint_fac, blend="MULTIPLY")
    if "AmbientOcclusion" in t:
        ao = n.image(t["AmbientOcclusion"], vec, "Non-Color", proj).outputs[0]
        col = n.mix(col, ao, 0.6, blend="MULTIPLY")
    if soot > 0:
        geo = n.node("ShaderNodeNewGeometry")
        sep = n.node("ShaderNodeSeparateXYZ")
        n.link(geo.outputs["Position"], sep.inputs[0])
        ax = {"X": 0, "Y": 1, "Z": 2}[soot_axis]
        f = n.maprange(sep.outputs[ax], soot_range[0], soot_range[1], 0.0, soot)
        col = n.mix(col, C.hex_lin(soot_color), f)
    p = n.node("ShaderNodeBsdfPrincipled")
    n.link(col, p.inputs["Base Color"])
    if "Roughness" in t:
        r = n.image(t["Roughness"], vec, "Non-Color", proj).outputs[0]
        n.link(n.maprange(r, 0, 1, rough[0], rough[1]), p.inputs["Roughness"])
    if "NormalGL" in t and normal > 0:
        nm = n.node("ShaderNodeNormalMap")
        nm.inputs["Strength"].default_value = normal
        n.link(n.image(t["NormalGL"], vec, "Non-Color", proj).outputs[0],
               nm.inputs["Color"])
        n.link(nm.outputs[0], p.inputs["Normal"])
    if emission is not None:
        p.inputs["Emission Color"].default_value = emission[0]
        p.inputs["Emission Strength"].default_value = emission[1]
    n.output(p.outputs[0])
    return m


def flat_material(name, color, rough=0.8, metallic=0.0, emission=None):
    m = C.new_material(name)
    n = C.NT(m)
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = C.hex_lin(color) if isinstance(color, str) else color
    p.inputs["Roughness"].default_value = rough
    p.inputs["Metallic"].default_value = metallic
    if emission is not None:
        p.inputs["Emission Color"].default_value = emission[0]
        p.inputs["Emission Strength"].default_value = emission[1]
    n.output(p.outputs[0])
    return m


def coals_material(name="Coals", strength=6.0):
    """Glowing coal bed: dark chunks (Voronoi cells) with hot cracks."""
    m = C.new_material(name)
    n = C.NT(m)
    tc = n.texcoord()
    vor = n.node("ShaderNodeTexVoronoi", _feature="DISTANCE_TO_EDGE")
    vor.inputs["Scale"].default_value = 9.0
    n.link(tc.outputs["Object"], vor.inputs["Vector"])
    noise = n.node("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 2.5
    noise.inputs["Detail"].default_value = 4.0
    n.link(tc.outputs["Object"], noise.inputs["Vector"])
    crack = n.maprange(vor.outputs["Distance"], 0.0, 0.12, 1.0, 0.0)
    heat = n.math("ADD", n.math("MULTIPLY", crack, 0.8),
                  n.maprange(noise.outputs[0], 0.35, 0.75, 0.0, 0.6))
    # hotter in the middle of the bed
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Object"], sep.inputs[0])
    r = n.math("SQRT", n.math("ADD", n.math("MULTIPLY", sep.outputs[0], sep.outputs[0]),
                              n.math("MULTIPLY", sep.outputs[1], sep.outputs[1])))
    centre = n.maprange(r, 0.0, 1.0, 1.0, 0.25)
    heat = n.math("MULTIPLY", heat, centre)
    col = n.ramp(heat, [(0.0, (0, 0, 0, 1)), (0.25, C.hex_lin("#5A1406")),
                        (0.5, C.hex_lin("#FF6A13")), (0.8, C.hex_lin("#FFB23F")),
                        (1.0, C.hex_lin("#FFF1D0"))])
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = C.hex_lin("#141010")
    p.inputs["Roughness"].default_value = 0.9
    n.link(col, p.inputs["Emission Color"])
    p.inputs["Emission Strength"].default_value = strength
    bump = n.node("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.6
    n.link(vor.outputs["Distance"], bump.inputs["Height"])
    n.link(bump.outputs[0], p.inputs["Normal"])
    n.output(p.outputs[0])
    return m


def water_material(name="Water", color="#0A0F12", rough=0.05):
    m = C.new_material(name)
    n = C.NT(m)
    tc = n.texcoord()
    noise = n.node("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 6.0
    noise.inputs["Detail"].default_value = 3.0
    n.link(tc.outputs["Object"], noise.inputs["Vector"])
    bump = n.node("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.08
    n.link(noise.outputs[0], bump.inputs["Height"])
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = C.hex_lin(color)
    p.inputs["Roughness"].default_value = rough
    p.inputs["Specular IOR Level"].default_value = 0.7
    n.link(bump.outputs[0], p.inputs["Normal"])
    n.output(p.outputs[0])
    return m


# --------------------------------------------------------------------------
# geometry helpers
# --------------------------------------------------------------------------
def box(name, loc, size, mat=None, bevel=0.03, segments=2, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc,
                                    rotation=[math.radians(a) for a in rot])
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = size
    C.apply_transform(ob)
    if bevel > 0:
        b = ob.modifiers.new("Bevel", "BEVEL")
        b.width = bevel
        b.segments = segments
    if mat:
        C.assign(ob, mat)
    return ob


def plane(name, loc, size, rot=(0, 0, 0), mat=None):
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc,
                                     rotation=[math.radians(a) for a in rot])
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = (size[0], size[1], 1)
    C.apply_transform(ob)
    if mat:
        C.assign(ob, mat)
    return ob


def cylinder(name, loc, radius, depth, mat=None, verts=48, bevel=0.0, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius, depth=depth,
                                        location=loc,
                                        rotation=[math.radians(a) for a in rot])
    ob = bpy.context.active_object
    ob.name = name
    C.shade_smooth(ob, auto_angle=40)
    if bevel > 0:
        b = ob.modifiers.new("Bevel", "BEVEL")
        b.width = bevel
        b.segments = 3
        b.limit_method = "ANGLE"
    if mat:
        C.assign(ob, mat)
    return ob


# --------------------------------------------------------------------------
# props
# --------------------------------------------------------------------------
def hearth(loc=(0, 0, 0), w=1.9, d=1.3, h=0.85, brick=None, hood=None,
           coal_strength=7.0, light_energy=900.0, hood_top=3.4, flue_top=8.0):
    """Brick forge with a glowing coal bed, a sooty hood and a flue."""
    x, y, z = loc
    objs = []
    objs.append(box("HearthBase", (x, y, z + h / 2), (w, d, h), brick, bevel=0.05))
    # raised brick lip around the fire pot
    lip_h = 0.12
    for i, (dx, dy, sx, sy) in enumerate([(0, d / 2 - 0.08, w, 0.16),
                                          (0, -d / 2 + 0.08, w, 0.16),
                                          (w / 2 - 0.08, 0, 0.16, d),
                                          (-w / 2 + 0.08, 0, 0.16, d)]):
        objs.append(box(f"HearthLip{i}", (x + dx, y + dy, z + h + lip_h / 2),
                        (sx, sy, lip_h), brick, bevel=0.03))
    # coal bed: displaced disc, slightly mounded
    bpy.ops.mesh.primitive_circle_add(vertices=64, radius=1.0, fill_type="TRIFAN",
                                      location=(x, y, z + h + 0.05))
    coal = bpy.context.active_object
    coal.name = "Coals"
    coal.scale = (w * 0.38, d * 0.34, 1)
    C.apply_transform(coal)
    sub = coal.modifiers.new("Sub", "SUBSURF")
    sub.subdivision_type = "SIMPLE"
    sub.levels = sub.render_levels = 4
    tex = bpy.data.textures.new("coal_lumps", "VORONOI")
    tex.noise_scale = 0.09
    disp = coal.modifiers.new("Lumps", "DISPLACE")
    disp.texture = tex
    disp.strength = 0.06
    disp.texture_coords = "GLOBAL"
    C.assign(coal, coals_material(strength=coal_strength))
    objs.append(coal)
    # fire light (soft, orange) just above the coals + an upward splash
    C.point_light("FireLight", (x, y, z + h + 0.45), light_energy, radius=0.35,
                  color=(1.0, 0.45, 0.14))
    C.point_light("FireLightLow", (x, y - d * 0.3, z + h + 0.2), light_energy * 0.35,
                  radius=0.25, color=(1.0, 0.38, 0.1))
    # hood: truncated pyramid
    hood_b = z + h + 1.0
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, y + 0.05, (hood_b + hood_top) / 2))
    hd = bpy.context.active_object
    hd.name = "Hood"
    hd.scale = (w * 1.05, d * 1.0, hood_top - hood_b)
    C.apply_transform(hd)
    for v in hd.data.vertices:
        if v.co.z > 0:
            v.co.x *= 0.42
            v.co.y = v.co.y * 0.45 + d * 0.2
    b = hd.modifiers.new("Bevel", "BEVEL")
    b.width = 0.04
    b.segments = 2
    C.assign(hd, hood)
    objs.append(hd)
    objs.append(box("Flue", (x, y + d * 0.2 + 0.05, (hood_top + flue_top) / 2),
                    (w * 0.44, d * 0.45, flue_top - hood_top), hood, bevel=0.03))
    return objs


def stump(name, loc, radius=0.36, height=0.45, mat=None, top_mat=None):
    x, y, z = loc
    ob = cylinder(name, (x, y, z + height / 2), radius, height, mat, verts=40, bevel=0.03)
    for v in ob.data.vertices:          # slightly irregular, wider foot
        k = 1.0 + 0.08 * (0.5 - (v.co.z / height + 0.5))
        a = math.atan2(v.co.y, v.co.x)
        k *= 1.0 + 0.04 * math.sin(3 * a + 1.3)
        v.co.x *= k
        v.co.y *= k
    if top_mat:
        ob.data.materials.append(top_mat)
        for p in ob.data.polygons:
            if p.normal.z > 0.9:
                p.material_index = 1
    return ob


def barrel(name, loc, radius=0.38, height=0.9, wood=None, iron=None, water=None):
    x, y, z = loc
    prof = []
    n = 24
    for i in range(n + 1):
        t = i / n
        r = radius * (0.86 + 0.14 * math.sin(math.pi * t))
        prof.append((r, height * t))
    prof = [(0.0, 0.0)] + prof + [(radius * 0.86 - 0.03, height), (radius * 0.86 - 0.03, height - 0.06),
                                  (0.0, height - 0.06)]
    ob = C.lathe(name, prof, segments=48)
    ob.location = loc
    if wood:
        C.assign(ob, wood)
    objs = [ob]
    for i, t in enumerate((0.12, 0.38, 0.62, 0.88)):
        r = radius * (0.86 + 0.14 * math.sin(math.pi * t)) + 0.006
        bpy.ops.mesh.primitive_torus_add(major_radius=r, minor_radius=0.014,
                                         major_segments=64, minor_segments=8,
                                         location=(x, y, z + height * t))
        hoop = bpy.context.active_object
        hoop.name = f"{name}Hoop{i}"
        hoop.scale = (1, 1, 2.2)
        if iron:
            C.assign(hoop, iron)
        objs.append(hoop)
    if water:
        bpy.ops.mesh.primitive_circle_add(vertices=48, radius=radius * 0.86 - 0.03,
                                          fill_type="NGON", location=(x, y, z + height - 0.1))
        w = bpy.context.active_object
        w.name = f"{name}Water"
        C.assign(w, water)
        objs.append(w)
    return objs


def tool_rack(loc, along="Y", length=2.2, wood=None, iron=None, handle=None,
              seed=4, facing=-1):
    """Plank on a wall with hammers and tongs hanging from pegs.
    along: wall direction ('Y' for side walls, 'X' for back wall)."""
    x, y, z = loc
    rnd = random.Random(seed)
    objs = []
    if along == "Y":
        objs.append(box("RackBoard", (x, y, z), (0.06, length, 0.22), wood, bevel=0.015))
    else:
        objs.append(box("RackBoard", (x, y, z), (length, 0.06, 0.22), wood, bevel=0.015))
    slots = 6
    for i in range(slots):
        t = (i + 0.5) / slots - 0.5
        px = x + (0 if along == "Y" else t * length)
        py = y + (t * length if along == "Y" else 0)
        off = 0.09 * facing
        if along == "Y":
            px += off
        else:
            py += off
        kind = ("hammer", "tongs", "hammer", "tongs", "hammer", "hammer")[i]
        if kind == "hammer":
            hl = rnd.uniform(0.32, 0.45)
            hm = P.hammer(f"RackHammer{i}", iron, handle, head_len=hl * 0.55,
                          head_w=hl * 0.2, handle_len=hl * 1.6, pein_axis="z",
                          handle_r=0.018)
            hm.location = (px, py, z + 0.12)
            hm.rotation_euler = (0, 0, math.radians(90 if along == "Y" else 0))
            # hang: head on top, handle down (handle already points -Z)
            objs.append(hm)
        else:
            tg = P.tongs(f"RackTongs{i}", iron, length=rnd.uniform(0.7, 0.9))
            tg.location = (px, py, z - 0.85)
            tg.rotation_euler = (0, 0, math.radians(90 if along == "Y" else 0))
            objs.append(tg)
    return objs


def haze(bounds_min, bounds_max, density=0.02, color=(1, 1, 1), anisotropy=0.35,
         noise=True, name="Haze"):
    c = [(a + b) / 2 for a, b in zip(bounds_min, bounds_max)]
    s = [(b - a) for a, b in zip(bounds_min, bounds_max)]
    bpy.ops.mesh.primitive_cube_add(size=1, location=c)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = s
    C.apply_transform(ob)
    m = C.new_material(name + "Mat")
    n = C.NT(m)
    vol = n.node("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = (*color[:3], 1)
    vol.inputs["Anisotropy"].default_value = anisotropy
    if noise:
        tc = n.texcoord()
        nz = n.node("ShaderNodeTexNoise")
        nz.inputs["Scale"].default_value = 0.35
        nz.inputs["Detail"].default_value = 3.0
        n.link(tc.outputs["Object"], nz.inputs["Vector"])
        dens = n.maprange(nz.outputs[0], 0.3, 0.7, density * 0.4, density * 1.6)
        n.link(dens, vol.inputs["Density"])
    else:
        vol.inputs["Density"].default_value = density
    out = n.node("ShaderNodeOutputMaterial")
    n.link(vol.outputs[0], out.inputs["Volume"])
    C.assign(ob, m)
    ob.visible_shadow = False
    return ob


def embers(region_min, region_max, count=40, seed=2, radius=0.008, strength=30.0):
    rnd = random.Random(seed)
    m = C.emission_material("Ember", C.hex_lin("#FF8A2A"), strength)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0)
    base = bpy.context.active_object
    base.name = "EmberBase"
    C.assign(base, m)
    base.hide_render = True
    obs = []
    for i in range(count):
        ob = bpy.data.objects.new(f"Ember{i}", base.data)
        C.link(ob)
        ob.location = [rnd.uniform(a, b) for a, b in zip(region_min, region_max)]
        r = radius * rnd.uniform(0.5, 1.4)
        ob.scale = (r, r, r * rnd.uniform(1.0, 3.0))
        ob.visible_shadow = False
        obs.append(ob)
    return obs
