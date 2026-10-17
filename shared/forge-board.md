# The Forge Board (shared contract)

Everyday goals and friendly competition, shown in the Forge Hall: the
**Daily Stoke** (a login reward), **Work Orders** (daily and weekly quests),
**Weekly Trials** (a friends-only XP tournament) and **Gifts** (a free Hammer
Strike for each friend once a day). Everything here is granted by the server.

All of it needs a set-up account (`403 setup_required`). Days are UTC dates
(`YYYY-MM-DD`); weeks are ISO weeks starting Monday 00:00 UTC, written
`YYYY-Www` (for example `2026-W42`).

## Rewards

A reward is `{xp, hints: {hammer, chisel, sparks}}`; every field is present
(0 when nothing). Granting one:

- adds the XP like any other XP (level-ups and their rewards apply, and it
  counts towards the Weekly Trials);
- adds the hints, except that a hint type the player hasn't unlocked yet
  (Chisel below Lv 5, Spark Shower below Lv 12) is given as the same number of
  Hammer Strikes instead. The level is the one before the reward's XP is added.

Responses report the reward as actually granted (after any swap to Hammer
Strikes). The board itself (`track`, each order's and the chest's `reward`)
always shows rewards as configured. A reward's XP is recorded as an XP event
like any other, so it counts towards the Weekly Trials in the week it's
claimed.

## `GET /v1/me/board`

Everything the Forge Hall shows, in one call:

```json
{
  "date": "2026-10-17",
  "week": "2026-W42",
  "stoke": { ... },
  "orders": { ... },
  "trials": { ... },
  "gifts": { ... }
}
```

