# art/blender: 3D render pipeline

Every 3D image in Wordsmith (letter tiles, anvil face, mold cells, the metal UI
kit, app icon and chapter backgrounds) comes from a Python (bpy) script in this folder. The
scripts build the scene from code, render it headless with Cycles on the CPU,
and then `post.py` turns the raw renders into the final optimised files.
Changing a colour or a light means editing a script and re-running it. Nothing
is touched up by hand.

```
fetch_assets.py   downloads the CC0 textures + font (pinned URL + sha256 from sources.json)
common.py         shared bpy helpers: scene/Cycles setup, cameras, lights, lathe, node builder
props.py          stylised props: anvil, hammer, tongs, sparks, iron/wood/hot-metal shaders
forge_kit.py      scene kit: textured materials, hearths, arched forge, flames, coals, barrels, haze;
                  chapter kit: metal/blued/damascus/glow shaders, lathe-turned wares (bells, goblets,
                  urns, crucibles, moulds...), torches, chains, blades, coins, ingots, night skies,
                  meteors, and walls with exact boolean openings (round or pointed arches)
tiles.py          tile_cold / tile_hot / tile_used
anvil_face.py     anvil_face + anvil_face_glow
cells.py          cell_empty / cell_metal
ui_geom.py        UI kit shapes (pure numpy heightfields + material weights), shared with post.py
ui_kit.py         UI kit: plate / plate_primary / panel / panel_gold / round / round_active / tab
icon.py           app icon foreground (+ an ID pass for the monochrome icon)
scene_hall.py     bg_hall   (Forge Hall, night)
scene_tin.py      bg_tin    (village smithy at dawn)
scene_copper.py   bg_copper (riverside workshop with water wheel, golden afternoon)
scene_bronze.py   bg_bronze (torchlit bronze foundry: clay dome furnace, crucible pour, bell)
scene_iron.py     bg_iron   (mountain forge hewn into rock, moonlit peaks through a cave mouth)
scene_steel.py    bg_steel  (early steelworks at dusk: crucible pour on chains, blued steel)
scene_silver.py   bg_silver (silversmith's studio by moonlight, arched window)
scene_gold.py     bg_gold   (royal goldsmith's vault: treasure shelves, crown, molten gold)
scene_damascus.py bg_damascus (desert bladesmith's workshop at sunset, damascus blades)
scene_starmetal.py bg_starmetal (volcanic ridge forge under a meteor shower, meteorite iron)
post.py           downscale, alpha/masks, drop shadow, glow layers, bloom, 9-slice clean-up, WebP;
                  writes the outputs
preview.py        dev aid: mock-ups (letters on tiles, tiles on the anvil, tinted cells, the UI kit
                  drawn as 9-slices over bg_hall...)
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
./run_all.sh tiles cells           # only some: tiles anvil cells icon ui hall tin copper bronze
                                   #   iron steel silver gold damascus starmetal
QUICK=1 ./run_all.sh hall          # fast low-res/low-sample render to check a change
python3 post.py bg                 # just redo post-processing (tiles anvil cells icon bg ui)
python3 post.py bg bg_gold         # ...or only some backgrounds
python3 preview.py tiles anvil cells ui   # mock-ups in _renders/preview/
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
| `app/assets/images/bg_bronze.webp` | 1080×2340 | scene_bronze.py | round clay furnace, crucible pouring into a mould, hanging bronze bell, warrior statuette, torches |
| `app/assets/images/bg_iron.webp` | 1080×2340 | scene_iron.py | rock-cut smithy: open stone hearth, ragged cave mouth onto moonlit snowy peaks, chain and hook |
| `app/assets/images/bg_steel.webp` | 1080×2340 | scene_steel.py | steelworks: crucible on chains pouring into ingot moulds, steel-framed dusk windows, cupola, blued bars |
| `app/assets/images/bg_silver.webp` | 1080×2340 | scene_silver.py | moonlit studio: arched window with a big moon, silverware on the bench, small brazier and candle |
| `app/assets/images/bg_gold.webp` | 1080×2340 | scene_gold.py | treasury vault: round hearth with molten gold, shelves of gold, crown on a cushion, coins and bars |
| `app/assets/images/bg_damascus.webp` | 1080×2340 | scene_damascus.py | adobe workshop, pointed arch onto dunes and a huge low sun, rack of damascus blades |
| `app/assets/images/bg_starmetal.webp` | 1080×2340 | scene_starmetal.py | rock overhang framing a violet starry sky with meteors and a far volcano; glowing meteorite on the anvil |
| `app/assets/ui/plate.png` | 480×192 RGBA | ui_kit.py | menu button: polished bronze rim, dark groove, hammered dark-iron face with a sheen in the upper half |
| `app/assets/ui/plate_primary.png` | 480×192 RGBA | ui_kit.py | same shape: bright gold rim, molten face `#FFC45E` → `#FFB23F` → `#FF6A13` under a glassy coat |
| `app/assets/ui/panel.png` | 288×288 RGBA | ui_kit.py | card: steel roll + bronze bead border, riveted bronze corner brackets, `#1E1814`-ish face at alpha 0.94 |
| `app/assets/ui/panel_gold.png` | 288×288 RGBA | ui_kit.py | same card in pale + rich gold, warmer face (rewards / claimable) |
| `app/assets/ui/round.png` | 168×168 RGBA | ui_kit.py | round control: bronze ring with 6 rivets, glossy concave iron dish (110 px) |
| `app/assets/ui/round_active.png` | 168×168 RGBA | ui_kit.py | lit state: gold ring, molten orange dish |
| `app/assets/ui/tab.png` | 144×72 RGBA | ui_kit.py | pill chip / badge: thin bronze rim, dark glossy iron face |
| `art/icon/icon_background.png` | 1024² opaque | post.py | warm forge glow gradient (procedural) |
| `art/icon/icon_foreground.png` | 1024² RGBA | icon.py | hammer striking a glowing "W" tile on an anvil, sparks; post.py scales it so everything fits inside a 60 % circle (safe zone 61 %) |
| `art/icon/icon_monochrome.png` | 1024² RGBA | icon.py + post.py | white silhouette with the W knocked out (Android 13 themed icon) |
| `art/icon/icon_full.png` | 1024² RGBA | post.py | preview: the visible 72/108 of fg over bg, in a rounded square |

