# Wordsmith API

The server side of Wordsmith: a Cloudflare Worker written in TypeScript, with
a D1 (SQLite) database, a global presence Durable Object (HubDO) and one
Durable Object per room (RoomDO). See [docs/TECH.md](../docs/TECH.md) for the
plan and [shared/room-protocol.md](../shared/room-protocol.md) for the room
contract.

| Path | What it is |
|---|---|
| `src/index.ts` | The router: every route, and which need a token |
| `src/auth/` | Firebase ID token checks with WebCrypto (`firebase.ts`) and reading the token from a request (`request.ts`) |
| `src/account/` | Username and avatar rules, and the profanity blocklist |
| `src/routes/` | The REST and WebSocket handlers |
| `src/db/` | D1 queries |
| `src/hub/` | HubDO (`hub.ts`) and its message protocol (`protocol.ts`) |
| `src/room/` | RoomDO (`room.ts`), the co-op referee, and its message protocol (`protocol.ts`) |
| `src/rules/` | Game rules as pure functions with no I/O, so they're easy to test and tune. The app's Dart engine mirrors them. |
| `migrations/` | The D1 schema (TECH.md §7), plus `0002_pickup_seeds.sql` |
| `scripts/build-campaign-sql.mjs` | Turns the app's campaign into SQL for the `campaign` table |
| `data/mp_bank.json` | The multiplayer puzzle bank (960 puzzles: heat 1–6 × size 1–4), made by `tools/puzzlegen`. Never shipped in the app. |
| `scripts/build-bank-sql.mjs` | Turns the bank into SQL for the `puzzles` table |

| Rules file | Rules |
|---|---|
| `words.ts` | Normalising a guess (A–Z only), the 3-letter minimum, and checking a word can be made from the anvil letters |
| `heat.ts` | Heat tier from Smith Level, tier names, co-op and VS timers, and the median level for VS |
| `progression.ts` | XP curve, levels, ranks, hint unlocks, level-up rewards, XP per mode, and the Scrap Bin |
| `pickups.ts` | Campaign pickup seeding ([shared/pickups.md](../shared/pickups.md)) |
| `campaign.ts` | A campaign puzzle's grid words, bonus words and letter cells, for checking syncs |
| `sync.ts` | Checking and applying offline solo results (see below) |
| `coop.ts` | Claim decisions, word points, MVP and stars |
| `room.ts` | Room codes, colours, the host, room timings (countdown, rejoin, closing) and the SUBMIT rate limit |
| `mold.ts` | A bank puzzle's slots and cells, which slots filled cells complete, where hints and embers land |
| `coop-round.ts` | One co-op round: claims, self-completing slots, hints, embers, scores, results and XP |
| `vs.ts` | Round results, series clinch, sudden death and the podium |

## Routes

Everything is under `/v1`. Every route except `/version` and `/health` needs
`Authorization: Bearer <Firebase ID token>`; the WebSocket route reads the
token from `Sec-WebSocket-Protocol` instead. Errors are always JSON
`{"error": "<code>", "message"?: "..."}`. A missing or bad token is
`401 {"error": "unauthorized", "message": "<reason>"}` (`missing_token`,
`expired`, `bad_signature`, `unknown_kid`, `bad_audience`, …).

