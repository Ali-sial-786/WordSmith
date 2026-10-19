# Wordsmith API

The server side of Wordsmith: a Cloudflare Worker written in TypeScript, with
a D1 (SQLite) database, a global presence Durable Object (HubDO) and one
Durable Object per room (RoomDO). See [docs/TECH.md](../docs/TECH.md) for the
plan and [shared/room-protocol.md](../shared/room-protocol.md) for the room
contract.

| Path | What it is |
|---|---|
| `src/index.ts` | The router (every route, and which need a token), and the hourly Cron Trigger's `scheduled` handler |
| `src/auth/` | Firebase ID token checks with WebCrypto (`firebase.ts`) and reading the token from a request (`request.ts`) |
| `src/account/` | Username, avatar and nickname rules, and the profanity blocklist |
| `src/routes/` | The REST and WebSocket handlers |
| `src/db/` | D1 queries |
| `src/hub/` | HubDO (`hub.ts`) and its message protocol (`protocol.ts`) |
| `src/room/` | RoomDO (`room.ts`), the co-op and Versus referee, and its message protocol (`protocol.ts`) |
| `src/dictionary/` | Online definitions for words the app's offline lexicon lacks (`define.ts`): the Free Dictionary API, then Wiktionary, and picking and filtering their senses (below) |
| `src/contact/` | The contact form ([shared/contact.md](../shared/contact.md)): forwarding messages to the inbox through Resend (`mail.ts`) and the hourly upkeep that retries them and tidies up (`upkeep.ts`); the route is `src/routes/contact.ts` and the table `src/db/contact.ts` |
| `src/push/` | Notifications ([shared/push.md](../shared/push.md)): the FCM HTTP v1 sender with its Google OAuth JWT and access-token cache (`fcm.ts`), sending to each of a player's phones (`send.ts`), the invite and gift messages (`invite.ts`, `gift.ts`), and the daily reminders' hourly run (`reminder.ts`) |
| `src/rules/` | Game rules as pure functions with no I/O, so they're easy to test and tune. The app's Dart engine mirrors them. |
| `migrations/` | The D1 schema (TECH.md §7), plus `0002_pickup_seeds.sql`, `0003_daily_completions.sql`, `0004_push_tokens.sql`, `0005_forge_board.sql` (the Forge Board, Masterworks and catch-up days), `0006_survival.sql` (The Crucible's runs and best runs), `0007_names.sql` (when the username last changed, and nicknames for friends) `0008_safety.sql` (blocks and reports) and `0009_contact.sql` (contact form messages) and `0010_age.sql` (birth month and year) |
| `scripts/build-campaign-sql.mjs` | Turns the app's campaign into SQL for the `campaign` table |
| `data/mp_bank.json` | The multiplayer puzzle bank, made by `tools/puzzlegen` (3,184 puzzles: 250 per heat for Versus, 52–100 per heat and co-op size). The Daily Commission uses its first part only (`m-00001`–`m-00960`). Never shipped in the app. |
| `scripts/build-bank-sql.mjs` | Turns the bank into SQL for the `puzzles` table |

| Rules file | Rules |
|---|---|
| `words.ts` | Normalising a guess (A–Z only), the 3-letter minimum, and checking a word can be made from the anvil letters |
| `heat.ts` | Heat tier from Smith Level, tier names, co-op and VS timers, and the median level for VS |
| `progression.ts` | XP curve, levels, ranks, hint unlocks, level-up rewards, XP per mode, and the Scrap Bin |
| `pickups.ts` | Campaign pickup seeding ([shared/pickups.md](../shared/pickups.md)) |
| `masterworks.ts` | Gilded cells (seeded like pickups), the twelve Masterworks and when each is finished ([shared/masterworks.md](../shared/masterworks.md)) |
| `rewards.ts` | Forge Board and Masterwork rewards: locked hint types become Hammer Strikes, and the XP's level-ups |
| `orders.ts` | Work Orders: the day's three (the same for everyone), the week's two, the swap, rewards, and what an accepted play counts towards |
| `board.ts` | ISO weeks, the Daily Stoke, Weekly Trials standings and prizes, gift limits, and the `GET /v1/me/board` body ([shared/forge-board.md](../shared/forge-board.md)) |
| `campaign.ts` | A campaign puzzle's grid words, bonus words and letter cells, for checking syncs, and which puzzle a Master Forge stage plays |
| `sync.ts` | Checking and applying offline solo results (see below) |
| `daily.ts` | The Daily Commission: the day's heat and puzzle pick, which day a completion may be for (on time, or a late catch-up day), streaks, daily XP, checking and applying a completion (with sync.ts's checks and hint arithmetic), and the calendar's trophies |
| `coop.ts` | Claim decisions, word points, MVP and stars |
| `room.ts` | Room codes, colours, the host, room timings (countdown, rejoin, closing) and the SUBMIT rate limit |
| `mold.ts` | A bank puzzle's slots and cells, which slots filled cells complete, where hints and embers land |
| `coop-round.ts` | One co-op round: claims, self-completing slots, hints, embers, scores, results and XP |
| `vs.ts` | Round results, series clinch, sudden death and the podium |
| `vs-round.ts` | One Versus round on everyone's own mold (claims, self-completing slots, embers, progress) and the series around it (tally, racers who left, what comes next, results and XP) |
| `survival.ts` | Survival ([shared/survival.md](../shared/survival.md)): the countdown (`survivalHeatMs`), the heat order and the heated slot, a mold's clock (grace, pauses), and checking and scoring a Crucible run. `coop-round.ts` and `vs-round.ts` keep each round's clocks |

