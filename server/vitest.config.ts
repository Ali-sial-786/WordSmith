import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
// @ts-expect-error -- plain .mjs script, no type declarations
import { loadCampaignRows } from "./scripts/build-campaign-sql.mjs";

export default defineConfig(async () => {
  // Read in Node, then handed to the Worker tests as bindings (see test/worker/setup.ts).
  const migrations = await readD1Migrations(new URL("./migrations", import.meta.url).pathname);
  // The real campaign from app/assets/campaign/campaign.json, for sync tests.
  const campaign = loadCampaignRows();

  return {
    test: {
      projects: [
        {
          // Pure game rules and helpers: plain unit tests in Node.
          test: {
            name: "rules",
            include: ["test/rules/**/*.test.ts", "test/unit/**/*.test.ts"],
            environment: "node",
          },
        },
        {
          // The Worker itself, in the real workerd runtime with a local D1.
          plugins: [
            cloudflareTest({
              wrangler: { configPath: "./wrangler.jsonc" },
              miniflare: { bindings: { TEST_MIGRATIONS: migrations, TEST_CAMPAIGN: campaign } },
            }),
          ],
          test: {
            name: "worker",
            include: ["test/worker/**/*.test.ts"],
            setupFiles: ["./test/worker/setup.ts"],
          },
        },
      ],
    },
  };
});
