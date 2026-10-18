# Survival (shared contract)

A variant of all three modes. One unforged word at a time is **heated**: it
glows, with a countdown. Forge it before the countdown ends and the next
word heats up. If the countdown runs out, the word **melts** (the app plays
a melting animation) and the round ends. Other words can be forged any time;
forging them doesn't stop the clock, but crossing letters help with the
heated word.

- **Solo:** "The Crucible", an endless run of puzzles (below). A melt ends the run.
- **Co-op:** the team shares one heated word. A melt ends the round.
- **Versus:** each racer has their own heated word on their own mold. The first melt by anyone ends the round for everyone, and the racer who melted can't win it.

Everything in `room-protocol.md` applies unless this says otherwise.

## Shared rules

**Which word heats.** At the start of each round (or each solo puzzle) the
slots are put in a random order, except that the first one is one of the
shortest. The heated word is always the first slot in that order that isn't
complete. Each mold works it out on its own: the team's mold in co-op, and
each racer's own mold in Versus. A slot that completes in any way (forged,
filled in by crossings, or revealed by hints) counts as done.

**Countdown.** In milliseconds, for a slot of `len` letters at heat tier
`heat` (1–6), after `saved` words saved so far this round:

```
survivalHeatMs(len, heat, saved) =
  max(8000, round((6000 + 2500 * len) * HEAT_FACTOR[heat] * 0.97 ^ min(saved, 20)))

HEAT_FACTOR = {1: 1.6, 2: 1.45, 3: 1.3, 4: 1.15, 5: 1.0, 6: 0.9}
```

For example, at heat 1 a 3-letter word gets 21.6 s and a 6-letter word gets
33.6 s. At heat 6 a 4-letter word gets 14.4 s.

- `saved` counts heated words completed before their deadline: per team in co-op, per racer in Versus, and over the whole run in solo.
- The first countdown starts at `startsAt` (when the countdown phase ends).
- Each later countdown starts the moment the previous heated slot completes.
- The server is the referee in rooms. A `SUBMIT` that it handles before the deadline plus a **300 ms grace** counts.

## Rooms (co-op and Versus)

### Client → server

| Op | Fields | Notes |
|---|---|---|
| `CONFIG` | `variant`: `classic` · `survival`, and/or `series` (Versus only) | Host only, in `lobby` or `results`. At least one field. Co-op with `series`, or a bad value, gets `bad_message`. A changed variant applies from the next `START` or `AGAIN`. The `series` rule from room-protocol.md (lobby only) is unchanged. |

### Server → client

