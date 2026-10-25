-- campaign_previous holds every earlier campaign edition, not just the last
-- one, so results played on any of them still count: apps that have an
-- older campaign built in, and results queued on a phone before it updated
-- (src/rules/campaign.ts editionFor tries the current puzzle, then the
-- earlier editions newest first). `edition` numbers them oldest first:
-- 1 is the campaign of app 0.8.0, 2 the one of 0.9.0.
-- Filled by scripts/build-campaign-sql.mjs (EARLIER_EDITIONS), which runs
-- after the migrations on every deploy.
CREATE TABLE campaign_editions (
  edition   INTEGER NOT NULL,
  stage     INTEGER NOT NULL,
  puzzle_id TEXT NOT NULL,                      -- c-NNNN
  data      TEXT NOT NULL,                      -- puzzle JSON incl. answers
  PRIMARY KEY (edition, stage)
);

-- The rows already loaded are the 0.8.0 campaign: keep them, so loading it
-- again writes nothing.
INSERT INTO campaign_editions (edition, stage, puzzle_id, data)
  SELECT 1, stage, puzzle_id, data FROM campaign_previous;

DROP TABLE campaign_previous;
ALTER TABLE campaign_editions RENAME TO campaign_previous;
