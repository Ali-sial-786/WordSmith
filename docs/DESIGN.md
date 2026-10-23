# Wordsmith — Game Design

> Status: **Built and playable.** Decisions are logged in
> [DECISIONS.md](DECISIONS.md). For the tech side see [TECH.md](TECH.md), for
> visuals and sound see [ART_AND_AUDIO.md](ART_AND_AUDIO.md), and for getting
> it onto friends' phones see [DISTRIBUTION.md](DISTRIBUTION.md).

---

## 1. Overview

Wordsmith is a crossword-style word puzzle for Android and the browser. A ring
of letters sits at the bottom of the screen, you swipe across them to build
words, and each valid word fills its slot in a crossword grid above. Valid
words that aren't in the grid are bonus words.

On top of that solo game, Wordsmith adds:

- **Accounts and levels.** XP is earned in every mode, and your Smith Level rises with it.
- **Co-op (2–4 players):** one shared, timed puzzle. Whoever enters a word first gets the points, and the host sets the difficulty (by default, from their level).
- **Versus (2–5 players):** everyone gets the same puzzle and races on their own copy. The first to finish wins the round, and matches are best-of-3/5/7/10 series.
- **Team Versus (2–6 players, two even teams):** Versus in two teams, Copper and Cobalt. A round goes to a team: on letters added up, or to whoever finishes first (§9.5).

The theme is blacksmithing. You **forge** words on the **anvil**, and they're
**cast** into the **mold**.

### Scope for v1
- **Android only.** Flutter keeps iOS open for later.
- **Just you and your friends.** It's shared as an APK, not through the Play Store, and there are no strangers or matchmaking.
- **English only.**
- **Free to run.** There are no ads, no purchases and no currency.

### Design pillars
1. **Easy to pick up.** The swipe, the grid, bonus words, shuffle and hints work the way word-puzzle players expect.
2. **Feels like a forge.** Every action has weight: clangs, sparks, glowing metal cooling down.
3. **Friends first.** Rooms take seconds to set up, every player's contribution is visible in co-op, and versus results are clear and fair.

---

## 2. Solo gameplay

### 2.1 Mechanics and how they map to the theme

| Common word-puzzle feature | Wordsmith | Behaviour |
|---|---|---|
| Letter wheel | **The Anvil** | 4–8 letter tiles sit in a ring on the anvil face. Swipe through them, and a molten trail follows your finger. Release to submit. |
| Crossword grid | **The Mold** | Empty slots. A found word pours in as glowing metal and cools to its colour. |
| Bonus / extra words | **Scrap Bin** | Valid words that aren't in the grid go to the bin. Every 10 bonus words are smelted into a **Hammer Strike** hint. |
| Shuffle | **Turn** | Rearranges the tiles. It's free and unlimited. |
| Reveal-a-letter hint | **Hammer Strike** | Reveals one random empty letter. |
| Targeted hint | **Chisel** | Reveals the letter in a cell you tap. |
| Multi-reveal (fireworks) | **Spark Shower** | Reveals up to 5 random empty letters. |
| Level complete | **"Forged!"** | Hammer clang, a burst of sparks, then XP and any rewards. |
| Level packs / scenes | **Chapters (metals)** | Tin, Copper, Bronze, Iron, Steel, Silver, Gold, Damascus, Starmetal. Each has its own forge scene. |

Every puzzle has **at least one word that uses all the anvil's letters**, as
in the genre.

### 2.2 Puzzle screen layout

This is the standard layout used across the genre (wheel at the bottom, grid
on top, buttons beside the wheel). It's a genre convention, not one specific
game's look.

```
┌────────────────────────────────────┐
│ <  Copper · 12 / 40          [=]   │  top bar: back, chapter + puzzle no., settings
│                                    │
│           ┌─┬─┬─┬─┐                │
│           │ │ │ │ │   THE MOLD     │  ~45% of screen height
│         ┌─┼─┼─┼─┼─┘                │
│         │ │ │ │                    │
│         └─┴─┴─┘                    │
│                                    │
│ [Scrap 7/10]          [Hammer x4]  │  Scrap Bin (left), hints with counts (right)
│                       [Chisel x1]  │
│               T H R E             │  live word preview
│            ╭──────────╮            │
│  [Turn]    │ R  D  A  │            │  THE ANVIL (letter ring)
│            │ H  E  T  │            │
│            ╰──────────╯            │
└────────────────────────────────────┘
```