| Op | Fields |
|---|---|
| `LOBBY` | adds `variant` (`classic` by default). |
| `ROUND_START` | adds `variant`. In survival it also has `heated` (as `HEATED` without `op`): the first heated slot, which is the same for everyone. `endsAt` becomes a safety cap of `startsAt` + 10 minutes, and the app hides the round clock in survival. |
| `HEATED` | `slot`, `startsAt`, `deadline`, `durationMs`, `saved`, `serverNow`. Co-op: sent to everyone when the team's heated slot changes. Versus: sent to the racer only, about their own mold. It follows the `CLAIMED`, `REVEAL` or `WORD_RESULT` that completed the previous one. When every slot is complete there is no `HEATED`; the round ends `complete` or `finished` as usual. |
| `MELT` | `slot`, plus `id` (whose mold) in Versus. Sent to everyone, straight before `ROUND_END`. The app plays the melt (about 2.4 s) before showing results or standings. |
| `ROUND_END` | Co-op: `reason` adds `melted`; adds `variant`, `saved` (team), and `melted`: `{slot}` or `null`. Stars and XP for a melted round are worked out as for `timeout`. Versus: `reason` adds `melted`, `how` adds `survived`; adds `variant`, `saved`: `{userId: n}`, and `melted`: `{id, slot}` or `null`. |
| `SERIES_END` | Versus: each `history` entry of a survival round adds `melted` and `saved`, as in its `ROUND_END`. |
| `SNAPSHOT` | `round` adds `variant` and, in survival, `heated` (co-op: the team's; Versus: the receiver's own; `null` for someone watching or when no slot is heated) and `saved` (co-op: a number; Versus: the receiver's). |

### Rules worth spelling out

- **Winning a Versus survival round:**
  - Filling your whole mold still wins at once (`finished`).
  - On a melt, the winner is the racer with the most letters filled among those who didn't melt, with ties going to whoever reached that count first (`how: "survived"`).
  - If none of them has filled a letter, there's no winner (`how: "none"`).
  - At the 10-minute cap, it's resolved as a `timeout`.
- **Disconnects:**
  - Co-op: the team's countdown pauses only while no player is connected.
  - Versus: a disconnected racer's countdown pauses while they're away. Their mold is frozen anyway.
  - On resume, the deadline moves on by the pause, and `HEATED` is sent again.
  - A racer who leaves the series can no longer melt.
- **Hints (co-op):** allowed as in classic. Letters they reveal can complete the heated word, which counts as saved.
- **XP:**
  - Co-op: `coopRoundXp` plus 2 per saved word, up to +30.
  - Versus: unchanged.
- **Records:** match records keep `variant` if they have room for it. Classic rooms behave exactly as before.

## Solo: The Crucible

The app runs it offline from the campaign puzzles.

- **Puzzles:**
  - Each one is picked at random from campaign stages up to `max(furthest stage finished, 20)`.
  - Small ones come first, and the run escalates.
  - Its heat tier is the puzzle's own `heat`.
- **Between puzzles:**
  - Clearing a puzzle moves on to the next after a short break. The next countdown starts when it appears.
  - `saved` carries over for the whole run.
- **Allowed:** Turn and hints (Hammer Strike, Chisel, Spark Shower) from the player's own stock.
- **Not in survival:** pickups, gilded cells and the Scrap Bin. Bonus words show as usual but count for nothing.
- **Pausing:** leaving the app pauses the countdown.
- **Ending:** a melt ends the run, or the player can leave (counted like a melt). The run's result is sent once, below.

### `POST /v1/survival/solo`

Signed-in players only. The app queues the run (like the solo sync queue) and
sends it when it can.

```json
{
  "runId": "uuid",
  "startedAt": 1792200000000,
  "endedAt": 1792200300000,
  "saved": 9,
  "puzzles": [
    {"stage": 12, "puzzleId": "c-012", "foundWords": ["ORE", "IRON"], "hintsUsed": {"hammer": 1}, "cleared": true}
  ]
}
```

**Rejected with 400 `invalid_run`:**

- More than 50 puzzles, or a puzzle that isn't shaped right.
- `stage` isn't in the campaign, or `puzzleId` isn't that stage's puzzle.
- `stage` is beyond `max(highest stage in solo_results + 10, 30)`.
- A found word isn't a grid word of that puzzle.
- `cleared` is set, but the found words plus the hints used can't fill the mold. Use the same check as sync's `incomplete`.
- `startedAt`/`endedAt` are more than 24 h old, in the future (10 min skew), or out of order.
- The run is under 1 s per found word.

**Duplicates:** a `runId` already recorded returns `200` with the original result and `"duplicate": true`.

**XP and hints:**

- XP is 1 per found grid word plus 8 per cleared puzzle, at most 150 per run. Level-up rewards apply as usual.
- The hints used are taken off the stock, never below zero (clamp as sync does).
- Found words count towards the `words` and `long_words` Work Orders, and cleared puzzles towards `solo_puzzles`, as sync's play facts do, if that fits without reshaping orders.

**Response:** `{profile, xp: {xp, level, levelUps, rewards}, best: {puzzles, words, saved, at}, newBest, duplicate?}`.

- `best` is the player's best run: most cleared puzzles, then most words, then most saved.
- The profile body (everywhere it's returned) gains `survivalBest`: that object, or `null`.

**D1 migration `0006_survival.sql`:**

- `survival_runs (uid, run_id, at, puzzles, words, saved, xp, PRIMARY KEY (uid, run_id))`
- `survival_best (uid PRIMARY KEY, puzzles, words, saved, at)`
- Both are removed with the account.

## As built (server)

Rooms:

- **Classic is untouched:** survival fields (`variant`, `heated`, `saved`, `melted`) only appear in survival rooms and rounds, and `LOBBY.variant` only while it's `survival`. A message without `variant` is classic. (Existing clients and tests pin the classic messages exactly.)
- **CONFIG:** `variant` in the lobby or results, `series` (Versus) in the lobby only; with both, the lobby only. No field, a bad value, or `series` in co-op is `bad_message`; then `wrong_phase`, then `not_host`. An unchanged value sends no `LOBBY`. A Versus series keeps the variant it started with, sudden death included.
- **`heated`** in `ROUND_START` and `SNAPSHOT` has the `HEATED` fields, `serverNow` included. In Versus everyone gets `ROUND_START.heated`, watchers too.
- **Order:** co-op `CLAIMED` or `REVEAL`, then `HEATED` to everyone. Versus `WORD_RESULT`, `PROGRESS`, then `HEATED` to each of the racer's open sockets. On a rejoin that resumes a countdown: `WELCOME`, `SNAPSHOT` (already resumed), then `HEATED`.
- **Grace:** the melt is the alarm at `deadline` + 300 ms, so anything handled before it counts. A co-op `HINT` still waiting on D1 when the melt comes is refunded (`wrong_phase`).
- **Pauses:** `startsAt` moves on with `deadline`, so `deadline − startsAt` is always `durationMs`. Time before the round's `startsAt` isn't a pause. A countdown whose melt is already due can't be paused.
- **Melts:** in Versus the earliest melt goes first; an exact tie goes to the racer who joined first. A melt due after the 10-minute cap doesn't happen; the cap is a `timeout`.
- **Wire:** `MELT` is `{slot}` in co-op and `{slot, id}` in Versus. `ROUND_END.melted` is `{slot}` in co-op and `{id, slot}` in Versus. Versus `saved` lists every racer in the round.
- **SNAPSHOT:** co-op `round.heated` is `null` once the round is over (results still carry the finished round). In Versus, someone watching (a racer out of the series too) gets `heated: null`; `saved` is the receiver's own, and 0 if they didn't race.
- **Stars:** a completed co-op survival round is timed against the 10-minute cap (★★★ inside 5 minutes).
- **Records:** `matches.summary` gets `variant: "survival"`, plus `saved` and `melted` in co-op. `mode` stays `coop` or `vs`. Everyone in the round gets the +2 per saved bonus, players who left too.

The Crucible (`POST /v1/survival/solo`):

- Like solo sync, it needs a token but not a set-up account. `runId` is 1–64 of `A–Z a–z 0–9 _ -`. An empty `puzzles` list is fine (0 XP).
- **Order of checks:** the body's shape, then the duplicate check, then the rest. So a run already recorded answers as a duplicate even if it would now fail (more than 24 h old, say). Also refused: `saved` greater than the run's grid words. The `400 invalid_run` has a `message` saying what's wrong.
- `503 campaign_unavailable` (empty campaign table) and `409 sync_conflict` mean keep the run and retry, as in sync.
- **Counting:** words are each puzzle's distinct found words, so a word found in two puzzles counts twice. `at` (runs and best) is the run's `endedAt`. `survival_runs.puzzles` is puzzles cleared. A tie with the best isn't a new best.
- **Duplicate answer:** `xp.xp` is what the run was given; `levelUps` 0 and `rewards` zero (they were paid the first time); `level` is the current one; `best` is the current best; and `newBest` says whether this run is still the best. Other answers have no `duplicate`. Hints clamped aren't reported; the profile is the truth.
- **Also written:** found words count as words forged and longest word, as in every mode (campaign progress and `soloDone` don't change). `xp_events` gets `source: "survival"` with the run id as `ref`, when the XP is above 0.
- **Work Orders:** found words count as forged words. That feeds `letter_hunt` as well as `words` and `long_words`, as sync's do. Cleared puzzles count as `solo_puzzles`, the weekly 15 included. Nothing counts for `no_hints`.
- The tables use `uid`, as written above (the older tables say `user_id`).
