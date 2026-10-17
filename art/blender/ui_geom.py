"""Shapes of the metal UI kit, shared by ui_kit.py (inside Blender) and post.py.

Pure numpy, no bpy. Every piece is a heightfield plus material weights over the
image plane, in FINAL image pixels (the kit is drawn at 3x: 1 logical px = 3 px),
x to the right and y down from the top-left corner. ui_kit.py turns a piece into
a mesh and renders it top-down; post.py uses the same functions for the exact
alpha masks, so the silhouettes of the renders and the masks always agree.

9-slice rule: inside a piece's centre slice the surface is flat (or varies
only smoothly along y), and every feature (bevels, rivets, brackets, sheen
ramps) lives in the fixed border bands. Straight bevel runs depend only on
the distance to the edge, so they stretch without any visible change.
"""
import math

import numpy as np

# name: canvas (w, h), shape kind, centre slice (L, T, R, B) in image px or None
PIECES = {
    "plate":         dict(size=(480, 192), kind="plate", slice=(60, 60, 420, 132)),
    "plate_primary": dict(size=(480, 192), kind="plate", slice=(60, 60, 420, 132)),
    "panel":         dict(size=(288, 288), kind="panel", slice=(72, 72, 216, 216)),
    "panel_gold":    dict(size=(288, 288), kind="panel", slice=(72, 72, 216, 216)),
    "round":         dict(size=(168, 168), kind="round", slice=None),
    "round_active":  dict(size=(168, 168), kind="round", slice=None),
    "tab":           dict(size=(144, 72), kind="tab", slice=(36, 30, 108, 42)),
}

# outer silhouettes (keep in sync with the profiles below)
PLATE_R, PLATE_M = 42.0, 2.5          # corner radius, antialias margin
PANEL_R, PANEL_M = 36.0, 2.5
ROUND_R = 82.0                        # outer radius (canvas 168: 2 px margin)
TAB_M = 2.0                           # pill: radius = h/2 - margin


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def seg(v, a, b):
    """0..1 linear ramp of v over [a, b]."""
    return np.clip((v - a) / (b - a), 0.0, 1.0)


def sstep(v, a, b):
    t = seg(v, a, b)
    return t * t * (3 - 2 * t)


def rrect_inside(x, y, w, h, r, m):
    """Distance inside the rounded rect [m, w-m] x [m, h-m] with corner radius
    r (positive inside, negative outside)."""
    qx = np.abs(x - w / 2) - (w / 2 - m - r)
    qy = np.abs(y - h / 2) - (h / 2 - m - r)
    out = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r
    return -out


def quarter_round(t):
    """0 -> 1 with a vertical start (the outer roll of a bevel)."""
    t = np.clip(t, 0.0, 1.0)
    return np.sqrt(1 - (1 - t) ** 2)


def cos_fall(t):
    """1 -> 0, smooth at both ends (a rounded bevel going down)."""
    t = np.clip(t, 0.0, 1.0)
    return 0.5 + 0.5 * np.cos(np.pi * t)


def bump(t):
    """0 -> 1 -> 0 half sine (a bead, or a groove when negated)."""
    t = np.clip(t, 0.0, 1.0)
    return np.sin(np.pi * t)


def band_weight(d, a, b, soft=0.6):
    """~1 where a <= d <= b, antialiased over +-soft px."""
    return sstep(d, a - soft, a + soft) * (1 - sstep(d, b - soft, b + soft))


def ease_out(t):
    t = np.clip(t, 0.0, 1.0)
    return 1 - (1 - t) ** 2


# --------------------------------------------------------------------------
# pieces: each returns dict(z=height, d=inside distance, w_*=material weights,
# fy=vertical face parameter 0 (top) .. 1 (bottom), rd=radial 0..1 (round))
# --------------------------------------------------------------------------
def plate(x, y, w=480, h=192):
    """Wide button: polished rim (outer roll, crown, inner bevel), a thin dark
    groove, and a cushioned face that is flat across the centre slice."""
    d = rrect_inside(x, y, w, h, PLATE_R, PLATE_M)
    roll = 6.0 * quarter_round(d / 5.5)                               # 0 .. 5.5
    crown = 6.0 + 0.55 * bump((d - 5.5) / 4.0)                        # 5.5 .. 9.5
    bevel = 2.2 + 3.8 * cos_fall((d - 9.5) / 4.0)                     # 9.5 .. 13.5
    groove = 2.2 - 1.5 * bump((d - 13.5) / 3.0)                       # 13.5 .. 16.5
    # the cushion follows a rounder contour (radius 58) so its corners have no
    # mitre crease; on the straight runs dc == d
    dc = rrect_inside(x, y, w, h, 58.0, PLATE_M)
    edge = ease_out((dc - 16.5) / 34.0)                               # cushion 0 .. 1
    # plus a gentle dome along y only (stretch-safe): the upper half of the
    # face tilts towards the top light for a soft glossy sheen
    yn = (y - h / 2) / (h / 2 - PLATE_M - 16.5)
    face = 2.2 + edge * (4.0 + 4.0 * (1 - np.clip(yn, -1, 1) ** 2))
    z = np.select([d < 0, d < 5.5, d < 9.5, d < 13.5, d < 16.5],
                  [d * 3.0, roll, crown, bevel, groove], face)
    face_top, face_bot = PLATE_M + 16.5, h - PLATE_M - 16.5
    return dict(
        z=z, d=d,
        w_rim=1 - sstep(d, 13.2, 14.2),
        w_groove=band_weight(d, 14.0, 16.2),
        w_face=sstep(d, 16.0, 17.0),
        fy=seg(y, face_top, face_bot),
        edge=edge,
    )


