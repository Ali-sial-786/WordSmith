#!/usr/bin/env python3
"""Build the browser version's icons and iPhone launch images.

Inputs (rendered by art/blender/post.py, like art/android_icons.py uses):
art/icon/icon_{background,foreground,full}.png, each 1024x1024, and the
Cinzel display font in app/assets/fonts/.

Outputs, all under app/web/ (copied into build/web by `flutter build web`):
  favicon.png                       64x64, the rounded launcher icon
  icons/Icon-192.png, Icon-512.png  manifest "any" icons: the rounded icon
                                    with transparent corners (Android, desktop)
  icons/Icon-maskable-{192,512}.png manifest "maskable" icons: full bleed,
                                    the anvil inside the 80% safe circle
  icons/apple-touch-icon.png        180x180, opaque and square (iOS rounds
                                    the corners itself and turns transparency
                                    black)
  icons/anvil.webp                  the anvil on its own, for the loading screen
  splash/launch-WxH.png             apple-touch-startup-image for each iPhone
                                    screen size: what the Home Screen app shows
                                    while index.html loads. Drawn to line up
                                    with the loading screen in index.html, so
                                    one fades into the other.

Needs Pillow (with WebP):  python3 art/web_icons.py
If you move the loading screen's anvil or title in index.html, change
ANVIL_* / TITLE_* here to match and rerun.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "art" / "icon"
WEB = ROOT / "app" / "web"
FONT = ROOT / "app" / "assets" / "fonts" / "Cinzel-Variable.ttf"

FORGE_BLACK = (0x12, 0x0C, 0x09)

# Foreground content fits a circle 0.60 of the layer wide (post.py SAFE_FRAC).
# Android shows the middle 72/108 of the layers; the maskable safe zone is a
# circle 80% wide, so a 0.78 crop keeps the anvil (0.60 / 0.78 = 77%) inside.
VISIBLE_CROP = 72 / 108
MASKABLE_CROP = 0.78

# Loading screen layout in CSS pixels, relative to the screen centre
# (index.html: .forge-anvil and .forge-title).
ANVIL_WIDTH = 176
ANVIL_CENTER_DY = -56
TITLE_TOP_DY = 44
TITLE_LINE_HEIGHT = 36
TITLE_SIZE = 30
TITLE_TRACKING = 0.2  # em, CSS letter-spacing
TITLE_WEIGHT = 700
TITLE_TOP_COLOR = (0xFF, 0xF1, 0xD0)
TITLE_MID_COLOR = (0xFF, 0xB2, 0x3F)
TITLE_BOTTOM_COLOR = (0xFF, 0x6A, 0x13)

# iPhone screens in portrait: (CSS width, CSS height, device pixel ratio).
IPHONES = [
    (440, 956, 3),  # 16 Pro Max, 17 Pro Max
    (402, 874, 3),  # 16 Pro, 17, 17 Pro
    (420, 912, 3),  # Air
    (430, 932, 3),  # 14 Pro Max, 15 Plus, 15 Pro Max, 16 Plus
    (393, 852, 3),  # 14 Pro, 15, 15 Pro, 16
    (428, 926, 3),  # 12 Pro Max, 13 Pro Max, 14 Plus
    (390, 844, 3),  # 12, 12 Pro, 13, 13 Pro, 14, 16e
    (375, 812, 3),  # X, XS, 11 Pro, 12 mini, 13 mini
    (414, 896, 3),  # XS Max, 11 Pro Max
    (414, 896, 2),  # XR, 11
    (414, 736, 3),  # 6s Plus, 7 Plus, 8 Plus
    (375, 667, 2),  # 6s, 7, 8, SE (2nd and 3rd generation)
]


def load(name: str) -> Image.Image:
    return Image.open(SRC / name).convert("RGBA")


def centre_crop(im: Image.Image, frac: float) -> Image.Image:
    size = im.width
    c = round(size * (1 - frac) / 2)
    return im.crop((c, c, size - c, size - c))


def save_png(im: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, optimize=True)
    print(f"  {path.relative_to(ROOT)}  {im.width}x{im.height}  {path.stat().st_size // 1024} KB")


def icons(bg: Image.Image, fg: Image.Image, full: Image.Image) -> None:
    layers = Image.alpha_composite(bg, fg)
    visible = centre_crop(layers, VISIBLE_CROP).convert("RGB")
    maskable = centre_crop(layers, MASKABLE_CROP).convert("RGB")
    lanczos = Image.Resampling.LANCZOS
    save_png(full.resize((64, 64), lanczos), WEB / "favicon.png")
    for size in (192, 512):
        save_png(full.resize((size, size), lanczos), WEB / "icons" / f"Icon-{size}.png")
        save_png(maskable.resize((size, size), lanczos), WEB / "icons" / f"Icon-maskable-{size}.png")
    save_png(visible.resize((180, 180), lanczos), WEB / "icons" / "apple-touch-icon.png")


def anvil(fg: Image.Image) -> Image.Image:
    """The foreground cropped to its glow, centred on the layer's centre so
    the anvil sits where it does in the launcher icon."""
    box = fg.getchannel("A").point(lambda v: 255 if v > 1 else 0).getbbox()
    half_w = max(512 - box[0], box[2] - 512)
    half_h = max(512 - box[1], box[3] - 512)
    return fg.crop((512 - half_w, 512 - half_h, 512 + half_w, 512 + half_h))


def title_layer(width: int, scale: int) -> tuple[Image.Image, int]:
    """WORDSMITH in Cinzel with the loading screen's gradient and glow, on a
    transparent strip `width` wide. Returns the strip and the offset of the
    CSS line box's top inside it."""
    size = TITLE_SIZE * scale
    font = ImageFont.truetype(str(FONT), size)
    font.set_variation_by_axes([TITLE_WEIGHT])
    tracking = TITLE_TRACKING * size
    text = "WORDSMITH"
    advances = [font.getlength(ch) for ch in text]
    run = sum(advances) + tracking * (len(text) - 1)
    pad = 24 * scale  # room for the glow
    line = TITLE_LINE_HEIGHT * scale
    height = line + 2 * pad
    ascent, descent = font.getmetrics()
    baseline = pad + (line - (ascent + descent)) / 2 + ascent

    mask = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask)
    x = (width - run) / 2
    for ch, adv in zip(text, advances):
        draw.text((x, baseline), ch, font=font, fill=255, anchor="ls")
        x += adv + tracking

    # Vertical gradient across the line box, as in the CSS.
    grad = Image.new("RGB", (1, height))
    for y in range(height):
        t = min(max((y - pad) / line, 0.0), 1.0)
        if t < 0.45:
            a, b, u = TITLE_TOP_COLOR, TITLE_MID_COLOR, t / 0.45
        else:
            a, b, u = TITLE_MID_COLOR, TITLE_BOTTOM_COLOR, (t - 0.45) / 0.55
        grad.putpixel((0, y), tuple(round(a[i] + (b[i] - a[i]) * u) for i in range(3)))
    grad = grad.resize((width, height))

    glow_alpha = mask.filter(ImageFilter.GaussianBlur(6 * scale)).point(lambda v: round(v * 0.45))
    glow = Image.new("RGBA", (width, height), TITLE_BOTTOM_COLOR + (0,))
    glow.putalpha(glow_alpha)
    letters = grad.convert("RGBA")
    letters.putalpha(mask)
    return Image.alpha_composite(glow, letters), pad


