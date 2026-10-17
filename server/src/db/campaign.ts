/** D1 queries for the `campaign` table (filled by scripts/build-campaign-sql.mjs). */

import { campaignPuzzle, type CampaignPuzzle } from "../rules/campaign";

/** The checking model for each of `stages` that's in the campaign table. */
export async function loadCampaignPuzzles(db: D1Database, stages: readonly number[]): Promise<Map<number, CampaignPuzzle>> {
  const puzzles = new Map<number, CampaignPuzzle>();
  if (stages.length === 0) return puzzles;
  const { results } = await db
    .prepare("SELECT stage, data FROM campaign WHERE stage IN (SELECT value FROM json_each(?1))")
    .bind(JSON.stringify([...new Set(stages)]))
    .all<{ stage: number; data: string }>();
  for (const row of results) puzzles.set(row.stage, campaignPuzzle(row.stage, JSON.parse(row.data)));
  return puzzles;
}

/** Number of campaign stages loaded. 0 means the table was never seeded. */
export async function campaignStageCount(db: D1Database): Promise<number> {
  const row = await db.prepare("SELECT COUNT(*) AS n FROM campaign").first<{ n: number }>();
  return row?.n ?? 0;
}
