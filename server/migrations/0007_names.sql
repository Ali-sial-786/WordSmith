-- Changing your username (POST /v1/me/username) and nicknames for friends
-- (PUT /v1/friends/:id/nickname). Times are epoch ms.

-- When the username last changed, or NULL if it hasn't since setup. A
-- change is allowed once every 7 days (src/account/username.ts); the first
-- is allowed straight away.
ALTER TABLE users ADD COLUMN username_changed_at INTEGER;

-- The nickname user_id gave friend_id: shown only to user_id, instead of
-- friend_id's username. Only set on accepted rows, so it goes with the
-- friendship (and with either account).
ALTER TABLE friends ADD COLUMN nickname TEXT;
