# Rune Grid

The letter-grid race: everyone gets the same grid of letter dice and finds
as many words as they can before the timer runs out. Two room modes, on
the room protocol (`shared/room-protocol.md`) like the others:

| Mode | Name | Players |
|---|---|---|
| `rune` | Rune Grid | 2–6, everyone for themselves |
| `runeteam` | Team Rune Grid | 2–6, two teams of 1–3 (Copper and Cobalt), the same size to start |

There is no co-op Rune Grid. The rules live in `server/src/rules/rune.ts`;
the room wires them up in `server/src/room/room.ts`.

## The rules

- **The grid:** 4×4, 5×5 or 6×6 letter dice, rolled fresh for every round
  (16 dice for 4×4, 25 for 5×5, those 25 and 11 more for 6×6). A Q face is
  the tile `QU`. A grid is rolled again (a few times at most) until it
  holds plenty of words.
- **Words:** join touching tiles, across, up and down or diagonally, using
  each tile once in a word. At least the shortest length (3, 4 or 5
  letters; `QU` counts as two). The words are the game's accepted list, the
  same as the puzzles' bonus words (3–8 letters, no names or rude words).
- **Points:** a word scores its length less two, at least 1: 3 letters 1,
  4 letters 2, 5 letters 3, and 1 more for each letter after that. A
  **unique** word, one nobody else found, scores **double**. Points are
  only worked out when the round ends, when everyone's words are known.
- **A game** is 1, 3 or 5 rounds, each on a fresh grid, won on the total
  points. Tied on points, more words found wins. Still tied after the last
  round, the leaders play a **tiebreaker round** (only they race in Rune
  Grid; everyone in Team Rune Grid), which adds to the totals; after 3
  tiebreakers the leaders share first place.
- **Between rounds** the standings show for 30 s (as in Versus); everyone
  ready (`NEXT`) starts the next round sooner.
- **Leaving mid-game:** the player is out, their points kept. One racer
  (or one team) left ends the game by forfeit.
- **XP** as for a Versus series, at the heat Auto would pick (the median
  level), written as a Versus match: 5 per round played, 10 per round won,
  30 for winning the game. No hints, embers or Scrap Bin.

### Team Rune Grid

The host picks how a team scores (`teamScoring`):

- **`pooled`** (the default): a team shares one list of words. A word one
  teammate has found is the team's: a teammate who sends it gets `already`
  with `by` the teammate, and teammates see each other's words as they
  come (`RUNE_WORD`). Unique means the other team didn't find it. The team
  scores its list.
- **`sum`**: everyone scores as in Rune Grid (unique means nobody else at
  all found it, teammates included), and a team scores its players' points
  added up.

Either way the team with more points takes the round and, on the total,
the game; a tie on points goes to more words.

## Messages

Only what Rune Grid adds or changes. Everything else (READY, TEAM, START,
AGAIN, NEXT, LEAVE, EMOTE, CHAT, mode switching) is as in the room
protocol. HINT is refused (`no_hints`).

### CONFIG `rune` (host, lobby or results)

```json
{"op": "CONFIG", "rune": {"size": 5, "seconds": 90, "min": 4, "rounds": 3, "teamScoring": "sum"}}
```

Any of: `size` 4 · 5 · 6, `seconds` 30 · 60 · 90 · 120 · 180, `min`
3 · 4 · 5, `rounds` 1 · 3 · 5, and (Team Rune Grid only) `teamScoring`
`"pooled"` · `"sum"`. At least one; anything else is `bad_message`, as are
`series`, `variant`, `heat`, `rule` and `scoring` in a Rune Grid room.
Defaults: 4×4, 180 s, 3 letters, 3 rounds, pooled. They apply from the
next START or AGAIN and are kept through mode switches.

### LOBBY

Adds `rune: {size, seconds, min, rounds, teamScoring}`: the next game's, or
during a game the game's own. Team Rune Grid players carry `team`. No
`series`, `variant`, `rule` or `scoring`.

### ROUND_START

```json
{"op": "ROUND_START", "game": "rune", "round": 1, "rounds": 3, "tiebreak": false,
 "players": ["u1", "u2"], "size": 4, "tiles": ["C", "A", "T", "S", "QU", …], "min": 3, "seconds": 180,
 "startsAt": 0, "endsAt": 0, "serverNow": 0, "heat": 2, "totals": {"u1": 0, "u2": 0},
 "teams": {"u1": 0, "u2": 1}, "teamScoring": "pooled", "teamTotals": [0, 0]}
```

`tiles` are row by row. `players` race this round (a tiebreaker: only the
tied; anyone else watches). The words on the grid are never sent before
the round ends. The last three fields are Team Rune Grid only.

### SUBMIT and WORD_RESULT

SUBMIT as usual (`word`, `seq`); the app only sends words traced on the
grid. WORD_RESULT `result`:

- `found`, with `points` (before any doubling): a new word.
- `already`, with `by`: found already, by the sender, or a pooled teammate.
- `invalid`: not a word on this grid (or shorter than `min`). Ten in five
  seconds lock the sender out for three, as everywhere.
- `rate_limited`, `too_late` as usual. A watcher's SUBMIT is
  `ERROR not_playing`.

### RUNE_TALLY, RUNE_WORD

- `{"op": "RUNE_TALLY", "id": "u1", "words": 7}`: to everyone, after each
  word found: how many words `id` has. Never the words.
- `{"op": "RUNE_WORD", "word": "CATS", "by": "u1", "points": 2}`: pooled
  teams only, to the finder's teammates.

### ROUND_END

```json
{"op": "ROUND_END", "game": "rune", "round": 1, "tiebreak": false, "size": 4, "tiles": […],
 "found": {"u1": [{"word": "QUILT", "points": 6, "unique": true}, …], "u2": […]},
 "points": {"u1": 9, "u2": 4}, "winner": "u1",
 "words": ["QUILTS", "QUILT", …], "total": 87,
 "totals": {"u1": 9, "u2": 4}, "next": {"round": 2, "tiebreak": false, "players": ["u1", "u2"]},
 "standingsEndsAt": 0,
 "teamPoints": [9, 4], "team": 0, "teamTotals": [9, 4]}
```

- `found`: each racer's words in the order found, with what each scored.
- `points`: this round; `totals`: the game so far.
- `winner`: who scored the most (more words breaking a tie); `null` for a
  tie, nobody scoring, or a team game, where `team` is the round's team
  (`null` for a tie).
- `words`: every word on the grid, longest first, at most 300 of `total`.
- `next` and `standingsEndsAt` are `null` when the game is over; SERIES_END
  follows.

### SERIES_END

The Versus shape (`podium`, `winner`, `team`, `teamTally`, `forfeit`,
`rounds`, `xp`, `scoring: "total"`, `tiebreak`), with `game: "rune"` and
`history: []`. In the podium `score` is the points, `wins` the rounds won.
It adds:

```json
"rune": {"settings": {…}, "history": [ROUND_END without totals, next and standingsEndsAt, …],
         "words": {"u1": 12, "u2": 9}, "teamTotals": [21, 14], "teamWords": [12, 9]}
```

### SNAPSHOT

During a countdown or round, `round` is the ROUND_START plus `mine` (the
receiver's words, or in pooled teams their team's, each `{word, by,
points}`) and `tally` (everyone's word count). During standings and
results, `standings` is the last ROUND_END; during results, `results` is
the SERIES_END.

## Records

A finished game is written as a Versus series (`matches.mode = "vs"`),
its summary adding `game: "rune"` and `rune` (the settings); `score` is
points, `wins` rounds won and `words` words found.
