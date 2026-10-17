# Masterworks (shared contract)

Some campaign puzzles hide a **gilded cell**: a grid cell with a gold edge.
Forging the word that covers it (the same way you collect an ember pickup)
earns a **blueprint piece**. Pieces build twelve legendary **Masterworks** in
order; finishing one grants a reward, and the finished pieces hang in the
**Armory** on your profile. This is Wordsmith's take on Word Trails' gold
tiles and jigsaw pieces.

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
`"gilded": [<cell index>]` (empty or missing when none was collected). The
server accepts the claim only if that cell is the gilded cell it computes for
the entry's `pickupSeed` and puzzle; a wrong claim is ignored (the rest of
the entry still counts). Each campaign stage can give a piece only once,
because each stage syncs once.

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
the rewards section of `shared/forge-board.md`). The XP counts towards the
Weekly Trials.

## Profile

The profile gains `"masterworks": {"pieces": <total collected>}`. The app
works out the current Masterwork and its progress from the table above.

## Test vectors

The server's tests and the app's tests must both reproduce these (filled in
by the implementation, computed with the reference algorithm above):

| userId | puzzleId | cellCount | level | gilded index |
|---|---|---|---|---|
