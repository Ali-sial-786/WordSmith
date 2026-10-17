# art/blender: 3D render pipeline

Every 3D image in Wordsmith (letter tiles, anvil face, mold cells, app icon and
chapter backgrounds) comes from a Python (bpy) script in this folder. The
scripts build the scene from code, render it headless with Cycles on the CPU,
and then `post.py` turns the raw renders into the final optimised files.
Changing a colour or a light means editing a script and re-running it. Nothing
is touched up by hand.

```
fetch_assets.py   downloads the CC0 textures + font (pinned URL + sha256 from sources.json)
common.py         shared bpy helpers: scene/Cycles setup, cameras, lights, lathe, node builder
props.py          stylised props: anvil, hammer, tongs, sparks, iron/wood/hot-metal shaders
forge_kit.py      scene kit: textured materials, hearths, arched forge, flames, coals, barrels, haze
tiles.py          tile_cold / tile_hot / tile_used
anvil_face.py     anvil_face + anvil_face_glow
cells.py          cell_empty / cell_metal
icon.py           app icon foreground (+ an ID pass for the monochrome icon)
scene_hall.py     bg_hall   (Forge Hall, night)
scene_tin.py      bg_tin    (village smithy at dawn)
scene_copper.py   bg_copper (riverside workshop with water wheel, golden afternoon)
post.py           downscale, alpha/masks, drop shadow, glow layers, bloom, WebP; writes the outputs
preview.py        dev aid: mock-ups (letters on tiles, tiles on the anvil, tinted cells...)
run_all.sh        runs everything in order
sources.json      third-party inputs (url, sha256, author, licence, use); CREDITS.part.md = credits rows
```

Raw renders and logs go to `_renders/`, which is git-ignored. Downloads go to
`art/third_party/blender/`, which is also git-ignored.

## Setup

1. **Blender 4.5 LTS** (built and tested with 4.5.14). Headless use needs no GPU or display:
   ```sh
   curl -O https://download.blender.org/release/Blender4.5/blender-4.5.14-linux-x64.tar.xz
   sha256sum blender-4.5.14-linux-x64.tar.xz   # 9ba871ff2ecd36526b77432745980b7e6664ecd0c7ca11c48849073dcfe06da3
   tar xf blender-4.5.14-linux-x64.tar.xz && mv blender-4.5.14-linux-x64 /opt/blender
   ```
   Any other location works if you set `BLENDER=/path/to/blender`. The scripts use the
   4.x node API (Principled BSDF v2, `ShaderNodeMix`). Blender 5.x should work too, but it hasn't been tested.
2. **Python 3** with `Pillow` and `numpy`, for `post.py` and `preview.py`. Install
   `fonttools` too (`pip install pillow numpy fonttools`). `fetch_assets.py` uses it to cut a
   static Black weight of Roboto Slab for the icon's 3D "W", because Blender only loads a
   variable font's default instance.

## Run

```sh
cd art/blender
./run_all.sh                       # everything: fetch, render, post-process
./run_all.sh tiles cells           # only some: tiles anvil cells icon hall tin copper
QUICK=1 ./run_all.sh hall          # fast low-res/low-sample render to check a change
python3 post.py bg                 # just redo post-processing (tiles anvil cells icon bg)
python3 preview.py tiles anvil cells   # mock-ups in _renders/preview/
```

Single script: `"$BLENDER" -b --factory-startup -P tiles.py -- --samples 128 --res 768`
(the arguments after `--` are optional overrides).

## Outputs

| File | Size | Script | Notes |
|---|---|---|---|
| `app/assets/images/tile_cold.png` | 256×256 RGBA | tiles.py | dark forged-iron stud with a crisp warm rim line; for white letters |
| `app/assets/images/tile_hot.png` | 256×256 RGBA | tiles.py | glowing yellow-orange centre, ember rim; for dark-brown letters |
| `app/assets/images/tile_used.png` | 256×256 RGBA | tiles.py | dull cooled grey-blue, low contrast |
| `app/assets/images/anvil_face.webp` | 768×768 RGBA | anvil_face.py | hammered iron face, polished wear ring at 70 % radius, bronze band, 8 rivets, soft drop shadow |
| `app/assets/images/anvil_face_glow.webp` | 768×768 RGBA | anvil_face.py | additive rim-heat layer; draw with `BlendMode.plus` (or screen) and fade with opacity |
| `app/assets/images/cell_empty.png` | 128×128 RGBA | cells.py | recessed slot in dark casting sand |
| `app/assets/images/cell_metal.png` | 128×128 RGBA | cells.py | bevelled plate, exactly neutral grey, made to be tinted by multiply |
| `app/assets/images/bg_hall.webp` | 1080×2340 | scene_hall.py | big arched forge with flames at ~45–62 % down the frame |
| `app/assets/images/bg_tin.webp` | 1080×2340 | scene_tin.py | open hearth with flames, plus a dawn doorway with chickens |
| `app/assets/images/bg_copper.webp` | 1080×2340 | scene_copper.py | workshop across the river: forge glowing through open doors, water wheel |
| `art/icon/icon_background.png` | 1024² opaque | post.py | warm forge glow gradient (procedural) |
| `art/icon/icon_foreground.png` | 1024² RGBA | icon.py | hammer striking a glowing "W" tile on an anvil, sparks; fits the 61 % safe circle |
| `art/icon/icon_monochrome.png` | 1024² RGBA | icon.py + post.py | white silhouette with the W knocked out (Android 13 themed icon) |
| `art/icon/icon_full.png` | 1024² RGBA | post.py | preview: the visible 72/108 of fg over bg, in a rounded square |

Notes for the app:
* **Tiles**: all three share one alpha mask, so they swap pixel-perfectly. The stud's diameter is
  246 of the 256 px. No shadow is baked in, so draw it in Flutter, where it can follow the lift animation.
* **Anvil face**: the plate diameter is 714 of the 768 px (93 %), centred. The margin holds the shadow.
* **Cells**: the rounded-square footprint is 124 of the 128 px (corner radius about 16 px). Empty and metal match exactly.
* **Backgrounds**: the top ~45 % and the bottom are kept dark and calm. `post.py` adds a light
  bloom and slightly darkens both bands. They are rendered at 0.667 scale and upscaled with Lanczos:
  the app blurs and dims them anyway, and it saves a lot of render time.

## Render times

Measured on 4 CPU cores (no GPU) with Cycles + OpenImageDenoise at the default settings.
Every render is logged in `_renders/render_times.log`.

RENDER_TIMES_TABLE

## Look and tuning

* Colours come from `docs/ART_AND_AUDIO.md` §2: ember `#FF6A13`, molten `#FFB23F`, white heat
  `#FFF1D0`, cold iron `~#3A3B3F`. `C.hex_lin("#RRGGBB")` turns a palette hex into the
  linear value a shader needs.
* The UI assets render with the *Standard* view transform, so palette colours come out exactly.
  The scenes use *Filmic High Contrast*, which keeps the fire saturated and pushes its hottest
  parts toward yellow-white.
* Metal reads as dark because it reflects a dark room, not because its albedo is dark. The
  crisp rim highlights come from an emissive "ring light" (`C.ring_light`) that only shows up in
  reflections.
* World shaders: in a world node tree, *Generated* gives the raw view direction (z = sine of
  the elevation), not a 0..1 value. Place sky ramp stops with the horizon at 0.
* Keep a volume box (haze) slightly inside the walls and floor. If its faces are coplanar
  with the floor, the floor turns into a bright, washed-out plane.
