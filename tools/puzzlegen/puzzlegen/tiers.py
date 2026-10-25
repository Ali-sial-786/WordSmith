"""Heat tiers (docs/DESIGN.md section 5) and campaign chapters (section 2.4)."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Tier:
    heat: int
    name: str
    lengths: tuple[int, ...]  # anvil letter counts
    min_words: int  # grid answers
    max_words: int
    answer_q: float  # answers have at least this quality (quality.py) ...
    answer_level: int  # ... and SCOWL level <= this
    common_q: float  # answers below this quality count as "rare" ...
    max_rare: int  # ... and at most this many rare words go in a grid
    seed_q: float  # the all-letter seed word has at least this quality


# Quality is on the Zipf scale (quality.py): about 4.2+ is what SCOWL calls
# "very common" (level 10), 3.4 is like level 20 and 2.0 like level 35.
# Answers must also be ENABLE words, not in data/answer_exclude.txt, and at
# most SCOWL 50 (55/60 were tried for the top tiers but were mostly unfair:
# GITS, LIDO, OPES, DACE). See words.Lexicon.is_answer. Answers below
# `common_q` are "rare": at most `max_rare` of them per grid.
TIERS = {
    1: Tier(1, "Ember", (4,), 3, 6, answer_q=3.4, answer_level=35, common_q=3.4, max_rare=0,
            seed_q=3.8),
    2: Tier(2, "Dull Red", (5,), 5, 9, answer_q=2.6, answer_level=35, common_q=3.0, max_rare=3,
            seed_q=3.6),
    3: Tier(3, "Cherry Red", (6,), 9, 14, answer_q=2.6, answer_level=35, common_q=3.0,
            max_rare=4, seed_q=3.4),
    4: Tier(4, "Orange", (6, 7), 11, 16, answer_q=2.3, answer_level=40, common_q=2.9, max_rare=3,
            seed_q=3.3),
    5: Tier(5, "Yellow", (7,), 13, 19, answer_q=2.0, answer_level=50, common_q=2.8, max_rare=4,
            seed_q=3.2),
    6: Tier(6, "White Heat", (7, 8), 15, 22, answer_q=1.9, answer_level=50, common_q=2.6,
            max_rare=5, seed_q=3.1),
}

# Leftovers: good words left in the Scrap Bin (bonus list) that could have
# been grid answers (lex.is_answer at the tier's SCOWL cap, whatever the
# tier's quality floor). Players notice these: ARE, FAR, RED, DARE left
# out of a FRAMED grid. Per puzzle, counted at three quality levels
# (metrics.leftovers): GREAT_Q (very common), NICE_Q (common) and FAIR_Q.
# Anvils are chosen so that, per heat, at most LEFTOVER_MAX[q] are left in
# any puzzle and LEFTOVER_AVG[q][heat] on average (FAIR_Q is only reported).
GREAT_Q = 4.0
NICE_Q = 3.0
FAIR_Q = 2.5
LEFTOVER_MAX = {GREAT_Q: 1, NICE_Q: 6}
LEFTOVER_AVG = {GREAT_Q: {h: 0.3 for h in range(1, 7)},
                NICE_Q: {1: 2.5, 2: 2.5, 3: 2.5, 4: 3.5, 5: 3.5, 6: 3.5}}

# Plain inflections (plurals, -ed, -ing, -est of a shorter word: LASTS,
# SALTS) allowed per grid, as a share of its target word count (at least 1).
# The seed word is never a plural.
INFLECTION_SHARE = 0.3

HEAT_NAMES = {t.heat: t.name for t in TIERS.values()}


@dataclass(frozen=True)
class Chapter:
    id: str
    name: str
    count: int
    heat_from: int
    heat_to: int


CHAPTERS = (
    Chapter("tin", "Tin", 40, 1, 1),
    Chapter("copper", "Copper", 50, 1, 2),
    Chapter("bronze", "Bronze", 60, 2, 2),
    Chapter("iron", "Iron", 60, 3, 3),
    Chapter("steel", "Steel", 70, 3, 4),
    Chapter("silver", "Silver", 70, 4, 4),
    Chapter("gold", "Gold", 80, 5, 5),
    Chapter("damascus", "Damascus", 80, 5, 6),
    Chapter("starmetal", "Starmetal", 90, 6, 6),
)

CAMPAIGN_TOTAL = sum(c.count for c in CHAPTERS)

# The first stages teach the game: 4 letters and exactly 3 short, very
# common words (quality like SCOWL level 10).
TUTORIAL_STAGES = 3
TUTORIAL_WORDS = 3
TUTORIAL_Q = 4.2


def chapter_heats(ch: Chapter) -> list[int]:
    """Heat of each stage in a chapter: an a->b chapter is split in half."""
    if ch.heat_from == ch.heat_to:
        return [ch.heat_from] * ch.count
    first = ch.count // 2
    return [ch.heat_from] * first + [ch.heat_to] * (ch.count - first)


# Multiplayer bank: size s (players) wants the tier's word count plus
# 2*(s-1) grid words. MP_SIZE_MIN is the minimum the bank guarantees. It is
# min_words + 2*(s-1) except where 4-8 letter anvils can't support it (see
# README): Ember's 4-letter anvils rarely make more than 6-7 common words.
MP_SIZES = (1, 2, 3, 4)


# A 10x10 grid holds about 22-24 words at most (fewer with 7-8 letter words),
# so no puzzle wants more than GRID_MAX_WORDS, and the bank guarantees at most
# MP_MIN_CAP.
GRID_MAX_WORDS = 24
MP_MIN_CAP = 20


def mp_target(heat: int, size: int) -> tuple[int, int]:
    t = TIERS[heat]
    extra = 2 * (size - 1)
    return t.min_words + extra, min(GRID_MAX_WORDS, t.max_words + extra)


MP_SIZE_MIN = {
    (h, s): min(MP_MIN_CAP, mp_target(h, s)[0]) for h in TIERS for s in MP_SIZES
}
# Ember: 4-letter anvils. Only a few dozen 4-letter words make 7+ common
# words that also fit a crossword, so sizes 3 and 4 are capped lower.
MP_SIZE_MIN[(1, 3)] = 6
MP_SIZE_MIN[(1, 4)] = 6

# Answer and seed pools may be widened for bigger multiplayer sizes so that
# enough words exist (Ember only). The 4-letter anvils that make 6+ words
# that interlock are scarce (about 120 not in the campaign), so co-op Ember
# takes any answer SCOWL calls common (<= 35) whatever its quality, as the
# old SCOWL-only pools did, and plural seeds too (generate.spec_for
# `widened`). The layout still prefers the best words.
MP_ANSWER_Q = {(1, 2): None, (1, 3): None, (1, 4): None}
MP_SEED_Q = {(1, 2): 2.0, (1, 3): 2.0, (1, 4): 2.0}

# A part added to the bank by `grow` (README "Growing the bank"). Versus
# (size 1) needs the most variety: 210 more per heat makes 250 with the
# first part's 40. Co-op sizes get 60 more (100 in all), except Ember: about
# 90 unused 4-letter anvils make 5+ common words and only 30 make 6+, so
# its sizes 2-4 get 40, 12 and 12. Ember size 1 also draws from common
# words (as Dull Red): the first part and the campaign used most of the
# very common 4-letter anvils.
MP_GROW_PER = {(h, s): 210 if s == 1 else 60 for h in TIERS for s in MP_SIZES}
MP_GROW_PER.update({(1, 2): 40, (1, 3): 12, (1, 4): 12})
MP_GROW_ANSWER_Q = {**MP_ANSWER_Q, (1, 1): 2.6}
MP_GROW_SEED_Q = {**MP_SEED_Q, (1, 1): 3.0}