### 2.3 Game feel (to match the genre)

- **Touching a tile:** it lifts and glows hot. Each tile added to the word plays a slightly **higher-pitched tink**, with a light haptic tick.
- **The trail:** a molten line connects the chosen tiles and follows your finger. You can back out by swiping back to the previous tile.
- **Valid grid word:** the letters fly from the preview into their cells one by one. Each cell fills with glowing metal, which cools to the chapter's metal colour. You hear an anvil clang plus a short sizzle.
- **Already found:** that word flashes in the grid with a soft tap sound.
- **Bonus word:** the letters fly into the Scrap Bin, which shows a fill meter, with a scrap clink.
- **Invalid:** the preview shakes and fades with a dull thunk.
- **Puzzle complete:** every cell pulses, the "Forged!" banner appears with a big hammer strike and a spark burst, and then the results card shows the XP bar, any level-up, and pickups collected.

### 2.4 Campaign

- There are **9 chapters**, one per metal. Each chapter has a **forge scene** background, and its finished cells cool to that metal's colour.
- Puzzles get harder within each chapter, and the chapters themselves get harder from Tin to Starmetal (see the heat tiers in §5).
- **Launch target: about 600 puzzles.** More can be generated at any time with the puzzle tool.
- Solo play **works offline**. Progress is saved on the phone and syncs to your account when you're back online.

| Chapter | Puzzles | Heat range |
|---|---|---|
| Tin | 40 | Ember |
| Copper | 50 | Ember → Dull Red |
| Bronze | 60 | Dull Red |
| Iron | 60 | Cherry Red |
| Steel | 70 | Cherry Red → Orange |
| Silver | 70 | Orange |
| Gold | 80 | Yellow |
| Damascus | 80 | Yellow → White Heat |
| Starmetal | 90 | White Heat |

**Daily Commission** (Forge Hall): one puzzle a day, the same for everyone,
with a streak. The heat follows the weekday (Monday Ember through Saturday
White Heat, Sunday Cherry Red). The first solve of the day earns 25 XP plus 5
per streak day beyond the first (up to 55). Hints come from your stock. The
rules are in `shared/daily.md`.

---

## 3. Hints and rewards

**Hints are items you collect and keep, and there's no currency.** Levelling
up unlocks hint types and gives you more of them, and they also turn up as
random pickups inside puzzles. There's no cap, so you can save them up.

### 3.1 Hint types

| Hint | Effect | Unlocks at |
|---|---|---|
| **Turn** | Shuffle the tiles | Always available, free |
| **Hammer Strike** | Reveal 1 random empty letter | Lv 1 (you start with 3) |
| **Chisel** | Reveal the letter in the cell you tap | Lv 5 |
| **Spark Shower** | Reveal up to 5 random empty letters | Lv 12 |

### 3.2 Where hints come from

1. **Level-up rewards.** These are the main source:
   - Every level-up: **+1 Hammer Strike**.
   - Every 5th level: **+1 Chisel**, once Chisel is unlocked.
   - Every 10th level: **+1 Spark Shower**, once Spark Shower is unlocked.
   - Rank-ups (Lv 10, 25, 50, 80, 120): a bonus bundle of one of each unlocked type.
2. **Random pickups in puzzles.** Some puzzles hide a **glowing ember** in one empty grid cell. Forge the word that covers it to collect a hint.
   - About **1 in 5 puzzles** has a pickup, and occasionally there are two.
   - The hint type is weighted about **70% Hammer Strike, 25% Chisel and 5% Spark Shower**, and only types you've unlocked can appear.
   - In the campaign, which puzzles have a pickup is random **for each player**, so different friends find them in different puzzles. (This uses a seed from player and puzzle, so the server can check it. See TECH.md.)
3. **Scrap Bin.** Every 10 bonus words gives **+1 Hammer Strike**. The bin carries over between puzzles and across modes.

