#!/usr/bin/env python3
"""Dev aid: mock-up sheets that show the final assets roughly as the app will
(letters drawn on tiles, tiles on the anvil face, cells tinted, icon masks).
Writes art/blender/_renders/preview/*.png. Not needed for the build.

    python3 preview.py [tiles] [anvil] [cells] [icon] [bg] [ui]
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


def bg():
    """Backgrounds side by side: raw (zones marked) and app-like (dim + blur
    with a mock grid, ring and flame band)."""
    names = [n for n in ("bg_hall", "bg_tin", "bg_copper", "bg_bronze", "bg_iron", "bg_steel",
                         "bg_silver", "bg_gold", "bg_damascus", "bg_starmetal")
             if os.path.exists(os.path.join(IMG, n + ".webp"))]
    if not names:
        return
    W, H = 360, 780
    sheet = Image.new("RGBA", (len(names) * (W + 10) * 2, H + 30), FORGE_BLACK + (255,))
    d0 = ImageDraw.Draw(sheet)
    face = img("anvil_face.webp")
    empty = img("cell_empty.png")
    for i, n in enumerate(names):
        im = img(n + ".webp").resize((W, H), Image.LANCZOS)
        raw_ = im.copy()
        d = ImageDraw.Draw(raw_)
        for frac, col in ((0.45, (80, 200, 255, 255)), (0.60, (255, 120, 40, 255))):
            d.line([(0, H * frac), (W, H * frac)], fill=col, width=2)
        sheet.alpha_composite(raw_, (i * 2 * (W + 10), 30))
        app = im.filter(ImageFilter.GaussianBlur(3))
        dark = Image.new("RGBA", app.size, (0, 0, 0, 90))
        app.alpha_composite(dark)
        # mock grid in the top 45 %
        cs = 34
        for r in range(5):
            for c in range(6):
                if (r + c) % 3 == 0 or r == 2:
                    app.alpha_composite(empty.resize((cs, cs), Image.LANCZOS),
                                        (60 + c * (cs + 4), 120 + r * (cs + 4)))
        # mock anvil ring at the bottom
        fs = 250
        app.alpha_composite(face.resize((fs, fs), Image.LANCZOS), ((W - fs) // 2, H - fs - 40))
        sheet.alpha_composite(app, (i * 2 * (W + 10) + W + 5, 30))
        d0.text((i * 2 * (W + 10) + 4, 8), n + "  (raw, zones)  |  app-like", fill=WHITE_HEAT)
    sheet.save(os.path.join(PV, "backgrounds.png"))
    print("preview bg")


# --------------------------------------------------------------------------
# metal UI kit: drawn the way Flutter's centerSlice draws it, at app size
# --------------------------------------------------------------------------
UI = os.path.join(REPO, "app", "assets", "ui")
APPFONTS = os.path.join(REPO, "app", "assets", "fonts")
SLICES = {"plate": (60, 60, 420, 132), "plate_primary": (60, 60, 420, 132),
          "panel": (72, 72, 216, 216), "panel_gold": (72, 72, 216, 216),
          "tab": (36, 30, 108, 42)}
K = 3   # image px per logical px


def ui_img(name):
    return Image.open(os.path.join(UI, name + ".png")).convert("RGBA")


def nine(name, w, h):
    """9-slice draw (corners 1:1, edges stretched along one axis, centre both)
    to w x h image px, bilinear like Flutter's default filter quality."""
    im = ui_img(name)
    if name not in SLICES:
        return im.resize((w, h), Image.LANCZOS)
    L, T, R, B = SLICES[name]
    W, H = im.size
    xs_src = [0, L, R, W]
    ys_src = [0, T, B, H]
    xs_dst = [0, L, w - (W - R), w]
    ys_dst = [0, T, h - (H - B), h]
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for j in range(3):
        for i in range(3):
            box = (xs_src[i], ys_src[j], xs_src[i + 1], ys_src[j + 1])
            size = (xs_dst[i + 1] - xs_dst[i], ys_dst[j + 1] - ys_dst[j])
            if size[0] <= 0 or size[1] <= 0:
                continue
            part = im.crop(box)
            if part.size != size:
                part = part.resize(size, Image.BILINEAR)
            out.paste(part, (xs_dst[i], ys_dst[j]))
    return out


