"""Assemble the campaign file and the multiplayer bank."""

from __future__ import annotations

import hashlib
import json
import os
import random
import time
from collections import Counter

from . import paths
from .render import report_path
from .generate import Result, SeedPool, Spec, answer_candidates, generate_slot, spec_for
from .layout import LayoutOptions
from .tiers import (CHAPTERS, MP_ANSWER_Q, MP_GROW_ANSWER_Q, MP_GROW_PER, MP_GROW_SEED_Q,
                    MP_SEED_Q, MP_SIZE_MIN, MP_SIZES, TIERS, TUTORIAL_Q, TUTORIAL_STAGES,
                    TUTORIAL_WORDS, Chapter, chapter_heats, mp_target)
from .words import Lexicon, load, signature

PUZZLE_KEYS = ("id", "letters", "heat", "size", "cols", "rows", "words", "bonus")


def rng_for(seed: int, *parts) -> random.Random:
    """An independent, reproducible RNG for one slot (not tied to PYTHONHASHSEED)."""
    key = ":".join(str(p) for p in (seed,) + parts)
    return random.Random(int(hashlib.sha256(key.encode()).hexdigest()[:16], 16))


def tutorial_spec() -> Spec:
    t = TIERS[1]
    return Spec(heat=1, length=4, target=TUTORIAL_WORDS, min_words=TUTORIAL_WORDS,
                max_words=TUTORIAL_WORDS,
                answer_q=TUTORIAL_Q, answer_level=t.answer_level, common_q=TUTORIAL_Q,
                max_rare=0, seed_q=TUTORIAL_Q, max_inflections=0, exact=True,
                max_answer_len=4, progress=0.0)


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


def write_report(out_path: str, report: dict, part: int | None = None) -> str:
    """Write the report; a bank part added by `grow` gets its own (<name>.partN.gen.json)."""
    rp = report_path(out_path)
    if part is not None:
        rp = rp.removesuffix(".gen.json") + f".part{part}.gen.json"
    os.makedirs(os.path.dirname(rp), exist_ok=True)
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
    usage: Counter = Counter()
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
        res = generate_slot(lex, pool, spec, used, rng, stats, opts=opts, usage=usage)
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
            "left": left_summary(ordered),
            "difficulty": [min(diffs), max(diffs)],
            "difficulty_by_stage": diffs,
            "seeds": [r.seed for r in ordered],
        }
        first += ch.count
    campaign = {"version": 1, "chapters": chapter_list, "puzzles": puzzles}
    report = {"seed": seed, "kind": "campaign", "groups": report_groups}
    return campaign, report


# ----------------------------------------------------------------- multiplayer


def left_summary(results: list[Result]) -> dict:
    """Good words left over (generate.make_puzzle info["left"]): mean and max per puzzle
    at each level (very common, common, fair)."""
    lefts = [r.info["left"] for r in results]
    return {name: [round(sum(x[i] for x in lefts) / len(lefts), 2), max(x[i] for x in lefts)]
            for i, name in enumerate(("4.0", "3.0", "2.5"))}


def campaign_signatures(path: str) -> set[str]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return {signature(p["letters"].lower()) for p in data["puzzles"]}