| Route | Body → response |
|---|---|
| `GET /version` | `{latest, minSupported, protocol}`, from the `vars` in `wrangler.jsonc` |
| `GET /health` | `{ok: true}` |
| `GET /me` | My profile (below). The first call creates the account with 3 Hammer Strikes; `needsSetup` stays true until setup. |
| `POST /me/setup` | `{username, avatar}` → my profile. Username: 3–16 of `A–Z a–z 0–9 _`, unique ignoring case, not blocked or reserved (`400 invalid_username`, `400 username_not_allowed`, `409 username_taken`). Avatar: `avatar_01` … `avatar_16` (`400 invalid_avatar`). The username can't change (`409 already_set`), but repeating it with another avatar changes the avatar. |
| `DELETE /me` | `{ok: true}`. Deletes all my rows. Past matches keep a row under a placeholder ID, which shows as "Deleted smith". The app should then delete the Firebase user; another `GET /me` before that would start a fresh account. |
| `GET /users/:username` | `{id, username, avatar, level, rank, campaignCompleted, stats, friendship}`; `friendship` is `self`, `none`, `friends`, `request_sent` or `request_received`. `404 user_not_found`. |
| `POST /solo/sync` | `{entries: [...]}` → `{profile, results}`; see below |
| `GET /friends` | `{friends, incoming, outgoing}`, each a list of `{id, username, avatar, level, rank, since}` |
| `POST /friends/request` | `{username}` → `{status: "pending" \| "accepted", user}`. Asking someone who already asked you accepts. `404 user_not_found`, `400 cannot_friend_self`, `409 already_friends`, `409 too_many_requests`. |
| `POST /friends/respond` | `{userId, accept}` → `{status: "accepted" \| "declined", user}`. `404 request_not_found`. |
| `DELETE /friends/:id` | `{ok: true}`. Removes a friend, cancels my request, or declines theirs. `404 not_found`. |
| `GET /leaderboard` | `{entries: [{place, id, username, avatar, level, rank, totalXp, vsSeriesWon, vsRoundsWon, coopRounds, coopMvps, me}]}`, me plus my friends by XP. There's no co-op best score yet: the schema has no column for it. |
| `GET /ws/hub` | WebSocket upgrade to HubDO (below) |
| `POST /rooms` | `{mode: "coop"}` → `{code}`: a new room with me as host (below). `400 unsupported_mode` for `"vs"` (M4), `400 invalid_mode` otherwise. |
| `GET /rooms/:code` | `{code, mode, phase, host: {id, username} \| null, players, maxPlayers}`; `players` is a count. The code is case-insensitive. `404 room_not_found`. |
| `GET /ws/room/:code` | WebSocket upgrade to that room's RoomDO (below). Refused before upgrading with `404 room_not_found`, `409 room_full` or `409 round_in_progress`. |

Friends, the leaderboard, the hub and rooms need a set-up account
(`403 setup_required`). `/me`, `/me/setup`, `/solo/sync` and `/users/:username` don't.

### Profile

```json
{
  "id": "<firebase uid>", "username": "Ali", "avatar": "avatar_03", "needsSetup": false,
  "totalXp": 1000, "level": 10, "xpIntoLevel": 100, "xpForLevel": 150, "rank": "Journeyman",
  "campaignCompleted": 12, "nextStage": 13,
  "scrapBin": 4, "hints": {"hammer": 5, "chisel": 1, "sparks": 0},
  "stats": {"wordsForged": 40, "longestWord": "THREAD", "soloDone": 12, "coopRounds": 0,
            "coopMvps": 0, "vsSeries": 0, "vsSeriesWon": 0, "vsRoundsWon": 0},
  "createdAt": 1792200000000
}
```

`campaignCompleted` is the highest stage completed (`profiles.campaign_stage`,
0 = none). `nextStage` is `campaignCompleted + 1`, which is what the app's
`Profile.campaignStage` holds.

### Solo sync

Each entry is what the app queues on finishing a campaign puzzle:
`{stage, puzzleId, foundWords, bonusWords, hintsUsed, pickups: [{cell, kind}], pickupSeed?, durationMs, completedAt}`
(`pickupsCollected` is accepted as another name for `pickups`). At most 100
entries per request. `results[i]` answers `entries[i]`:

```json
{"stage": 7, "accepted": true, "xp": 12, "levelUps": 1, "level": 2,
 "rewards": {"hammer": 1, "chisel": 0, "sparks": 0}, "scrapHammers": 0,
 "pickups": [{"cell": 3, "kind": "hammer"}], "pickupsRejected": 0,
 "hintsClamped": {"hammer": 1, "chisel": 0, "sparks": 0}}
{"stage": 8, "accepted": false, "reason": "duplicate", "xp": 0, "levelUps": 0, "rewards": {...}}
```

Every result is final, so the app can drop all the entries it sent and take
`profile` as the truth. The rules (in `src/rules/sync.ts`):