### 3.3 Using hints in each mode

- **Solo:** use any hint at any time.
- **Co-op:** each player spends **from their own stock**, and the revealed letters show for the whole team.
  - Hinted letters score nothing. A word is worth 10 points for each letter **not** revealed by a hint.
  - A word revealed entirely by hints completes itself, and nobody scores it.
  - Pickups go to whoever forges the word that covers them.
- **Versus:** **no hints** during a match (Turn is still allowed).
  - Pickups still appear, in the same cell for everyone because it's the same puzzle.
  - Anyone who forges that word collects the pickup, but can only use it after the match.

All numbers here are starting values to tune during playtesting.

---

## 4. Accounts and progression

### 4.1 Sign-in
- **Google** (one tap on Android) or **email and password**, through Firebase Authentication.
- On first launch you pick a **unique username** (a profanity filter applies) and an emblem avatar.
- **Delete my account** is in Settings. It's good practice even without the Play Store.

### 4.2 XP, Smith Level and ranks

The **Smith Level** comes from XP earned in every mode. It is separate from your
campaign puzzle number. XP, levels and hints are all **granted by the
server**, so they stay consistent across your devices and can't be edited
on the phone.

| Source | XP (starting values) |
|---|---|
| Solo puzzle forged | 10, plus 1 per bonus word (max +5) |
| Co-op round | 20 for taking part, plus 1 per 10 points you scored, plus 20 if the team fills the mold, plus 10 for MVP |
| Versus series | 5 per round played, plus 10 per round won, plus 30 for winning the series |

**Hotter games pay more.** Co-op and Versus XP are multiplied by the heat
played (§5): ×1.0 at Ember, ×1.2 Dull Red, ×1.4 Cherry Red, ×1.6 Orange,
×1.8 Yellow and ×2.0 White Heat. Playing above your own tier (the heat
for your level) adds 0.2 more for each tier, so a newcomer in a White Heat
game gets ×3.0. A strong player who picks a cool heat gets only that
heat's multiplier.

**XP to reach the next level:** `50 + 10 × current level`. For example, Lv 1→2 takes 60 XP, Lv 10→11 takes 150, and Lv 50→51 takes 550.

| Rank | Smith Level |
|---|---|
| Apprentice | 1–9 |
| Journeyman | 10–24 |
| Smith | 25–49 |
| Master Smith | 50–79 |
| Grandmaster | 80–119 |
| Legend | 120+ |

**Profile shows:** level and rank, XP bar, hint stock, words forged, longest
word, campaign progress, co-op rounds and MVPs, versus series played and won,
and versus rounds won.

---

## 5. Difficulty: heat tiers

Puzzle difficulty is a **heat tier**, named after the colours a blacksmith reads
in hot metal.

- **Campaign:** the heat comes from where you are in the campaign.
- **Co-op and Versus:** the **host picks the heat** in the lobby. **Auto**, the default, is the **host's Smith Level** in co-op and the **median Smith Level** in the room in Versus.

| Heat | Smith Level | Anvil letters | Grid words | Word pool | Co-op timer | VS round timer |
|---|---|---|---|---|---|---|
| Ember | 1–5 | 4 | 3–5 | very common | 3:00 | 2:00 |
| Dull Red | 6–15 | 5 | 5–7 | common | 3:00 | 2:00 |
| Cherry Red | 16–30 | 6 | 7–10 | common | 3:30 | 2:30 |
| Orange | 31–50 | 6–7 | 9–12 | + less common | 3:30 | 2:30 |
| Yellow | 51–80 | 7 | 11–15 | + uncommon | 4:00 | 3:00 |
| White Heat | 81+ | 7–8 | 14–20 | uncommon, longer words | 4:00 | 3:00 |

**Co-op scales with team size.** It uses a puzzle from the room's heat tier
with about **2 more grid words for each player after the first**, so four
people don't finish it in seconds. Two practical limits apply:
- A 4-letter Ember anvil can't support that many common words, so Ember rooms of 3–4 get puzzles of 6–11 words.
- A 10×10 grid tops out at about 22 words, which caps White Heat for 4 players.