Notes for the app:
* **Tiles**: all three share one alpha mask, so they swap pixel-perfectly. The stud's diameter is
  246 of the 256 px. No shadow is baked in, so draw it in Flutter, where it can follow the lift animation.
* **Anvil face**: the plate diameter is 714 of the 768 px (93 %), centred. The margin holds the shadow.
* **Cells**: the rounded-square footprint is 124 of the 128 px (corner radius about 16 px). Empty and metal match exactly.
* **Backgrounds**: the top ~45 % and the bottom are kept dark and calm. `post.py` adds a light
  bloom and slightly darkens both bands. They are rendered at the native 1080×2340 (`--scale 1.0`,
  the default) and `post.py` never upscales them: a raw render smaller than 1080×2340 is skipped
  (only `QUICK=1` previews pass `--allow-upscale`). WebP quality 90, stepped down only if a file
  would pass 600 KB, so all ten stay under 6 MB.
* **UI kit** (`app/assets/ui/`): 9-slice PNGs at 3× (1 logical px = 3 image px), transparent
  outside the shape, no shadow baked in (the app adds it). Draw them with `centerSlice`:

  | Image | Size (logical) | `centerSlice` (image px) |
  |---|---|---|
  | `plate.png`, `plate_primary.png` | 160×64 | `Rect.fromLTRB(60, 60, 420, 132)` |
  | `panel.png`, `panel_gold.png` | 96×96 | `Rect.fromLTRB(72, 72, 216, 216)` |
  | `tab.png` | 48×24 | `Rect.fromLTRB(36, 30, 108, 42)` |
  | `round.png`, `round_active.png` | 56×56 | none (drawn at 56×56; the dish is the inner 110 px) |

  Outside the corners every feature runs straight along the edges, and the centre is flat
  (plates and tab: a smooth vertical sheen only), so any stretch is clean. The kit is lit only by
  a procedural studio environment (`ui_kit.studio_world`, no lamps): a straight bevel reflects the
  same thing along its whole length. `post.py` then makes the stretched rows and columns exactly
  uniform along the stretch and keeps only part of the fine grain there (`UI_GRAIN_KEEP`).
  The silhouettes and the panel's face alpha (0.94) come from `ui_geom.py`, the same functions
  that built the meshes, so masks and renders line up exactly.

