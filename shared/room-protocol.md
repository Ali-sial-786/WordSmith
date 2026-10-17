# Room protocol (shared contract, M3 co-op)

How the app and the RoomDO talk during co-op. Versus (M4) extends this.
Game rules are in `docs/DESIGN.md` §8, the referee design in `docs/TECH.md` §6,
and point and XP values in `server/src/rules/`. All messages are JSON
`{ "op": "...", ... }` over one WebSocket per room.

## Creating and joining

- `POST /v1/rooms` with `{mode: "coop"}` creates a room and returns `{code}`.
  - The code is 6 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`.
  - The creator becomes the host.
  - Requires a set-up account.
- `GET /v1/rooms/:code` returns `{code, mode, phase, host: {id, username}, players, maxPlayers}`, or `404 room_not_found`.
- `GET /v1/ws/room/:code` upgrades to a WebSocket, offering subprotocols `wordsmith.v1, <ID token>` (like the hub).
  - The Worker looks up the player's username, avatar and level and passes them to the room.
  - Refused before upgrade with `404 room_not_found`, `403 setup_required`, `409 room_full` (4 players) or `409 round_in_progress`. A player who was already in the room may always rejoin, even mid-round.

## Phases

`lobby → countdown (3 s) → round → results`

- From results, the host's `AGAIN` goes straight to a new countdown with a new puzzle.
- A room closes 30 minutes after its last activity, or 2 minutes after everyone has left.

## Server → client

| Op | Fields |
|---|---|
| `WELCOME` | `you` (user id), `protocol: 1`, `serverNow` |
| `LOBBY` | `code`, `mode`, `phase`, `hostId`, `heat` (1–6, from the host's level), `players`: `[{id, username, avatar, level, color, ready, connected}]`. `color` is 0–3 (copper, gold, verdigris, cobalt) and stays the same while the player is in the room. Sent whenever any of this changes. |
| `ROUND_START` | `round` (1, 2, …), `heat`, `startsAt`, `endsAt`, `serverNow`, `letters` (anvil letters, shuffled), `cols`, `rows`, `slots`: `[{slot, x, y, d: "a" \| "d", len}]` (**no words**), `pickups`: `[{x, y}]` (cells holding an ember) |
| `WORD_RESULT` | Sent only to the player who submitted. `seq` (echoed), `word`, `result`: `claimed` · `bonus` · `already` · `invalid` · `rate_limited` · `too_late`. `already` adds `by` (user id, or `null` if the word filled in by itself). `claimed` and `bonus` add `points`. |
| `CLAIMED` | Sent to everyone. `slot`, `word`, `by`, `points`, `scores` (`{userId: points}`). `auto`: `[{slot, word}]` lists crossing slots that this claim completed: they fill in and score nothing. `pickup`: `"hammer" \| "chisel" \| "sparks"` if `by` collected an ember. |
| `BONUS` | Sent to everyone. `word`, `by`, `points`, `scores` |
| `REVEAL` | Sent to everyone after a hint. `by`, `kind`, `cells`: `[{x, y, letter}]`, `auto`: `[{slot, word}]` |
| `ROUND_END` | `reason`: `complete` \| `timeout`; `teamScore`; `filled` and `total` (letters); `stars` (0–3); `players`: `[{id, points, words, longest}]`; `mvp` (user id or `null`); `answers`: `[{slot, word}]` (every grid word, so missed ones can be shown); `xp`: `{userId: {xp, level, levelUps, rewards: {hammer, chisel, sparks}}}` |
| `SNAPSHOT` | Sent on join and rejoin. `lobby` (as `LOBBY`), plus `round` while a round is on (the `ROUND_START` fields plus `claims`: `[{slot, word, by, points}]`, `auto`: `[{slot, word}]`, `bonus`: `[{word, by}]`, `revealed`: `[{x, y, letter}]`, `scores`), plus `results` during results (as `ROUND_END`) |
| `EMOTE` | `from`, `emote` |
| `ERROR` | `code`: `not_host`, `not_enough_players`, `bad_message`, `no_hint`, `hint_locked`, `bad_cell`, `wrong_phase` |

## Client → server

| Op | Fields | Notes |
|---|---|---|
| `READY` | `ready: bool` | In the lobby |
| `START` | — | Host only, from the lobby. Needs at least 1 player; solo co-op is allowed. Starting doesn't require everyone to be ready. |
| `SUBMIT` | `word`, `seq` | `seq` goes up by one each time. About 4 per second; past that the server answers `rate_limited` and may lock the player out for 3 s. |
| `HINT` | `kind`, plus `x`, `y` for a chisel | Spends one of the sender's **own** hints (checked and taken in D1 straight away). Revealed letters score for no one. |
| `AGAIN` | — | Host only, from results |
| `LEAVE` | — | Leave the room (the host role moves to whoever joined earliest) |
| `EMOTE` | `emote`: `nice` · `close` · `fire` · `hammer` · `gg` | |
| `{"op":"PING"}` | — | Keep-alive; answered with `{"op":"PONG"}` |

## Rules worth spelling out

- **Scoring:** a claimed grid word earns 10 points for each of its letters that a hint didn't reveal. A bonus word earns 3 per letter, and each bonus word can be claimed once per room per round.
- **Size:** at `START` the room chooses a bank puzzle with `size` = number of players (1–4) and `heat` from the host's level, skipping puzzles any player has seen in the last 60 days.
- **Pickups:** about 1 round in 5 has one ember, and occasionally two, on random cells. The claimer of the word through that cell gets the hint added to their inventory immediately, so it can be used in the same round.
- **Disconnects:** a dropped player has 30 s to rejoin and keeps their points. `LOBBY` shows `connected: false` meanwhile.
- **XP:** written by the server at `ROUND_END` (DESIGN §4.2) together with the match records, stats and level-up rewards, in one D1 batch.
