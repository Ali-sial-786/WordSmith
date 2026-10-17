# puzzlegen: the Wordsmith puzzle generator

Offline generator for the solo campaign (`app/assets/campaign/campaign.json`)
and the multiplayer bank (`server/data/mp_bank.json`). The output format is
the contract in [`shared/puzzle-format.md`](../../shared/puzzle-format.md);
heat tiers and chapters come from `docs/DESIGN.md` sections 2.4, 5 and 6.

Python 3.13, standard library only. Generation, validation and the tests
need no network: they read the committed word lists in `data/`.

## Commands

Run everything from this directory:

```sh
cd tools/puzzlegen

python3 -m puzzlegen fetch                 # download sources, rebuild data/*.txt (network)
python3 -m puzzlegen campaign --seed 1 --out ../../app/assets/campaign/campaign.json
python3 -m puzzlegen mp --seed 2 --per 40 --out ../../server/data/mp_bank.json
python3 -m puzzlegen validate ../../app/assets/campaign/campaign.json
python3 -m puzzlegen validate ../../server/data/mp_bank.json   # also checks it shares no letters with the campaign
python3 -m puzzlegen show ../../app/assets/campaign/campaign.json c-0001 c-0300
python3 -m puzzlegen stats ../../app/assets/campaign/campaign.json

python3 -m unittest discover -s tests      # about 3 s
```

- `mp` reads the campaign file (`--campaign`, default the committed one) so
  multiplayer letter sets never repeat campaign ones. Generate the campaign
  first.
- `validate` exits non-zero and prints every problem. For a bank,
  `--campaign FILE` checks it against a campaign (automatic for the committed
  bank) and `--per N` checks the count per heat and size.
- Each generation run writes a report (seeds, difficulty per stage, rejected
  seeds) to `reports/campaign.gen.json` / `reports/mp_bank.gen.json`; other
  `--out` paths get `<name>.gen.json` beside the output. `stats` shows it.

Same inputs and the same `--seed` give byte-identical output (nothing depends
on `PYTHONHASHSEED`). Runtime on one core: campaign about 35 s, bank about
70 s.

## Word lists

`fetch` downloads into `data/raw/` (git-ignored), checks each file's sha256
against the value recorded in `puzzlegen/fetch.py`, and writes:

| File | Contents |
|---|---|
| `data/accepted.txt` | Every accepted (bonus) word: ENABLE + SCOWL levels <= 70, minus the blocklist. 3-8 letters, a-z. |
| `data/scowl_levels.tsv` | `word<TAB>level`, the smallest SCOWL size level (10 = most common, 70) the word appears at. |
| `data/scowl_only.txt` | Accepted SCOWL words that are not in ENABLE (`gonna`, `email`). Never grid answers. |
| `data/blocklist.txt` | LDNOOBW single English words + `blocklist_extra.txt`, with simple inflections, plus every word containing a `*stem*` entry. |
| `data/LICENSES.md` | Sources, licences and the verbatim SCOWL copyright notice. |

Sources: ENABLE (public domain), SCOWL 2020.12.07 (`final/english-words.*`
and `final/american-words.*` only; permissive notice kept in
`data/LICENSES.md`), and the LDNOOBW English list (CC BY 4.0).

Hand-curated, committed files:

- `data/blocklist_extra.txt`: extra blocked words (slurs, crude words the
  LDNOOBW list misses). `*stem*` lines block every word containing the stem.
  Re-run `fetch` after editing it.
- `data/answer_exclude.txt`: words that stay valid bonus words but never go in
  a grid (interjections, letter plurals like `IFS`, archaic or British forms,
  odd inflections SCOWL ranks as common such as `GROSSES`, and dark or
  sensitive words such as `MURDER`). Read at generation time, so no `fetch`
  needed. This is the main knob for answer quality: when `show` turns up a
  bad answer, add it here and regenerate.

## Answer pools and heat tiers

A grid answer must be accepted, an ENABLE word, not in `answer_exclude.txt`,
and at or below the tier's SCOWL level. Words above the tier's "common" level
count as rare, and only a few are allowed per grid (fewer early in a tier).
The all-letter seed word is always SCOWL <= 20 (<= 10 early in Ember).

| Heat | Letters | Grid words | Answers from | Rare words allowed |
|---|---|---|---|---|
| 1 Ember | 4 | 3-5 | SCOWL <= 20 (very common) | none |
| 2 Dull Red | 5 | 5-7 | <= 35 (common) | up to 3 above 20 |
| 3 Cherry Red | 6 | 7-10 | <= 35 | up to 5 above 20 |
| 4 Orange | 6-7 | 9-12 | <= 40 (less common) | up to 2 above 35 |
| 5 Yellow | 7 | 11-15 | <= 50 (uncommon) | up to 3 above 35 |
| 6 White Heat | 7-8 | 14-20 | <= 50 | up to 4 above 35 |

