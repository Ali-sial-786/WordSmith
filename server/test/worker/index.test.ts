import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const BASE = "https://api.test";

function get(path: string, init?: RequestInit): Promise<Response> {
  return exports.default.fetch(new Request(BASE + path, init));
}

describe("routes", () => {
  it("GET /v1/version returns the versions from wrangler vars", async () => {
    const res = await get("/v1/version");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toMatch(/^application\/json/);
    expect(await res.json()).toEqual({
      latest: "0.6.0",
      minSupported: "0.1.0",
      protocol: 1,
      apk: "https://github.com/Ali-sial-786/WordSmith/releases/download/v0.6.0/wordsmith-0.6.0.apk",
    });
  });

  it("GET /v1/health is ok", async () => {
    const res = await get("/v1/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });

  it.each(["/", "/v1", "/v1/nope", "/v1/version/", "/version", "/v1/toString", "/v1/__proto__"])(
    "unknown route %s is a JSON 404",
    async (path) => {
      const res = await get(path);
      expect(res.status).toBe(404);
      expect(await res.json()).toEqual({ error: "not_found" });
    },
  );

  it.each(["POST", "PUT", "DELETE"])("a known route with method %s is a 405", async (method) => {
    const res = await get("/v1/version", { method });
    expect(res.status).toBe(405);
    expect(res.headers.get("allow")).toBe("GET");
    expect(await res.json()).toEqual({ error: "method_not_allowed" });
  });
});

describe("D1 schema", () => {
  const TABLES = [
    "blocks",
    "campaign",
    "daily_completions",
    "friends",
    "gifts",
    "inventory",
    "match_players",
    "matches",
    "pickup_seeds",
    "profiles",
    "push_tokens",
    "puzzle_seen",
    "puzzles",
    "reports",
    "solo_results",
    "stats",
    "survival_best",
    "survival_runs",
    "trial_claims",
    "users",
    "weekly_xp",
    "work_orders",
    "xp_events",
  ];

  it("has every table from TECH.md §7, plus pickup_seeds, daily_completions, push_tokens, the Forge Board's, Survival's, and blocks and reports", async () => {
    const { results } = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'd1_%' AND name NOT LIKE '_cf_%' ORDER BY name",
    ).all<{ name: string }>();
    expect(results.map((r) => r.name)).toEqual(TABLES);
  });

  it("stores and reads back a user with a profile and hints", async () => {
    const now = Date.now();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO users (id, username, avatar, created_at) VALUES (?, ?, ?, ?)").bind("uid-1", "Ali", "anvil", now),
      env.DB.prepare("INSERT INTO profiles (user_id, updated_at) VALUES (?, ?)").bind("uid-1", now),
      env.DB.prepare("INSERT INTO inventory (user_id, item, count) VALUES (?, 'hammer', 3)").bind("uid-1"),
    ]);
    const row = await env.DB.prepare(
      `SELECT u.username, p.xp, p.level, p.scrap_bin, i.count AS hammers
         FROM users u JOIN profiles p ON p.user_id = u.id JOIN inventory i ON i.user_id = u.id AND i.item = 'hammer'
        WHERE u.username = ?`,
    )
      .bind("ali") // usernames compare case-insensitively
      .first();
    expect(row).toEqual({ username: "Ali", xp: 0, level: 1, scrap_bin: 0, hammers: 3 });
  });

  it("rejects a duplicate username that differs only in case", async () => {
    await env.DB.prepare("INSERT INTO users (id, username, created_at) VALUES ('uid-a', 'Sam', 0)").run();
    await expect(env.DB.prepare("INSERT INTO users (id, username, created_at) VALUES ('uid-b', 'SAM', 0)").run()).rejects.toThrow(
      /UNIQUE/,
    );
  });

  it("never lets a hint count go below zero", async () => {
    await env.DB.prepare("INSERT INTO inventory (user_id, item, count) VALUES ('uid-1', 'chisel', 0)").run();
    await expect(
      env.DB.prepare("UPDATE inventory SET count = count - 1 WHERE user_id = 'uid-1' AND item = 'chisel'").run(),
    ).rejects.toThrow(/CHECK/);
  });
});
