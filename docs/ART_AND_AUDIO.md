# Wordsmith — Art and Audio Plan

> Status: **Plan approved, not yet built.**
>
> **Approach:** use free, properly licensed assets where they fit and look
> good. Where they don't, make our own in **Blender** (3D renders) or
> **Inkscape** (vector), or generate them in code (shaders and particles).
> Nothing is taken from Wordscapes, Word Trails or any other commercial game.

---

## 1. Art direction

- **Mood:** a cosy blacksmith's workshop at night. Dark, sooty surroundings, glowing orange heat, and the soft sheen of cooled metal.
- **Style:** **stylised 3D renders** for the hero objects (the anvil, letter tiles, forge scenes), with a **clean, flat-leaning UI** on top. Shapes are rounded and chunky rather than photo-realistic, so it reads clearly on a phone.
- **Readability first:** letters are always high-contrast, light on dark. Backgrounds sit dimmed and softly blurred behind the play area.
- **Motion:** heat is the main visual language. Things glow when active, cool when done, and throw sparks when something good happens.

---

## 2. Colour palette

These become Flutter theme tokens.

| Token | Hex | Use |
|---|---|---|
| Forge Black | `#17110E` | App background |
| Soot | `#241B16` | Panels, cards |
| Ash | `#3A2F28` | Borders, empty mold cells |
| Iron | `#6B6F75` | Cold tiles, disabled controls |
| Steel | `#A3ACB5` | Secondary text, icons |
| Ember | `#FF6A13` | Primary accent, active trail |
| Molten | `#FFB23F` | Highlights, selected tiles |
| White Heat | `#FFF1D0` | Primary text and letters |
| Quench Red | `#D9433B` | Errors, timer warning |

**Heat tiers (difficulty badges):**

| Ember | Dull Red | Cherry Red | Orange | Yellow | White Heat |
|---|---|---|---|---|---|
| `#5A2A1C` | `#8B1E1E` | `#C0262D` | `#F0701E` | `#F6C343` | `#FFF4D6` |

**Player colours:**
- Copper `#C8693F`
- Gold `#E1B53B`
- Verdigris `#3FA58E`
- Cobalt `#4A78C8`
- Titanium `#9A6BC8` (Versus only)

Every player-coloured element also shows the player's **initial**, so no
information depends on colour alone. All text must meet a **4.5:1 contrast**
ratio.

**Chapter metal colours** (what finished cells cool to in solo):
- Tin `#B9BCB8`
- Copper `#C8693F`
- Bronze `#A97142`
- Iron `#7A7E84`
- Steel `#9FB3C4`
- Silver `#D5D9DF`
- Gold `#E1B53B`
- Damascus: a wavy grey pattern shader
- Starmetal: dark blue-violet with glints

---

## 3. Visual asset list

