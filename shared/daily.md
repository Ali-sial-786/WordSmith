# Daily Commission (shared contract, M5)

One puzzle a day, the same for everyone. Solve it for bonus XP and keep a
streak going. It's solo play: the app has the answers (like the campaign) and
the server checks the result when it's sent.

## Which puzzle

- The day is the **UTC date** (`YYYY-MM-DD`).
- The puzzle is a bank puzzle with `size` 1, chosen deterministically from the
  date (for example `fnv1a32("daily:" + date)` modulo the number of candidates,
  candidates ordered by id), so every phone and the server agree. Candidates
  come from the bank's first part only (`m-00001` to `m-00960`), so puzzles
  added to the bank later don't change any date's puzzle.
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

## Calendar and catch-up

Missed a day? Days from the **1st of last month** up to yesterday can be
played late, as in the genre's daily-puzzle calendars.

- `GET /v1/daily?date=YYYY-MM-DD` → the same body for that day (without
  `date`, today). Its `completed` is for that day; `streak` and `best` are as
  usual. A date outside the window (before the 1st of last month, or after
  today) → `400 wrong_day`; a malformed one → `400 invalid_body`.
- `POST /v1/daily/complete` also accepts any date in the window. A **late**
  completion (any date other than today, apart from yesterday within the
  first hour of today) grants a flat **15 XP**, never touches the streak, and
  otherwise works the same (hints, Scrap Bin, `alreadyDone`, seen puzzles).
  Dates outside the window → `400 wrong_day`.
- `POST /v1/daily/complete` also answers `late` (whether that date is a late
  one) and `total` (completions after it, like the `GET` body's).
- Every `GET /v1/daily` body also has `total`: all my completions, late ones
  included. The app unlocks one Smith's Lore page per completion.
- `GET /v1/daily/calendar?month=YYYY-MM` →
  `{month, days, trophy, trophies}`:
  - `days`: the dates I completed that month, on time or late, ascending.
  - `trophy`: that month's trophy so far: `"gold"` when every day of the
    month is done (only possible once the month is over or on its last day),
    `"silver"` for 15+ days, `"bronze"` for 7+ days, otherwise `null`.
  - `trophies`: `{bronze, silver, gold}`, how many months have earned each
    (a month counts once, at its best trophy).
  - `month` must be this month or last month for the calendar view; any
    other month (earlier, or to come) → `400 wrong_month`, a malformed one
    → `400 invalid_body`. Without `month`, this month. (Trophy counts cover
    all months.)

## Storage

A D1 table `daily_completions (user_id, date, completed_at, xp, late)` with
primary key `(user_id, date)`. Streaks are counted from it, ignoring `late`
rows, so playing a missed day late can't repair a broken streak. Deleting an
account deletes its rows.
