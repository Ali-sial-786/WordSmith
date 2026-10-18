#!/usr/bin/env python3
"""Export optimised assets from art/third_party into app/assets, and build the credits.

    python3 art/fetch.py              # 1. download + verify third-party sources
    python3 art/export.py all         # 2. fonts + icons + audio + credits
    python3 art/export.py icons       #    ...or one step: fonts | icons | audio | credits

Steps:
  fonts    copy the variable TTFs to app/assets/fonts/ and licence texts (+ SCOWL's) to app/assets/licenses/
  icons    clean game-icons.net / Material Symbols SVGs into single-colour glyphs
           (background removed, fill #ffffff, so the app can tint them) in app/assets/icons/,
           and the twelve Masterwork glyphs in app/assets/masterworks/
  audio    run art/audio/build_audio.py (needs ffmpeg + numpy) -> app/assets/audio/
  credits  write art/CREDITS.md, art/credits.json (+ app/assets/credits.json) from art/sources.json plus the
           icon/font tables below and art/audio/manifest.json

Only the standard library is needed for fonts, icons and credits.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ART = Path(__file__).resolve().parent
ROOT = ART.parent
THIRD_PARTY = ART / "third_party"
ASSETS = ROOT / "app" / "assets"
AUDIO_MANIFEST = ART / "audio" / "manifest.json"
SVG_NS = "http://www.w3.org/2000/svg"
ICON_FILL = "#ffffff"

# app file -> (pack, source file in that pack, licence file in pack, app licence file name)
FONTS = {
    "Cinzel-Variable.ttf": ("font-cinzel", "Cinzel[wght].ttf", "OFL.txt", "Cinzel-OFL.txt"),
    "RobotoSlab-Variable.ttf": ("font-roboto-slab", "RobotoSlab[wght].ttf", "LICENSE.txt", "RobotoSlab-LICENSE.txt"),
    "NunitoSans-Variable.ttf": ("font-nunito-sans", "NunitoSans[YTLC,opsz,wdth,wght].ttf", "OFL.txt", "NunitoSans-OFL.txt"),
    "VollkornSC-Bold.ttf": ("font-vollkorn-sc", "VollkornSC-Bold.ttf", "OFL.txt", "VollkornSC-OFL.txt"),
    "Arvo-Bold.ttf": ("font-arvo", "Arvo-Bold.ttf", "OFL.txt", "Arvo-OFL.txt"),
    "AtkinsonHyperlegibleNext-Variable.ttf": ("font-atkinson-hyperlegible-next", "AtkinsonHyperlegibleNext[wght].ttf",
                                              "OFL.txt", "AtkinsonHyperlegibleNext-OFL.txt"),
    "Texturina-Variable.ttf": ("font-texturina", "Texturina[opsz,wght].ttf", "OFL.txt", "Texturina-OFL.txt"),
}
# The player picks a set in Settings (FontChoice in app/lib/ui/theme/theme.dart).
FONT_USE = {
    "Cinzel-Variable.ttf": "Titles in the Classic fonts. Variable axis wght 400-900.",
    "RobotoSlab-Variable.ttf": "Letter tiles in the Classic fonts. Variable axis wght 100-900 (use 700-900).",
    "NunitoSans-Variable.ttf": "UI text. Variable axes wght 200-1000, wdth 75-125, opsz 6-12, YTLC 440-540.",
    "VollkornSC-Bold.ttf": "Titles in the Forge fonts (the default). Bold (700) only.",
    "Arvo-Bold.ttf": "Letter tiles in the Forge fonts (the default); titles and tiles in Foundry. Bold (700) only.",
    "AtkinsonHyperlegibleNext-Variable.ttf": "Everything in the Clear fonts. Variable axis wght 200-800.",
    "Texturina-Variable.ttf": "Titles and letter tiles in the Guild fonts. Variable axes wght 100-900, opsz 12-72.",
}

GI = "game-icons"
ICONS = {
    "hammer.svg": (GI, "lorc/flat-hammer.svg"),
    "chisel.svg": (GI, "delapouite/chisel.svg"),
    "sparks.svg": (GI, "lorc/laser-sparks.svg"),
    "turn.svg": (GI, "lorc/cycle.svg"),
    "anvil.svg": (GI, "lorc/anvil.svg"),
    "scrap_bucket.svg": (GI, "delapouite/full-metal-bucket-handle.svg"),
    "ember.svg": (GI, "lorc/ember-shot.svg"),
    "tongs.svg": (GI, "lorc/pincers.svg"),
    "crown.svg": (GI, "lorc/queen-crown.svg"),
    "friends.svg": (GI, "delapouite/three-friends.svg"),
    "settings.svg": (GI, "lorc/cog.svg"),
    "back.svg": ("material-symbols", "arrow_back_wght600_24px.svg"),
    "lock.svg": (GI, "lorc/padlock.svg"),
    "star.svg": (GI, "delapouite/round-star.svg"),
    "trophy.svg": (GI, "delapouite/trophy-cup.svg"),
    "flame.svg": (GI, "carl-olsen/flame.svg"),
    "map.svg": (GI, "lorc/treasure-map.svg"),
    "user.svg": (GI, "delapouite/character.svg"),
    # Forge Board, Daily Commission calendar, Lore Book and Masterworks screens
    "scroll.svg": (GI, "lorc/scroll-unfurled.svg"),            # Work Orders
    "gift.svg": (GI, "delapouite/present.svg"),                # friend gifts
    "bellows.svg": (GI, "delapouite/bellows.svg"),             # Daily Stoke (login reward)
    "calendar.svg": (GI, "delapouite/calendar.svg"),
    "book.svg": (GI, "delapouite/book-cover.svg"),             # Smith's Lore book
    "blueprint.svg": (GI, "seregacthtuf/armor-blueprint.svg"),  # blueprint pieces
    "gilded.svg": (GI, "willdabeast/gold-bar.svg"),            # gilded cell / gold ingot
    "swap.svg": ("material-symbols", "swap_horiz_wght600_24px.svg"),
    "speaker.svg": (GI, "delapouite/speaker.svg"),             # play pronunciation
}
AVATARS = [  # avatar_01.svg ... avatar_16.svg
    "delapouite/thor-hammer.svg", "lorc/anvil-impact.svg", "delapouite/blacksmith.svg", "lorc/fluffy-flame.svg",
    "kier-heyl/dwarf-helmet.svg", "lorc/checked-shield.svg", "lorc/battle-axe.svg", "lorc/sword-smithing.svg",
    "delapouite/horseshoe.svg", "lorc/gears.svg", "delapouite/imperial-crown.svg", "lorc/dragon-head.svg",
    "lorc/wolf-head.svg", "delapouite/bear-head.svg", "lorc/owl.svg", "lorc/mountains.svg",
]
for _i, _src in enumerate(AVATARS, 1):
    ICONS[f"avatar_{_i:02d}.svg"] = (GI, _src)

# Rank badges (Apprentice -> Legend). Unlike the icons above these keep their colour: each is filled
# with a vertical metal gradient (light top -> base -> dark bottom), so the app should draw them
# untinted (SvgPicture.asset without a colorFilter). A badge is one or more game-icons glyphs, each
# with an SVG transform in the 512x512 icon space ("" = as drawn).
METALS = {  # light, base (docs/ART_AND_AUDIO.md chapter colours), dark
    "bronze": ("#E8B27A", "#A97142", "#5E3A1E"),
    "iron": ("#B4B8BE", "#7A7E84", "#44474C"),
    "steel": ("#DCEAF6", "#9FB3C4", "#55697C"),
    "silver": ("#FFFFFF", "#D5D9DF", "#8E949C"),
    "gold": ("#FFF0B0", "#E1B53B", "#8A6210"),
    "starmetal": ("#FFFFFF", "#B9A8FF", "#5A46C8"),
}
RANKS = {
    "rank_apprentice.svg": ("bronze", [("delapouite/3d-hammer.svg", "")]),
    "rank_journeyman.svg": ("iron", [("delapouite/3d-hammer.svg",
                                      "translate(318 262) rotate(-6) scale(0.74) translate(-256 -256)"),
                                     ("delapouite/3d-hammer.svg",
                                      "translate(194 262) rotate(6) scale(-0.74 0.74) translate(-256 -256)")]),
    "rank_smith.svg": ("steel", [("lorc/anvil.svg", "")]),
    "rank_master.svg": ("silver", [("lorc/anvil.svg", "translate(256 490) scale(0.8) translate(-256 -443)"),
                                   ("delapouite/round-star.svg",
                                    "translate(256 126) scale(0.37) translate(-255.5 -255.5)")]),
    "rank_grandmaster.svg": ("gold", [("delapouite/jewel-crown.svg", "")]),
    "rank_legend.svg": ("starmetal", [("lorc/laurel-crown.svg", "")]),
}
RANK_FILL = "url(#metal)"

# Masterworks (shared/masterworks.md): one single-colour glyph per item in app/assets/masterworks/<id>.svg,
# cleaned exactly like the icons (fill #ffffff, transparent, square viewBox). The app tints them:
# blueprint-white while unfinished, a metal gradient once finished. Names and blurbs live in
# app/assets/masterworks/masterworks.json.
MASTERWORKS = {
    "horseshoe.svg": (GI, "delapouite/horseshoe.svg"),
    "bell.svg": (GI, "lorc/ringing-bell.svg"),
    "dagger.svg": (GI, "lorc/plain-dagger.svg"),
    "lantern.svg": (GI, "lorc/lantern-flame.svg"),
    "helm.svg": (GI, "lorc/visored-helm.svg"),
    "shield.svg": (GI, "lorc/bordered-shield.svg"),
    "axe.svg": (GI, "delapouite/sharp-axe.svg"),
    "crown.svg": (GI, "lorc/crown.svg"),
    "longsword.svg": (GI, "lorc/broadsword.svg"),
    "astrolabe.svg": (GI, "caro-asercion/astrolabe.svg"),
    "warhammer.svg": (GI, "delapouite/warhammer.svg"),
    "anvil.svg": (GI, "lorc/anvil.svg"),
}

LICENCE_NAMES = {
    "OFL-1.1": "SIL Open Font License 1.1",
    "Apache-2.0": "Apache License 2.0",
    "CC0 1.0": "CC0 1.0 (public domain)",
    "CC BY 3.0": "CC BY 3.0",
}
SYNTH_LICENCE = "original (synthesized by Wordsmith)"


# ------------------------------------------------------------------ helpers
def packs() -> dict:
    return {p["id"]: p for p in json.loads((ART / "sources.json").read_text())["packs"]}


def src_path(pack: str, rel: str) -> Path:
    p = THIRD_PARTY / pack / rel
    if not p.exists():
        sys.exit(f"missing {p}\nRun `python3 art/fetch.py` first.")
    return p


def file_meta(pack: dict, rel: str) -> dict:
    for f in pack["files"]:
        if f["name"] == rel:
            return f
    raise KeyError(f"{rel} not listed in sources.json pack {pack['id']}")


# ------------------------------------------------------------------ fonts
def export_fonts() -> None:
    out = ASSETS / "fonts"
    licences = ASSETS / "licenses"
    out.mkdir(parents=True, exist_ok=True)
    licences.mkdir(parents=True, exist_ok=True)
    for app_name, (pack, ttf, lic, app_lic) in FONTS.items():
        shutil.copyfile(src_path(pack, ttf), out / app_name)
        # Licence texts go to assets/licenses/, which the app bundles and
        # shows on its licences page.
        shutil.copyfile(src_path(pack, lic), licences / app_lic)
        print(f"fonts/{app_name:26} {(out / app_name).stat().st_size / 1024:7.1f} KiB  + licenses/{app_lic}")
    export_scowl_notice(licences)


def export_scowl_notice(licences: Path) -> None:
    """The puzzles contain SCOWL words, so the app shows SCOWL's notice too."""
    md = (ART.parent / "tools" / "puzzlegen" / "data" / "LICENSES.md").read_text()
    section = md.split("## SCOWL copyright notice", 1)[1]
    notice = section.split("```", 2)[1].strip("\n")
    (licences / "SCOWL.txt").write_text(notice + "\n")
    print("licenses/SCOWL.txt")


