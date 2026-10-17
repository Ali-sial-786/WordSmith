#!/usr/bin/env python3
"""Export optimised assets from art/third_party into app/assets, and build the credits.

    python3 art/fetch.py              # 1. download + verify third-party sources
    python3 art/export.py all         # 2. fonts + icons + audio + credits
    python3 art/export.py icons       #    ...or one step: fonts | icons | audio | credits

Steps:
  fonts    copy the variable TTFs and their licence texts to app/assets/fonts/
  icons    clean game-icons.net / Material Symbols SVGs into single-colour glyphs
           (background removed, fill #ffffff, so the app can tint them) in app/assets/icons/
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
}
FONT_USE = {
    "Cinzel-Variable.ttf": "Titles and banners. Variable axis wght 400-900.",
    "RobotoSlab-Variable.ttf": "Letter tiles and grid letters. Variable axis wght 100-900 (use 700-900).",
    "NunitoSans-Variable.ttf": "UI text. Variable axes wght 200-1000, wdth 75-125, opsz 6-12, YTLC 440-540.",
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
}
AVATARS = [  # avatar_01.svg ... avatar_16.svg
    "delapouite/thor-hammer.svg", "lorc/anvil-impact.svg", "delapouite/blacksmith.svg", "lorc/fluffy-flame.svg",
    "kier-heyl/dwarf-helmet.svg", "lorc/checked-shield.svg", "lorc/battle-axe.svg", "lorc/sword-smithing.svg",
    "delapouite/horseshoe.svg", "lorc/gears.svg", "delapouite/imperial-crown.svg", "lorc/dragon-head.svg",
    "lorc/wolf-head.svg", "delapouite/bear-head.svg", "lorc/owl.svg", "lorc/mountains.svg",
]
for _i, _src in enumerate(AVATARS, 1):
    ICONS[f"avatar_{_i:02d}.svg"] = (GI, _src)

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
    out.mkdir(parents=True, exist_ok=True)
    for app_name, (pack, ttf, lic, app_lic) in FONTS.items():
        shutil.copyfile(src_path(pack, ttf), out / app_name)
        shutil.copyfile(src_path(pack, lic), out / app_lic)
        print(f"fonts/{app_name:26} {(out / app_name).stat().st_size / 1024:7.1f} KiB  + {app_lic}")


# ------------------------------------------------------------------ icons
def clean_svg(src: Path, credit: str) -> tuple[str, bool]:
    """Return (single-colour SVG, background_was_removed): every glyph path filled white."""
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
    body = "".join(f'<path fill="{ICON_FILL}" d="{d}"/>' for d in paths)
    if vb[1] != 0 or vb[0] != 0:  # Material Symbols use viewBox "0 -960 960 960"
        body = f'<g transform="translate({0 - vb[0] + 0:g} {0 - vb[1] + 0:g})">{body}</g>'
    view = f"0 0 {vb[2]:g} {vb[3]:g}"
    change = ("background removed, " if removed else "") + f"recoloured {ICON_FILL}"
    return (f'<svg xmlns="{SVG_NS}" viewBox="{view}">'
            f"<!-- {credit} Modified for Wordsmith: {change}. -->{body}</svg>\n"), removed


def export_icons() -> None:
    out = ASSETS / "icons"
    out.mkdir(parents=True, exist_ok=True)
    P = packs()
    for app_name, (pack, rel) in ICONS.items():
        meta = file_meta(P[pack], rel)
        credit = (f'"{meta.get("title", rel)}" by {meta.get("author", P[pack]["author"])}, '
                  f'{meta.get("page", P[pack]["page"])}, {P[pack]["licence"]}.')
        svg, _ = clean_svg(src_path(pack, rel), credit.replace("--", "-"))
        (out / app_name).write_text(svg)
    print(f"icons: {len(ICONS)} SVGs written to {out.relative_to(ROOT)}")
    validate_icons(out)


def validate_icons(out: Path) -> None:
    for f in sorted(out.glob("*.svg")):
        root = ET.parse(f).getroot()
        paths = list(root.iter(f"{{{SVG_NS}}}path"))
        fills = {p.get("fill") for p in paths}
        assert root.tag == f"{{{SVG_NS}}}svg" and root.get("viewBox"), f
        assert paths and fills == {ICON_FILL}, f"{f}: paths={len(paths)} fills={fills}"
        assert not list(root.iter(f"{{{SVG_NS}}}rect")), f"{f}: has a rect"
    print(f"icons: {len(list(out.glob('*.svg')))} SVGs validated (XML, >=1 path, single fill {ICON_FILL})")


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
    for app_name, (pack, rel) in ICONS.items():
        p, m = P[pack], file_meta(P[pack], rel)
        rows.append(dict(file=f"icons/{app_name}", title=m.get("title", rel), author=m.get("author", p["author"]),
                         licence=LICENCE_NAMES[p["licence"]], url=m.get("page", p["page"]), licence_url=p["licence_url"],
                         source=m["url"], retrieved=p["retrieved"],
                         changes=("Background removed, recoloured " if clean_svg(src_path(pack, rel), "")[1]
                                  else "Recoloured ") + ICON_FILL))
    # Other outputs (e.g. Blender renders built from CC0 textures) can be credited by adding
    # "used_by": [{"file": "images/x.webp", "changes": "..."}] to their pack in sources.json.
    for p in P.values():
        for u in p.get("used_by", []):
            rows.append(dict(file=u["file"], title=u.get("title", p["title"]), author=p["author"],
                             licence=LICENCE_NAMES.get(p["licence"], p["licence"]), url=p["page"],
                             licence_url=p["licence_url"], source=p["files"][0]["url"],
                             changes=u.get("changes", ""), retrieved=p["retrieved"]))
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
    audio = json.loads(AUDIO_MANIFEST.read_text())
    for a in audio.values():
        for s in a["sources"]:
            used_packs.setdefault(s["pack"], set()).add(a["file"])
    for pid, p in P.items():
        for u in p.get("used_by", []):
            used_packs.setdefault(pid, set()).add(u["file"])

    L = ["# Wordsmith asset credits", "",
         "Every third-party file bundled in `app/assets/` (fonts, icons, audio), where it came from and its licence.",
         "Generated by `python3 art/export.py credits` from `art/sources.json`, the tables in `art/export.py` and",
         "`art/audio/manifest.json`; the same data is in `art/credits.json` for the in-app Credits screen.",
         "Do not edit by hand. Licence texts are saved by `art/fetch.py` under `art/third_party/<pack>/LICENSE`",
         "(fonts also ship their licence next to the font in `app/assets/fonts/`).", "",
         "Allowed licences (docs/ART_AND_AUDIO.md section 7): CC0, CC BY 3.0/4.0 (credited), OFL / Apache 2.0 for fonts",
         "and icons. Nothing here is CC BY-SA, NC, ND, GPL or taken from another game.", "",
         "## Attribution required in the app", "",
         "- **Icons:** game-icons.net icons are CC BY 3.0. Credit line: *Icons made by Lorc, Delapouite, Carl Olsen and",
         "  Kier Heyl, from game-icons.net, licensed under CC BY 3.0 (https://creativecommons.org/licenses/by/3.0/).*",
         "  All were modified (background removed, recoloured).",
         "- **Fonts:** Cinzel and Nunito Sans (SIL OFL 1.1), Roboto Slab (Apache 2.0): ship the licence files; a credits",
         "  mention is good practice.",
         "- **Material Symbols** (back arrow): Apache 2.0, Google.",
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
          "All single-colour SVGs (fill `#ffffff`, transparent background) for tinting in the app.", "",
          "| File | Icon | Author | Licence | Source page |", "|---|---|---|---|---|"]
    for r in rows:
        if r["file"].startswith("icons/"):
            L.append(f"| `{r['file']}` | {r['title']} | {r['author']} | {r['licence']} | {r['url']} |")
    L += ["", "## Audio (`app/assets/audio/`)", "",
          "Built by `art/audio/build_audio.py`. Rows marked *original* are synthesized by our own code",
          "(modal synthesis of struck metal, filtered noise); third-party rows list each source clip used.", "",
          "| File | Built from | Author | Licence | Source |", "|---|---|---|---|---|"]
    for r in rows:
        if r["file"].startswith("audio/"):
            src = r["url"] or f"`{r['source']}`"
            L.append(f"| `{r['file']}` | {md_escape(r['title'])} | {md_escape(r['author'])} | {r['licence']} | {src} |")
    other = [r for r in rows if not r["file"].startswith(("fonts/", "icons/", "audio/"))]
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
