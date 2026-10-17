# Wordsmith API

The server side of Wordsmith: a Cloudflare Worker written in TypeScript, with
a D1 (SQLite) database and a global presence Durable Object (HubDO). Rooms
(RoomDO) come in M3. See [docs/TECH.md](../docs/TECH.md) for the plan.

| Path | What it is |
|---|---|
| `src/index.ts` | The router: every route, and which need a token |
| `src/auth/` | Firebase ID token checks with WebCrypto (`firebase.ts`) and reading the token from a request (`request.ts`) |
| `src/account/` | Username and avatar rules, and the profanity blocklist |
| `src/routes/` | The REST and WebSocket handlers |
| `src/db/` | D1 queries |
| `src/hub/` | HubDO (`hub.ts`) and its message protocol (`protocol.ts`) |
| `src/rules/` | Game rules as pure functions with no I/O, so they're easy to test and tune. The app's Dart engine mirrors them. |
| `migrations/` | The D1 schema (TECH.md §7), plus `0002_pickup_seeds.sql` |
| `scripts/build-campaign-sql.mjs` | Turns the app's campaign into SQL for the `campaign` table |

| Rules file | Rules |
|---|---|
| `words.ts` | Normalising a guess (A–Z only), the 3-letter minimum, and checking a word can be made from the anvil letters |
| `heat.ts` | Heat tier from Smith Level, tier names, co-op and VS timers, and the median level for VS |
| `progression.ts` | XP curve, levels, ranks, hint unlocks, level-up rewards, XP per mode, and the Scrap Bin |
| `pickups.ts` | Campaign pickup seeding ([shared/pickups.md](../shared/pickups.md)) |
| `campaign.ts` | A campaign puzzle's grid words, bonus words and letter cells, for checking syncs |
| `sync.ts` | Checking and applying offline solo results (see below) |
| `coop.ts` | Claim decisions, word points, MVP and stars |
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

Friends, the leaderboard and the hub need a set-up account
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
- An entry is **rejected** if it's malformed (`invalid_entry`, with `detail`), its stage isn't in the campaign (`unknown_stage`), `puzzleId` isn't that stage's (`puzzle_mismatch`), the stage was already counted (`duplicate`), `completedAt` is more than 10 minutes ahead or before 2026 (`bad_completed_at`), a found word isn't a grid word (`unknown_word`), a bonus word isn't in the bonus list (`unknown_bonus_word`), the cells no found word covers are more than the hints used could have shown (`incomplete`; a Hammer or Chisel shows 1, a Spark Shower 5), or it took under 2 s per found word (`too_fast`).
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
| `OPEN_ROOMS` | S→C | `{rooms: []}`; always empty until rooms arrive in M3 |
| `ERROR` | S→C | `{code}`: `bad_message`, `unknown_op`, `bad_status`, `bad_invite`, `not_friends`, `friend_offline`, `rate_limited` |

On connect you get a `PRESENCE` for each online friend, then `OPEN_ROOMS`.
Send the exact text `{"op":"PING"}` as a keep-alive; the runtime answers
`{"op":"PONG"}` without waking the hub. Accepting or removing a friend
through REST updates both players' presence at once. Deleting an account
closes its sockets with code 4001.

## Local development

You need Node 22.12 or newer. Local mode doesn't need a Cloudflare account or
`wrangler login`.

```sh
cd server
npm ci
npm run db:migrate:local   # apply migrations/ to the local D1
npm run db:seed:local      # build data/campaign.sql from the app's campaign.json and load it
npm run dev                # wrangler dev on http://localhost:8787
curl http://localhost:8787/v1/version
```

- `wrangler dev` runs the Worker, the HubDO and a local D1 database. The data lives in `.wrangler/state/`, which git ignores. Delete that folder to start over.
- **Seeding:** sync checks need the campaign in the `campaign` table. `npm run db:campaign` writes `data/campaign.sql` from `../app/assets/campaign/campaign.json` (git-ignored, since it's rebuilt from that file); `db:seed:local` also loads it. Re-run it whenever the campaign is regenerated.
- Authenticated routes need a real Firebase ID token for project `wordsmith-8f550`: the Worker always checks Google's keys.
- To look inside the local database: `npx wrangler d1 execute wordsmith --local --command "SELECT COUNT(*) FROM campaign"`
- To turn off Wrangler's telemetry, set `WRANGLER_SEND_METRICS=false`.

## Tests

```sh
npm run typecheck   # tsc --noEmit (strict)
npm test            # vitest run: both projects
npx vitest run --project rules    # just the pure code
npx vitest run --project worker   # just the Worker
```

The tests run as two Vitest projects:

- **`rules`** (`test/rules/`, `test/unit/`) runs plain unit tests in Node: the game rules (with every vector in `shared/pickups.md`), sync checks, usernames, the hub protocol, the router and the campaign SQL script.
- **`worker`** (`test/worker/`) runs the Worker and HubDO inside the real `workerd` runtime using `@cloudflare/vitest-plugin` (the new name of `@cloudflare/vitest-pool-workers`). Before each test file, `test/worker/setup.ts` applies `migrations/` and loads the real campaign into the test D1 database. Tests sign their own Firebase-style tokens with a generated RSA key, which `test/worker/helpers.ts` installs with `setJwksFetcher()`.

## Changing the schema

Add a new numbered file such as `migrations/0003_something.sql`. Don't edit
a migration once it has been applied to the real database. Wrangler records
which migrations have been applied in the `d1_migrations` table. Durable
Object class changes go in the `migrations` list in `wrangler.jsonc`.

## Later: deploying

Nothing is deployed yet, and there's no Cloudflare account set up for this
project. Already configured: `FIREBASE_PROJECT_ID` (`wordsmith-8f550`, not a
secret) and the `HUB` Durable Object with its `new_sqlite_classes`
migration. Still needed:

1. A Cloudflare account, and an API token for CI.
2. Create the database with `npx wrangler d1 create wordsmith`. Paste the `database_id` it prints into `wrangler.jsonc`, replacing the all-zero placeholder.
3. Apply the migrations to it: `npx wrangler d1 migrations apply wordsmith --remote`.
4. Load the campaign: `npm run db:campaign && npx wrangler d1 execute wordsmith --remote --file data/campaign.sql`. Repeat whenever the campaign changes.
5. Deploy with `npm run deploy`, which runs `wrangler deploy`.

CI deploys need the GitHub secrets `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID`. Neither is set up yet. To raise the app version
users are told about, change `LATEST_VERSION` and `MIN_SUPPORTED_VERSION` in
`wrangler.jsonc` and deploy.
