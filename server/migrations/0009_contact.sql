-- The contact form on the web pages (shared/contact.md). Times are epoch ms.
-- Messages aren't tied to an account; the hourly cron forgets each one's
-- ip_hash after a day and deletes messages after a year (src/contact/upkeep.ts).

CREATE TABLE contact_messages (
  id             INTEGER PRIMARY KEY,
  topic          TEXT NOT NULL,              -- account, deletion, bug, player, privacy, feedback or other
  message        TEXT NOT NULL,              -- trimmed, at most 2000 characters
  email          TEXT,                       -- where to reply, if they gave one
  username       TEXT,                       -- their Wordsmith username, as they typed it, if given
  ip_hash        TEXT,                       -- SHA-256 of the sender's IP, for the per-hour limit; NULL after a day
  created_at     INTEGER NOT NULL,
  emailed_at     INTEGER,                    -- when it was forwarded to the developer's inbox; NULL until then
  email_attempts INTEGER NOT NULL DEFAULT 0, -- forwarding tries so far (the cron gives up after a few)
  status         TEXT NOT NULL DEFAULT 'open'
);
CREATE INDEX contact_by_ip ON contact_messages (ip_hash, created_at);
CREATE INDEX contact_by_time ON contact_messages (created_at);
CREATE INDEX contact_unsent ON contact_messages (emailed_at, created_at);
