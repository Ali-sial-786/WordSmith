# Wordsmith — Design Proposal

> **Status:** Draft for review. Nothing is built yet. This document is meant to
> settle the platform and the rules of each mode before any code is written.
> Sections marked **(decision)** are the ones that need sign-off.

---

## 1. The game in one paragraph

Wordsmith is a Wordscapes / Word Trails–style word puzzle for Android: a ring
of letters sits at the bottom of the screen, you swipe across them to form
words, and each valid word fills its slot in a crossword grid above. Valid
words that aren't in the grid are bonus words. On top of that solo core,
Wordsmith adds online accounts with XP and levels, a **Versus** mode for up to
5 players, and a **Co-op** mode where up to 4 players race the clock on one
shared puzzle. The theme is metalwork: you **forge** words on an **anvil** and
**cast** them into a **mold**.

### What "as close as possible" means legally

Game mechanics can't be copyrighted, so the swipe wheel, crossword grid,
bonus words, shuffle and hints are fine to copy. Art, sounds, level data, names
and a screen-for-screen copy of the layout ("trade dress") are not; *Tetris v.
Xio* (2012) is the usual warning. So we copy the **mechanics and feel**, and
build our own art, sounds and puzzles. The smithing theme takes care of most of
that.

---

## 2. Platform recommendation (decision)

| Layer | Recommendation | Why |
|---|---|---|
| Android client | **Flutter** (Dart) | Good fit for a UI-heavy 2D game (custom-painted wheel, grid animations, particle sparks). One codebase also gives us iOS later at no extra cost. It also builds for web, so UI can be checked in a browser during development. |
| Game backend | **Nakama** (open-source game server by Heroic Labs) | Has accounts, device/Google/email login, friends, parties, matchmaking, **server-authoritative real-time matches**, leaderboards and storage built in. There's an official Dart/Flutter client. |
| Server game logic | Nakama **TypeScript runtime** | The VS and Co-op rules run on the server. Clients only send guesses. |
| Database | **PostgreSQL** (used by Nakama) | Accounts, profiles/XP, leaderboards. |
| Hosting (v1) | One small VPS running Docker Compose (Nakama + Postgres + Caddy for TLS) | About $5–20/month to start. Can move to managed Postgres or Heroic Cloud later. |
| Puzzle generation | Offline generator script in `tools/puzzlegen` | Builds a puzzle bank from openly licensed word lists. Puzzles are checked before release instead of generated live. |

### Why a real game server and not just a database

Co-op hinges on **"whoever enters the word first gets the point."** That needs
one referee that sees every guess in the order it arrived. In a Nakama
authoritative match, the match loop is that referee:

- Guesses are processed in the order they arrive. There's one source of truth, so two players can't both get credit for the same word.
- The server holds the answers. Clients get the grid *shape* and the letters, not the words, so a modded client can't read the solutions.
- The server owns the clock, so the round ends at the same moment for everyone.
- The "host" is just whoever configured the lobby. The game itself runs on the server, so it carries on if the host drops.

### Alternatives considered

| Option | Verdict |
|---|---|
| **Supabase** (Postgres + Auth + Realtime) | **Runner-up.** Fully managed, with an official Flutter SDK. "First claim wins" works well as an atomic insert with a unique constraint. Round lifecycle (countdowns, ending on the timer, VS rounds) has no game loop, so it ends up spread across SQL functions and cron. Pick this if you'd rather not run any server at all. |
| **Firebase** (Auth + Firestore/RTDB + Cloud Functions) | Not recommended for the multiplayer part. There's no authoritative game loop, every guess would be a Cloud Function call (latency and cold starts), and hiding answers from clients is awkward. Firebase *Auth* alone would be fine. |
| **Custom Node/TypeScript WebSocket server** | Works, but we'd be building accounts, friends, matchmaking, parties and leaderboards ourselves, all of which Nakama already has. |
| **Google Play Games Services multiplayer** | Not an option. Google shut down real-time multiplayer in 2020. (Play Games sign-in and achievements can still be added later.) |
| **Unity + Photon/PlayFab** | Too heavy for a 2D word game. Per-CCU pricing, larger APK, slower iteration. |
| **Native Kotlin + Jetpack Compose** | A good Android-only option. Flutter wins because iOS comes for free and UI can be checked in a browser. |

