# Hint pickup seeding (shared contract)

In the solo campaign, whether a puzzle has a hint pickup, which cell it's in
and what it gives are decided by a seed made from the player and the puzzle.
The app and the server use the same algorithm, so the server can check
claimed pickups without storing them. Both implementations **must** reproduce
the test vectors below.

## Algorithm

```
seed  = fnv1a32(utf8(userId + ":" + puzzleId))
rand  = mulberry32(seed)                  // each call returns a float in [0, 1)

if rand() >= 0.20: no pickups
count = min((rand() < 0.15) ? 2 : 1, cellCount)
for each pickup:
    index = floor(rand() * cellCount)     // cells = the grid's letter cells, sorted by row, then column
    while index already used: index = (index + 1) % cellCount
    t = rand()
    kind = t < 0.70 ? hammer : t < 0.95 ? chisel : sparks
    if kind == chisel and level < 5:  kind = hammer
    if kind == sparks and level < 12: kind = hammer
```

`level` is the player's Smith Level when the puzzle starts.

### fnv1a32
Offset basis `0x811C9DC5` and prime `0x01000193`, applied to each byte of the
string, with all arithmetic mod 2³².

### mulberry32
```js
function mulberry32(a) {
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
```

## Test vectors

| Input | Expected |
|---|---|
| `fnv1a32("")` | `0x811c9dc5` |
| `fnv1a32("a")` | `0xe40c292c` |
| `fnv1a32("wordsmith")` | `0xb0870248` |
| first three outputs of `mulberry32(1)` | `0.6270739406`, `0.0027357212`, `0.5274470400` (to 10 decimal places) |

| userId | puzzleId | cellCount | level | pickups `(index, kind)` |
|---|---|---|---|---|
| `user-123` | `c-0010` | 30 | 20 | `(10, chisel)` |
| `user-123` | `c-0010` | 30 | 1 | `(10, hammer)` |
| `user-123` | `c-0032` | 24 | 3 | `(7, hammer)` |
| `abc` | `c-0001` | 12 | 1 | none |
| `user-123` | `c-0012` | 9 | 50 | `(0, hammer)` |
| `friend-7` | `m-00033` | 40 | 30 | `(29, hammer)`, `(2, hammer)` |
| `user-123` | `c-0074` | 30 | 12 | `(19, sparks)` |
| `user-123` | `c-0074` | 30 | 11 | `(19, hammer)` |
| `user-123` | `c-0146` | 3 | 12 | `(2, hammer)`, `(0, hammer)` (collision step) |