def build_mp(seed: int, per, exclude: set[str], lex: Lexicon | None = None,
             heats=tuple(sorted(TIERS)), sizes=MP_SIZES,
             opts: LayoutOptions | None = None, log=None, first_id: int = 1,
             answer_qs=MP_ANSWER_Q, seed_qs=MP_SEED_Q):
    """Return (bank dict, report dict). `exclude` = letter signatures already used.

    `per` is the number of puzzles for every heat and size, or a dict
    {(heat, size): n}. Ids start at m-`first_id`.
    """
    lex = lex or load()
    count = per if isinstance(per, dict) else {(h, s): per for h in heats for s in sizes}
    pool = SeedPool(lex)
    used = set(exclude)
    groups: dict[tuple[int, int], list[Result]] = {}
    report_groups = {}
    notes = []
    usage: Counter = Counter()
    # Biggest sizes first, so they get the seeds with the most words.
    for heat in heats:
        richness = anvil_richness(lex, pool, heat, sizes, answer_qs, used)
        for size in sorted(sizes, reverse=True):
            if count.get((heat, size), 0) == 0:
                continue
            lo, hi = mp_target(heat, size)
            need = MP_SIZE_MIN[(heat, size)]
            if need < lo:
                notes.append(f"heat {heat} size {size}: wants {lo}-{hi} words, "
                             f"guarantees {need}+ (anvil too small)")
            # Pools widened to any quality (co-op Ember): anvils with enough words
            # are scarce, so the richest go first.
            scarce = (heat, size) in answer_qs and answer_qs[(heat, size)] is None
            stats: dict = {}
            out = []
            t0 = time.time()
            for i in range(count[(heat, size)]):
                rng = rng_for(seed, "mp", heat, size, i)
                progress = rng.random()
                target = rng.randint(lo, hi)
                spec = spec_for(heat, progress, rng, target=target, extra_words=2 * (size - 1),
                                min_words=need, answer_q=answer_qs.get((heat, size)),
                                widened=(heat, size) in answer_qs)
                spec.seed_q = seed_qs.get((heat, size), TIERS[heat].seed_q)
                res = generate_slot(lex, pool, spec, used, rng, stats, opts=opts,
                                    rich_first=scarce, usage=usage,
                                    avoid=reserved_for_bigger(richness, heat, size, sizes))
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
                "left": left_summary(out),
            }
            if log:
                log(f"  heat {heat} size {size}: {len(out)} puzzles, words {min(nw)}-{max(nw)} "
                    f"(target {lo}-{hi}), {time.time() - t0:.0f}s")
    puzzles = []
    for heat in heats:
        for size in sorted(sizes):
            for r in groups.get((heat, size), ()):
                r.puzzle["id"] = f"m-{first_id + len(puzzles):05d}"
                puzzles.append(r.puzzle)
    bank = {"version": 1, "puzzles": puzzles}
    report = {"seed": seed, "kind": "mp", "per": per if isinstance(per, int) else per_table(count),
              "groups": report_groups, "notes": notes}
    return bank, report


def anvil_richness(lex: Lexicon, pool: SeedPool, heat: int, sizes, answer_qs: dict,
                   used: set[str]) -> dict[str, int]:
    """For a heat with scarce sizes (guaranteeing fewer words than they want, README:
    Ember), the answer count of each unused anvil in the widest pool; {} otherwise."""
    scarce = [s for s in sizes if MP_SIZE_MIN[(heat, s)] < mp_target(heat, s)[0]]
    if not scarce:
        return {}
    widest = max(scarce)
    need = MP_SIZE_MIN[(heat, widest)]
    spec = spec_for(heat, 0.5, random.Random(0), target=need, min_words=need,
                    answer_q=answer_qs.get((heat, widest)),
                    widened=(heat, widest) in answer_qs)
    out = {}
    for length in TIERS[heat].lengths:
        for s in pool.seeds(length, spec.answer_level, None, True):
            sig = signature(s)
            if sig not in used:
                out[sig] = len(answer_candidates(lex, s, spec))
    return out


def reserved_for_bigger(richness: dict[str, int], heat: int, size: int, sizes) -> frozenset[str]:
    """Anvils a bigger size of `heat` could use: `size` takes them only when nothing
    else is left, so that later parts still find some (Ember has about 120 anvils
    that make 6+ interlocking words, and about 200 that make 5+)."""
    bigger = [MP_SIZE_MIN[(heat, s)] for s in sizes if s > size]
    if not richness or not bigger:
        return frozenset()
    need = min(bigger)
    return frozenset(sig for sig, n in richness.items() if n >= need)


def per_table(count: dict) -> list[list[int]]:
    """{(heat, size): n} as [[n for each size 1-4] for each heat 1-6], as bank parts store it."""
    return [[count.get((h, s), 0) for s in MP_SIZES] for h in sorted(TIERS)]


def bank_parts(data: dict) -> list[dict]:
    """The bank's parts (see README); a bank without any is one part of every puzzle."""
    return data.get("parts") or [{"first": 1, "count": len(data["puzzles"])}]


# ------------------------------------------------------------ refresh / grow


