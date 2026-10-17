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
Strikes).

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
  "dailyEndsAt": 1760745600000,
  "weeklyEndsAt": 1761004800000
}
```

An order:

```json
{ "slot": "d0", "kind": "bonus_words", "target": 10, "progress": 4,
  "letter": null, "friends": false, "reward": <reward>, "claimed": false }
```

- `slot`: `d0`, `d1`, `d2` (daily) or `w0`, `w1` (weekly).
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
  daily order: `POST /v1/me/orders/swap {slot}` → `{profile, board, reward}`
  (`reward` all zeros). The new kind is a random pool kind not already among
  today's orders (and not a second `friends` kind), with progress 0. Errors:
  `409 swap_used`, `409 order_done` (finished or claimed), `400 invalid_slot`.

### Rewards

| Order | Reward |
|---|---|
| each daily order | 20 XP and 1 Hammer Strike |
| the daily **chest** (all three daily orders claimed) | 30 XP and 1 Chisel |
| `letter_hunt` | 100 XP and 1 Spark Shower |
| weekly `solo_puzzles` | 60 XP and 1 Chisel |

`POST /v1/me/orders/claim {slot}` with `slot` one of `d0`–`d2`, `w0`, `w1` or
`chest` → `{profile, board, reward}`. Errors: `409 not_done` (below target,
or the chest before all three are claimed), `409 already_claimed`,
`400 invalid_slot`.

## Weekly Trials

A weekly XP race between you and your friends. All XP counts, whatever its
source, including rewards from this board.

```json
"trials": {
  "week": "2026-W42",
  "endsAt": 1761004800000,
  "standings": [
    { "id": "u1", "username": "Ali", "avatar": "avatar_02", "level": 14, "xp": 340, "me": true }
  ],
  "lastWeek": { "week": "2026-W41", "place": 1, "of": 4, "reward": <reward>, "claimed": false }
}
```

- `standings`: me and my accepted friends, by XP this week (high first), ties
  by username (case-insensitive). Players with 0 XP are listed too.
- `lastWeek`: my result last week, or `null` if I earned no XP then. `of` is
  the number of players (me and friends) with XP > 0 last week; `place` is
  mine among them. There's a prize only when `of` ≥ 2 and I placed in the
  top 3; otherwise `reward` is `null`. The place is worked out with my
  current friends.

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
  "pending": [ { "id": 17, "from": { "id": "u2", "username": "sam", "avatar": "avatar_05" }, "sentAt": 1760700000000 } ],
  "sentToday": ["u2", "u3"],
  "claimedToday": 1,
  "claimLimit": 5
}
```

- `POST /v1/friends/:id/gift` → `{ok: true}`. Errors: `404 not_friends` (not
  an accepted friend), `409 already_sent` (already today), `400` for sending
  to yourself. The friend gets a push notification (`shared/push.md`) with
  `"data": {"type": "gift", "from": "<user id>"}`, title "<username> sent you a
  gift", body "A free Hammer Strike is waiting in the Forge Hall".
- `POST /v1/me/gifts/claim` → `{profile, board, reward}`: collects the oldest
  pending gifts, up to `claimLimit − claimedToday` of them, one Hammer Strike
  each. `409 nothing_to_claim` when none are pending or today's limit is used.
- `pending` lists at most 20, oldest first. Gifts expire 7 days after sending.
- Removing a friend leaves gifts already sent in place.

## Storage (suggested)

- `profiles`: `stoke_claims INT`, `stoke_last TEXT` (date).
- `work_orders (user_id, period, slot, kind, target, progress, letter, claimed)`,
  primary key `(user_id, period, slot)`, where `period` is `d:<date>` or
  `w:<week>`; created when first needed. Rows older than 14 days can go.
  Today's swap and chest can be stored as rows with slots `swap` and `chest`.
- `weekly_xp (user_id, week, xp)`, primary key `(user_id, week)`.
- `trial_claims (user_id, week)`.
- `gifts (id, from_user, to_user, sent_date, sent_at, claimed_at)`, with one
  gift per `(from_user, to_user, sent_date)`.
- Deleting an account deletes its rows (gifts it sent or received included).
