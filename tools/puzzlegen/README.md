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
python3 -m puzzlegen grow --seed 3                 # add a part of new puzzles to the bank
python3 -m puzzlegen refresh ../../app/assets/campaign/campaign.json   # new bonus lists, same grids
python3 -m puzzlegen validate ../../app/assets/campaign/campaign.json
python3 -m puzzlegen validate ../../server/data/mp_bank.json   # also checks it shares no letters with the campaign
python3 -m puzzlegen show ../../app/assets/campaign/campaign.json c-0001 c-0300
python3 -m puzzlegen stats ../../app/assets/campaign/campaign.json

python3 -m unittest discover -s tests      # about 10 s
```

- `mp` reads the campaign file (`--campaign`, default the committed one) so
  multiplayer letter sets never repeat campaign ones. Generate the campaign
  first. It makes a whole new bank: to add puzzles to the committed one, whose
  ids rooms and players have seen, use `grow` (see "Growing the bank").
- `validate` exits non-zero and prints every problem. For a bank,
  `--campaign FILE` checks it against a campaign (automatic for the committed
  bank) and `--per N` checks the count per heat and size (a bank with parts
  carries its own counts).
- `stats` also prints answer quality per chapter and heat (`metrics.py`):
  `inv` = bonus words clearly better than the grid's worst word (quality 0.5+
  higher, very common or long, SCOWL <= 50), `missed` = very common words
  (quality 3.8+) left in the bonus list, `infl`/`plural` = share of grid
  words that are plain inflections / plurals, `no def` = share the app's
  dictionary has no meaning for, then mean and per-puzzle minimum zipf and
  quality.
- Each generation run writes a report (seeds, difficulty per stage, rejected
  seeds) to `reports/campaign.gen.json` / `reports/mp_bank.gen.json`; other
  `--out` paths get `<name>.gen.json` beside the output. `stats` shows it.
  A part added by `grow` gets `reports/mp_bank.partN.gen.json`.
- `refresh FILE` recomputes every bonus list from the current word lists and
  changes nothing else (ids, letters, grids and order stay, so players'
  progress still matches). Run it on the campaign and the bank after the word
  lists change. It exits non-zero, naming the puzzles, if a grid answer is no
  longer accepted: those need a new grid.

Same inputs and the same `--seed` give byte-identical output (nothing depends
on `PYTHONHASHSEED`). Runtime on one core: campaign about 35 s, bank about
2.5 min, `grow` with the current part sizes about 4.5 min.

## Word lists

`fetch` downloads into `data/raw/` (git-ignored), checks each file's sha256
against the value recorded in `puzzlegen/fetch.py`, and writes:

| File | Contents |
|---|---|
| `data/accepted.txt` | Every accepted (bonus) word: ENABLE + SCOWL levels <= 70, minus the blocklist and the names. 3-8 letters, a-z. |
| `data/names_exclude.txt` | Names, places, brands and nationalities that ENABLE or SCOWL also list as lowercase words (`boston`, `abigail`, `berlin`). Never accepted. See Names below. |
| `data/scowl_levels.tsv` | `word<TAB>level`, the smallest SCOWL size level (10 = most common, 70) the word appears at. |
| `data/scowl_only.txt` | Accepted SCOWL words that are not in ENABLE (`gonna`, `email`). Never grid answers. |
| `data/blocklist.txt` | LDNOOBW single English words + `blocklist_extra.txt`, with simple inflections, plus every word containing a `*stem*` entry. |
| `data/freq.tsv` | `word<TAB>zipf`: how common each accepted word is in real use (wordfreq 3.1.1 `zipf_frequency(word, "en")`, 2 decimals; words it doesn't know are absent and count as 0). The main input to answer quality. |
| `data/name_senses.txt` | Accepted words SCOWL also lists capitalised (`mike`, `harry`, `amazon`): their frequency counts the name too, so quality caps it. |
| `data/LICENSES.md` | Sources, licences and the verbatim SCOWL copyright notice. |

Sources: ENABLE (public domain), SCOWL 2020.12.07 (`final/english-words.*`
and `final/american-words.*` for the words; its proper-name, capitalised and
other regions' word lists for the names; permissive notice kept in
`data/LICENSES.md`), the LDNOOBW English list (CC BY 4.0), and wordfreq 3.1.1
for `freq.tsv` (data CC BY-SA 4.0, so `freq.tsv` is too; credits in
`data/LICENSES.md`). wordfreq is the one non-stdlib package and only `fetch`
uses it (`pip install wordfreq==3.1.1`); without it `fetch` keeps the
committed `freq.tsv`. Generation only reads the committed file.

Hand-curated, committed files:

- `data/blocklist_extra.txt`: extra blocked words (slurs, crude words the
  LDNOOBW list misses). `*stem*` lines block every word containing the stem.
  Re-run `fetch` after editing it.
- `data/names_keep.txt` and `data/names_extra.txt`: the hand-kept edges of
  the names list (below). Re-run `fetch` after editing them, then `refresh`.
- `data/answer_exclude.txt`: words that stay valid bonus words but never go in
  a grid (interjections, letter plurals like `IFS`, archaic or British forms,
  odd inflections SCOWL ranks as common such as `GROSSES`, and dark or
  sensitive words such as `MURDER`). Read at generation time, so no `fetch`
  needed. When `show` turns up a bad answer, add it here and regenerate.
  Most bad answers are now kept out by quality (below), so the list is for
  words whose frequency hides that they are poor answers: clipped or informal forms (`INFO`, `DEMO`, `REPS`,
  `GIMME`) and archaic ones (`NIGH`, `THYSELF`).
- `data/not_inflections.txt`: words that only look like an inflection of a
  shorter word (`seed` is not `see` + d). Read at generation time.

## Names

Names don't count as words. ENABLE and SCOWL's lowercase lists hold hundreds
of words that people know only as names, places, brands or nationalities,
through an obscure lowercase sense (`abigail` a lady's maid, `boston` a card
game, `ben` a mountain). `fetch` writes them to `data/names_exclude.txt` and
leaves them out of `accepted.txt`, so they are never bonus words or grid
answers, and the app's dictionary (tools/dictgen) has no entry for them.

A word is a name when both hold (`build_names` in `fetch.py`):

1. SCOWL lists it capitalised at level <= 60 (`NAME_LEVEL`): a proper name
   (`final/english-proper-names.*`, `american-proper-names.*`: people, places,
   brands) or another word written with a capital (`english-upper.*`,
   `american-upper.*`: nationalities, languages, religions, characters). Only
   plain capitalised entries count: `Boston`, not `IBM` or `McCoy`.
2. No SCOWL word list for any spelling region (American, British, Canadian,
   Australian) has it in lowercase at level <= 60 (`COMMON_LEVEL`). The
   British lists count, so `grey`, `armour` and `tyre` stay.

So `china`, `bill`, `mark`, `rose`, `jack`, `may`, `will`, `amber`, `amazon`
and `google` stay (lowercase at level 10-50), while `abigail`, `boston`,
`berlin`, `brazil`, `ben` and `bertha` go (lowercase at level 70, 80 or not at
all). The levels come from reading the results: names SCOWL only has at 70+
are mostly obscure, and their lowercase words rarely read as names
(`boreal`, `pinot`, `raj`); lowercase senses at 55-60 are mostly ordinary words
(`angelica`, `corvette`, `gestalt`, `java`, `kelvin`).

Then:

- `data/names_keep.txt` keeps real words whose lowercase sense SCOWL ranks
  too rare for the rule: `adonis`, `bonnie`, `chile`, `gothic`, `max`,
  `merlot`, `savannah`, `utopian`, ...
- `data/names_extra.txt` drops names the rule misses: names with a lowercase
  sense at 55-60 (`barbie`, `batman`, `carter`, `ted`, `dutch`, `viking`),
  `japan` and `morocco` (50), and a few well-known names SCOWL only lists at
  70+ (`abba`, `wigan`).
- Plural and verb forms of a name go too (`bostons`, `abigails`, `burked`),
  unless SCOWL ranks the form as a common word (`dee` goes, `deed` stays) or
  it is a form of another word (`lased` is `lase` + d). Forms of a common word
  are never names (`easts`, `concords`), and forms of a kept word stay.
- `fetch` prints any keep or extra entry that no longer makes a difference.

The current list has 1,010 words: 575 found by the rule, 64 from
`names_extra.txt` and 371 forms of those; `names_keep.txt` (45 entries) saves
51 words. Slurs found while reading the list (`abo`, `sambo`, `kaffir`, ...)
went into `blocklist_extra.txt` instead.

## Answer quality

Every answer-eligible word gets a quality score (`quality.py`), on the Zipf
scale (log10 of uses per billion words: 5 = `salt`, 3 = `gnat`):

    quality = 0.7 * zipf' + 0.3 * prior(SCOWL level) + length adjustment
              - inflection penalty

- `zipf'` is the word's frequency from `freq.tsv`. Above 5 it counts only 30%
  (everything up there is well known, and the top is grammar words). For a
  word that is also a name (`name_senses.txt`) it is capped at the level's
  prior + 0.6.
