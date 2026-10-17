"""Assemble the campaign file and the multiplayer bank."""

from __future__ import annotations

import hashlib
import json
import os
import random
import time
from collections import Counter

from . import paths
from .generate import Result, SeedPool, Spec, generate_slot, spec_for
from .layout import LayoutOptions
from .tiers import (CHAPTERS, MP_ANSWER_LEVEL, MP_SEED_LEVEL, MP_SIZE_MIN, MP_SIZES, TIERS,
                    TUTORIAL_LEVEL, TUTORIAL_STAGES, TUTORIAL_WORDS, Chapter,
                    chapter_heats, mp_target)
from .words import Lexicon, load, signature

PUZZLE_KEYS = ("id", "letters", "heat", "size", "cols", "rows", "words", "bonus")


def rng_for(seed: int, *parts) -> random.Random:
    """An independent, reproducible RNG for one slot (not tied to PYTHONHASHSEED)."""
    key = ":".join(str(p) for p in (seed,) + parts)
    return random.Random(int(hashlib.sha256(key.encode()).hexdigest()[:16], 16))


def tutorial_spec() -> Spec:
    t = TIERS[1]
    return Spec(heat=1, length=4, target=TUTORIAL_WORDS, min_words=TUTORIAL_WORDS,
                answer_level=TUTORIAL_LEVEL, common_level=t.common_level, max_rare=0,
                seed_level=TUTORIAL_LEVEL, exact=True, max_answer_len=4, progress=0.0)


def arrange(results: list[Result], rng: random.Random) -> list[Result]:
    """Sort by difficulty, then drop in an occasional easier "breather"."""
    items = sorted(results, key=lambda r: (r.difficulty, r.seed))
    n = len(items)
    positions = []
    p = rng.randint(6, 9)
    while p < n - 2:
        positions.append(p)
        p += rng.randint(7, 10)
    taken: set[int] = set()
    moves = []
    for p in positions:
        src = int(p * 0.55)
        while src in taken:
            src += 1
        taken.add(src)
        moves.append((p, src))
    order = [i for i in range(n) if i not in taken]
    for p, src in moves:
        order.insert(p, src)
    return [items[i] for i in order]


def ordered_puzzle(p: dict) -> dict:
    return {k: p[k] for k in PUZZLE_KEYS if k in p}


