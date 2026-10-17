#!/usr/bin/env python3
"""Build every Wordsmith sound effect into app/assets/audio/ (reproducible).

Inputs:  CC0 packs downloaded by `python3 art/fetch.py` (art/third_party/...)
         + sounds synthesised here (see synth.py).
Output:  app/assets/audio/<name>.ogg  - Ogg Vorbis, 44.1 kHz, mono for SFX
         (the forge ambience loop is stereo), high-passed at 80 Hz, trimmed,
         faded out, loudness normalised (EBU R128: max momentary loudness for
         one-shots, integrated for the loop) and true-peak limited to <= -1 dBTP.
         art/audio/manifest.json - per-file sources, loudness and peak (used
         by art/export.py to build the credits).

Usage:   python3 art/audio/build_audio.py            # build everything
         python3 art/audio/build_audio.py tink_1 clang   # just these
         python3 art/audio/build_audio.py --list

Needs ffmpeg (with libvorbis) on PATH and numpy.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth as S  # noqa: E402
from synth import level, place, undb  # noqa: E402

ART = Path(__file__).resolve().parents[1]
THIRD_PARTY = ART / "third_party"
OUT_DIR = ART.parent / "app" / "assets" / "audio"
MANIFEST = Path(__file__).resolve().parent / "manifest.json"

TP_CEILING = -1.0       # final true-peak limit (dBTP), checked on the decoded OGG
TP_PRE = -1.6           # pre-encode ceiling (Vorbis adds a little overshoot)
MAX_LIMITING_DB = 4.0   # above this, turn the whole sound down instead of squashing it
SFX_HIGHPASS_HZ = 80    # phone speakers can't play below this; it only eats headroom

KI = "kenney-impact-sounds"
KF = "kenney-interface-sounds"
KR = "kenney-rpg-audio"
OGA_FIRE = "oga-fireplace-loop"
OGA_FEAST = "oga-kings-feast"
OGA_MINSTREL = "oga-minstrel-dance"


@dataclass
class Recipe:
    name: str
    build: Callable[[], np.ndarray]
    lufs: float                     # loudness target, see `metric`
    desc: str
    channels: int = 1
    quality: float = 4              # libvorbis -q:a
    release: float = 0.03           # limiter release (s); short = only shave transients
    max_limit: float = MAX_LIMITING_DB
    metric: str = "mmax"            # "mmax" = max momentary LUFS (one-shots), "lufs" = integrated (loops)
    sources: list = field(default_factory=list)   # filled while building: (pack, file)
    synth: bool = False             # contains synthesised layers


RECIPES: dict[str, Recipe] = {}
_current: Recipe | None = None


def recipe(name: str, lufs: float, desc: str, synth: bool = False, **kw):
    def deco(fn):
        RECIPES[name] = Recipe(name, fn, lufs, desc, synth=synth, **kw)
        return fn
    return deco


def K(pack: str, rel: str, channels: int = 1, trim_db: float = -40) -> np.ndarray:
    """Load a third-party source (and record it for the credits)."""
    path = THIRD_PARTY / pack / rel
    if not path.exists():
        sys.exit(f"missing {path}\nRun `python3 art/fetch.py` first.")
    if _current is not None and (pack, rel) not in _current.sources:
        _current.sources.append((pack, rel))
    x = S.load(str(path), channels=channels)
    if channels == 1:
        x = S.normalize_peak(S.trim(x, start_db=trim_db, end_db=-70))
    return x


# ------------------------------------------------------------------ tile tinks
# G major pentatonic, G5 -> B6: each tile in a word is one step higher.
TINK_NOTES = [("G5", 783.99), ("A5", 880.00), ("B5", 987.77), ("D6", 1174.66),
              ("E6", 1318.51), ("G6", 1567.98), ("A6", 1760.00), ("B6", 1975.53)]

for _i, (_note, _f) in enumerate(TINK_NOTES, 1):
    recipe(f"tink_{_i}", -21, f"Tile touch tink #{_i} ({_note}, {_f:.0f} Hz): struck steel bar", synth=True)(
        lambda f=_f: level(S.tink(f, dur=0.22)))


# ------------------------------------------------------------------ word results
@recipe("clang", -14, "Valid word: anvil clang + short sizzle", synth=True)
def clang():
    x = level(S.anvil(700, 0.95, decay=0.9, bright=1.0, thump_gain=0.45, seed=21))
    x = place(x, level(S.fft_filter(K(KI, "Audio/impactMetal_heavy_001.ogg"), lo=150)), 0.0, undb(-3))
    x = place(x, level(S.sizzle(0.75, seed=22, attack=0.05, tau=0.22)), 0.06, undb(-9))
    return S.fit(x, 0.95, fade_out=0.25)


@recipe("clang_light", -17.5, "Teammate claimed a word: lighter, higher clang (a fourth up, no sizzle)", synth=True)
def clang_light():
    x = level(S.anvil(700 * 4 / 3, 0.6, decay=0.55, bright=1.15, thump_gain=0.0, seed=71))
    x = place(x, level(S.fft_filter(K(KI, "Audio/impactMetal_light_000.ogg"), lo=300)), 0.0, undb(-6))
    return S.fit(x, 0.6, fade_out=0.2)


@recipe("bonus", -16.5, "Bonus word: scrap metal clinking into a bucket", release=0.015, max_limit=6)
def bonus():
    x = S.silence(0.85)
    x = place(x, level(S.resample_pitch(K(KI, "Audio/impactMetal_light_004.ogg"), 1.12)), 0.0, undb(-3))
    x = place(x, level(K(KI, "Audio/impactTin_medium_003.ogg")), 0.075, undb(-1))
    x = place(x, level(S.fft_filter(K(KR, "Audio/metalPot2.ogg"), hi=8000)), 0.09, undb(-5))
    x = place(x, level(S.resample_pitch(K(KI, "Audio/impactMetal_light_001.ogg"), 1.25)), 0.19, undb(-10))
    return S.fit(x, 0.85, fade_out=0.25)


@recipe("already", -26, "Word already found: soft, dull tap")
def already():
    x = level(S.fft_filter(K(KI, "Audio/impactGeneric_light_001.ogg"), hi=2200, order=2))
    return S.fit(x, 0.16, fade_out=0.06)


@recipe("invalid", -21, "Not a word: dull 'cold metal' thunk", synth=True)
def invalid():
    hit = level(S.fft_filter(S.resample_pitch(K(KI, "Audio/impactPlate_heavy_001.ogg"), 0.9), hi=2200, order=2))
    body = S.modal((196, 412, 655, 1010), (1.0, 0.6, 0.35, 0.2), (0.07, 0.05, 0.035, 0.02), 0.35, seed=12)
    x = place(hit, level(body), 0.0, undb(-3))
    return S.fit(S.fft_filter(x, lo=120), 0.35, fade_out=0.12)


# ------------------------------------------------------------------ hints
@recipe("hint_hammer", -17, "Hammer Strike hint: heavy hammer blow with a short ring", synth=True)
def hint_hammer():
    x = level(K(KI, "Audio/impactMining_000.ogg"))
    x = place(x, level(S.anvil(560, 0.6, decay=0.4, bright=0.9, thump_gain=0.0, seed=81)), 0.0, undb(-8))
    return S.fit(x, 0.6, fade_out=0.18)


@recipe("hint_chisel", -19, "Chisel hint: sharp, bright metal tap", synth=True)
def hint_chisel():
    x = level(K(KI, "Audio/impactMetal_light_002.ogg"))
    x = place(x, level(S.tink(3200, dur=0.2)), 0.0, undb(-10))
    return S.fit(S.fft_filter(x, lo=400), 0.3, fade_out=0.1)


@recipe("hint_sparks", -17, "Spark Shower hint: crackling, fizzing sparks", synth=True)
def hint_sparks():
    x = level(S.sparkles(0.85, 55, seed=91, decay=0.25))
    x = place(x, level(S.sizzle(0.85, seed=92, attack=0.01, tau=0.18)), 0.0, undb(-8))
    x = place(x, level(S.crackle(0.7, 120, seed=93, lo=2500)), 0.0, undb(-6))
    return S.fit(x, 0.85, fade_out=0.2)


# ------------------------------------------------------------------ pickups & big moments
@recipe("pickup", -17, "Pickup collected: ember whoosh + small chime", synth=True)
def pickup():
    x = S.silence(0.75)
    x = place(x, level(S.whoosh(0.38, 350, 2600, seed=61, q=0.9, peak_at=0.6)), 0.0)
    x = place(x, level(S.crackle(0.35, 40, seed=62)), 0.02, undb(-14))
    x = place(x, level(S.bell(2093.0, 0.5, tau=0.22, seed=63)), 0.20, undb(-2))
    x = place(x, level(S.bell(3135.96, 0.45, tau=0.18, seed=64)), 0.27, undb(-7))
    return S.fit(x, 0.75, fade_out=0.2)


@recipe("forged", -12, "Puzzle complete ('Forged!'): big anvil hit + quench hiss + spark whoosh", synth=True,
        release=0.02, max_limit=5)
def forged():
    x = S.silence(2.4)
    x = place(x, level(S.anvil(520, 2.0, decay=1.7, bright=0.9, thump_gain=0.8, seed=31)), 0.0)
    x = place(x, level(S.resample_pitch(K(KI, "Audio/impactMetal_heavy_001.ogg"), 0.85)), 0.0, undb(-3))
    x = place(x, level(K(KI, "Audio/impactBell_heavy_002.ogg")), 0.0, undb(-9))
    x = place(x, level(S.whoosh(1.0, 900, 5500, seed=32, q=1.0, peak_at=0.35)), 0.08, undb(-12))
    x = place(x, level(S.sparkles(1.4, 45, seed=33)), 0.05, undb(-10))
    x = place(x, level(S.quench(1.9, seed=34)), 0.38, undb(-5))
    return S.fit(x, 2.4, fade_out=0.45)


@recipe("levelup", -13, "Level up / rank up: rising bell arpeggio into a bell + anvil chord", synth=True)
def levelup():
    x = S.silence(1.7)
    for k, (at, f) in enumerate([(0.00, 523.25), (0.10, 659.26), (0.20, 783.99)]):
        x = place(x, level(S.bell(f, 0.9, tau=0.5, seed=40 + k)), at, undb(-4))
    chord_at = 0.32
    for k, (f, g) in enumerate([(523.25, -8), (659.26, -8), (783.99, -7), (1046.50, -3)]):
        x = place(x, level(S.bell(f, 1.35, tau=0.9, seed=44 + k)), chord_at, undb(g))
    x = place(x, level(S.anvil(1046.5 / 2.09, 1.3, decay=1.1, bright=1.2, thump_gain=0.3, seed=48)), chord_at, undb(-7))
    x = place(x, level(S.sparkles(1.0, 25, seed=49, f_range=(4000, 10000))), chord_at + 0.02, undb(-16))
    return S.fit(x, 1.7, fade_out=0.4)


# ------------------------------------------------------------------ UI & timing
@recipe("shuffle", -19, "Shuffle: letter tiles flipping over in quick succession, metallic rattle",
        release=0.012, max_limit=6)
def shuffle():
    rng = np.random.default_rng(5)
    x = S.silence(0.7)
    clinks = ["impactMetal_light_000", "impactMetal_light_002", "impactTin_medium_001", "impactMetal_light_003",
              "impactMetal_light_004", "impactTin_medium_004", "impactMetal_light_001"]
    at = 0.0
    for k, name in enumerate(clinks):
        c = S.resample_pitch(K(KI, f"Audio/{name}.ogg"), rng.uniform(1.25, 1.7))  # small, light pieces
        c = S.fit(c, 0.09, fade_out=0.05)
        x = place(x, level(c), at, undb(-2 - 1.2 * k + rng.uniform(-1.5, 1.5)))
        at += rng.uniform(0.04, 0.06)
    x = place(x, level(S.fft_filter(K(KR, "Audio/handleCoins.ogg"), lo=600, hi=11000)), 0.03, undb(-9))
    x = place(x, level(S.whoosh(0.4, 1800, 5000, seed=6, q=0.8, peak_at=0.4)), 0.0, undb(-16))
    return S.fit(x, 0.6, fade_out=0.2)


@recipe("tap", -25, "Generic UI button tap", release=0.01, max_limit=5)
def tap():
    return S.fit(level(K(KF, "Audio/select_001.ogg")), 0.06, fade_out=0.02)


@recipe("countdown", -20, "Multiplayer countdown beat: bellows puff + tick", synth=True, release=0.015)
def countdown():
    x = level(S.puff(0.32, seed=101))
    x = place(x, level(K(KF, "Audio/tick_002.ogg")), 0.0, undb(-10))
    return S.fit(x, 0.32, fade_out=0.1)


@recipe("go", -16, "Multiplayer 'go': bright anvil-bell ding", synth=True)
def go():
    x = level(S.bell(1318.51, 1.0, tau=0.55, seed=51))
    x = place(x, level(S.bell(659.26, 1.0, tau=0.6, seed=52)), 0.0, undb(-9))
    x = place(x, level(S.tink(2637.0, dur=0.2)), 0.0, undb(-10))
    return S.fit(x, 1.0, fade_out=0.35)


@recipe("tick", -22, "Last 10 seconds: hammer 'heartbeat' tick", synth=True, release=0.012, max_limit=6)
def tick():
    x = level(S.fft_filter(S.resample_pitch(K(KI, "Audio/impactMetal_medium_002.ogg"), 0.9), hi=3500))
    x = place(x, level(S.thump(0.15, 140, 80, 0.03)), 0.0, undb(-6))
    return S.fit(x, 0.17, fade_out=0.06)


# ------------------------------------------------------------------ ambience
@recipe("forge_ambience", -30, "Forge fire crackle, seamless ~27 s stereo loop with one faint bellows breath",
        synth=True, channels=2, quality=3, metric="lufs")
def forge_ambience():
    x = K(OGA_FIRE, "fire.wav", channels=2)
    x = np.stack([S.fft_filter(x[:, c], lo=45) for c in range(2)], axis=1)
    # seamless loop: cross-fade the last 2 s into the first 2 s (equal power)
    n = S.n_samples(2.0)
    u = np.linspace(0, 1, n)[:, None]
    y = x[: len(x) - n].copy()
    y[:n] = x[len(x) - n:] * np.cos(0.5 * np.pi * u) + x[:n] * np.sin(0.5 * np.pi * u)
    # one faint bellows breath in the middle (never crosses the loop point)
    ref = np.sqrt(np.mean(y ** 2))
    b = S.whoosh(1.6, 180, 700, seed=111, q=0.7, peak_at=0.45)
    b = b / np.sqrt(np.mean(b[b != 0] ** 2)) * ref * undb(-9)
    at = S.n_samples(13.0)
    y[at:at + len(b), 0] += b
    y[at:at + len(b), 1] += np.roll(b, 40)  # tiny inter-channel delay = width
    return y


# ------------------------------------------------------------------ multiplayer results
def glide(x: np.ndarray, cents: float, start: float = 0.0) -> np.ndarray:
    """Bend the pitch smoothly by `cents` (negative = down) from `start` s to the end."""
    n = len(x)
    u = np.clip((np.arange(n) / S.SR - start) / max(n / S.SR - start, 1e-6), 0, 1)
    ratio = 2 ** (cents * (0.5 - 0.5 * np.cos(np.pi * u)) / 1200)
    pos = np.cumsum(ratio) - ratio[0]
    pos = pos[pos < n - 1]
    return np.interp(pos, np.arange(n), x)


@recipe("round_win", -13, "Round won: bright 'ta-da' sting, a two-bell pickup into a G major bell chord over an anvil ring",
        synth=True)
def round_win():
    x = S.silence(1.5)
    x = place(x, level(S.bell(587.33, 0.3, tau=0.22, seed=201, strike=0.2)), 0.0, undb(-5))
    x = place(x, level(S.bell(783.99, 0.3, tau=0.22, seed=202, strike=0.2)), 0.09, undb(-4))
    at = 0.19
    for k, (f, g) in enumerate([(392.00, -9), (493.88, -8), (587.33, -7), (783.99, -4), (987.77, -7)]):
        x = place(x, level(S.bell(f, 1.3, tau=0.7, seed=203 + k)), at, undb(g))
    x = place(x, level(S.anvil(783.99 / 2.09, 1.2, decay=0.9, bright=1.2, thump_gain=0.35, seed=209)), at, undb(-6))
    x = place(x, level(S.sparkles(0.9, 22, seed=210, f_range=(4000, 10000))), at + 0.02, undb(-15))
    return S.fit(x, 1.5, fade_out=0.45)


@recipe("round_lose", -19, "Round lost: gentle 'aw', two soft falling bell notes (G4 to E-flat 4) that sag in pitch",
        synth=True)
def round_lose():
    x = S.silence(1.4)
    x = place(x, level(S.bell(392.00, 0.6, tau=0.35, seed=221, strike=0.03)), 0.0, undb(-3))
    low = S.bell(311.13, 1.15, tau=0.6, seed=222, strike=0.03)
    low = place(low, S.bell(155.56, 1.15, tau=0.5, seed=223, strike=0.0), 0.0, 0.35)
    x = place(x, level(glide(low, -70, start=0.15)), 0.26, undb(-1))
    x = place(x, level(S.fft_filter(K(KI, "Audio/impactGeneric_light_001.ogg"), hi=1500, order=2)), 0.26, undb(-16))
    return S.fit(S.fft_filter(x, hi=3200, order=2), 1.4, fade_out=0.5)


@recipe("series_win", -12, "Series won: ~2.8 s bell-and-anvil fanfare (ta-ta-ta-TAA, then a rising run into a big C major chord)",
        synth=True, release=0.02, max_limit=5)
def series_win():
    x = S.silence(2.9)
    for k, at in enumerate((0.0, 0.12, 0.24)):                    # ta-ta-ta
        x = place(x, level(S.bell(783.99, 0.25, tau=0.14, seed=231 + k, strike=0.25)), at, undb(-5))
    for k, (f, g) in enumerate([(523.25, -8), (659.26, -8), (783.99, -6)]):   # TAA
        x = place(x, level(S.bell(f, 0.9, tau=0.45, seed=235 + k)), 0.38, undb(g))
    x = place(x, level(S.anvil(1046.5 / 2.09, 0.9, decay=0.7, bright=1.1, thump_gain=0.3, seed=239)), 0.38, undb(-9))
    for k, (at, f) in enumerate([(0.86, 659.26), (0.98, 783.99), (1.10, 880.00)]):   # rising run
        x = place(x, level(S.bell(f, 0.4, tau=0.2, seed=241 + k, strike=0.18)), at, undb(-6))
    big = 1.24
    for k, (f, g) in enumerate([(523.25, -9), (659.26, -9), (783.99, -8), (1046.50, -4), (1318.51, -9)]):
        x = place(x, level(S.bell(f, 1.65, tau=1.0, seed=245 + k)), big, undb(g))
    x = place(x, level(S.anvil(1046.5 / 2.09, 1.6, decay=1.2, bright=1.2, thump_gain=0.6, seed=251)), big, undb(-5))
    x = place(x, level(K(KI, "Audio/impactBell_heavy_001.ogg")), big, undb(-12))
    x = place(x, level(S.whoosh(0.9, 800, 5000, seed=252, q=1.0, peak_at=0.3)), big + 0.02, undb(-22))
    x = place(x, level(S.sparkles(1.3, 40, seed=253, f_range=(4000, 10000))), big + 0.03, undb(-13))
    return S.fit(x, 2.9, fade_out=0.6)


@recipe("rival_finished", -15, "Opponent finished / is close: deep gong-like anvil ring under a quick rising two-bell alert",
        synth=True, release=0.02)
def rival_finished():
    x = S.silence(1.3)
    x = place(x, level(S.anvil(175, 1.3, decay=1.5, bright=0.7, thump_gain=0.6, seed=261)), 0.0)
    x = place(x, level(S.resample_pitch(K(KI, "Audio/impactBell_heavy_003.ogg"), 0.75)), 0.0, undb(-7))
    x = place(x, level(S.bell(880.00, 0.5, tau=0.25, seed=262, strike=0.2)), 0.0, undb(-5))
    x = place(x, level(S.bell(1318.51, 0.7, tau=0.35, seed=263, strike=0.2)), 0.12, undb(-4))
    return S.fit(x, 1.3, fade_out=0.4)


# ------------------------------------------------------------------ Masterworks, Forge Board, Lore Book
@recipe("gilded", -16, "Blueprint piece from a gilded cell: bright golden chime, a quick E major run of small bells "
        "(E6 G#6 B6 E7) over a soft shimmer", synth=True)
def gilded():
    x = S.silence(1.05)
    for k, (at, f) in enumerate([(0.0, 1318.51), (0.045, 1661.22), (0.09, 1975.53), (0.135, 2637.02)]):
        x = place(x, level(S.bell(f, 0.9, tau=0.3, seed=301 + k, strike=0.18)), at, undb(-4 - 0.7 * k))
    x = place(x, level(S.bell(659.26, 0.95, tau=0.42, seed=305, strike=0.0)), 0.0, undb(-12))  # warm E5 under it
    x = place(x, level(S.bell(2637.02, 0.8, tau=0.4, seed=306, strike=0.0)), 0.18, undb(-10))  # ringing top
    x = place(x, level(S.sparkles(0.8, 28, seed=307, f_range=(5000, 11000), decay=0.25)), 0.03, undb(-15))
    x = place(x, level(S.whoosh(0.35, 3000, 9000, seed=308, q=0.8, peak_at=0.3)), 0.0, undb(-22))
    return S.fit(x, 1.05, fade_out=0.35)


@recipe("masterwork", -12, "Masterwork finished: ~3.3 s triumphant flourish, an anvil strike and three rising bells "
        "(A4 D5 F#5) into a D major chord, a quick run, then a big ringing D major bell-and-anvil chord with sparks",
        synth=True, release=0.02, max_limit=5)
def masterwork():
    x = S.silence(3.4)
    x = place(x, level(S.anvil(587.33 / 2.09, 0.9, decay=0.8, bright=0.9, thump_gain=0.7, seed=311)), 0.0, undb(-3))
    for k, (at, f) in enumerate([(0.0, 440.00), (0.13, 587.33), (0.26, 739.99)]):         # da-da-da (rising)
        x = place(x, level(S.bell(f, 0.35, tau=0.18, seed=312 + k, strike=0.22)), at, undb(-5))
    for k, (f, g) in enumerate([(587.33, -8), (739.99, -8), (880.00, -6)]):               # DAA
        x = place(x, level(S.bell(f, 0.8, tau=0.4, seed=315 + k)), 0.40, undb(g))
    x = place(x, level(S.anvil(1174.66 / 2.09, 0.8, decay=0.6, bright=1.1, thump_gain=0.3, seed=318)), 0.40, undb(-10))
    for k, (at, f) in enumerate([(0.86, 880.00), (0.96, 987.77), (1.06, 1108.73)]):       # quick run up
        x = place(x, level(S.bell(f, 0.4, tau=0.2, seed=319 + k, strike=0.18)), at, undb(-7))
    big = 1.18
    for k, (f, g) in enumerate([(293.66, -12), (587.33, -9), (739.99, -9), (880.00, -8), (1174.66, -4),
                                (1479.98, -10)]):
        x = place(x, level(S.bell(f, 2.2, tau=1.2, seed=322 + k)), big, undb(g))
    x = place(x, level(S.anvil(1174.66 / 2.09, 2.0, decay=1.4, bright=1.2, thump_gain=0.8, seed=328)), big, undb(-5))
    x = place(x, level(K(KI, "Audio/impactBell_heavy_000.ogg")), big, undb(-12))
    x = place(x, level(S.whoosh(1.0, 700, 5200, seed=329, q=1.0, peak_at=0.3)), big + 0.02, undb(-21))
    x = place(x, level(S.sparkles(1.6, 50, seed=330, f_range=(4000, 10000), decay=0.45)), big + 0.03, undb(-13))
    x = place(x, level(S.bell(2349.32, 1.6, tau=0.8, seed=331, strike=0.0)), big + 0.25, undb(-16))  # glint
    return S.fit(x, 3.4, fade_out=0.8)


@recipe("claim", -16.5, "Reward claimed (Work Order, gift, Daily Stoke): warm two-note rising bell chime (C6 to G6), "
        "no coins", synth=True)
def claim():
    x = S.silence(0.85)
    x = place(x, level(S.bell(1046.50, 0.5, tau=0.22, seed=341, strike=0.15)), 0.0, undb(-4))
    x = place(x, level(S.bell(1567.98, 0.78, tau=0.4, seed=342, strike=0.15)), 0.085, undb(-2))
    x = place(x, level(S.bell(783.99, 0.78, tau=0.38, seed=343, strike=0.0)), 0.085, undb(-11))
    x = place(x, level(S.tink(3135.96, dur=0.2)), 0.085, undb(-15))
    return S.fit(x, 0.85, fade_out=0.3)


@recipe("page", -21, "Lore Book page turn: a parchment page swishing over, with a dry crinkle", synth=True,
        release=0.01, max_limit=6.5)
def page():
    flip = S.fft_filter(K(KR, "Audio/bookFlip2.ogg"), lo=250, hi=11000)
    x = level(S.fade(flip, fade_in=0.012))  # round off the flip's slap so it isn't all transient
    x = place(x, level(S.whoosh(0.32, 900, 3500, seed=351, q=0.7, peak_at=0.55)), 0.02, undb(-7))
    x = place(x, level(S.crackle(0.3, 70, seed=352, lo=1800, hi=9000)), 0.03, undb(-18))
    return S.fit(x, 0.5, fade_out=0.15)


# ------------------------------------------------------------------ music
def seamless(x: np.ndarray, xfade: float = 0.015) -> np.ndarray:
    """Make a loop click-free: fold its last `xfade` s into its first (equal power).
    The loop gets `xfade` shorter; the end now runs straight into the start."""
    n = S.n_samples(xfade)
    u = np.linspace(0, 1, n)[:, None]
    y = x[: len(x) - n].copy()
    y[:n] = x[len(x) - n:] * np.cos(0.5 * np.pi * u) + x[:n] * np.sin(0.5 * np.pi * u)
    return y


@recipe("music_hall", -16, "Forge Hall / menus music: calm medieval loop, 'King's Feast' (loop version), ~81 s stereo",
        channels=2, quality=2, metric="lufs", release=0.3, max_limit=1.5)
def music_hall():
    return seamless(K(OGA_FEAST, "Loop_Kings_Feast_0.wav", channels=2))


@recipe("music_round", -16, "Multiplayer round music: lively medieval dance loop, 'Minstrel Dance' (loop version), ~56 s stereo",
        channels=2, quality=2, metric="lufs", release=0.3, max_limit=1.5)
def music_round():
    return seamless(K(OGA_MINSTREL, "Loop_Minstrel_Dance_0.wav", channels=2))


# ------------------------------------------------------------------ pipeline
def master(r: Recipe, x: np.ndarray) -> tuple[np.ndarray, list[str]]:
    notes = []
    if x.ndim == 1:
        x = S.fft_filter(x, lo=SFX_HIGHPASS_HZ, order=2)
        x = S.trim(x, start_db=-50, end_db=-70, pre=0.001)
        x = S.fade(x, fade_in=0.0003, fade_out=0.01)
    m = S.measure(x)
    x = x * undb(r.lufs - m[r.metric])
    over = S.db(S.true_peak(x)) - TP_PRE
    if over > r.max_limit:
        x = x * undb(-(over - r.max_limit))
        notes.append(f"peak-bound: {over - r.max_limit:.1f} dB under loudness target")
    if over > 0:
        x = S.limit(x, undb(TP_PRE), release=r.release)
        if over > 0.05:
            notes.append(f"limited {min(over, r.max_limit):.1f} dB")
    return x, notes


def build(r: Recipe) -> dict:
    global _current
    _current = r
    r.sources.clear()
    x = r.build()
    _current = None
    x, notes = master(r, x)
    out = OUT_DIR / f"{r.name}.ogg"
    for _ in range(4):
        S.encode_ogg(x, str(out), quality=r.quality)
        m = S.measure_file(str(out))
        if m["tp"] <= TP_CEILING:
            break
        x = x * undb(TP_CEILING - m["tp"] - 0.2)
        notes.append("re-encoded for true peak")
    info = S.probe(str(out))
    return {
        "file": f"audio/{r.name}.ogg",
        "description": r.desc,
        "duration_s": round(float(info["duration"]), 3),
        "channels": int(info["channels"]),
        "sample_rate": int(info["sample_rate"]),
        "bytes": out.stat().st_size,
        "loudness_metric": "integrated" if r.metric == "lufs" else "max momentary",
        "target_lufs": r.lufs,
        "lufs_integrated": m["lufs"],
        "lufs_momentary_max": m["mmax"],
        "true_peak_dbtp": m["tp"],
        "synthesized": r.synth,
        "sources": [{"pack": p, "file": f} for p, f in r.sources],
        "notes": notes,
    }


def dominant_hz(path: Path) -> float:
    """Strongest spectral peak in the first 120 ms (parabolic-interpolated FFT bin)."""
    x = S.load(str(path))[: S.n_samples(0.12)]
    n = 1 << 16
    X = np.abs(np.fft.rfft(x * np.hanning(len(x)), n))
    k = int(np.argmax(X[1:])) + 1
    a, b, c = np.log(X[k - 1:k + 2] + 1e-12)
    return (k + 0.5 * (a - c) / (a - 2 * b + c)) * S.SR / n


def verify() -> list[str]:
    """Check every built file against the audio rules; returns a list of problems."""
    problems = []
    for name, r in RECIPES.items():
        path = OUT_DIR / f"{name}.ogg"
        if not path.exists():
            problems.append(f"{name}: not built")
            continue
        info = S.probe(str(path))
        if info["codec_name"] != "vorbis" or int(info["sample_rate"]) != S.SR or int(info["channels"]) != r.channels:
            problems.append(f"{name}: {info['codec_name']} {info['sample_rate']} Hz {info['channels']} ch")
        tp = S.measure_file(str(path))["tp"]
        if tp > TP_CEILING:
            problems.append(f"{name}: true peak {tp} dBTP > {TP_CEILING}")
    freqs = [dominant_hz(OUT_DIR / f"tink_{i}.ogg") for i in range(1, len(TINK_NOTES) + 1)]
    for (note, want), got in zip(TINK_NOTES, freqs):
        if abs(1200 * np.log2(got / want)) > 15:
            problems.append(f"tink {note}: measured {got:.1f} Hz, expected {want:.1f} Hz")
    if any(b <= a for a, b in zip(freqs, freqs[1:])):
        problems.append(f"tink series does not rise: {[round(f) for f in freqs]}")
    print("tink pitches (Hz):", ", ".join(f"{f:.1f}" for f in freqs))
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*", help="build only these sounds")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list:
        for r in RECIPES.values():
            print(f"{r.name:16} {r.lufs:6.1f} LUFS  {r.desc}")
        return 0
    names = args.names or list(RECIPES)
    unknown = [n for n in names if n not in RECIPES]
    if unknown:
        ap.error(f"unknown sound(s): {', '.join(unknown)}")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    for n in names:
        r = RECIPES[n]
        res = build(r)
        manifest[n] = res
        flag = "" if not res["notes"] else "  (" + "; ".join(res["notes"]) + ")"
        print(f"{n:16} {res['duration_s']:6.3f}s ch{res['channels']} {res['bytes'] / 1024:7.1f} KiB "
              f"I {res['lufs_integrated']:6.1f}  M-max {res['lufs_momentary_max']:6.1f} (target {r.lufs:5.1f})  "
              f"TP {res['true_peak_dbtp']:5.1f}{flag}")
    manifest = {k: manifest[k] for k in RECIPES if k in manifest}  # stable order, drop stale
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    total = sum(p.stat().st_size for p in OUT_DIR.glob("*.ogg"))
    print(f"\n{len(list(OUT_DIR.glob('*.ogg')))} files, {total / 1024:.0f} KiB total in {OUT_DIR}")
    problems = verify()
    for prob in problems:
        print("PROBLEM:", prob, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