Every claim below answers `{profile, board, reward}` (`reward` as granted;
`board` is a fresh `GET /v1/me/board` body), so the app can redraw at once.
Each is granted exactly once, even when the same claim arrives twice at the
same moment (the second gets the claim's `409`). Any claim may also answer
`409 sync_conflict` when the profile kept changing meanwhile (retry), and
`400 invalid_json` for a body that isn't JSON. Bodies other than `{slot}` are
ignored.

## Daily Stoke

A 7-day track of rewards. Claim once per UTC day. Missing days never resets
it: the next claim simply takes the next step, and after day 7 it starts
again at day 1.

| Day | Reward |
|---|---|
| 1 | 15 XP |
| 2 | 1 Hammer Strike |
| 3 | 25 XP |
| 4 | 1 Chisel |
| 5 | 35 XP |
| 6 | 2 Hammer Strikes |
| 7 | 1 Spark Shower and 50 XP |

```json
"stoke": { "day": 3, "claimedToday": false, "track": [<reward>, ... 7] }
```

- `day` (1–7) is the step today's claim gives, or the step already claimed
  today when `claimedToday` is true.
- `track` lists the 7 rewards as configured (before any swap to Hammer Strikes).
- `POST /v1/me/stoke/claim` → `{profile, board, reward}`. A second claim on the
  same day → `409 already_claimed`.

## Work Orders

Three **daily orders** and two **weekly orders**. Progress counts when the
server accepts the play (a solo result counts on the day it's synced, not the
day it was played offline). Progress stops at the target. A finished order is
claimed by the player; unclaimed rewards are lost when the period ends.

```json
"orders": {
  "daily": [<order>, <order>, <order>],
  "weekly": [<order>, <order>],
  "chest": { "reward": <reward>, "ready": false, "claimed": false },
  "swapAvailable": true,
  "dailyEndsAt": 1792281600000,
  "weeklyEndsAt": 1792368000000
}
```

An order:

```json
{ "slot": "d0", "kind": "bonus_words", "target": 10, "progress": 4,
  "letter": null, "friends": false, "reward": <reward>, "claimed": false }
```

- `slot`: `d0`, `d1`, `d2` (daily) or `w0`, `w1` (weekly).
- `progress` counts from 0 for a day's or week's orders until something
  counts towards them; reading the board never changes anything.
- `letter`: only for `letter_hunt`, the letter (uppercase A–Z).
- `friends`: true for kinds that need other players (`coop_rounds`, `vs_series`).
- The app writes the text from `kind`, `target` and `letter`.

### Kinds and what counts

| kind | target | counts |
|---|---|---|
| `solo_puzzles` | 3 (weekly: 15) | campaign puzzles accepted by solo sync |
| `bonus_words` | 10 | valid bonus words from solo sync, the Daily Commission, co-op and Versus |
| `words` | 30 | grid words the player forged: typed words in solo sync and the daily (`foundWords`), words the player claimed in co-op, and words claimed in their own Versus molds |
| `long_words` | 3 | the same words, counting only those of 6+ letters |
| `daily` | 1 | a Daily Commission completion that isn't a repeat (catch-up days count too) |
| `no_hints` | 1 | a campaign puzzle accepted by solo sync with no hints used |
| `coop_rounds` | 1 | a co-op round the player took part in (they're in its results) |
| `vs_series` | 1 | a Versus series the player finished (they're on its podium) |
| `letter_hunt` | 40 | forged words (as for `words`) that contain the week's letter |

### Choosing the orders

- **Daily:** the same three for everyone each day, so friends can compare.
  `rand = mulberry32(fnv1a32("orders:" + date))` (functions as in
  `shared/pickups.md`) shuffles the daily pool with a Fisher–Yates shuffle
  (`for i from n−1 down to 1: j = floor(rand() × (i+1)); swap`), then takes
  the first three, skipping a second `friends` kind. Daily pool, in this
  order: `solo_puzzles`, `bonus_words`, `words`, `long_words`, `daily`,
  `no_hints`, `coop_rounds`, `vs_series`.
- **Weekly:** `w0` is always `letter_hunt`, `w1` is always `solo_puzzles`
  with target 15. The letter is
  `"RTNSLDGPMBHCKFWY"[fnv1a32("letter:" + week) mod 16]`.
- **Swap:** once per day, a player may replace one unfinished, unclaimed
  daily order: `POST /v1/me/orders/swap {slot}` (`d0`–`d2`) →
  `{profile, board, reward}` (`reward` all zeros). The new kind is a random
  pool kind that isn't any of today's three (the replaced one included) and
  wouldn't be a second `friends` kind beside the two that stay, with its
  daily target and progress 0. The server picks it (seeded by the player and
  the day, so a retried swap picks the same). The swapped order keeps its
  kind for the rest of the day. Errors: `409 swap_used`, `409 order_done`
  (finished or claimed), `400 invalid_slot` (missing, or not `d0`–`d2`).
- `swapAvailable`: today's swap is unused and at least one daily order is
  still unfinished and unclaimed.
- `chest.ready`: all three daily orders are claimed (it stays true once the
  chest is claimed too); `chest.claimed`: the chest is open.

### Rewards

| Order | Reward |
|---|---|
| each daily order | 20 XP and 1 Hammer Strike |
| the daily **chest** (all three daily orders claimed) | 30 XP and 1 Chisel |
| `letter_hunt` | 100 XP and 1 Spark Shower |
| weekly `solo_puzzles` | 60 XP and 1 Chisel |

`POST /v1/me/orders/claim {slot}` with `slot` one of `d0`–`d2`, `w0`, `w1` or
`chest` → `{profile, board, reward}`. Errors: `409 already_claimed` (checked
first), `409 not_done` (below target, or the chest before all three are
claimed), `400 invalid_slot` (missing, or anything else).

## Weekly Trials

A weekly XP race between you and your friends. All XP counts, whatever its
source, including rewards from this board.

```json
"trials": {
  "week": "2026-W42",
  "endsAt": 1792368000000,
  "standings": [
    { "id": "u1", "username": "Ali", "avatar": "avatar_02", "level": 14, "xp": 340, "me": true }
  ],
  "lastWeek": { "week": "2026-W41", "place": 1, "of": 4, "reward": <reward>, "claimed": false }
}
```

- `standings`: me and my accepted friends, by XP this week (high first), ties
  by username (case-insensitive). Players with 0 XP are listed too.
- `standings` includes only set-up accounts; `level` is the Smith Level now.
- `lastWeek`: my result last week, or `null` if I earned no XP then. `of` is
  the number of players (me and friends) with XP > 0 last week; `place` is
  mine among them: 1 + the number of them with more XP than me, so equal XP
  shares a place (two can both be 1st, and then the next is 3rd). There's a
  prize only when `of` ≥ 2 and I placed in the top 3; otherwise `reward` is
  `null`. The place is worked out with my current friends. `claimed`: I've
  claimed last week's prize.

| Place | Prize |
|---|---|
| 1st | 100 XP and 1 Spark Shower |
| 2nd | 50 XP and 1 Chisel |
| 3rd | 2 Hammer Strikes |

`POST /v1/me/trials/claim` → `{profile, board, reward}`. Errors:
`409 no_prize` (no prize last week), `409 already_claimed`. A prize can only
be claimed during the following week.

## Gifts

Each day you may send every friend one free Hammer Strike. It costs you
nothing. They collect it from the Forge Hall.

```json
"gifts": {
  "pending": [ { "id": 17, "from": { "id": "u2", "username": "sam", "avatar": "avatar_05" }, "sentAt": 1792224000000 } ],
  "sentToday": ["u2", "u3"],
  "claimedToday": 1,
  "claimLimit": 5
}
```

- `POST /v1/friends/:id/gift` (no body needed) → `{ok: true}`. Errors:
  `404 not_friends` (not an accepted friend, or no such user),
  `409 already_sent` (already today), `400 cannot_gift_self`. The friend gets
  a push notification (`shared/push.md`, "Gift notifications") with
  `"data": {"type": "gift", "from": "<user id>"}`, title "<username> sent you a
  gift", body "A free Hammer Strike is waiting in the Forge Hall".
- `sentToday`: the friends I've sent a gift to today (UTC). `claimedToday`:
  gifts I've collected today (UTC).
- `POST /v1/me/gifts/claim` → `{profile, board, reward}`: collects the oldest
  pending gifts, up to `claimLimit − claimedToday` of them, one Hammer Strike
  each. `409 nothing_to_claim` when none are pending or today's limit is used.
- `pending` lists at most 20, oldest first. Gifts expire 7 days after sending
  (a gift sent at `t` can be collected until just before `t + 7 days`).
- Removing a friend leaves gifts already sent in place.

## Test vectors

The day's orders and the week's letter, which the app can check its own
copy of the choice against:

| date | daily orders `d0`, `d1`, `d2` |
|---|---|
| `2026-10-01` | `solo_puzzles`, `coop_rounds`, `long_words` (the shuffle's third, `vs_series`, is skipped) |
| `2026-10-12` | `daily`, `no_hints`, `long_words` |
| `2026-10-17` | `daily`, `coop_rounds`, `words` |
| `2026-10-18` | `bonus_words`, `no_hints`, `long_words` |
| `2026-10-19` | `solo_puzzles`, `bonus_words`, `words` |
| `2026-11-01` | `vs_series`, `bonus_words`, `solo_puzzles` |

| week | letter |
|---|---|
| `2026-W01` | `K` |
| `2026-W41` | `M` |
| `2026-W42` | `T` |
| `2027-W01` | `S` |

## Storage

As built (`server/migrations/0005_forge_board.sql`):

- `profiles`: `stoke_claims INT` (claims ever; the next step is
  `stoke_claims mod 7 + 1`), `stoke_last TEXT` (date).
- `work_orders (user_id, period, slot, kind, target, progress, letter, claimed)`,
  primary key `(user_id, period, slot)`, where `period` is `d:<date>` or
  `w:<week>`; created when something first counts towards them (or the
  swap). A player's rows older than 14 days are dropped as new ones are made.
  Today's swap and chest are rows with slots `swap` (`kind` = the slot
  swapped) and `chest`.
- `weekly_xp (user_id, week, xp)`, primary key `(user_id, week)`, kept in
  step with `xp_events` by a trigger, so every XP grant counts.
- `trial_claims (user_id, week, claimed_at)`.
- `gifts (id, from_user, to_user, sent_date, sent_at, claimed_at)`, with one
  gift per `(from_user, to_user, sent_date)`.
- Deleting an account deletes its rows (gifts it sent or received included).
