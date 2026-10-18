#!/usr/bin/env python3
"""Post-process raw Blender renders into the final app assets.

Plain Python 3 + Pillow + numpy (no bpy). Reads art/blender/_renders/,
writes app/assets/images/ (and the UI kit to app/assets/ui/).

    python3 post.py [tiles] [anvil] [cells] [icon] [bg] [ui] [ui_faces]   (default: all)
    python3 post.py bg bg_iron bg_gold                      (only these backgrounds)
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
RAW = os.path.join(HERE, "_renders")
OUT = os.path.join(REPO, "app", "assets", "images")   # bundled into the APK
ICON_OUT = os.path.join(REPO, "art", "icon")          # art/android_icons.py -> mipmaps
os.makedirs(OUT, exist_ok=True)
os.makedirs(ICON_OUT, exist_ok=True)


# --------------------------------------------------------------------------
# helpers (float RGBA arrays in 0..1, straight alpha)
# --------------------------------------------------------------------------
def load(path):
    im = Image.open(path).convert("RGBA")
    return np.asarray(im).astype(np.float32) / 255.0


def save_png(a, path, opaque=False):
    a = np.clip(a, 0, 1)
    if opaque:
        im = Image.fromarray((a[..., :3] * 255 + 0.5).astype(np.uint8), "RGB")
    else:
        # zero colour where fully transparent -> better PNG compression
        a = a.copy()
        a[a[..., 3] <= 0.5 / 255] = 0
        im = Image.fromarray((a * 255 + 0.5).astype(np.uint8), "RGBA")
    im.save(path, optimize=True)
    print(f"  wrote {os.path.relpath(path, REPO)}  {im.size[0]}x{im.size[1]}  "
          f"{os.path.getsize(path) / 1024:.1f} KB")


def save_webp(a, path, quality=92, opaque=False):
    """Lossy WebP with lossless alpha (much smaller than PNG for renders)."""
    a = np.clip(a, 0, 1)
    if opaque:
        im = Image.fromarray((a[..., :3] * 255 + 0.5).astype(np.uint8), "RGB")
        im.save(path, "WEBP", quality=quality, method=6)
    else:
        a = a.copy()
        a[a[..., 3] <= 0.5 / 255] = 0
        im = Image.fromarray((a * 255 + 0.5).astype(np.uint8), "RGBA")
        im.save(path, "WEBP", quality=quality, alpha_quality=100, method=6, exact=False)
    print(f"  wrote {os.path.relpath(path, REPO)}  {im.size[0]}x{im.size[1]}  "
          f"{os.path.getsize(path) / 1024:.1f} KB")


def resize(a, size):
    """High-quality downscale with premultiplied alpha."""
    if a.shape[1] == size[0] and a.shape[0] == size[1]:
        return a
    alpha = a[..., 3:4]
    pm = np.concatenate([a[..., :3] * alpha, alpha], axis=-1)
    chans = []
    for c in range(4):
        im = Image.fromarray(pm[..., c].astype(np.float32), "F")
        chans.append(np.asarray(im.resize(size, Image.LANCZOS)))
    pm = np.clip(np.stack(chans, -1), 0, None)
    al = np.clip(pm[..., 3:4], 0, 1)
    rgb = np.where(al > 1e-5, pm[..., :3] / np.maximum(al, 1e-5), 0)
    return np.concatenate([np.clip(rgb, 0, 1), al], -1)


def _box(a, r, axis):
    """Box blur of radius r along axis (edge-clamped), via cumulative sums."""
    if r < 1:
        return a
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    p = np.pad(a, pad, mode="edge")
    c = np.cumsum(p, axis=axis, dtype=np.float64)
    n = a.shape[axis]
    hi = np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return ((hi - lo) / (2 * r + 1)).astype(np.float32)


def blur(ch, radius):
    """Gaussian-ish blur (3 box passes) of a 2-D float array; radius ~ sigma."""
    if radius <= 0:
        return ch
    # box radius for 3 passes approximating sigma
    r = max(1, int(round((np.sqrt(4 * radius * radius + 1) - 1) / 2)))
    out = ch.astype(np.float32)
    for _ in range(3):
        out = _box(_box(out, r, 0), r, 1)
    return out


def over(top, bottom):
    """Straight-alpha 'over' composite."""
    at, ab = top[..., 3:4], bottom[..., 3:4]
    ao = at + ab * (1 - at)
    rgb = (top[..., :3] * at + bottom[..., :3] * ab * (1 - at)) / np.maximum(ao, 1e-6)
    return np.concatenate([rgb, ao], -1)


def circle_mask(size, radius, cx=None, cy=None, soft=1.0):
    h, w = size[1], size[0]
    cx = (w - 1) / 2 if cx is None else cx
    cy = (h - 1) / 2 if cy is None else cy
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    return np.clip((radius - d) / soft + 0.5, 0, 1)


def rounded_rect_mask(w, h, r, inset=0.0, soft=1.0):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32) + 0.5
    x0, y0, x1, y1 = inset, inset, w - inset, h - inset
    cx = np.clip(xx, x0 + r, x1 - r)
    cy = np.clip(yy, y0 + r, y1 - r)
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) - r
    return np.clip(0.5 - d / soft, 0, 1)


def raw(*p):
    return os.path.join(RAW, *p)


def out(name):
    return os.path.join(OUT, name)


# --------------------------------------------------------------------------
# 1. tiles
# --------------------------------------------------------------------------
def tiles():
    print("tiles")
    imgs = {k: resize(load(raw("tiles", f"tile_{k}.png")), (256, 256))
            for k in ("cold", "hot", "used")}
    # one shared, clean alpha mask so the states swap seamlessly
    alpha = np.max(np.stack([imgs[k][..., 3] for k in imgs]), axis=0)
    alpha = np.where(alpha < 2 / 255, 0, alpha)
    for k, a in imgs.items():
        a = a.copy()
        a[..., 3] = alpha
        save_png(a, out(f"tile_{k}.png"))


# --------------------------------------------------------------------------
# 2. anvil face (+ additive glow layer)
# --------------------------------------------------------------------------
def drop_shadow(a, offset=(0, 8), radius=12, opacity=0.6, color=(0.04, 0.02, 0.015)):
    """Put a soft drop shadow (from a's own alpha) underneath a."""
    al = a[..., 3]
    sh = np.zeros_like(al)
    dx, dy = offset
    h, w = al.shape
    sh[max(dy, 0):h + min(dy, 0), max(dx, 0):w + min(dx, 0)] = \
        al[max(-dy, 0):h - max(dy, 0), max(-dx, 0):w - max(dx, 0)]
    sh = blur(sh, radius) * opacity
    shadow = np.concatenate([np.broadcast_to(np.array(color, np.float32),
                                             al.shape + (3,)), sh[..., None]], -1)
    return over(a, shadow)


def additive_layer(emission, bloom_radius=0.0, bloom_gain=0.0):
    """Emission render (black body on transparent) -> RGBA whose premultiplied
    colour equals the emitted light, i.e. ready for BlendMode.plus / screen."""
    e = emission[..., :3] * emission[..., 3:4]          # premultiplied light
    if bloom_radius > 0:
        bl = np.stack([blur(e[..., c], bloom_radius) for c in range(3)], -1)
        e = e + bl * bloom_gain
    e = np.clip(e, 0, 1)
    al = np.max(e, axis=-1, keepdims=True)
    rgb = np.where(al > 1e-4, e / np.maximum(al, 1e-4), 0)
    return np.concatenate([rgb, al], -1)


ANVIL = 768   # ring shows at ~260 dp (~780 px on a 3x phone)


def anvil():
    print("anvil")
    k = ANVIL / 1024.0
    face = resize(load(raw("anvil", "anvil_face.png")), (ANVIL, ANVIL))
    # WebP (lossy colour, lossless alpha): ~8x smaller than PNG, same look
    save_webp(drop_shadow(face, offset=(0, round(9 * k)), radius=13 * k, opacity=0.65),
              out("anvil_face.webp"))
    glow = resize(load(raw("anvil", "anvil_face_glow.png")), (ANVIL, ANVIL))
    save_webp(additive_layer(glow, bloom_radius=14 * k, bloom_gain=0.4),
              out("anvil_face_glow.webp"))
    for old in ("anvil_face.png", "anvil_face_glow.png"):   # superseded names
        if os.path.exists(out(old)):
            os.remove(out(old))


# --------------------------------------------------------------------------
# 3. mold cells
# --------------------------------------------------------------------------
CELL = 128
CELL_FOOT = 124.0               # keep in sync with cells.py FOOT_PX
CELL_CORNER = 0.13 * CELL_FOOT  # cells.py CORNER (in cell units) -> px


def cells():
    print("cells")
    mask = rounded_rect_mask(CELL, CELL, CELL_CORNER, inset=(CELL - CELL_FOOT) / 2)
    empty = resize(load(raw("cells", "cell_empty.png")), (CELL, CELL))
    empty[..., 3] = mask
    save_png(empty, out("cell_empty.png"))
    metal = resize(load(raw("cells", "cell_metal.png")), (CELL, CELL))
    # force perfectly neutral grey (the app tints it by multiplying)
    lum = metal[..., 0] * 0.2126 + metal[..., 1] * 0.7152 + metal[..., 2] * 0.0722
    metal[..., 0] = metal[..., 1] = metal[..., 2] = lum
    metal[..., 3] = mask
    save_png(metal, out("cell_metal.png"))


# --------------------------------------------------------------------------
# 4. app icon  (-> art/icon/, turned into mipmaps by art/android_icons.py)
# --------------------------------------------------------------------------
def icon_out(name):
    return os.path.join(ICON_OUT, name)


def lerp_stops(t, stops):
    """t array -> RGB from [(pos, (r,g,b)), ...] (0..1 floats)."""
    t = np.clip(t, 0, 1)
    out = np.zeros(t.shape + (3,), np.float32)
    for (p0, c0), (p1, c1) in zip(stops[:-1], stops[1:]):
        m = (t >= p0) & (t <= p1)
        k = ((t - p0) / max(p1 - p0, 1e-6))[..., None]
        out[m] = (np.array(c0) * (1 - k) + np.array(c1) * k)[m]
    return out


def hexf(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def icon_background(size=1024, seed=3):
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    # main glow behind the anvil/tile, slightly below centre
    d = np.sqrt((xx - 0.5) ** 2 + ((yy - 0.55) * 1.1) ** 2) / 0.62
    col = lerp_stops(d, [(0.0, hexf("#7A3212")), (0.22, hexf("#58220F")),
                         (0.5, hexf("#2E140B")), (0.8, hexf("#1A0D08")),
                         (1.2, hexf("#120907"))])
    # faint hearth warmth rising from the bottom edge
    col += (np.clip(1 - (1 - yy) / 0.35, 0, 1) ** 2)[..., None] * \
        np.array(hexf("#3A1608"), np.float32) * 0.5
    # soft smoky mottling + dither noise against banding
    rng = np.random.default_rng(seed)
    smoke = blur(rng.random((size, size)).astype(np.float32), 40)
    smoke = (smoke - smoke.mean()) / (smoke.std() + 1e-6)
    col *= (1 + 0.05 * smoke)[..., None]
    col += (rng.random((size, size, 1)).astype(np.float32) - 0.5) / 255.0
    return np.concatenate([np.clip(col, 0, 1), np.ones((size, size, 1), np.float32)], -1)


def bloom_under(fg, threshold=0.75, radius=22, gain=0.9, tint="#FF7A20"):
    """Soft glow from the brightest (emissive) pixels, placed under fg."""
    lum = fg[..., :3].max(-1) * fg[..., 3]
    hot = np.clip((lum - threshold) / (1 - threshold), 0, 1)
    g = blur(hot, radius) * gain + blur(hot, radius * 3) * gain * 0.6
    g = np.clip(g, 0, 0.85)
    glow = np.concatenate([np.broadcast_to(np.array(hexf(tint), np.float32),
                                           g.shape + (3,)), g[..., None]], -1)
    return over(fg, glow)


def id_masks(ids):
    """Classify the flat-colour ID render into named masks (0..1)."""
    a = ids[..., 3]
    rgb = ids[..., :3]
    refs = {"anvil": (1, 1, 0), "anvil_side": (0, 1, 1), "anvil_base": (1, 0, 1),
            "tile": (0, 1, 0),
            "letter": (0, 0, 1), "hammer": (1, 0, 0), "spark": (1, 1, 1)}
    d = np.stack([np.sum((rgb - np.array(c)) ** 2, -1) for c in refs.values()], -1)
    lab = np.argmin(d, -1)
    return {k: ((lab == i) & (a > 0.5)).astype(np.float32) for i, k in enumerate(refs)}


def erode(mask, px):
    if px <= 0:
        return mask
    im = Image.fromarray((mask * 255).astype(np.uint8), "L")
    return np.asarray(im.filter(ImageFilter.MinFilter(2 * px + 1))).astype(np.float32) / 255


def smooth_mask(mask, px):
    """Opening + closing + blur/threshold: removes specks, fills pinholes."""
    m = dilate(erode(mask, px), px)
    m = erode(dilate(m, px), px)
    return (blur(m, px * 0.6) > 0.5).astype(np.float32)


def dilate(mask, px):
    if px <= 0:
        return mask
    im = Image.fromarray((mask * 255).astype(np.uint8), "L")
    return np.asarray(im.filter(ImageFilter.MaxFilter(2 * px + 1))).astype(np.float32) / 255


SAFE_FRAC = 0.60      # adaptive-icon safe circle is 66/108 = 0.611 of the layer


def fit_safe(a, frac=SAFE_FRAC, thr=0.08, scale=None):
    """Shrink a centred RGBA layer so its content fits a circle of diameter
    frac * size. Returns (layer, scale used)."""
    h, w = a.shape[:2]
    if scale is None:
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        d = np.sqrt((xx - (w - 1) / 2) ** 2 + (yy - (h - 1) / 2) ** 2) / w
        r = float(d[a[..., 3] > thr].max()) * 2
        scale = min(1.0, frac / r)
    if scale >= 0.999:
        return a, 1.0
    n = int(round(w * scale))
    small = resize(a, (n, n))
    outa = np.zeros_like(a)
    o = (w - n) // 2
    outa[o:o + n, o:o + n] = small
    return outa, scale


def icon():
    print("icon")
    size = 1024
    bg = icon_background(size)
    save_png(bg, icon_out("icon_background.png"), opaque=True)

    fg = resize(load(raw("icon", "icon_fg.png")), (size, size))
    fg, k = fit_safe(fg, thr=0.3)
    print(f"  foreground scaled x{k:.3f} to fit the safe circle")
    fg = bloom_under(fg)
    save_png(fg, icon_out("icon_foreground.png"))

    # monochrome (Android 13 themed icon): one white silhouette, with the
    # letter knocked out and thin gaps between hammer / tile / anvil
    ids = load(raw("icon", "icon_ids.png"))
    m = id_masks(ids)
    gap = 9
    # sparks: drop the ones crowding the hammer, fatten the rest
    near_hammer = dilate(m["hammer"], 26)
    sparks = m["spark"] * (1 - near_hammer)
    sparks = dilate(sparks, 3)
    body = smooth_mask(np.clip(m["anvil"] + m["anvil_side"] + m["anvil_base"] +
                               m["tile"] + m["letter"], 0, 1), 3)
    tile = smooth_mask(np.clip(m["tile"] + m["letter"], 0, 1), 3)
    body = body * (1 - dilate(tile, gap))           # ring gap around the tile
    tile = tile * (1 - dilate(m["letter"], 1))       # letter knocked out
    # hammer: fill holes where sparks crossed in front of it
    hammer = smooth_mask(np.clip(m["hammer"] + m["spark"] * dilate(m["hammer"], 6), 0, 1), 8)
    rest = np.clip(body + tile + sparks, 0, 1) * (1 - dilate(hammer, gap))
    sil = np.clip(rest + hammer, 0, 1)
    sil = blur(sil, 1.0)
    sil = np.clip((sil - 0.5) * 3 + 0.5, 0, 1)
    sil = resize(np.concatenate([np.ones(sil.shape + (3,), np.float32), sil[..., None]], -1),
                 (size, size))
    sil, _ = fit_safe(sil, scale=k)          # same scale as the foreground
    sil[..., :3] = 1.0
    save_png(sil, icon_out("icon_monochrome.png"))

    # full preview: what a launcher shows -- the visible 72/108 of the layers,
    # in a rounded square
    full = over(fg, bg)
    c = size * (1 - 72 / 108) / 2
    crop = full[int(c):int(size - c), int(c):int(size - c)]
    full = resize(crop, (size, size))
    full[..., 3] = rounded_rect_mask(size, size, size * 0.23, soft=1.5)
    save_png(full, icon_out("icon_full.png"))


# --------------------------------------------------------------------------
# 5. backgrounds (1080x2340 WebP)
# --------------------------------------------------------------------------
BG_SIZE = (1080, 2340)
BG_QUALITY = 90          # WebP quality; stepped down only if a file would exceed the budget
BG_BUDGET_KB = 600       # per file: the ten backgrounds stay <= 6 MB in the app


def bloom_add(rgb, threshold=0.7, radii=(12, 40), gains=(0.35, 0.25)):
    """Additive glow around the brightest areas (fire, embers)."""
    lum = rgb.max(-1)
    hot = np.clip((lum - threshold) / (1 - threshold), 0, 1)[..., None] * rgb
    out = rgb.copy()
    for r, g in zip(radii, gains):
        out += np.stack([blur(hot[..., c], r) for c in range(3)], -1) * g
    return np.clip(out, 0, 1)


def calm_bands(rgb, top=0.45, bottom=0.62, top_dim=0.82, bottom_dim=0.78):
    """Gently darken the grid zone (top) and the very bottom (app flames)."""
    h = rgb.shape[0]
    y = np.linspace(0, 1, h, dtype=np.float32)
    k = np.ones_like(y)
    t_top = np.clip(y / top, 0, 1)
    t_bot = np.clip((y - bottom) / (1 - bottom), 0, 1)
    k = np.where(y < top, top_dim + (1 - top_dim) * t_top ** 1.5, k)
    k = np.where(y > bottom, 1 - (1 - bottom_dim) * t_bot ** 1.3, k)
    return rgb * k[:, None, None]


def background(name, **kw):
    src = load(raw("bg", f"{name}.png"))
    size = (src.shape[1], src.shape[0])
    img = Image.fromarray((src[..., :3] * 255 + 0.5).astype(np.uint8))
    if size != BG_SIZE:
        if size[0] > BG_SIZE[0]:                  # supersampled render: downscale
            img = img.resize(BG_SIZE, Image.LANCZOS)
        elif "--allow-upscale" in sys.argv:       # QUICK=1 previews only
            print(f"  NOTE {name}: raw is {size[0]}x{size[1]}, upscaled for a preview only")
            img = img.resize(BG_SIZE, Image.LANCZOS)
        else:
            print(f"  (skip {name}: raw is {size[0]}x{size[1]}, not native "
                  f"{BG_SIZE[0]}x{BG_SIZE[1]}; re-render with --scale 1.0)")
            return
    a = np.asarray(img).astype(np.float32) / 255
    a = bloom_add(a, **kw.get("bloom", {}))
    a = calm_bands(a, **kw.get("bands", {}))
    im = Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    path = out(f"{name}.webp")
    for q in range(BG_QUALITY, 69, -2):
        im.save(path, "WEBP", quality=q, method=6)
        if os.path.getsize(path) <= BG_BUDGET_KB * 1024:
            break
    print(f"  wrote {os.path.relpath(path, REPO)}  {im.size[0]}x{im.size[1]}  q{q}  "
          f"{os.path.getsize(path) / 1024:.1f} KB")


BG_SETTINGS = {
    "bg_hall": dict(bands=dict(top=0.45, bottom=0.66, top_dim=0.85, bottom_dim=0.5)),
    "bg_tin": dict(bands=dict(top=0.45, bottom=0.66, top_dim=0.85, bottom_dim=0.55)),
    "bg_copper": dict(bands=dict(top=0.45, bottom=0.66, top_dim=0.72, bottom_dim=0.55)),
    "bg_bronze": dict(bands=dict(top=0.45, bottom=0.66, top_dim=0.82, bottom_dim=0.55)),
    "bg_iron": dict(bands=dict(top=0.45, bottom=0.66, top_dim=0.82, bottom_dim=0.55)),
    "bg_steel": dict(bands=dict(top=0.45, bottom=0.66, top_dim=0.82, bottom_dim=0.55)),
    "bg_silver": dict(bands=dict(top=0.45, bottom=0.66, top_dim=0.82, bottom_dim=0.55)),
    "bg_gold": dict(bands=dict(top=0.45, bottom=0.66, top_dim=0.82, bottom_dim=0.55)),
    "bg_damascus": dict(bands=dict(top=0.45, bottom=0.66, top_dim=0.78, bottom_dim=0.55)),
    "bg_starmetal": dict(bands=dict(top=0.45, bottom=0.66, top_dim=0.85, bottom_dim=0.55)),
}
BG_NAMES = ("bg_hall", "bg_tin", "bg_copper", "bg_bronze", "bg_iron", "bg_steel", "bg_silver",
            "bg_gold", "bg_damascus", "bg_starmetal")


def bg():
    print("backgrounds")
    want = [a for a in sys.argv[2:] if a.startswith("bg_")] if sys.argv[1:2] == ["bg"] else []
    for name in want or BG_NAMES:
        if os.path.exists(raw("bg", f"{name}.png")):
            background(name, **BG_SETTINGS.get(name, {}))
        else:
            print(f"  (skip {name}: no raw render)")


# --------------------------------------------------------------------------
# 6. metal UI kit (9-slice PNGs at 3x) -> app/assets/ui/
# --------------------------------------------------------------------------
UI_OUT = os.path.join(REPO, "app", "assets", "ui")
UI_PANEL_FACE_ALPHA = 0.94
# share of the fine grain kept where the app stretches the image (1 = all)
UI_GRAIN_KEEP = {"plate": 0.5, "plate_primary": 0.5, "tab": 0.4, "panel": 0.0, "panel_gold": 0.0}


def _blur_axis(ch, sigma, axis):
    """1-D Gaussian-ish blur (3 box passes) along one axis of a 2-D array."""
    r = max(1, int(round((np.sqrt(4 * sigma * sigma + 1) - 1) / 2)))
    out = ch.astype(np.float32)
    for _ in range(3):
        out = _box(out, r, axis)
    return out


def _slice_weight(n, lo, hi, feather):
    """1 inside [lo, hi), smoothly 0 within `feather` px outside it."""
    i = np.arange(n, dtype=np.float32) + 0.5
    t = np.clip(np.minimum(i - (lo - feather), (hi + feather) - i) / feather, 0, 1)
    return t * t * (3 - 2 * t)


def nine_slice_safe(rgb, rect, grain_keep=0.0, feather=10, ysigma=6.0, grain_mask=None):
    """Make an image stretch cleanly with Flutter's centerSlice.

    Columns L..R are stretched horizontally: there every row is made exactly
    uniform along x (its mean over L..R). Rows T..B are stretched vertically:
    there the image is smoothed along y only. Both steps work along the stretch
    direction alone, so the crisp bevel profiles across an edge stay intact.
    Fine grain along the stretch direction is put back at `grain_keep` (times
    `grain_mask`, e.g. only on the face: grain on a bright polished rim would
    streak). The corners stay as rendered and blend in over `feather` px."""
    L, T, R, B = rect
    h, w = rgb.shape[:2]
    g = grain_keep if grain_mask is None else grain_keep * grain_mask[..., None]
    wx = _slice_weight(w, L, R, feather)[None, :, None]
    wy = _slice_weight(h, T, B, feather)[:, None, None]
    # horizontal stretch: uniform rows (+ x-only grain)
    fine_x = rgb - np.stack([_blur_axis(rgb[..., c], 1.2, 1) for c in range(3)], -1)
    rowmean = rgb[:, L:R].mean(axis=1, keepdims=True)
    out = rgb * (1 - wx) + (rowmean + g * fine_x) * wx
    # vertical stretch: smooth along y (+ y-only grain)
    smooth = np.stack([_blur_axis(out[..., c], ysigma, 0) for c in range(3)], -1)
    fine_y = out - np.stack([_blur_axis(out[..., c], 1.2, 0) for c in range(3)], -1)
    return out * (1 - wy) + (smooth + g * fine_y) * wy


def ui():
    print("ui kit")
    import ui_geom as G
    os.makedirs(UI_OUT, exist_ok=True)
    for name, spec in G.PIECES.items():
        src = raw("ui", f"{name}.png")
        if not os.path.exists(src):
            print(f"  (skip {name}: no raw render)")
            continue
        a = resize(load(src), spec["size"])
        alpha = G.alpha_mask(name)
        rgb = a[..., :3]
        if spec["slice"]:
            rgb = nine_slice_safe(rgb, spec["slice"], UI_GRAIN_KEEP.get(name, 0.0),
                                  grain_mask=G.field(name, "w_face"))
        if spec["kind"] == "panel":       # face reads solid but lets a hint through
            alpha = alpha * (1 - (1 - UI_PANEL_FACE_ALPHA) * G.field(name, "w_face"))
        save_png(np.concatenate([np.clip(rgb, 0, 1), alpha[..., None]], -1),
                 os.path.join(UI_OUT, f"{name}.png"))
    ui_faces()


def ui_faces():
    """Each kit piece's face alone (<name>_face.png), cut from the final PNG
    with the exact face weight, so the app can recolour face and rim apart
    for its colour schemes (app/lib/ui/widgets/forge_frame.dart)."""
    print("ui faces")
    import ui_geom as G
    for name in G.PIECES:
        src = os.path.join(UI_OUT, f"{name}.png")
        if not os.path.exists(src):
            print(f"  (skip {name}: no {name}.png)")
            continue
        a = load(src)
        a[..., 3] *= G.field(name, "w_face")
        save_png(a, os.path.join(UI_OUT, f"{name}_face.png"))


# --------------------------------------------------------------------------
# 7. the Hammer Strike hint's hammer (hammer_sprite.py)
# --------------------------------------------------------------------------
def hammer():
    """Crops the hammer to its pixels, scales it to 384 px on the long side
    and prints where its striking face and grip land, for the app's
    HammerStrike (app/lib/ui/mold/hammer_strike.dart)."""
    print("hammer")
    a = load(raw("hammer_strike.png"))
    with open(raw("hammer_strike.json")) as f:
        pts = json.load(f)
    h, w = a.shape[:2]
    ys, xs = np.nonzero(a[..., 3] > 2 / 255)
    m = 6
    x0, x1 = max(0, xs.min() - m), min(w, xs.max() + 1 + m)
    y0, y1 = max(0, ys.min() - m), min(h, ys.max() + 1 + m)
    a = a[y0:y1, x0:x1]
    scale = 384 / max(a.shape[:2])
    size = (round(a.shape[1] * scale), round(a.shape[0] * scale))
    save_png(resize(a, size), out("hammer_strike.png"))
    for k in ("face", "grip"):
        fx = (pts[k][0] * w - x0) / (x1 - x0)
        fy = (pts[k][1] * h - y0) / (y1 - y0)
        print(f"  {k}: Offset({fx:.4f}, {fy:.4f})  (fraction of the sprite, from the top left)")


STEPS = {"tiles": tiles, "anvil": anvil, "cells": cells, "icon": icon, "bg": bg, "ui": ui, "ui_faces": ui_faces, "hammer": hammer}


def main():
    want = [a for a in sys.argv[1:] if a in STEPS] or list(STEPS)
    for k in want:
        STEPS[k]()


if __name__ == "__main__":
    main()
