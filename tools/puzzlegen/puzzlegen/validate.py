"""`validate`: check a campaign file or multiplayer bank against every rule."""

from __future__ import annotations

import json
import os
import re
from collections import Counter

from . import paths
from .rules import check_puzzle
from .tiers import (CAMPAIGN_TOTAL, CHAPTERS, MP_SIZE_MIN, MP_SIZES, TIERS,
                    TUTORIAL_STAGES, TUTORIAL_WORDS, chapter_heats, mp_target)
from .words import Lexicon, load, signature

CAMPAIGN_ID = re.compile(r"^c-\d{4}$")
MP_ID = re.compile(r"^m-\d{5}$")


def _tier_checks(p: dict, heat: int, lo: int, hi: int, where: str) -> list[str]:
    errors = []
    t = TIERS.get(heat)
    if t is None:
        return [f"{where}: unknown heat {heat}"]
    if len(p["letters"]) not in t.lengths:
        errors.append(f"{where}: heat {heat} needs {'/'.join(map(str, t.lengths))} letters, "
                      f"has {len(p['letters'])}")
    n = len(p["words"])
    if not lo <= n <= hi:
        errors.append(f"{where}: heat {heat} needs {lo}-{hi} grid words, has {n}")
    return errors


def validate_campaign(data: dict, lex: Lexicon) -> list[str]:
    errors = []
    if data.get("version") != 1:
        errors.append(f"version must be 1, is {data.get('version')!r}")
    chapters = data.get("chapters")
    puzzles = data.get("puzzles")
    if not isinstance(chapters, list) or not isinstance(puzzles, list):
        return errors + ["campaign needs 'chapters' and 'puzzles' lists"]
    # Chapters: exactly DESIGN.md 2.4, in order, contiguous.
    expected_first = 1
    if len(chapters) != len(CHAPTERS):
        errors.append(f"expected {len(CHAPTERS)} chapters, found {len(chapters)}")
    for i, ch in enumerate(chapters):
        if set(ch) != {"id", "name", "first", "count"}:
            errors.append(f"chapter {i}: fields must be id, name, first, count")
            continue
        if ch["first"] != expected_first:
            errors.append(f"chapter {ch['id']}: first is {ch['first']}, expected "
                          f"{expected_first} (chapters must be contiguous)")
        expected_first = ch["first"] + ch["count"]
        if i < len(CHAPTERS):
            want = CHAPTERS[i]
            if (ch["id"], ch["name"], ch["count"]) != (want.id, want.name, want.count):
                errors.append(f"chapter {i}: is {ch['id']}/{ch['name']}/{ch['count']}, expected "
                              f"{want.id}/{want.name}/{want.count}")
    if expected_first - 1 != len(puzzles):
        errors.append(f"chapters cover {expected_first - 1} stages but there are "
                      f"{len(puzzles)} puzzles")
    if len(puzzles) != CAMPAIGN_TOTAL:
        errors.append(f"expected {CAMPAIGN_TOTAL} puzzles, found {len(puzzles)}")

    # Heat each stage should have.
    stage_heat = []
    for ch in CHAPTERS:
        stage_heat += [(ch, h) for h in chapter_heats(ch)]

    seen_sigs: dict[str, str] = {}
    for i, p in enumerate(puzzles):
        where = f"stage {i + 1}"
        if not isinstance(p, dict):
            errors.append(f"{where}: not an object")
            continue
        pid = p.get("id")
        if pid != f"c-{i + 1:04d}":
            errors.append(f"{where}: id {pid!r}, expected c-{i + 1:04d}")
        where = f"{pid}"
        if "size" in p:
            errors.append(f"{where}: campaign puzzles have no 'size'")
        if set(p) - {"id", "letters", "heat", "cols", "rows", "words", "bonus"}:
            errors.append(f"{where}: unexpected fields {sorted(set(p) - set(_KEYS))}")
        errs = check_puzzle(p, lex)
        errors += [f"{where}: {e}" for e in errs]
        if not _well_formed(p):
            continue
        if i < len(stage_heat):
            ch, h = stage_heat[i]
            if p["heat"] != h:
                errors.append(f"{where}: chapter {ch.name} stage should be heat {h}, "
                              f"is {p['heat']}")
            if not ch.heat_from <= p["heat"] <= ch.heat_to:
                errors.append(f"{where}: heat {p['heat']} outside {ch.name}'s range")
        if i < TUTORIAL_STAGES:
            if len(p["letters"]) != 4 or len(p["words"]) != TUTORIAL_WORDS:
                errors.append(f"{where}: tutorial stages need 4 letters and exactly "
                              f"{TUTORIAL_WORDS} words")
        else:
            t = TIERS.get(p["heat"])
            if t:
                errors += _tier_checks(p, p["heat"], t.min_words, t.max_words, where)
        sig = signature(p["letters"])
        if sig in seen_sigs:
            errors.append(f"{where}: same letters as {seen_sigs[sig]}")
        else:
            seen_sigs[sig] = pid
    # Heat never goes down along the campaign.
    heats = [p.get("heat", 0) for p in puzzles if isinstance(p, dict)]
    for i in range(1, len(heats)):
        if heats[i] < heats[i - 1]:
            errors.append(f"stage {i + 1}: heat drops from {heats[i - 1]} to {heats[i]}")
    return errors


_KEYS = ("id", "letters", "heat", "cols", "rows", "words", "bonus")


def _well_formed(p: dict) -> bool:
    """Enough structure for the campaign/bank-level checks to run."""
    return (all(k in p for k in _KEYS) and isinstance(p["letters"], str)
            and p["letters"].isalpha() and isinstance(p["words"], list)
            and isinstance(p["heat"], int))


