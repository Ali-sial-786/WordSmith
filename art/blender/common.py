"""Shared helpers for the Wordsmith Blender render scripts.

Imported by every scene script (tiles.py, anvil_face.py, ...). Runs inside
Blender's bundled Python (bpy); nothing here is usable from plain Python.

Conventions
-----------
* Raw renders go to art/blender/_renders/ (git-ignored); post.py turns them
  into the final optimised files in app/assets/images/.
* Third-party textures/models live in art/third_party/blender/ and are
  fetched by fetch_assets.py (pinned URLs + sha256 in sources.json).
* Script arguments come after "--":  blender -b -P tiles.py -- --samples 64
"""
import math
import os
import sys
import time

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
THIRD = os.path.join(REPO, "art", "third_party", "blender")
RAW = os.path.join(HERE, "_renders")
os.makedirs(RAW, exist_ok=True)


# --------------------------------------------------------------------------
# arguments
# --------------------------------------------------------------------------
def args():
    """Parse the arguments after '--' into a dict (--key value / --flag)."""
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            k = a[2:]
            if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                out[k] = argv[i + 1]
                i += 2
                continue
            out[k] = True
        i += 1
    return out


ARGS = args()


def arg(name, default):
    v = ARGS.get(name, default)
    if isinstance(default, bool):
        return bool(v)
    if isinstance(default, int):
        return int(v)
    if isinstance(default, float):
        return float(v)
    return v


# --------------------------------------------------------------------------
# colour helpers
# --------------------------------------------------------------------------
def srgb_to_lin(c):
    c = c / 255.0 if c > 1.0 else c
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_lin(h, a=1.0):
    """'#FF6A13' -> linear RGBA tuple for shader sockets."""
    h = h.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return (srgb_to_lin(r), srgb_to_lin(g), srgb_to_lin(b), a)


# --------------------------------------------------------------------------
# scene setup
# --------------------------------------------------------------------------
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    world = bpy.data.worlds.new("World")
    sc.world = world
    world.use_nodes = True
    return sc


def setup_cycles(res, samples=128, transparent=True, view="Standard",
                 look="None", exposure=0.0, bounces=6, clamp=10.0,
                 denoise=True, adaptive_threshold=0.01):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    cy = sc.cycles
    cy.device = "CPU"
    cy.samples = samples
    cy.use_adaptive_sampling = True
    cy.adaptive_threshold = adaptive_threshold
    cy.use_denoising = denoise
    cy.denoiser = "OPENIMAGEDENOISE"
    try:
        cy.denoising_input_passes = "RGB_ALBEDO_NORMAL"
        cy.denoising_prefilter = "ACCURATE"
    except Exception:
        pass
    cy.max_bounces = bounces
    cy.diffuse_bounces = min(bounces, 4)
    cy.glossy_bounces = min(bounces, 4)
    cy.transmission_bounces = bounces
    cy.volume_bounces = 0
    cy.transparent_max_bounces = 8
    cy.sample_clamp_indirect = clamp
    cy.caustics_reflective = False
    cy.caustics_refractive = False
    sc.render.threads_mode = "FIXED"
    sc.render.threads = os.cpu_count() or 4
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = transparent
    sc.render.use_persistent_data = True
    sc.view_settings.view_transform = view
    try:
        sc.view_settings.look = look
    except TypeError:
        sc.view_settings.look = "None"
    sc.view_settings.exposure = exposure
    sc.display_settings.display_device = "sRGB"
    im = sc.render.image_settings
    im.file_format = "PNG"
    im.color_mode = "RGBA" if transparent else "RGB"
    im.color_depth = "8"
    im.compression = 15
    return sc


def world_color(rgb_lin, strength=1.0):
    w = bpy.context.scene.world
    nt = w.node_tree
    bg = nt.nodes.get("Background")
    bg.inputs[0].default_value = rgb_lin if len(rgb_lin) == 4 else (*rgb_lin, 1)
    bg.inputs[1].default_value = strength
    return w