def refresh_bonus(puzzles: list[dict], lex: Lexicon) -> tuple[list[dict], list[str]]:
    """Recompute every puzzle's bonus list with `lex`; nothing else changes.

    Returns (puzzles, problems). A problem is a grid answer that is no longer
    an accepted word: that puzzle needs a new grid, and keeps its old bonus
    list here.
    """
    out, problems = [], []
    for p in puzzles:
        grid = {w["w"] for w in p["words"]}
        gone = sorted(w for w in grid if w.lower() not in lex.accepted)
        if gone:
            size = f", size {p['size']}" if "size" in p else ""
            problems.append(f"{p['id']} (heat {p['heat']}{size}): grid answer "
                            f"{', '.join(gone)} is no longer accepted")
            out.append(p)
            continue
        bonus = sorted(w.upper() for w in lex.subwords(p["letters"]) if w.upper() not in grid)
        out.append(dict(p, bonus=bonus))
    return out, problems


def bonus_changes(old: list[dict], new: list[dict]) -> dict:
    """How the bonus lists changed between two versions of the same puzzles."""
    removed: Counter = Counter()
    added: Counter = Counter()
    changed = 0
    for a, b in zip(old, new):
        gone, extra = set(a["bonus"]) - set(b["bonus"]), set(b["bonus"]) - set(a["bonus"])
        changed += bool(gone or extra)
        removed.update(gone)
        added.update(extra)
    return {"puzzles": len(old), "changed": changed,
            "bonus_before": sum(len(p["bonus"]) for p in old),
            "bonus_after": sum(len(p["bonus"]) for p in new),
            "removed": dict(sorted(removed.items())), "added": dict(sorted(added.items()))}


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


def main_refresh(args) -> int:
    with open(args.file, encoding="utf-8") as f:
        data = json.load(f)
    puzzles, problems = refresh_bonus(data["puzzles"], load())
    for line in problems:
        print(f"NEEDS A NEW GRID: {line}")
    c = bonus_changes(data["puzzles"], puzzles)
    dump_puzzle_file(args.file, {k: v for k, v in data.items() if k != "puzzles"}, puzzles)
    print(f"{args.file}: {c['changed']} of {c['puzzles']} bonus lists changed, "
          f"{c['bonus_before']} -> {c['bonus_after']} bonus words "
          f"({len(c['removed'])} words removed, {len(c['added'])} added)")
    return 1 if problems else 0


def main_grow(args) -> int:
    """Append a part to the bank: new puzzles after the last id, the others kept."""
    t0 = time.time()
    with open(args.bank, encoding="utf-8") as f:
        data = json.load(f)
    lex = load()
    puzzles, problems = refresh_bonus(data["puzzles"], lex)
    if problems:
        for line in problems:
            print(f"NEEDS A NEW GRID: {line}")
        return 1
    parts = bank_parts(data)
    if len(parts) == 1 and "per" not in parts[0]:
        # A bank made by `mp`: its seed is in its generation report.
        first_part = dict(parts[0])
        if os.path.exists(report_path(args.bank)):
            with open(report_path(args.bank), encoding="utf-8") as f:
                gen = json.load(f)
            if gen.get("kind") == "mp":
                first_part["seed"] = gen["seed"]
        first_part["per"] = per_table(Counter((p["heat"], p["size"]) for p in puzzles))
        parts = [first_part]
    used = campaign_signatures(args.campaign) | {signature(p["letters"].lower()) for p in puzzles}
    first = len(puzzles) + 1
    part, report = build_mp(args.seed, dict(MP_GROW_PER), used, lex=lex, log=print,
                            first_id=first, answer_qs=MP_GROW_ANSWER_Q,
                            seed_qs=MP_GROW_SEED_Q)
    parts.append({"first": first, "count": len(part["puzzles"]), "seed": args.seed,
                  "per": per_table(MP_GROW_PER)})
    puzzles += part["puzzles"]
    dump_puzzle_file(args.out, {"version": 1, "parts": parts}, puzzles)
    rp = write_report(args.out, dict(report, kind="mp grow", first=first), part=len(parts))
    print(f"wrote {len(puzzles)} puzzles ({len(part['puzzles'])} new, from m-{first:05d}) "
          f"to {args.out} in {time.time() - t0:.1f}s (report: {os.path.relpath(rp)})")
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