---

## 3. Architecture

```
 ┌──────────────────────── Android app (Flutter) ────────────────────────┐
 │  UI: Anvil (letter wheel) · Mold (grid) · Lobby · Results · Profile    │
 │  Game engine (pure Dart): puzzle model, board state, local validation  │
 │  Solo campaign: bundled puzzle packs, works offline, syncs when online │
 │  Net: nakama Dart client ── HTTPS (auth, RPC) + WebSocket (matches)    │
 └──────────────────────────────────┬─────────────────────────────────────┘
                                    │ TLS (Caddy)
 ┌──────────────────────────────────▼─────────────────────────────────────┐
 │  Nakama server                                                          │
 │   • Auth: guest(device) / Google / email, account linking               │
 │   • RPCs: profile, solo-level-complete (grants XP), create/join room    │
 │   • Matchmaker: VS quick match (2–5 players, level brackets)            │
 │   • Authoritative matches (TypeScript):  coop_match · vs_match          │
 │   • Puzzle bank loaded in memory at startup (JSON, a few MB)            │
 │   • Leaderboards, friends, in-app notifications (invites)               │
 └──────────────────────────────────┬─────────────────────────────────────┘
                                    │
                             ┌──────▼──────┐
                             │ PostgreSQL  │  accounts, profiles/XP, stats,
                             └─────────────┘  leaderboards, match history
```

---

## 4. Core gameplay (solo): Wordscapes mechanics, smithing theme

| Wordscapes / Word Trails | Wordsmith | Behaviour |
|---|---|---|
| Letter wheel | **The Anvil** | 4–8 hot-metal letter tiles in a ring on the anvil face. Swipe through tiles; a molten trail follows your finger; release to submit. |
| Crossword grid | **The Mold** | Empty slots. A found word pours in as glowing metal and cools to that metal's colour. |
| Bonus / extra words | **Scrap Bin** | Valid non-grid words go to the bin. When it's full, it's smelted into Ingots. |
| Coins | **Ingots** | Currency for hints. Earned from levels, the Scrap Bin, and daily rewards. |
| Shuffle | **Turn** | Rotates and reshuffles the tiles. Free. |
| Hint (reveal 1 letter) | **Hammer Strike** | Reveals one random letter. |
| Targeted hint | **Chisel** | Reveals the letter in the cell you tap. |
| Multi-reveal (fireworks) | **Spark Shower** | Reveals 5 random letters. |
| Level complete | **"Forged!"** | Hammer clang, spark burst, Ingots and XP. |
| Level packs / scenes | **Metals** | Chapters: Tin → Copper → Bronze → Iron → Steel → Silver → Gold → Damascus → Starmetal, each with its own forge scene (village smithy, dwarven hall, foundry, volcano forge…). |

Other details to match the genre: a short wiggle and buzz on invalid words, a
grey flash when a word is already found, haptics on each tile, and a running
preview of the word being built above the anvil.

Daily Commission (daily puzzle), cosmetics (anvil skins, spark colours) and
the shop come after the base game.

---

## 5. Accounts and progression

### Sign-in
- **Guest** (device ID) gets you playing instantly. It can later be **linked**
  to **Google** or **email/password** without losing progress.
- Unique username, chosen at first multiplayer entry, with a profanity filter.
- Account deletion in the app **and** on a web page. Google Play requires both
  for any app that lets users create accounts.

### XP, Smith Level, ranks
"Level" in this doc means the **Smith Level**. It's earned from XP in **every**
mode. It is separate from the solo campaign's puzzle number. All XP is granted
**on the server** so it can't be edited client-side.