# ------------------------------------------------------------------ icons
def glyph_paths(src: Path) -> tuple[list[str], bool, list[float]]:
    """(glyph path data, background_was_removed, viewBox) of a game-icons / Material SVG."""
    root = ET.parse(src).getroot()
    vb = [float(v) for v in root.get("viewBox").split()]
    paths = []
    removed = False
    for el in root.iter(f"{{{SVG_NS}}}path"):
        d = el.get("d", "").strip()
        fill = el.get("fill")
        w, h = vb[2], vb[3]
        is_background = fill in (None, "#000", "#000000") and re.fullmatch(
            rf"M0 0h{w:g}v{h:g}H0[Vz0 ]*z?", d.replace(",", " "), flags=re.I)
        if is_background or fill == "none":
            removed = True
            continue
        paths.append(d)
    if not paths:
        raise ValueError(f"{src}: no glyph path left")
    return paths, removed, vb


def clean_svg(src: Path, credit: str) -> tuple[str, bool]:
    """Return (single-colour SVG, background_was_removed): every glyph path filled white."""
    paths, removed, vb = glyph_paths(src)
    body = "".join(f'<path fill="{ICON_FILL}" d="{d}"/>' for d in paths)
    if vb[1] != 0 or vb[0] != 0:  # Material Symbols use viewBox "0 -960 960 960"
        body = f'<g transform="translate({0 - vb[0] + 0:g} {0 - vb[1] + 0:g})">{body}</g>'
    view = f"0 0 {vb[2]:g} {vb[3]:g}"
    change = ("background removed, " if removed else "") + f"recoloured {ICON_FILL}"
    return (f'<svg xmlns="{SVG_NS}" viewBox="{view}">'
            f"<!-- {credit} Modified for Wordsmith: {change}. -->{body}</svg>\n"), removed


