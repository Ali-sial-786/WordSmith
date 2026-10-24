"""Build one puzzle: seed word -> answers -> crossword layout -> JSON object."""

from __future__ import annotations

import itertools
import math
import random
from collections import Counter
from dataclasses import dataclass, field

from . import layout as layout_mod
from .rules import check_puzzle
from .tiers import INFLECTION_SHARE, TIERS, Tier
from .words import Lexicon, signature


@dataclass
class Spec:
    """What one puzzle slot asks for."""

    heat: int
    length: int  # anvil letters
    target: int  # grid words wanted
    min_words: int  # fewer than this => reject the seed
    answer_q: float | None  # answers have at least this quality (None: any) ...
    answer_level: int  # ... and SCOWL level <= this
    common_q: float  # answers below this quality are "rare" ...
    max_rare: int  # ... and at most this many go in a grid
    seed_q: float | None
    max_inflections: int = 1
    plural_seed: bool = False  # the seed may be a plural (only where anvils are scarce)
    exact: bool = False  # tutorial: exactly `target` words
    max_answer_len: int = 8
    progress: float = 0.5  # 0..1 position in the tier's ramp


def spec_for(heat: int, progress: float, rng: random.Random, length: int | None = None,
             target: int | None = None, extra_words: int = 0, min_words: int | None = None,
             answer_q: float | None = None, widened: bool = False) -> Spec:
    """A Spec for heat tier `heat` at `progress` (0 = easiest, 1 = hardest).

    `widened` (multiplayer sizes that need more words than the tier's anvils
    have): answers need only `answer_q` and all count as ordinary rather
    than rare. With `answer_q` None any quality within the SCOWL cap will do,
    the seed may be a plural and inflections aren't capped.
    """
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
    # Early in Ember, keep the seed very common.
    seed_q = t.seed_q
    if progress < 0.3 and heat == 1:
        seed_q = max(seed_q, EARLY_EMBER_SEED_Q)
    # Multiplayer sizes' extra words may all be rare ones.
    max_rare = round(t.max_rare * min(1.0, 0.25 + progress)) + extra_words
    common_q = t.common_q
    max_inflections = max(1, round(INFLECTION_SHARE * target))
    scarce = widened and answer_q is None
    if widened:
        common_q = min(common_q, answer_q if answer_q is not None else float("-inf"))
    if scarce:
        max_inflections = target
    return Spec(
        heat=heat, length=length, target=target,
        min_words=lo if min_words is None else min_words,
        answer_q=answer_q if widened else t.answer_q,
        answer_level=t.answer_level,
        common_q=common_q, max_rare=max_rare, seed_q=seed_q,
        max_inflections=max_inflections, plural_seed=scarce, progress=progress,
    )


EARLY_EMBER_SEED_Q = 4.2
# Priority of a word for the layout: quality dominates, length adds a little
# (a long word is more satisfying to find than a short one of the same
# quality).
LENGTH_PRIORITY = {3: 0.0, 4: 0.8, 5: 1.6, 6: 2.2, 7: 2.7, 8: 3.0}
QUALITY_WEIGHT = 2.0
# Randomized layout restarts: big grids benefit most from more tries.
RESTARTS = {1: 16, 2: 20, 3: 24, 4: 24, 5: 32, 6: 40}
# The layout first gets only the best words: the target count plus this
# share (at least POOL_EXTRA_MIN more), and more of the ranked list only
# when that can't make a big enough grid.
POOL_EXTRA = 0.3
POOL_EXTRA_MIN = 2
# A grid may come out this many words short of its target (never below the
# minimum) when that keeps worse words out.
TARGET_SLACK = {1: 0, 2: 0, 3: 1, 4: 1, 5: 1, 6: 2}
# Priority lost per doubling of a word's uses so far (see priority_of).
REPEAT_WEIGHT = 0.3


def rarity(lex: Lexicon, w: str) -> float:
    """Rarity points for difficulty: 0 for very common words, about 4 at quality 2.3."""
    return max(0.0, 4.8 - lex.quality(w)) * 1.6


def priority_of(lex: Lexicon, w: str, usage: Counter | None = None) -> float:
    """Layout priority; `usage` (grid answers so far in this campaign or bank) makes
    a word used often a little less likely, so the same few words don't fill every grid."""
    p = QUALITY_WEIGHT * lex.quality(w) + LENGTH_PRIORITY[len(w)]
    if usage:
        p -= REPEAT_WEIGHT * math.log2(1 + usage[w])
    return p


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
        if len(w) <= spec.max_answer_len and lex.is_answer(w, spec.answer_level, spec.answer_q)
    ]


def is_plural(lex: Lexicon, w: str) -> bool:
    inf = lex.inflection(w)
    return inf is not None and inf[0] == "s"


def answer_pool(lex: Lexicon, seed_word: str, answers: list[str], spec: Spec,
                priority: dict[str, float], rng: random.Random) -> list[str]:
    """The seed's other answers, best first, within the rare and inflection caps."""
    ranked = sorted((w for w in answers if w != seed_word), key=lambda w: (-priority[w], w))
    # Rare words: the best few, with a little noise for variety.
    rare = [w for w in ranked if lex.quality(w) < spec.common_q]
    rare.sort(key=lambda w: -(priority[w] + rng.random() * 0.5))
    drop = set(rare[spec.max_rare:])
    # Inflections: the best few (the seed counts if it is one).
    infl = [w for w in ranked if w not in drop and lex.inflection(w)]
    room = spec.max_inflections - (1 if lex.inflection(seed_word) else 0)
    drop |= set(infl[max(0, room):])
    return [w for w in ranked if w not in drop]


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