def ortho_camera(scale, loc=(0, 0, 10), rot=(0, 0, 0), name="Cam"):
    cam = bpy.data.cameras.new(name)
    cam.type = "ORTHO"
    cam.ortho_scale = scale
    cam.clip_start = 0.01
    cam.clip_end = 100
    ob = bpy.data.objects.new(name, cam)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = rot
    bpy.context.scene.camera = ob
    return ob


def persp_camera(loc, target, lens=35, name="Cam", sensor=36):
    cam = bpy.data.cameras.new(name)
    cam.lens = lens
    cam.sensor_width = sensor
    cam.sensor_fit = "AUTO"
    cam.clip_start = 0.05
    cam.clip_end = 500
    ob = bpy.data.objects.new(name, cam)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    look_at(ob, target)
    bpy.context.scene.camera = ob
    return ob


def look_at(ob, target):
    d = Vector(target) - Vector(ob.location)
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def area_light(name, loc, target, energy, size=1.0, color=(1, 1, 1),
               shape="DISK", size_y=None, spread=180.0, visible=False):
    li = bpy.data.lights.new(name, "AREA")
    li.energy = energy
    li.shape = shape
    li.size = size
    if size_y is not None:
        li.size_y = size_y
    li.color = color[:3]
    try:
        li.spread = math.radians(spread)
    except Exception:
        pass
    ob = bpy.data.objects.new(name, li)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    look_at(ob, target)
    ob.visible_camera = visible
    return ob


def point_light(name, loc, energy, radius=0.1, color=(1, 1, 1)):
    li = bpy.data.lights.new(name, "POINT")
    li.energy = energy
    li.shadow_soft_size = radius
    li.color = color[:3]
    ob = bpy.data.objects.new(name, li)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    return ob


def sun_light(name, rot, energy, angle=2.0, color=(1, 1, 1)):
    li = bpy.data.lights.new(name, "SUN")
    li.energy = energy
    li.angle = math.radians(angle)
    li.color = color[:3]
    ob = bpy.data.objects.new(name, li)
    bpy.context.scene.collection.objects.link(ob)
    ob.rotation_euler = [math.radians(a) for a in rot]
    return ob


def link(ob, coll=None):
    (coll or bpy.context.scene.collection).objects.link(ob)
    return ob


def render(name, subdir=""):
    """Render the current scene to _renders/<subdir>/<name>.png."""
    d = os.path.join(RAW, subdir) if subdir else RAW
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, name + ".png")
    sc = bpy.context.scene
    sc.render.filepath = path
    t = time.time()
    bpy.ops.render.render(write_still=True)
    dt = time.time() - t
    print(f"[render] {path}  {sc.render.resolution_x}x{sc.render.resolution_y} "
          f"{sc.cycles.samples}spp  {dt:.1f}s", flush=True)
    with open(os.path.join(RAW, "render_times.log"), "a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\t{os.path.relpath(path, RAW)}\t"
                f"{sc.render.resolution_x}x{sc.render.resolution_y}\t"
                f"{sc.cycles.samples}spp\t{dt:.1f}s\n")
    return path


# --------------------------------------------------------------------------
# mesh helpers
# --------------------------------------------------------------------------
def mesh_object(name, verts, faces, smooth=True, coll=None):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    if smooth:
        for p in me.polygons:
            p.use_smooth = True
    ob = bpy.data.objects.new(name, me)
    link(ob, coll)
    return ob


def lathe(name, profile, segments=256, smooth=True, coll=None, cap_center=True):
    """Revolve a (r, z) profile around Z. profile[0] should be at r=0 (centre)
    if cap_center; rings with r==0 collapse into a single pole vertex."""
    verts, faces = [], []
    rings = []
    for (r, z) in profile:
        if r <= 1e-9:
            verts.append((0.0, 0.0, z))
            rings.append([len(verts) - 1] * segments)
        else:
            idx = []
            for s in range(segments):
                a = 2 * math.pi * s / segments
                verts.append((r * math.cos(a), r * math.sin(a), z))
                idx.append(len(verts) - 1)
            rings.append(idx)
    for i in range(len(rings) - 1):
        A, B = rings[i], rings[i + 1]
        for s in range(segments):
            s2 = (s + 1) % segments
            quad = [A[s], B[s], B[s2], A[s2]]
            # collapse degenerate (pole) quads into tris
            q = []
            for v in quad:
                if v not in q:
                    q.append(v)
            if len(q) >= 3:
                faces.append(q)
    return mesh_object(name, verts, faces, smooth, coll)


