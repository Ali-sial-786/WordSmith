/** D1 queries for the `campaign` table (filled by scripts/build-campaign-sql.mjs). */

import { campaignPuzzle, puzzleStageFor, type CampaignPuzzle } from "../rules/campaign";

const ROWS_SQL = "SELECT stage, data FROM campaign WHERE stage IN (SELECT value FROM json_each(?1))";
const PREVIOUS_SQL = "SELECT stage, data FROM campaign_previous WHERE stage IN (SELECT value FROM json_each(?1))";

/**
 * The checking model for each of `stages` that has a puzzle: a campaign
 * stage's own, or for a Master Forge stage past the last one
 * (shared/master-forge.md), the campaign puzzle it plays again, keyed by
 * the Master Forge stage. The campaign's length is its last stage, since
 * stages run 1…N. Each carries the previous campaign's puzzle at that
 * stage too, where there is one (`campaign_previous`; rules/campaign.ts
 * `editionFor`).
 */
export async function loadCampaignPuzzles(db: D1Database, stages: readonly number[]): Promise<Map<number, CampaignPuzzle>> {
  const puzzles = new Map<number, CampaignPuzzle>();
  const wanted = [...new Set(stages)];
  if (wanted.length === 0) return puzzles;
  // Usually every stage is in the campaign, and this one round trip is all.
  const [last, direct] = await db.batch<{ n?: number; stage?: number; data?: string }>([
    db.prepare("SELECT COALESCE(MAX(stage), 0) AS n FROM campaign"),
    db.prepare(ROWS_SQL).bind(JSON.stringify(wanted)),
  ]);
  const n = last!.results[0]?.n ?? 0;
  const data = new Map(direct!.results.map((r) => [r.stage!, r.data!]));

  const master = new Map<number, number>();
  for (const s of wanted) {
    const base = puzzleStageFor(s, n);
    if (base !== null && base !== s) master.set(s, base);
  }
  const missing = [...new Set(master.values())].filter((b) => !data.has(b));
  if (missing.length > 0) {
    const { results } = await db.prepare(ROWS_SQL).bind(JSON.stringify(missing)).all<{ stage: number; data: string }>();
    for (const r of results) data.set(r.stage, r.data);
  }

  const bases = [...new Set(wanted.flatMap((s) => puzzleStageFor(s, n) ?? []))];
  const { results: prevRows } = await db.prepare(PREVIOUS_SQL).bind(JSON.stringify(bases)).all<{ stage: number; data: string }>();
  const previous = new Map(prevRows.map((r) => [r.stage, r.data]));

  for (const s of wanted) {
    const base = puzzleStageFor(s, n);
    const json = base === null ? undefined : data.get(base);
    const prev = base === null ? undefined : previous.get(base);
    if (json !== undefined) puzzles.set(s, campaignPuzzle(s, JSON.parse(json), prev === undefined ? undefined : JSON.parse(prev)));
  }
  return puzzles;
}

/** Number of campaign stages loaded. 0 means the table was never seeded. */
export async function campaignStageCount(db: D1Database): Promise<number> {
  const row = await db.prepare("SELECT COUNT(*) AS n FROM campaign").first<{ n: number }>();
  return row?.n ?? 0;
}
