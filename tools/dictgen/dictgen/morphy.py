"""WordNet's morphological rules ("morphy"), used to find the base form of an inflected word.

The suffix rules are those of WordNet's morph.c, plus noun "-oes"
(potatoes), y -> i before -ed/-er/-est (partied, chalkier) and, for verb
-ed/-ing and adjective -er/-est, a doubled final consonant (hummed -> hum,
fatter -> fat). Irregular forms come from the source's exception lists
(OEWN's <Form> elements), which the caller tries first. This module only
proposes candidates; the caller keeps the ones that are real lemmas.
"""

from __future__ import annotations

RULES = {
    "n": [("s", ""), ("ses", "s"), ("xes", "x"), ("zes", "z"), ("ches", "ch"), ("shes", "sh"),
          ("men", "man"), ("ies", "y"), ("oes", "o")],
    "v": [("s", ""), ("ies", "y"), ("es", "e"), ("es", ""), ("ed", "e"), ("ed", ""),
          ("ied", "y"), ("ing", "e"), ("ing", "")],
    "a": [("er", ""), ("est", ""), ("er", "e"), ("est", "e"), ("ier", "y"), ("iest", "y")],
    "r": [],
}
POS_ORDER = ("n", "v", "a", "r")
DOUBLING = {"v": ("ed", "ing"), "a": ("er", "est")}
VOWELS = frozenset("aeiouy")


def rule_bases(word: str, pos: str) -> list[str]:
    """Candidate base forms of `word` as `pos`, in rule order, without duplicates."""
    out: list[str] = []
    for suffix, repl in RULES[pos]:
        if not word.endswith(suffix) or len(word) <= len(suffix):
            continue
        if pos == "n" and suffix == "s" and word.endswith("ss"):
            continue  # glass, moss: not plurals
        stem = word[: -len(suffix)]
        cands = [stem + repl]
        if (repl == "" and suffix in DOUBLING.get(pos, ()) and len(stem) >= 3
                and stem[-1] == stem[-2] and stem[-1] not in VOWELS):
            cands.append(stem[:-1])  # hummed -> humm -> hum
        for c in cands:
            if len(c) >= 2 and c != word and c not in out:
                out.append(c)
    return out