| Source | XP (starting values, to be tuned) |
|---|---|
| Solo puzzle forged | 10 + 1 per bonus word (capped) |
| Co-op round | 20 participation + 1 per 10 points you scored + 20 if the team completes the mold + 10 for MVP |
| VS series | 5 per round played + 10 per round won + 30 for winning the series (so longer series earn more) |

XP needed for the next level: `50 + 10 × level` (Lv1→2 = 60 XP, Lv10→11 =
150, Lv50→51 = 550).

| Rank | Smith Level |
|---|---|
| Apprentice | 1–9 |
| Journeyman | 10–24 |
| Smith | 25–49 |
| Master Smith | 50–79 |
| Grandmaster | 80–119 |
| Legend | 120+ |

Profile stats: words forged, solo puzzles, co-op rounds, MVPs, VS matches,
VS wins, longest word.

---

## 6. Difficulty model

Each puzzle in the bank has a **tier**. Co-op picks the tier from the **host's
Smith Level**. VS picks it from the **median level** of the lobby.

| Tier | Level | Anvil letters | Grid words | Word pool | Co-op timer |
|---|---|---|---|---|---|
| Tin | 1–5 | 4 | 3–5 | very common | 3:00 |
| Copper | 6–15 | 5 | 5–7 | common | 3:00 |
| Bronze | 16–30 | 6 | 7–10 | common | 3:30 |
| Iron | 31–50 | 6–7 | 9–12 | + less common | 3:30 |
| Steel | 51–80 | 7 | 11–15 | + uncommon | 4:00 |
| Damascus | 81+ | 7–8 | 14–20 | uncommon, longer words | 4:00 |

**Co-op team-size scaling:** a solo-sized puzzle is too small for 4 people, so
Co-op picks a puzzle from the host's tier with about **+2 grid words per player
beyond the first**. Each puzzle in the bank records its size so this is a
simple lookup.

---

## 7. Puzzles and dictionary

- **Word lists:** openly licensed lists only. **SCOWL** (permissive licence)
  sorted by size level as a "how common is this word" scale, and **ENABLE**
  (public domain) for accepting bonus words. A blocklist keeps offensive words
  out of grids. They are still accepted quietly as bonus words, or rejected,
  depending on the filter setting.
- **Answers vs bonus:** grid answers come only from common words (SCOWL ≤ 35
  or so). Bonus words come from the bigger list, so obscure-but-real words
  still count.
- **Generator** (`tools/puzzlegen`):
  1. Pick a seed word of N letters (N = 4–8).
  2. Find every sub-anagram of 3+ letters in the answer pool and the bonus pool.
  3. Choose K answer words and lay them out as an interlocking crossword
     (greedy placement with backtracking; maximise crossings; keep it under
     about 10×10 so it fits a phone).
  4. Score difficulty (letters, word count, word rarity, longest word) and
     assign a tier.
  5. Emit JSON.
- **Two separate pools:** a fixed, ordered **campaign** sequence bundled in the
  app, and a **multiplayer bank** that only the server has. That way campaign
  answers can't be memorised for multiplayer, and multiplayer answers never
  ship in the APK.
- The server avoids giving a player a multiplayer puzzle they've seen
  recently.

Puzzle JSON (sketch):

```json
{
  "id": "mp-iron-00412",
  "tier": "iron",
  "letters": "RDATEH",
  "grid": { "w": 7, "h": 6 },
  "words": [
    { "word": "THREAD", "x": 0, "y": 2, "dir": "across" },
    { "word": "HEART",  "x": 1, "y": 0, "dir": "down" }
  ],
  "bonus": ["DEARTH", "HATED", "TREAD"],
  "difficulty": 0.47
}
```

For multiplayer, clients receive only `grid`, the slot positions/lengths and
`letters`. The words and the bonus list stay on the server.

---

## 8. Co-op mode: "The Guild Forge" (up to 4 players)

One shared mold, one timer, everyone forging together.