## Render times

Measured on 4 CPU cores (no GPU) with Cycles + OpenImageDenoise at the default settings.
Every render is logged in `_renders/render_times.log`.

| Script | Render size | Samples | Time | Notes |
|---|---|---|---|---|
| tiles.py | 3 × 768² (→256²) | 128 | ~12 min (205–270 s each) | |
| anvil_face.py | 2 × 1152² (→768²) | 80 | ~10–13 min (face 380 s, glow 400 s) | measured while another render was running |
| cells.py | 2 × 512² (→128²) | 128 | ~1.5 min (23 s + 73 s) | |
| icon.py | 1024² + ID pass | 128 / 16 | ~1.5–2.5 min (85–137 s + 3 s) | |
| ui_kit.py | 7 pieces at 2× (plate 960×384 → 480×192) | 256 | ~25 min (plate 553 s, primary 326 s, panels 183–199 s, rounds 87–117 s, tab 54 s) | measured while a background render shared the 4 cores; `--ss 1 --samples 48` previews all seven in ~2 min |
| scene_hall.py | 1080×2340 | 80 | ~22 min (1332 s) | volumetric haze + flame volumes; measured while the UI kit renders shared the cores |
| scene_tin.py | 1080×2340 | 80 | ~25 min (1520 s) | volumetric haze; shared the cores with the UI kit renders |
| scene_copper.py | 1080×2340 | 80 | ~8.5 min (500 s) | |
| scene_bronze.py | 1080×2340 | 80 | ~19 min (1156 s) | volumetric haze, torches |
| scene_iron.py | 1080×2340 | 64 | ~12 min (est.) | haze (volume step rate 8) for the moon shaft |
| scene_steel.py | 1080×2340 | 64 | ~11 min (est.) | haze |
| scene_silver.py | 1080×2340 | 64 | ~10 min (est.) | haze |
| scene_gold.py | 1080×2340 | 64 | ~12 min (est.) | ~500 objects (coins are instances) |
| scene_damascus.py | 1080×2340 | 64 | ~14 min (est.) | haze |
| scene_starmetal.py | 1080×2340 | 64 | ~16 min (est.) | haze, emissive sky, displaced ground |
| post.py (all) | | | ~30 s | |

Native 1080×2340 costs about 2.25× the old 720×1561 renders (est. = 2.25 × the earlier 0.667-scale
time on an otherwise idle 4-core machine). Total for `./run_all.sh` is about 3–3.5 h. `QUICK=1` previews
take 10–60 s per asset. The chapter scenes from bronze on default to 64 samples and a volume step rate
of 8 (bronze: 80 / 4).

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
* The frame is narrow (about 35° across), so props only show within about ±1.1 m of the centre
  line at the anvil's depth, and side walls are never seen. Check placement with a `QUICK=1` render.
* Openings in flat walls (windows, arches): `K.wall_with_openings` with `K.arch_outline` cuts them
  with an exact boolean. For a displaced rock wall (bg_iron) delete grid faces before displacing
  instead: a boolean on a displaced, solidified slab comes out empty.
* An emissive "sky" plane behind a window blocks the sun unless it has `visible_shadow = False`.
* Thin planes lying just above the floor (sand patches) cast a dark outline under low light:
  turn their shadows off.
