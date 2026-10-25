"""Word lists, commonness levels and the sub-anagram finder.

Everything here reads only the committed files in data/, so it works offline.
Words are lowercase internally and uppercased when written to puzzles.
"""

from __future__ import annotations

import glob
import gzip
import itertools
import json
import os
from collections import Counter
from functools import lru_cache

from . import paths
from .quality import Scorer

MIN_WORD = 3
MAX_WORD = 8
UNRANKED = 99  # level used for accepted words that SCOWL (<= 70) doesn't rank


def signature(word: str) -> str:
    """Sorted letters: two words are anagrams iff their signatures match."""
    return "".join(sorted(word))


def can_make(word: str, letters: str) -> bool:
    """True if `word` can be spelled from `letters` respecting multiplicity."""
    have = Counter(letters)
    need = Counter(word)
    return all(have[c] >= n for c, n in need.items())


def sub_signatures(letters: str, min_len: int = MIN_WORD) -> list[str]:
    """Every distinct sorted sub-multiset of `letters` with >= min_len letters."""
    counts = sorted(Counter(letters).items())
    chars = [c for c, _ in counts]
    out = []
    for combo in itertools.product(*(range(n + 1) for _, n in counts)):
        if sum(combo) >= min_len:
            out.append("".join(c * k for c, k in zip(chars, combo)))
    return out


def _read_lines(path: str) -> list[str]:
    with open(path, encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]


def _read_tokens(path: str) -> set[str]:
    out = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            out.update(line.split("#", 1)[0].lower().split())
    return out


class Lexicon:
    """Accepted words, SCOWL levels, frequencies, blocklist, names, answer eligibility
    and word quality (quality.py)."""

    def __init__(self, accepted, levels, blocked, scowl_only=(), answer_exclude=(), names=(),
                 freq=None, name_senses=(), defined=None, not_inflections=()):
        self.blocked = frozenset(blocked)
        self.names = frozenset(names)  # data/names_exclude.txt: names, not words
        self.accepted = frozenset(w for w in accepted
                                  if w not in self.blocked and w not in self.names)
        self.levels = {w: lv for w, lv in levels.items() if w in self.accepted}
        self.scowl_only = frozenset(scowl_only)
        self.answer_exclude = frozenset(answer_exclude)
        self.freq = {w: z for w, z in (freq or {}).items() if w in self.accepted}
        self.name_senses = frozenset(name_senses)
        # Words the app's dictionary has a meaning for (None: not known, all count).
        self.defined = None if defined is None else frozenset(defined)
        self.not_inflections = frozenset(not_inflections)
        self.scorer = Scorer(self)
        index: dict[str, list[str]] = {}
        for w in sorted(self.accepted):
            index.setdefault(signature(w), []).append(w)
        self._index = index
        self._subs: dict[str, tuple[str, ...]] = {}

    # ------------------------------------------------------------ queries

    def level(self, word: str) -> int:
        return self.levels.get(word, UNRANKED)

    def is_answer(self, word: str, max_level: int, min_q: float | None = None) -> bool:
        """Can `word` be a grid answer in a pool capped at SCOWL `max_level` and,
        if `min_q` is given, with at least that quality?"""
        return (
            word in self.accepted
            and word not in self.scowl_only  # must also be an ENABLE word
            and word not in self.answer_exclude
            and self.level(word) <= max_level
            and (min_q is None or self.quality(word) >= min_q)
        )

    def quality(self, word: str) -> float:
        """Word quality on the Zipf scale (quality.py): higher is a better answer."""
        return self.scorer.quality(word)

    def inflection(self, word: str):
        """(kind, base) if `word` is a plain inflection of a shorter word, else None."""
        return self.scorer.inflection(word)

    def anagrams(self, sig: str) -> list[str]:
        return self._index.get(sig, [])

    def subwords(self, letters: str) -> list[str]:
        """All accepted words (3+ letters) formable from `letters`, sorted (a new list)."""
        key = signature(letters.lower())
        got = self._subs.get(key)
        if got is None:
            out = []
            for sig in sub_signatures(key):
                out.extend(self._index.get(sig, ()))
            got = self._subs[key] = tuple(sorted(out))
        return list(got)

    def full_words(self, letters: str) -> list[str]:
        """Accepted words that use every one of `letters`."""
        return list(self._index.get(signature(letters.lower()), ()))


@lru_cache(maxsize=1)
def load() -> Lexicon:
    accepted = _read_lines(paths.ACCEPTED)
    levels = {}
    for line in _read_lines(paths.SCOWL_LEVELS):
        w, lv = line.split("\t")
        levels[w] = int(lv)
    blocked = _read_lines(paths.BLOCKLIST)
    scowl_only = _read_lines(paths.SCOWL_ONLY)
    exclude = _read_tokens(paths.ANSWER_EXCLUDE)
    names = _read_lines(paths.NAMES_EXCLUDE)
    freq = {}
    for line in _read_lines(paths.FREQ):
        w, z = line.split("\t")
        freq[w] = float(z)
    return Lexicon(accepted, levels, blocked, scowl_only, exclude, names, freq=freq,
                   name_senses=_read_lines(paths.NAME_SENSES), defined=read_defined(),
                   not_inflections=_read_tokens(paths.NOT_INFLECTIONS))


def read_defined(dict_dir: str = paths.DICT_DIR) -> set[str] | None:
    """Words the app's dictionary (app/assets/dict, built by tools/dictgen) can show a
    meaning for, or None if it isn't there."""
    files = sorted(glob.glob(os.path.join(dict_dir, "?.json.gz")))
    if not files:
        return None
    out: set[str] = set()
    for f in files:
        with gzip.open(f, "rt", encoding="utf-8") as fh:
            data = json.load(fh)
        out.update(data["entries"])
        out.update(data["forms"])
    return out