- `prior` is the typical zipf at the word's SCOWL level (10: 4.6, 20: 3.9,
  35: 2.8, 40: 2.4, 50: 2.0), which steadies the frequency where stray uses
  inflate it (`DIN`, `NIT`: abbreviations, foreign words, names).
- Length: 3 letters -0.6, 4 -0.2, 5 +0.2, 6 +0.45, 7 +0.65, 8 +0.8.
- A plain inflection of a shorter, reasonably common word loses points:
  plural or -s verb 1.0 (`SALTS`, `LASTS`), -est 0.6, -ed 0.5, -ing 0.4. Only
  40% of that when the form is at least as common as its base (`BUILDING`,
  `PARENTS`).
- A word the app's dictionary (`app/assets/dict`, built by tools/dictgen) has
  no meaning for is capped at 2.9: those are function words (`ITS`, `NOR`).

So `DIG` (3.5) beats `DIN` (2.7), `TAG` (3.7) beats `NIT` (2.4), `SALT` (4.2) beats
`SALTS` (2.4). The unit tests pin these pairs.

## Answer pools and heat tiers

A grid answer must be accepted, an ENABLE word, not in `answer_exclude.txt`,
at or below the tier's SCOWL level and at or above its quality floor.
Answers below the tier's "common" quality count as rare, and only a few are
allowed per grid (fewer early in a tier). The all-letter seed word needs the
tier's seed quality (4.2 for the first 30% of Ember) and is never a plural.
Plain inflections are capped at 30% of the grid's target word count (at
least 1).

