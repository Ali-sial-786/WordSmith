"""The layout checker catches each kind of violation (hand-made grids)."""

import copy
import unittest

from puzzlegen.rules import check_layout, check_puzzle
from puzzlegen.words import Lexicon


def W(w, x, y, d):
    return {"w": w, "x": x, "y": y, "d": d}


# The example from shared/puzzle-format.md:
#   T E A R
#   . A . A
#   . T . T
#   . . . E
GOOD = {
    "id": "c-0001",
    "letters": "RTAE",
    "heat": 1,
    "cols": 4,
    "rows": 4,
    "words": [W("TEAR", 0, 0, "a"), W("EAT", 1, 0, "d"), W("RATE", 3, 0, "d")],
    "bonus": ["ARE", "ART", "ATE", "EAR", "ERA", "RAT", "TAR", "TEA"],
}


def has(errors, text):
    return any(text in e for e in errors)


class LayoutRuleTests(unittest.TestCase):
    def test_good_example(self):
        self.assertEqual(check_layout(GOOD["words"], 4, 4), [])
        self.assertEqual(check_puzzle(GOOD), [])

    def test_letter_clash(self):
        words = [W("TEAR", 0, 0, "a"), W("OAT", 1, 0, "d")]  # E vs O at (1,0)
        self.assertTrue(has(check_layout(words, 4, 3), "rule 4"))

    def test_parallel_words_touching_make_stray_runs(self):
        # CAT on row 0 and DOG directly below: columns spell CD, AO, TG.
        words = [W("CAT", 0, 0, "a"), W("DOG", 0, 1, "a")]
        errs = check_layout(words, 3, 2)
        self.assertTrue(has(errs, "stray run CD"))

    def test_word_end_touches_another_letter(self):
        # TEA across, then ART down starting right after the A: row 0 = TEAA?
        # Simpler: EAT across at (0,0) and TO down at (3,0) -> row 0 "EATT".
        words = [W("EAT", 0, 0, "a"), W("TOE", 3, 0, "d")]
        errs = check_layout(words, 4, 3)
        self.assertTrue(has(errs, "not a maximal run"))
        self.assertTrue(has(errs, "stray run EATT"))

    def test_cell_before_word_not_empty(self):
        # SEA down at (0,0) and SEAT down at (0,3)... touch end to start: SEASEAT
        words = [W("SEA", 0, 0, "d"), W("TEA", 0, 3, "d")]
        errs = check_layout(words, 1, 6)
        self.assertTrue(has(errs, "not a maximal run"))

    def test_overlapping_across_words(self):
        # TEAR and EAR share cells on the same row.
        words = [W("TEAR", 0, 0, "a"), W("EAR", 1, 0, "a")]
        errs = check_layout(words, 4, 1)
        self.assertTrue(has(errs, "not a maximal run"))

    def test_same_word_twice_same_spot(self):
        words = [W("TEAR", 0, 0, "a"), W("TEAR", 0, 0, "a")]
        self.assertTrue(has(check_layout(words, 4, 1), "placed twice"))

    def test_disconnected(self):
        words = [W("TEA", 0, 0, "a"), W("EAT", 0, 2, "a")]
        errs = check_layout(words, 3, 3)
        self.assertTrue(has(errs, "rule 6"))

    def test_not_cropped(self):
        errs = check_layout(GOOD["words"], 5, 4)
        self.assertTrue(has(errs, "column 4 is empty"))
        words = [W("TEAR", 1, 1, "a"), W("EAT", 2, 1, "d"), W("RATE", 4, 1, "d")]
        errs = check_layout(words, 5, 5)
        self.assertTrue(has(errs, "row 0 is empty"))
        self.assertTrue(has(errs, "column 0 is empty"))

    def test_too_big(self):
        words = [W("ABCDEFGHIJK", 0, 0, "a")]
        self.assertTrue(has(check_layout(words, 11, 1), "exceeds 10x10"))

    def test_word_outside_grid(self):
        self.assertTrue(has(check_layout(GOOD["words"], 4, 3), "runs outside"))


class PuzzleRuleTests(unittest.TestCase):
    def bad(self, **changes):
        p = copy.deepcopy(GOOD)
        p.update(changes)
        return check_puzzle(p)

    def test_rule1_unformable(self):
        p = copy.deepcopy(GOOD)
        p["bonus"] = sorted(p["bonus"] + ["TREAT"])
        self.assertTrue(has(check_puzzle(p), "rule 1: TREAT"))
        p["bonus"] = ["AT"]
        self.assertTrue(has(check_puzzle(p), "shorter than 3"))

    def test_rule2_no_full_word(self):
        words = [W("EAT", 0, 0, "a"), W("TAR", 2, 0, "d")]
        errs = self.bad(words=words, cols=3, rows=3)
        self.assertTrue(has(errs, "rule 2"))

    def test_rule3_duplicates(self):
        errs = self.bad(bonus=sorted(GOOD["bonus"] + ["EAT"]))
        self.assertTrue(has(errs, "rule 3: repeated words: EAT"))

    def test_bonus_sorted(self):
        errs = self.bad(bonus=list(reversed(GOOD["bonus"])))
        self.assertTrue(has(errs, "not sorted"))

    def test_letters_spell_word(self):
        self.assertTrue(has(self.bad(letters="TEAR"), "spell a grid word"))

    def test_letters_format(self):
        self.assertTrue(self.bad(letters="rtae"))
        self.assertTrue(self.bad(letters="RTA"))
        self.assertTrue(has(self.bad(heat=7), "heat"))

    def test_rule7_and_dictionary(self):
        lex = Lexicon(["tear", "eat", "rate", "are", "art", "ate", "ear", "era", "rat", "tar",
                       "tea", "tare"], {}, blocked=["tar"])
        errs = check_puzzle(GOOD, lex)
        self.assertTrue(has(errs, "rule 7: blocked word TAR"))
        self.assertTrue(has(errs, "missing TARE"))


if __name__ == "__main__":
    unittest.main()
