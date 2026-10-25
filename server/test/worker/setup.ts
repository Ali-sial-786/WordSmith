import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Runs before each test file. Already-applied migrations are skipped.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

// Load the campaign and the multiplayer bank (what `npm run db:seed:local` does for wrangler dev).
const loaded = await env.DB.prepare("SELECT COUNT(*) AS n FROM campaign").first<{ n: number }>();
if ((loaded?.n ?? 0) < env.TEST_CAMPAIGN.length) {
  const insert = env.DB.prepare("INSERT OR REPLACE INTO campaign (stage, puzzle_id, data) VALUES (?1, ?2, ?3)");
  for (let i = 0; i < env.TEST_CAMPAIGN.length; i += 100) {
    await env.DB.batch(env.TEST_CAMPAIGN.slice(i, i + 100).map((r) => insert.bind(r.stage, r.puzzleId, r.data)));
  }
}
const earlier = await env.DB.prepare("SELECT COUNT(*) AS n FROM campaign_previous").first<{ n: number }>();
if ((earlier?.n ?? 0) < env.TEST_CAMPAIGN_EARLIER.length) {
  const insert = env.DB.prepare("INSERT OR REPLACE INTO campaign_previous (edition, stage, puzzle_id, data) VALUES (?1, ?2, ?3, ?4)");
  for (let i = 0; i < env.TEST_CAMPAIGN_EARLIER.length; i += 100) {
    await env.DB.batch(env.TEST_CAMPAIGN_EARLIER.slice(i, i + 100).map((r) => insert.bind(r.edition, r.stage, r.puzzleId, r.data)));
  }
}
const banked = await env.DB.prepare("SELECT COUNT(*) AS n FROM puzzles WHERE pool = 'mp'").first<{ n: number }>();
if ((banked?.n ?? 0) < env.TEST_BANK.length) {
  const insert = env.DB.prepare("INSERT OR REPLACE INTO puzzles (id, pool, heat, size, letters, data) VALUES (?1, 'mp', ?2, ?3, ?4, ?5)");
  for (let i = 0; i < env.TEST_BANK.length; i += 100) {
    await env.DB.batch(env.TEST_BANK.slice(i, i + 100).map((r) => insert.bind(r.id, r.heat, r.size, r.letters, r.data)));
  }
}