| Heat | Letters | Grid words | Answers: quality, SCOWL | Rare (quality below) | Seed quality |
|---|---|---|---|---|---|
| 1 Ember | 4 | 3-5 | >= 3.4, <= 35 | none | >= 3.8 |
| 2 Dull Red | 5 | 5-7 | >= 2.6, <= 35 | up to 3 (below 3.4) | >= 3.6 |
| 3 Cherry Red | 6 | 7-10 | >= 2.6, <= 35 | up to 4 (below 3.2) | >= 3.4 |
| 4 Orange | 6-7 | 9-12 | >= 2.3, <= 40 | up to 3 (below 2.9) | >= 3.3 |
| 5 Yellow | 7 | 11-15 | >= 2.0, <= 50 | up to 4 (below 2.8) | >= 3.2 |
| 6 White Heat | 7-8 | 14-20 | >= 1.9, <= 50 | up to 5 (below 2.6) | >= 3.1 |

The floors ramp difficulty by heat: Ember's answers are all very common, and
from Orange up words like `GNAT` (2.4) can go in. SCOWL 55/60 were tried for
the top tiers but gave unfair answers (`GITS`, `LIDO`, `OPES`, `DACE`), so 50
is the ceiling. Bonus words come from the whole accepted list, so obscure
real words still count as bonus words.

## How a puzzle is built

1. **Seed.** Pick an unused seed word (no two puzzles anywhere share a letter
   multiset), the best-quality word of its letter multiset. Its letters are
   the anvil.
2. **Words.** Every sub-anagram comes from a sorted-letter signature index:
   all distinct sub-multisets of the anvil (at most 256) are looked up
   directly, so multiplicity is respected and it's fast.
3. **Priorities.** Priority = 2 x quality + a length bonus (3 letters 0 ...
   8 letters 3.0), less 0.3 x log2(1 + times the word is already a grid
   answer in this campaign or bank), so the same few words don't fill every
   grid. The rare-word and inflection caps are applied here, best words
   first.
4. **Layout.** The layout first gets only the best words: the target count
   plus a few (30%, at least 2). Only when no layout of those reaches the
   target (less a slack of 0-2 words in the top tiers) do more words join,
   best first. So a worse word goes in only when the better ones don't
   interlock. The seed word goes in first (across about 2/3 of the time), then
   words are added greedily. At each step the best few unplaced words compete,
   and each placement is scored on crossings, bounding-box growth and aspect
   ratio, plus noise. Every placement keeps the grid valid (proper crossword
   spacing, 10x10 limit), and positions are tracked incrementally. 16-40
   randomized restarts per puzzle (more for bigger tiers). The best layout wins
   on word count first, then crossings, density, an aspect ratio
   (cols/rows) inside 0.8-1.6, word priority, and how central the seed word
   is.
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
are the tutorial: 4 letters and exactly 3 words of 3-4 letters, all quality
4.2+ (as common as SCOWL's level 10) and no inflections.

The chapters get harder from Tin to Starmetal. Where the heat changes inside
a chapter (Copper, Steel, Damascus), the first puzzles of the new heat can be
easier than the last ones of the old heat, because the tiers' word ranges
overlap (Cherry Red goes up to 10 words, Orange starts at 9).

## Multiplayer bank

`mp` makes, for each heat 1-6 and size 1-4, `--per` puzzles (default 40, so
960 in all) with ids `m-NNNNN`, ordered by heat, then size, then difficulty. Size s
targets the tier's word count + 2*(s-1) and guarantees at least the tier
minimum + 2*(s-1), with these exceptions (see `MP_SIZE_MIN` in
`puzzlegen/tiers.py`):

- **Ember (4 letters) sizes 3 and 4** want 7-9 and 9-11 words, but a 4-letter
  anvil rarely makes more than 6-7 common words that also interlock. They
  guarantee 6 words. The current bank has 6-7 (size 3) and 6-11 (size 4).
- **Ember sizes 2-4** take any answer SCOWL calls common (<= 35) whatever
  its quality, allow plural seeds (seed quality >= 2.0) and don't cap
  inflections (`MP_ANSWER_Q`, `MP_SEED_Q`), so that enough words exist; the
  layout still prefers the best words. Their seeds are tried richest first,
  and a smaller size uses an anvil rich enough for a bigger size only when
  nothing else is left, so the bigger sizes (and later parts) still find
  some.
- Multiplayer sizes' extra words may all be rare ones (the rare cap grows by
  the extra word count).