def splash(anvil_im: Image.Image, w: int, h: int, scale: int) -> Image.Image:
    W, H = w * scale, h * scale
    im = Image.new("RGBA", (W, H), FORGE_BLACK + (255,))
    aw = ANVIL_WIDTH * scale
    ah = round(anvil_im.height * aw / anvil_im.width)
    a = anvil_im.resize((aw, ah), Image.Resampling.LANCZOS)
    cy = H / 2 + ANVIL_CENTER_DY * scale
    im.alpha_composite(a, (round((W - aw) / 2), round(cy - ah / 2)))
    strip, pad = title_layer(W, scale)
    im.alpha_composite(strip, (0, round(H / 2 + TITLE_TOP_DY * scale - pad)))
    return im.convert("RGB")


def main() -> None:
    bg, fg, full = load("icon_background.png"), load("icon_foreground.png"), load("icon_full.png")
    print("icons")
    icons(bg, fg, full)

    anvil_im = anvil(fg)
    out = WEB / "icons" / "anvil.webp"
    small = anvil_im.resize((ANVIL_WIDTH * 3, round(anvil_im.height * ANVIL_WIDTH * 3 / anvil_im.width)),
                            Image.Resampling.LANCZOS)
    small.save(out, quality=88, method=6)
    print(f"  {out.relative_to(ROOT)}  {small.width}x{small.height}  {out.stat().st_size // 1024} KB")

    print("iPhone launch images")
    for w, h, scale in IPHONES:
        # A 256-colour palette keeps each one under ~70 KB; median cut keeps
        # the glow smooth and the background exactly FORGE_BLACK.
        im = splash(anvil_im, w, h, scale).quantize(256, method=Image.Quantize.MEDIANCUT)
        save_png(im, WEB / "splash" / f"launch-{w * scale}x{h * scale}.png")


if __name__ == "__main__":
    main()
