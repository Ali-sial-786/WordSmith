-- Blocking and reporting (shared/safety.md). Times are epoch ms.
-- Deleting an account deletes its rows in both: its blocks either way, and
-- every report it made or that was made about it (src/db/accounts.ts).

-- user_id has blocked blocked_id. Only user_id ever reads the row; the
-- blocked player isn't told.
CREATE TABLE blocks (
  user_id    TEXT NOT NULL,
  blocked_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, blocked_id)
);
CREATE INDEX blocks_by_blocked ON blocks (blocked_id);

-- One row per report, for whoever reviews them. Nothing here is ever sent
-- to the reported player.
CREATE TABLE reports (
  id                INTEGER PRIMARY KEY,
  reporter_id       TEXT NOT NULL,
  reported_id       TEXT NOT NULL,
  reported_username TEXT NOT NULL,           -- their username when reported
  reason            TEXT NOT NULL,           -- harassment, hate, sexual, name, cheating, spam or other
  details           TEXT,                    -- trimmed, at most 500 characters; NULL for none
  room              TEXT,                    -- the room code, or NULL
  lines             TEXT NOT NULL,           -- JSON [{id, text, at}]: their chat lines as the reporter saw them
  created_at        INTEGER NOT NULL,
  status            TEXT NOT NULL DEFAULT 'open'
);
CREATE INDEX reports_by_status ON reports (status, created_at);
CREATE INDEX reports_by_reporter ON reports (reporter_id, created_at);
