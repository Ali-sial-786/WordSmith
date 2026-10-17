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
    warp = n.node("ShaderNodeTexNoise")
    warp.inputs["Scale"].default_value = 6.0
    warp.inputs["Detail"].default_value = 2.0
    n.link(tc.outputs["Object"], warp.inputs["Vector"])
    wv = n.node("ShaderNodeVectorMath", _operation="MULTIPLY_ADD")
    n.link(warp.outputs["Color"], wv.inputs[0])
    wv.inputs[1].default_value = (0.08, 0.08, 0.08)
    n.link(tc.outputs["Object"], wv.inputs[2])
    vor = n.node("ShaderNodeTexVoronoi", _feature="DISTANCE_TO_EDGE")
    vor.inputs["Scale"].default_value = 16.0
    n.link(wv.outputs[0], vor.inputs["Vector"])
    noise = n.node("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 3.0
    noise.inputs["Detail"].default_value = 4.0
    n.link(tc.outputs["Object"], noise.inputs["Vector"])
    crack = n.maprange(vor.outputs["Distance"], 0.0, 0.07, 1.0, 0.0)
    glowy = n.maprange(noise.outputs[0], 0.4, 0.7, 0.15, 1.0)
    heat = n.math("ADD", n.math("MULTIPLY", n.math("MULTIPLY", crack, glowy), 0.9),
                  n.maprange(noise.outputs[0], 0.5, 0.8, 0.0, 0.45))
    # hotter in the middle of the bed
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Object"], sep.inputs[0])
    r = n.math("SQRT", n.math("ADD", n.math("MULTIPLY", sep.outputs[0], sep.outputs[0]),
                              n.math("MULTIPLY", sep.outputs[1], sep.outputs[1])))
    centre = n.maprange(r, 0.0, 1.0, 1.0, 0.25)
    heat = n.math("MULTIPLY", heat, centre)
    col = n.ramp(heat, [(0.0, (0, 0, 0, 1)), (0.25, C.hex_lin("#5A1004")),
                        (0.5, C.hex_lin("#FF4A0A")), (0.8, C.hex_lin("#FF9A2A")),
                        (1.0, C.hex_lin("#FFE0A0"))])
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
    flame_volume((x, y, z + h + 0.32), size=(w * 0.36, d * 0.3, 0.42),
                 strength=coal_strength * 1.1)
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


def flame_volume(loc, size=(0.7, 0.45, 0.5), strength=6.0, name="Flame"):
    """Soft emissive fire glow (emission-only volume) above a coal bed."""
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=1.0,
                                         location=loc)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = size
    C.apply_transform(ob)
    m = C.new_material(name + "Mat")
    n = C.NT(m)
    tc = n.texcoord()
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Object"], sep.inputs[0])
    # radial falloff (object space), stronger at the bottom, licking upward
    lng = n.node("ShaderNodeVectorMath", _operation="LENGTH")
    n.link(tc.outputs["Object"], lng.inputs[0])
    fall = n.maprange(lng.outputs["Value"], 0.2, 1.0, 1.0, 0.0, interp="SMOOTHSTEP")
    up = n.maprange(sep.outputs[2], -size[2], size[2], 1.0, 0.25)
    nz = n.node("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 3.5
    nz.inputs["Detail"].default_value = 4.0
    mp = n.node("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (1.0, 1.0, 0.45)      # vertical streaks
    n.link(tc.outputs["Object"], mp.inputs[0])
    n.link(mp.outputs[0], nz.inputs["Vector"])
    lick = n.maprange(nz.outputs[0], 0.35, 0.75, 0.0, 1.0)
    dens = n.math("MULTIPLY", n.math("MULTIPLY", fall, up), lick)
    vol = n.node("ShaderNodeVolumePrincipled")
    vol.inputs["Density"].default_value = 0.0
    vol.inputs["Emission Color"].default_value = C.hex_lin("#FF5A0E")
    n.link(n.math("MULTIPLY", dens, strength), vol.inputs["Emission Strength"])
    out = n.node("ShaderNodeOutputMaterial")
    n.link(vol.outputs[0], out.inputs["Volume"])
    C.assign(ob, m)
    ob.visible_shadow = False
    return ob


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
    slots = max(2, int(round(length / 0.36)))
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


# --------------------------------------------------------------------------
# fire: stylised flame meshes + arched brick forge
# --------------------------------------------------------------------------
def flame_material(name="FlameMat", strength=9.0, alpha=0.85):
    """Emissive flame: white-yellow core at the base -> orange -> red tip,
    soft (partly transparent) towards the silhouette edges."""
    m = C.new_material(name)
    n = C.NT(m)
    tc = n.texcoord()
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Generated"], sep.inputs[0])
    col = n.ramp(sep.outputs[2], [(0.0, C.hex_lin("#FFE7B0")), (0.18, C.hex_lin("#FFC24A")),
                                  (0.45, C.hex_lin("#FF8A1E")), (0.75, C.hex_lin("#FF4A0E")),
                                  (1.0, C.hex_lin("#B8240A"))])
    stren = n.maprange(sep.outputs[2], 0.0, 1.0, strength, strength * 0.35)
    e = n.node("ShaderNodeEmission")
    n.link(col, e.inputs["Color"])
    n.link(stren, e.inputs["Strength"])
    lw = n.node("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.35
    edge = n.math("POWER", n.math("SUBTRACT", 1.0, lw.outputs["Facing"]), 1.5)
    a = n.math("MULTIPLY", edge, alpha)
    tip = n.maprange(sep.outputs[2], 0.6, 1.0, 1.0, 0.4)
    a = n.math("MULTIPLY", a, tip)
    tr = n.node("ShaderNodeBsdfTransparent")
    mix = n.node("ShaderNodeMixShader")
    n.link(a, mix.inputs[0])
    n.link(tr.outputs[0], mix.inputs[1])
    n.link(e.outputs[0], mix.inputs[2])
    n.output(mix.outputs[0])
    return m


def flame(name, base, height=0.8, width=0.22, seed=1, lean=(0.0, 0.0), mat=None):
    """One chunky stylised flame tongue (teardrop lathe, swaying upward)."""
    rnd = random.Random(seed)
    prof = []
    rings = 22
    for i in range(rings + 1):
        t = i / rings
        r = width * (math.sin(math.pi * min(1.0, t ** 0.55)) ** 1.1) * (1 - t) ** 0.35
        prof.append((max(r, 0.0), height * t))
    prof[0] = (0.0, 0.0)
    prof[-1] = (0.0, height)
    ob = C.lathe(name, prof, segments=20)
    ph, fq = rnd.uniform(0, 6.28), rnd.uniform(5.0, 8.0) / height
    amp = width * rnd.uniform(0.35, 0.7)
    for v in ob.data.vertices:
        t = v.co.z / height
        v.co.x += amp * math.sin(v.co.z * fq + ph) * t + lean[0] * t * t * height
        v.co.y += 0.4 * amp * math.cos(v.co.z * fq * 0.7 + ph) * t + lean[1] * t * t * height
    ob.location = base
    ob.visible_shadow = False
    if mat:
        C.assign(ob, mat)
    return ob


def fire(center, spread=(0.6, 0.3), count=9, height=0.9, width=0.2, seed=3,
         strength=9.0, name="Fire"):
    """A cluster of flame tongues: tall in the middle, smaller at the edges."""
    rnd = random.Random(seed)
    mat = flame_material(name + "Mat", strength=strength)
    obs = []
    for i in range(count):
        u = (i + 0.5) / count * 2 - 1           # -1..1 across the bed
        x = center[0] + u * spread[0] + rnd.uniform(-0.05, 0.05)
        y = center[1] + rnd.uniform(-spread[1], spread[1])
        k = (1 - 0.65 * abs(u)) * rnd.uniform(0.75, 1.15)
        obs.append(flame(f"{name}{i}", (x, y, center[2]), height * k, width * (0.7 + 0.5 * k),
                         seed=seed * 31 + i, lean=(-u * 0.15, 0.0), mat=mat))
    return obs


def hot_bar_material(name="HotBar"):
    """Iron bar: glowing yellow-orange at the far (+Y) end, cooling to dark."""
    m = C.new_material(name)
    n = C.NT(m)
    tc = n.texcoord()
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Generated"], sep.inputs[0])
    col = n.ramp(sep.outputs[1], [(0.0, (0, 0, 0, 1)), (0.45, (0, 0, 0, 1)),
                                  (0.6, C.hex_lin("#5A1406")), (0.75, C.hex_lin("#FF5A10")),
                                  (1.0, C.hex_lin("#FFD27A"))])
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = C.hex_lin("#55575C")
    p.inputs["Metallic"].default_value = 0.9
    p.inputs["Roughness"].default_value = 0.45
    n.link(col, p.inputs["Emission Color"])
    p.inputs["Emission Strength"].default_value = 6.0
    n.output(p.outputs[0])
    return m


def coal_heap(name, center, radius=(0.7, 0.45), height=0.22, strength=7.0):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, radius=1.0,
                                         location=center)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = (radius[0], radius[1], height)
    C.apply_transform(ob)
    tex = bpy.data.textures.new(name + "_lumps", "VORONOI")
    tex.noise_scale = 0.08
    d = ob.modifiers.new("Lumps", "DISPLACE")
    d.texture = tex
    d.strength = 0.07
    d.texture_coords = "GLOBAL"
    C.shade_smooth(ob)
    C.assign(ob, coals_material(name + "Mat", strength=strength))
    return ob


def arched_forge(loc=(0, 0, 0), w=2.7, d=1.5, h=2.0, mouth_w=1.5, mouth_h=1.05,
                 mouth_z=0.72, brick=None, iron=None, stone=None, chimney=None,
                 chimney_top=7.0, fire_strength=9.0, light=900.0, seed=3):
    """Brick forge with an arched fire mouth: coal heap and flames inside,
    stone apron in front, iron lintel band, chimney breast above.
    loc = centre of the front face at floor level; the forge extends +Y."""
    x, y0, z = loc
    yc = y0 + d / 2
    objs = []
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, yc, z + h / 2))
    blk = bpy.context.active_object
    blk.name = "ForgeBlock"
    blk.scale = (w, d, h)
    C.apply_transform(blk)
    # cutters: rectangular mouth + round arch on top, 70 % deep
    depth = d * 0.72
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, y0 + depth / 2 - 0.05,
                                                      z + mouth_z + (mouth_h - mouth_w / 2) / 2))
    c1 = bpy.context.active_object
    c1.scale = (mouth_w, depth + 0.1, mouth_h - mouth_w / 2)
    bpy.ops.mesh.primitive_cylinder_add(vertices=64, radius=mouth_w / 2, depth=depth + 0.1,
                                        location=(x, y0 + depth / 2 - 0.05,
                                                  z + mouth_z + mouth_h - mouth_w / 2),
                                        rotation=(math.pi / 2, 0, 0))
    c2 = bpy.context.active_object
    for c in (c1, c2):
        mod = blk.modifiers.new("Cut", "BOOLEAN")
        mod.operation = "DIFFERENCE"
        mod.object = c
        mod.solver = "EXACT"
    bpy.context.view_layer.objects.active = blk
    for mod in list(blk.modifiers):
        bpy.ops.object.modifier_apply(modifier=mod.name)
    for c in (c1, c2):
        bpy.data.objects.remove(c)
    if brick:
        C.assign(blk, brick)
    objs.append(blk)
    # the arch cylinder also cut below the mouth floor: fill that back in
    fill_b = z + mouth_z + mouth_h - mouth_w / 2 - mouth_w / 2 - 0.02
    objs.append(box("ForgeFill", (x, y0 + depth / 2, (fill_b + z + mouth_z) / 2),
                    (mouth_w + 0.02, depth + 0.02, z + mouth_z - fill_b), brick, bevel=0))
    # stone apron / ledge in front of the mouth
    objs.append(box("ForgeApron", (x, y0 - 0.22, z + mouth_z - 0.06), (w * 0.86, 0.5, 0.12),
                    stone or brick, bevel=0.03))
    # iron band across the lintel + corner plates
    if iron:
        objs.append(box("ForgeBand", (x, y0 - 0.03, z + mouth_z + mouth_h + 0.18),
                        (w * 1.02, 0.08, 0.16), iron, bevel=0.02))
    # chimney breast tapering up into the dark
    cb = z + h
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, yc + 0.1, (cb + chimney_top) / 2))
    ch = bpy.context.active_object
    ch.name = "Chimney"
    ch.scale = (w * 0.9, d * 0.8, chimney_top - cb)
    C.apply_transform(ch)
    for v in ch.data.vertices:
        if v.co.z > 0:
            v.co.x *= 0.62
            v.co.y = v.co.y * 0.7 + d * 0.06
    C.assign(ch, chimney or brick)
    objs.append(ch)
    # coals + flames inside the firebox
    fy = y0 + depth * 0.5
    objs.append(coal_heap("ForgeCoals", (x, fy, z + mouth_z), radius=(mouth_w * 0.42, depth * 0.36),
                          height=0.2, strength=fire_strength * 0.8))
    objs += fire((x, fy - 0.05, z + mouth_z + 0.06), spread=(mouth_w * 0.3, depth * 0.18),
                 count=9, height=mouth_h * 0.78, width=0.17, seed=seed,
                 strength=fire_strength)
    objs.append(flame_volume((x, fy - 0.1, z + mouth_z + 0.4),
                             size=(mouth_w * 0.45, depth * 0.35, mouth_h * 0.42),
                             strength=fire_strength * 0.5, name="ForgeGlow"))
    # an iron bar heating in the coals, its end resting on the apron
    bar_mat = hot_bar_material("HotBar")
    bar = box("HotBar", (x + 0.25, fy - depth * 0.15 - 0.35, z + mouth_z + 0.07),
              (0.05, depth * 0.9 + 0.7, 0.05), bar_mat, bevel=0.01,
              rot=(-4, 0, -14))
    objs.append(bar)
    # lights: inside the firebox and spilling out of the mouth
    C.point_light("ForgeFire", (x, fy, z + mouth_z + 0.45), light, radius=0.4,
                  color=(1.0, 0.42, 0.12))
    C.area_light("ForgeMouth", (x, y0 - 0.05, z + mouth_z + mouth_h * 0.45),
                 (x, y0 - 4.0, z + 0.4), light * 0.2, size=mouth_w * 0.8,
                 size_y=mouth_h * 0.6, shape="RECTANGLE", color=(1.0, 0.45, 0.15))
    return objs
