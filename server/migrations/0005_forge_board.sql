-- The Forge Board (shared/forge-board.md), Masterworks (shared/masterworks.md)
-- and the Daily Commission's catch-up days (shared/daily.md).
--
-- Days are UTC dates (YYYY-MM-DD) and weeks ISO weeks (YYYY-Www, Monday
-- 00:00 UTC). Deleting an account deletes its rows in every table here,
-- gifts it sent or received included (src/db/accounts.ts).

-- The Daily Stoke: claims ever made (the next step is claims % 7 + 1) and
-- the day of the last one. Blueprint pieces collected, for the Masterworks.
ALTER TABLE profiles ADD COLUMN stoke_claims INTEGER NOT NULL DEFAULT 0;
ALTER TABLE profiles ADD COLUMN stoke_last TEXT;               -- UTC day of the last claim
ALTER TABLE profiles ADD COLUMN masterwork_pieces INTEGER NOT NULL DEFAULT 0;

-- A catch-up day played late: flat XP, and streaks ignore it.
ALTER TABLE daily_completions ADD COLUMN late INTEGER NOT NULL DEFAULT 0;

-- Work Orders. A player's rows for a day (`d:<date>`) or a week
-- (`w:<week>`) are made when something first needs them, from the
-- configured orders (src/rules/orders.ts); progress stops at the target.
-- Two more rows per day: slot 'swap' (kind = the slot swapped) once the
-- daily swap is used, and slot 'chest' (claimed = 1) once the chest is.
-- Rows older than 14 days are dropped as new ones are made.
CREATE TABLE work_orders (
  user_id  TEXT NOT NULL,
  period   TEXT NOT NULL,                    -- d:YYYY-MM-DD or w:YYYY-Www
  slot     TEXT NOT NULL,                    -- d0 d1 d2 w0 w1, or swap / chest
  kind     TEXT NOT NULL,
  target   INTEGER NOT NULL DEFAULT 0,
  progress INTEGER NOT NULL DEFAULT 0,
  letter   TEXT,                             -- letter_hunt only
  claimed  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, period, slot)
);

-- Weekly Trials: XP per player per ISO week, from every XP grant. Kept in
-- step by the trigger below, so anything that records XP in xp_events
-- (solo, daily, co-op, Versus, board rewards, Masterworks) counts, in the
-- same transaction, at the week the event was recorded.
CREATE TABLE weekly_xp (
  user_id TEXT NOT NULL,
  week    TEXT NOT NULL,                     -- YYYY-Www
  xp      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, week)
);

-- The ISO week of created_at: the year of that week's Thursday (the
-- following Sunday, less 3 days), and 1 + whole weeks from that year's
-- 1 January to the Thursday. src/rules/board.ts's isoWeek() is the same.
CREATE TRIGGER xp_events_weekly_xp AFTER INSERT ON xp_events WHEN NEW.amount > 0
BEGIN
  INSERT INTO weekly_xp (user_id, week, xp)
  VALUES (
    NEW.user_id,
    printf('%s-W%02d',
      strftime('%Y', date(NEW.created_at / 1000, 'unixepoch', 'weekday 0', '-3 days')),
      (CAST(strftime('%j', date(NEW.created_at / 1000, 'unixepoch', 'weekday 0', '-3 days')) AS INTEGER) - 1) / 7 + 1),
    NEW.amount)
  ON CONFLICT (user_id, week) DO UPDATE SET xp = xp + excluded.xp;
END;

-- Last week's Trials prizes claimed.
CREATE TABLE trial_claims (
  user_id    TEXT NOT NULL,
  week       TEXT NOT NULL,                  -- the week the prize was for, YYYY-Www
  claimed_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, week)
);

-- Gifts: a free Hammer Strike from a friend, one per sender, receiver and
-- UTC day. Collectable for 7 days; removing the friend leaves them.
CREATE TABLE gifts (
  id         INTEGER PRIMARY KEY,
  from_user  TEXT NOT NULL,
  to_user    TEXT NOT NULL,
  sent_date  TEXT NOT NULL,                  -- UTC day sent
  sent_at    INTEGER NOT NULL,               -- epoch ms
  claimed_at INTEGER,                        -- epoch ms, NULL while waiting
  UNIQUE (from_user, to_user, sent_date)
);
CREATE INDEX gifts_by_receiver ON gifts (to_user, claimed_at, sent_at);