- **White Heat size 4** wants 20-26 words, but a 10x10 grid tops out around
  22-23. The current bank has 20-23.

### Growing the bank

`grow --seed N` appends a **part** to the bank: new puzzles with ids after
the last one, ordered by heat, then size, then difficulty within the part,
using no letter set the campaign or the earlier parts use. Earlier puzzles
keep their ids, grids and order (their bonus lists are refreshed first), so
rooms' history of seen puzzles and players' results still match. The bank's
head lists its parts (`{"first", "count", "seed", "per"}`, `per` being
the count for each heat and size), and `validate` checks each part's counts
and order. Same bank, campaign, word lists and seed give the same part.

| Part | Ids | Made by | Per heat: size 1 / 2 / 3 / 4 |
|---|---|---|---|
| 1 | m-00001 to m-00960 | `mp --seed 2 --per 40` | 40 / 40 / 40 / 40 |
| 2 | m-00961 to m-03184 | `grow --seed 3` | 210 / 60 / 60 / 60; Ember 210 / 40 / 12 / 12 |

Both parts (and the campaign) were made again on 2026-10-24 when answers
started being chosen by quality: same ids, counts and order rules, new
grids. The server keeps the previous campaign (`campaign_previous`, see
server/README) so results played on it before the update still sync.

So Versus (size 1) has 250 puzzles per heat, and co-op 100 per heat and size,
except Ember: only about 90 unused 4-letter anvils make 5+ common words that
interlock, and about 30 make 6+, so Ember has 80 (size 2) and 52 (sizes 3, 4).
In part 2 Ember size 1 also takes answers of quality 2.6+ and seeds of
3.0+ (as Dull Red), since the campaign and part 1 used most of the very
common 4-letter anvils. `MP_GROW_PER`, `MP_GROW_ANSWER_Q` and
`MP_GROW_SEED_Q` in `puzzlegen/tiers.py` set what the next `grow` makes.

The Daily Commission picks from part 1's size-1 puzzles only
(`server/src/db/daily.ts`), so growing the bank never changes a date's
puzzle. The server loads the whole bank with `npm run db:bank` (one small SQL
statement per puzzle).

## Tests

`tests/` (unittest, about 10 s): anagram finder and multiplicity (and a check
against brute force on the real lists), the rule checker on a hand-made bad
grid for each kind of violation, a small generated batch per tier, the
tutorial, letter shuffling, determinism of the campaign and the bank, a bank
part (its counts, ids and unused letters), blocked words, the names rule on a
small made-up list and on the real one (names out, real words and their forms
in), `refresh`, answer quality (inflection detection, the score on made-up
words, real pairs such as `DIG` > `DIN` and `SALT` > `SALTS`, the pool caps,
a layout that keeps `DIN` and `NIT` out, no plural seeds, the metrics on a
hand-made puzzle), and the committed `campaign.json` / `mp_bank.json` passing
`validate` with no blocked words or names, its parts checks, and quality
bounds (inversions per puzzle and plural share; skipped if the files are
missing).

## Layout of the package

| Module | Role |
|---|---|
| `fetch.py` | downloads, derived lists (blocklist, names, frequencies), LICENSES.md |
| `words.py` | lexicon, levels, answer eligibility, sub-anagram index |
| `quality.py` | word quality score, inflection detection |
| `metrics.py` | answer-quality metrics for `stats` and the tests |
| `tiers.py` | heat tiers, chapters, multiplayer size rules |
| `layout.py` | crossword placement |
| `generate.py` | one puzzle: seed -> answers -> layout -> JSON; difficulty |
| `campaign.py` | campaign and bank assembly, bank parts (`grow`), `refresh`, output writing, reports |
| `rules.py` | every rule in shared/puzzle-format.md, for one puzzle |
| `validate.py` | campaign / bank structure checks plus `rules.py` |
| `render.py` | `show` and `stats` |