def shade_smooth(ob, auto_angle=None):
    for p in ob.data.polygons:
        p.use_smooth = True
    if auto_angle is not None:
        try:
            bpy.context.view_layer.objects.active = ob
            ob.select_set(True)
            bpy.ops.object.shade_auto_smooth(angle=math.radians(auto_angle))
            ob.select_set(False)
        except Exception:
            pass


def apply_transform(ob):
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    ob.select_set(False)


# --------------------------------------------------------------------------
# material helpers
# --------------------------------------------------------------------------
class NT:
    """Tiny node-tree builder: n = NT(mat); p = n.node('ShaderNodeBsdfPrincipled')"""

    def __init__(self, mat_or_tree, clear=True):
        self.tree = getattr(mat_or_tree, "node_tree", mat_or_tree)
        if clear:
            self.tree.nodes.clear()
        self.x = 0

    def node(self, kind, **inputs):
        nd = self.tree.nodes.new(kind)
        nd.location = (self.x, 0)
        self.x += 220
        for k, v in inputs.items():
            if k.startswith("_"):
                setattr(nd, k[1:], v)
            else:
                self.set(nd, k, v)
        return nd

    def set(self, nd, key, v):
        sock = nd.inputs[key]
        if isinstance(v, bpy.types.NodeSocket):
            self.tree.links.new(v, sock)
        else:
            sock.default_value = v

    def link(self, a, b):
        self.tree.links.new(a, b)

    # common combos -------------------------------------------------------
    def math(self, op, a, b=None, clamp=False):
        nd = self.node("ShaderNodeMath", _operation=op, _use_clamp=clamp)
        self.set(nd, 0, a)
        if b is not None:
            self.set(nd, 1, b)
        return nd.outputs[0]

    def mix(self, a, b, fac, blend="MIX", dtype="RGBA", clamp=False):
        nd = self.node("ShaderNodeMix", _data_type=dtype, _blend_type=blend,
                       _clamp_result=clamp)
        if dtype == "RGBA":
            self.set(nd, 6, a)
            self.set(nd, 7, b)
            self.set(nd, 0, fac)
            return nd.outputs[2]
        self.set(nd, 2, a)
        self.set(nd, 3, b)
        self.set(nd, 0, fac)
        return nd.outputs[0]

    def ramp(self, fac, stops, interp="LINEAR"):
        nd = self.node("ShaderNodeValToRGB")
        cr = nd.color_ramp
        cr.interpolation = interp
        while len(cr.elements) > len(stops):
            cr.elements.remove(cr.elements[-1])
        while len(cr.elements) < len(stops):
            cr.elements.new(0.5)
        for el, (pos, col) in zip(cr.elements, stops):
            el.position = pos
            el.color = col if len(col) == 4 else (*col, 1)
        self.set(nd, 0, fac)
        return nd.outputs[0]

    def maprange(self, v, a, b, c, d, clamp=True, interp="LINEAR"):
        nd = self.node("ShaderNodeMapRange", _clamp=clamp, _interpolation_type=interp)
        self.set(nd, 0, v)
        nd.inputs[1].default_value = a
        nd.inputs[2].default_value = b
        nd.inputs[3].default_value = c
        nd.inputs[4].default_value = d
        return nd.outputs[0]

    def texcoord(self):
        return self.node("ShaderNodeTexCoord")

    def image(self, path, vector=None, colorspace="sRGB", proj="FLAT", blend=0.2,
              extension="REPEAT"):
        nd = self.node("ShaderNodeTexImage", _projection=proj,
                       _extension=extension)
        nd.projection_blend = blend
        img = bpy.data.images.load(path, check_existing=True)
        img.colorspace_settings.name = colorspace
        nd.image = img
        if vector is not None:
            self.set(nd, "Vector", vector)
        return nd

    def output(self, shader, volume=None, displacement=None):
        out = self.node("ShaderNodeOutputMaterial")
        self.link(shader, out.inputs["Surface"])
        if volume is not None:
            self.link(volume, out.inputs["Volume"])
        if displacement is not None:
            self.link(displacement, out.inputs["Displacement"])
        return out


