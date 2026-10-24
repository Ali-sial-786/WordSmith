import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
import { loadBankRows } from "./scripts/build-bank-sql.mjs";
import { loadCampaignRows, loadPreviousCampaignRows } from "./scripts/build-campaign-sql.mjs";

export default defineConfig(async () => {
  // Read in Node, then handed to the Worker tests as bindings (see test/worker/setup.ts).
  const migrations = await readD1Migrations(new URL("./migrations", import.meta.url).pathname);
  // The real campaign from app/assets/campaign/campaign.json, for sync tests.
  const campaign = loadCampaignRows();
  // The campaign before it (data/campaign_previous.json), whose results still count.
  const campaignPrevious = loadPreviousCampaignRows();
  // The multiplayer bank from data/mp_bank.json, for room tests.
  const bank = loadBankRows();

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
              miniflare: {
                bindings: {
                  TEST_MIGRATIONS: migrations,
                  TEST_CAMPAIGN: campaign,
                  TEST_CAMPAIGN_PREVIOUS: campaignPrevious,
                  TEST_BANK: bank,
                  // A made-up LiveKit project, so the video route can sign tokens.
                  LIVEKIT_URL: "wss://wordsmith-test.livekit.cloud",
                  LIVEKIT_API_KEY: "APItestkey",
                  LIVEKIT_API_SECRET: "test-secret-that-is-long-enough-for-hs256",
                },
              },
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
