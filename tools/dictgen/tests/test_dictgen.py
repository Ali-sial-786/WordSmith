"""dictgen tests. Run from tools/dictgen: python3 -m unittest discover -s tests

The unit tests use a small WN-LMF fixture. The asset tests check the
committed app/assets/dict/ files. If the source data is present (data/raw/,
or DICTGEN_RAW_DIR), a rebuild must reproduce the committed files exactly.
"""

import gzip
import json
import os
import string
import tempfile
import unittest

from dictgen import build, fetch, morphy, oewn, paths

FIXTURE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE LexicalResource SYSTEM "http://globalwordnet.github.io/schemas/WN-LMF-1.3.dtd">
<LexicalResource xmlns:dc="https://globalwordnet.github.io/schemas/dc/">
  <Lexicon id="t" label="Test" language="en" email="x@example.com" version="1"
           license="https://creativecommons.org/licenses/by/4.0" url="https://example.com">
    <LexicalEntry id="t-forge-n"><Lemma writtenForm="forge" partOfSpeech="n"/>
      <Sense id="t-forge-1" synset="t-01-n"/><Sense id="t-forge-2" synset="t-02-n"/></LexicalEntry>
    <LexicalEntry id="t-forge-v"><Lemma writtenForm="forge" partOfSpeech="v"/>
      <Sense id="t-forge-3" synset="t-03-v"/><Sense id="t-forge-4" synset="t-04-v"/>
      <Sense id="t-forge-5" synset="t-05-v"/></LexicalEntry>
    <LexicalEntry id="t-forged-a"><Lemma writtenForm="forged" partOfSpeech="a"/>
      <Sense id="t-forged-1" synset="t-06-s"/></LexicalEntry>
    <LexicalEntry id="t-go-v"><Lemma writtenForm="go" partOfSpeech="v"/>
      <Form writtenForm="went"/><Sense id="t-go-1" synset="t-07-v"/></LexicalEntry>
    <LexicalEntry id="t-Mars-n"><Lemma writtenForm="Mars" partOfSpeech="n"/>
      <Sense id="t-Mars-1" synset="t-08-n"/></LexicalEntry>
    <LexicalEntry id="t-mar-v"><Lemma writtenForm="mar" partOfSpeech="v"/>
      <Sense id="t-mar-1" synset="t-09-v"/></LexicalEntry>
    <LexicalEntry id="t-screw-n"><Lemma writtenForm="screw" partOfSpeech="n"/>
      <Sense id="t-screw-1" synset="t-10-n"/></LexicalEntry>
    <LexicalEntry id="t-screw-v"><Lemma writtenForm="screw" partOfSpeech="v"/>
      <Sense id="t-screw-2" synset="t-11-v"/><Sense id="t-screw-3" synset="t-12-v"/></LexicalEntry>
    <LexicalEntry id="t-chastity-n"><Lemma writtenForm="chastity" partOfSpeech="n"/>
      <Sense id="t-chastity-1" synset="t-13-n"/></LexicalEntry>
    <LexicalEntry id="t-hum-v"><Lemma writtenForm="hum" partOfSpeech="v"/>
      <Sense id="t-hum-1" synset="t-14-v"/></LexicalEntry>
    <LexicalEntry id="t-tongs-n"><Lemma writtenForm="tongs" partOfSpeech="n"/>
      <Sense id="t-tongs-1" synset="t-15-n"/></LexicalEntry>
    <LexicalEntry id="t-boche-n"><Lemma writtenForm="boche" partOfSpeech="n"/>
      <Sense id="t-boche-1" synset="t-16-n"/></LexicalEntry>
    <LexicalEntry id="t-anvil-n"><Lemma writtenForm="anvil" partOfSpeech="n"/>
      <Sense id="t-anvil-1" synset="t-17-n"/></LexicalEntry>
    <Synset id="t-01-n" partOfSpeech="n"><Definition>furnace where metal is heated</Definition>
      <Example>the smith fired up the forge</Example></Synset>
    <Synset id="t-02-n" partOfSpeech="n"><Definition>a workplace where metal is worked</Definition></Synset>
    <Synset id="t-03-v" partOfSpeech="v"><Definition>create by hammering</Definition></Synset>
    <Synset id="t-04-v" partOfSpeech="v"><Definition> make a copy of  with the intent to deceive ;</Definition></Synset>
    <Synset id="t-05-v" partOfSpeech="v"><Definition>move ahead steadily</Definition></Synset>
    <Synset id="t-06-s" partOfSpeech="s"><Definition>reproduced fraudulently</Definition></Synset>
    <Synset id="t-07-v" partOfSpeech="v"><Definition>change location; move</Definition></Synset>
    <Synset id="t-08-n" partOfSpeech="n"><Definition>a small reddish planet</Definition>
      <SynsetRelation relType="instance_hypernym" target="t-99-n"/></Synset>
    <Synset id="t-09-v" partOfSpeech="v"><Definition>make imperfect</Definition></Synset>
    <Synset id="t-10-n" partOfSpeech="n"><Definition>a simple machine with a spiral thread</Definition></Synset>
    <Synset id="t-11-v" partOfSpeech="v"><Definition>have sexual intercourse with</Definition></Synset>
    <Synset id="t-12-v" partOfSpeech="v"><Definition>turn like a screw</Definition></Synset>
    <Synset id="t-13-n" partOfSpeech="n"><Definition>abstaining from sexual relations</Definition></Synset>
    <Synset id="t-14-v" partOfSpeech="v"><Definition>sing with closed lips</Definition></Synset>
    <Synset id="t-15-n" partOfSpeech="n"><Definition>any of various devices for taking hold of objects</Definition></Synset>
    <Synset id="t-16-n" partOfSpeech="n"><Definition>offensive term for a person of German descent</Definition></Synset>
    <Synset id="t-17-n" partOfSpeech="n"><Definition>a heavy block of iron or steel</Definition></Synset>
  </Lexicon>
