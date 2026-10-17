"""The committed campaign and multiplayer bank pass `validate`."""

import copy
import json
import os
import unittest

from puzzlegen import paths, words
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

    def test_no_blocked_words(self):
        for p in self.data["puzzles"]:
            for w in [pw["w"] for pw in p["words"]] + p["bonus"]:
                self.assertNotIn(w.lower(), self.lex.blocked, p["id"])

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
    def test_bank_validates(self):
        lex = words.load()
        data = load(paths.MP_BANK_JSON)
        campaign = load(paths.CAMPAIGN_JSON) if os.path.exists(paths.CAMPAIGN_JSON) else None
        self.assertEqual(validate_mp(data, lex, campaign), [])


if __name__ == "__main__":
    unittest.main()