def panel(x, y, w=288, h=288):
    """Card frame: steel outer roll, a dark parting line, a bronze bead, an
    inner bevel down to a barely cushioned face; riveted L-brackets in the four
    corners (all inside the 72 px corner squares)."""
    d = rrect_inside(x, y, w, h, PANEL_R, PANEL_M)
    roll = 4.6 * quarter_round(d / 4.0)                               # steel 0 .. 4
    steel_top = 4.6 + 0.3 * bump((d - 4.0) / 1.6)                     # 4 .. 5.6
    notch = 4.6 - 1.0 * bump((d - 5.6) / 1.4)                         # 5.6 .. 7
    bead = 4.6 + 1.0 * bump((d - 7.0) / 3.4)                          # bronze 7 .. 10.4
    bevel = 1.2 + 3.4 * cos_fall((d - 10.4) / 3.2)                    # 10.4 .. 13.6
    dc = rrect_inside(x, y, w, h, 50.0, PANEL_M)                      # crease-free cushion
    face = 1.2 + 2.0 * ease_out((dc - 13.6) / 30.0)                   # flat from d = 43.6
    z = np.select([d < 0, d < 4.0, d < 5.6, d < 7.0, d < 10.4, d < 13.6],
                  [d * 3.0, roll, steel_top, notch, bead, bevel], face)
    w_rim2 = 1 - sstep(d, 5.4, 6.2)                 # steel
    w_groove = band_weight(d, 5.8, 6.8, 0.5)
    w_rim = band_weight(d, 6.6, 13.2)               # bronze bead + inner bevel

    # corner brackets, built in corner-local coords (u, v) = distance from the
    # nearest vertical / horizontal canvas edge, so all four are mirror images
    u = np.minimum(x, w - x)
    v = np.minimum(y, h - y)
    c0 = PANEL_M + PANEL_R                          # corner arc centre (u = v = c0)
    band_in, band_out = 2.0, 19.5                   # bracket spans this range of d
    mid = (band_in + band_out) / 2
    arm = 49.0                                      # arm length along each edge
    s_band = np.maximum(band_in - d, d - band_out)              # <0 inside the band
    s_arm = np.maximum(u - arm, v - arm)
    s_br = np.maximum(s_band, s_arm)
    lobe_c = PANEL_M + mid                          # lobes sit on the band's centre line
    lobe_r = 10.5
    s_lobe1 = np.hypot(u - arm, v - lobe_c) - lobe_r
    s_lobe2 = np.hypot(u - lobe_c, v - arm) - lobe_r
    boss = c0 - (PANEL_R - mid) / math.sqrt(2)
    s_boss = np.hypot(u - boss, v - boss) - 12.0
    s_br = np.minimum(np.minimum(s_br, s_lobe1), np.minimum(s_lobe2, s_boss))
    inside_br = -s_br                               # distance inside the bracket
    br_z = 3.0 + 4.2 * quarter_round(inside_br / 3.2) + 0.25 * ease_out((inside_br - 3.2) / 6.0)
    br_z = np.where(inside_br > 0, br_z, -1e3)
    # rivets: lobes + boss
    riv = np.full_like(d, -1e3)
    w_riv = np.zeros_like(d)
    for (cu, cv, rr) in ((arm, lobe_c, 4.6), (lobe_c, arm, 4.6), (boss, boss, 5.6)):
        r = np.hypot(u - cu, v - cv)
        dome = 7.45 + 2.6 * np.sqrt(np.clip(1 - (r / rr) ** 2, 0, 1))
        riv = np.where(r < rr, np.maximum(riv, dome), riv)
        w_riv = np.maximum(w_riv, 1 - sstep(r, rr - 0.8, rr + 0.2))
    z = np.maximum(np.maximum(z, br_z), riv)
    w_br = sstep(inside_br, -0.4, 0.6)
    face_w = sstep(d, 13.2, 14.2) * (1 - w_br)
    other = 1 - w_br
    face_top = PANEL_M + 13.6
    return dict(
        z=z, d=d,
        w_rim=w_rim * other, w_rim2=w_rim2 * other, w_groove=w_groove * other,
        w_face=face_w, w_brk=w_br * (1 - w_riv), w_rivet=w_br * w_riv,
        fy=seg(y, face_top, h - face_top),
        top=1 - sstep(y, face_top, 72.0),            # lighter face near the top (fixed band)
        bracket=w_br,
    )


