# Puzzle format (shared contract)

Produced by `tools/puzzlegen`. Read by the app (`app/lib/engine/puzzle.dart`)
and, later, the server. Any change here must be made in all three places.

## Puzzle object

```json
{
  "id": "c-0001",
  "letters": "RTAE",
  "heat": 1,
  "cols": 4,
  "rows": 4,
  "words": [
    { "w": "TEAR", "x": 0, "y": 0, "d": "a" },
    { "w": "EAT",  "x": 1, "y": 0, "d": "d" },
    { "w": "RATE", "x": 3, "y": 0, "d": "d" }
  ],
  "bonus": ["ARE", "ART", "ATE", "EAR", "ERA", "RAT", "TAR", "TEA"]
}
```

| Field | Meaning |
|---|---|
| `id` | Unique ID. Campaign: `c-NNNN` (1-based stage number, zero-padded to 4). Multiplayer bank: `m-NNNNN`. |
| `letters` | The anvil letters, uppercase A–Z, length 4–8. Order is the default shuffle and never spells the longest word. |
| `heat` | Difficulty tier 1–6: Ember, Dull Red, Cherry Red, Orange, Yellow, White Heat. |
| `cols`, `rows` | Grid size. Each is 10 or less. The grid is cropped tightly, so every row and column holds at least one letter. |
| `words` | The grid answers. `w` is the uppercase word, `x`/`y` is the zero-based column/row of its first letter, and `d` is `"a"` (across, left to right) or `"d"` (down, top to bottom). |
| `bonus` | Every other accepted word that can be made from `letters`, uppercase and sorted. It never includes a grid word. |

Multiplayer bank entries also carry `"size": 1..4`, the number of players the
puzzle is sized for. Versus always uses size 1.

## Rules every puzzle satisfies

1. Every grid word and bonus word has 3+ letters and can be made from `letters`, using each tile no more often than it appears.
2. **At least one grid word uses all of `letters`.**
3. No word appears twice, whether in the grid or in the bonus list.
4. Where two words cross, the shared cell has the same letter in both.
5. **Proper crossword spacing:**
   - Every horizontal or vertical run of 2 or more letters is exactly one grid word.
   - The cells just before a word's first letter and just after its last letter are empty.
   - No two across words overlap, and no two down words overlap.
6. All grid words are connected through their crossings.
7. No word on the blocklist appears anywhere.

## Campaign file: `app/assets/campaign/campaign.json`

```json
{
  "version": 1,
  "chapters": [
    { "id": "tin", "name": "Tin", "first": 1, "count": 40 },
    { "id": "copper", "name": "Copper", "first": 41, "count": 50 }
  ],
  "puzzles": [ { "id": "c-0001", ... }, ... ]
}
```

- `puzzles[i]` is campaign stage `i + 1`, and its `id` is `c-` followed by the stage number zero-padded to 4 digits.
- The chapters cover the stages in order, with no gaps.
- Chapters, counts and heat ranges are listed in `docs/DESIGN.md` §2.4.
