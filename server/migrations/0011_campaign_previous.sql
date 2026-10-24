-- The campaign before the current one, stage by stage, so results played on
-- it still count: apps that have the old campaign built in, and results
-- queued on a phone before it updated (src/rules/campaign.ts editionFor).
-- Filled by scripts/build-campaign-sql.mjs from data/campaign_previous.json.
CREATE TABLE campaign_previous (
  stage     INTEGER PRIMARY KEY,
  puzzle_id TEXT NOT NULL,                      -- c-NNNN
  data      TEXT NOT NULL                       -- puzzle JSON incl. answers
);