def quality_layout(seed_word: str, ranked: list[str], priority: dict[str, float], spec: Spec,
                   rng: random.Random, opts: layout_mod.LayoutOptions):
    """The layout with the best words that still makes a big enough grid.

    The layout first gets only the top of the ranked pool, a few more words
    than the target. When that can't reach the target (less the tier's
    slack), more words join, best first, until it can or the pool is used
    up. So a worse word only goes in when no layout of better ones exists
    (as far as the randomized search finds).
    """
    need = spec.target if spec.exact else max(spec.min_words,
                                              spec.target - TARGET_SLACK[spec.heat])
    extra = max(POOL_EXTRA_MIN, round(POOL_EXTRA * spec.target))
    k = min(len(ranked), spec.target - 1 + extra)
    best = None
    while True:
        lay = layout_mod.build(seed_word, ranked[:k], priority, spec.target, rng, opts)
        if lay is not None and (best is None or len(lay.words) > len(best.words)):
            best = lay
        if (best is not None and len(best.words) >= need) or k >= len(ranked):
            return best
        k = min(len(ranked), k + max(2, extra // 2 + 1))


def make_puzzle(lex: Lexicon, seed_word: str, spec: Spec, rng: random.Random,
                opts: layout_mod.LayoutOptions | None = None,
                usage: Counter | None = None) -> Result:
    """Try to build a puzzle around `seed_word`. puzzle is None on rejection."""
    letters = seed_word
    answers = answer_candidates(lex, letters, spec)
    if seed_word not in answers:
        return Result(None, "seed is not an answer word", seed=seed_word)
    if len(answers) < spec.min_words:
        return Result(None, "too few answer words", seed=seed_word)

    priority = {w: priority_of(lex, w, usage) for w in answers}
    pool = answer_pool(lex, seed_word, answers, spec, priority, rng)
    if spec.exact:
        # Tutorial: short, very common words only.
        pool = [w for w in pool if len(w) <= 4]
    opts = opts or layout_mod.LayoutOptions(restarts=RESTARTS[spec.heat])
    lay = quality_layout(seed_word, pool, priority, spec, rng, opts)
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
    """Seed words grouped by letter multiset, per (length, SCOWL cap, min quality)."""

    def __init__(self, lex: Lexicon):
        self.lex = lex
        self._cache: dict[tuple[int, int], list[str]] = {}
        self._by_len: dict[int, list[str]] = {}
        for w in sorted(lex.accepted):
            self._by_len.setdefault(len(w), []).append(w)

    def seeds(self, length: int, max_level: int, min_q: float | None,
              plural_ok: bool = False) -> list[str]:
        """One seed per signature: its best answer word (sorted). Plurals aren't seeds
        unless `plural_ok`."""
        key = (length, max_level, min_q, plural_ok)
        if key not in self._cache:
            best: dict[str, str] = {}
            lex = self.lex
            for w in self._by_len.get(length, ()):
                if not lex.is_answer(w, max_level, min_q) or (is_plural(lex, w) and not plural_ok):
                    continue
                sig = signature(w)
                cur = best.get(sig)
                if cur is None or (-lex.quality(w), w) < (-lex.quality(cur), cur):
                    best[sig] = w
            self._cache[key] = sorted(best.values())
        return self._cache[key]


def generate_slot(lex: Lexicon, pool: SeedPool, spec: Spec, used: set[str],
                  rng: random.Random, stats: dict, max_tries: int = 400,
                  opts: layout_mod.LayoutOptions | None = None,
                  rich_first: bool = False, usage: Counter | None = None,
                  avoid: frozenset[str] = frozenset()) -> Result:
    """Pick an unused seed for `spec` and build a puzzle, retrying on rejection.

    `usage` counts the grid answers of the puzzles made so far (updated here),
    see priority_of.

    Seeds are tried in random order, or with `rich_first` those with the most
    answer words first (for slots that need more words than most anvils have).
    Seeds whose signature is in `avoid` are tried last.
    """
    seeds = [s for s in pool.seeds(spec.length, spec.answer_level, spec.seed_q,
                                   spec.plural_seed)
             if signature(s) not in used]
    rng.shuffle(seeds)
    if rich_first:
        seeds.sort(key=lambda s: -len(answer_candidates(lex, s, spec)))
    if avoid:
        seeds.sort(key=lambda s: signature(s) in avoid)
    tries = 0
    for s in seeds:
        answers = answer_candidates(lex, s, spec)
        # Cheap pre-filter, not counted as a rejection. Big grids need spare
        # words: only some of the candidates ever fit.
        margin = spec.min_words // 3 if spec.min_words >= 12 else 0
        if len(answers) < spec.min_words + margin:
            continue
        tries += 1
        res = make_puzzle(lex, s, spec, rng, opts, usage)
        if res.puzzle is not None:
            used.add(signature(s))
            if usage is not None:
                usage.update(w["w"].lower() for w in res.puzzle["words"])
            return res
        stats[res.reason] = stats.get(res.reason, 0) + 1
        if tries >= max_tries:
            break
    raise RuntimeError(
        f"no seed found for heat {spec.heat}, {spec.length} letters, "
        f"{spec.min_words}+ words (tried {tries})")
