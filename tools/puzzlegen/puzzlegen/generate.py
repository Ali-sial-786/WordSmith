"""Build one puzzle: seed word -> answers -> crossword layout -> JSON object."""

from __future__ import annotations

import itertools
import random
from dataclasses import dataclass, field

from . import layout as layout_mod
from .rules import check_puzzle
from .tiers import TIERS, Tier
from .words import Lexicon, signature


@dataclass
class Spec:
    """What one puzzle slot asks for."""

    heat: int
    length: int  # anvil letters
    target: int  # grid words wanted
    min_words: int  # fewer than this => reject the seed
    answer_level: int
    common_level: int
    max_rare: int
    seed_level: int
    exact: bool = False  # tutorial: exactly `target` words
    max_answer_len: int = 8
    progress: float = 0.5  # 0..1 position in the tier's ramp


def spec_for(heat: int, progress: float, rng: random.Random, length: int | None = None,
             target: int | None = None, extra_words: int = 0, min_words: int | None = None,
             answer_level: int | None = None) -> Spec:
    """A Spec for heat tier `heat` at `progress` (0 = easiest, 1 = hardest)."""
    t: Tier = TIERS[heat]
    lo, hi = t.min_words + extra_words, t.max_words + extra_words
    if length is None:
        if len(t.lengths) == 1:
            length = t.lengths[0]
        else:
            # Longer anvils become more likely as the tier ramps up.
            p_long = 0.15 + 0.7 * progress
            length = t.lengths[1] if rng.random() < p_long else t.lengths[0]
    if target is None:
        k = lo + (hi - lo) * progress + rng.uniform(-0.8, 0.8)
        target = max(lo, min(hi, round(k)))
    # Early in a tier, keep the seed and the grid very common.
    seed_level = t.seed_level
    if progress < 0.3:
        seed_level = min(seed_level, {1: 10}.get(heat, seed_level))
    max_rare = round(t.max_rare * min(1.0, 0.25 + progress))
    common_level = t.common_level
    if answer_level and answer_level > t.answer_level:
        # A widened pool (multiplayer sizes that need more words): the extra
        # words count as ordinary, not rare.
        common_level = max(common_level, answer_level)
    return Spec(
        heat=heat, length=length, target=target,
        min_words=lo if min_words is None else min_words,
        answer_level=answer_level or t.answer_level,
        common_level=common_level, max_rare=max_rare,
        seed_level=seed_level, progress=progress,
    )


# Rarity points by SCOWL level, used for priorities and difficulty.
RARITY = {10: 0, 20: 1, 35: 2, 40: 3, 50: 4, 55: 5, 60: 6, 70: 7}
LENGTH_PRIORITY = {3: 0.0, 4: 1.2, 5: 2.0, 6: 2.6, 7: 3.0, 8: 3.3}
PRIORITY_RARITY = {10: 0.0, 20: 0.5, 35: 1.2, 40: 2.5, 50: 3.5, 55: 4.5, 60: 5.5}
COMMON_WEIGHT = {1: 1.0, 2: 1.0, 3: 1.0, 4: 0.8, 5: 0.8, 6: 0.6}
# Randomized layout restarts: big grids benefit most from more tries.
RESTARTS = {1: 16, 2: 20, 3: 24, 4: 24, 5: 32, 6: 40}


def rarity(lex: Lexicon, w: str) -> int:
    return RARITY.get(lex.level(w), 8)


@dataclass
class Result:
    puzzle: dict | None
    reason: str = ""
    difficulty: float = 0.0
    seed: str = ""
    info: dict = field(default_factory=dict)


def answer_candidates(lex: Lexicon, letters: str, spec: Spec) -> list[str]:
    return [
        w for w in lex.subwords(letters)
        if len(w) <= spec.max_answer_len and lex.is_answer(w, spec.answer_level)
    ]


def shuffle_letters(letters: str, avoid: set[str], rng: random.Random) -> str:
    """A shuffle of `letters` that doesn't spell any word in `avoid`.

    It also tries to avoid spelling one around the ring (any rotation, either
    direction), because the anvil shows the tiles in a circle.
    """
    chars = list(letters)
    n = len(chars)

    def ring_ok(s: str) -> bool:
        for r in range(n):
            rot = s[r:] + s[:r]
            if rot in avoid or rot[::-1] in avoid:
                return False
        return True

    for _ in range(200):
        rng.shuffle(chars)
        s = "".join(chars)
        if ring_ok(s):
            return s
    perms = sorted({"".join(p) for p in itertools.permutations(letters)})
    rng.shuffle(perms)
    for s in perms:
        if ring_ok(s):
            return s
    for s in perms:
        if s not in avoid:
            return s
    raise ValueError(f"every arrangement of {letters} spells a word")


def difficulty(lex: Lexicon, letters: str, words: list[str], cols: int, rows: int) -> float:
    """Rough difficulty for ordering: bigger anvils, more and rarer words, more cells."""
    n = len(words)
    rar = sum(rarity(lex, w) for w in words) / n
    max_rar = max(rarity(lex, w) for w in words)
    longest = max(len(w) for w in words)
    long_words = sum(1 for w in words if len(w) >= 5)
    cells = sum(len(w) for w in words)  # letters to find, counting crossings twice
    return round(
        8.0 * (len(letters) - 4)
        + 2.2 * n
        + 4.0 * rar + 1.0 * max_rar
        + 1.5 * (longest - 4)
        + 0.8 * long_words
        + 0.15 * cells
        + 0.05 * cols * rows,
        2,
    )