</LexicalResource>
"""

WORDS = ["anvil", "boche", "chastity", "forge", "forged", "forges", "hummed", "mars", "screw",
         "tong", "went", "zzz"]


def fixture_dictionary():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "wn.xml.gz")
        with gzip.open(path, "wt", encoding="utf-8") as f:
            f.write(FIXTURE)
        wn = oewn.load(path)
    return wn, build.Dictionary(wn, build.load_filter(paths.GLOSS_FILTER))


def load_committed():
    shards = {}
    for letter in string.ascii_lowercase:
        with open(os.path.join(paths.DICT_DIR, f"{letter}.json.gz"), "rb") as f:
            shards[letter] = f.read()
    return shards


class ParseTests(unittest.TestCase):
    def test_load(self):
        wn, _ = fixture_dictionary()
        self.assertEqual(wn.info["version"], "1")
        forge_v = next(e for e in wn.entries if e.written == "forge" and e.pos == "v")
        self.assertEqual(forge_v.synsets, ["t-03-v", "t-04-v", "t-05-v"])
        self.assertEqual(next(e for e in wn.entries if e.written == "go").forms, ["went"])
        self.assertEqual(next(e for e in wn.entries if e.written == "forged").pos, "a")
        self.assertEqual(wn.definitions["t-01-n"], "furnace where metal is heated")  # no example
        self.assertEqual(wn.instances, {"t-08-n"})


class GlossTests(unittest.TestCase):
    def test_clean(self):
        self.assertEqual(build.clean_gloss(" make a copy of  with the intent to deceive ;"),
                         "make a copy of with the intent to deceive")
        self.assertEqual(build.clean_gloss("; a ;; b ,"), "a; b")

    def test_shorten(self):
        text = " ".join(["anvil"] * 40)  # 239 characters
        short = build.clean_gloss(text)
        self.assertLessEqual(len(short), build.MAX_GLOSS)
        self.assertTrue(short.endswith("anvil…"))
        self.assertEqual(build.clean_gloss("x" * 160), "x" * 160)


class MorphyTests(unittest.TestCase):
    def test_rules(self):
        self.assertIn("forge", morphy.rule_bases("forges", "n"))
        self.assertIn("forge", morphy.rule_bases("forged", "v"))
        self.assertIn("hum", morphy.rule_bases("hummed", "v"))
        self.assertIn("party", morphy.rule_bases("partied", "v"))
        self.assertIn("big", morphy.rule_bases("biggest", "a"))
        self.assertIn("chalky", morphy.rule_bases("chalkier", "a"))
        self.assertIn("potato", morphy.rule_bases("potatoes", "n"))
        self.assertEqual(morphy.rule_bases("glass", "n"), [])


class SelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.wn, cls.d = fixture_dictionary()
        cls.entries, cls.forms, cls.missing = cls.d.build(WORDS)

    def test_variety_and_order(self):
        # The verb has more senses, so it goes first; then the first noun sense.
        self.assertEqual(self.entries["forge"], [
            ["v", "create by hammering"],
            ["n", "furnace where metal is heated"],
            ["v", "make a copy of with the intent to deceive"],
        ])

    def test_forms(self):
        self.assertEqual(self.forms["forges"], "forge")
        self.assertEqual(self.forms["went"], "go")
        self.assertEqual(self.forms["hummed"], "hum")
        self.assertEqual(self.forms["tong"], "tongs")
        self.assertIn("go", self.entries)  # base lemmas get entries even if not in the word list

    def test_lemma_that_is_also_an_inflection(self):
        self.assertEqual(self.entries["forged"], [["a", "reproduced fraudulently"]])
        self.assertEqual(self.forms["forged"], "forge")

    def test_capitalised_only_match_prefers_lowercase_base(self):
        self.assertNotIn("mars", self.entries)
        self.assertEqual(self.forms["mars"], "mar")

    def test_filter(self):
        self.assertEqual(self.entries["screw"], [["n", "a simple machine with a spiral thread"],
                                                 ["v", "turn like a screw"]])
        self.assertNotIn("sexual", json.dumps(self.entries["screw"]))
        self.assertEqual(self.entries["chastity"], [["n", "abstaining from sexual relations"]])
        self.assertIn("boche", self.missing)
        self.assertIn("zzz", self.missing)

    def test_shards(self):
        files = build.shard_files(self.entries, self.forms)
        self.assertEqual(files, build.shard_files(dict(reversed(self.entries.items())), self.forms))
        self.assertEqual(sorted(files), sorted([f"{c}.json.gz" for c in string.ascii_lowercase] + ["meta.json"]))
        self.assertEqual(files["f.json.gz"][4:8], b"\0\0\0\0")  # gzip mtime 0
        doc = json.loads(gzip.decompress(files["f.json.gz"]))
        self.assertEqual(list(doc), ["v", "entries", "forms"])
        self.assertEqual(sorted(doc["entries"]), ["forge", "forged"])
        self.assertEqual(doc["forms"], {"forged": "forge", "forges": "forge"})
        w = json.loads(gzip.decompress(files["w.json.gz"]))
        self.assertEqual(w, {"v": 1, "entries": {}, "forms": {"went": "go"}})
        meta = json.loads(files["meta.json"])
        self.assertEqual(meta, {"v": 1, "source": fetch.SOURCE_NAME, "license": "CC BY 4.0",
                                "entries": len(self.entries), "forms": len(self.forms)})


class CommittedAssetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = load_committed()
        cls.docs = {c: json.loads(gzip.decompress(b)) for c, b in cls.raw.items()}
        cls.entries = {k: v for d in cls.docs.values() for k, v in d["entries"].items()}
        cls.forms = {k: v for d in cls.docs.values() for k, v in d["forms"].items()}
        with open(os.path.join(paths.DICT_DIR, "meta.json"), encoding="utf-8") as f:
            cls.meta = json.load(f)

    def test_files(self):
        names = sorted(os.listdir(paths.DICT_DIR))
        self.assertEqual(names, sorted([f"{c}.json.gz" for c in string.ascii_lowercase] + ["meta.json"]))
        total = sum(os.path.getsize(os.path.join(paths.DICT_DIR, n)) for n in names)
        self.assertLess(total, 4_000_000)

    def test_meta(self):
        self.assertEqual(list(self.meta), ["v", "source", "license", "entries", "forms"])
        self.assertEqual(self.meta["v"], 1)
        self.assertEqual(self.meta["entries"], len(self.entries))
        self.assertEqual(self.meta["forms"], len(self.forms))

    def test_format(self):
        for letter, doc in self.docs.items():
            self.assertEqual(list(doc), ["v", "entries", "forms"])
            self.assertEqual(doc["v"], 1)
            for key in [*doc["entries"], *doc["forms"]]:
                self.assertTrue(key.isascii() and key.isalpha() and key.islower() and key[0] == letter, key)
            self.assertEqual(list(doc["entries"]), sorted(doc["entries"]))
        for key, senses in self.entries.items():
            self.assertTrue(1 <= len(senses) <= 3, key)
            for pos, gloss in senses:
                self.assertIn(pos, ("n", "v", "a", "r"), key)
                self.assertTrue(0 < len(gloss) <= 160, key)
                self.assertEqual(gloss, gloss.strip(" ;,"), key)
        for word, lemma in self.forms.items():
            self.assertIn(lemma, self.entries, word)
            self.assertNotEqual(word, lemma)

    def test_known_words(self):
        self.assertEqual({p for p, _ in self.entries["forge"]}, {"n", "v"})
        self.assertEqual(self.forms["forged"], "forge")
        self.assertEqual(self.forms["forges"], "forge")
        self.assertEqual(self.forms["went"], "go")
        self.assertEqual(self.forms["ingots"], "ingot")
        self.assertIn("anvil", self.entries)
        self.assertIn("hammering", self.entries["anvil"][0][1])

    @unittest.skipIf(fetch.verify(os.environ.get("DICTGEN_RAW_DIR", paths.RAW_DIR)),
                     "source data not downloaded (python3 -m dictgen fetch)")
    def test_rebuild_is_identical(self):
        raw_dir = os.environ.get("DICTGEN_RAW_DIR", paths.RAW_DIR)
        with tempfile.TemporaryDirectory() as tmp:
            build.run(source=os.path.join(raw_dir, fetch.XML_NAME), words_path=paths.ACCEPTED,
                      out_dir=tmp, filter_path=paths.GLOSS_FILTER,
                      licence_out=os.path.join(tmp, "licence.txt"), raw_dir=raw_dir,
                      report_path=None, log=lambda *_: None)
            for name in [f"{c}.json.gz" for c in string.ascii_lowercase] + ["meta.json"]:
                with open(os.path.join(tmp, name), "rb") as a, open(os.path.join(paths.DICT_DIR, name), "rb") as b:
                    self.assertEqual(a.read(), b.read(), name)
            with open(os.path.join(tmp, "licence.txt"), "rb") as a, open(paths.LICENCE_TXT, "rb") as b:
                self.assertEqual(a.read(), b.read())


if __name__ == "__main__":
    unittest.main()