### Flow
1. **Host** taps *Co-op → Light the Forge*. The server creates a match and returns a **6-character room code**.
2. Friends join with the code or an **invite** (in-app notification to friends).
3. **Lobby:** player list with levels and ready checks, plus a difficulty banner ("Iron tier — set by host Ali, Lv 34"). Only the host can start (2–4 players; solo co-op is allowed for testing).
4. **Countdown 3-2-1**, then the round begins. Everyone sees the **same mold and the same letters**. Each player can Turn (shuffle) their own anvil.
5. **Forging:** a player submits a word and the server rules on it:
   - **Unclaimed grid word:** it's claimed by that player. Everyone sees it fill in **that player's metal colour** (copper / gold / silver / steel-blue), and a feed line appears: "Ali forged THREAD +60".
   - **Already claimed:** only the sender sees "Already forged by Sam".
   - **Bonus word, unclaimed:** small points to the finder; it goes into the team's Scrap Bin.
   - **Invalid:** only the sender sees the wiggle and buzz.
6. **Round ends** when the mold is complete (win) or the timer hits 0.
7. **Results:** team score, % of the mold filled, stars (3★ = finished with ≥ 50% time left, 2★ = finished, 1★ = ≥ 75% filled), then each player's points, words and longest word, and the **MVP / "Master of the Forge"** banner for the top scorer (ties go to whoever reached that score first).
8. The host can **Forge Again** (new puzzle, same crew) or disband.

### Scoring (starting values)
- Grid word: **10 points per letter** (THREAD = 60).
- Bonus word: **3 points per letter**.

### Hints in Co-op
The team shares **3 Hammer Strikes per round**, and any player can use one.
Revealed letters score for no one. A word completed entirely by hints scores
0.

### Edge cases
- **Two players enter the same word at almost the same time:** the server's match loop handles them in arrival order. First one wins, and the second gets "Already forged by …".
- **Host disconnects in the lobby:** host passes to the player who has been in the lobby longest. Their level then sets the difficulty, and the banner updates.
- **Host disconnects mid-round:** the round continues. The server runs it, not the host's phone.
- **Anyone disconnects:** 30 seconds to rejoin with points kept. The server sends a full snapshot on rejoin.

---

## 9. Versus mode: "Anvil Clash" (2–5 players)

### Rounds: a race to finish the mold
Every player gets the **same puzzle**, each on **their own mold**. Nobody can
block or steal anyone else's words.

- **The first player to fill their whole mold wins the round.** The round ends for everyone at that moment ("Sam forged it first!") and all boards freeze.
- **If the timer runs out first, the round ends.** *Proposed default (decision):* the player with the most of their mold filled wins the round. Fill is counted in letters, and a tie goes to whoever reached that count first. The other option is that a timed-out round has no winner.
- **Round timer:** 2:30 to start with, tuned per tier later.
- **No hints in VS.** Turn (shuffle) is allowed. Bonus words are still accepted and still feed your Scrap Bin, but they don't help you win the round.
- Top strip: each opponent's avatar, their round-win pips and a live **progress bar** showing how full their mold is. You never see their words.

### Series: best of 3, 5, 7 or 10
A match is a **series** of rounds. **Round wins add up across the series.**

- Each round uses a new puzzle from the same tier, set from the lobby's median level.
- **The series ends as soon as someone can't be caught**, i.e. their round wins are more than anyone else's round wins plus the rounds left. Otherwise it runs to the full length.
  - With 2 players: best of 3 = first to 2, best of 5 = first to 3, best of 7 = first to 4, best of 10 = first to 6.
  - With 3–5 players it can also end early, but it often runs the full length.
- **Ties after the last round** can happen in best of 10 (5–5) or with 3+ players (e.g. 1–1–1 in a best of 3). *Proposed default (decision):* a **sudden-death round** between the tied players only, with everyone else watching live. The other option is to break ties on total letters forged across the series.
- **Between rounds:** 10-second standings showing the round winner, the series tally and "Round 4 of up to 7".
- **End of series:** podium ranked by round wins, then XP.