def round_button(x, y, w=168, h=168):
    """Round control: polished ring (outer roll, crown, a slightly conical
    face with 6 tiny rivets, inner bevel), groove, concave glossy dish."""
    cx, cy = w / 2, h / 2
    r = np.hypot(x - cx, y - cy)
    s = ROUND_R - r                                     # distance inside the edge
    roll = 6.0 * quarter_round(s / 5.0)                               # 0 .. 5
    crown = 6.0 + 0.5 * bump((s - 5.0) / 4.0)                         # 5 .. 9
    ringf = 6.0 - 0.6 * seg(s, 9.0, 19.0)                             # 9 .. 19
    bevel = 1.6 + 3.8 * cos_fall((s - 19.0) / 5.0)                    # 19 .. 24
    groove = 1.6 - 1.0 * bump((s - 24.0) / 2.6)                       # 24 .. 26.6
    rd = r / (ROUND_R - 26.6)                                         # dish 0..1
    dish = 1.6 - 4.2 * (1 - np.clip(rd, 0, 1) ** 2)                  # shallow concave
    z = np.select([s < 0, s < 5, s < 9, s < 19, s < 24, s < 26.6],
                  [s * 3.0, roll, crown, ringf, bevel, groove], dish)
    w_riv = np.zeros_like(r)
    rr, rp = 3.7, ROUND_R - 14.0
    for i in range(6):
        a = math.radians(60 * i)
        px, py = cx + rp * math.cos(a), cy - rp * math.sin(a)
        q = np.hypot(x - px, y - py)
        dome = 6.0 - 0.6 * 0.5 + 2.4 * np.sqrt(np.clip(1 - (q / rr) ** 2, 0, 1))
        z = np.where(q < rr, np.maximum(z, dome), z)
        w_riv = np.maximum(w_riv, 1 - sstep(q, rr - 0.7, rr + 0.2))
    return dict(
        z=z, d=s,
        w_rim=(1 - sstep(s, 23.8, 24.6)) * (1 - w_riv),
        w_rivet=w_riv,
        w_groove=band_weight(s, 24.4, 26.4, 0.5),
        w_face=sstep(s, 26.2, 27.0),
        rd=np.clip(rd, 0, 1),
        fy=seg(y, cy - (ROUND_R - 26.6), cy + (ROUND_R - 26.6)),
    )


def tab(x, y, w=144, h=72):
    """Pill chip: thin polished rim, groove, gently cushioned dark face."""
    R = h / 2 - TAB_M
    d = rrect_inside(x, y, w, h, R, TAB_M)
    roll = 3.6 * quarter_round(d / 3.0)                               # 0 .. 3
    crown = 3.6 + 0.3 * bump((d - 3.0) / 1.6)                         # 3 .. 4.6
    bevel = 1.2 + 2.4 * cos_fall((d - 4.6) / 2.2)                     # 4.6 .. 6.8
    groove = 1.2 - 0.8 * bump((d - 6.8) / 1.8)                        # 6.8 .. 8.6
    edge = ease_out((d - 8.6) / 18.0)
    yn = (y - h / 2) / (h / 2 - TAB_M - 8.6)
    face = 1.2 + edge * (2.2 + 1.6 * (1 - np.clip(yn, -1, 1) ** 2))   # flat in x from d = 26.6
    z = np.select([d < 0, d < 3.0, d < 4.6, d < 6.8, d < 8.6],
                  [d * 3.0, roll, crown, bevel, groove], face)
    return dict(
        z=z, d=d,
        w_rim=1 - sstep(d, 6.6, 7.4),
        w_groove=band_weight(d, 7.2, 8.4, 0.45),
        w_face=sstep(d, 8.2, 9.0),
        fy=seg(y, TAB_M + 8.6, h - TAB_M - 8.6),
        edge=edge,
    )


KINDS = {"plate": plate, "panel": panel, "round": round_button, "tab": tab}


def evaluate(name, x, y):
    p = PIECES[name]
    w, h = p["size"]
    return KINDS[p["kind"]](x, y, w, h)


def alpha_mask(name, ss=4):
    """Exact antialiased silhouette at the final size (ss x ss supersampled)."""
    w, h = PIECES[name]["size"]
    o = (np.arange(ss) + 0.5) / ss
    acc = np.zeros((h, w), np.float32)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    for oy in o:
        for ox in o:
            acc += (evaluate(name, xx + ox, yy + oy)["d"] > 0)
    return acc / (ss * ss)


def field(name, key, ss=4):
    """Any weight of a piece at the final size, ss x ss supersampled."""
    w, h = PIECES[name]["size"]
    o = (np.arange(ss) + 0.5) / ss
    acc = np.zeros((h, w), np.float64)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    for oy in o:
        for ox in o:
            acc += evaluate(name, xx + ox, yy + oy)[key]
    return (acc / (ss * ss)).astype(np.float32)
