"""Generated puzzles follow every rule; generation is deterministic."""

import json
import random
import unittest

from puzzlegen import campaign, generate, layout, words
from puzzlegen.rules import check_layout, check_puzzle
from puzzlegen.tiers import TIERS, Chapter
from puzzlegen.validate import _tier_checks


class LayoutTests(unittest.TestCase):
    def test_grid_stays_valid_while_growing(self):
        lex = words.load()
        rng = random.Random(7)
        for seed in ("planets", "garden", "stone", "masters"):
            answers = [w for w in lex.subwords(seed) if lex.is_answer(w, 35)]
            prio = {w: len(w) for w in answers}
            lay = layout.build(seed, answers, prio, 30, rng, layout.LayoutOptions(restarts=3))
            g = lay.grid
            placed = [{"w": w, "x": x, "y": y, "d": d} for (w, x, y, d) in g.cropped()]
            self.assertEqual(check_layout(placed, g.width, g.height), [], seed)
            self.assertLessEqual(max(g.width, g.height), 10)
            self.assertIn(seed, lay.words)

    def test_local_check_rejects_bad_spots(self):
        g = layout.Grid()
        g.place("cat", 0, 0, layout.ACROSS)
        self.assertIsNotNone(g.local_check("tea", 2, 0, layout.DOWN))  # crosses the T
        self.assertIsNone(g.local_check("ate", 1, 1, layout.ACROSS))  # touches, no cross
        self.assertIsNone(g.local_check("eat", 0, 0, layout.DOWN))  # E vs C
        self.assertIsNone(g.local_check("act", 0, 0, layout.ACROSS))  # same direction
        self.assertIsNone(g.check("t" * 3, 2, -9, layout.DOWN, 10, 10))  # no crossing
        self.assertIsNone(g.check("tabcdefghijk", 2, 0, layout.DOWN, 10, 10))  # too tall


class TierBatchTests(unittest.TestCase):
    def test_small_batch_per_tier_is_valid(self):
        lex = words.load()
        pool = generate.SeedPool(lex)
        used = set()
        for heat in sorted(TIERS):
            t = TIERS[heat]
            for i in range(2):
                rng = random.Random(f"test-{heat}-{i}")
                spec = generate.spec_for(heat, i / 1.0, rng)
                res = generate.generate_slot(lex, pool, spec, used, rng, {},
                                             opts=layout.LayoutOptions(restarts=6))
                p = res.puzzle
                p["id"] = f"c-{heat * 10 + i:04d}"
                self.assertEqual(check_puzzle(p, lex), [], (heat, p))
                self.assertEqual(_tier_checks(p, heat, t.min_words, t.max_words, ""), [])
                # Answers come from the tier's answer pool.
                for pw in p["words"]:
                    self.assertTrue(lex.is_answer(pw["w"].lower(), t.answer_level), pw["w"])
                # No blocked word anywhere.
                for w in [pw["w"] for pw in p["words"]] + p["bonus"]:
                    self.assertNotIn(w.lower(), lex.blocked)

    def test_tutorial_spec(self):
        lex = words.load()
        pool = generate.SeedPool(lex)
        rng = random.Random(3)
        res = generate.generate_slot(lex, pool, campaign.tutorial_spec(), set(), rng, {})
        p = res.puzzle
        self.assertEqual(len(p["letters"]), 4)
        self.assertEqual(len(p["words"]), 3)
        for pw in p["words"]:
            self.assertLessEqual(lex.level(pw["w"].lower()), 10)

    def test_shuffle_never_spells_a_full_word(self):
        rng = random.Random(1)
        for _ in range(50):
            s = generate.shuffle_letters("stop", {"stop", "pots", "tops", "spot", "post", "opts"},
                                         rng)
            self.assertNotIn(s, {"stop", "pots", "tops", "spot", "post", "opts"})
            self.assertEqual(sorted(s), sorted("stop"))


SMALL_CHAPTERS = (
    Chapter("tin", "Tin", 5, 1, 1),
    Chapter("copper", "Copper", 4, 1, 2),
    Chapter("iron", "Iron", 3, 3, 3),
)


class DeterminismTests(unittest.TestCase):
    def build(self, seed):
        c, rep = campaign.build_campaign(seed, chapters=SMALL_CHAPTERS,
                                         opts=layout.LayoutOptions(restarts=4))
        return json.dumps(c, sort_keys=True), c

    def test_same_seed_same_output(self):
        a, camp = self.build(11)
        b, _ = self.build(11)
        self.assertEqual(a, b)
        c, _ = self.build(12)
        self.assertNotEqual(a, c)
        # Structure of the small campaign.
        self.assertEqual([p["id"] for p in camp["puzzles"]],
                         [f"c-{i:04d}" for i in range(1, 13)])
        self.assertEqual([p["heat"] for p in camp["puzzles"]], [1] * 7 + [2] * 2 + [3] * 3)
        sigs = {"".join(sorted(p["letters"])) for p in camp["puzzles"]}
        self.assertEqual(len(sigs), 12)
        lex = words.load()
        for p in camp["puzzles"]:
            self.assertEqual(check_puzzle(p, lex), [])

    def test_mp_bank_small(self):
        exclude = set()
        bank, rep = campaign.build_mp(5, 1, exclude, heats=(1, 3), sizes=(1, 2),
                                      opts=layout.LayoutOptions(restarts=4))
        bank2, _ = campaign.build_mp(5, 1, exclude, heats=(1, 3), sizes=(1, 2),
                                     opts=layout.LayoutOptions(restarts=4))
        self.assertEqual(json.dumps(bank), json.dumps(bank2))
        self.assertEqual([(p["id"], p["heat"], p["size"]) for p in bank["puzzles"]],
                         [("m-00001", 1, 1), ("m-00002", 1, 2), ("m-00003", 3, 1),
                          ("m-00004", 3, 2)])
        lex = words.load()
        for p in bank["puzzles"]:
            q = {k: v for k, v in p.items() if k != "size"}
            self.assertEqual(check_puzzle(q, lex), [])
        self.assertGreaterEqual(len(bank["puzzles"][3]["words"]), TIERS[3].min_words + 2)

    def test_mp_bank_part(self):
        # A later part: its own counts per heat and size, ids after the earlier parts',
        # and no letters the earlier ones (`exclude`) used.
        first, _ = campaign.build_mp(5, 1, set(), heats=(3,), sizes=(1,),
                                     opts=layout.LayoutOptions(restarts=4))
        used = {"".join(sorted(p["letters"].lower())) for p in first["puzzles"]}
        part, rep = campaign.build_mp(6, {(3, 1): 2, (3, 2): 0}, used, heats=(3,), sizes=(1, 2),
                                      opts=layout.LayoutOptions(restarts=4), first_id=2)
        self.assertEqual([(p["id"], p["heat"], p["size"]) for p in part["puzzles"]],
                         [("m-00002", 3, 1), ("m-00003", 3, 1)])
        self.assertFalse(used & {"".join(sorted(p["letters"].lower())) for p in part["puzzles"]})
        self.assertEqual(rep["per"][2], [2, 0, 0, 0])


if __name__ == "__main__":
    unittest.main()