def app_font(file, px, weight=700):
    f = ImageFont.truetype(os.path.join(APPFONTS, file), px)
    try:
        f.set_variation_by_axes([weight])
    except Exception:
        pass
    return f


def _svg_polys(d, steps=12):
    """Minimal SVG path flattener (M L H V C S Q Z; arcs become lines):
    enough for the app's single-path game-icons. Returns [[(x, y), ...], ...]."""
    import re
    toks = re.findall(r"[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?", d)
    polys, cur, i = [], [], 0
    x = y = sx = sy = 0.0
    last_c = None
    cmd = None
    def num():
        nonlocal i
        v = float(toks[i]); i += 1
        return v
    while i < len(toks):
        if toks[i].isalpha():
            cmd = toks[i]; i += 1
        rel = cmd.islower()
        c = cmd.upper()
        ox, oy = (x, y) if rel else (0.0, 0.0)
        if c == "Z":
            if cur:
                polys.append(cur)
            cur = []
            x, y = sx, sy
            last_c = None
            continue
        if c == "M":
            if cur:
                polys.append(cur)
            x, y = ox + num(), oy + num()
            sx, sy = x, y
            cur = [(x, y)]
            cmd = "l" if rel else "L"
            last_c = None
        elif c == "L":
            x, y = ox + num(), oy + num(); cur.append((x, y)); last_c = None
        elif c == "H":
            x = ox + num(); cur.append((x, y)); last_c = None
        elif c == "V":
            y = oy + num(); cur.append((x, y)); last_c = None
        elif c in "CSQ":
            if c == "C":
                p1 = (ox + num(), oy + num())
            elif c == "S":
                p1 = (2 * x - last_c[0], 2 * y - last_c[1]) if last_c else (x, y)
            if c == "Q":
                q = (ox + num(), oy + num()); end = (ox + num(), oy + num())
                p1 = (x + 2 / 3 * (q[0] - x), y + 2 / 3 * (q[1] - y))
                p2 = (end[0] + 2 / 3 * (q[0] - end[0]), end[1] + 2 / 3 * (q[1] - end[1]))
            else:
                p2 = (ox + num(), oy + num()); end = (ox + num(), oy + num())
            for k in range(1, steps + 1):
                t = k / steps
                a, b, cc, dd = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t ** 3
                cur.append((a * x + b * p1[0] + cc * p2[0] + dd * end[0],
                            a * y + b * p1[1] + cc * p2[1] + dd * end[1]))
            last_c = p2
            x, y = end
        elif c == "A":
            for _ in range(5):
                num()
            x, y = ox + num(), oy + num(); cur.append((x, y)); last_c = None
        else:
            i += 1
    if cur:
        polys.append(cur)
    return polys


def icon(name, px, color=(255, 214, 150)):
    """An app SVG icon (game-icons style, viewBox 512) rasterised and tinted."""
    import re
    src = os.path.join(REPO, "app", "assets", "icons", name + ".svg")
    try:
        svg = open(src).read()
    except OSError:
        return None
    vb = re.search(r'viewBox="([^"]+)"', svg)
    vw = float(vb.group(1).split()[2]) if vb else 512.0
    ss = 4
    mask = Image.new("1", (px * ss, px * ss), 0)
    for dpath in re.findall(r' d="([^"]+)"', svg):
        for poly in _svg_polys(dpath):
            if len(poly) < 3:
                continue
            m = Image.new("1", mask.size, 0)
            ImageDraw.Draw(m).polygon([(u * px * ss / vw, v * px * ss / vw) for u, v in poly], fill=1)
            mask = ImageChops.logical_xor(mask, m)
    a = mask.convert("L").resize((px, px), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), color + (255,))
    out.putalpha(a)
    return out


