-- Wordsmith D1 schema, from docs/TECH.md §7.
-- Times are epoch milliseconds. JSON columns hold TEXT.
-- Apply with: npx wrangler d1 migrations apply wordsmith --local   (or --remote)

-- One row per Firebase account. username and avatar stay NULL until
-- POST /v1/me/setup; usernames are unique ignoring case.
CREATE TABLE users (
  id         TEXT PRIMARY KEY,                 -- Firebase uid
  username   TEXT UNIQUE COLLATE NOCASE,
  avatar     TEXT,
  created_at INTEGER NOT NULL
);

-- xp is the lifetime total; level is derived from it and stored for queries.
CREATE TABLE profiles (
  user_id        TEXT PRIMARY KEY,
  xp             INTEGER NOT NULL DEFAULT 0,
  level          INTEGER NOT NULL DEFAULT 1,
  campaign_stage INTEGER NOT NULL DEFAULT 0,   -- highest campaign stage completed (0 = none)
  scrap_bin      INTEGER NOT NULL DEFAULT 0,   -- bonus words towards the next Hammer Strike (0-9)
  updated_at     INTEGER NOT NULL
);

-- Hint stock. Never negative (TECH.md §8).
CREATE TABLE inventory (
  user_id TEXT NOT NULL,
  item    TEXT NOT NULL CHECK (item IN ('hammer', 'chisel', 'sparks')),
  count   INTEGER NOT NULL DEFAULT 0 CHECK (count >= 0),
  PRIMARY KEY (user_id, item)
);

CREATE TABLE stats (
  user_id       TEXT PRIMARY KEY,
  words_forged  INTEGER NOT NULL DEFAULT 0,
  longest_word  TEXT,
  solo_done     INTEGER NOT NULL DEFAULT 0,
  coop_rounds   INTEGER NOT NULL DEFAULT 0,
  coop_mvps     INTEGER NOT NULL DEFAULT 0,
  vs_series     INTEGER NOT NULL DEFAULT 0,
  vs_series_won INTEGER NOT NULL DEFAULT 0,
  vs_rounds_won INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE friends (
  user_id    TEXT NOT NULL,
  friend_id  TEXT NOT NULL,
  status     TEXT NOT NULL CHECK (status IN ('pending', 'accepted')),
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, friend_id)
);
CREATE INDEX friends_by_friend ON friends (friend_id);

-- Multiplayer puzzle bank. Answers never ship in the APK.
CREATE TABLE puzzles (
  id      TEXT PRIMARY KEY,                     -- m-NNNNN
  pool    TEXT NOT NULL DEFAULT 'mp',
  heat    INTEGER NOT NULL CHECK (heat BETWEEN 1 AND 6),
  size    INTEGER NOT NULL CHECK (size BETWEEN 1 AND 4),  -- players it's sized for; VS uses 1
  letters TEXT NOT NULL,
  data    TEXT NOT NULL                         -- puzzle JSON (shared/puzzle-format.md)
);
CREATE INDEX puzzles_by_heat_size ON puzzles (heat, size);

-- Campaign answers, for checking solo syncs.
CREATE TABLE campaign (
  stage     INTEGER PRIMARY KEY,
  puzzle_id TEXT NOT NULL,                      -- c-NNNN
  data      TEXT NOT NULL                       -- puzzle JSON incl. answers
);

-- Multiplayer puzzles each player has had, to skip ones seen in the last 60 days.
CREATE TABLE puzzle_seen (
  user_id   TEXT NOT NULL,
  puzzle_id TEXT NOT NULL,
  seen_at   INTEGER NOT NULL,
  PRIMARY KEY (user_id, puzzle_id)
);
CREATE INDEX puzzle_seen_by_user_time ON puzzle_seen (user_id, seen_at);

CREATE TABLE matches (
  id         TEXT PRIMARY KEY,
  mode       TEXT NOT NULL CHECK (mode IN ('coop', 'vs')),
  code       TEXT NOT NULL,                     -- room code
  started_at INTEGER NOT NULL,
  ended_at   INTEGER,
  summary    TEXT                               -- JSON
);

CREATE TABLE match_players (
  match_id   TEXT NOT NULL,
  user_id    TEXT NOT NULL,
  placement  INTEGER,
  points     INTEGER NOT NULL DEFAULT 0,
  rounds_won INTEGER NOT NULL DEFAULT 0,
  xp         INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (match_id, user_id)
);
CREATE INDEX match_players_by_user ON match_players (user_id);

CREATE TABLE xp_events (
  id         INTEGER PRIMARY KEY,
  user_id    TEXT NOT NULL,
  source     TEXT NOT NULL,                     -- e.g. solo, coop, vs
  amount     INTEGER NOT NULL,
  ref        TEXT,                              -- e.g. stage or match id
  created_at INTEGER NOT NULL
);
CREATE INDEX xp_events_by_user ON xp_events (user_id, created_at);

-- One row per campaign stage counted, so re-sent syncs are ignored.
CREATE TABLE solo_results (
  user_id      TEXT NOT NULL,
  stage        INTEGER NOT NULL,
  completed_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, stage)
);