def new_material(name):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    return m


def assign(ob, mat):
    if ob.data.materials:
        ob.data.materials[0] = mat
    else:
        ob.data.materials.append(mat)


def tex_set(asset_id, res="1K"):
    """Paths of an ambientCG material set in third_party."""
    d = os.path.join(THIRD, "ambientcg", asset_id)
    base = os.path.join(d, f"{asset_id}_{res}-JPG_")
    out = {}
    for k in ("Color", "NormalGL", "Roughness", "Displacement",
              "AmbientOcclusion", "Metalness"):
        p = base + k + ".jpg"
        if os.path.exists(p):
            out[k] = p
    if not out:
        raise FileNotFoundError(f"{asset_id}: run fetch_assets.py first ({d})")
    return out


def emission_material(name, color_lin, strength=1.0):
    m = new_material(name)
    n = NT(m)
    e = n.node("ShaderNodeEmission")
    e.inputs[0].default_value = color_lin
    e.inputs[1].default_value = strength
    n.output(e.outputs[0])
    return m


def world_gradient(zenith, horizon, ground, strength=1.0):
    """World colour by direction: what the metal's bevels reflect."""
    w = bpy.context.scene.world
    n = NT(w)
    tc = n.node("ShaderNodeTexCoord")
    sep = n.node("ShaderNodeSeparateXYZ")
    n.link(tc.outputs["Generated"], sep.inputs[0])
    col = n.ramp(sep.outputs[2], [(0.0, ground), (0.47, ground), (0.5, horizon),
                                  (0.62, horizon), (0.85, zenith), (1.0, zenith)])
    bg = n.node("ShaderNodeBackground")
    n.link(col, bg.inputs[0])
    bg.inputs[1].default_value = strength
    out = n.node("ShaderNodeOutputWorld")
    n.link(bg.outputs[0], out.inputs[0])


def ring_light(name, radius, z, color, peak, base, focus=2.0,
               direction=(-0.7071, 0.7071), thickness=0.05):
    """Thin emissive torus seen only in reflections: draws a crisp highlight
    line around the tile's bevels, brightest towards `direction`."""
    bpy.ops.mesh.primitive_torus_add(major_radius=radius, minor_radius=thickness,
                                     major_segments=192, minor_segments=12,
                                     location=(0, 0, z))
    ob = bpy.context.active_object
    ob.name = name
    ob.visible_camera = False
    ob.visible_diffuse = False
    ob.visible_shadow = False
    ob.visible_transmission = False
    m = new_material(name + "Mat")
    n = NT(m)
    tc = n.texcoord()
    norm = n.node("ShaderNodeVectorMath", _operation="NORMALIZE")
    n.link(tc.outputs["Object"], norm.inputs[0])
    dot = n.node("ShaderNodeVectorMath", _operation="DOT_PRODUCT")
    n.link(norm.outputs[0], dot.inputs[0])
    dot.inputs[1].default_value = (direction[0], direction[1], 0.0)
    w = n.maprange(dot.outputs["Value"], -1.0, 1.0, 0.0, 1.0)
    w = n.math("POWER", w, focus)
    strength = n.maprange(w, 0.0, 1.0, base, peak)
    e = n.node("ShaderNodeEmission")
    e.inputs["Color"].default_value = color
    n.link(strength, e.inputs["Strength"])
    n.output(e.outputs[0])
    assign(ob, m)
    return ob


