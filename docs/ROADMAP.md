# Wordsmith — Roadmap

> Each milestone ends with something you and your friends can actually
> install and try.
>
> **Status (2026-10-17):**
> - **M0:** done.
> - **M1:** done. Builds are signed with the permanent release key and shared as APKs (GitHub Releases).
> - **M2:** live. The server runs at https://wordsmith-api.wordsmith-forge.workers.dev and deploys from GitHub Actions.
> - **M3:** live. A two-player round passed against the real server; waiting on a real-phones test.
> - **M4:** live. Versus app and server are built; a best-of-3 series passed against the real server (podium, XP, stats). Waiting on a real-phones test.
> - **M5:** mostly done.
>   - Done: the Daily Commission (live, tested), scenes for all nine chapters, rank badges, music and match sounds, the level-up flourish after matches, the update banner, multiplayer records on the profile, Join-a-friend, the 130%-text accessibility pass, and a code-review pass (rejoining your own room, phase races, offline sign-in, daily rollover).
>   - Still open: invite notifications are built and live on the server; they start sending once the owner adds the `FCM_SERVICE_ACCOUNT` secret (DISTRIBUTION.md §5).
> - **Video chat (extra):** live, and tested on two phones.
> - **M6 (genre extras):** built: word meanings, Daily Stoke, Work Orders, Weekly Trials, gifts, the commission calendar and trophies, Smith's Lore, gilded cells and the Armory, chapter maps with replays, the Master Forge, daily reminders, the first-puzzle guide and a left-handed layout (DESIGN.md §10).

---

## M0 — Foundation
- Create the repo layout from [TECH.md §10](TECH.md#10-repository-layout):
  - `app/` (Flutter, Android only)
  - `server/` (Worker + Durable Objects + D1)
  - `shared/protocol/`
  - `tools/puzzlegen/`
  - `art/`
- Set up CI on every PR: Flutter analyze and tests, server typecheck and tests, generator tests. CI also builds a debug APK.
- Server runs locally with `wrangler dev`, including D1 with the first migration.
- Theme tokens (the palette), fonts and placeholder art.

**Done when** CI is green, a debug APK installs on a phone and shows a
placeholder Forge Hall, and the Worker responds locally.

## M1 — Solo Forge (the base game)
- **Puzzle generator v1:**
  - word lists and blocklist
  - finding all words in the letters
  - crossword layout
  - difficulty scoring and heat tiers
  - the 9-chapter campaign (about 600 puzzles)
  - a separate multiplayer bank
  - checks on every puzzle
- **Engine:** puzzle and board model, word validation, bonus words and the Scrap Bin, hint effects, pickup seeding.
- **Gameplay UI:**
  - the anvil (swipe, trail, preview, Turn)
  - the mold (cells, pour and cool)
  - the full set of reactions (valid, already found, bonus, invalid)
  - Hammer Strike, Chisel and Spark Shower
  - the "Forged!" flow, chapter map and settings (sound, music, haptics)
- **Local progress:** hint stock (starts with 3 Hammer Strikes), pickups, Scrap Bin, and unlocks by local level (moved to the server in M2).
- **Art v1:**
  - anvil and tiles
  - mold cells
  - Tin and Copper backgrounds
  - icon set
  - core sounds (tile tink, clang, invalid, bonus, Forged!)
- **Distribution:** release signing, the release pipeline (GitHub Releases), the limited distribution account, and the **first build sent to friends**.

**Done when** friends can install the APK and play the
campaign offline, with all hint types, pickups and the Scrap Bin working.

## M2 — Accounts and progression
- Firebase sign-in (Google, email), username and avatar setup.
- Worker REST API, Firebase token checking, D1 schema.
- **Server-side** XP, levels, ranks and level-up rewards (hint unlocks and grants).
- Solo sync: an offline queue, checked by the server.
- Profile screen with stats, and account deletion.
- Friends: add by username, accept, remove. Live online status through HubDO.
- Version check and update banner.

**Done when** your progress follows you to a new phone and reinstalls, and
friends can see each other online.

## M3 — Co-op ("The Guild Forge")
- RoomDO: room codes, lobby, ready checks, host start, host handoff, heat from the host's level.
- Multiplayer puzzle bank in D1, picked by heat and team size, skipping recently played puzzles.
- Co-op rules:
  - shared mold, first to claim wins
  - player colours and initials, live feed
  - timer
  - hints from each player's own stock, with point deductions
  - pickups
  - results with stars and MVP
  - Forge Again
- Rejoin with snapshots, rate limiting, invites and the open-rooms list.

**Done when** four phones can finish a co-op round together, the
"same word at the same instant" bot test passes, and XP lands on everyone's
profile.

## M4 — Versus ("Anvil Clash")
- VS rooms with a series length setting (3 / 5 / 7 / 10).
- Race rounds: first to finish wins, otherwise the most letters at the timer.
- Live opponent progress strip.
- Early clinch, sudden-death tiebreak, podium and XP.
- Pickups collected in VS are saved for later.

**Done when** a 5-player best-of-3, including a timed-out round and a
sudden-death round, plays end to end (bot-tested and with real phones).

## M5 — Polish
- All 9 chapter backgrounds and the Forge Hall hero art.
- Full sound set, music and ambience; haptics tuning.
- "Forged!" and level-up animations, rank badges, avatars.
- Credits screen (built from `art/CREDITS.md`) and a friends leaderboard.
- **Daily Commission** puzzle.
- Push notifications for invites (Firebase Cloud Messaging, free).
- Accessibility pass: colour-blind check, text scaling, reduced-motion option.

**Done when** it looks, sounds and feels finished on friends' phones.

## Later / maybe
- iOS or a browser version for iPhone friends.
- Cosmetics (anvil skins, spark colours) as level rewards.
- Quick Match and the Play Store, only if the game ever goes public.