def rank_svg(metal: str, layers: list[tuple[str, str]]) -> tuple[str, str]:
    """(metal-gradient SVG, changes note) for a rank badge built from game-icons glyphs."""
    P = packs()
    light, base, dark = METALS[metal]
    credits, groups = [], []
    for rel, transform in layers:
        meta = file_meta(P[GI], rel)
        c = f'"{meta["title"]}" by {meta["author"]}, {meta["page"]}'
        if c not in credits:
            credits.append(c)
        paths, _, _ = glyph_paths(src_path(GI, rel))
        body = "".join(f'<path fill="{RANK_FILL}" d="{d}"/>' for d in paths)
        groups.append(f'<g transform="{transform}">{body}</g>' if transform else body)
    changes = f"background removed, filled with a metal gradient ({metal})"
    if len(layers) > 1:
        changes += (", two copies mirrored and scaled into a crossed pair" if len(credits) == 1
                    else ", glyphs scaled and combined")
    note = f"{'; '.join(credits)}; {P[GI]['licence']}. Modified for Wordsmith: {changes}."
    defs = (f'<defs><linearGradient id="metal" x1="0" y1="40" x2="0" y2="472" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{light}"/><stop offset="0.55" stop-color="{base}"/>'
            f'<stop offset="1" stop-color="{dark}"/></linearGradient></defs>')
    return (f'<svg xmlns="{SVG_NS}" viewBox="0 0 512 512"><!-- {note.replace("--", "-")} -->'
            f'{defs}{"".join(groups)}</svg>\n'), changes


