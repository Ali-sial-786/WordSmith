"""Word quality (quality.py), the answer pool caps and the metrics."""

import random
import unittest

from puzzlegen import generate, layout, metrics, quality, words
from puzzlegen.tiers import GREAT_Q, LEFTOVER_MAX, NICE_Q, TIERS
from puzzlegen.words import Lexicon


def small_lexicon(**kw):
    accepted = ["last", "lasts", "salt", "salts", "see", "seed", "date", "dating", "hum",
                "hummed", "city", "cities", "build", "building", "mike", "the", "lake", "fake"]
    levels = {w: 10 for w in accepted}
    levels.update(mike=35, lake=35)
    freq = {"last": 5.9, "lasts": 3.9, "salt": 4.6, "salts": 3.4, "see": 6.2, "seed": 4.4,
            "date": 5.0, "dating": 4.7, "hum": 3.5, "hummed": 2.9, "city": 5.5, "cities": 4.9,
            "build": 5.0, "building": 5.1, "mike": 4.8, "the": 7.7, "lake": 4.6, "fake": 4.6}
    args = dict(freq=freq, name_senses=["mike"], not_inflections=["seed"],
                defined=set(accepted) - {"the"})
    args.update(kw)
    return Lexicon(accepted, levels, blocked=[], **args)


class InflectionTests(unittest.TestCase):
    def test_kinds_and_bases(self):
        lex = small_lexicon()
        self.assertEqual(lex.inflection("lasts"), ("s", "last"))
        self.assertEqual(lex.inflection("cities"), ("s", "city"))
        self.assertEqual(lex.inflection("dating"), ("ing", "date"))
        self.assertEqual(lex.inflection("hummed"), ("ed", "hum"))
        self.assertIsNone(lex.inflection("last"))
        self.assertIsNone(lex.inflection("seed"))  # not_inflections.txt: SEED isn't SEE + D

    def test_forms_of(self):
        self.assertEqual(quality.forms_of("city")["cities"], quality.PLURAL)
        self.assertEqual(quality.forms_of("hum")["humming"], quality.ING)
        self.assertEqual(quality.forms_of("nice")["nicest"], quality.EST)
        self.assertEqual(quality.forms_of("box")["boxes"], quality.PLURAL)


class ScoreTests(unittest.TestCase):
    def test_base_word_beats_its_inflection(self):
        lex = small_lexicon()
        self.assertGreater(lex.quality("salt"), lex.quality("salts"))
        self.assertGreater(lex.quality("last"), lex.quality("lasts"))
        # SALTS loses the whole plural penalty: it is much rarer than SALT.
        self.assertAlmostEqual(lex.scorer.penalty("salts"), quality.INFLECTION_PENALTY["s"])

    def test_form_more_common_than_its_base_keeps_most_points(self):
        lex = small_lexicon()
        self.assertLess(lex.scorer.penalty("building"), quality.INFLECTION_PENALTY["ing"])

    def test_name_senses_and_function_words_are_capped(self):
        lex = small_lexicon()
        # MIKE is as frequent as LAKE, but much of that is the name.
        self.assertLess(lex.quality("mike"), lex.quality("lake"))
        self.assertLessEqual(lex.quality("the"), quality.UNDEFINED_CAP)
        # Without a dictionary every word counts as defined.
        self.assertGreater(small_lexicon(defined=None).quality("the"), quality.UNDEFINED_CAP)

    def test_real_lexicon_orders_familiar_words_first(self):
        lex = words.load()
        for better, worse in (("dig", "din"), ("tag", "nit"), ("gain", "gnat"), ("salt", "salts"),
                              ("last", "lasts"), ("ding", "din"), ("tang", "nit"),
                              ("giant", "gnat"), ("slate", "slats")):
            self.assertGreater(lex.quality(better), lex.quality(worse), (better, worse))
        self.assertEqual(lex.inflection("salts"), ("s", "salt"))
        self.assertIsNone(lex.inflection("gnat"))
        self.assertEqual(lex.quality("salt"), lex.quality("salt"))  # cached, stable

    def test_frequencies_are_committed(self):
        lex = words.load()
        self.assertGreater(len(lex.freq), 40000)
        self.assertTrue(lex.freq["the"] > 7 > lex.freq["salt"] > lex.freq["salts"] > 0)
        self.assertTrue(set(lex.freq) <= lex.accepted)


