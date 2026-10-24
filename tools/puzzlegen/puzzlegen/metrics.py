"""Answer-quality metrics for a campaign file or bank (`stats` prints them).

Per puzzle, with q = word quality (quality.py) and the grid's worst answer w:

- inversions: bonus words that could be answers (ENABLE, not excluded,
  SCOWL <= 50) and are clearly better than w: q >= q(w) + INVERSION_MARGIN.
  The grid should hold the best words, so this should be small; it can't be
  zero everywhere because not every word fits the crossword.
- missed common: bonus words that could be answers with q >= COMMON_Q (very
  common words like DIG, TAG, GAIN) left out of the grid.
- inflections: grid answers that are plain plurals / -ed / -ing / -est forms
  of a shorter word (LASTS, SALTS).
- zipf: word frequency of the grid answers (data/freq.tsv), mean and min.
"""

from __future__ import annotations

INVERSION_MARGIN = 0.5
COMMON_Q = 3.8
ANSWER_LEVEL = 50  # the widest SCOWL cap any tier uses


def puzzle_metrics(p: dict, lex) -> dict:
    grid = [w["w"].lower() for w in p["words"]]
    bonus = [w.lower() for w in p["bonus"]]
    qs = [lex.quality(w) for w in grid]
    worst = min(qs)
    eligible = [w for w in bonus if lex.is_answer(w, ANSWER_LEVEL)]
    zipfs = [lex.freq.get(w, 0.0) for w in grid]
    return {
        "words": len(grid),
        "inversions": sum(1 for w in eligible if lex.quality(w) >= worst + INVERSION_MARGIN),
        "missed_common": sum(1 for w in eligible if lex.quality(w) >= COMMON_Q),
        "inflections": sum(1 for w in grid if lex.inflection(w)),
        "plurals": sum(1 for w in grid if (lex.inflection(w) or ("",))[0] == "s"),
        "undefined": sum(1 for w in grid if lex.defined is not None and w not in lex.defined),
        "mean_q": sum(qs) / len(qs),
        "min_q": worst,
        "mean_zipf": sum(zipfs) / len(zipfs),
        "min_zipf": min(zipfs),
    }


def summary(puzzles: list[dict], lex) -> dict:
    """Totals and averages of puzzle_metrics over `puzzles`."""
    ms = [puzzle_metrics(p, lex) for p in puzzles]
    n = len(ms)
    words = sum(m["words"] for m in ms)
    return {
        "puzzles": n,
        "inversions/puzzle": sum(m["inversions"] for m in ms) / n,
        "puzzles with inversions": sum(1 for m in ms if m["inversions"]) / n,
        "missed common/puzzle": sum(m["missed_common"] for m in ms) / n,
        "inflection share": sum(m["inflections"] for m in ms) / words,
        "plural share": sum(m["plurals"] for m in ms) / words,
        "no meaning share": sum(m["undefined"] for m in ms) / words,
        "mean zipf": sum(m["mean_zipf"] * m["words"] for m in ms) / words,
        "mean min zipf": sum(m["min_zipf"] for m in ms) / n,
        "mean quality": sum(m["mean_q"] * m["words"] for m in ms) / words,
        "mean min quality": sum(m["min_q"] for m in ms) / n,
    }


SUMMARY_COLUMNS = (
    ("inv/pz", "inversions/puzzle", "{:.2f}"),
    ("pz inv", "puzzles with inversions", "{:.0%}"),
    ("missed", "missed common/puzzle", "{:.2f}"),
    ("infl", "inflection share", "{:.0%}"),
    ("plural", "plural share", "{:.0%}"),
    ("no def", "no meaning share", "{:.1%}"),
    ("zipf", "mean zipf", "{:.2f}"),
    ("min zipf", "mean min zipf", "{:.2f}"),
    ("q", "mean quality", "{:.2f}"),
    ("min q", "mean min quality", "{:.2f}"),
)


def summary_row(name: str, puzzles: list[dict], lex) -> tuple:
    s = summary(puzzles, lex)
    return (name, s["puzzles"]) + tuple(fmt.format(s[key]) for _, key, fmt in SUMMARY_COLUMNS)


SUMMARY_HEADER = ("group", "n") + tuple(c for c, _, _ in SUMMARY_COLUMNS)
