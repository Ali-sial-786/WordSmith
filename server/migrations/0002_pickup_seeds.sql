-- Pickup seeds used by a player's solo syncs (docs/TECH.md §8, shared/pickups.md).
--
-- Before an account exists the app seeds campaign pickups with a local
-- install id ("install-<32 hex>"), so queued results carry that id as
-- `pickupSeed`. The server accepts the account's own uid, or an install id
-- this account has used before, or a new one while the account has fewer
-- than MAX_INSTALL_SEEDS (src/rules/sync.ts). That stops a modified client
-- from trying fresh seeds until every puzzle has a pickup.
CREATE TABLE pickup_seeds (
  user_id       TEXT NOT NULL,
  seed          TEXT NOT NULL,
  first_used_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, seed)
);