def write_glyphs(table: dict, out: Path) -> None:
    """Clean each (pack, rel) source of `table` into a single-colour SVG in `out`."""
    out.mkdir(parents=True, exist_ok=True)
    P = packs()
    for app_name, (pack, rel) in table.items():
        meta = file_meta(P[pack], rel)
        credit = (f'"{meta.get("title", rel)}" by {meta.get("author", P[pack]["author"])}, '
                  f'{meta.get("page", P[pack]["page"])}, {P[pack]["licence"]}.')
        svg, _ = clean_svg(src_path(pack, rel), credit.replace("--", "-"))
        (out / app_name).write_text(svg)


def export_icons() -> None:
    out = ASSETS / "icons"
    write_glyphs(ICONS, out)
    for app_name, (metal, layers) in RANKS.items():
        (out / app_name).write_text(rank_svg(metal, layers)[0])
    print(f"icons: {len(ICONS)} SVGs + {len(RANKS)} rank badges written to {out.relative_to(ROOT)}")
    validate_icons(out)
    mw = ASSETS / "masterworks"
    write_glyphs(MASTERWORKS, mw)
    print(f"masterworks: {len(MASTERWORKS)} SVGs written to {mw.relative_to(ROOT)}")
    validate_icons(mw, MASTERWORKS)


