#!/usr/bin/env python3
"""Post-process raw Blender renders into the final app assets.

Plain Python 3 + Pillow + numpy (no bpy). Reads art/blender/_renders/,
writes app/assets/images/.

    python3 post.py [tiles] [anvil] [cells] [icon] [bg]     (default: all)
"""
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
    save_png(drop_shadow(face, offset=(0, round(9 * k)), radius=13 * k, opacity=0.65),
             out("anvil_face.png"))
    glow = resize(load(raw("anvil", "anvil_face_glow.png")), (ANVIL, ANVIL))
    save_png(additive_layer(glow, bloom_radius=14 * k, bloom_gain=0.4),
             out("anvil_face_glow.png"))


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


STEPS = {"tiles": tiles, "anvil": anvil, "cells": cells}


def main():
    want = sys.argv[1:] or list(STEPS)
    for k in want:
        STEPS[k]()


if __name__ == "__main__":
    main()