---

## 6. Puzzles and dictionary

- **Word lists:** only openly licensed lists are used.
  - **SCOWL** has a permissive licence. Its size levels act as a "how common is this word" scale.
  - **ENABLE** is public domain. It's used to accept bonus words.
  - A **blocklist** keeps offensive words out of grids and out of the bonus list.
- **Answers vs bonus words:** grid answers come only from **common** words, so nobody has to guess obscure ones. Bonus words come from the bigger list, so obscure but real words still count.
- **How the generator builds a puzzle** (`tools/puzzlegen`):
  1. Pick a seed word with N letters (N = 4–8). Those letters become the anvil.
  2. Find every word of 3+ letters that can be made from them, in both the answer and bonus pools.
  3. Choose K answer words, always including one that uses every letter.
  4. Lay them out as a connected crossword with proper crossword spacing, so no stray words form. It must fit within **10 × 10**.
  5. Generate each puzzle for a target heat tier, then score its difficulty (letter count, word count, how common the words are, longest word) to order puzzles within a chapter.
  6. Write the puzzle out as JSON.
- **Two separate pools:**
  - The **campaign** pool is bundled in the app.
  - The **multiplayer** pool lives only on the server, so multiplayer answers never ship inside the APK.
- The server avoids giving anyone a multiplayer puzzle they've played recently.

---

## 7. Friends and rooms

There's no matchmaking with strangers. Everything goes through friends and
room codes.

- **Friends:** add someone by username, and they accept. Your friends list shows who's **online**, who's **in a puzzle**, and who's **in a room**.
- **Forge Hall (home screen):**
  - Continue the campaign.
  - Start a Co-op or Versus room.
  - Join a room with a code.
  - **Open rooms** among your friends, e.g. "Sam's Co-op · 2/4 · Join".
  - Friends, Profile and Settings.
- **Rooms:**
  - The creator is the **host** and gets a **6-character room code**. Codes skip look-alike characters such as 0/O and 1/I.
  - Friends join with the code, through an **invite**, or from the open rooms list.
  - Co-op rooms hold 2–4 players, Versus rooms 2–5 and Team Versus rooms 2–6. A Co-op room with just the host is allowed for testing.
- **Invites:** in-app while the app is open. Push notifications for invites come later (Firebase Cloud Messaging is free).
- **Emotes:** preset reactions in rooms ("Nice strike!", "So close!", a fire emoji, a hammer emoji).
- **Chat:** text chat for everyone in a Co-op or Versus room, in the lobby, during rounds and at results. New lines pop up over the game for a moment, and the chat button counts the ones not yet read. Quick phrases send in one tap. Holding down someone's line mutes them for the rest of the room, and Settings can turn chat off (shared/room-protocol.md, "Chat").

---

## 8. Co-op: "The Guild Forge" (2–4 players)

One shared mold, one timer, everyone forging together.

### Flow
1. The **host** creates a Co-op room, and friends join.
2. **Lobby:** the player list shows levels and ready checks. The host picks the heat (Auto or a tier) and everyone sees it ("Cherry Red heat · picked by Ali"). Only the host can start.
3. A **3-2-1 countdown** starts the round. Everyone sees the **same mold and the same letters**, and each player can Turn (shuffle) their own anvil.
4. **Forging.** The server referees every word:
   - **A grid word nobody has found yet:** it goes to that player. It fills in **that player's colour** on every screen, and a line appears in the feed: "Ali forged THREAD +60".
   - **Already found:** only the sender sees "Already forged by Sam".
   - **A bonus word nobody has found yet:** small points for the finder, and it goes into the finder's Scrap Bin.
   - **Not a word:** only the sender sees the shake and buzz.
   - **Two players send the same word at almost the same moment:** the server handles words strictly in the order they arrive. The first gets it, and the second sees "Already forged by …".
5. The **round ends** when the mold is full (the team wins) or the timer runs out.
6. **Results:**
   - The team's score, how much of the mold was filled, and stars (★★★ = finished with at least 50% of the time left, ★★ = finished, ★ = at least 75% filled).
   - Each player's points, words and longest word.
   - The **"Master of the Forge" (MVP)** banner goes to the top scorer. If two players are tied, the one who reached that score first gets it.
   - XP is added to everyone's profiles.
