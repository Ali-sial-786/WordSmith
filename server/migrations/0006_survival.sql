-- Survival's solo mode, The Crucible (shared/survival.md): the runs each
-- player has sent, so a run sent again answers as a duplicate, and each
-- player's best run (most puzzles cleared, then most words, then most
-- saved), which the profile shows as `survivalBest`. Times are epoch ms.
-- Deleting an account deletes its rows in both (src/db/accounts.ts).

CREATE TABLE survival_runs (
  uid     TEXT NOT NULL,
  run_id  TEXT NOT NULL,                     -- the app's runId
  at      INTEGER NOT NULL,                  -- when the run ended (endedAt)
  puzzles INTEGER NOT NULL,                  -- puzzles cleared
  words   INTEGER NOT NULL,                  -- grid words found
  saved   INTEGER NOT NULL,                  -- heated words saved
  xp      INTEGER NOT NULL,                  -- XP granted
  PRIMARY KEY (uid, run_id)
);

CREATE TABLE survival_best (
  uid     TEXT PRIMARY KEY,
  puzzles INTEGER NOT NULL,
  words   INTEGER NOT NULL,
  saved   INTEGER NOT NULL,
  at      INTEGER NOT NULL                   -- when that run ended
);
