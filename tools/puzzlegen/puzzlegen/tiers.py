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
    answer_level: int  # answers come from SCOWL <= this level
    common_level: int  # words above this level count as "rare" ...
    max_rare: int  # ... and at most this many rare words go in a grid
    seed_level: int  # the all-letter seed word comes from SCOWL <= this level


# SCOWL size levels: 10/20 "very common", 35 "common", 40 "less common",
# 50 "uncommon". (55/60 were tried for the top tiers but were mostly unfair:
# GITS, LIDO, OPES, DACE...) Answers must also be ENABLE words and not in
# data/answer_exclude.txt (see words.Lexicon.is_answer). Words above
# `common_level` are "rare": at most `max_rare` of them per grid.
TIERS = {
    1: Tier(1, "Ember", (4,), 3, 5, answer_level=20, common_level=20, max_rare=0, seed_level=20),
    2: Tier(2, "Dull Red", (5,), 5, 7, answer_level=35, common_level=20, max_rare=3, seed_level=20),
    3: Tier(3, "Cherry Red", (6,), 7, 10, answer_level=35, common_level=20, max_rare=5, seed_level=20),
    4: Tier(4, "Orange", (6, 7), 9, 12, answer_level=40, common_level=35, max_rare=2, seed_level=20),
    5: Tier(5, "Yellow", (7,), 11, 15, answer_level=50, common_level=35, max_rare=3, seed_level=20),
    6: Tier(6, "White Heat", (7, 8), 14, 20, answer_level=50, common_level=35, max_rare=4, seed_level=20),
}

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
# common words.
TUTORIAL_STAGES = 3
TUTORIAL_WORDS = 3
TUTORIAL_LEVEL = 10


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


def mp_target(heat: int, size: int) -> tuple[int, int]:
    t = TIERS[heat]
    extra = 2 * (size - 1)
    return t.min_words + extra, t.max_words + extra


MP_SIZE_MIN = {
    (h, s): mp_target(h, s)[0] for h in TIERS for s in MP_SIZES
}
# Ember: 4-letter anvils. Only a few dozen 4-letter words make 7+ common
# words that also fit a crossword, so sizes 3 and 4 are capped lower.
MP_SIZE_MIN[(1, 3)] = 6
MP_SIZE_MIN[(1, 4)] = 6

# Answer and seed pools may be widened for bigger multiplayer sizes so that
# enough words exist (Ember only: very common -> common).
MP_ANSWER_LEVEL = {(1, 2): 35, (1, 3): 35, (1, 4): 35}
MP_SEED_LEVEL = {(1, 2): 35, (1, 3): 35, (1, 4): 35}