def drop(canvas, im, x, y, off=4, rad=6, op=170):
    shadow_under(canvas, im, int(x), int(y), off=off * K // 2, rad=rad * K // 2, op=op)


def scene_bg(dim, blur_lp, size=(1080, 2340)):
    from PIL import ImageEnhance  # noqa: F401
    bgp = os.path.join(IMG, "bg_hall.webp")
    im = Image.open(bgp).convert("RGB").resize(size, Image.LANCZOS)
    r, g, b = im.split()      # the app's warm grade (warmth 1)
    im = Image.merge("RGB", (r.point(lambda v: min(255, v * 1.06)), g.point(lambda v: v * 0.86),
                             b.point(lambda v: v * 0.7)))
    if blur_lp > 0:
        im = im.filter(ImageFilter.GaussianBlur(blur_lp * K))
    im = im.convert("RGBA")
    ov = Image.new("RGBA", size)
    d = ImageDraw.Draw(ov)
    for yy in range(size[1]):
        t = yy / size[1]
        a = dim * (0.8 + 0.4 * t) if t < 0.5 else dim * (1.0 + 0.5 * (t - 0.5))
        d.line([(0, yy), (size[0], yy)], fill=FORGE_BLACK + (int(255 * min(1, a)),))
    im.alpha_composite(ov)
    return im


def text(c, xy, s, font, fill, anchor="la", glow=None):
    d = ImageDraw.Draw(c)
    if glow:
        g = Image.new("RGBA", c.size, (0, 0, 0, 0))
        ImageDraw.Draw(g).text(xy, s, font=font, fill=glow, anchor=anchor)
        c.alpha_composite(g.filter(ImageFilter.GaussianBlur(12)))
    d.text(xy, s, font=font, fill=fill, anchor=anchor)


def home_mock(dim, blur_lp, label):
    c = scene_bg(dim, blur_lp)
    title = app_font("Cinzel-Variable.ttf", 46 * K, 800)
    cap = app_font("Cinzel-Variable.ttf", 17 * K, 700)
    body = app_font("NunitoSans-Variable.ttf", 13 * K, 600)
    small = app_font("NunitoSans-Variable.ttf", 11 * K, 700)
    text(c, (540, 118 * K), "WORDSMITH", title, (255, 178, 63), "mm", glow=(255, 106, 19, 160))
    text(c, (540, 160 * K), "Forge words. Level up.", body, (200, 190, 180), "mm")
    # profile card
    x0, y0, w, h = 16, 186, 328, 150
    drop(c, nine("panel", w * K, h * K), x0 * K, y0 * K)
    rb = nine("round", 56 * K, 56 * K)
    drop(c, rb, (x0 + 18) * K, (y0 + 22) * K, off=3, rad=4)
    ic = icon("hammer", 30 * K)
    if ic:
        c.alpha_composite(ic, ((x0 + 18 + 13) * K, (y0 + 22 + 13) * K))
    text(c, ((x0 + 88) * K, (y0 + 28) * K), "ALI_SMITH", cap, (255, 241, 208))
    text(c, ((x0 + 88) * K, (y0 + 56) * K), "Journeyman", body, (200, 190, 180))
    chip = nine("tab", 64 * K, 24 * K)
    drop(c, chip, (x0 + 244) * K, (y0 + 52) * K, off=2, rad=3)
    text(c, ((x0 + 276) * K, (y0 + 64) * K), "Lv 18", small, (255, 214, 150), "mm")
    d = ImageDraw.Draw(c)
    bx, by = (x0 + 88) * K, (y0 + 86) * K
    d.rounded_rectangle([bx, by, bx + 220 * K, by + 8 * K], radius=4 * K, fill=(30, 22, 18, 255),
                        outline=(90, 66, 44, 255), width=2)
    d.rounded_rectangle([bx + 3, by + 3, bx + 190 * K, by + 8 * K - 3], radius=3 * K,
                        fill=(255, 140, 40, 255))
    text(c, (bx, (y0 + 104) * K), "220 / 230 XP", small, (200, 190, 180))
    # buttons
    def plate(name, x, y, w, h, t1, t2, ic_name, dark_text=False):
        im = nine(name, w * K, h * K)
        drop(c, im, x * K, y * K)
        col = (58, 26, 10) if dark_text else (255, 241, 208)
        col2 = (90, 42, 14) if dark_text else (200, 186, 170)
        i = icon(ic_name, 26 * K, (58, 26, 10) if dark_text else (255, 214, 150))
        if i:
            c.alpha_composite(i, ((x + 18) * K, int((y + h / 2 - 13) * K)))
        text(c, ((x + 58) * K, int((y + h / 2 - (8 if t2 else 0)) * K)), t1, cap, col, "lm")
        if t2:
            text(c, ((x + 58) * K, int((y + h / 2 + 13) * K)), t2, body, col2, "lm")
    plate("plate_primary", 16, 350, 328, 72, "FORGE", "Bronze · Puzzle 42 of 60", "anvil", True)
    plate("plate", 16, 434, 328, 64, "DAILY COMMISSION", "Keep your 4-day streak going", "flame")
    plate("plate", 16, 510, 328, 64, "FORGE BOARD", "3 rewards waiting", "scroll")
    badge = nine("tab", 30 * K, 24 * K)
    drop(c, badge, 312 * K, 500 * K, off=2, rad=3)
    text(c, (327 * K, 512 * K), "3", small, (255, 214, 150), "mm")
    plate("plate", 16, 586, 158, 60, "CHAPTERS", "9 metals", "map")
    plate("plate", 186, 586, 158, 60, "FRIENDS", "0 online", "friends")
    plate("plate", 16, 658, 158, 60, "CO-OP", "Up to 4", "tongs")
    plate("plate", 186, 658, 158, 60, "VERSUS", "Up to 5", "trophy")
    text(c, (16 * K, 8 * K), label, small, (120, 200, 255))
    return c


def board_mock():
    c = scene_bg(0.3, 0.5)
    cap = app_font("Cinzel-Variable.ttf", 17 * K, 700)
    body = app_font("NunitoSans-Variable.ttf", 12 * K, 600)
    x0, y0 = 16, 40
    drop(c, nine("panel", 328 * K, 210 * K), x0 * K, y0 * K)
    text(c, ((x0 + 20) * K, (y0 + 26) * K), "STOKE THE FORGE", cap, (255, 241, 208))
    for i in range(7):
        name = "round_active" if i == 2 else "round"
        rb = nine(name, 40 * K, 40 * K)
        x = x0 + 16 + i * 43
        drop(c, rb, x * K, (y0 + 62) * K, off=2, rad=3)
        ic = icon("star" if i != 6 else "sparks", 18 * K,
                  (58, 26, 10) if name == "round_active" else (255, 200, 120))
        if ic:
            c.alpha_composite(ic, ((x + 11) * K, (y0 + 73) * K))
        text(c, ((x + 20) * K, (y0 + 116) * K), f"Day {i + 1}", body, (200, 190, 180), "mm")
    drop(c, nine("plate_primary", 296 * K, 52 * K), (x0 + 16) * K, (y0 + 140) * K)
    text(c, ((x0 + 164) * K, (y0 + 166) * K), "STOKE! (DAY 3)", cap, (58, 26, 10), "mm")
    y1 = y0 + 228
    drop(c, nine("panel_gold", 328 * K, 120 * K), x0 * K, y1 * K)
    text(c, ((x0 + 20) * K, (y1 + 28) * K), "SMITH'S LEDGER", cap, (255, 214, 150))
    text(c, ((x0 + 20) * K, (y1 + 54) * K), "Fill all three orders: 30 XP", body, (220, 205, 185))
    chip = nine("tab", 88 * K, 28 * K)
    drop(c, chip, (x0 + 220) * K, (y1 + 72) * K, off=2, rad=3)
    text(c, ((x0 + 264) * K, (y1 + 86) * K), "CLAIM", app_font("Cinzel-Variable.ttf", 13 * K, 700),
         (255, 214, 150), "mm")
    y2 = y1 + 140
    drop(c, nine("panel", 328 * K, 330 * K), x0 * K, y2 * K)
    text(c, ((x0 + 20) * K, (y2 + 28) * K), "WORK ORDERS", cap, (255, 241, 208))
    for i in range(3):
        drop(c, nine("plate", 296 * K, 56 * K), (x0 + 16) * K, (y2 + 64 + i * 70) * K)
        text(c, ((x0 + 36) * K, (y2 + 92 + i * 70) * K), ["Find 10 bonus words",
             "Forge 3 campaign puzzles", "Play a Co-op round"][i], body, (230, 220, 205), "lm")
    return c


def ui():
    if not os.path.exists(os.path.join(UI, "plate.png")):
        return
    # 1. the pieces at native size and stretched, on flat dark and mid tones
    W, H = 1500, 1260
    sheet = Image.new("RGBA", (W, H), (34, 26, 21, 255))
    d = ImageDraw.Draw(sheet)
    d.rectangle([W // 2, 0, W, H], fill=(70, 58, 50, 255))
    lab = app_font("NunitoSans-Variable.ttf", 26, 700)
    for half, x0 in ((0, 20), (1, W // 2 + 20)):
        y = 20
        d.text((x0, y), "native" if half == 0 else "native (mid background)", font=lab,
               fill=(200, 190, 180))
        y += 40
        for n in ("plate", "plate_primary"):
            shadow_under(sheet, ui_img(n), x0, y, off=6, rad=8)
            y += 210
        x = x0
        for n in ("round", "round_active", "tab"):
            shadow_under(sheet, ui_img(n), x, y, off=5, rad=7)
            x += ui_img(n).size[0] + 24
        y += 190
        for n in ("panel", "panel_gold"):
            shadow_under(sheet, ui_img(n), x0 + (0 if n == "panel" else 310), y, off=6, rad=8)
        y += 310
        # stretched as the app draws them
        shadow_under(sheet, nine("plate", 700, 160), x0, y, off=6, rad=8)
        shadow_under(sheet, nine("tab", 220, 72), x0, y + 180, off=4, rad=5)
        shadow_under(sheet, nine("tab", 96, 72), x0 + 240, y + 180, off=4, rad=5)
    sheet.save(os.path.join(PV, "ui_kit.png"))
    big = nine("panel_gold", 900, 1300)
    big2 = nine("panel", 900, 1300)
    st = Image.new("RGBA", (1880, 1360), (60, 48, 40, 255))
    shadow_under(st, big2, 20, 20)
    shadow_under(st, big, 960, 20)
    st.save(os.path.join(PV, "ui_panels_stretched.png"))
    # 2. app-size mock-ups over bg_hall (now: dim .55 blur 3; lighter: dim .25 blur .5)
    a = home_mock(0.45, 1.5, "bg dim 0.45, blur 1.5")
    b = home_mock(0.25, 0.5, "bg dim 0.25, blur 0.5")
    cmb = Image.new("RGBA", (a.size[0] * 2 + 30, a.size[1]), FORGE_BLACK + (255,))
    cmb.paste(a, (0, 0))
    cmb.paste(b, (a.size[0] + 30, 0))
    cmb.save(os.path.join(PV, "ui_home.png"))
    board_mock().save(os.path.join(PV, "ui_board.png"))
    print("preview ui")


STEPS = {"tiles": tiles, "anvil": anvil, "cells": cells, "bg": bg, "ui": ui}

if __name__ == "__main__":
    for k in (sys.argv[1:] or list(STEPS)):
        STEPS[k]()