def validate_icons(out: Path, table: dict | None = None) -> None:
    """Check the files this script writes (other SVGs in the folder, e.g. google_g.svg, are left alone)."""
    names = list(table) if table is not None else [*ICONS, *RANKS]
    for name in names:
        f = out / name
        root = ET.parse(f).getroot()
        paths = list(root.iter(f"{{{SVG_NS}}}path"))
        fills = {p.get("fill") for p in paths}
        rank = table is None and name in RANKS
        want = RANK_FILL if rank else ICON_FILL
        assert root.tag == f"{{{SVG_NS}}}svg" and root.get("viewBox"), f
        vb = root.get("viewBox").split()
        assert vb[2] == vb[3], f"{f}: viewBox {vb} is not square"
        assert paths and fills == {want}, f"{f}: paths={len(paths)} fills={fills}"
        assert not list(root.iter(f"{{{SVG_NS}}}rect")), f"{f}: has a rect"
        if rank:
            assert len(list(root.iter(f"{{{SVG_NS}}}linearGradient"))) == 1, f"{f}: no metal gradient"
    if table is not None:
        print(f"{out.name}: {len(names)} SVGs validated (XML, square viewBox, >=1 path, single fill {ICON_FILL})")
        return
    print(f"icons: {len(ICONS)} SVGs validated (XML, square viewBox, >=1 path, single fill {ICON_FILL}), "
          f"{len(RANKS)} rank badges (fill {RANK_FILL} + gradient)")


# ------------------------------------------------------------------ audio
def export_audio() -> None:
    r = subprocess.run([sys.executable, str(ART / "audio" / "build_audio.py")])
    if r.returncode:
        sys.exit("audio build failed")


# ------------------------------------------------------------------ credits
def credit_rows() -> list[dict]:
    P = packs()
    rows = []
    for app_name, (pack, ttf, lic, app_lic) in FONTS.items():
        p = P[pack]
        rows.append(dict(file=f"fonts/{app_name}", title=p["title"], author=p["author"],
                         licence=LICENCE_NAMES[p["licence"]], url=p["page"], licence_url=p["licence_url"],
                         source=file_meta(p, ttf)["url"], changes="Renamed file; licence shipped alongside as " + app_lic,
                         retrieved=p["retrieved"]))
    def glyph_rows(folder: str, table: dict) -> None:
        for app_name, (pack, rel) in table.items():
            p, m = P[pack], file_meta(P[pack], rel)
            rows.append(dict(file=f"{folder}/{app_name}", title=m.get("title", rel),
                             author=m.get("author", p["author"]), licence=LICENCE_NAMES[p["licence"]],
                             url=m.get("page", p["page"]), licence_url=p["licence_url"],
                             source=m["url"], retrieved=p["retrieved"],
                             changes=("Background removed, recoloured " if clean_svg(src_path(pack, rel), "")[1]
                                      else "Recoloured ") + ICON_FILL))

    glyph_rows("icons", ICONS)
    for app_name, (metal, layers) in RANKS.items():
        changes = rank_svg(metal, layers)[1]
        for rel in dict.fromkeys(rel for rel, _ in layers):
            p, m = P[GI], file_meta(P[GI], rel)
            rows.append(dict(file=f"icons/{app_name}", title=m["title"], author=m["author"],
                             licence=LICENCE_NAMES[p["licence"]], url=m["page"], licence_url=p["licence_url"],
                             source=m["url"], retrieved=p["retrieved"], changes=changes[0].upper() + changes[1:]))
    glyph_rows("masterworks", MASTERWORKS)
    # Other outputs (e.g. Blender renders built from CC0 textures) can be credited by adding
    # "used_by": [{"file": "images/x.webp", "changes": "..."}] to their pack in sources.json.
    for p in P.values():
        for u in p.get("used_by", []):
            rows.append(dict(file=u["file"], title=u.get("title", p["title"]), author=p["author"],
                             licence=LICENCE_NAMES.get(p["licence"], p["licence"]), url=p["page"],
                             licence_url=p["licence_url"], source=p["files"][0]["url"],
                             changes=u.get("changes", ""), retrieved=p["retrieved"]))
    # Textures (and the icon font) baked into the Blender renders: art/blender/sources.json.
    blender = json.loads((ART / "blender" / "sources.json").read_text())
    for a in blender["assets"]:
        rows.append(dict(file="images/ (3D renders)", title=Path(a.get("unzip_to", a["file"])).name,
                         author=a["author"], licence=a["licence"], url=a.get("page", a["url"]),
                         licence_url=a.get("licence_url", ""), source=a["url"],
                         changes="Baked into renders: " + a.get("used_for", ""),
                         retrieved=blender.get("retrieved", "")))
    if not AUDIO_MANIFEST.exists():
        sys.exit("art/audio/manifest.json missing - run `python3 art/export.py audio` first")
    for name, a in json.loads(AUDIO_MANIFEST.read_text()).items():
        for s in a["sources"]:
            p = P[s["pack"]]
            short = s["file"].split("/")[-1]
            rows.append(dict(file=a["file"], title=f"{short} ({p['title']})", author=p["author"],
                             licence=LICENCE_NAMES[p["licence"]], url=p["page"], licence_url=p["licence_url"],
                             source=next(f["url"] for f in p["files"] if f.get("extract") or f["name"] == s["file"]),
                             changes="Edited, layered and loudness-normalised (art/audio/build_audio.py)",
                             retrieved=p["retrieved"]))
        if a["synthesized"]:
            rows.append(dict(file=a["file"], title=a["description"], author="Wordsmith",
                             licence=SYNTH_LICENCE, url="", licence_url="", source="art/audio/build_audio.py",
                             changes="", retrieved=""))
    return rows


