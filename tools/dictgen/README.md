# dictgen: the Wordsmith dictionary

Builds the offline dictionary the app shows when a player taps a word
(`app/assets/dict/`) from [Open English WordNet 2024](https://github.com/globalwordnet/english-wordnet),
for every word in `tools/puzzlegen/data/accepted.txt` (which already leaves
out names: see the puzzlegen README).

Python 3.13, standard library only. The build and the tests need no network
once the source is downloaded.

## Commands

Run from this directory:

```sh
cd tools/dictgen

python3 -m dictgen fetch                   # download the source into data/raw/ (network, ~13 MB)
python3 -m dictgen build                   # write app/assets/dict/, the licence text and the report
python3 -m dictgen show forge forged went  # print what the app will show for some words

python3 -m unittest discover -s tests      # < 1 s; about 10 s more when data/raw/ is present
```

- `fetch` and `build` take `--raw-dir DIR` to keep the download somewhere
  other than `data/raw/` (git-ignored). For the tests, point
  `DICTGEN_RAW_DIR` at it.
- `fetch` checks each file's SHA-256 against `SOURCES` in `dictgen/fetch.py`;
  `build` refuses to run on a file that does not match.
- `build` also writes `app/assets/licenses/OEWN-CC-BY-4.0.txt` (attribution
  plus OEWN's licence files) and `reports/lexicon.gen.json` (coverage,
  file sizes, senses removed per filter pattern, common words with no
  definition).
- Same inputs give byte-identical output: keys are sorted, gzip runs with
  mtime 0, and nothing depends on `PYTHONHASHSEED`. The tests rebuild and
  compare when the source is present.

Re-run `build` after the word list changes (`python3 -m puzzlegen fetch`) or
after editing `data/gloss_filter.txt`.

## Source and licence

| File | From | Licence |
|---|---|---|
| `english-wordnet-2024.xml.gz` (WN-LMF XML) | https://github.com/globalwordnet/english-wordnet/releases/tag/2024-edition | CC BY 4.0 |
| `LICENSE.md`, `WNDB_License.txt` | the same repository at tag `2024-edition` | |

Open English WordNet is Copyright (c) 2019-present, The Open English WordNet
Team, under the [Creative Commons Attribution 4.0 International License](https://creativecommons.org/licenses/by/4.0/).
It is derived from Princeton WordNet 3.1 (WordNet 3.1 Copyright 2011 by
Princeton University; WordNet License, BSD-like), and OEWN asks that
attribution go to both. The app ships the full text in
`app/assets/licenses/OEWN-CC-BY-4.0.txt`. The credit row comes from the
`open-english-wordnet` pack in `art/sources.json`, which
`python3 art/export.py credits` turns into `art/CREDITS.md` and
`app/assets/credits.json` (the Credits screen).

## Output: `app/assets/dict/`

One gzip file per first letter, `a.json.gz` ... `z.json.gz`, each holding the
entry lemmas and form words that start with that letter (excerpt of
`f.json.gz`):

```json
{"v":1,
 "entries":{"forge":[["v","create by hammering"],["n","furnace consisting of a special hearth where metal is heated before shaping"],["v","make a copy of with the intent to deceive"]],
            "forged":[["a","reproduced fraudulently"]]},
 "forms":{"forged":"forge","forges":"forge"}}
```

and `meta.json` (plain JSON): `{"v":1,"source":"Open English WordNet 2024","license":"CC BY 4.0","entries":N,"forms":M}`.

- `entries[lemma]`: 1 to 3 senses `[pos, gloss]`, pos `n`, `v`, `a`
  (adjectives, satellites included) or `r` (adverbs).
- `forms[word]`: the lemma an inflected word belongs to. That lemma's entry
  may be in another letter's file (`went` -> `go`).
- A word can be in both: `forged` is a WordNet lemma of its own and also a
  form of `forge`. Look a word up in `entries` first, then follow `forms`.
- Keys are lowercase a-z.

## How words are matched

For each accepted word, in order:

1. It is a lowercase WordNet lemma: it gets an entry. If it is also an
   inflection of another lemma (exception lists, or the noun/verb rules
   below) it gets a form too.
2. Its base form is a lowercase lemma by WordNet's morphology ("morphy"):
   it gets a form. Irregular forms come from OEWN's exception lists
   (`<Form>` elements: went -> go, children -> child), then the suffix rules
   of WordNet's morph.c: noun -s, -ses, -xes, -zes, -ches, -shes, -men,
   -ies, plus -oes; verb -s, -ies, -es, -ed, -ing; adjective -er, -est; plus
   -ied/-ier/-iest -> -y and a doubled final consonant before -ed/-ing/-er/-est
   (hummed -> hum). The base must be a lemma of that part of speech.
3. It only matches a capitalised lemma (brie ~ Brie) and step 2 found
   nothing: that entry is used. (So mars -> mar and burns -> burn, rather
   than the planet and the poet.)
4. Fallbacks: the same rules landing on another part of speech (guested ->
   guest, exotics -> exotic); capitalised bases (amanitas -> Amanita), but
   not names of individuals or bases under three letters; the singular of a
   plural-only noun (tong -> tongs). Otherwise the word has no definition.

Multiword and hyphenated lemmas never match (the word list is single a-z
words), so only exact matches count.

## How senses are picked

- Lowercase spellings first; capitalised ones (March, Turkey) only fill
  leftover slots and never with names of individuals (OEWN
  `instance_hypernym` synsets: people, places, deities).
- Within a part of speech, WordNet's sense order. Across parts of speech,
  round robin (first sense of each, then second of each); the part of speech
  with more senses goes first, ties n, v, a, r. At most 3.
- Gloss = the definition only (no examples), whitespace and stray `;` / `,`
  cleaned, at most 160 characters (cut at a word boundary, ending in `…`).
  Duplicate glosses are dropped.
- `data/gloss_filter.txt` drops slur senses and sexual content (patterns are
  documented in the file). `[always]` patterns always drop the sense;
  `[unless-only]` patterns (plain sexual or anatomical wording, non-ethnic
  "disparaging term") drop it only when the word has another sense to show.
