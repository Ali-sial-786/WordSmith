# Room protocol (shared contract, M3 co-op)

How the app and the RoomDO talk during co-op. Versus (M4) extends this.
Game rules are in `docs/DESIGN.md` §8, the referee design in `docs/TECH.md` §6,
and point and XP values in `server/src/rules/`. All messages are JSON
`{ "op": "...", ... }` over one WebSocket per room.

## Creating and joining

- `POST /v1/rooms` with `{mode: "coop"}` creates a room and returns `{code}`.
  - The code is 6 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`.
  - The creator becomes the host and is seated straight away (`connected: false` until their socket arrives, with the usual 30 s to connect).
  - Requires a set-up account.
- `GET /v1/rooms/:code` returns `{code, mode, phase, host: {id, username} | null, players, maxPlayers, seated}`, where `players` is a **count** and `seated` says whether the caller holds a seat (then they can always come back, even mid-round or when the room is full), or `404 room_not_found`.
- `POST /v1/rooms/:code/video` returns `{url, token, room, expiresAt}` for the room's optional **video chat**: a LiveKit token (camera and microphone only) for a LiveKit room named after the code and the room's creation time. Only for players holding a seat (`403 not_in_room`); `503 video_unavailable` while the server has no LiveKit project. The app then talks to LiveKit directly; video never goes through the RoomDO. LiveKit identities are user IDs, so bubbles match `LOBBY` players.
- `GET /v1/ws/room/:code` upgrades to a WebSocket, offering subprotocols `wordsmith.v1, <ID token>` (like the hub).
  - The Worker looks up the player's username, avatar and level and passes them to the room.
  - Refused before upgrade with `404 room_not_found`, `403 setup_required`, `409 room_full` (4 players) or `409 round_in_progress`. A player who was already in the room may always rejoin, even mid-round.

## Phases

`lobby → countdown (3 s) → round → results → (wait, up to 20 s) → countdown → …`

- From results, the host's `AGAIN` starts a short wait before the next round (see "Between rounds"), then a new countdown with a new puzzle.
- A room closes 30 minutes after its last activity, or 2 minutes after everyone has left.
- **Close codes:** `4000` the room closed, `4001` the account was deleted, `4002` after the player's own `LEAVE`. Clients stop reconnecting on any code from 4000 to 4099.

## Server → client

| Op | Fields |
|---|---|
| `WELCOME` | `you` (user id), `protocol: 1`, `serverNow` |
| `LOBBY` | `code`, `mode`, `phase`, `hostId`, `heat` (1–6: what the next round plays, or the round's own while one is on), `heatChoice` (the host's pick: 1–6, or `"auto"`, the default), `autoHeat` (1–6: what `"auto"` gives now, from the host's level), `players`: `[{id, username, avatar, level, color, ready, connected}]`. `color` is 0–3 (copper, gold, verdigris, cobalt) and stays the same while the player is in the room. Sent whenever any of this changes, a player changing their username (`POST /v1/me/username`) included. The app shows a friend under the nickname its player gave them, if any; nicknames never reach the room. `nextAt` (server ms) is there only during the wait after `AGAIN` (see "Between rounds"). |
| `ROUND_START` | `round` (1, 2, …), `heat`, `startsAt`, `endsAt`, `serverNow`, `letters` (anvil letters, shuffled), `cols`, `rows`, `slots`: `[{slot, x, y, d: "a" \| "d", len}]` (**no words**), `pickups`: `[{x, y}]` (cells holding an ember) |
| `WORD_RESULT` | Sent only to the player who submitted. `seq` (echoed), `word`, `result`: `claimed` · `bonus` · `already` · `invalid` · `rate_limited` · `too_late`. `already` adds `by` (user id, or `null` if the word filled in by itself). `claimed` and `bonus` add `points`. |
| `CLAIMED` | Sent to everyone. `slot`, `word`, `by`, `points`, `scores` (`{userId: points}`). `auto`: `[{slot, word}]` lists crossing slots that this claim completed: they fill in and score nothing. `pickup`: `"hammer" \| "chisel" \| "sparks"` if `by` collected an ember. |
| `BONUS` | Sent to everyone. `word`, `by`, `points`, `scores` |
| `REVEAL` | Sent to everyone after a hint. `by`, `kind`, `cells`: `[{x, y, letter}]`, `auto`: `[{slot, word}]` |
| `ROUND_END` | `reason`: `complete` \| `timeout`; `teamScore`; `filled` and `total` (letters); `stars` (0–3); `players`: `[{id, username, points, words, longest, bonus}]` (`username` so players who left can still be named; `words` counts grid words, `bonus` bonus words; everyone who played the round is listed); `mvp` (user id or `null`, bonus points count); `answers`: `[{slot, word}]` (every grid word, so missed ones can be shown); `xp`: `{userId: {xp, level, levelUps, rewards: {hammer, chisel, sparks}, scrapHammers, heatBonus, tiersAbove}}` (`rewards` are level-up rewards; `scrapHammers` are Hammer Strikes smelted from this round's bonus words; `heatBonus` is the part of `xp` the heat added and `tiersAbove` the tiers the round ran above the player's own, see "XP and heat"). `xp` is `{}` if the results couldn't be saved yet; the server retries. |
| `SNAPSHOT` | Sent on join and rejoin. `lobby` (as `LOBBY`), plus `round` while a round is on (the `ROUND_START` fields plus `claims`: `[{slot, word, by, points}]`, `auto`: `[{slot, word}]`, `bonus`: `[{word, by}]`, `revealed`: `[{x, y, letter}]`, `scores`), plus `results` during results (as `ROUND_END`), plus `chat`: the room's latest 50 lines, oldest first, as in `CHAT` without `op` (left out while there are none; Versus too) |
| `EMOTE` | `from`, `emote` |
| `CHAT` | Sent to everyone, the sender too. `id` (counts up from 1 in each room), `from`, `username` (the sender's when they wrote it, so a player who has left can still be named), `text` (profanity starred out), `at` (server ms). See "Chat". |
| `ERROR` | `code`: `not_host`, `not_enough_players`, `bad_message`, `no_hint`, `hint_locked`, `bad_cell`, `wrong_phase`, `no_puzzle` (the puzzle bank is empty), `chat_limit` (CHAT too fast) |

## Client → server

| Op | Fields | Notes |
|---|---|---|
| `READY` | `ready: bool` | In the lobby |
| `CONFIG` | `heat`: 1–6 or `"auto"` | Host only, in the lobby or results. Applies from the next `START` or `AGAIN` and is kept through `AGAIN`. Survival adds `variant` (shared/survival.md), Versus `series`, and any room `mode` ("Switching mode"). |
| `START` | — | Host only, from the lobby. Needs at least 1 player; solo co-op is allowed. Starting doesn't require everyone to be ready. |
| `SUBMIT` | `word`, `seq` | `seq` goes up by one each time. About 4 per second per player; past that the server answers `rate_limited` and may lock the player out for 3 s. In the lobby or countdown it gets `ERROR wrong_phase` (no `WORD_RESULT`); after the round it gets `too_late`. Other messages are limited per socket (a burst of 10, then 2 a second) and extras are dropped silently. |
| `HINT` | `kind`, plus `x`, `y` for a chisel | Spends one of the sender's **own** hints (checked and taken in D1 straight away). Revealed letters score for no one. |
| `AGAIN` | — | Host only, from results. Starts the wait before the next round, with the host ready (see "Between rounds"); a second `AGAIN` during it changes nothing. |
| `NEXT` | — | Ready for the next round: during the wait after `AGAIN`, or the Versus standings. `wrong_phase` at any other time. See "Between rounds". |
| `LEAVE` | — | Leave the room (the host role moves on, see "Host") |
| `EMOTE` | `emote`: `nice` · `close` · `fire` · `hammer` · `gg` | |
| `CHAT` | `text` | Any phase, Versus rounds included. See "Chat". A `text` that's missing, not a string or empty once tidied is `bad_message`. |
| `{"op":"PING"}` | — | Keep-alive; answered with `{"op":"PONG"}` |

## Between rounds

Between one round and the next there's time to look at the results, with a countdown anyone can cut short:

- **Co-op:** the host's `AGAIN` sets `nextAt` = now + 20 s (`COOP_NEXT_MS`) in `LOBBY`, with the host ready. The countdown starts at `nextAt`, or as soon as every connected seated player has sent `NEXT`.
- **Versus:** the standings last 30 s (`STANDINGS_MS`, until `standingsEndsAt`), or until every connected racer of the next round (`ROUND_END.next.players`) has sent `NEXT`. Players sitting out a sudden death don't count, and their `NEXT` is just ignored.
- Readiness uses the players' `ready` flags in `LOBBY`, the same as the lobby's. They're cleared when the next round's countdown starts.
- A player leaving or dropping out counts too: once everyone still there is ready, the round starts.
- Apps from before this ignore `nextAt` and never send `NEXT`; for them the wait simply runs its course.

## Rules worth spelling out

- **Scoring:** a claimed grid word earns 10 points for each of its letters that a hint didn't reveal. A bonus word earns 3 per letter, and each bonus word can be claimed once per room per round.
- **Heat:** the host picks it in the lobby, or in results for the next round (`CONFIG heat`), from Ember (1) to White Heat (6). `"auto"`, the default, is the tier for the host's level, so it follows the host if the role moves on. A round's heat is fixed when it starts.
- **Size:** at `START` the room chooses a bank puzzle with `size` = number of players (1–4) at the room's heat (the nearest size, then the nearest heat, if the bank has none).
- **Which puzzle:** chosen at random, never in a set order:
  - among those nobody in the room has had in the last 60 days;
  - if there are none, among the third of them seen longest ago by anyone in the room (by when anyone last had each).
  - The room also remembers its latest 50 puzzles and skips them unless nothing else is left, so a series or a run of `AGAIN`s never repeats one.
  - Every seated player is recorded as having seen it when the round starts (Versus: watchers too).
- **Host:** the host keeps the role while they're seated, through a dropped connection's 30 s. When they leave (`LEAVE`, or their 30 s run out, in any phase), it goes to whoever joined earliest among the players connected, or among those still seated if nobody is. A host who comes back later doesn't take it back. `LOBBY` tells everyone.
- **Pickups:** about 1 round in 5 has one ember, and occasionally two, on random cells. The claimer of the word through that cell gets the hint added to their inventory immediately, so it can be used in the same round.
- **Disconnects:** a dropped player has 30 s to rejoin and keeps their points. `LOBBY` shows `connected: false` meanwhile. A player who leaves or runs out of time mid-round stays listed (disconnected) until the round ends, keeps their points and gets XP, and is then removed.
- **Embers:** go to whoever claims the first word through the cell. An ember on a hinted cell stays until a word through it is forged; one on a slot that fills in by itself is lost.
- **Open rooms (hub):** friends see `OPEN_ROOMS` entries `{code, mode, hostId, hostUsername, players, max}` for rooms in the lobby or results that aren't full.
- **XP:** written by the server at `ROUND_END` (DESIGN §4.2) together with the match records, stats and level-up rewards, in one D1 batch.

## Switching mode

One room can play every mode in turn: the code, the players, the chat and the video call stay.

- **CONFIG `mode`:** `"coop"` · `"vs"` · `"team"`. Host only, in the lobby, or at results once everyone has them (`wrong_phase` before that). The room goes back to the **lobby** with nobody ready, and plays the new mode from the next `START`.
- **The same mode again, at results** (`{mode: "vs"}` in a Versus room) is how the host goes back to the lobby to set up the next game: the series length, scoring, rule and heat can then be changed before `START`. The teams stay as they were. `AGAIN` still replays straight away with the same settings.
- **The new mode is set up:** players keep their colour where the new mode has it and nobody who joined earlier does; otherwise they get the first free one. Versus and Team Versus get the default series length unless the room had one. Team Versus deals the players onto Copper and Cobalt in join order (anyone can switch teams afterwards); leaving Team Versus forgets the teams. Survival is dropped going to Team Versus.
- **Other fields in the same `CONFIG`** are judged by the new mode (`{mode: "team", rule: "first"}` works).
- **More players than the new mode seats** (co-op 4, Versus 5, Team Versus 6): `too_many_players`, and nothing changes.
- The open-rooms listing and `GET /v1/rooms/:code` show the new mode at once.
- **The app** keeps players in the room when they go back to the Forge Hall (a bar at the top takes them back, with the mic, camera and Leave), and picking a mode there while in a room switches the room (the host) or goes back to it (anyone else). The host picking the room's own mode after a game goes back to its lobby; the results screens also have a button for it. A round starting brings everyone in the room back to it.

## Chat

- **Who and when:** anyone seated in the room, in every phase, in co-op and Versus alike. Lines go to everyone in the room, the sender included (the app shows a line once the server echoes it). There are no private messages.
- **Tidying:** control, private-use and invisible formatting characters are removed, right-to-left overrides among them (the joiners and tags inside emoji stay). Line breaks and runs of spaces become one space, and the ends are trimmed. Lines are cut to 160 characters (code points).
- **Profanity:** every word the username filter would refuse (`account/profanity.ts`) is starred out, keeping its length: `what the ****`. Words are runs of letters, digits and `_`, so look-alike digits are caught (`sh1t`); short words such as `ass` are only caught on their own or with a plain ending (`asses`), never inside another word (`class`).
- **Limit:** a burst of 5 lines per player, then one every 2 s. Past that the server answers `ERROR chat_limit` and drops the line. The socket's general limit applies first.
- **History:** the room keeps its latest 50 lines in its storage, through hibernation, for `SNAPSHOT`. They go when the room closes; chat is never written to D1.
- **On the phone:** what was said before you joined isn't counted as new; lines that came while you were reconnecting are. You can mute a player for the rest of the room (on your phone only), and turn text chat off in Settings.

## XP and heat

Co-op and Versus XP grow with the heat played (`heatXp` in `server/src/rules/progression.ts`):

```
xp = round(base × (HEAT_XP[heat] + 0.2 × tiersAbove))