- Entries are applied in `completedAt` order, so each puzzle's level-up rewards and pickup types use the level the player had when it started.
- An entry is **rejected** if it's malformed (`invalid_entry`, with `detail`), its stage isn't in the campaign (`unknown_stage`), `puzzleId` isn't that stage's (`puzzle_mismatch`), the stage was already counted (`duplicate`), `completedAt` is more than 10 minutes ahead or before 2026 (`bad_completed_at`), a found word isn't a grid word (`unknown_word`), a bonus word isn't in the bonus list (`unknown_bonus_word`), the cells no found word covers are more than the hints used could have shown (`incomplete`; a Hammer or Chisel shows 1, a Spark Shower 5), or it took under 1 s per found word (`too_fast`).
- An **accepted** entry gives 10 XP plus 1 per bonus word (up to +5), level-up rewards, and puts its bonus words in the Scrap Bin (each 10 → a Hammer Strike). Hints used are taken off the stock after adding the puzzle's pickups and Scrap Bin hammers, and before level-up rewards. Stock never goes below 0; any overdraw is reported in `hintsClamped`.
- **Pickups** are checked by recomputing `pickupsFor(seed, puzzleId, cellCount, levelAtStart)`. The seed is `pickupSeed` (the app's install ID from before sign-in) or else the account's uid. A claim on the right cell gets the server's type; other claims are dropped (`pickupsRejected`). An account may use its own uid and up to 5 install IDs (`pickup_seeds` table).
- `503 campaign_unavailable` means the server's campaign table is empty: keep the queue and retry later. `409 sync_conflict` means the profile kept changing during the sync: retry.

### Hub WebSocket

Connect to `/v1/ws/hub` offering the subprotocols `wordsmith.v1, <ID token>`
(`Sec-WebSocket-Protocol`); the server accepts `wordsmith.v1`. Messages are
JSON `{op, ...}`, defined in `src/hub/protocol.ts`:

| Op | Direction | Payload |
|---|---|---|
| `PRESENCE` | S→C | `{userId, status}`; status is `online`, `solo`, `in_room:<CODE>` or `offline` |
| `SET_STATUS` | C→S | `{status}`: `online`, `solo` or `in_room:<6 chars A–Z 0–9>` |
| `INVITE` | C→S | `{to, code, mode: "coop" \| "vs"}`, only to an accepted friend who's online |
| `INVITE` | S→C | `{from, fromUsername, code, mode}` |
| `OPEN_ROOMS` | S→C | `{rooms: [{code, mode, hostId, hostUsername, players, max}]}`: joinable rooms (lobby or results, not full) hosted by my friends, newest first |
| `ERROR` | S→C | `{code}`: `bad_message`, `unknown_op`, `bad_status`, `bad_invite`, `not_friends`, `friend_offline`, `rate_limited` |

On connect you get a `PRESENCE` for each online friend, then `OPEN_ROOMS`.
A fresh `OPEN_ROOMS` (the whole list) comes whenever a friend's room opens,
changes its player count or host, starts a round, or closes, and when a
friendship with a host starts or ends.
Send the exact text `{"op":"PING"}` as a keep-alive; the runtime answers
`{"op":"PONG"}` without waking the hub. Accepting or removing a friend
through REST updates both players' presence at once. Deleting an account
closes its sockets with code 4001.

### Rooms

Implements [shared/room-protocol.md](../shared/room-protocol.md) for
`mode: "coop"`; the message types are in `src/room/protocol.ts`. Connect to
`/v1/ws/room/<CODE>` offering `wordsmith.v1, <ID token>`, like the hub. You
get `WELCOME`, then `SNAPSHOT`.

**Lifecycle.** `lobby → countdown (3 s) → round → results`, and the host's
`AGAIN` goes from results straight to a new countdown. `ROUND_START` is sent
when the countdown begins (`startsAt` is when play starts); `LOBBY` follows
every phase change. The round ends when the mold is full or at `endsAt`
(the DO's alarm), then `ROUND_END` (after XP has been written) and `LOBBY`
with `phase: "results"`.

- **Creating:** `POST /v1/rooms` seats the creator straight away as host, shown as `connected: false` until their socket arrives (they have the 30 s rejoin time to connect).
- **Joining:** anyone with the code, while the room has fewer than 4 players and isn't in a countdown or round. Joining during results is fine; you're in the next round. Colours are the lowest free one (0–3) and stay while you're in the room.
- **Dropping out:** a closed socket (without `LEAVE`) keeps your seat for 30 s (`connected: false`); reconnecting gets a fresh `SNAPSHOT`. After 30 s the seat goes (in the lobby or results) and the host role moves on.
- **`LEAVE`:** your seat goes at once (the server closes your sockets with code **4002**). During a countdown or round you stay listed (`connected: false`) until it ends, so your words keep their owner, and you can still come back to that round.
- **Host:** if the host leaves (or their 30 s run out), whoever joined earliest becomes host; `LOBBY.heat` follows the new host's level.
- **Closing:** 30 minutes after the last message from anyone, or 2 minutes after the last socket closed. A round in progress is ended (and scored) first. Every socket is closed with code **4000** (`room_closed`), the room's storage is wiped, and the code stops working (`404 room_not_found`). The app treats 4000–4099 as "don't reconnect".

**Puzzles.** `START`/`AGAIN` pick a bank puzzle with `heat` from the host's
level and `size` = players in the room (1–4), skipping puzzles any player had
in the last 60 days (`puzzle_seen`, recorded at the start). If the whole
size has been seen, the one seen longest ago is used; a size or heat with no
puzzles at all falls back to the nearest. An empty bank answers `ERROR no_puzzle`.

**Refereeing.** Words are handled strictly in arrival order (src/rules/coop-round.ts):

- A grid word nobody has: `WORD_RESULT claimed` to the sender, `CLAIMED` to everyone; 10 points per letter a hint didn't reveal. Crossing slots it completes fill in (`auto`) and score nothing.
- A bonus word nobody has: `bonus`, `BONUS` to everyone; 3 points per letter. Bonus words also go into the finder's Scrap Bin at the end.
- Found already: `already` with `by` (`null` for a slot that filled in by itself). Not a word: `invalid`.
- After the round: `too_late`. During the lobby or countdown: `ERROR wrong_phase`.
- **Rate limit:** 4 words at once, then 4 a second, per player; 10 `invalid` within 5 s locks the player out for 3 s. Either way the answer is `rate_limited`. Other messages are limited to 10 at once, then 2 a second, per socket; extra ones are dropped silently.

**Hints.** `HINT {kind}` (`{kind: "chisel", x, y}` for a Chisel) spends one of
the sender's own hints in D1 at once. Errors: `hint_locked` (level too low:
Chisel 5, Spark Shower 12), `bad_cell` (a Chisel on a filled or non-letter
cell), `no_hint` (none left), `wrong_phase`. A Hammer Strike reveals one
random empty cell, a Chisel the chosen one, a Spark Shower up to 5 cells
spread across different words. `REVEAL` goes to everyone; slots the letters
complete fill in (`auto`).

**Embers.** About 1 round in 5 has one ember (sometimes two, never on the
same word), at `ROUND_START.pickups`. Whoever forges a word through an ember's
cell collects it: `CLAIMED.pickup` names the hint, which goes into their D1
stock at once (a type they've unlocked; otherwise a Hammer Strike). An ember on
a hinted cell stays until a word through it is forged; one on a slot that
fills in by itself is lost.

**Results and XP.** `ROUND_END` follows the contract, plus a few extra fields:
`players[].username` (so results can name someone who has since left),
`players[].bonus` (bonus words found) and `xp[id].scrapHammers` (Hammer
Strikes smelted from the Scrap Bin, not part of `rewards`). Every player in
the round gets XP, including ones who left. One D1 batch writes the `matches`
row, and for each player `match_players`, `xp_events`, the profile (XP, level,
Scrap Bin), stats (`coop_rounds`, `coop_mvps`, `words_forged`,
`longest_word`) and hints won. If D1 fails, `ROUND_END` goes out with
`xp: {}` and the write is retried in the background (the app should refresh
`GET /v1/me` after a round anyway). During results, `SNAPSHOT` carries both
`results` and the finished `round`.

**State.** Everything that matters is in the RoomDO's own storage, so it
survives hibernation and eviction mid-round; one alarm always points at the
nearest deadline. Hint spends, ember grants and XP writes also move
`profiles.updated_at` on, so a solo sync running at the same moment retries
instead of overwriting them.

## Local development

You need Node 22.12 or newer. Local mode doesn't need a Cloudflare account or
`wrangler login`.

```sh
cd server
npm ci
npm run db:migrate:local   # apply migrations/ to the local D1
npm run db:seed:local      # build data/campaign.sql and data/bank.sql, and load both
npm run dev                # wrangler dev on http://localhost:8787
curl http://localhost:8787/v1/version
```

- `wrangler dev` runs the Worker, the HubDO, RoomDOs and a local D1 database. The data lives in `.wrangler/state/`, which git ignores. Delete that folder to start over.
- **Seeding:** sync checks need the campaign in the `campaign` table, and rooms need the multiplayer bank in `puzzles`. `npm run db:campaign` writes `data/campaign.sql` from `../app/assets/campaign/campaign.json`; `npm run db:bank` writes `data/bank.sql` from `data/mp_bank.json` (both git-ignored, since they're rebuilt from those files). `db:seed:local` builds and loads both. Re-run it whenever either is regenerated; it replaces rows and removes puzzles no longer in the file.
- Authenticated routes need a real Firebase ID token for project `wordsmith-8f550`: the Worker always checks Google's keys.
- To look inside the local database: `npx wrangler d1 execute wordsmith --local --command "SELECT COUNT(*) FROM campaign"` (600 stages), or `... "SELECT heat, size, COUNT(*) FROM puzzles GROUP BY heat, size"` (40 each).
- To turn off Wrangler's telemetry, set `WRANGLER_SEND_METRICS=false`.

## Tests

```sh
npm run typecheck   # tsc --noEmit (strict)
npm test            # vitest run: both projects
npx vitest run --project rules    # just the pure code
npx vitest run --project worker   # just the Worker
```

The tests run as two Vitest projects:

- **`rules`** (`test/rules/`, `test/unit/`) runs plain unit tests in Node: the game rules (with every vector in `shared/pickups.md`), the co-op round and mold rules (every bank puzzle is parsed), sync checks, usernames, the hub and room protocols, the router and the campaign and bank SQL scripts.
- **`worker`** (`test/worker/`) runs the Worker, HubDO and RoomDO inside the real `workerd` runtime using `@cloudflare/vitest-plugin` (the new name of `@cloudflare/vitest-pool-workers`). Before each test file, `test/worker/setup.ts` applies `migrations/` and loads the real campaign and bank into the test D1 database. Tests sign their own Firebase-style tokens with a generated RSA key, which `test/worker/helpers.ts` installs with `setJwksFetcher()`. Room tests (`rooms.test.ts`) drive real WebSockets; they run the DO's alarm early with `runDurableObjectAlarm()` (the room treats an alarm as "the planned deadline has come"), evict it with `evictDurableObject()`, and read or adjust its storage with `runInDurableObject()`.

## Changing the schema

Add a new numbered file such as `migrations/0003_something.sql`. Don't edit
a migration once it has been applied to the real database. Wrangler records
which migrations have been applied in the `d1_migrations` table. Durable
Object class changes go in the `migrations` list in `wrangler.jsonc`.

## Later: deploying

Nothing is deployed yet, and there's no Cloudflare account set up for this
project. Already configured: `FIREBASE_PROJECT_ID` (`wordsmith-8f550`, not a
secret) and the `HUB` and `ROOM` Durable Objects with their
`new_sqlite_classes` migrations (`v1`, `v2`). Still needed:

1. A Cloudflare account, and an API token for CI.
2. Create the database with `npx wrangler d1 create wordsmith`. Paste the `database_id` it prints into `wrangler.jsonc`, replacing the all-zero placeholder.
3. Apply the migrations to it: `npx wrangler d1 migrations apply wordsmith --remote`.
4. Load the campaign: `npm run db:campaign && npx wrangler d1 execute wordsmith --remote --file data/campaign.sql`. Repeat whenever the campaign changes.
5. Load the multiplayer bank: `npm run db:bank && npx wrangler d1 execute wordsmith --remote --file data/bank.sql`. Repeat whenever `data/mp_bank.json` changes. (The deploy workflow in `.github/workflows/deploy-server.yml` doesn't do this step yet.)
6. Deploy with `npm run deploy`, which runs `wrangler deploy`.

CI deploys need the GitHub secrets `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID`. Neither is set up yet. To raise the app version
users are told about, change `LATEST_VERSION` and `MIN_SUPPORTED_VERSION` in
`wrangler.jsonc` and deploy.