SCOWL 55/60 were tried for the top tiers but gave unfair answers (`GITS`,
`LIDO`, `OPES`, `DACE`), so 50 is the ceiling. Bonus words come from the whole
accepted list, so obscure real words still count as bonus words.

## How a puzzle is built

1. **Seed.** Pick an unused seed word (no two puzzles anywhere share a letter
   multiset). Its letters are the anvil.
2. **Words.** Every sub-anagram comes from a sorted-letter signature index:
   all distinct sub-multisets of the anvil (at most 256) are looked up
   directly, so multiplicity is respected and it's fast.
3. **Priorities.** Longer and more common words rank higher (commonness
   weighs more in low tiers). The rare-word cap is applied here.
4. **Layout.** The seed word goes in first (across about 2/3 of the time), then
   words are added greedily. At each step the best few unplaced words compete,
   and each placement is scored on crossings, bounding-box growth and aspect
   ratio, plus noise. Every placement keeps the grid valid (proper crossword
   spacing, 10x10 limit), and positions are tracked incrementally. 16-40
   randomized restarts per puzzle (more for bigger tiers). The best layout wins
   on word count first, then crossings, density, an aspect ratio
   (cols/rows) inside 0.8-1.6, common words, and how central the seed word is.
5. **Accept or reject.** Fewer than the tier minimum: the seed is rejected and
   another is tried. Fewer than the target: kept, if still at or above the
   minimum.
6. **Output.** Words are cropped to (0,0). Bonus = every accepted word formable
   from the letters minus the grid words. The letters are shuffled so they
   don't spell any all-letter word, even reading around the ring.
7. **Difficulty** (for ordering only; it isn't written to the JSON):
   letters, word count, mean and max rarity, longest word, long-word count,
   letters to fill and grid area.

Finally `rules.py` (written separately from the layout code) re-checks the
grid.

## Campaign

Chapters as in DESIGN 2.4 (600 stages). In an "a -> b" chapter the first half
is heat a and the second half heat b. Each tier ramps across all its stages
in the campaign: target word count goes from the tier minimum to its maximum,
longer anvils get more likely (Orange 6 -> 7, White Heat 7 -> 8), and rare
words are allowed later. Within each chapter (and heat part), puzzles are
sorted by difficulty, with an easier "breather" every 7-10 stages. Stages 1-3
are the tutorial: 4 letters and exactly 3 words, all SCOWL <= 10.

The chapters get harder from Tin to Starmetal. Where the heat changes inside
a chapter (Copper, Steel, Damascus), the first puzzles of the new heat can be
easier than the last ones of the old heat, because the tiers' word ranges
overlap (Cherry Red goes up to 10 words, Orange starts at 9).

## Multiplayer bank

For each heat 1-6 and size 1-4 there are `--per` puzzles (default 40, so 960
in all) with ids `m-NNNNN`, ordered by heat, then size, then difficulty. Size s
targets the tier's word count + 2*(s-1) and guarantees at least the tier
minimum + 2*(s-1), with these exceptions (see `MP_SIZE_MIN` in
`puzzlegen/tiers.py`):

- **Ember (4 letters) sizes 3 and 4** want 7-9 and 9-11 words, but a 4-letter
  anvil rarely makes more than 6-7 common words that also interlock. They
  guarantee 6 words. The current bank has 6-7 (size 3) and 7-11 (size 4).
- **Ember sizes 2-4** draw answers and seeds from "common" (SCOWL <= 35)
  instead of "very common" (<= 20), so that enough words exist. Their seeds
  are tried richest first.
- **White Heat size 4** wants 20-26 words, but a 10x10 grid tops out around
  22-23. The current bank has 20-22.

## Tests

`tests/` (unittest, about 3 s): anagram finder and multiplicity (and a check
against brute force on the real lists), the rule checker on a hand-made bad
grid for each kind of violation, a small generated batch per tier, the
tutorial, letter shuffling, determinism of the campaign and the bank, blocked
words, and the committed `campaign.json` / `mp_bank.json` passing `validate`
(skipped if the files are missing).

## Layout of the package

| Module | Role |
|---|---|
| `fetch.py` | downloads, derived lists, LICENSES.md |
| `words.py` | lexicon, levels, answer eligibility, sub-anagram index |
| `tiers.py` | heat tiers, chapters, multiplayer size rules |
| `layout.py` | crossword placement |
| `generate.py` | one puzzle: seed -> answers -> layout -> JSON; difficulty |
| `campaign.py` | campaign and bank assembly, output writing, reports |
| `rules.py` | every rule in shared/puzzle-format.md, for one puzzle |
| `validate.py` | campaign / bank structure checks plus `rules.py` |
| `render.py` | `show` and `stats` |
