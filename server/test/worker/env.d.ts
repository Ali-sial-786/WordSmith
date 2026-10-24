import type { Env as WorkerEnv } from "../../src/env";

declare global {
  namespace Cloudflare {
    interface Env extends WorkerEnv {
      /** Migrations from migrations/, injected by vitest.config.ts. */
      TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
      /** Campaign rows from app/assets/campaign/campaign.json (scripts/build-campaign-sql.mjs). */
      TEST_CAMPAIGN: { stage: number; puzzleId: string; data: string }[];
      /** The previous campaign's rows, from data/campaign_previous.json. */
      TEST_CAMPAIGN_PREVIOUS: { stage: number; puzzleId: string; data: string }[];
      /** Multiplayer bank rows from data/mp_bank.json (scripts/build-bank-sql.mjs). */
      TEST_BANK: { id: string; heat: number; size: number; letters: string; data: string }[];
    }
    interface GlobalProps {
      /** Types `exports` from "cloudflare:workers". */
      mainModule: typeof import("../../src/index");
    }
  }
}