def make_puzzle(lex: Lexicon, seed_word: str, spec: Spec, rng: random.Random,
                opts: layout_mod.LayoutOptions | None = None) -> Result:
    """Try to build a puzzle around `seed_word`. puzzle is None on rejection."""
    letters = seed_word
    answers = answer_candidates(lex, letters, spec)
    if seed_word not in answers:
        return Result(None, "seed is not an answer word", seed=seed_word)
    if len(answers) < spec.min_words:
        return Result(None, "too few answer words", seed=seed_word)

    # Priorities: longer and more common words first (commonness matters more
    # in the low tiers); the layout adds a little noise for variety.
    common_weight = COMMON_WEIGHT[spec.heat]
    priority = {}
    for w in answers:
        priority[w] = (LENGTH_PRIORITY[len(w)]
                       - common_weight * PRIORITY_RARITY.get(lex.level(w), 6.5))

    # Cap the number of rarer words a grid may use.
    rare = [w for w in answers if lex.level(w) > spec.common_level and w != seed_word]
    rare.sort(key=lambda w: -(priority[w] + rng.random()))
    allowed_rare = set(rare[: spec.max_rare])
    pool = [w for w in answers if w != seed_word and (w in allowed_rare or w not in rare)]

    if spec.exact:
        # Tutorial: short, very common words only.
        pool = [w for w in pool if len(w) <= 4]
    opts = opts or layout_mod.LayoutOptions(restarts=RESTARTS[spec.heat])
    lay = layout_mod.build(seed_word, pool, priority, spec.target, rng, opts)
    placed = lay.words if lay else [seed_word]
    if len(placed) < spec.min_words:
        return Result(None, "layout fit too few words", seed=seed_word,
                      info={"placed": len(placed)})
    if spec.exact and len(placed) != spec.target:
        return Result(None, "tutorial needs an exact word count", seed=seed_word)

    grid = lay.grid
    words = [
        {"w": w.upper(), "x": x, "y": y, "d": d}
        for (w, x, y, d) in grid.cropped()
    ]
    grid_set = {w for w in placed}
    subs = lex.subwords(letters)
    bonus = sorted(w.upper() for w in subs if w not in grid_set)
    full = {w for w in subs if len(w) == len(letters)}
    shuffled = shuffle_letters(letters, full, rng).upper()
    cols, rows = grid.width, grid.height
    puzzle = {
        "id": "",
        "letters": shuffled,
        "heat": spec.heat,
        "cols": cols,
        "rows": rows,
        "words": words,
        "bonus": bonus,
    }
    # Independent re-check of every format rule; a failure here is a bug in
    # the layout code, so the seed is rejected (and counted) rather than kept.
    errors = check_puzzle(dict(puzzle, id="c-0000"), lex)
    if errors:
        return Result(None, "failed rule check", seed=seed_word, info={"errors": errors})
    diff = difficulty(lex, letters, placed, cols, rows)
    return Result(puzzle, "", diff, seed_word, info={
        "placed": len(placed), "target": spec.target, "candidates": len(answers),
        "crossings": grid.crossings(),
    })


class SeedPool:
    """Seed words grouped by letter multiset, per (length, max level)."""

    def __init__(self, lex: Lexicon):
        self.lex = lex
        self._cache: dict[tuple[int, int], list[str]] = {}
        self._by_len: dict[int, list[str]] = {}
        for w in sorted(lex.accepted):
            self._by_len.setdefault(len(w), []).append(w)

    def seeds(self, length: int, max_level: int) -> list[str]:
        """One seed per signature: its most common answer word (sorted)."""
        key = (length, max_level)
        if key not in self._cache:
            best: dict[str, str] = {}
            for w in self._by_len.get(length, ()):
                if not self.lex.is_answer(w, max_level):
                    continue
                sig = signature(w)
                cur = best.get(sig)
                if cur is None or (self.lex.level(w), w) < (self.lex.level(cur), cur):
                    best[sig] = w
            self._cache[key] = sorted(best.values())
        return self._cache[key]


def generate_slot(lex: Lexicon, pool: SeedPool, spec: Spec, used: set[str],
                  rng: random.Random, stats: dict, max_tries: int = 400,
                  opts: layout_mod.LayoutOptions | None = None,
                  rich_first: bool = False) -> Result:
    """Pick an unused seed for `spec` and build a puzzle, retrying on rejection.

    Seeds are tried in random order, or with `rich_first` those with the most
    answer words first (for slots that need more words than most anvils have).
    """
    seeds = [s for s in pool.seeds(spec.length, spec.seed_level) if signature(s) not in used]
    rng.shuffle(seeds)
    if rich_first:
        seeds.sort(key=lambda s: -len(answer_candidates(lex, s, spec)))
    tries = 0
    for s in seeds:
        answers = answer_candidates(lex, s, spec)
        # Cheap pre-filter, not counted as a rejection. Big grids need spare
        # words: only some of the candidates ever fit.
        margin = spec.min_words // 3 if spec.min_words >= 12 else 0
        if len(answers) < spec.min_words + margin:
            continue
        tries += 1
        res = make_puzzle(lex, s, spec, rng, opts)
        if res.puzzle is not None:
            used.add(signature(s))
            return res
        stats[res.reason] = stats.get(res.reason, 0) + 1
        if tries >= max_tries:
            break
    raise RuntimeError(
        f"no seed found for heat {spec.heat}, {spec.length} letters, "
        f"{spec.min_words}+ words (tried {tries})")
