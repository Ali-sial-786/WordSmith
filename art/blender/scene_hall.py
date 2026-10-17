"""bg_hall: the Forge Hall (home screen). A stone forge interior at night:
brick hearth with glowing coals under a sooty hood (left), an anvil on a
stump catching the firelight (centre), tools on the right wall, a quench
barrel, smoky haze and a faint cool moonlit window.

Portrait 1080x2340. Composition keeps the top ~45 % (beams, upper wall in
smoke) and the bottom ~35 % (floor in shadow) calm; the interest sits in
the middle band and around the edges.

    blender -b --factory-startup -P scene_hall.py -- [--samples 96] [--scale 0.75]
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy  # noqa: E402

import common as C  # noqa: E402
import forge_kit as K  # noqa: E402
import props as P  # noqa: E402

SAMPLES = C.arg("samples", 96)
SCALE = C.arg("scale", 0.75)          # render scale of 1080x2340
NAME = "bg_hall"

W_HALF, BACK, FRONT, HEIGHT = 3.2, 5.0, -6.0, 6.5


def materials():
    return dict(
        wall=K.tex_material("StoneWall", "Bricks102", scale=0.45, value=0.32, sat=0.7,
                            tint="#8A6A55", tint_fac=0.4, rough=(0.75, 1.0),
                            soot=0.85, soot_range=(2.0, 5.5)),
        floor=K.tex_material("Flagstones", "PavingStones142", scale=0.35, value=0.38,
                             sat=0.6, tint="#7A6252", tint_fac=0.3, rough=(0.5, 0.9)),
        brick=K.tex_material("HearthBrick", "Bricks094", scale=0.9, value=0.5, sat=0.85,
                             rough=(0.7, 1.0), soot=0.7, soot_range=(0.3, 1.0)),
        hood=K.tex_material("Hood", "Bricks094", scale=0.9, value=0.16, sat=0.4,
                            rough=(0.8, 1.0)),
        beam=K.tex_material("Beam", "Planks023A", scale=0.6, value=0.28, sat=0.8,
                            rough=(0.7, 0.95)),
        wood=P.wood_material("Wood", value=0.55, scale=1.2),
        stump=K.tex_material("Stump", "Planks023A", scale=1.4, value=0.42, sat=1.0,
                             tint="#8A5A38", tint_fac=0.5),
        iron=P.iron_material("Iron", base="#62646A", rough=(0.3, 0.5), bump=0.12),
        handle=P.wood_material("Handle", value=0.8, scale=3.0),
        water=K.water_material("Water"),
    )


def build(M):
    # room shell ----------------------------------------------------------
    K.plane("Floor", (0, (BACK + FRONT) / 2, 0), (2 * W_HALF, BACK - FRONT), mat=M["floor"])
    K.box("BackWall", (0, BACK + 0.15, HEIGHT / 2), (2 * W_HALF + 0.6, 0.3, HEIGHT),
          M["wall"], bevel=0)
    K.box("LeftWall", (-W_HALF - 0.15, (BACK + FRONT) / 2, HEIGHT / 2),
          (0.3, BACK - FRONT, HEIGHT), M["wall"], bevel=0)
    K.box("RightWall", (W_HALF + 0.15, (BACK + FRONT) / 2, HEIGHT / 2),
          (0.3, BACK - FRONT, HEIGHT), M["wall"], bevel=0)
    K.box("Ceiling", (0, (BACK + FRONT) / 2, HEIGHT + 0.1), (2 * W_HALF + 0.6, BACK - FRONT, 0.2),
          M["beam"], bevel=0)
    for i, y in enumerate((4.2, 2.2, 0.2, -1.8)):
        K.box(f"Beam{i}", (0, y, 4.3), (2 * W_HALF, 0.32, 0.36), M["beam"], bevel=0.04)
    for i, x in enumerate((-W_HALF + 0.2, W_HALF - 0.2)):
        K.box(f"Post{i}", (x, 2.2, 2.15), (0.3, 0.3, 4.3), M["beam"], bevel=0.04)

    # hearth (left, against the back wall) ---------------------------------
    K.hearth((-1.35, 3.85, 0), w=1.9, d=1.3, h=0.82, brick=M["brick"], hood=M["hood"],
             coal_strength=8.0, light_energy=1100, hood_top=3.6, flue_top=HEIGHT)

    # anvil on its stump (centre-right, horn towards the fire) -------------
    K.stump("Stump", (0.55, 1.35, 0), radius=0.36, height=0.45, mat=M["stump"])
    anv = P.anvil("Anvil", M["iron"], depth=1.15, location=(0.55, 1.35, 0.45),
                  rot_z=math.radians(-14))
    anv.scale = (0.28, 0.28, 0.28)
    # a resting hammer on the anvil face
    hm = P.hammer("AnvilHammer", M["iron"], M["handle"], head_len=0.26, head_w=0.09,
                  handle_len=0.5, pein_axis="z", handle_r=0.02)
    hm.location = (0.62, 1.30, 0.97)
    hm.rotation_euler = (math.radians(90), 0, math.radians(-30))

    # quench barrel near the hearth ----------------------------------------
    K.barrel("Barrel", (-2.35, 2.35, 0), radius=0.4, height=0.85, wood=M["wood"],
             iron=M["iron"], water=M["water"])

    # tools on the right wall ------------------------------------------------
    K.tool_rack((W_HALF - 0.05, 3.0, 2.05), along="Y", length=2.4, wood=M["beam"],
                iron=M["iron"], handle=M["handle"], facing=-1)

    # small moonlit window high on the back wall (cool accent) ---------------
    win = K.plane("Window", (1.55, BACK - 0.01, 3.3), (0.7, 0.9), rot=(90, 0, 0),
                  mat=K.flat_material("Moon", "#000000", emission=(C.hex_lin("#5E7FB0"), 1.6)))
    for i, (dx, dz, sx, sz) in enumerate([(0, 0.47, 0.86, 0.08), (0, -0.47, 0.86, 0.08),
                                          (0.39, 0, 0.08, 1.0), (-0.39, 0, 0.08, 1.0),
                                          (0, 0, 0.05, 0.9), (0, 0, 0.7, 0.05)]):
        K.box(f"WinFrame{i}", (1.55 + dx, BACK - 0.03, 3.3 + dz), (sx, 0.08, sz), M["beam"],
              bevel=0.01)
    C.spot_light("MoonShaft", (1.55, BACK + 0.6, 3.5), (0.9, 1.5, 0.0), 260, angle=22,
                 blend=0.6, radius=0.3, color=(0.55, 0.68, 1.0))

    # warm bounce from the fire onto the anvil + rim on the tools ------------
    C.area_light("FireBounce", (-0.6, 2.6, 1.3), (0.6, 1.3, 0.8), 70, size=1.2,
                 color=(1.0, 0.5, 0.2))
    C.area_light("ToolRim", (1.0, 3.6, 2.4), (W_HALF, 3.0, 2.0), 60, size=1.0,
                 color=(1.0, 0.55, 0.25))

    # smoke + embers -----------------------------------------------------------
    K.haze((-W_HALF, FRONT + 2, 0), (W_HALF, BACK, HEIGHT), density=0.035,
           color=(1.0, 0.92, 0.85), anisotropy=0.4)
    K.embers((-2.0, 3.2, 1.0), (-0.6, 4.4, 3.4), count=26, seed=5, radius=0.01)


def main():
    C.reset()
    res = (round(1080 * SCALE), round(2340 * SCALE))
    sc = C.setup_cycles(res, samples=SAMPLES, transparent=False, view="AgX",
                        look="AgX - Medium High Contrast", exposure=0.0, bounces=5)
    sc.cycles.volume_step_rate = 4.0
    sc.cycles.volume_max_steps = 256
    sc.cycles.volume_bounces = 0
    C.world_color(C.hex_lin("#020203"), 1.0)
    M = materials()
    build(M)
    cam = C.persp_camera((0.3, -4.3, 1.55), (-0.15, 4.0, 1.3), lens=26)
    cam.data.sensor_fit = "VERTICAL"
    cam.data.sensor_height = 36
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = 5.7
    cam.data.dof.aperture_fstop = 2.8
    C.render(NAME, "bg")


if __name__ == "__main__":
    main()
