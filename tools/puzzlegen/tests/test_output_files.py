"""The committed campaign and multiplayer bank pass `validate`."""

import copy
import json
import os
import unittest
from collections import Counter

from puzzlegen import campaign, paths, words
from puzzlegen.validate import validate_campaign, validate_mp


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


@unittest.skipUnless(os.path.exists(paths.CAMPAIGN_JSON), "campaign.json not generated")
class CampaignFileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lex = words.load()
        cls.data = load(paths.CAMPAIGN_JSON)

    def test_campaign_validates(self):
        self.assertEqual(validate_campaign(self.data, self.lex), [])

    def test_no_blocked_words_or_names(self):
        for p in self.data["puzzles"]:
            for w in [pw["w"] for pw in p["words"]] + p["bonus"]:
                self.assertNotIn(w.lower(), self.lex.blocked, p["id"])
                self.assertNotIn(w.lower(), self.lex.names, p["id"])

    def test_refresh_keeps_grids_and_drops_names(self):
        def lex_naming(word):
            return words.Lexicon(self.lex.accepted, self.lex.levels, self.lex.blocked,
                                 names={word.lower()})

        p = next(p for p in self.data["puzzles"] if len(p["bonus"]) > 2)
        self.assertEqual(campaign.refresh_bonus([p], self.lex), ([p], []))
        out, problems = campaign.refresh_bonus([p], lex_naming(p["bonus"][1]))
        self.assertEqual(problems, [])
        self.assertEqual(out, [dict(p, bonus=p["bonus"][:1] + p["bonus"][2:])])
        # A grid answer that stops being a word needs a new grid: reported, left alone.
        out, problems = campaign.refresh_bonus([p], lex_naming(p["words"][0]["w"]))
        self.assertEqual(out, [p])
        self.assertEqual(len(problems), 1)
        self.assertIn(f"{p['id']} (heat {p['heat']}): grid answer {p['words'][0]['w']}", problems[0])

    def test_validator_catches_structure_errors(self):
        d = copy.deepcopy(self.data)
        d["puzzles"][5]["id"] = "c-9999"
        d["puzzles"][7]["letters"] = d["puzzles"][6]["letters"]
        d["puzzles"][0]["heat"] = 2
        d["chapters"][1]["first"] += 1
        del d["puzzles"][-1]
        errs = "\n".join(validate_campaign(d, self.lex))
        self.assertIn("expected c-0006", errs)
        self.assertIn("same letters as c-0007", errs)
        self.assertIn("should be heat 1", errs)
        self.assertIn("contiguous", errs)
        self.assertIn("expected 600 puzzles", errs)

    def test_tutorial_and_ramp(self):
        ps = self.data["puzzles"]
        for p in ps[:3]:
            self.assertEqual((len(p["letters"]), len(p["words"])), (4, 3))
        heats = [p["heat"] for p in ps]
        self.assertEqual(heats, sorted(heats))


@unittest.skipUnless(os.path.exists(paths.MP_BANK_JSON), "mp_bank.json not generated")
class MpFileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lex = words.load()
        cls.data = load(paths.MP_BANK_JSON)

    def test_bank_validates(self):
        camp = load(paths.CAMPAIGN_JSON) if os.path.exists(paths.CAMPAIGN_JSON) else None
        self.assertEqual(validate_mp(self.data, self.lex, camp), [])

    def test_no_names(self):
        for p in self.data["puzzles"]:
            for w in [pw["w"] for pw in p["words"]] + p["bonus"]:
                self.assertNotIn(w.lower(), self.lex.names, p["id"])

    def test_parts(self):
        parts = campaign.bank_parts(self.data)
        self.assertEqual(parts[0]["first"], 1)
        self.assertEqual(parts[0]["count"], 960)  # the Daily Commission's pool
        self.assertEqual(sum(p["count"] for p in parts), len(self.data["puzzles"]))
        size1 = Counter(p["heat"] for p in self.data["puzzles"] if p["size"] == 1)
        self.assertEqual(set(size1.values()), {250})

    def test_validator_catches_part_errors(self):
        d = copy.deepcopy(self.data)
        d["parts"][1]["per"][0][0] += 1
        self.assertIn("part 2 heat 1 size 1: 210 puzzles, expected 211",
                      validate_mp(d, self.lex)[-1])
        d = copy.deepcopy(self.data)
        d["parts"][1]["first"] += 1
        errs = "\n".join(validate_mp(d, self.lex))
        self.assertIn("parts must be contiguous", errs)
        d = copy.deepcopy(self.data)
        d["puzzles"][960], d["puzzles"][1200] = d["puzzles"][1200], d["puzzles"][960]
        self.assertIn("part 2 is not ordered by heat, then size", validate_mp(d, self.lex))


if __name__ == "__main__":
    unittest.main()