### Getting into a match
- **Private Clash:** room code or friend invite, exactly like Co-op. The creator picks the series length (3 / 5 / 7 / 10) in the lobby and starts once 2–5 players are in.
- **Quick Match:** Nakama matchmaker ticket with `min 2, max 5`, grouped by level bracket. It waits up to about 20 seconds to fill toward 5, then starts with whoever's there (minimum 2). *Proposed default (decision):* Quick Match is **best of 3 only** at launch, so a small player base isn't split across four queues. Longer series are available in Private Clash, and they can be added to Quick Match once there are enough players.

### Disconnects
- A dropped player's mold freezes. They can rejoin the current round within 30 seconds and carry on.
- If they don't come back, they simply can't win any more rounds, and the series continues without them.
- If only one player is left, they win the series by forfeit.

---

## 10. How online play works

### Match lifecycle (both modes)

```
LOBBY ──host Start──▶ COUNTDOWN (3s) ──▶ ROUND (timer) ──▶ ROUND_RESULTS
  ▲                                                          │
  └──────── Forge Again / next VS round ◀────────────────────┘
                     (VS once the series is clinched or played out) ─▶ SERIES_RESULTS ─▶ XP granted

VS round ends: first player to complete their mold  OR  timer reaches 0
```

- Each mode is a Nakama **authoritative match** running at **10 ticks/second**, so the most a guess waits for the next tick is 100 ms.
- **Clock:** the server sends `endsAt` (server time) plus `serverNow`. Clients work out their clock offset and show the countdown. Only the server ends rounds.
- **Room codes:** a short code maps to a match ID. Joining is "RPC `room_lookup(code)` → socket `joinMatch(matchId)`".

### Messages (op codes)

| Op | Direction | Payload |
|---|---|---|
| `LOBBY_STATE` | S→C | players, levels, ready flags, host, tier, VS series length |
| `READY` / `START` | C→S | (host only for START) |
| `ROUND_START` | S→C | round #, grid shape, slots, letters, `startsAt`, `endsAt`; VS: series tally, which players are in it (sudden death) |
| `SUBMIT` | C→S | `{ word, seq }` |
| `WORD_RESULT` | S→C (sender) | `accepted` / `bonus` / `already` (+by whom) / `invalid` |
| `WORD_CLAIMED` | S→C (all, co-op) | word, slot, player, points |
| `PROGRESS` | S→C (all, VS) | player, % filled, score (no words) |
| `HINT_USED` | C→S / S→C | co-op team hint, revealed cell |
| `SNAPSHOT` | S→C | full state on join/rejoin |
| `ROUND_END` | S→C | co-op: results and MVP; VS: round winner, how it was won (finished / timer), series tally |
| `SERIES_END` / `MATCH_END` | S→C | VS podium / co-op final; XP awarded |
| `EMOTE` | C→S→C | preset reactions ("Nice strike!", 🔥) |

### Fairness and anti-cheat
- **Multiplayer answers never leave the server.**
- **Rate limit:** about 4 guesses per second per player. Spamming invalid guesses triggers a short lockout. This stops brute-forcing every letter combination.
- **XP, levels, Ingots and stats are written only by the server.** Clients can read their profile but can't write it.
- **Solo campaign** keeps working offline (answers are local, like Wordscapes). When it syncs, the server checks that the reported puzzle ID and found words are valid, and the time is plausible, before granting XP.

### Safety
- **No free-text chat in v1.** Preset emotes only, which avoids a moderation workload. Usernames go through a profanity filter, and players can **block** and **report**.
- Target audience **13+** for v1. Targeting under-13s puts us in Google's Families programme, which has much stricter rules.

---

## 11. Data model (Nakama)

| Where | What |
|---|---|
| Nakama `users` | username, display name, avatar, linked logins |
| Storage `profile/main` (owner read-only, server write) | `xp`, `level`, `ingots`, `campaignStage`, `scrapBin`, `stats{…}`, `recentPuzzleIds` |
| Storage `history/*` | last N match summaries |
| Leaderboards | `level_alltime`, `vs_wins_weekly`, `coop_score_weekly` |
| Server memory | multiplayer puzzle bank (loaded from JSON at startup), room-code → match-ID index |

---

## 12. Repository layout (planned)