def validate_mp(data: dict, lex: Lexicon, campaign: dict | None = None,
                per: int | None = None) -> list[str]:
    errors = []
    if data.get("version") != 1:
        errors.append(f"version must be 1, is {data.get('version')!r}")
    puzzles = data.get("puzzles")
    if not isinstance(puzzles, list) or not puzzles:
        return errors + ["bank needs a non-empty 'puzzles' list"]
    seen_sigs: dict[str, str] = {}
    camp_sigs = {}
    if campaign is not None:
        camp_sigs = {signature(p["letters"]): p["id"] for p in campaign.get("puzzles", [])}
    for i, p in enumerate(puzzles):
        pid = p.get("id") if isinstance(p, dict) else None
        if pid != f"m-{i + 1:05d}":
            errors.append(f"puzzle {i}: id {pid!r}, expected m-{i + 1:05d}")
        where = str(pid)
        if not isinstance(p, dict):
            continue
        size = p.get("size")
        if size not in MP_SIZES:
            errors.append(f"{where}: size {size!r} not in 1-4")
            continue
        if set(p) - set(_KEYS) - {"size"}:
            errors.append(f"{where}: unexpected fields {sorted(set(p) - set(_KEYS) - {'size'})}")
        errs = check_puzzle({k: v for k, v in p.items() if k != "size"}, lex)
        errors += [f"{where}: {e}" for e in errs]
        if not _well_formed(p):
            continue
        heat = p["heat"]
        if heat in TIERS:
            lo, hi = mp_target(heat, size)
            errors += _tier_checks(p, heat, MP_SIZE_MIN[(heat, size)], hi, where)
        sig = signature(p["letters"])
        if sig in seen_sigs:
            errors.append(f"{where}: same letters as {seen_sigs[sig]}")
        else:
            seen_sigs[sig] = pid
        if sig in camp_sigs:
            errors.append(f"{where}: same letters as campaign {camp_sigs[sig]}")
    return errors + _part_checks(data.get("parts"), puzzles, per)


def _part_checks(parts, puzzles: list, per: int | None) -> list[str]:
    """A bank is one or more parts (README "Growing the bank"), contiguous from
    m-00001. In each part every heat x size is present, `per[heat-1][size-1]`
    times (a bank without parts: `per` times, or equally often), ordered by
    heat, then size."""
    errors = []
    single = parts is None
    if single:
        parts = [{"first": 1, "count": len(puzzles)}]
    if not isinstance(parts, list) or not parts:
        return ["'parts' must be a non-empty list"]
    expected_first = 1
    for k, part in enumerate(parts):
        name = "bank" if single else f"part {k + 1}"
        if (not isinstance(part, dict) or not isinstance(part.get("first"), int)
                or not isinstance(part.get("count"), int)):
            return errors + [f"{name}: needs integer 'first' and 'count'"]
        if part["first"] != expected_first:
            errors.append(f"{name}: first is {part['first']}, expected {expected_first} "
                          "(parts must be contiguous)")
        expected_first = part["first"] + part["count"]
        ps = [p for p in puzzles[part["first"] - 1:expected_first - 1] if isinstance(p, dict)]
        counts = Counter((p.get("heat"), p.get("size")) for p in ps)
        table = part.get("per")
        if table is not None and not (
                isinstance(table, list) and len(table) == len(TIERS)
                and all(isinstance(r, list) and len(r) == len(MP_SIZES) for r in table)):
            errors.append(f"{name}: 'per' must list a count for each heat and size")
            table = None
        for h in sorted(TIERS):
            for s in MP_SIZES:
                if table is not None:
                    want = table[h - 1][s - 1]
                else:
                    want = per if per is not None else max(counts.values(), default=0)
                if counts[(h, s)] != want:
                    where = f"heat {h} size {s}" if single else f"{name} heat {h} size {s}"
                    errors.append(f"{where}: {counts[(h, s)]} puzzles, expected {want}")
        order = [(p.get("heat"), p.get("size")) for p in ps]
        if order != sorted(order, key=lambda x: (x[0] or 0, x[1] or 0)):
            errors.append(f"{name} is not ordered by heat, then size")
    if expected_first - 1 != len(puzzles):
        errors.append(f"parts cover {expected_first - 1} puzzles but there are {len(puzzles)}")
    return errors


def validate_file(path: str, campaign_path: str | None = None, per: int | None = None,
                  lex: Lexicon | None = None) -> tuple[str, list[str], int]:
    lex = lex or load()
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if "chapters" in data:
        return "campaign", validate_campaign(data, lex), len(data.get("puzzles", []))
    campaign = None
    if campaign_path:
        with open(campaign_path, encoding="utf-8") as f:
            campaign = json.load(f)
    return "multiplayer bank", validate_mp(data, lex, campaign, per), len(data.get("puzzles", []))


def main(args) -> int:
    campaign = args.campaign
    if (campaign is None and os.path.exists(paths.MP_BANK_JSON)
            and os.path.exists(paths.CAMPAIGN_JSON)
            and os.path.samefile(args.file, paths.MP_BANK_JSON)):
        campaign = paths.CAMPAIGN_JSON  # the real bank must not reuse campaign letters
    kind, errors, n = validate_file(args.file, campaign, args.per)
    if errors:
        for e in errors[:200]:
            print(f"ERROR {e}")
        if len(errors) > 200:
            print(f"... and {len(errors) - 200} more")
        print(f"{args.file}: {kind} with {n} puzzles: {len(errors)} error(s)")
        return 1
    print(f"{args.file}: {kind} with {n} puzzles: OK")
    return 0