def dump_puzzle_file(path: str, head: dict, puzzles: list[dict]) -> None:
    """Compact JSON: the outer structure, with one puzzle per line."""
    parts = []
    for k, v in head.items():
        parts.append(json.dumps(k) + ":" + json.dumps(v, separators=(",", ":")))
    lines = ",\n".join(json.dumps(ordered_puzzle(p), separators=(",", ":")) for p in puzzles)
    text = "{" + ",".join(parts) + ',"puzzles":[\n' + lines + "\n]}\n"
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def write_report(out_path: str, report: dict) -> str:
    os.makedirs(paths.REPORTS_DIR, exist_ok=True)
    base = os.path.splitext(os.path.basename(out_path))[0]
    rp = os.path.join(paths.REPORTS_DIR, base + ".gen.json")
    with open(rp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(report, f, indent=1)
        f.write("\n")
    return rp


# ------------------------------------------------------------------ campaign


def build_campaign(seed: int, lex: Lexicon | None = None,
                   chapters: tuple[Chapter, ...] = CHAPTERS,
                   opts: LayoutOptions | None = None, log=None):
    """Return (campaign dict, report dict)."""
    lex = lex or load()
    pool = SeedPool(lex)
    used: set[str] = set()
    slots = []
    for ci, ch in enumerate(chapters):
        for h in chapter_heats(ch):
            slots.append((ci, h))
    tier_total = Counter(h for i, (_, h) in enumerate(slots) if i >= TUTORIAL_STAGES)
    tier_seen: Counter = Counter()
    per_chapter: list[dict[int, list[Result]]] = [dict() for _ in chapters]
    tutorials: list[Result] = []
    rejections = [Counter() for _ in chapters]
    for idx, (ci, h) in enumerate(slots):
        rng = rng_for(seed, "campaign", idx)
        if idx < TUTORIAL_STAGES:
            spec = tutorial_spec()
        else:
            k = tier_seen[h]
            tier_seen[h] += 1
            progress = k / max(1, tier_total[h] - 1)
            spec = spec_for(h, progress, rng)
        stats: dict = {}
        res = generate_slot(lex, pool, spec, used, rng, stats, opts=opts)
        rejections[ci].update(stats)
        if idx < TUTORIAL_STAGES:
            tutorials.append(res)
        else:
            per_chapter[ci].setdefault(h, []).append(res)
        if log and (idx + 1) % 50 == 0:
            log(f"  {idx + 1}/{len(slots)} puzzles")

    puzzles = []
    chapter_list = []
    report_groups = {}
    first = 1
    for ci, ch in enumerate(chapters):
        ordered: list[Result] = []
        if ci == 0:
            ordered += sorted(tutorials, key=lambda r: (r.difficulty, r.seed))
        for h in sorted(per_chapter[ci]):
            ordered += arrange(per_chapter[ci][h], rng_for(seed, "arrange", ch.id, h))
        assert len(ordered) == ch.count, (ch.id, len(ordered))
        for r in ordered:
            r.puzzle["id"] = f"c-{len(puzzles) + 1:04d}"
            puzzles.append(r.puzzle)
        chapter_list.append({"id": ch.id, "name": ch.name, "first": first, "count": ch.count})
        diffs = [r.difficulty for r in ordered]
        report_groups[ch.name] = {
            "rejections": dict(sorted(rejections[ci].items())),
            "difficulty": [min(diffs), max(diffs)],
            "difficulty_by_stage": diffs,
            "seeds": [r.seed for r in ordered],
        }
        first += ch.count
    campaign = {"version": 1, "chapters": chapter_list, "puzzles": puzzles}
    report = {"seed": seed, "kind": "campaign", "groups": report_groups}
    return campaign, report


# ----------------------------------------------------------------- multiplayer


def campaign_signatures(path: str) -> set[str]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return {signature(p["letters"].lower()) for p in data["puzzles"]}


def build_mp(seed: int, per: int, exclude: set[str], lex: Lexicon | None = None,
             heats=tuple(sorted(TIERS)), sizes=MP_SIZES,
             opts: LayoutOptions | None = None, log=None):
    """Return (bank dict, report dict). `exclude` = campaign letter signatures."""
    lex = lex or load()
    pool = SeedPool(lex)
    used = set(exclude)
    groups: dict[tuple[int, int], list[Result]] = {}
    report_groups = {}
    notes = []
    # Biggest sizes first, so they get the seeds with the most words.
    for heat in heats:
        for size in sorted(sizes, reverse=True):
            lo, hi = mp_target(heat, size)
            need = MP_SIZE_MIN[(heat, size)]
            if need < lo:
                notes.append(f"heat {heat} size {size}: wants {lo}-{hi} words, "
                             f"guarantees {need}+ (anvil too small)")
            stats: dict = {}
            out = []
            for i in range(per):
                rng = rng_for(seed, "mp", heat, size, i)
                progress = rng.random()
                target = rng.randint(lo, hi)
                spec = spec_for(heat, progress, rng, target=target, extra_words=2 * (size - 1),
                                min_words=need, answer_level=MP_ANSWER_LEVEL.get((heat, size)))
                spec.seed_level = MP_SEED_LEVEL.get((heat, size), TIERS[heat].seed_level)
                res = generate_slot(lex, pool, spec, used, rng, stats, opts=opts,
                                    rich_first=need < lo)
                res.puzzle["size"] = size
                out.append(res)
            out.sort(key=lambda r: (r.difficulty, r.seed))
            groups[(heat, size)] = out
            nw = [len(r.puzzle["words"]) for r in out]
            report_groups[f"heat {heat} size {size}"] = {
                "rejections": dict(sorted(stats.items())),
                "difficulty": [out[0].difficulty, out[-1].difficulty],
                "words": [min(nw), max(nw)],
                "target": [lo, hi],
            }
            if log:
                log(f"  heat {heat} size {size}: {per} puzzles, words {min(nw)}-{max(nw)} "
                    f"(target {lo}-{hi})")
    puzzles = []
    for heat in heats:
        for size in sorted(sizes):
            for r in groups[(heat, size)]:
                r.puzzle["id"] = f"m-{len(puzzles) + 1:05d}"
                puzzles.append(r.puzzle)
    bank = {"version": 1, "puzzles": puzzles}
    report = {"seed": seed, "kind": "mp", "per": per, "groups": report_groups, "notes": notes}
    return bank, report


# ----------------------------------------------------------------- commands


def main_campaign(args) -> int:
    t0 = time.time()
    campaign, report = build_campaign(args.seed, log=print)
    dump_puzzle_file(args.out, {"version": 1, "chapters": campaign["chapters"]},
                     campaign["puzzles"])
    rp = write_report(args.out, report)
    print(f"wrote {len(campaign['puzzles'])} puzzles to {args.out} "
          f"in {time.time() - t0:.1f}s (report: {os.path.relpath(rp)})")
    return 0


def main_mp(args) -> int:
    t0 = time.time()
    if not os.path.exists(args.campaign):
        print(f"campaign file {args.campaign} not found; generate the campaign first "
              "(multiplayer seed words must not repeat campaign ones)")
        return 2
    exclude = campaign_signatures(args.campaign)
    bank, report = build_mp(args.seed, args.per, exclude, log=print)
    dump_puzzle_file(args.out, {"version": 1}, bank["puzzles"])
    rp = write_report(args.out, report)
    print(f"wrote {len(bank['puzzles'])} puzzles to {args.out} "
          f"in {time.time() - t0:.1f}s (report: {os.path.relpath(rp)})")
    return 0