def md_escape(s: str) -> str:
    return s.replace("|", "\\|")


def write_credits() -> None:
    rows = credit_rows()
    P = packs()
    credits_json = json.dumps(
        [dict(file=r["file"], title=r["title"], author=r["author"], licence=r["licence"], url=r["url"],
              licence_url=r["licence_url"], changes=r["changes"]) for r in rows], indent=2) + "\n"
    (ART / "credits.json").write_text(credits_json)
    # The app's Credits screen reads its own copy.
    (ART.parent / "app" / "assets" / "credits.json").write_text(credits_json)

    used_packs = {}
    for app_name, (pack, *_rest) in FONTS.items():
        used_packs.setdefault(pack, set()).add(f"fonts/{app_name}")
    for app_name, (pack, _rel) in ICONS.items():
        used_packs.setdefault(pack, set()).add(f"icons/{app_name}")
    for app_name in RANKS:
        used_packs.setdefault(GI, set()).add(f"icons/{app_name}")
    for app_name, (pack, _rel) in MASTERWORKS.items():
        used_packs.setdefault(pack, set()).add(f"masterworks/{app_name}")
    # Everyone whose game-icons.net work we ship, in order of first use.
    gi_authors = list(dict.fromkeys(r["author"] for r in rows
                                    if r["url"].startswith("https://game-icons.net/")))
    gi_credit = ", ".join(gi_authors[:-1]) + " and " + gi_authors[-1]
    ms_used = [t for t, (pack, _rel) in ICONS.items() if pack == "material-symbols"]
    audio = json.loads(AUDIO_MANIFEST.read_text())
    for a in audio.values():
        for s in a["sources"]:
            used_packs.setdefault(s["pack"], set()).add(a["file"])
    for pid, p in P.items():
        for u in p.get("used_by", []):
            used_packs.setdefault(pid, set()).add(u["file"])

    L = ["# Wordsmith asset credits", "",
         "Every third-party file bundled in `app/assets/` (fonts, icons, masterworks, audio), where it came from and",
         "its licence.",
         "Generated by `python3 art/export.py credits` from `art/sources.json`, the tables in `art/export.py` and",
         "`art/audio/manifest.json`; the same data is in `art/credits.json` for the in-app Credits screen.",
         "Do not edit by hand. Licence texts are saved by `art/fetch.py` under `art/third_party/<pack>/LICENSE`",
         "(fonts also ship their licence next to the font in `app/assets/fonts/`).", "",
         "Allowed licences (docs/ART_AND_AUDIO.md section 7): CC0, CC BY 3.0/4.0 (credited), OFL / Apache 2.0 for fonts",
         "and icons. Nothing here is CC BY-SA, NC, ND, GPL or taken from another game.", "",
         "## Attribution required in the app", "",
         "- **Icons and Masterworks:** game-icons.net icons are CC BY 3.0. Credit line: *Icons made by",
         f"  {gi_credit}, from game-icons.net, licensed under CC BY 3.0",
         "  (https://creativecommons.org/licenses/by/3.0/).* All were modified (background removed, recoloured).",
         "- **Fonts:** Cinzel, Nunito Sans, Vollkorn SC, Arvo, Atkinson Hyperlegible Next and Texturina (SIL OFL 1.1),",
         "  Roboto Slab (Apache 2.0): ship the licence files; a credits mention is good practice.",
         f"- **Material Symbols** ({', '.join(f'`{n}`' for n in ms_used)}): Apache 2.0, Google.",
         "- **Audio:** Kenney and OpenGameArt sources are CC0 (no attribution required; credited anyway).", "",
         "## Source packs", "",
         "| Pack | Author | Licence | Page | Retrieved | Used by |", "|---|---|---|---|---|---|"]
    for pid, files in used_packs.items():
        p = P[pid]
        L.append(f"| {md_escape(p['title'])} | {md_escape(p['author'])} | [{p['licence']}]({p['licence_url']}) | "
                 f"{p['page']} | {p['retrieved']} | {len(files)} file(s) |")
    L += ["", "Pinned download URLs and SHA-256 checksums are in `art/sources.json`.", "",
          "## Fonts (`app/assets/fonts/`)", "",
          "| File | Font | Author | Licence | Source | Notes |", "|---|---|---|---|---|---|"]
    for r in rows:
        if r["file"].startswith("fonts/"):
            L.append(f"| `{r['file']}` | {r['title']} | {md_escape(r['author'])} | {r['licence']} | {r['source']} | "
                     f"{FONT_USE[r['file'].split('/')[1]]} |")
    L += ["", "## Icons (`app/assets/icons/`)", "",
          "Single-colour SVGs (fill `#ffffff`, transparent background) for tinting in the app; the `rank_*`",
          "badges instead carry a metal gradient (bronze, iron, steel, silver, gold, starmetal) and are drawn untinted.", "",
          "| File | Icon | Author | Licence | Source page |", "|---|---|---|---|---|"]
    for r in rows:
        if r["file"].startswith("icons/"):
            L.append(f"| `{r['file']}` | {r['title']} | {r['author']} | {r['licence']} | {r['url']} |")
    L += ["", "## Masterworks (`app/assets/masterworks/`)", "",
          "One single-colour glyph per Masterwork (fill `#ffffff`, transparent background, square viewBox), tinted by",
          "the app. Names and blurbs (`masterworks.json`) are our own writing.", "",
          "| File | Icon | Author | Licence | Source page |", "|---|---|---|---|---|"]
    for r in rows:
        if r["file"].startswith("masterworks/"):
            L.append(f"| `{r['file']}` | {r['title']} | {r['author']} | {r['licence']} | {r['url']} |")
    L += ["", "## Audio (`app/assets/audio/`)", "",
          "Built by `art/audio/build_audio.py`. Rows marked *original* are synthesized by our own code",
          "(modal synthesis of struck metal, filtered noise); third-party rows list each source clip used.", "",
          "| File | Built from | Author | Licence | Source |", "|---|---|---|---|---|"]
    for r in rows:
        if r["file"].startswith("audio/"):
            src = r["url"] or f"`{r['source']}`"
            L.append(f"| `{r['file']}` | {md_escape(r['title'])} | {md_escape(r['author'])} | {r['licence']} | {src} |")
    other = [r for r in rows if not r["file"].startswith(("fonts/", "icons/", "masterworks/", "audio/"))]
    if other:
        L += ["", "## Other assets", "", "| File | Built from | Author | Licence | Source |", "|---|---|---|---|---|"]
        L += [f"| `{r['file']}` | {md_escape(r['title'])} | {md_escape(r['author'])} | {r['licence']} | {r['url']} |"
              for r in other]
    L += ["", "## Audio file details", "",
          "| File | Duration | Channels | Loudness | True peak | Size |", "|---|---|---|---|---|---|"]
    for a in audio.values():
        loud = (f"{a['lufs_integrated']} LUFS integrated" if a["loudness_metric"] == "integrated"
                else f"{a['lufs_momentary_max']} LUFS-M max")
        L.append(f"| `{a['file']}` | {a['duration_s']:.2f} s | {'stereo' if a['channels'] == 2 else 'mono'} | "
                 f"{loud} | {a['true_peak_dbtp']} dBTP | {a['bytes'] / 1024:.1f} KiB |")
    (ART / "CREDITS.md").write_text("\n".join(L) + "\n")
    print(f"credits: {len(rows)} rows -> art/CREDITS.md, art/credits.json")


def main() -> int:
    steps = {"fonts": export_fonts, "icons": export_icons, "audio": export_audio, "credits": write_credits}
    args = sys.argv[1:] or ["all"]
    if args == ["all"]:
        args = list(steps)
    bad = [a for a in args if a not in steps]
    if bad:
        print(__doc__)
        return 2
    for a in args:
        steps[a]()
    return 0


if __name__ == "__main__":
    sys.exit(main())
