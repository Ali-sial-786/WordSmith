import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Runs before each test file. Already-applied migrations are skipped.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

// Load the campaign (what `npm run db:seed:local` does for wrangler dev).
const loaded = await env.DB.prepare("SELECT COUNT(*) AS n FROM campaign").first<{ n: number }>();
if ((loaded?.n ?? 0) < env.TEST_CAMPAIGN.length) {
  const insert = env.DB.prepare("INSERT OR REPLACE INTO campaign (stage, puzzle_id, data) VALUES (?1, ?2, ?3)");
  for (let i = 0; i < env.TEST_CAMPAIGN.length; i += 100) {
    await env.DB.batch(env.TEST_CAMPAIGN.slice(i, i + 100).map((r) => insert.bind(r.stage, r.puzzleId, r.data)));
  }
}
