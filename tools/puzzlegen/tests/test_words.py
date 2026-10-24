import unittest

from puzzlegen import fetch, words
from puzzlegen.words import Lexicon, can_make, signature, sub_signatures


def small_lexicon():
    accepted = ["tea", "eat", "ate", "eta", "tee", "teat", "tat", "att", "seat", "east",
                "eats", "sate", "teas", "set", "sea", "tes", "ess", "tess", "states"]
    levels = {"tea": 10, "eat": 10, "ate": 10, "seat": 20, "east": 10, "eats": 20,
              "teat": 35, "tat": 50, "set": 10, "sea": 10, "teas": 20, "states": 10}
    return Lexicon(accepted, levels, blocked=["tess"], scowl_only=["tes"],
                   answer_exclude=["eta"])


class AnagramTests(unittest.TestCase):
    def test_signature(self):
        self.assertEqual(signature("tea"), signature("eat"))
        self.assertNotEqual(signature("teat"), signature("eat"))

    def test_can_make_respects_multiplicity(self):
        self.assertTrue(can_make("tat", "teat"))
        self.assertFalse(can_make("tat", "tea"))
        self.assertFalse(can_make("tee", "teat"))
        self.assertTrue(can_make("teat", "teat"))

    def test_sub_signatures_are_distinct_multisets(self):
        sigs = sub_signatures("aab", min_len=1)
        self.assertEqual(sorted(sigs), sorted(["a", "aa", "b", "ab", "aab"]))
        self.assertEqual(len(sigs), len(set(sigs)))
        self.assertTrue(all(len(s) >= 3 for s in sub_signatures("letters")))

    def test_subwords_small(self):
        lex = small_lexicon()
        got = lex.subwords("teat")
        self.assertEqual(got, sorted(["tea", "eat", "ate", "eta", "teat", "tat", "att"]))
        self.assertNotIn("tee", got)  # needs two Es
        self.assertNotIn("seat", got)  # needs an S

    def test_subwords_multiplicity_s(self):
        lex = small_lexicon()
        got = lex.subwords("seats")
        self.assertIn("ess", got)
        self.assertNotIn("tess", got)  # blocked
        self.assertNotIn("states", got)  # too many letters
        self.assertEqual(lex.full_words("aset"), ["east", "eats", "sate", "seat", "teas"])

    def test_answer_eligibility(self):
        lex = small_lexicon()
        self.assertTrue(lex.is_answer("tea", 10))
        self.assertFalse(lex.is_answer("teat", 20))  # too rare for the pool
        self.assertTrue(lex.is_answer("teat", 35))
        self.assertFalse(lex.is_answer("eta", 99))  # excluded as an answer
        self.assertFalse(lex.is_answer("tes", 99))  # SCOWL-only (not in ENABLE)
        self.assertFalse(lex.is_answer("att", 70))  # unranked by SCOWL
        # A quality floor (quality.py): with no frequencies, quality comes from the
        # SCOWL level and the length alone.
        self.assertTrue(lex.is_answer("seat", 35, 0.5))
        self.assertGreater(lex.quality("seat"), lex.quality("teat"))
        self.assertFalse(lex.is_answer("teat", 35, lex.quality("seat")))
        self.assertNotIn("tess", lex.accepted)

    def test_subwords_match_brute_force_on_real_lexicon(self):
        lex = words.load()
        for letters in ("listen", "banana", "eeee", "strength", "aabbccdd"):
            fast = lex.subwords(letters)
            slow = sorted(w for w in lex.accepted if len(w) >= 3 and can_make(w, letters))
            self.assertEqual(fast, slow, letters)


class DataTests(unittest.TestCase):
    def test_committed_lists(self):
        lex = words.load()
        self.assertGreater(len(lex.accepted), 70000)
        self.assertTrue(all(3 <= len(w) <= 8 and w.isalpha() and w.islower()
                            for w in lex.accepted))
        self.assertFalse(lex.accepted & lex.blocked)
        self.assertTrue(set(lex.levels) <= lex.accepted)
        for w in ("cat", "house", "forge", "anvil"):
            self.assertIn(w, lex.accepted)

    def test_blocklist_inflections(self):
        lex = words.load()
        for w in ("shit", "shits", "bitches", "fuckhead"):
            if len(w) <= 8:
                self.assertIn(w, lex.blocked, w)
        self.assertNotIn("shell", lex.blocked)
        self.assertNotIn("cockpit", lex.blocked)

    def test_names_are_not_words(self):
        lex = words.load()
        self.assertGreater(len(lex.names), 900)
        self.assertFalse(lex.accepted & lex.names)
        for w in ("abigail", "alaska", "boston", "berlin", "brazil", "barbie", "batman", "ben",
                  "bertha", "bilbo", "bolivia", "bostons", "abigails", "ted", "english", "jew"):
            self.assertIn(w, lex.names, w)
        # Real words that are also names stay, and so do their forms.
        for w in ("china", "amber", "august", "bill", "mark", "rose", "jack", "mike", "peter",
                  "may", "will", "bass", "basil", "angel", "apple", "amazon", "google", "grey",
                  "armour", "tyre", "east", "easts", "deed", "lased", "gothic", "gothics",
                  "adonis", "roses", "willies"):
            self.assertIn(w, lex.accepted, w)


class NamesRuleTests(unittest.TestCase):
    def test_names_their_forms_and_the_hand_lists(self):
        vocabulary = {"boston", "bostons", "china", "east", "easts", "hade", "hades", "had",
                      "dee", "dees", "deed", "las", "lase", "lased", "lases", "adonis",
                      "adonises", "ted", "teds", "tedded", "abigail", "abigails", "cat"}
        names = {w: 50 for w in ("boston", "china", "easts", "hades", "dee", "las", "adonis",
                                 "abigail")}
        common = {"china", "east", "had", "deed", "cat"}
        got = fetch.build_names(vocabulary, names, common, keep={"adonis"}, extra={"ted"})
        self.assertEqual(got, {"boston", "bostons", "hades", "dee", "dees", "las", "ted", "teds",
                               "tedded", "abigail", "abigails"})

    def test_word_forms(self):
        self.assertLessEqual({"chevies", "chevied", "chevying"}, fetch.word_forms("chevy"))
        self.assertIn("burked", fetch.word_forms("burke"))
        self.assertNotIn("hades", fetch.word_forms("had"))
        self.assertEqual(fetch._bases("lased"), {"lase", "las"})


if __name__ == "__main__":
    unittest.main()