## Routes

Everything is under `/v1`. Every route except `/version`, `/health`,
`/apk/:version`, `/define/:word` and `/contact` needs `Authorization: Bearer <Firebase ID token>`; the
WebSocket route reads the token from `Sec-WebSocket-Protocol` instead.
From Quebec, where online play isn't offered, every route that needs a token
answers `403 quebec_not_offered` before reading it, except `DELETE /me` and
`DELETE /me/push-token`, unless the request has `X-Not-In-Quebec: 1`
([shared/region.md](../shared/region.md)).
Errors are always JSON `{"error": "<code>", "message"?: "..."}`. A missing or bad token is
`401 {"error": "unauthorized", "message": "<reason>"}` (`missing_token`,
`expired`, `bad_signature`, `unknown_kid`, `bad_audience`, …).

| Route | Body → response |
|---|---|
| `GET /version` | `{latest, minSupported, protocol, apk, quebec}`, from the `vars` in `wrangler.jsonc`. `apk` is where the Android app downloads `latest` to update itself: this server's `/apk/<latest>`, or null without `APK_SOURCE_URL`. `quebec` is true when the request comes from Quebec ([shared/region.md](../shared/region.md)) |
| `GET /apk/:version` · `HEAD` | The APK for a version (`1.2.3`) or `latest`, streamed from `APK_SOURCE_URL` (where release.yml publishes it) with its length, as `wordsmith-<version>.apk`, so players never see where builds are kept (`src/routes/apk.ts`). No token needed. `404 apk_not_found` when it isn't published (yet), `502 apk_unavailable` when the source fails. |
| `GET /health` | `{ok: true}` |
| `GET /define/:word` | `{word, senses: [{pos, gloss}], source, sourceUrl, license, licenseUrl}`: what a word means, from an online dictionary, for words the app's offline lexicon lacks (below). No token needed. `word` is lowercased; `source` is `dictionaryapi.dev` or `wiktionary`; `sourceUrl` is the Wiktionary entry and `license`/`licenseUrl` its CC BY-SA licence, which the app shows with the text. `400 invalid_word` unless it's 2–15 letters A–Z, `404 word_not_found` when neither dictionary has it (or has it only as a name), `502 dictionary_unavailable` when one couldn't be asked and the other didn't have it. |
| `GET /me` | My profile (below). The first call creates the account with 3 Hammer Strikes; `needsSetup` stays true until setup. |
| `POST /me/setup` | `{username, avatar, birthYear?, birthMonth?}` → my profile. Under 13 (by birth month and year): `403 under_13` and the account is deleted ([shared/age.md](../shared/age.md)); without them (apps before 0.7) the profile says `needsAge`. Username: 3–16 of `A–Z a–z 0–9 _`, unique ignoring case, not blocked or reserved (`400 invalid_username`, `400 username_not_allowed`, `409 username_taken`). Avatar: `avatar_01` … `avatar_16` (`400 invalid_avatar`). Setup can't change the username (`409 already_set`; that's `POST /me/username`), but repeating it with another avatar changes the avatar. |
| `POST /me/age` | `{birthYear, birthMonth}` → my profile, once, for an account with no age yet. `400 invalid_birth`, `409 age_already_set`, `403 under_13` (the account is deleted). The profile's `needsAge` and `minor` (under 18) come from it. |
| `POST /me/username` | `{username}` → my profile, renamed. Setup's rules (`400 invalid_username`, `400 username_not_allowed`, `409 username_taken`, unique ignoring case; a change of case only is fine), as often as the player likes. Asking for exactly my current name changes nothing and answers 200 (a retry). See "Changing the username" below. |
| `DELETE /me` | `{ok: true}`. Deletes all my rows (push tokens too, my blocks either way, and reports I made or that were made about me). Past matches keep a row under a placeholder ID, which shows as "Deleted smith". The app should then delete the Firebase user; another `GET /me` before that would start a fresh account. |
| `POST /me/push-token` | `{token}` → `{ok: true}`: this phone's FCM registration token gets invite notifications (below). A token another account had moves here; an account keeps its 5 newest. `400 invalid_push_token` unless `token` is 1–4096 printable ASCII characters without spaces. |
| `DELETE /me/push-token` | `{token}` → `{ok: true}`: no more notifications to that phone (sign-out, or turned off). Only removes my own token; unknown tokens are fine. `400 invalid_push_token` as above. |
| `PUT /me/reminder` | `{hour}` (a UTC hour 0–23, or `null`) → `{ok: true, hour}`: a daily reminder while the Daily Commission is waiting (below). `400 invalid_body`. |
| `GET /users/:username` | `{id, username, avatar, level, rank, campaignCompleted, stats, friendship}`; `friendship` is `self`, `none`, `friends`, `request_sent` or `request_received`. `404 user_not_found`. |
| `POST /solo/sync` | `{entries: [...]}` → `{profile, results}`; see below |
| `POST /survival/solo` | A Crucible run `{runId, startedAt, endedAt, saved, puzzles}` → `{profile, xp: {xp, level, levelUps, rewards}, best, newBest, duplicate?}`; see Survival below. `400 invalid_run` (with a `message`), `503 campaign_unavailable`, `409 sync_conflict`. |
| `GET /daily?date=` | `{date, heat, puzzle, completed, streak, best, total}`: today's Daily Commission, or a catch-up day's (below). `400 wrong_day`, `400 invalid_body`. |
| `POST /daily/complete` | `{date, foundWords, bonusWords?, hintsUsed?, durationMs}` → `{profile, xp, late, streak, best, total, alreadyDone}`. `400 wrong_day`, `400 incomplete`, `400 too_fast`, `400 invalid_body`; `409 sync_conflict` (retry). |
| `GET /daily/calendar?month=` | `{month, days, trophy, trophies}` for this month (default) or last. `400 wrong_month`, `400 invalid_body`. |
| `GET /me/board` | The Forge Board (below) |
| `POST /me/stoke/claim` | → `{profile, board, reward}`. `409 already_claimed`. |
| `POST /me/orders/swap` | `{slot: "d0" \| "d1" \| "d2"}` → `{profile, board, reward}`. `400 invalid_slot`, `409 swap_used`, `409 order_done`. |
| `POST /me/orders/claim` | `{slot}` (`d0`–`d2`, `w0`, `w1`, `chest`) → `{profile, board, reward}`. `400 invalid_slot`, `409 already_claimed`, `409 not_done`. |
| `POST /me/trials/claim` | → `{profile, board, reward}`. `409 no_prize`, `409 already_claimed`. |
| `POST /me/gifts/claim` | → `{profile, board, reward}`. `409 nothing_to_claim`. |
| `POST /friends/:id/gift` | → `{ok: true}`. `400 cannot_gift_self`, `404 not_friends`, `409 already_sent`. |
| `GET /friends` | `{friends, incoming, outgoing}`, each a list of `{id, username, avatar, level, rank, since, nickname}`. `nickname` is the one I gave that friend (`null` for none, and always for requests); `friends` is sorted by it, or else the username. |
| `PUT /friends/:id/nickname` | `{nickname}` → `{ok: true, nickname}`: my private name for an accepted friend, or `{nickname: null}` to clear it. Trimmed, 1–20 characters as they show on screen (an emoji counts once; at most 160 code points), at least one visible character, and no control characters, line breaks or bidi overrides (`400 invalid_nickname`). `404 not_friends` for requests, strangers and myself. Only `GET /friends` returns it, and only to me; removing the friend drops it. |
| `POST /friends/request` | `{username}` → `{status: "pending" \| "accepted", user}`. Asking someone who already asked you accepts. `404 user_not_found`, `400 cannot_friend_self`, `409 already_friends`, `409 too_many_requests`. While either has blocked the other: `409 blocked` if I blocked them (whatever they did), else `404 user_not_found`, just as for a wrong name. |
| `POST /friends/respond` | `{userId, accept}` → `{status: "accepted" \| "declined", user}`. `404 request_not_found` (also for accepting while either has blocked the other). |
| `DELETE /friends/:id` | `{ok: true}`. Removes a friend, cancels my request, or declines theirs. `404 not_found`. |
| `GET /me/blocks` | `{blocks: [{id, username, avatar, at}]}`, the players I've blocked, newest first (`at`: when, epoch ms). See [shared/safety.md](../shared/safety.md). |
| `PUT /me/blocks/:id` | `{ok: true}`: blocks that player (again is fine, and keeps the first time). Ends any friendship or request between us either way, as `DELETE /friends/:id` would, hub updates included. `400 cannot_block_self`, `404 user_not_found`. They aren't told. |
| `DELETE /me/blocks/:id` | `{ok: true}`, always: unblocks them. The friendship stays ended. |
| `POST /reports` | `{userId, reason, details?, room?, lines?}` → `201 {ok: true}`. `reason`: `harassment`, `hate`, `sexual`, `name`, `cheating`, `spam` or `other`; `details` trimmed, at most 500 characters (code points); `room` a room code; `lines` at most 20 `{id, text, at}` with `text` at most 200 characters. Missing and `null` are the same. `400 bad_request` for anything malformed (a body that isn't a JSON object too), `400 cannot_report_self`, `404 user_not_found`, `429 too_many_reports` past 10 in 24 hours. Stored in `reports` with their username at the time and `status` `open`; nothing tells them. |
| `POST /contact` | `{topic, message, email?, username?, website?}` → `201 {ok: true}`, no token needed: the web pages' contact form ([shared/contact.md](../shared/contact.md)). `topic`: `account`, `deletion`, `bug`, `player`, `privacy`, `feedback` or `other`; `message` 1 to 2000 characters; `email` an address to reply to; `username` at most 40 characters; `website` the hidden field, where anything means a bot (still `201`, nothing kept). `400 bad_request`, `429 too_many_messages` past 5 an hour from one IP, `429 contact_busy` past 80 a day in all. Stored in `contact_messages`, then emailed to `CONTACT_EMAIL` through Resend when the `RESEND_API_KEY` and `CONTACT_EMAIL` secrets are set (`src/contact/mail.ts`); the hourly cron retries failures and tidies up. |
| `GET /leaderboard` | `{entries: [{place, id, username, avatar, level, rank, totalXp, vsSeriesWon, vsRoundsWon, coopRounds, coopMvps, me}]}`, me plus my friends by XP. There's no co-op best score yet: the schema has no column for it. |
| `GET /ws/hub` | WebSocket upgrade to HubDO (below) |
| `POST /rooms` | `{mode: "coop" \| "vs"}` → `{code}`: a new room with me as host (below). `400 invalid_mode` otherwise. |
| `GET /rooms/:code` | `{code, mode, phase, host: {id, username} \| null, players, maxPlayers, seated}`; `players` is a count, `seated` whether the caller holds a seat. The code is case-insensitive. `404 room_not_found`. |
| `GET /ws/room/:code` | WebSocket upgrade to that room's RoomDO (below). Refused before upgrading with `404 room_not_found`, `409 room_full` or `409 round_in_progress`. |
| `POST /rooms/:code/video` | `{url, token, room, expiresAt}`: a LiveKit token for the room's video chat (`src/video/livekit.ts`). Only for players holding a seat: `403 not_in_room`. `503 video_unavailable` until the `LIVEKIT_URL`, `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` secrets are set. |

Friends, the leaderboard, the hub, rooms, the Daily Commission, the Forge Board, push tokens, changing the username, blocks and reports need a set-up account
(`403 setup_required`). `/me`, `/me/setup`, `/solo/sync`, `/survival/solo` and `/users/:username` don't.

### Definitions

`GET /v1/define/:word` (`src/routes/define.ts`, `src/dictionary/define.ts`) is
the app's fallback when its offline WordNet lexicon has no entry, which is
often the case for rarer words:

- **Sources:** the Free Dictionary API (`https://api.dictionaryapi.dev/api/v2/entries/en/<word>`) first; when it has nothing, Wiktionary's REST definitions (`https://en.wiktionary.org/api/rest_v1/page/definition/<word>`) for the lowercase title, English entries only, with the HTML stripped. Both serve Wiktionary's text (CC BY-SA), and the app says which one a meaning came from. Requests carry a descriptive `User-Agent` with the repository's URL, as Wikimedia's API policy asks, and time out after 5 s.
- **Senses** are picked as `tools/dictgen` picks the lexicon's: at most 3, round robin across parts of speech (the one with more senses first), duplicates dropped, glosses cleaned and cut to 160 characters. Slur and sexual senses are left out with the patterns of `tools/dictgen/data/gloss_filter.txt`, plus Wiktionary's `(vulgar)`, `(offensive)` and `(slur)` labels (`(derogatory)` only when there's another sense to show).
- **Names** aren't words in Wordsmith (`tools/puzzlegen` drops them from the word list), so they never come back: proper-noun senses, the Free Dictionary API's capitalised entries (`Omar`, `Boston`) and senses worded as a given name or surname (`A male given name from Arabic.`) are left out, and Wiktionary's capitalised titles aren't asked. A word with only those is a `404 word_not_found`.
- **`pos`** is the app's `Sense.pos`: `n`, `v`, `a` or `r` for noun, verb, adjective and adverb; another part of speech spelled out in lowercase (`interjection`, `pronoun`, …); or `""`.
- **Caching:** answers are kept in the Workers Cache API (`caches.default`, per data centre) under the word: definitions for 30 days, misses (the 404) for a day. A `502` isn't kept, so the next ask tries again. Responses also carry a matching `Cache-Control`.

### Profile

```json
{
  "id": "<firebase uid>", "username": "Ali", "avatar": "avatar_03", "needsSetup": false,
  "totalXp": 1000, "level": 10, "xpIntoLevel": 100, "xpForLevel": 150, "rank": "Journeyman",
  "campaignCompleted": 12, "nextStage": 13,
  "scrapBin": 4, "hints": {"hammer": 5, "chisel": 1, "sparks": 0},
  "stats": {"wordsForged": 40, "longestWord": "THREAD", "soloDone": 12, "coopRounds": 0,
            "coopMvps": 0, "vsSeries": 0, "vsSeriesWon": 0, "vsRoundsWon": 0},
  "masterworks": {"pieces": 7}, "reminderHour": 18,
  "survivalBest": {"puzzles": 4, "words": 31, "saved": 12, "at": 1792200300000},
  "createdAt": 1792200000000
}
```

`campaignCompleted` is the highest stage completed (`profiles.campaign_stage`,
0 = none). `nextStage` is `campaignCompleted + 1`, which is what the app's
`Profile.campaignStage` holds.

### Changing the username

`POST /me/username` (`src/routes/me.ts`, `changeUsername` in
`src/db/accounts.ts`) has no limit on how often: two players racing for a
name meet the `UNIQUE COLLATE NOCASE` index (one gets `409 username_taken`),
and `users.username_changed_at` records the latest change. In D1 the name lives only in
`users`: friends, requests, the leaderboard, the Forge Board's Weekly Trials
and gifts, and `GET /users/:username` all join it, and match summaries only
hold user IDs. Two places keep a copy, and are told before the answer (best
effort, like presence):

- **HubDO** (`usernameChanged`): each of the player's sockets carries the name for the invites it sends, and each room they host is listed under it. It updates both, sends the host's connected friends a fresh `OPEN_ROOMS`, and returns the codes of the rooms the player is in (by their `in_room:` status) or hosts.
- **RoomDO** (`renamed`), for each of those codes: the player's seat takes the new name and everyone gets a `LOBBY`; the open-rooms listing, `GET /rooms/:code`'s host and results still to come follow. Results already sent keep the old name. A room that missed it catches up when the player next connects, since each connection brings the player's current name.

### Solo sync

Each entry is what the app queues on finishing a campaign puzzle:
`{stage, puzzleId, foundWords, bonusWords, hintsUsed, pickups: [{cell, kind}], gilded?: [cell], pickupSeed?, durationMs, completedAt}`
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
- **Master Forge** ([shared/master-forge.md](../shared/master-forge.md)): with `N` the campaign's last stage, a stage `N < s ≤ 10N` plays campaign puzzle `((s − N − 1) mod N) + 1` (`loadCampaignPuzzles` in `src/db/campaign.ts`) and is otherwise exactly a campaign stage, so `campaignCompleted` keeps counting past `N`.
- An entry is **rejected** if it's malformed (`invalid_entry`, with `detail`), its stage isn't in the campaign or the Master Forge (`unknown_stage`), `puzzleId` isn't that stage's (`puzzle_mismatch`), the stage was already counted (`duplicate`), `completedAt` is more than 10 minutes ahead or before 2026 (`bad_completed_at`), a found word isn't a grid word (`unknown_word`), a bonus word isn't in the bonus list (`unknown_bonus_word`), the cells no found word covers are more than the hints used could have shown (`incomplete`; a Hammer or Chisel shows 1, a Spark Shower 5), or it took under 1 s per found word (`too_fast`).
- An **accepted** entry gives 10 XP plus 1 per bonus word (up to +5), level-up rewards, and puts its bonus words in the Scrap Bin (each 10 → a Hammer Strike). Hints used are taken off the stock after adding the puzzle's pickups and Scrap Bin hammers, and before level-up rewards. Stock never goes below 0; any overdraw is reported in `hintsClamped`.
- **Pickups** are checked by recomputing `pickupsFor(seed, puzzleId, cellCount, levelAtStart)`. The seed is `pickupSeed` (the app's install ID from before sign-in) or else the account's uid. A claim on the right cell gets the server's type; other claims are dropped (`pickupsRejected`). An account may use its own uid and up to 5 install IDs (`pickup_seeds` table).
- **Gilded cells** ([shared/masterworks.md](../shared/masterworks.md)) are checked the same way with `gildedCell(seed, …)`: a right claim is a blueprint piece (`profiles.masterwork_pieces`; the result gets `gilded: [cell]`), a wrong one is ignored. A piece that finishes a Masterwork grants 100 XP, a Chisel and a Spark Shower (locked types as Hammer Strikes) in the same sync: the result gets `masterwork: {id, reward}`, and `xp_events` a `masterwork` row.
- **Work Orders:** the accepted entries (puzzles, those with no hints, bonus words, typed words) are added to the player's orders for the sync's day and week, in the same batch (`src/db/orders.ts`).
- `503 campaign_unavailable` means the server's campaign table is empty: keep the queue and retry later. `409 sync_conflict` means the profile kept changing during the sync: retry.

### Daily Commission

[shared/daily.md](../shared/daily.md), with the rules in `src/rules/daily.ts`:

- **The day** is the UTC date. Its heat follows the weekday (Mon 1, Tue 2, Wed 3, Thu 4, Fri 5, Sat 6, Sun 3), and its puzzle is candidate `fnv1a32("daily:" + date) % n` among the `n` size-1 bank puzzles at that heat, ordered by id (the nearest heat that has some if that one has none; `503 daily_unavailable` if the bank is empty). `puzzle` is in the campaign format with `id: "daily-<date>"`; `heat` is the puzzle's.
- **Streaks** come from `daily_completions`: `streak` is the run of days ending today, or yesterday while today isn't done; `best` the longest run.
- **Catch-up days:** any day from the 1st of last month up to today can be fetched (`?date=`) and completed. One that isn't on time (today, or yesterday in the first hour of today) is **late**: a flat 15 XP, `daily_completions.late = 1`, and streaks ignore it. `total` counts every completion. `GET /daily/calendar` lists a month's days done and its trophy (bronze 7+, silver 15+, gold every day) and how many months have earned each.
- **Completing** is checked like a solo sync entry: `date` must be in that window (`wrong_day`); the typed grid words plus the hints used must be able to fill every letter cell (`incomplete`; a slot that filled in by itself needn't be in `foundWords`, and words that aren't grid words are ignored); at least 1 s per word typed (`too_fast`). The first completion of a day grants `25 + 5 × (streak − 1)` XP, capped at 55, with level-up rewards; the puzzle's bonus words among `bonusWords` go to the Scrap Bin (others are ignored); the hints used come off the stock after the Scrap Bin's hammers and before level-up rewards, never below 0. Typed words count as words forged. A repeat answers `alreadyDone: true` and grants nothing.
- **Written** in one optimistic batch like solo sync: the `daily_completions` row, `xp_events` (`source: "daily"`, `ref`: the date), the profile, hints and stats, Work Orders progress, and `puzzle_seen` for the bank puzzle, so rooms don't serve it again for 60 days. Deleting the account deletes its completions.

### Forge Board

[shared/forge-board.md](../shared/forge-board.md), with the rules in `src/rules/board.ts`, `orders.ts` and `rewards.ts`, the queries in `src/db/board.ts` and `src/db/orders.ts`:

- **`GET /me/board`** reads everything in one D1 batch and writes nothing: `{date, week, stoke, orders, trials, gifts}`.
- **Claims** read the account, then the board, decide, and write one optimistic batch like solo sync: the claim's mark (`profiles.stoke_*`, `work_orders.claimed`, the day's `chest` or `swap` row, `trial_claims`, `gifts.claimed_at`), `xp_events` (`source: "board"`), the hints (with locked types as Hammer Strikes) and level-up rewards, and the profile. Every write the marks depend on moves the profile's version, so two claims at once grant once; the loser re-reads and gets the claim's `409`.
- **Work Orders progress** is written by solo sync, the daily, and the room's co-op and Versus results (`writeMatch` in `src/db/rooms.ts`, from the words each player claimed, which the room keeps in the round and the series), always in the batch that writes the play. A player's rows for the day and week are made then, from the configured orders.
- **Weekly Trials XP** is `weekly_xp`, which a trigger on `xp_events` keeps in step (migrations/0005), so every XP grant counts at the ISO week it was recorded.
- **Gifts:** one row per sender, receiver and day; `POST /friends/:id/gift` sends the notification with `ctx.waitUntil` after answering (`src/push/gift.ts`). Rows older than 14 days are dropped as new ones are written.
- Deleting the account deletes its `work_orders`, `weekly_xp`, `trial_claims` and every gift it sent or received.

### Hub WebSocket

Connect to `/v1/ws/hub` offering the subprotocols `wordsmith.v1, <ID token>`
(`Sec-WebSocket-Protocol`); the server accepts `wordsmith.v1`. Messages are
JSON `{op, ...}`, defined in `src/hub/protocol.ts`:

| Op | Direction | Payload |
|---|---|---|
| `PRESENCE` | S→C | `{userId, status}`; status is `online`, `solo`, `in_room:<CODE>` or `offline` |
| `SET_STATUS` | C→S | `{status}`: `online`, `solo` or `in_room:<6 chars A–Z 0–9>` |
| `INVITE` | C→S | `{to, code, mode: "coop" \| "vs"}`, only to an accepted friend who's online or, with push on, has a phone registered (below) |
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

### Notifications

[shared/push.md](../shared/push.md), in `src/push/` and HubDO. It's off
until the Worker secret `FCM_SERVICE_ACCOUNT` holds a service account's JSON
key (`client_email`, `private_key` as a PKCS#8 PEM, `project_id`); the deploy
workflow copies it from the GitHub secret of the same name. A missing or
malformed secret means push is off: invites behave exactly as before, and
the hub doesn't touch D1 for them. Tokens are stored either way.

- **Tokens** live in `push_tokens` (`migrations/0004_push_tokens.sql`): the token is unique across accounts, and registering it again gives it a new, higher `id`, so each account keeps its 5 highest.
- **Sending:** when the hub relays an `INVITE`, it also reads the friend's tokens and the nickname they gave the inviter (one D1 batch, `pushTargetOf` in `src/db/push.ts`) and sends each an HTTP v1 message: title `<nickname or username> invited you to Co-op` or `… to Versus`, body `Tap to join room <CODE>`, `data: {type: "invite", code, mode, from: <user id>}`, `android: {priority: "high", ttl: "300s", collapse_key: "invite-<CODE>"}`. It goes out with `ctx.waitUntil`, after the socket relay. Only when the friend has no open socket does the hub wait for the token read, since it decides the reply: `ERROR friend_offline` if they have no tokens either, otherwise nothing (as for a relayed invite).
- **Google:** the sender signs an RS256 JWT with the key (`iss` = `client_email`, `scope` = `https://www.googleapis.com/auth/firebase.messaging`, `aud` = `https://oauth2.googleapis.com/token`, one hour), trades it for an access token, and keeps that per isolate until 5 minutes before it expires (a 401 from FCM drops it early).
- **Failures:** a token FCM calls dead (404 or `UNREGISTERED`, or 400 `INVALID_ARGUMENT` about `message.token`) is deleted. Anything else is logged and ignored, so an invite never fails because a notification did.
- **Gifts** (`POST /friends/:id/gift`) notify the friend's phones the same way, after the answer, also under the receiver's nickname for the sender if they gave one (`src/push/gift.ts`).
- **Daily reminders:** a Cron Trigger (`"0 * * * *"` in `wrangler.jsonc`) runs `scheduled` in `src/index.ts` at the start of every hour. `src/push/reminder.ts` finds up to 500 accounts whose `reminder_hour` is that UTC hour, that have a token, haven't done today's Daily Commission and weren't reminded today (`profiles_by_reminder` index; never-reminded first), records today in `reminder_last` (an `UPDATE … RETURNING`, so an overlapping run can't remind twice), and sends "Today's Daily Commission is waiting" with the streak ending yesterday. Without the FCM key it reads nothing.

### Rooms

Implements [shared/room-protocol.md](../shared/room-protocol.md) for
`mode: "coop"` and, further down, `mode: "vs"`; the message types are in `src/room/protocol.ts`. Connect to
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

### Versus rooms ("Anvil Clash")

The contract's "Versus (M4)" section, refereed in `src/rules/vs-round.ts`
(with `vs.ts`, `heat.ts` and `progression.ts`). Everything above about
joining, dropping out, the host, closing and the alarm applies, with these
differences:

- **Seats:** up to 5, colours 0–4 (4 is titanium). `GET /rooms/:code` says `maxPlayers: 5`; open rooms list `max: 5`.
- **Lobby:** `LOBBY.series` (3, 5, 7 or 10; default 3) is set by the host's `CONFIG {series}` in the lobby (`not_host`, `wrong_phase`; any other value is `bad_message`, and so is `CONFIG` in a co-op room). `LOBBY.heat` is the median level of the seated players (`vsHeat`), and the series' heat while one is on.
- **START** (and `AGAIN` from results) needs 2 connected players (`not_enough_players`) and starts a series with everyone seated (connected or within their 30 s) as racers, at the room's length and heat. `HINT` is always `ERROR no_hints`.
- **Phases:** `lobby → countdown → round → standings (10 s) → countdown → … → results`. Newcomers are refused with `409 round_in_progress` during countdown, round and standings.
- **Rounds:** each picks a size-1 bank puzzle at the series' heat, skipping puzzles anyone still in the series saw in the last 60 days, and records it as seen. `ROUND_START` adds `series`, `regular` (`null` in sudden death), `suddenDeath`, `players` (racing; everyone else watches) and `tally` (wins before the round). The timer is `vsRoundTimerMs(heat)`.
- **Words:** each racer has their own mold. `WORD_RESULT` has no `points`; `claimed` adds `slot`, `auto` (crossing slots this completed on the sender's mold) and `pickup` (an ember, granted after the series); `already` (no `by`) means the sender already has the word, including a slot that filled in by itself or a bonus word they found; `bonus` words go to the Scrap Bin at the end. Every gain sends `PROGRESS {id, filled, total}` to everyone. Watching (sudden death, or out of the series) gets `ERROR not_playing`; standings and results get `too_late`; lobby and countdown `ERROR wrong_phase`.
- **Round end:** the first racer to fill every letter wins at once (`reason`/`how: "finished"`). At the timer the most letters wins, ties going to whoever got there first by a server-side counter (`timeout`), or nobody (`none`). `ROUND_END` = `{round, reason, winner, how, progress, tally, answers, next, standingsEndsAt}`; `round` (the round that ended) isn't in the contract.
- **Series:** decided among the racers still in it (`seriesStatus`): clinched, or a clear leader after the last regular round, ends it; a tie after the last regular round is sudden death between the tied leaders, replayed with the same players while nobody wins.
- **Leaving:** a racer who leaves or runs out of rejoin time is out: they stay listed (not connected) until the series ends, keep their wins on the podium and get XP for the rounds they raced, but can't win. If that leaves one racer (or decides the series) it ends at once: a round in play is resolved first (`reason: "timeout"`); a countdown's round never started and doesn't count; during the standings only `SERIES_END` follows. A racer who left may come back to watch.
- **`SERIES_END`** `{winner, early, forfeit, rounds, podium: [{id, username, wins, place}], xp}`: the podium ranks everyone in the series by wins (equal wins share a place; the winner first among them). `forfeit` means the others all left (then `early` is false). `xp[id]` is co-op's shape plus `pickups` (embers collected). If the room closes mid-series, it ends with what was played (`winner` only if already decided).
- **XP:** one D1 batch at the end of the series (retried like co-op's): the `matches` row (`mode: "vs"`, summary with the series), `match_players` (podium place, round wins, XP), `xp_events` (`source: "vs"`), `vsSeriesXp` (5 per round raced, 10 per round won, 30 for the series), level-up rewards, Scrap Bin hammers from the series' bonus words, embers, and stats `vs_series`, `vs_series_won`, `vs_rounds_won`, `words_forged` and `longest_word`.
- **SNAPSHOT:** `lobby`; during a countdown or round `round` (the `ROUND_START` fields plus `mine: {claims, auto}`, the receiver's own mold, empty for someone watching, and `progress`); during standings `standings` (the last `ROUND_END`); during results `results` (the `SERIES_END`) and `standings`.

### Survival

[shared/survival.md](../shared/survival.md), with the rules in `src/rules/survival.ts` (and each round's clocks in `coop-round.ts` and `vs-round.ts`):

- **Rooms:** the host's `CONFIG {variant}` (lobby or results, either mode) picks the variant for the next `START` or `AGAIN`; a Versus series keeps the one it started with. Classic rooms are exactly as before: every survival field is left out, so a message without `variant` is classic.
- **The clock:** a survival round keeps the heat order and a countdown per mold (the team's, or each racer's) in its stored round, and the DO's one alarm also covers the next melt (deadline + 300 ms). `endsAt` is only a 10-minute cap. A countdown pauses while nobody is there to forge it (co-op: no player connected; Versus: that racer away) and resumes, deadline moved on, when someone is back (`syncHeat` in `room.ts`).
- **The Crucible:** `POST /v1/survival/solo` checks a run against the campaign (`checkSurvivalRun`), and writes it in one optimistic batch like solo sync: `survival_runs`, `xp_events` (`source: "survival"`, `ref`: the run id), hints, words forged, `survival_best` when the run beats it, and Work Orders progress. The profile's `survivalBest` comes from `survival_best`. Deleting the account deletes both tables' rows.

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

- **`rules`** (`test/rules/`, `test/unit/`) runs plain unit tests in Node: the game rules (with every vector in `shared/pickups.md`), the co-op round and mold rules (every bank puzzle is parsed), the Versus round and series rules, Survival's rules, the Daily Commission rules, sync checks, usernames, the hub and room protocols, the router, the campaign and bank SQL scripts, LiveKit tokens, online definitions (parsing both dictionaries, picking and filtering senses, the fallback order, with `setDictionaryFetcher()` standing in for the network), and the FCM sender (the JWT, checked against a generated key's public half; the access-token cache; the invite message; which tokens to forget).
- **`worker`** (`test/worker/`) runs the Worker, HubDO and RoomDO inside the real `workerd` runtime using `@cloudflare/vitest-plugin` (the new name of `@cloudflare/vitest-pool-workers`). Before each test file, `test/worker/setup.ts` applies `migrations/` and loads the real campaign and bank into the test D1 database. Tests sign their own Firebase-style tokens with a generated RSA key, which `test/worker/helpers.ts` installs with `setJwksFetcher()`. Room tests (`rooms.test.ts` for co-op, `vs.test.ts` for Versus, `survival.test.ts` for Survival rooms; `survival-solo.test.ts` is The Crucible's endpoint) drive real WebSockets; they run the DO's alarm early with `runDurableObjectAlarm()` (the room treats an alarm as "the planned deadline has come"), evict it with `evictDurableObject()`, and read or adjust its storage with `runInDurableObject()`. `daily.test.ts` and `board.test.ts` move the clock with Vitest's fake `Date` (only `Date` is faked, and each test signs fresh tokens at the new time), so streaks, Work Orders and Weekly Trials across days and weeks run without waiting. `define.test.ts` answers the dictionaries with `setDictionaryFetcher()` and checks the Cache API keeps hits and misses. The test env has no `FCM_SERVICE_ACCOUNT`, so push is off everywhere except `push.test.ts`, which installs a generated key with `setFcmServiceAccount()` and catches the requests to Google with `setFcmFetcher()` (both in `src/push/fcm.ts`; the HubDO runs in the test's isolate, so it sees them). Likewise there's no `RESEND_API_KEY`, so contact form emails are off except in `contact.test.ts`, which installs settings with `setContactMailConfig()` and catches the requests to Resend with `setContactFetcher()` (`src/contact/mail.ts`).

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

Optional Worker secrets, which the deploy workflow copies from GitHub
secrets of the same names when they're set: `LIVEKIT_URL`,
`LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` (video chat), and
`FCM_SERVICE_ACCOUNT` (invite notifications).

CI deploys need the GitHub secrets `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID`. Neither is set up yet. To raise the app version
users are told about, change `LATEST_VERSION` and `MIN_SUPPORTED_VERSION` in
`wrangler.jsonc` and deploy.
