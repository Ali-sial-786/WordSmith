-- FCM registration tokens for invite notifications (shared/push.md).
--
-- A token belongs to one account: registering it again, from any account,
-- replaces its row (INSERT OR REPLACE), which moves it there and gives it a
-- new, higher id. So within an account the highest ids are the most recently
-- registered, and src/db/push.ts keeps the newest MAX_PUSH_TOKENS of them.
-- Deleting an account deletes its rows (src/db/accounts.ts).
CREATE TABLE push_tokens (
  id            INTEGER PRIMARY KEY,
  token         TEXT NOT NULL UNIQUE,
  user_id       TEXT NOT NULL,
  registered_at INTEGER NOT NULL               -- epoch ms
);
CREATE INDEX push_tokens_by_user ON push_tokens (user_id, id);
