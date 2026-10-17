import type { Env as WorkerEnv } from "../../src/env";

declare global {
  namespace Cloudflare {
    interface Env extends WorkerEnv {
      /** Migrations from migrations/, injected by vitest.config.ts. */
      TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
      /** Campaign rows from app/assets/campaign/campaign.json (scripts/build-campaign-sql.mjs). */
      TEST_CAMPAIGN: { stage: number; puzzleId: string; data: string }[];
    }
    interface GlobalProps {
      /** Types `exports` from "cloudflare:workers". */
      mainModule: typeof import("../../src/index");
    }
  }
}
