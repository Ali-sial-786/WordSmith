#!/usr/bin/env python3
"""Dev aid: mock-up sheets that show the final assets roughly as the app will
(letters drawn on tiles, tiles on the anvil face, cells tinted, icon masks).
Writes art/blender/_renders/preview/*.png. Not needed for the build.

    python3 preview.py [tiles] [anvil] [cells] [icon] [bg]
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
IMG = os.path.join(REPO, "app", "assets", "images")
PV = os.path.join(HERE, "_renders", "preview")
FONT = os.path.join(REPO, "art", "third_party", "blender", "fonts", "RobotoSlab-wght.ttf")
os.makedirs(PV, exist_ok=True)

FORGE_BLACK = (23, 17, 14)
WHITE_HEAT = (255, 241, 208)


def font(px, weight=b"Bold"):
    f = ImageFont.truetype(FONT, px)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def img(name):
    return Image.open(os.path.join(IMG, name)).convert("RGBA")


def letter_on(tile, ch, color, size=None):
    t = tile.copy()
    s = size or t.size[1]
    d = ImageDraw.Draw(t)
    f = font(int(s * 0.55 * 1.0), b"Bold")
    d.text((t.size[0] / 2, t.size[1] / 2), ch, font=f, fill=color, anchor="mm")
    return t


def shadow_under(canvas, im, x, y, off=6, rad=8, op=150):
    a = im.split()[3].point(lambda v: v * op // 255)
    sh = Image.new("RGBA", im.size, (0, 0, 0, 0))
    sh.putalpha(a)
    sh = sh.filter(ImageFilter.GaussianBlur(rad))
    canvas.alpha_composite(sh, (x, y + off))
    canvas.alpha_composite(im, (x, y))


def tiles():
    cold, hot, used = img("tile_cold.png"), img("tile_hot.png"), img("tile_used.png")
    W, H = 256 * 3 + 80, 256 + 260
    c = Image.new("RGBA", (W, H), FORGE_BLACK + (255,))
    for i, (t, ch, col) in enumerate([(cold, "A", WHITE_HEAT),
                                      (hot, "R", (58, 26, 10)),
                                      (used, "E", (163, 172, 181))]):
        shadow_under(c, letter_on(t, ch, col), 20 + i * 276, 10)
    # small (phone-size) versions
    for i, (t, ch, col) in enumerate([(cold, "W", WHITE_HEAT), (hot, "O", (58, 26, 10)),
                                      (used, "R", (163, 172, 181)), (cold, "D", WHITE_HEAT),
                                      (hot, "S", (58, 26, 10))]):
        s = letter_on(t, ch, col).resize((96, 96), Image.LANCZOS)
        shadow_under(c, s, 40 + i * 120, 300, off=3, rad=4)
    # bare tiles at small size on a mid background, to judge the rims
    for i, t in enumerate([cold, hot, used]):
        s = t.resize((96, 96), Image.LANCZOS)
        bg = Image.new("RGBA", (110, 110), (58, 47, 40, 255))
        bg.alpha_composite(s, (7, 7))
        c.alpha_composite(bg, (W - 120 * (3 - i) - 10, 400))
    c.save(os.path.join(PV, "tiles.png"))
    print("preview tiles")


def add_plus(base, layer, gain=1.0):
    """Additive blend of a straight-alpha layer (premultiplied colour added)."""
    import numpy as np
    b = np.asarray(base).astype(np.float32) / 255
    l = np.asarray(layer).astype(np.float32) / 255
    rgb = b[..., :3] + l[..., :3] * l[..., 3:4] * gain
    out = np.concatenate([np.clip(rgb, 0, 1), b[..., 3:4]], -1)
    return Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA")


def anvil():
    face, glow = img("anvil_face.webp"), img("anvil_face_glow.webp")
    cold, hot = img("tile_cold.png"), img("tile_hot.png")
    S = 620
    def board(with_glow):
        c = Image.new("RGBA", (S + 40, S + 40), FORGE_BLACK + (255,))
        f = face.resize((S, S), Image.LANCZOS)
        c.alpha_composite(f, (20, 20))
        if with_glow:
            g = glow.resize((S, S), Image.LANCZOS)
            sub = c.crop((20, 20, 20 + S, 20 + S))
            c.paste(add_plus(sub, g), (20, 20))
        letters = "FORGED"
        ts = int(S * 0.93 * 0.21)
        R = S * 0.93 / 2 * 0.70
        cx = cy = 20 + S / 2
        for i, ch in enumerate(letters):
            a = -math.pi / 2 + 2 * math.pi * i / len(letters)
            hotness = with_glow and i < 3
            t = letter_on(hot if hotness else cold, ch,
                          (58, 26, 10) if hotness else WHITE_HEAT)
            t = t.resize((ts, ts), Image.LANCZOS)
            x, y = int(cx + R * math.cos(a) - ts / 2), int(cy + R * math.sin(a) - ts / 2)
            shadow_under(c, t, x, y, off=4, rad=5)
        return c
    a, b = board(False), board(True)
    W = Image.new("RGBA", (a.size[0] * 2, a.size[1]), FORGE_BLACK + (255,))
    W.paste(a, (0, 0)); W.paste(b, (a.size[0], 0))
    W.save(os.path.join(PV, "anvil.png"))
    print("preview anvil")


def multiply(im, rgb):
    t = Image.new("RGBA", im.size, tuple(rgb) + (255,))
    out = ImageChops.multiply(im, t)
    out.putalpha(im.split()[3])
    return out


def cells():
    empty, metal = img("cell_empty.png"), img("cell_metal.png")
    S, G = 96, 6
    # a little crossword: (col, row, letter or None)
    words = [((0, 1), "FORGE", "h", (200, 105, 63)), ((2, 0), "ORE", "v", (185, 188, 184)),
             ((4, 1), "EMBER", "v", None), ((0, 1), "FIRE", "v", (225, 181, 59))]
    cells_ = {}
    for (c0, r0), w, d, col in words:
        for i, ch in enumerate(w):
            c, r = (c0 + i, r0) if d == "h" else (c0, r0 + i)
            if (c, r) not in cells_ or col is not None:
                cells_[(c, r)] = (ch, col)
    W = 7 * (S + G) + 40
    Hh = 7 * (S + G) + 40
    canvas = Image.new("RGBA", (W, Hh), FORGE_BLACK + (255,))
    e = empty.resize((S, S), Image.LANCZOS)
    m = metal.resize((S, S), Image.LANCZOS)
    f = font(int(S * 0.6), b"Bold")
    for (c, r), (ch, col) in cells_.items():
        x, y = 20 + c * (S + G), 20 + r * (S + G)
        if col is None:
            canvas.alpha_composite(e, (x, y))
        else:
            t = multiply(m, col)
            d = ImageDraw.Draw(t)
            d.text((S / 2, S / 2 + 2), ch, font=f, fill=(30, 20, 14), anchor="mm")
            canvas.alpha_composite(t, (x, y))
    # raw cells at native size on the right
    canvas.alpha_composite(empty, (W - 150, Hh - 300))
    canvas.alpha_composite(metal, (W - 150, Hh - 160))
    canvas.save(os.path.join(PV, "cells.png"))
    print("preview cells")


STEPS = {"tiles": tiles, "anvil": anvil, "cells": cells}

if __name__ == "__main__":
    for k in (sys.argv[1:] or list(STEPS)):
        STEPS[k]()
