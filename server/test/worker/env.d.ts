import type { Env as WorkerEnv } from "../../src/env";

declare global {
  namespace Cloudflare {
    interface Env extends WorkerEnv {
      /** Migrations from migrations/, injected by vitest.config.ts. */
      TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
    }
    interface GlobalProps {
      /** Types `exports` from "cloudflare:workers". */
      mainModule: typeof import("../../src/index");
    }
  }
}
