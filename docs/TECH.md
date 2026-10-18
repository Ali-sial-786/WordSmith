# Wordsmith — Technical Plan

> Status: **Plan approved, not yet built.** Game rules live in
> [DESIGN.md](DESIGN.md). This document covers how the app and online play are
> built.

---

## 1. Stack

| Layer | Choice | Cost |
|---|---|---|
| Android app | **Flutter** (Dart). Android only for v1. | Free |
| Sign-in | **Firebase Authentication** (Google, email/password) | Free (Spark plan) |
| API | **Cloudflare Workers** (TypeScript) | Free plan |
| Real-time rooms | **Cloudflare Durable Objects**, one per room, acting as the referee | Free plan |
| Database | **Cloudflare D1** (SQLite): profiles, XP, hints, friends, puzzles | Free plan |
| Distribution | Signed APK on **GitHub Releases**, sent to friends directly, plus Google's free limited-distribution developer account (see [DISTRIBUTION.md](DISTRIBUTION.md)) | Free |
| CI/CD | GitHub Actions | Free tier |
| Puzzle generator | Python 3 script (`tools/puzzlegen`) | — |

**Target running cost: $0/month.** If we ever outgrow the free plan,
Cloudflare's paid plan starts at $5/month.

### Why this stack
- **A Durable Object is a single referee for each room.** It handles one event at a time, in the order events arrive. That gives co-op's "first to enter the word gets the point" for free, with no race conditions or locking.
- **The room code can be the Durable Object's name.** `idFromName(code)` sends every player with that code to the same room instance.
- **The WebSocket Hibernation API** keeps idle sockets open without billing time, so a lobby that's sitting waiting costs nothing.
- **Durable Object alarms** handle countdowns, round timers, rejoin windows and room cleanup.
- There are **no servers to run**, and it doesn't pause when nobody's playing (unlike Supabase's free tier).

---

## 2. Architecture

```
┌──────────────────────────── Android app (Flutter) ─────────────────────────────┐
│ UI: Forge Hall · Anvil (letter ring) · Mold (grid) · Lobby · Results · Profile │
│ Engine (pure Dart): puzzle model, board state, scoring, hint effects            │
│ Solo campaign: bundled puzzle packs, playable offline, sync queue               │
│ Firebase Auth SDK ── sign in ──► Firebase Authentication ── ID token (JWT)      │
│ HTTPS (REST)  ─┐                                                               │
│ WebSocket hub ─┼─► Cloudflare                                                   │
│ WebSocket room┘                                                                │
└────────────────────────────────────────────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────── Cloudflare ────────────────────────┐
│ Worker "api"   verifies Firebase JWT → REST routes → forwards WS upgrades       │
│                                                                                │
│ HubDO (one, global)       presence · friend online/offline · invites ·         │
│                           open-rooms directory                                 │
│ RoomDO (one per code)     lobby · co-op referee · versus referee · timers      │
│                           (state persisted in the DO's own SQLite storage)     │
│                                                                                │
│ D1 database               users · profiles · inventory · stats · friends ·     │
│                           puzzles (multiplayer + campaign answers) ·           │
│                           puzzle_seen · matches · xp_events                    │
└────────────────────────────────────────────────────────────────────────────────┘
```

A single HubDO is fine for a friend group. It can be split per user later if
that's ever needed.

---

## 3. Authentication

1. The app signs in with the Firebase Auth SDK (Google or email/password) and gets an **ID token**. This is a JWT signed by Google that lasts about 1 hour and refreshes automatically.
2. Every REST call sends `Authorization: Bearer <token>`.
3. The Worker verifies the token itself, without the Firebase Admin SDK:
   - The signature is RS256, checked against Google's published `securetoken` keys, cached according to their `Cache-Control`.
   - `aud` must be our Firebase project ID, `iss` must be `https://securetoken.google.com/<project-id>`, and `exp` and `iat` must be valid.
   - The token's `sub` is our user ID.
4. **WebSockets:** the token goes in the `Sec-WebSocket-Protocol` header, which keeps it out of URLs and logs. The Worker verifies it and then forwards the upgrade to the Durable Object, adding the verified user ID. The Durable Object stores the user ID on the socket with `serializeAttachment`, so it survives hibernation.
5. **Account deletion:**
   - The app calls `DELETE /v1/me`. The server removes all our data and leaves the user's name as "Deleted smith" in past match records.
   - The app then calls Firebase `currentUser.delete()`.

---

## 4. REST API (Worker)

All routes are under `/v1` and need a valid token, except `/v1/version`, `/v1/health` and `/v1/define/:word`. Friends, leaderboard and the hub return `403 setup_required` until the player has picked a username. The full request and response shapes are in `server/README.md`.

| Method & path | Purpose |
|---|---|
| `GET /version` | Latest app version and minimum supported version (for the update banner and blocking old clients) |
| `GET /health` | `{ok: true}` liveness check |
| `GET /define/:word` | What a word means, from an online dictionary (the Free Dictionary API, then Wiktionary), for words the app's offline lexicon lacks (never names: a word with only name senses is a 404). No token needed; cached in the Workers Cache API (definitions 30 days, misses a day). |
| `GET /me` | My profile, level, XP, hint stock, stats, campaign progress, Masterwork pieces and reminder hour |
| `POST /me/setup` | Set my username and avatar on first sign-in (profanity-checked, must be unique) |
| `POST /me/username` | Change my username: the same rules, at most once every 7 days (`429 too_soon` says when) |
| `DELETE /me` | Delete my account data |
| `POST /me/push-token` · `DELETE /me/push-token` | This phone's FCM token for notifications (`shared/push.md`) |
| `PUT /me/reminder` | The UTC hour of a daily reminder, or none (`shared/push.md`) |
| `GET /users/:username` | A player's public profile (any signed-in player, so you can look someone up before adding them) |
| `POST /solo/sync` | Upload a batch of offline solo results (see §8), campaign and Master Forge stages (`shared/master-forge.md`). Returns the updated profile and any rewards. |
| `GET /friends` | My friends (with the nicknames I gave them) and pending requests |
| `POST /friends/request` · `POST /friends/respond` · `DELETE /friends/:id` | Manage friends |
| `PUT /friends/:id/nickname` | My private nickname for a friend, or none; the app shows it instead of their username everywhere |
| `POST /rooms` | Create a room `{mode: coop \| vs}` and get back `{code}` |
| `GET /rooms/:code` | Room summary (mode, host, player count, state) |
| `POST /rooms/:code/video` | A LiveKit token for the room's optional video chat (§6, "Video chat") |
| `GET /daily?date=` · `POST /daily/complete` | The Daily Commission for today or a catch-up day (from the 1st of last month), its streak and total (`shared/daily.md`) |
| `GET /daily/calendar?month=` | This or last month's days done and trophies (`shared/daily.md`) |
| `GET /me/board` | The Forge Board: Daily Stoke, Work Orders, Weekly Trials and gifts (`shared/forge-board.md`) |
| `POST /me/stoke/claim` · `POST /me/orders/swap` · `POST /me/orders/claim` · `POST /me/trials/claim` · `POST /me/gifts/claim` | Forge Board claims, each answering `{profile, board, reward}` |
| `POST /friends/:id/gift` | Today's free Hammer Strike for a friend, with a notification (`shared/push.md`) |
| `GET /ws/hub` | WebSocket upgrade to HubDO |
| `GET /ws/room/:code` | WebSocket upgrade to that room's RoomDO |
| `GET /leaderboard` | Friends leaderboard (level, XP, VS series and rounds won, co-op rounds and MVPs) |

---

## 5. Real-time protocol

Messages are JSON over WebSocket, in the form `{ "op": "...", ...payload }`.
The plan is to define them once in `shared/protocol/` (as JSON Schema) and
generate both the Dart and the TypeScript types from it, so the app and server
can't drift apart. Until that lands (M3), `server/src/hub/protocol.ts` is the
definition of the hub messages. Two hub details:
- `{"op":"PING"}` gets an automatic `{"op":"PONG"}` without waking the Durable Object.
- Errors come back as `ERROR {code}`.

### Hub (HubDO)

| Op | Direction | Payload |
|---|---|---|
| `PRESENCE` | S→C | friend user ID and their status (`online`, `solo`, `in_room:<code>`, `offline`) |
| `SET_STATUS` | C→S | my status |
| `INVITE` | C→S / S→C | room code, mode, from whom |
| `OPEN_ROOMS` | S→C | my friends' rooms that are still open (code, mode, host, players/max) |

### Room (RoomDO)

Overview only. Co-op is specified exactly in
[`shared/room-protocol.md`](../shared/room-protocol.md); the VS-only parts
below are the M4 plan.

| Op | Direction | Payload |
|---|---|---|
| `WELCOME` | S→C | your user ID, protocol version, `serverNow` |
| `LOBBY` | S→C | players (ID, name, avatar, level, colour, ready, connected), host, mode, phase, heat, VS series length |
| `READY` | C→S | `{ready: bool}` |
| `CONFIG` | C→S (host) | VS series length (3 / 5 / 7 / 10) |
| `START` | C→S (host) | — |
| `ROUND_START` | S→C | round number, grid size, slots (x, y, direction, length; **never the words**), letters, pickup cells, `startsAt`, `endsAt`, `serverNow`. VS also gets the series tally and the list of players in this round (for sudden death). |
| `SUBMIT` | C→S | `{word, seq}` |
| `WORD_RESULT` | S→C (to the sender only) | `seq`, and one of `claimed` / `bonus` / `already` (with who found it) / `invalid` / `rate_limited` / `too_late` |
| `CLAIMED` | S→C (co-op, to everyone) | slot, word, player, points, scores, crossing slots it completed, pickup collected |
| `BONUS` | S→C (co-op, to everyone) | word, player, points, scores |
| `REVEAL` | S→C | VS: the letters for your own slot (to you only). Co-op: hinted letters (to everyone). |
| `HINT` | C→S (co-op) | `{type, cell?}` — the server checks your stock and spends one |
| `PROGRESS` | S→C (VS, to everyone) | player, letters filled, % of the mold filled. **No words.** |
| `ROUND_END` | S→C | Co-op: team result, stars, per-player breakdown, MVP, every answer, and per player XP, level-ups and hint rewards. VS: round winner, how they won (`finished` / `timeout` / `none`), series tally. |
| `SERIES_END` | S→C (VS) | podium, tiebreak details if a sudden-death round was needed, XP |
| `SNAPSHOT` | S→C | full room and round state, sent on join or rejoin |
| `EMOTE` | C→S→C | preset emote ID |
| `ERROR` | S→C | code (e.g. `not_host`, `wrong_phase`, `no_hint`). Joining a full room or one mid-round is refused before the WebSocket upgrade. |

### Clock
- The server sends `startsAt`, `endsAt` and `serverNow` as epoch milliseconds.
- The client works out `offset = serverNow − localNow` and shows the countdown from that.
- **Only the server ends a round**, using a Durable Object alarm. A word that arrives after `endsAt` is rejected.

---

## 6. RoomDO: the referee

### State machine

```
            host START (≥ min players)
  LOBBY ───────────────────────────────► COUNTDOWN (3 s)
    ▲                                         │ alarm
    │                                         ▼
    │                                       ROUND ──── mold complete (co-op: team; VS: first player)
    │                                         │   └─── alarm at endsAt (timer)
    │                                         ▼
    │                                   ROUND_RESULTS (co-op: until host acts; VS: 10 s)
    │   co-op "Forge Again" / host idle       │
    ├─────────────────────────────────────────┤
    │                     VS: series not decided ──► COUNTDOWN (next round)
    │                     VS: decided ──► SERIES_RESULTS ──► LOBBY
    │                     VS: tied after last round ──► COUNTDOWN (sudden death, tied players only)
    │
  idle 30 min / everyone gone ──► room closed (storage cleared)
```

### How it works
- **Ordering:** a Durable Object handles one message at a time, in arrival order. The first `SUBMIT` of a word that nobody has found wins. Nothing else is needed.
- **Persistence:** in-memory state is **lost when the DO hibernates**, so all room state lives in the DO's SQLite storage. That covers players, scores, the puzzle with its answers, claims, the series tally and deadlines. It's reloaded on wake, and a busy round stays in memory anyway.
- **Alarms:** a DO has a single alarm, so it's always set to the **nearest deadline** (countdown end, `endsAt`, a rejoin grace period, or idle cleanup). Each time the alarm fires, the DO checks every deadline that has passed.
- **Choosing a puzzle at the start of a round:** query D1 for the heat tier (and, for co-op, the size for the team), excluding puzzles any player has seen in the last 60 days. One is chosen at random.
- **Pickups in multiplayer:** the server picks pickup cells at random when the round starts. In VS everyone gets the same cells, because it's the same puzzle.
- **Checking a word:** normalise it to uppercase A–Z, check it's 3+ letters and can be made from the anvil's letters, then look it up in this puzzle's answer set and its bonus set (both precomputed by the generator, so no full dictionary is needed on the server).
- **Rate limit:** words use a token bucket of 4 per second **per player** (so a second socket doesn't double it); 10 invalid words within 5 seconds triggers a 3-second lockout. Other messages: a burst of 10, then 2 a second, per socket.
- **Writing results:** at the end of a round or series the server writes match records, XP, stats and hint changes to D1 in **one batch**, and the XP goes out in `ROUND_END` (retried by the alarm if the write fails).
- **Rejoining:** a socket that closes mid-round starts a 30-second grace period. A player who reconnects with the same user ID gets a `SNAPSHOT`.
- **Host handoff:** in the lobby, if the host leaves, the player who joined earliest becomes host and the heat is recalculated.

### Game rules as pure functions
All the rules are plain, side-effect-free TypeScript in `server/src/rules/`:
- the claim decision
- co-op scoring with hint deductions
- VS round resolution (`finished`, `timeout` by letters and then by time, or `none`)
- series clinch: `leaderWins > secondWins + roundsLeft`
- sudden-death player selection
- heat from level
- XP and level-ups
- hint grants

The Durable Object only wires these into the network and storage. That keeps
the rules unit-testable and easy to tweak.

### Video chat (optional)
Players can turn on video chat in a room (Settings, or the lobby's video
row). Each player then shows up as a small live video bubble in place of
their avatar, with voice.
- **Service:** [LiveKit Cloud](https://livekit.io), free Build plan
  (5,000 participant-minutes a month; a 4-player, 20-minute game uses 80).
  The app uses `livekit_client`; media goes between phones and LiveKit,
  never through the Worker or the RoomDO.
- **Access:** `POST /v1/rooms/:code/video` checks the caller holds a seat
  (`RoomDO.videoRoom`) and signs a 2-hour LiveKit token (HS256 with the
  project's API secret, `server/src/video/livekit.ts`): one room, camera and
  microphone only, identity = user ID.
- **Light on data:** 240×180 video at 15 fps without simulcast, adaptive
  streaming (each phone downloads only the size it shows) and dynacast.
  Roughly 400–500 MB an hour per player in a 5-player room; Wi-Fi is best.
- **Off by default.** The camera and mic switches are remembered. Nothing is
  recorded.
- **In the background:** voices go on both ways. While the mic is on,
  `GameAudioService` runs as a microphone foreground service ("Voice chat
  on"), started from the screen since Android 11+ cuts the mic off for
  background apps otherwise; a muted call gets a media-playback one off
  screen. The camera pauses until the game is back.
- **Setup:** the `LIVEKIT_URL`, `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`
  GitHub secrets, which the deploy workflow copies to the Worker. Without
  them the route answers `503 video_unavailable` and the app says so.

---

## 7. Data model (D1)

```sql
users        (id TEXT PK /*firebase uid*/, username TEXT UNIQUE, avatar TEXT, created_at INT, username_changed_at INT /*once a week*/)
profiles     (user_id PK, xp INT /*lifetime total*/, level INT, campaign_stage INT /*highest completed; the app's campaignStage = this + 1*/, scrap_bin INT, updated_at INT)
inventory    (user_id, item TEXT /*hammer|chisel|sparks*/, count INT, PRIMARY KEY(user_id, item))
stats        (user_id PK, words_forged INT, longest_word TEXT, solo_done INT,
              coop_rounds INT, coop_mvps INT, vs_series INT, vs_series_won INT, vs_rounds_won INT)
friends      (user_id, friend_id, status TEXT /*pending|accepted*/, created_at INT,
              nickname TEXT /*user_id's private name for friend_id*/, PRIMARY KEY(user_id, friend_id))
puzzles      (id TEXT PK, pool TEXT /*mp*/, heat INT, size INT, letters TEXT, data TEXT /*json*/)
campaign     (stage INT PK, puzzle_id TEXT, data TEXT /*json incl. answers, for validation*/)
puzzle_seen  (user_id, puzzle_id, seen_at INT, PRIMARY KEY(user_id, puzzle_id))
matches      (id TEXT PK, mode TEXT, code TEXT, started_at INT, ended_at INT, summary TEXT /*json*/)
match_players(match_id, user_id, placement INT, points INT, rounds_won INT, xp INT)
xp_events    (id INTEGER PK, user_id, source TEXT, amount INT, ref TEXT, created_at INT)
solo_results (user_id, stage INT, completed_at INT, PRIMARY KEY(user_id, stage))  -- dedupes syncs
pickup_seeds (user_id, seed TEXT, PRIMARY KEY(user_id, seed))  -- install ids used before sign-in (max 5)
daily_completions (user_id, date TEXT, completed_at INT, xp INT, late INT /*catch-up day: no streak*/, PRIMARY KEY(user_id, date))
push_tokens  (id INTEGER PK, token TEXT UNIQUE, user_id, registered_at INT)
work_orders  (user_id, period TEXT /*d:<date> | w:<week>*/, slot TEXT, kind TEXT, target INT, progress INT, letter TEXT, claimed INT,
              PRIMARY KEY(user_id, period, slot))
weekly_xp    (user_id, week TEXT /*YYYY-Www*/, xp INT, PRIMARY KEY(user_id, week))  -- kept by a trigger on xp_events
trial_claims (user_id, week TEXT, claimed_at INT, PRIMARY KEY(user_id, week))
gifts        (id INTEGER PK, from_user, to_user, sent_date TEXT, sent_at INT, claimed_at INT, UNIQUE(from_user, to_user, sent_date))
```

`profiles` also has `stoke_claims` and `stoke_last` (the Daily Stoke),
`masterwork_pieces` (blueprint pieces, `shared/masterworks.md`), and
`reminder_hour` and `reminder_last` (daily reminders, sent by an hourly
Cron Trigger, `shared/push.md`). Every XP
grant writes an `xp_events` row (`source`: `solo`, `daily`, `coop`, `vs`,
`board` or `masterwork`), and a trigger adds it to `weekly_xp` for the
Weekly Trials.

Migrations live in `server/migrations/` and are applied with `wrangler d1 migrations apply`.

---

## 8. Solo, offline play and sync

- The campaign's puzzles are **bundled in the app** (`app/assets/campaign/`), so solo play works with no connection.
- The phone keeps a **local profile cache** and a **sync queue** of results: `{stage, puzzleId, foundWords, bonusWords, hintsUsed, pickups, gilded, pickupSeed, durationMs, completedAt}`. `pickupSeed` is the id the pickups (and the gilded cell) were seeded with: the account id, or the install id (`install-<hex>`) for puzzles played before sign-in. The server accepts up to 5 install ids per account. `gilded` is `[<cell index>]` when the puzzle's gilded cell was collected, else `[]` (optional; `shared/masterworks.md`).
- `POST /solo/sync` uploads the queue whenever the app is online. Stages past the campaign's last, `N`, are the **Master Forge** (up to `10 × N`): stage `s` replays campaign puzzle `((s − N − 1) mod N) + 1` and is checked and counted like a campaign stage (`shared/master-forge.md`). For each entry, the server checks:
  - the stage hasn't already been counted (`solo_results` stops duplicates);
  - the found words match that puzzle's answers;
  - the bonus words are in its bonus set;
  - the time taken is plausible.

  It then grants XP, applies hint use and pickups (the inventory can't go below 0), counts a blueprint piece for a gilded cell it can reproduce (and grants a finished Masterwork's reward), handles level-ups and their rewards, adds the puzzles to the player's Work Orders, and returns the updated profile.
- **Campaign pickups** are worked out the same way on the phone and on the server, from `pickupSeed + ":" + puzzleId` (see `shared/pickups.md`). That decides whether a puzzle has a pickup, which cell it's in, and which type it is. The server can therefore check claimed pickups without them being stored in advance. **Gilded cells** work the same way, from `pickupSeed + ":" + puzzleId + ":gilded"`, stepping off the pickup cells (`shared/masterworks.md`).
- **Server wins conflicts.** For example, if the same account played offline on two phones, the server's numbers are kept after the sync.

---

## 9. App structure (Flutter)

- **State:** Riverpod for app-wide state (profile, settings, campaign, sound). Each puzzle screen owns a plain `ChangeNotifier` controller (`SoloController`), which keeps the animation-heavy game screen simple.
- **Navigation:** go_router.
- **Local storage:** `shared_preferences` with small JSON blobs (profile, settings, the puzzle in progress, the sync queue). That's enough for M1. A database (drift) can replace it if the sync queue or caches grow.
- **Networking (M2+):** `http` + `web_socket_channel`, behind small typed client classes.
- **Engine** (`lib/engine/`) is pure Dart with no Flutter imports. It covers the puzzle and board model, word validation, scoring and hint effects, and is fully unit-tested.
- **The anvil:** a `CustomPainter` plus a gesture detector.
  - Tiles are hit-tested with a radius check against each tile centre.
  - A word can't reuse a tile, and swiping back to the previous tile removes the last letter.
  - The trail is drawn as a gradient stroke with a glow blur.
- **The mold:** a grid of cells drawn from the puzzle's slot data, with fill and cool animations.
- **Effects:**
  - Sparks and embers use a small custom particle system.
  - Heat shimmer and molten glow use Flutter **fragment shaders** (`FragmentProgram`).
  - Haptics through `HapticFeedback`.
- **Audio:** `audioplayers` with a pool per sound effect. The tile "tink" uses eight pre-pitched files that rise in pitch with each letter. Ambience is a looping player, sounds mix with the user's own music rather than taking audio focus, and each has its own volume setting. Music plays only in the Forge Hall and solo play (rooms have the forge's ambience and sounds, and voice chat), and music and ambience pause whenever the game is off screen. A room's voice chat carries on off screen: `GameAudioService` runs as a foreground service for it (microphone with the mic on, media playback when just listening), since Android cuts the mic and silences background audio without one. Closing the game (backing out, or swiping it away) ends the process from `MainActivity.onDestroy`, so nothing outlives it.
- **Web build:** used **only** to take automated screenshots during development (there's no Android emulator in the build environment). The product is Android-only.
- **Real-time client:** reconnects automatically with backoff, re-sends `READY` and rebuilds the screen from the `SNAPSHOT`. Words are sent with increasing `seq` numbers, and results are matched back by `seq`.

---

## 10. Repository layout

```
WordSmith/
├─ app/                        Flutter app (Android)
│  ├─ lib/engine/              pure Dart rules: puzzle, board, validation, scoring, hints
│  ├─ lib/features/            solo/ coop/ versus/ lobby/ hall/ friends/ profile/ settings/
│  ├─ lib/ui/                  anvil/, mold/, effects/, theme/
│  ├─ lib/net/                 REST client, WebSocket client, generated protocol types
│  ├─ assets/                  images/, audio/, fonts/, shaders/, campaign/
│  └─ test/                    unit, widget, golden tests
├─ server/                     Cloudflare Worker + Durable Objects (TypeScript)
│  ├─ src/index.ts, router.ts  entry point and routing
│  ├─ src/auth/                Firebase token verification
│  ├─ src/account/             username rules, profanity filter
│  ├─ src/routes/              REST and WebSocket route handlers
│  ├─ src/hub/                 HubDO (presence, invites)
│  ├─ src/room/                RoomDO (lobby, co-op, versus) (M3)
│  ├─ src/rules/               pure game rules, incl. sync validation (unit-tested)
│  ├─ src/db/                  D1 queries
│  ├─ scripts/                 campaign.json → D1 seed SQL
│  ├─ migrations/              D1 SQL
│  ├─ test/
│  └─ wrangler.jsonc
├─ shared/protocol/            message schema → generated Dart + TS types
├─ tools/puzzlegen/            Python: word lists → campaign packs + multiplayer bank
├─ art/                        asset sources and render scripts (see ART_AND_AUDIO.md)
├─ docs/                       these plans
└─ .github/workflows/          CI
```

---

## 11. Testing

| Area | How it's tested |
|---|---|
| Dart engine | Unit tests: board state, word validation, scoring, hint effects, pickup seeding (which must match the server) |
| Flutter UI | Widget tests and **golden screenshots** of key screens; anvil gesture tests with simulated swipe paths |
| Server rules | Vitest unit tests for every pure rule: claims, scoring, VS resolution, clinch, sudden death, XP and level-ups, hint grants |
| Worker + Durable Objects + D1 | `@cloudflare/vitest-plugin` runs the real Workers runtime (workerd) locally. Includes **scripted bot clients**, e.g. 4 bots sending the same word in the same instant (exactly one gets it) and a 5-player best-of-3 with a timed-out round and a sudden-death round. |
| Puzzle generator | Every word is reachable from the letters, the crossword is connected with no stray adjacent letters, it fits within 10×10, a word uses all the letters, the output is the same every run for the same seed, and no blocked words appear |
| CI (GitHub Actions) | On every PR: `flutter analyze` + tests, server typecheck + tests, generator tests. When a release is tagged: build a signed APK and attach it to a GitHub Release. When `server/` changes on the default branch: deploy the Worker. |

Local development uses `wrangler dev`, which runs the Worker, Durable Objects
and D1 locally with no Docker. The app is pointed at it with a build flag.

---

## 12. Free-tier budget

These are the Cloudflare Workers Free plan limits as of October 2026. They
reset every day at 00:00 UTC.

| Resource | Free limit | What it means for us |
|---|---|---|
| Durable Object time | 13,000 GB-s/day | Each DO is billed at 128 MB while it's awake, so this is about **28 hours of live room time a day** across all rooms combined. That's roughly 500 three-minute co-op rounds or about 140 best-of-5 VS series a day. Lobbies waiting idle hibernate and cost nothing. |
| Durable Object requests | 100,000/day | Incoming WebSocket messages count at 20 messages per request, so it's nowhere near a limit for us. |
| Worker requests | 100,000/day | Logins, profile fetches and syncs: far below the limit for a friend group. |
| D1 | 5M rows read/day, 100k rows written/day, 5 GB | Far below the limit. |
| Firebase Auth | Free on Spark (about 50k monthly users) | Far below the limit. |
| LiveKit Cloud (video chat) | 5,000 participant-minutes a month | About 60 four-player, 20-minute games with video on. Past it, video stops until the next month; the game itself is unaffected. |

If a free limit is hit, further operations **fail until the next reset**
rather than charging money. The server will return a clear
"forge is resting, try again later" error. Moving to the $5/month plan
removes the daily caps.

---

## 13. Versioning

- `GET /v1/version` returns `{latest, minSupported, apk}`.
- If the app is older than `latest`, it shows an **update banner**. On Android its **Update now** button downloads `apk` (the GitHub Release's APK) with a progress bar and opens Android's installer; Settings → Version checks again on demand.
- If it's older than `minSupported`, it **blocks multiplayer** until the player updates. This keeps the protocol in step across all friends' phones.
- The protocol has a version number, and rooms refuse clients on a different major version.