HEAT_XP   = {1: 1.0, 2: 1.2, 3: 1.4, 4: 1.6, 5: 1.8, 6: 2.0}
tiersAbove = max(0, heat − heatForLevel(the player's level before this XP))
```

- `base` is the mode's XP: `coopRoundXp` plus any survival bonus, or `vsSeriesXp`.
- Playing above your own tier adds 0.2 for each tier, up to +1.0 for a level 1–5 smith at White Heat (×3.0 in all).
- Playing at or below your tier adds nothing beyond the heat's own multiplier, so a strong player who picks Ember gets ×1.0.
- For example, a Versus series of 3 rounds with 1 win (25 XP at Ember) pays a level 3 newcomer 75 XP at White Heat. Their level 90 rival who won it 2–1 gets (15 + 20 + 30) × 2.0 = 130.
- `xp.heatBonus` is `xp − base`, and `xp.tiersAbove` is as above. A retried write that only kept the XP sends both as 0.

---

# Versus (M4): "Anvil Clash"

Everything above applies unless this section says otherwise. Game rules are in
`docs/DESIGN.md` §9; the pure rules already exist in `server/src/rules/vs.ts`
(`resolveVsRound`, `seriesStatus`, `podium`), `heat.ts` (`vsHeat`,
`vsRoundTimerMs`) and `progression.ts` (`vsSeriesXp`).

## Creating and joining

- `POST /v1/rooms` with `{mode: "vs"}`. Up to **5** players; `color` is 0–4 (copper, gold, verdigris, cobalt, titanium).
- `GET /v1/rooms/:code` reports `maxPlayers: 5`.
- Joining is refused with `409 round_in_progress` during `countdown`, `round` and `standings` unless the player already holds a seat.

## Phases

`lobby → countdown (3 s) → round → standings (up to 30 s) → countdown → round → … → results`

- After a round that doesn't end the series, `standings` shows for 30 s, then the next countdown starts by itself; sooner if every racer is ready (`NEXT`, see "Between rounds" above).
- When the series is decided, the room goes straight to `results` (`ROUND_END` then `SERIES_END`).
- From `results`, the host's `AGAIN` starts a new series with the same length and whoever is still seated.

## Client → server (changes)

| Op | Fields | Notes |
|---|---|---|
| `CONFIG` | `series`: 3 · 5 · 7 · 10, and/or `heat` | Host only. `series` in the lobby (default 3); `heat` in the lobby or results, as in co-op, for the next series. |
| `START` | — | Host only. Needs at least **2** connected players (`not_enough_players`). |
| `SUBMIT` | `word`, `seq` | Only players racing this round. Someone watching a sudden-death round gets `ERROR not_playing`. |
| `HINT` | — | Not allowed in VS: `ERROR no_hints`. (Turn is local to the app.) |
| `AGAIN` | — | Host only, from `results`: a new series, straight away (no wait). |
| `NEXT` | — | During `standings`: ready for the next round. |

## Server → client (changes)

| Op | Fields |
|---|---|
| `LOBBY` | adds `series` (3, 5, 7 or 10). `"auto"` (`autoHeat`) is the tier of the **median** level of the seated players (`vsHeat`); during a series `heat` is the series' own. |
| `ROUND_START` | the co-op fields (`slots` without words, `letters`, `pickups`, `startsAt`, `endsAt`, `serverNow`, …) plus `series` (length), `regular` (1…`series` for a regular round, `null` for sudden death), `suddenDeath` (bool), `players` (ids racing this round; everyone else watches) and `tally` (`{userId: wins}`). Everyone gets the same puzzle and letters. |
| `WORD_RESULT` | Sent to the submitter only. `claimed` adds `slot` and `auto`: `[{slot, word}]` (crossing slots this completed on **your** mold; they fill in too), plus `pickup` if an ember was collected (granted after the series). `already` means you've already got that word. `bonus` means a bonus word (it goes to the Scrap Bin and never counts as progress). No `points` in VS. |
| `PROGRESS` | Sent to everyone whenever a racer's count changes: `id`, `filled` (letter cells filled on their mold), `total`. Never words or cells. Someone **watching** the round (sitting out a sudden death, or out of the series) also gets `slots`: the racer's complete slots, sorted, so their molds can be watched filling; never letters, and racers never get it. |
| `ROUND_END` | `reason`: `finished` \| `timeout`; `winner` (user id or `null`); `how`: `finished` \| `timeout` \| `none`; `progress`: `[{id, filled, total}]` for the racers; `molds`: `{userId: [slot, …]}` for the racers (the slots complete on their own mold, forged or filled in by themselves, sorted); `tally` (after this round); `answers`: `[{slot, word}]`; `next`: `{round, suddenDeath, players}` for the round coming after the standings, or `null` if the series is over; `standingsEndsAt` (ms, when the next countdown starts; `null` if the series is over). |
| `SERIES_END` | `winner` (user id or `null`), `early` (clinched before the last regular round), `forfeit` (everyone else left), `rounds` (rounds played, sudden death included), `podium`: `[{id, username, wins, place}]` (equal wins share a place), `history`: `[{round, suddenDeath, reason, winner, how, cols, rows, slots: [{slot, x, y, d, len}], progress: [{id, filled, total}], molds, letters, answers: [{slot, word}], bins: {userId: [word, …]}}]` (one entry per round played, in order; `reason`, `winner`, `how`, `progress`, `molds` and `answers` as in that round's `ROUND_END`, the shape and `letters` as in its `ROUND_START`; `bins` is each racer's Scrap Bin for the round: their bonus words in the order found, `[]` for none), `xp`: `{userId: {xp, level, levelUps, rewards, scrapHammers, heatBonus, tiersAbove, pickups: {hammer, chisel, sparks}}}` (`{}` if the write failed; retried like co-op; `heatBonus` and `tiersAbove` as in co-op). |
| `SNAPSHOT` | `lobby`; during `countdown`/`round`: `round` = the `ROUND_START` fields plus `mine`: `{claims: [{slot, word}], auto: [{slot, word}]}` (the receiver's own mold) and `progress`: `[{id, filled, total}]` (with `slots` when the receiver is watching, as in `PROGRESS`); during `standings`: `standings` = the last `ROUND_END`; during `results`: `results` = the `SERIES_END` (and `standings` = the last `ROUND_END`). |
| `ERROR` | adds `not_playing`, `no_hints`. |

## Rules worth spelling out (VS)

- **Puzzle:** one bank puzzle per round with `size` 1 at the series' heat, chosen as in co-op ("Which puzzle") from what everyone seated has seen, watchers included. Each racer fills their **own** copy. The round timer is `vsRoundTimerMs(heat)`.
- **Winning a round:** the first racer to fill every letter wins at once (`finished`); the round ends for everyone and boards freeze. At the timer, the most letters filled wins, a tie going to whoever reached that count first (`timeout`). Nobody filled anything: no winner (`none`). Use a server-side counter as `reachedAt` so it never ties.
- **Series:** after each round use `seriesStatus`. Clinched → `SERIES_END`. All regular rounds played and tied → **sudden death** between the tied leaders only; a sudden-death round with no winner is played again with the same players.
- **Disconnects:** a dropped racer's mold freezes and they have 30 s to come back and carry on. A racer who leaves or runs out of time can't win any more rounds but keeps their wins on the podium. If only one racer is left, they win by **forfeit**.
- **Embers:** the same cells for everyone. Each racer who forges a word through an ember collects it once; it's granted after the series, not usable during it.
- **XP** (one D1 batch at `SERIES_END`): `vsSeriesXp` (5 per round played, 10 per round won, 30 for winning the series) at the series' heat ("XP and heat"), plus level-up rewards, Scrap Bin hammers from bonus words, ember pickups, and stats (VS series played and won, VS rounds won).
- **Open rooms:** VS rooms in `lobby` or `results` that aren't full are listed to friends like co-op ones (`mode: "vs"`, `max: 5`).

## As built (VS details beyond the tables above)

- `ROUND_START.round` counts from 1 in each series, sudden death included. `tally` is the wins *before* the round, for every racer in the series (also ones who left).
- `ROUND_END` also carries `round` (the round that ended).
- `ROUND_END.molds` is the only place rivals' cells appear, once the round is over: every racer of the round has an entry (`[]` if they filled nothing, racers who left mid-round included), whatever the `reason`. The app draws the cells from `ROUND_START.slots`.
- `SERIES_END.history` sums up the series round by round, so the podium can show every round, and go back over each one with its words and everyone's Scrap Bin, even to someone who rejoined mid-series or during results (it's in `SNAPSHOT.results` too). It has every round that ended, sudden death included (a round dropped in its countdown isn't one), and carries its own mold shape and anvil. Rivals' bonus words only ever come out here, once the series is over. Survival rounds add `melted` and `saved` (as in `ROUND_END`). The series keeps the latest 50 rounds at most, so it always fits in the room's storage and `SERIES_END` in one message, even with every bonus word in every bin. It's called `history` because `rounds` was already the count. A series already under way when the server was updated lists only the rounds since, and rounds stored by a server from before `letters`, `answers` and `bins` come without them: apps treat all three as optional.
- `WORD_RESULT` in VS has no `points`, and `already` has no `by`. `already` also covers a slot that filled in by itself on your mold and a bonus word you'd already found.
- `SNAPSHOT` for someone watching has `mine: {claims: [], auto: []}`; bonus words aren't included.
- Clinch, sudden death and forfeit only count racers still in the series. Racers who left keep their wins on the podium, which ranks by wins with the series winner first among equals.
- When people leaving decides the series: mid-round, the round is resolved among those left (`ROUND_END` with `reason: "timeout"`), then `SERIES_END`; during a countdown, the round is dropped (no `ROUND_END`) and `SERIES_END` follows; during standings, only `SERIES_END` follows. A forfeit always has `early: false`.
- A racer who left can reconnect and watch; their `SUBMIT` gets `not_playing`. `SUBMIT` during standings gets `too_late`. `CONFIG` in a co-op room or with a bad value gets `bad_message`. `HINT` gets `no_hints` in every phase.
- If the room idle-closes mid-series, `SERIES_END` goes out with what was played (`winner: null` unless already decided) and XP is still written.
- Heat is fixed at `START` (or `AGAIN`) for the whole series, sudden death included. The series length can only be changed in the lobby (before the first series); the heat also in results, for the next series.
- `CONFIG` checks, as in survival.md: no field, a bad value, or `series` in co-op is `bad_message`; then `wrong_phase`; then `not_host`. An unchanged value sends no `LOBBY`.


## Total score (`scoring`)

A Versus series is won on **round wins** (`"rounds"`, the default, everything above) or on the **total score** (`"total"`). Versus only: Team Versus and co-op have no `scoring`.

- **Picking it:** the host sends `CONFIG {scoring: "rounds" | "total"}` in the lobby or at results, for the next series. `scoring` in a co-op or Team Versus room, or a bad value, is `bad_message`. `LOBBY` in a Versus room always carries `scoring` (while a series is on, the series' own).
- **Rounds:** each round still ends, and is still won, exactly as above, and round wins still count up in `tally`. A racer's **score** for a round is the letters they filled on their mold (bonus words don't count).
- **Every regular round is played:** no clinch.
- **Winner:** the most letters over the series among racers still in it; tied → the most bonus words over the series; still tied → a **tiebreaker round**: sudden death between those leaders (`next.suddenDeath: true`), whose winner takes the series. A tiebreaker with no winner is played again by the same leaders (still in the series), whatever it added to anyone's totals; if only one of them is left, they win. Letters and bonus words from tiebreakers still count in `scores`, `bonusTally` and the podium. Forfeit works as above.
- **`ROUND_START` and `ROUND_END`** add `scoring: "total"`, `scores` (letters so far, per racer in the series, after the round in `ROUND_END`) and `bonusTally` (bonus words so far, likewise). A round-wins series sends none of the three.
- **`SERIES_END`** adds `scoring`, `tiebreak: true` when the series went to a tiebreaker, and each podium entry adds `score` and `bonus`. The winner is first; everyone else ranks by score, then bonus words, sharing a place only when both are equal. Racers who left keep their score on the podium.
- **XP** is as in a round-wins series (`vsSeriesXp`), tiebreakers counting as rounds played.
- **D1:** the match summary adds `scoring`, `tiebreak` and each player's `score`, and `match_players.points` is the score. Series stored before this have no `score` (read as 0).

---

# Team Versus

Versus with two teams: **Copper** (team `0`) and **Cobalt** (team `1`).
Everything in "Versus (M4)" applies unless this section says otherwise. The
pure rules are in `server/src/rules/teams.ts`, applied to the round and the
series in `vs-round.ts`.

## Creating and joining

- `POST /v1/rooms` with `{mode: "team"}`. Up to **6** players, at most 3 on a team; `color` is 0–5 (Versus' five, plus rose gold, 5).
- `GET /v1/rooms/:code` reports `mode: "team"` and `maxPlayers: 6`. Open-room listings and invites carry `mode: "team"`.
- A newcomer joins the smaller team (Copper on a tie) and keeps their team while seated, through AGAIN.

## How a round is won (`rule`)

Each player races their own copy of the mold, exactly as in Versus. A round is won by a **team**. The host picks how (`CONFIG rule`), from the next START or AGAIN:

- **`combined`** (the default): a team's score is the letters its racers have filled, added up.
  - A team wins at once when every one of its racers still in the series has filled their whole mold (`how: "finished"`). Until then the round goes on, so a racer who finishes early waits for their teammates.
  - At the timer, the higher score wins (`timeout`). A tie goes to the team that reached its score first (its racers' latest change).
  - Nobody filled anything: no winner (`none`).
- **`first`**: the first racer to fill their whole mold wins the round for their team, and it ends at once (`finished`). At the timer, the racer with the most letters wins it for their team, a tie going to whoever got there first (`timeout`), as in Versus.
- A racer who has left the series counts for nothing: their letters don't add to their team's score, and they can't win a round.

## Series

- Round wins are counted per team. Clinching and sudden death follow `seriesStatus` with the two teams' wins. **Sudden death** is played by every racer still in the series.
- A team with nobody left in the series loses by **forfeit**.
- Each racer's own `wins` are the rounds their team won while they raced.

## Client → server (changes)

| Op | Fields | Notes |
|---|---|---|
| `TEAM` | `team`: 0 · 1; `id` (optional) | In the lobby or results. Moves the sender; the host may move anyone with `id`. `team_full` if that team has 3, `not_host`, `not_in_room` (no such seated player), `wrong_phase`. Any other room: `bad_message`. |
| `CONFIG` | adds `rule`: `"combined"` · `"first"` | Host only, in the lobby or results, for the next series. `rule` in another room, or `variant: "survival"` in a team room, is `bad_message`: teams play classic rounds. |
| `START` · `AGAIN` | — | Also need both teams the same size, with at least one each, and everyone seated on one: `uneven_teams`. 1 against 1 to 3 against 3. |

## Server → client (changes)

| Op | Fields |
|---|---|
| `LOBBY` | adds `rule` (the series' own during a series), and `team` (0 or 1) on every player |
| `ROUND_START` | adds `rule`, `teams` (`{userId: 0 \| 1}` for everyone in the series) and `teamTally` (`[copper, cobalt]` round wins before this round) |
| `ROUND_END` | adds `team` (the winning team, or `null`), `teamScores` (`[copper, cobalt]`: letters added up over the racers still in the series), `teamTally` (after this round), `rule` and `teams`. `winner` is the racer who won it under `first`, and `null` under `combined`. |
| `SERIES_END` | adds `team` (the winning team, or `null`), `rule` and `teamTally`. `winner` is `null`. `podium` entries add `team`; `place` is the team's: 1 for the winners, 2 for the others (both 1 if neither won; a stopped series ranks by round wins). `history` entries add `team` and `teamScores`. |
| `ERROR` | adds `uneven_teams`, `team_full`, `not_in_room` |

## XP and records

- XP is Versus': 5 per round raced, 10 per round their team won while they raced, 30 if their team won the series, at the series' heat.
- D1 keeps a Team Versus series as a Versus match (`matches.mode = 'vs'`), with `teams: {rule, winner, members: {userId: team}}` in its summary. It counts towards the Versus stats (`vs_series`, `vs_series_won` when their team won, `vs_rounds_won`).