7. The host can **Forge Again** (new puzzle, same group) or close the room.

### Scoring
- **Grid word:** 10 points per letter not revealed by a hint, so THREAD with no hints is 60.
- **Bonus word:** 3 points per letter.

### Player colours
Copper, Gold, Verdigris (green) and Cobalt (blue). Each found word also carries
the player's initial, so it's still readable for colour-blind players.

### Screen extras
- A **top strip** shows the team score, the timer, and each teammate as a colour chip with their points.
- Under the mold there's a **feed line** showing the last 2–3 claims.

### Disconnects
- **Host leaves (or drops for more than 30 seconds):** the host role passes to whoever has been in the room longest among those still connected. On Auto, their level now sets the heat, and the banner updates. The old host doesn't get it back by returning.
- **Host leaves mid-round:** the round carries on, because it runs on the server, not on the host's phone.
- **Anyone drops:** they have **30 seconds to rejoin** and keep their points. They get the full current board when they're back.

---

## 9. Versus: "Anvil Clash" (2–5 players)

### 9.1 Rounds: race to finish the mold
- Everyone gets the **same puzzle**, each on **their own mold**, so nobody can block or steal anyone else's words.
- **The first player to fill their whole mold wins the round.** The round ends for everyone at that moment ("Sam forged it first!"), and every board freezes.
- **If the timer runs out first,** the round ends, and the player with the **most letters filled** wins it.
  - If two players have the same count, whoever reached that count first wins.
  - If nobody filled anything, the round has no winner.
- **No hints.** Turn is allowed. Bonus words are still accepted and go into your Scrap Bin, but they don't help you win the round.
- The **top strip** shows each opponent's avatar, their round-win pips and a live **progress bar** showing how full their mold is. You never see their words.
- The round timer depends on the heat tier (see §5).

### 9.2 Series: best of 3, 5, 7 or 10
- The **host picks the series length** in the lobby.
- **Round wins add up across the series.** Each round is a new puzzle at the same heat.
- **The series ends early once nobody can catch the leader.** That happens when the leader's wins are more than anyone else's wins plus the rounds left.
  - With 2 players: best of 3 is first to 2, best of 5 is first to 3, best of 7 is first to 4, and best of 10 is first to 6.
- **Tied at the end?** Only the tied players play a **sudden-death round** under the same rules, while everyone else watches live. The "most letters, then who got there first" rule almost always produces a winner. In the rare case that nobody fills a single letter, the sudden-death round is played again.
- **Between rounds:** 10 seconds of standings showing the round winner, how they won (finished or on time), the series tally, and "Round 4 of up to 7".
- **End of the series:** a podium ranked by round wins, with XP added to everyone's profiles. Every round can be looked back at from there: the whole mold with the words you forged and the ones you missed, everyone's molds, and everyone's Scrap Bin.

### 9.3 Player colours
Copper, Gold, Verdigris, Cobalt and **Titanium** (the purple of anodised
titanium).

### 9.4 Disconnects
- A dropped player's mold freezes. They can rejoin within 30 seconds and carry on with that round.
- If they don't return, they can't win any more rounds, and the series continues without them.
- If only one player is left, they win the series by forfeit.

### 9.5 Team Versus: "Team Clash" (2–6 players)
- **Two teams:** Copper and Cobalt, 1 to 3 smiths each. A series starts only when both teams have the same number. Newcomers join the smaller team; anyone can switch teams in the lobby (or between series), and the host can move anyone.
- Everyone races their **own mold** of the same puzzle, as in Versus, and a round is won by a **team**. The host picks how:
  - **Combined:** a team's score is its smiths' letters added up. The first team whose every smith has filled their mold wins the round; a smith who finishes early waits for their teammates. At the timer, the higher total wins (a tie goes to the team that got there first).
  - **First to finish:** the first smith to fill their mold wins the round for their team. At the timer, the smith with the most letters wins it for their team.
