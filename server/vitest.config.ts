import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  // Read in Node, then handed to the Worker tests as a binding (see test/worker/setup.ts).
  const migrations = await readD1Migrations(new URL("./migrations", import.meta.url).pathname);

  return {
    test: {
      projects: [
        {
          // Pure game rules: plain unit tests in Node.
          test: {
            name: "rules",
            include: ["test/rules/**/*.test.ts"],
            environment: "node",
          },
        },
        {
          // The Worker itself, in the real workerd runtime with a local D1.
          plugins: [
            cloudflareTest({
              wrangler: { configPath: "./wrangler.jsonc" },
              miniflare: { bindings: { TEST_MIGRATIONS: migrations } },
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