```
WordSmith/
├─ app/                  Flutter Android app
│  ├─ lib/engine/        pure-Dart puzzle/board logic (unit tested)
│  ├─ lib/ui/            anvil, mold, screens, effects
│  ├─ lib/net/           Nakama client wrapper, typed messages
│  └─ assets/campaign/   bundled campaign puzzle packs
├─ server/               Nakama TypeScript modules
│  ├─ src/matches/       coop.ts, vs.ts (rules kept as pure functions → unit tested)
│  ├─ src/rpc/           profile, rooms, solo completion
│  └─ data/              multiplayer puzzle bank (server-only)
├─ tools/puzzlegen/      word lists → campaign packs + multiplayer bank
├─ deploy/               docker-compose (nakama + postgres + caddy), backups
├─ docs/                 this document
└─ .github/workflows/    CI: analyze/test app, test server, build APK
```

---

## 13. Hosting and running costs

- **Dev:** `docker compose up` runs Postgres and Nakama locally. The app points at it.
- **Production v1:** one VPS (2 vCPU / 4 GB) with Docker Compose (Postgres + Nakama + Caddy auto-TLS) and a daily `pg_dump` backup. That's about **$5–20/month** plus a domain.
- **Scale:** one Nakama node handles far more than a launch-sized player base for a low-message game like this. Multi-node clustering is a paid Heroic Labs feature (Heroic Cloud / Enterprise), so it's the path if we ever need it.
- **Google Play:** $25 one-time developer fee.

---

## 14. Google Play launch requirements to plan for

- **Closed testing:** new *personal* developer accounts must run a closed test with **at least 12 testers opted in for 14 consecutive days** before production access. Recruit testers early.
- In-app **and** web **account deletion**.
- Privacy policy URL and Data safety form. Content rating questionnaire.
- Release signing (Play App Signing) and the current target API level.

---

## 15. Milestones

| # | Milestone | Result |
|---|---|---|
| M0 | Foundation | Repo skeleton, Flutter app shell, local Nakama stack, CI building a debug APK |
| M1 | **Solo Forge (the base)** | Full Wordscapes-style loop offline: anvil swipe, mold, bonus words / Scrap Bin, Turn, Hammer Strike / Chisel / Spark Shower, campaign chapters, generated puzzles |
| M2 | Accounts and progression | Guest / Google / email sign-in, server-side XP and Smith Level, ranks, cloud save, profile |
| M3 | Co-op | Room codes, lobby, authoritative co-op match, live claims in player colours, results and MVP |
| M4 | Versus | Quick Match and private rooms, race rounds, best-of-3/5/7/10 series with early clinch and tiebreak, progress strip, podium |
| M5 | Polish | Smithing art pass, sounds, haptics, friends and invites, leaderboards, Daily Commission |
| M6 | Launch prep | Account deletion, privacy policy, closed test (12 testers × 14 days), store listing |

---

## 16. Open questions

1. **Platform:** OK with Flutter + Nakama on a small VPS you pay for (about $5–20/month)? Or would you rather have a fully managed backend (Supabase) and accept a clunkier round lifecycle?
2. **Versus details** (format settled: race on separate molds, first to finish wins the round, best of 3/5/7/10 series):
   - When the timer runs out, does the most-filled mold win the round (proposed), or does nobody win it?
   - Tie after the last round: sudden-death round (proposed), or most letters forged across the series?
   - Quick Match best of 3 only at launch (proposed), or let players choose any length?
3. **"Level":** an XP-based Smith Level from all modes (proposed), or the solo campaign puzzle number like Wordscapes' "Level 1,203"?
4. **Hints in multiplayer:** none in VS, and 3 shared Hammer Strikes in Co-op (proposed)?
5. **Sign-in:** guest + Google + email (proposed). Do we also need Facebook or others?
6. **Language:** English only for v1?
7. **Art:** v1 will use code-drawn metal (gradients, shaders, spark particles) and placeholder sounds. Is there an artist for illustrated forge backgrounds later, or should we plan for generated or stock assets?
