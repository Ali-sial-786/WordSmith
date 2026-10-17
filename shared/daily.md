# Daily Commission (shared contract, M5)

One puzzle a day, the same for everyone. Solve it for bonus XP and keep a
streak going. It's solo play: the app has the answers (like the campaign) and
the server checks the result when it's sent.

## Which puzzle

- The day is the **UTC date** (`YYYY-MM-DD`).
- The puzzle is a bank puzzle with `size` 1, chosen deterministically from the
  date (for example `fnv1a32("daily:" + date)` modulo the number of candidates,
  candidates ordered by id), so every phone and the server agree.
- The heat follows the weekday: Monday Ember (1), Tuesday Dull Red (2),
  Wednesday Cherry Red (3), Thursday Orange (4), Friday Yellow (5),
  Saturday White Heat (6), Sunday Cherry Red (3).

## REST

- `GET /v1/daily` → `{date, heat, puzzle, completed, streak, best}`
  - `puzzle` uses the campaign puzzle format (`shared/puzzle-format.md`), so the
    app can play it with the solo screen. Its `id` is `daily-<date>`.
  - `completed`: whether I've finished today's.
  - `streak`: consecutive days completed, ending today (or yesterday, if today
    isn't done yet). `best`: my longest streak.
- `POST /v1/daily/complete` with
  `{date, foundWords, bonusWords, hintsUsed: {hammer, chisel, sparks}, durationMs}`
  → `{profile, xp, streak, best, alreadyDone}`
  - `date` must be today, or yesterday within the first hour of today (UTC).
    Otherwise `400 wrong_day`.
  - As in solo sync: the typed words in `foundWords` plus the hints used must
    account for every cell (`400 incomplete`); a slot that fills in from its
    crossings needn't be typed. `durationMs` must be at least 1 s per typed
    word (`400 too_fast`). Unknown words and invalid bonus words are ignored.
  - The first completion of a day grants **25 XP plus 5 per streak day beyond the
    first, up to +30** (so 25–55), takes the hints used from the stock (never
    below 0), and adds valid bonus words to the Scrap Bin. Level-up rewards
    apply as usual. A repeat for the same day grants nothing: `alreadyDone: true`.
- Both need a set-up account.
- Other errors: `400 invalid_body` (bad shape or date), `503 daily_unavailable`
  (empty bank), `409 sync_conflict` (the profile kept changing; retry).
- Completing marks the bank puzzle as seen, so co-op and Versus won't serve it
  to that player for 60 days. The answers are public through `GET` (fine for a
  friends-only game).

## Storage

A D1 table `daily_completions (user_id, date, completed_at, xp)` with primary
key `(user_id, date)`; streaks are counted from it. Deleting an account deletes
its rows.