- **Series:** best of 3, 5, 7 or 10, counted in team wins, with sudden death for everyone if the teams are level. A team whose smiths have all left loses by forfeit.
- **XP:** as in Versus, but rounds and the series count as won when your team won them.
- Player colours add **Rose gold** for a sixth smith. The teams show in copper and cobalt.
- No Survival variant: teams play classic rounds.

---

## 10. Everyday extras (the genre's daily loop)

Everyday features word-puzzle players expect, in forge clothes. The exact
rules live in the shared contracts.

| Genre feature | Wordsmith | Contract |
|---|---|---|
| Word definitions and pronunciation | **Meanings**: tap any forged word (or a bonus word, or a word on the Forged! card) to see up to three definitions from Open English WordNet, offline, and hear it said. Words WordNet lacks (rarer words) are looked up online through the server (Wiktionary) when there's a connection. Names aren't words: they never count as answers or bonus words, and their meanings aren't shown | `tools/dictgen`, `GET /v1/define/:word` |
| Daily login reward | **Daily Stoke**: a 7-step track (XP, hints, a Spark Shower on day 7); missing days never resets it | `shared/forge-board.md` |
| Quests | **Work Orders**: three daily orders (one swap a day) and a chest for all three, plus two weekly orders including a **Letter Hunt** | `shared/forge-board.md` |
| Weekend tournament | **Weekly Trials**: an XP race among your friends; the top three win prizes | `shared/forge-board.md` |
| Team help | **Gifts**: send each friend a free Hammer Strike every day | `shared/forge-board.md` |
| Daily puzzle calendar and monthly awards | **Commission calendar**: play missed days of this month or last (no streak), and earn a bronze, silver or gold trophy each month | `shared/daily.md` |
| Fun facts with the daily puzzle | **Smith's Lore**: every commission forged adds a page of forge history to the Lore Book | `app/assets/lore` |
| Gold tiles and picture pieces | **Gilded cells** give **blueprint pieces** that build twelve **Masterworks**, shown in the **Armory** | `shared/masterworks.md` |
| Level select | **Chapter maps**: replay any forged puzzle for practice | — |
| Master / expert levels | **Master Forge**: after Starmetal, every puzzle again at full XP | `shared/master-forge.md` |
| Reminder notifications | **Daily reminder** at an hour you pick, only when the commission is still waiting | `shared/push.md` |
| Tutorial | A hand traces a word on the first puzzle; one-time tips for embers, gilded cells and meanings | — |
| Timed / survival modes | **Survival**: one heated word at a time on a countdown; if it isn't forged in time it melts and the round ends. Solo as **The Crucible** (an endless run of puzzles), and as a lobby option in Co-op and Versus | `shared/survival.md` |
| Game history | **Puzzle history** (from the Profile): every puzzle finished on this phone in every mode, newest first and filtered by mode, the latest 150 kept. Each opens its whole mold, with the words forged, the ones missed glowing and the bonus words; co-op shows who forged what, the Crucible every puzzle of the run, and Versus the series round by round. Kept on the phone only, and cleared when the account is deleted | `app/lib/data/history.dart` |

Also: a left-handed layout (hints on the left of the anvil).

---

## 11. Fair play and safety

- The server holds every multiplayer answer and referees every guess. Phones only get the shape of the grid and the letters.
- **Rate limit:** about 4 guesses per second per player. A burst of invalid guesses triggers a 3-second cool-down, which stops anyone spamming every letter combination.
- XP, levels, hints and stats are only ever written by the server.
- Room chat goes through the same profanity filter as usernames: bad words are starred out on the server. Lines are limited to 160 characters and a burst of 5, then one every 2 seconds. Players can mute each other, and chat is never stored beyond the room. There's no reporting or moderation team yet. Usernames go through the profanity filter too.

---

## 12. Originality

Game mechanics can't be copyrighted, so the swipe ring, crossword grid, bonus
words, shuffle and hints follow common word-puzzle conventions. Other games'
**art, sounds, puzzle data, names and screen designs** are protected, so all
of ours are original or properly licensed (see
[ART_AND_AUDIO.md](ART_AND_AUDIO.md)). Nothing is taken from any other game.