| # | Asset | How we'll make it | Free sources to try first | Notes |
|---|---|---|---|---|
| 1 | **Anvil** (base of the letter ring) | **Blender**, our own model. It's a simple hard-surface shape and it's the hero asset, so we want full control. | Iron/steel textures: ambientCG (CC0), Poly Haven (CC0). Lighting: a Poly Haven HDRI (CC0). | Rendered top-down at a slight angle on a transparent background. Two versions: cold, and a glowing-rim variant for active moments. |
| 2 | **Letter tiles** | **Blender** render of a **blank** round iron tile in 3 states: cold, hot (selected) and dim (used). | Same textures as the anvil | The **letters are drawn live** in Flutter with an emboss and glow, so any letter works with only 3 images. |
| 3 | **Molten trail** | **Code**: a gradient stroke with a glow blur, plus spark particles | — | An optional heat-shimmer fragment shader. |
| 4 | **Mold cells** | Empty: a recessed sand-cast slot (**Blender** bake or a CC0 sand texture). Filled: a **code**-drawn bevelled metal plate tinted by the metal or player colour. | ambientCG sand and stone (CC0) | The pour-and-cool animation is code (a shader drives the colour change). |
| 5 | **9 chapter backgrounds** | **Blender** scenes built from CC0 3D kits, lit with CC0 HDRIs | Quaternius (CC0), Kenney 3D kits (CC0), Poly Haven models and HDRIs (CC0) | Portrait 1080×2340 WebP (quality 90), rendered at that native size with no upscaling; dark and softly blurred behind play. The scenes are listed in §4. |
| 6 | **Forge Hall (home) hero art** | **Blender**: a forge interior with the hearth glowing | Same kits | Slow-drifting embers on top (code). |
| 7 | **Icons** (hammer, chisel, sparks, anvil, tongs, scrap bucket, crown, friends, etc.) | Free icon set, tinted in the app | **game-icons.net** (CC BY 3.0, credit each author; some icons are CC0) | Generic UI icons (back, settings, close) come from **Material Symbols** (Apache 2.0). |
| 8 | **UI panels and buttons** | **Blender** (`art/blender/ui_kit.py`): a metal 9-slice kit rendered with Cycles in a procedural studio light: polished bronze / gold / steel rims and riveted brackets around dark forged-iron or molten faces. `plate` / `plate_primary` (menu buttons), `panel` / `panel_gold` (cards), `round` / `round_active` (round controls), `tab` (chips and badges) | — (all procedural, no third-party input) | PNG at 3× in `app/assets/ui/`, drawn with `centerSlice` (rects in `art/blender/README.md`); flat centres, so they stretch cleanly. No baked shadows. |
| 9 | **Avatars** | 16 emblem avatars (hammer, tongs, anvil, flame, helm, …) on metal badge backgrounds | game-icons.net emblems + our own badge frames | More can be unlocked later as level rewards. |
| 10 | **App icon** | **Blender**: a hammer striking a glowing tile on an anvil, with sparks | — | Android adaptive icon (separate foreground and background layers) plus a **monochrome** version for themed icons. |
| 11 | **"Forged!" and level-up moments** | **Code** particle bursts plus a short **Blender** hammer-strike sprite sequence (about 12 frames) | — | Short and skippable. |
| 12 | **Pickup marker** | **Code** glow plus a small ember icon in the grid cell | game-icons.net | A gentle pulse so it's noticeable but not distracting. |
| 13 | **Rank badges** (Apprentice → Legend) | **Inkscape**: six badges in progressively finer metals | — | Shown on the profile and in lobbies. |
| 14 | **Forge Board, calendar and Lore icons** | Free icon set, tinted in the app (same pipeline as #7) | game-icons.net (CC BY 3.0); Material Symbols (Apache 2.0) for `swap` | `scroll` (Work Orders), `gift`, `bellows` (Daily Stoke), `calendar`, `book` (Lore Book), `blueprint`, `gilded` (gold ingot), `swap`, `speaker` (pronunciation). Trophies reuse the existing `trophy`. |
| 15 | **Masterworks** (12 legendary items, `shared/masterworks.md`) | One game-icons.net glyph per item in `app/assets/masterworks/<id>.svg`, cleaned like the icons (fill `#ffffff`, transparent, 512×512 viewBox) | game-icons.net (CC BY 3.0) | The app tints them: blueprint-white while unfinished, a metal gradient once finished. Names, piece counts and blurbs are in `app/assets/masterworks/masterworks.json`. |

---

## 4. Chapter scenes

| Chapter | Scene | Lighting |
|---|---|---|
| Tin | A village smithy at dawn, with an open door and chickens outside | Soft morning light plus the forge glow |
| Copper | A riverside workshop with a water wheel | Warm afternoon |
| Bronze | An ancient casting pit with clay moulds | Torchlight |
| Iron | A mountain forge cut into rock | Cool blue night plus orange hearth |
| Steel | An early industrial foundry with crucibles and chains | Molten pour glow |
| Silver | A silversmith's studio in moonlight | Cool, silvery |
| Gold | A royal goldsmith's vault with treasure shelves | Rich warm gold |
| Damascus | A desert bladesmith's workshop at sunset | Hot dusk |
| Starmetal | A forge on a volcanic ridge under a meteor shower | Dramatic violet and orange |

---

## 5. Fonts (bundled in the app, not downloaded at runtime)

| Use | Font | Licence |
|---|---|---|
| Titles, banners ("Forged!") | **Cinzel** | OFL |
| Letter tiles and grid letters | **Roboto Slab** (Bold/Black): sturdy and very readable | Apache 2.0 / OFL (via Google Fonts) |
| UI text | **Nunito Sans** | OFL |

---

## 6. Audio

### Sound effects

| Event | Sound | Free sources to try first |
|---|---|---|
| Touching a tile | Short metallic "tink" that **rises in pitch with each tile** | Kenney audio packs (CC0), or generated |
| Valid grid word | Anvil clang plus a short sizzle | Sonniss GDC Game Audio Bundle (royalty-free, no attribution), Freesound (CC0 only) |
| Bonus word | Scrap clinking into a bucket | Kenney (CC0) |
| Already found | Soft dull tap | Kenney (CC0) |
| Invalid word | Dull "cold metal" thunk | Kenney (CC0) |
| Using a hint | Hammer strike (Chisel: a sharper tap; Spark Shower: a crackle) | Sonniss, Freesound CC0 |
| Pickup collected | Ember whoosh plus a small chime | Freesound CC0 |
| Puzzle complete ("Forged!") | Big anvil hit, quench hiss and a spark whoosh | Sonniss, Freesound CC0 |
| Level up / rank up | Short fanfare of bells and anvil chord | Kevin MacLeod stingers (CC BY 4.0), or our own |
| Countdown 3-2-1 | Three bellows puffs and a ding | Freesound CC0 |
| Last 10 seconds | Steady hammer "heartbeat" ticking | Kenney (CC0) |
| Teammate claimed a word (co-op) | Lighter clang in a different tone from your own | Made from the valid-word sound |
| Opponent finished (VS) | Deep gong-like anvil ring | Sonniss |
| Blueprint piece from a gilded cell (`gilded.ogg`) | Bright golden chime: a quick run of small bells over a shimmer (~1 s) | Synthesised (`art/audio/build_audio.py`) |
| Masterwork finished (`masterwork.ogg`) | Triumphant bell-and-anvil flourish ending on a big ringing chord (~3.3 s) | Synthesised, plus a Kenney bell (CC0) |
| Reward claimed: Work Order, gift, Daily Stoke (`claim.ogg`) | Warm two-note rising bell chime, no coins (~0.8 s) | Synthesised |
| Lore Book page turn (`page.ogg`) | Parchment page swish with a dry crinkle (~0.4 s) | Kenney RPG Audio `bookFlip2` (CC0) + synthesised layers |
| Hammer Strike swing (`swing.ogg`) | Short whoosh that swells as the hammer comes down and cuts off on impact (~0.3 s); the clang (`hint_hammer.ogg`) plays as it lands | Synthesised (`art/audio/swing.py`) |
| Survival: a heated word melts (`melt.ogg`) | Sizzle and steam over a sagging metal groan, bubbling, then drips (~2.4 s) | Synthesised (`art/audio/melt.py`; `python3 melt.py melt.wav`, then encode to Vorbis q4 mono) |

### Music and ambience

| Use | Sound | Free sources to try first |
|---|---|---|
| Ambience under the music | Forge fire crackle and the occasional bellows | Freesound CC0 |
| Music | Calm, warm, folk/medieval-flavoured loops for menus and puzzles, and a slightly more driving track for timed multiplayer | Kevin MacLeod / incompetech (CC BY 4.0), OpenGameArt (CC0 only) |

### Backup plan
If free libraries don't have the right metal sounds:
- **record a real hammer on steel** with a phone, or
- **synthesise** them (modal synthesis of a struck metal bar, via a small Python script).

### Audio rules
- Sound effects are **mono OGG**. Music is stereo OGG.
- Loudness is normalised to about −16 LUFS for music, with sound-effect peaks at −1 dBTP or below.
- Settings has separate **SFX / Music / Ambience** volume sliders, plus a **haptics** toggle.

### Written content

| Asset | What it is | Notes |
|---|---|---|
| `app/assets/lore/lore.json` | **Smith's Lore**: 150 short pages, one unlocked per Daily Commission completed (`shared/daily.md`) | `{"v": 1, "pages": [{id, title, text, topic}]}`; topics `metals`, `history`, `tools`, `words`, `legends`, `craft`; text ≤ 260 characters. Our own writing, fact-checked page by page; sources in `art/lore/SOURCES.md`. Myths are framed as myth or legend, and uncertain etymologies say "probably". Early pages are the most accessible, with topics mixed. |
| `app/assets/masterworks/masterworks.json` | Names and blurbs of the 12 Masterworks | `{"v": 1, "items": [{id, name, pieces, blurb}]}`; ids and piece counts match `shared/masterworks.md`. |

---

## 7. Licensing rules

- **Allowed:**
  - **CC0** (preferred)
  - **CC BY 3.0/4.0**, credited in the in-app **Credits** screen and in `art/CREDITS.md`
  - royalty-free licences that explicitly allow use in games (e.g. Sonniss GDC bundle)
  - **OFL / Apache 2.0** for fonts and icons
- **Not allowed:**
  - CC BY-SA, NC (non-commercial) or ND (no derivatives) art and sound
  - GPL-licensed assets
  - "free for personal use only" fonts
  - anything ripped from another game
- **Tracking:** every third-party file gets a line in `art/CREDITS.md` with file, source URL, author, licence and date. Licence texts are saved under `art/third_party/<pack>/LICENSE`. The in-app Credits screen is generated from that list.
- **Freesound:** licences vary per sound, so we only take sounds marked CC0 (or CC BY, with credit) and record each one individually.

---

## 8. Asset pipeline

```
art/
├─ fetch.py            downloads third-party packs from pinned URLs + checksums
├─ third_party/        (git-ignored) downloaded packs + their LICENSE files
├─ blender/            scene-building and render scripts (Python, bpy), plus small .blend files
├─ svg/                Inkscape sources (panels, badges, icon tweaks)
├─ audio/              source sound edits, synthesis scripts
├─ export.py           optimises renders → WebP/PNG at 1x/2x/3x, audio → OGG, into app/assets
│                      (`icons` also writes the Masterwork glyphs to app/assets/masterworks/)
├─ lore/SOURCES.md     a source note for every Smith's Lore page
└─ CREDITS.md          every third-party asset, source and licence
```

- **Reproducible renders:** Blender scenes are put together by **Python scripts** (bpy) from the downloaded CC0 kits, and rendered **headless** (Cycles on CPU with denoising). Changing a colour or a light means editing a script and re-rendering, not re-doing manual work. This also keeps big binary files out of git.
- **Only the final, optimised assets** are committed under `app/assets/`.
- **Size budget:**
  - APK under about 60 MB.
  - Each background at most 600 KB (WebP, quality 90, native 1080×2340); all ten under 6 MB.
  - The UI kit (seven 9-slice PNGs) about 0.4 MB.
  - All audio together under 8 MB.
- **Placeholders first:** early builds use simple code-drawn stand-ins, swapped for the real assets one at a time as they're made. Gameplay is never blocked waiting for art.