class PoolTests(unittest.TestCase):
    def test_caps_and_order(self):
        lex = words.load()
        spec = generate.spec_for(4, 1.0, random.Random(1), length=6, target=9)
        answers = generate.answer_candidates(lex, "dating", spec)
        self.assertNotIn("dita", answers)  # below the tier's quality floor
        prio = {w: generate.priority_of(lex, w) for w in answers}
        pool = generate.answer_pool(lex, "dating", answers, spec, prio, random.Random(0))
        self.assertEqual(pool, sorted(pool, key=lambda w: (-prio[w], w)))
        self.assertLess(pool.index("dig"), pool.index("din"))
        inflected = [w for w in pool if lex.inflection(w)]
        self.assertLessEqual(len(inflected) + 1, spec.max_inflections)  # DATING is one
        rare = [w for w in pool if lex.quality(w) < spec.common_q]
        self.assertLessEqual(len(rare), spec.max_rare)

    def test_layout_prefers_the_better_words(self):
        # The old campaign's stage 290: DIN and NIT went in, DIG, TAG and GIN to the Scrap Bin.
        lex = words.load()
        spec = generate.spec_for(4, 0.5, random.Random(2), length=6, target=10)
        res = generate.make_puzzle(lex, "dating", spec, random.Random(3))
        grid = {w["w"] for w in res.puzzle["words"]}
        # 10 words, and past that only good ones (quality 3.0+) that would otherwise be left over.
        self.assertGreaterEqual(len(grid), 10)
        self.assertLessEqual(len(grid), spec.max_words)
        self.assertTrue({"DIG", "GIN", "GAIN", "GIANT"} <= grid, grid)
        self.assertFalse({"DIN", "NIT"} & grid, grid)
        self.assertGreater(min(lex.quality(w.lower()) for w in grid), lex.quality("din"))

    def test_seeds_are_never_plurals(self):
        lex = words.load()
        pool = generate.SeedPool(lex)
        t = TIERS[2]
        seeds = pool.seeds(5, t.answer_level, t.seed_q)
        self.assertNotIn("salts", seeds)
        self.assertFalse([s for s in seeds if generate.is_plural(lex, s)])
        self.assertFalse({"lasts", "salts", "slats"} & set(seeds))
        # Where anvils are scarce (co-op Ember) a plural may be the seed.
        self.assertTrue({"lasts", "salts", "slats"} & set(pool.seeds(5, 35, None, plural_ok=True)))


class LeftoverTests(unittest.TestCase):
    """Good words left in the Scrap Bin (metrics.leftovers) decide which anvils are used."""

    def test_letter_sets_whose_good_words_cant_fit_are_rejected(self):
        # The players' examples (bank m-01642 and m-01677, Cherry Red): 25 and 28 words of
        # quality 3.0+, far more than a 14-word grid takes.
        lex = words.load()
        for seed in ("entail", "framed"):
            spec = generate.spec_for(3, 0.5, random.Random(1), target=12)
            res = generate.make_puzzle(lex, seed, spec, random.Random(2))
            self.assertIsNone(res.puzzle, seed)
            self.assertEqual(res.reason, "good words can't all fit")
            self.assertFalse(res.info.get("laid_out"))

    def test_good_words_go_in_past_the_target(self):
        lex = words.load()
        spec = generate.spec_for(3, 0.5, random.Random(1), target=9)
        res = generate.make_puzzle(lex, "pocket", spec, random.Random(2))
        grid = {w["w"].lower() for w in res.puzzle["words"]}
        extra = len(grid) - spec.target
        self.assertGreater(extra, 0)
        self.assertLessEqual(len(grid), spec.max_words)
        self.assertEqual(res.info["left"], metrics.leftovers(lex, 3, res.puzzle["bonus"]))

    def test_slot_picks_letters_within_the_limits(self):
        lex = words.load()
        pool = generate.SeedPool(lex)
        for heat in (3, 5):
            rng = random.Random(f"left-{heat}")
            spec = generate.spec_for(heat, 0.5, rng)
            res = generate.generate_slot(lex, pool, spec, set(), rng, {},
                                         opts=layout.LayoutOptions(restarts=8))
            l4, l3, _ = metrics.leftovers(lex, heat, res.puzzle["bonus"])
            self.assertLessEqual(l4, LEFTOVER_MAX[GREAT_Q])
            self.assertLessEqual(l3, LEFTOVER_MAX[NICE_Q])
            self.assertGreaterEqual(len(res.puzzle["words"]), spec.min_words)

    def test_leftovers_count_at_the_tiers_scowl_cap(self):
        lex = words.load()
        # ARE, FAR, RED: very common. FAME: common. Not eligible: a name, a
        # SCOWL-only word, an excluded one.
        bonus = ["ARE", "FAR", "RED", "FAME", "ARM"]
        qs = [lex.quality(w.lower()) for w in bonus]
        want = (sum(q >= 4.0 for q in qs), sum(q >= 3.0 for q in qs), sum(q >= 2.5 for q in qs))
        self.assertEqual(metrics.leftovers(lex, 3, bonus), want)
        self.assertEqual(metrics.leftover_words(lex, 3, bonus),
                         sorted((w.lower() for w in bonus), key=lambda w: (-lex.quality(w), w)))
        self.assertEqual(metrics.leftovers(lex, 3, ["GONNA", "INFO"]), (0, 0, 0))


class MetricsTests(unittest.TestCase):
    def test_puzzle_metrics(self):
        lex = words.load()
        p = {"letters": "DNGTIA", "heat": 4, "cols": 6, "rows": 5,
             "words": [{"w": w} for w in ("AID", "AND", "DIN", "NIT", "GIANT", "DATING")],
             "bonus": ["DIG", "TAG", "GNAT", "ADIT"]}
        m = metrics.puzzle_metrics(p, lex)
        # DIG and TAG are clearly better than the worst grid word; GNAT and ADIT aren't.
        self.assertEqual(m["inversions"], 2)
        self.assertEqual(m["inflections"], 1)  # DATING
        self.assertEqual(m["words"], 6)
        self.assertEqual(m["min_q"], min(lex.quality(w) for w in ("din", "nit", "and")))
        # DIG and TAG are good words left over (GNAT and ADIT are below 2.5).
        self.assertEqual((m["left3"], m["left25"]), (2, 2))
        s = metrics.summary([p, p], lex)
        self.assertEqual(s["inversions/puzzle"], 2)
        self.assertAlmostEqual(s["inflection share"], 1 / 6)


if __name__ == "__main__":
    unittest.main()
