"""Word quality: how good a word is as a grid answer.

The score is on the Zipf scale (log10 of uses per billion words: 7 = "the",
5 = "salt", 3 = "gnat", 1 = very rare) so that its numbers mean something:

    quality = 0.7 * zipf + 0.3 * prior(SCOWL level) + length adjustment
              - inflection penalty, capped for words with no meaning

- zipf comes from data/freq.tsv (wordfreq, see the README). For words that
  are also names (data/name_senses.txt: MIKE, HARRY, AMAZON) the name's uses
  are counted too, so their zipf is capped a little above what their SCOWL
  level suggests.
- prior(SCOWL level) is the typical zipf of a word at that level. It steadies
  the frequency, which is noisy for short words (abbreviations, foreign
  words and names inflate DIN or NIT).
- Length: short words get more of those stray uses, and long words of the
  same frequency are better known, so 3-letter words lose a little and 7-8
  letter words gain a little.
- Above zipf 5 the frequency counts only 30%: every word up there is well
  known, and the very top (ARE, ONE, HIS, NOT) is mostly grammar words.
- Plain inflections of a shorter word (LASTS, SALTS: plurals and -s verbs;
  -ed, -ing, -est) lose points, less when the form is more common than its
  base (BUILDING, MORNING, PARENTS have a sense of their own).
- Words the app's dictionary (tools/dictgen) has no meaning for are function
  words (THE, ITS, NOR, PER): common but dull answers, so capped.
"""

from __future__ import annotations

import re

# Typical (median) zipf of the answer-eligible words at each SCOWL level.
PRIOR = {10: 4.6, 20: 3.9, 35: 2.8, 40: 2.4, 50: 2.0, 55: 1.8, 60: 1.5, 70: 1.1}
PRIOR_UNRANKED = 0.6
FREQ_WEIGHT = 0.7
NAME_SENSE_MARGIN = 0.6  # a name-sense word's zipf is capped at prior + this
LENGTH_ADJ = {3: -0.6, 4: -0.2, 5: 0.2, 6: 0.45, 7: 0.65, 8: 0.8}
UNDEFINED_CAP = 2.9
# Above zipf 5 a word is very common either way; the very top (ARE, ONE, HIS,
# NOT) is mostly grammar words, so frequency counts much less up there.
SOFT_CAP = 5.0
SOFT_CAP_SLOPE = 0.3

# Inflection kinds and their penalties (zipf points).
PLURAL, PAST, ING, EST = "s", "ed", "ing", "est"
INFLECTION_PENALTY = {PLURAL: 1.0, PAST: 0.5, ING: 0.4, EST: 0.6}
# A base must itself be a reasonably common word for a form to count.
BASE_MAX_LEVEL = 60
BASE_MIN_ZIPF = 3.0


def forms_of(base: str) -> dict[str, str]:
    """Regular inflected forms of `base` -> their kind (PLURAL, PAST, ING, EST)."""
    out: dict[str, str] = {base + "s": PLURAL}
    if re.search(r"(s|x|z|ch|sh|o)$", base):
        out[base + "es"] = PLURAL
    if re.search(r"[^aeiou]y$", base):
        out[base[:-1] + "ies"] = PLURAL
        out[base[:-1] + "ied"] = PAST
        out[base[:-1] + "iest"] = EST
    if base.endswith("e"):
        out[base + "d"] = PAST
        out[base[:-1] + "ing"] = ING
        out[base + "st"] = EST
    else:
        out[base + "ed"] = PAST
        out[base + "ing"] = ING
        out[base + "est"] = EST
    if re.search(r"[^aeiou][aeiou][bdgklmnprt]$", base):
        out[base + base[-1] + "ed"] = PAST
        out[base + base[-1] + "ing"] = ING
        out[base + base[-1] + "est"] = EST
    return out


def base_candidates(word: str) -> set[str]:
    """Strings `word` might be a regular form of (checked with forms_of)."""
    cands = {word[:-k] for k in (1, 2, 3, 4) if len(word) - k >= 3}
    cands |= {word[:-3] + "e", word[:-3] + "y", word[:-4] + "y", word[:-2] + "e"}
    return {b for b in cands if len(b) >= 3}


class Scorer:
    """Quality scores for one Lexicon (cached)."""

    def __init__(self, lex):
        self.lex = lex
        self._cache: dict[str, float] = {}
        self._infl: dict[str, tuple[str, str] | None] = {}

    def zipf(self, w: str) -> float:
        return self.lex.freq.get(w, 0.0)

    def prior(self, w: str) -> float:
        return PRIOR.get(self.lex.level(w), PRIOR_UNRANKED)

    def _is_base(self, b: str) -> bool:
        lex = self.lex
        return (b in lex.accepted and b not in lex.answer_exclude
                and (lex.level(b) <= BASE_MAX_LEVEL or self.zipf(b) >= BASE_MIN_ZIPF))

    def inflection(self, w: str) -> tuple[str, str] | None:
        """(kind, base) if `w` is a plain inflection of a shorter common word."""
        if w in self._infl:
            return self._infl[w]
        found = None
        if w not in self.lex.not_inflections:
            for b in sorted(base_candidates(w), key=lambda b: (-len(b), b)):
                kind = forms_of(b).get(w)
                if kind and self._is_base(b):
                    found = (kind, b)
                    break
        self._infl[w] = found
        return found

    def penalty(self, w: str) -> float:
        inf = self.inflection(w)
        if inf is None:
            return 0.0
        kind, base = inf
        p = INFLECTION_PENALTY[kind]
        gap = self.zipf(base) - self.zipf(w)
        if gap <= 0:
            p *= 0.4  # the form is the more common word: it has a sense of its own
        return p

    def familiarity(self, w: str) -> float:
        """How well known the word is, before the inflection penalty."""
        prior = self.prior(w)
        z = self.zipf(w)
        if w in self.lex.name_senses:
            z = min(z, prior + NAME_SENSE_MARGIN)
        if z > SOFT_CAP:
            z = SOFT_CAP + SOFT_CAP_SLOPE * (z - SOFT_CAP)
        return FREQ_WEIGHT * z + (1 - FREQ_WEIGHT) * prior + LENGTH_ADJ.get(len(w), 0.8)

    def quality(self, w: str) -> float:
        q = self._cache.get(w)
        if q is None:
            q = self.familiarity(w) - self.penalty(w)
            if self.lex.defined is not None and w not in self.lex.defined:
                q = min(q, UNDEFINED_CAP)
            q = round(q, 3)
            self._cache[w] = q
        return q
