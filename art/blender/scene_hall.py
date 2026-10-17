"""bg_hall: the Forge Hall (home screen, and the puzzle background for the
chapters that have no scene of their own yet). A stone forge interior at
night, built around one big arched brick forge whose mouth is full of hot
coals and flames: the clear focal point, sitting ~45-62 % down the frame.
Tools hang either side, an anvil on its stump and a quench barrel stand in
silhouette in the foreground; smoke and drifting embers fill the air.

Portrait 1080x2340. The top ~45 % (chimney breast, beams, smoke) stays dark
and calm for the crossword grid; the bottom (floor) is darker too, as the app
draws animated flames over the bottom 40 %.

    blender -b --factory-startup -P scene_hall.py -- [--samples 80] [--scale 1.0]
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402

import common as C  # noqa: E402
import forge_kit as K  # noqa: E402
import props as P  # noqa: E402

SAMPLES = C.arg("samples", 80)
SCALE = C.arg("scale", 1.0)           # 1.0 = native 1080x2340 (post.py never upscales)
NAME = "bg_hall"

W_HALF, BACK, FRONT, HEIGHT = 3.0, 4.0, -6.0, 6.5
FORGE_Y = BACK - 1.6          # front face of the forge


def materials():
    return dict(
        wall=K.tex_material("StoneWall", "Bricks102", scale=0.45, value=0.26, sat=0.7,
                            tint="#8A6A55", tint_fac=0.4, rough=(0.75, 1.0),
                            soot=0.9, soot_range=(2.2, 5.0)),
        floor=K.tex_material("Flagstones", "PavingStones142", scale=0.8, value=0.2,
                             sat=0.5, tint="#7A6252", tint_fac=0.3, rough=(0.38, 0.9),
                             normal=0.6),
        brick=K.tex_material("ForgeBrick", "Bricks094", scale=1.0, value=0.55, sat=0.9,
                             rough=(0.7, 1.0), soot=0.75, soot_range=(1.6, 2.4)),
        chimney=K.tex_material("ChimneyBrick", "Bricks094", scale=1.0, value=0.3, sat=0.6,
                               rough=(0.7, 1.0), soot=0.9, soot_range=(2.2, 4.5)),
        stone=K.tex_material("Apron", "Bricks102", scale=1.4, value=0.4, sat=0.6,
                             rough=(0.6, 0.95)),
        beam=K.tex_material("Beam", "Planks023A", scale=0.6, value=0.28, sat=0.8,
                            rough=(0.7, 0.95)),
        wood=P.wood_material("Wood", value=0.55, scale=1.2),
        stump=K.tex_material("Stump", "Planks023A", scale=1.4, value=0.42, sat=1.0,
                             tint="#8A5A38", tint_fac=0.5),
        iron=P.iron_material("Iron", base="#62646A", rough=(0.3, 0.5), bump=0.12),
        # worn-bright working iron (anvil face, hammer heads, hoops, hung tools):
        # low roughness so it throws crisp warm glints of the fire
        polished=P.iron_material("PolishedIron", base="#9A9CA2", rough=(0.1, 0.24), bump=0.05,
                                 facet_scale=6.0),
        handle=P.wood_material("Handle", value=0.8, scale=3.0),
        water=K.water_material("Water"),
    )


def build(M):
    # room shell ----------------------------------------------------------
    K.plane("Floor", (0, (BACK + FRONT) / 2, 0), (2 * W_HALF, BACK - FRONT), mat=M["floor"])
    K.box("FrontWall", (0, FRONT - 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT),
          M["wall"], bevel=0)      # behind the camera: keeps the sky out
    K.box("BackWall", (0, BACK + 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT),
          M["wall"], bevel=0)
    K.box("LeftWall", (-W_HALF - 0.15, (BACK + FRONT) / 2, HEIGHT / 2),
          (0.3, BACK - FRONT, HEIGHT), M["wall"], bevel=0)
    K.box("RightWall", (W_HALF + 0.15, (BACK + FRONT) / 2, HEIGHT / 2),
          (0.3, BACK - FRONT, HEIGHT), M["wall"], bevel=0)
    K.box("Ceiling", (0, (BACK + FRONT) / 2, HEIGHT + 0.1), (2 * W_HALF + 0.6, BACK - FRONT, 0.2),
          M["beam"], bevel=0)
    for i, y in enumerate((3.0, 1.0, -1.0)):
        K.box(f"Beam{i}", (0, y, 4.4), (2 * W_HALF, 0.34, 0.38), M["beam"], bevel=0.04)

    # the forge: centred on the back wall ----------------------------------
    K.arched_forge((0, FORGE_Y, 0), w=2.9, d=1.6, h=2.2, mouth_w=1.7, mouth_h=1.22,
                   mouth_z=0.72, brick=M["brick"], iron=M["iron"], stone=M["stone"],
                   chimney=M["chimney"], chimney_top=HEIGHT, fire_strength=6.5,
                   light=190.0, seed=3)

    # tools hanging either side of the forge, lit by its spill -------------
    K.tool_rack((-1.95, BACK - 0.05, 2.15), along="X", length=0.9, wood=M["beam"],
                iron=M["polished"], handle=M["handle"], facing=-1, seed=4)
    K.tool_rack((1.95, BACK - 0.05, 2.15), along="X", length=0.9, wood=M["beam"],
                iron=M["polished"], handle=M["handle"], facing=-1, seed=9)
    # tongs and a poker leaning against the forge's front corners
    tg = P.tongs("LeanTongs", M["polished"], length=1.15)
    tg.location = (-1.28, FORGE_Y - 0.28, 0.0)
    tg.rotation_euler = (math.radians(-12), math.radians(8), math.radians(10))
    K.cylinder("Poker", (1.3, FORGE_Y - 0.25, 0.6), 0.018, 1.25, M["polished"], verts=12,
               rot=(-12, -8, 0))

    # anvil on its stump (front right, horn towards the fire) --------------
    AX, AY = 1.05, 0.55
    K.stump("Stump", (AX, AY, 0), radius=0.36, height=0.45, mat=M["stump"])
    anv = P.anvil("Anvil", M["polished"], depth=1.15, location=(AX, AY, 0.45),
                  rot_z=math.radians(-28))
    anv.scale = (0.28, 0.28, 0.28)
    hm = P.hammer("AnvilHammer", M["polished"], M["handle"], head_len=0.26, head_w=0.09,
                  handle_len=0.5, pein_axis="z", handle_r=0.02)
    hm.location = (AX + 0.05, AY - 0.06, 0.97)
    hm.rotation_euler = (math.radians(90), 0, math.radians(-40))

    # quench barrel front left ---------------------------------------------
    K.barrel("Barrel", (-1.45, 0.9, 0), radius=0.4, height=0.85, wood=M["wood"],
             iron=M["polished"], water=M["water"])

    # warm rim on the foreground silhouettes, very faint cool fill -----------
    C.area_light("RimAnvil", (0.6, 2.2, 1.3), (AX, AY, 0.8), 55, size=0.45,
                 color=(1.0, 0.52, 0.2))
    # warm bounce card right of the forge: what the polished anvil face mirrors
    C.area_light("AnvilBounce", (1.6, 2.3, 1.25), (AX, AY, 0.9), 40, size=1.0,
                 color=(1.0, 0.55, 0.25))
    C.area_light("RimBarrel", (-0.75, 2.1, 1.45), (-1.45, 0.9, 0.6), 30, size=0.45,
                 color=(1.0, 0.5, 0.2))
    # the forge's spill grazing the hung tools either side of it
    for sx in (-1, 1):
        C.area_light(f"RackSpill{sx}", (sx * 1.15, BACK - 0.9, 1.7), (sx * 1.95, BACK, 2.1),
                     14, size=0.5, color=(1.0, 0.5, 0.2))
    C.area_light("CoolFill", (-2.0, -3.0, 3.5), (0, 2, 1), 6, size=3.0,
                 color=(0.5, 0.6, 0.9))

    # smoke + embers -----------------------------------------------------------
    K.haze((-W_HALF + 0.02, FRONT + 2, 0.03), (W_HALF - 0.02, BACK - 0.02, HEIGHT - 0.02), density=0.005,
           color=(1.0, 0.9, 0.82), anisotropy=0.45)
    K.embers((-0.8, FORGE_Y - 0.6, 1.6), (0.8, FORGE_Y + 0.2, 3.2), count=22, seed=5,
             radius=0.012)


def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="Filmic",
                        look="High Contrast", exposure=0.0, bounces=5)
    sc.cycles.volume_step_rate = 4.0
    sc.cycles.volume_max_steps = 256
    sc.cycles.volume_bounces = 0
    C.world_color(C.hex_lin("#020203"), 1.0)
    M = materials()
    build(M)
    cam = C.persp_camera((0.15, -2.9, 1.45), (0.0, FORGE_Y, 1.36), lens=26)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 5.4
    cam.data.dof.aperture_fstop = 5.0      # crisper props; the fire still sits in focus
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
