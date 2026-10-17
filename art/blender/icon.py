"""App icon foreground: a hammer striking a glowing "W" tile on an anvil,
with a burst of sparks. Transparent background (post.py builds the opaque
background layer, the monochrome silhouette and the full preview).

Two renders, same camera:
  icon_fg.png   beauty pass, transparent film
  icon_ids.png  flat ID colours (hammer red, tile green, letter blue,
                anvil yellow, sparks white) used by post.py for the
                monochrome (themed) icon

    blender -b --factory-startup -P icon.py -- [--samples 128] [--res 1024]
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import common as C  # noqa: E402
import props as P  # noqa: E402
import tiles as T  # noqa: E402

RES = C.arg("res", 1024)
SAMPLES = C.arg("samples", 128)
ONLY = C.arg("only", "")
FONT = os.path.join(C.THIRD, "fonts", "RobotoSlab-Black-static.ttf")

ANVIL_YAW = 8.0
TILE_R = 0.70
TILE_R_SIN = 0.70 * math.sin(math.radians(12.0)) - 0.01
TILE_POS = Vector((0.18, -0.04, 1.62 + TILE_R_SIN))
TILE_TILT = 12.0
        # degrees, towards the camera (reads the W better)


def build():
    iron = P.iron_material("AnvilIron", base="#585C63", rough=(0.30, 0.50),
                           bump=0.15, facet_scale=3.0)
    anvil = P.anvil("Anvil", iron, depth=1.36, rot_z=math.radians(ANVIL_YAW),
                    horn_len=1.15)

    # glowing tile = same lathe profile as the app's tiles, scaled
    tile = C.lathe("Tile", T.tile_profile(), segments=192)
    tile.scale = (TILE_R, TILE_R, TILE_R)
    tile.location = TILE_POS
    tile.rotation_euler = (math.radians(TILE_TILT), 0, 0)
    hot = T.mat_hot()
    # brighter so it blooms in the icon
    for nd in hot.node_tree.nodes:
        if nd.type == "BSDF_PRINCIPLED":
            nd.inputs["Emission Strength"].default_value = 2.2
    C.assign(tile, hot)

    # the letter
    cu = bpy.data.curves.new("W", "FONT")
    cu.body = "W"
    if os.path.exists(FONT):
        cu.font = bpy.data.fonts.load(FONT)
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    cu.size = 1.32
    cu.extrude = 0.03
    cu.bevel_depth = 0.008
    cu.bevel_resolution = 2
    letter = bpy.data.objects.new("Letter", cu)
    C.link(letter)
    letter.parent = tile
    letter.location = (0, -0.03, 0.262)
    lm = C.new_material("LetterMat")
    n = C.NT(lm)
    p = n.node("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = C.hex_lin("#3A1808")
    p.inputs["Roughness"].default_value = 0.45
    p.inputs["Emission Color"].default_value = C.hex_lin("#5A1E08")
    p.inputs["Emission Strength"].default_value = 0.6
    n.output(p.outputs[0])
    letter.data.materials.append(lm)

    # hammer, striking from the upper right
    head = P.iron_material("HammerIron", base="#7C7F85", rough=(0.25, 0.42),
                           bump=0.08, facet_scale=6.0)
    wood = P.wood_material("Handle", value=1.1, scale=2.0, tint="#C08050")
    ham = P.hammer("Hammer", head, wood, head_len=1.05, head_w=0.52,
                   handle_len=1.5, pein_axis="none", handle_r=0.1)
    # orient: striking face points `face_dir`, handle runs along `handle_dir`
    face_dir = Vector((-0.50, 0.05, -0.86)).normalized()
    handle_dir = Vector((0.78, 0.25, 0.56))
    X = -face_dir
    Z = -(handle_dir - handle_dir.dot(X) * X).normalized()
    Y = Z.cross(X)
    ham.rotation_euler = Matrix((X, Y, Z)).transposed().to_euler()
    ham.location = (0.62, 0.02, 1.98)

    # sparks bursting from the strike
    spk = P.spark_material("Spark", strength=14.0)
    origin = Vector((0.55, -0.15, 1.88))
    # main fan: up and to the right/front, away from the letter
    sp = P.sparks(origin, count=22, seed=7, direction=(0.55, -0.45, 0.70),
                  spread=48, length=(0.14, 0.42), dist=(0.55, 1.6),
                  radius=0.026, mat=spk, gravity=0.1)
    # a few low, fast streaks skimming out to the right over the heel
    sp += P.sparks(origin, count=10, seed=11, direction=(1.0, -0.55, 0.05),
                   spread=22, length=(0.12, 0.3), dist=(0.7, 1.5),
                   radius=0.022, mat=spk, gravity=0.12, name="SparkL")
    return anvil, tile, letter, ham, sp


def lights():
    C.world_gradient(C.hex_lin("#060404"), C.hex_lin("#22160F"),
                     C.hex_lin("#080605"), 1.0)
    # warm key, front-left high
    C.area_light("Key", (-4.0, -4.5, 6.0), (0, 0, 1.2), 170, size=3.0,
                 color=(0.92, 0.9, 0.9))
    # strong orange rim from behind: outlines anvil + hammer on dark bg
    C.area_light("RimL", (-3.5, 5.0, 3.5), (0, 0, 1.2), 650, size=2.5,
                 color=(1.0, 0.55, 0.3))
    C.area_light("RimR", (4.5, 4.0, 4.0), (0, 0, 1.5), 800, size=2.5,
                 color=(1.0, 0.55, 0.22))
    # cool faint fill from the right-front for iron sheen variety
    C.area_light("Fill", (5.0, -4.0, 2.0), (0, 0, 1.0), 90, size=4.0,
                 color=(0.6, 0.7, 0.95))
    # light from the hot tile onto hammer underside and anvil face
    C.point_light("TileGlow", TILE_POS + Vector((0, -0.1, 0.45)), 220,
                  radius=0.35, color=(1.0, 0.55, 0.2))


def camera():
    cam = C.persp_camera((0.76, -7.6, 7.4), (0.06, 0.0, 1.36), lens=50)
    cam.data.shift_y = 0.02
    return cam


def id_pass(anvil, tile, letter, ham, sp):
    def flat(name, rgb):
        return C.emission_material(name, (*rgb, 1), 1.0)
    C.assign(anvil, flat("IdAnvil", (1, 1, 0)))
    C.assign(tile, flat("IdTile", (0, 1, 0)))
    letter.data.materials[0] = flat("IdLetter", (0, 0, 1))
    hm = flat("IdHammer", (1, 0, 0))
    for ch in ham.children:
        C.assign(ch, hm)
    sm = flat("IdSpark", (1, 1, 1))
    bpy.data.objects["SparkBase"].data.materials[0] = sm
    bpy.data.objects["SparkLBase"].data.materials[0] = sm
    for ob in [o for o in bpy.data.objects if o.type == "LIGHT"]:
        bpy.data.objects.remove(ob)
    C.world_color((0, 0, 0, 1), 0.0)
    sc = bpy.context.scene
    sc.cycles.samples = 16
    sc.cycles.use_denoising = False
    sc.render.filter_size = 0.8


def main():
    C.reset()
    C.setup_cycles((RES, RES), samples=SAMPLES, transparent=True,
                   view="Standard", bounces=6)
    camera()
    objs = build()
    if not ONLY or "fg" in ONLY:
        lights()
        C.render("icon_fg", "icon")
    if not ONLY or "ids" in ONLY:
        id_pass(*objs)
        bpy.context.scene.view_settings.view_transform = "Standard"
        bpy.context.scene.view_settings.look = "None"
        C.render("icon_ids", "icon")


if __name__ == "__main__":
    main()
