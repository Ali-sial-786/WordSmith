-- Daily Commission completions (shared/daily.md): one row per player per
-- UTC day completed. Streaks are counted from these rows. Deleting an
-- account deletes its rows (src/db/accounts.ts).
CREATE TABLE daily_completions (
  user_id      TEXT NOT NULL,
  date         TEXT NOT NULL,                  -- UTC day, YYYY-MM-DD
  completed_at INTEGER NOT NULL,               -- epoch ms
  xp           INTEGER NOT NULL,               -- XP granted
  PRIMARY KEY (user_id, date)
);
