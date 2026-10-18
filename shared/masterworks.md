# Masterworks (shared contract)

Some campaign puzzles hide a **gilded cell**: a grid cell with a gold edge.
Forging the word that covers it (the same way you collect an ember pickup)
earns a **blueprint piece**. Pieces build twelve legendary **Masterworks** in
order; finishing one grants a reward, and the finished pieces hang in the
**Armory** on your profile.

## Gilded cells

Like hint pickups (`shared/pickups.md`), gilded cells are decided by a seed
made from the player and the puzzle, so the server can check claims without
storing them. Same `fnv1a32` and `mulberry32`; same `userId` (or install id)
and `puzzleId`; same cell order (letter cells sorted by row, then column).

```
seed = fnv1a32(utf8(userId + ":" + puzzleId + ":gilded"))
rand = mulberry32(seed)
if rand() >= 0.25: no gilded cell
index = floor(rand() * cellCount)
while index is one of the puzzle's pickup cells (for the same player and level):
    index = (index + 1) % cellCount
    (if every cell is a pickup cell: no gilded cell)
```

At most one gilded cell per puzzle. Only the campaign has them (not the Daily
Commission, co-op or Versus).

## Collecting

A piece is collected when a slot that covers the gilded cell is completed,
whether by a typed word, by hints, or by filling in from its crossings
(exactly as for pickups).

The solo sync entry (`docs/TECH.md` §8) gets an optional field
`"gilded": [<cell index>]` (empty or missing when none was collected; at most
4 entries, each 0–1000, or the entry is `invalid_entry` with `detail:
"gilded"`). The server accepts the claim only if that cell is the gilded cell
it computes for the entry's `pickupSeed` and puzzle, with the player's level
when the puzzle started (as for pickups). The seed must be one the account may
use for pickups: its own uid, an install id it used before, or a new one while
it has fewer than 5. A wrong claim is ignored (the rest of the entry still
counts). Each campaign stage can give a piece only once, because each stage
syncs once.

An accepted entry's result (`results[i]`) then has two more fields, each
only present when it applies:

- `"gilded": [<cell index>]`: the piece was collected.
- `"masterwork": {"id": "horseshoe", "reward": <reward as granted>}`: that
  piece finished a Masterwork. The entry's `xp` stays the puzzle's own XP;
  its `level`, `levelUps` and `rewards` (level-up rewards) include any
  level-up from the Masterwork's XP.

## The Masterworks

Twelve, made in this order. The app owns their names, art and text; the
server only needs the piece counts.

| # | id | Pieces |
|---|---|---|
| 1 | `horseshoe` | 6 |
| 2 | `bell` | 6 |
| 3 | `dagger` | 8 |
| 4 | `lantern` | 8 |
| 5 | `helm` | 8 |
| 6 | `shield` | 10 |
| 7 | `axe` | 10 |
| 8 | `crown` | 10 |
| 9 | `longsword` | 12 |
| 10 | `astrolabe` | 12 |
| 11 | `warhammer` | 12 |
| 12 | `anvil` | 12 |

114 pieces in all. Pieces collected after the twelfth is finished are still
counted but build nothing.

**Finishing a Masterwork** (the piece count reaches the running total 6, 12,
20, 28, …, 114) grants, automatically during the sync: **100 XP, 1 Chisel and
1 Spark Shower** (with the usual swap to Hammer Strikes for locked types; see
the rewards section of `shared/forge-board.md`). The level that decides the
swap is the one after the puzzle's own XP. The reward comes at the end of the
puzzle, like level-up rewards, so it can't pay for hints used in it. The XP is
recorded as its own XP event (`source: "masterwork"`, `ref`: the Masterwork's
id) and counts towards the Weekly Trials.

## Profile

The profile gains `"masterworks": {"pieces": <total collected>}`. The app
works out the current Masterwork and its progress from the table above.

## Test vectors

The server's tests and the app's tests must both reproduce these, computed
with the algorithm above.

Pickups for the same inputs are shown in brackets, since the gilded cell
steps around them. The first seven come from the app's implementation; the
last three cover a step that wraps round to cell 0, a step past two pickups,
and a grid whose only cell is a pickup cell.

| userId | puzzleId | cellCount | level | gilded index |
|---|---|---|---|---|
| `user-123` | `c-0010` | 30 | 20 | none [pickup `(10, chisel)`] |
| `abc` | `c-0001` | 12 | 1 | none [no pickups] |
| `friend-7` | `c-0200` | 40 | 30 | 14 [no pickups] |
| `user-123` | `c-0074` | 30 | 12 | 23 [pickup `(19, sparks)`] |
| `u1` | `c-0003` | 9 | 5 | 4 [no pickups] |
| `user-123` | `c-0025` | 3 | 20 | 1 [pickup `(0, hammer)`; raw index 0 steps to 1] |
| `user-123` | `c-0025` | 12 | 20 | 4 [pickup `(3, hammer)`; raw index 3 steps to 4] |
| `user-123` | `c-0205` | 3 | 20 | 0 [pickup `(2, sparks)`; raw index 2 wraps to 0] |
| `user-123` | `c-1306` | 3 | 20 | 2 [pickups `(0, hammer)`, `(1, hammer)`; raw index 0 steps to 2] |
| `user-123` | `c-0025` | 1 | 20 | none [pickup `(0, hammer)` covers every cell] |
