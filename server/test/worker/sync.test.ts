import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { ensureAccount, loadAccount } from "../../src/db/accounts";
import { loadCampaignPuzzles } from "../../src/db/campaign";
import { loadSoloState, writeSync } from "../../src/db/sync";
import { campaignPuzzle } from "../../src/rules/campaign";
import { pickupsFor } from "../../src/rules/pickups";
import { evaluateSync, MAX_SYNC_ENTRIES } from "../../src/rules/sync";
import { body, client, request, setUpClient, type Client } from "./helpers";

interface PuzzleJson {
  id: string;
  words: { w: string }[];
  bonus: string[];
}

function puzzle(stage: number): PuzzleJson {
  return JSON.parse(env.TEST_CAMPAIGN[stage - 1]!.data) as PuzzleJson;
}

const T0 = Date.now() - 24 * 3600 * 1000;

/** A queue entry for `stage` that the server should accept: every grid word typed, no hints. */
function entry(stage: number, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const p = puzzle(stage);
  return {
    stage,
    puzzleId: p.id,
    foundWords: p.words.map((w) => w.w),
    bonusWords: [],
    hintsUsed: {},
    pickups: [],
    durationMs: 60_000,
    completedAt: T0 + stage * 60_000,
    ...overrides,
  };
}

interface SyncBody {
  profile: Record<string, any>;
  results: Record<string, any>[];
}

async function sync(c: Client, entries: unknown[]): Promise<SyncBody> {
  const res = await c.post("/v1/solo/sync", { entries });
  expect(res.status, await res.clone().text()).toBe(200);
  return body<SyncBody>(res);
}

describe("POST /v1/solo/sync: accepting", () => {
  it("counts a forged puzzle: XP, campaign progress, stats, and the rows behind them", async () => {
    const c = await client();
    const p = puzzle(1);
    const out = await sync(c, [entry(1, { bonusWords: p.bonus.slice(0, 2) })]);
    expect(out.results).toEqual([
      {
        stage: 1,
        accepted: true,
        xp: 12,
        levelUps: 0,
        level: 1,
        rewards: { hammer: 0, chisel: 0, sparks: 0 },
        scrapHammers: 0,
        pickups: [],
        pickupsRejected: 0,
      },
    ]);
    const longest = p.words.map((w) => w.w).reduce((a, b) => (b.length > a.length ? b : a));
    expect(out.profile).toMatchObject({
      id: c.uid,
      totalXp: 12,
      campaignCompleted: 1,
      nextStage: 2,
      scrapBin: 2,
      hints: { hammer: 3, chisel: 0, sparks: 0 },
      stats: { wordsForged: p.words.length, longestWord: longest, soloDone: 1 },
    });
    // GET /v1/me agrees.
    expect(await body(await c.get("/v1/me"))).toMatchObject({ totalXp: 12, campaignCompleted: 1, nextStage: 2, scrapBin: 2 });

    const done = await env.DB.prepare("SELECT stage, completed_at FROM solo_results WHERE user_id = ?").bind(c.uid).all();
    expect(done.results).toEqual([{ stage: 1, completed_at: T0 + 60_000 }]);
    const xp = await env.DB.prepare("SELECT source, amount, ref FROM xp_events WHERE user_id = ?").bind(c.uid).all();
    expect(xp.results).toEqual([{ source: "solo", amount: 12, ref: "c-0001" }]);
  });

  it("caps bonus XP at +5 and smelts every 10 bonus words into a Hammer Strike", async () => {
    const c = await client();
    const p = puzzle(33); // 14 bonus words
    const out = await sync(c, [entry(33, { bonusWords: p.bonus.slice(0, 12) })]);
    expect(out.results[0]).toMatchObject({ accepted: true, xp: 15, scrapHammers: 1 });
    expect(out.profile).toMatchObject({ totalXp: 15, scrapBin: 2, hints: { hammer: 4 }, campaignCompleted: 33, nextStage: 34 });
  });

  it("accepts words lower-case and repeated, counting each once", async () => {
    const c = await client();
    const p = puzzle(1);
    const words = p.words.map((w) => w.w.toLowerCase());
    const out = await sync(c, [entry(1, { foundWords: [...words, ...words], bonusWords: [p.bonus[0], p.bonus[0]] })]);
    expect(out.results[0]).toMatchObject({ accepted: true, xp: 11 });
    expect(out.profile).toMatchObject({ scrapBin: 1, stats: { wordsForged: p.words.length } });
  });

  it("applies entries in completedAt order and grants level-up rewards", async () => {
    const c = await client();
    // 6 puzzles × 10 XP = 60 XP = level 2. Sent out of order.
    const entries = [3, 1, 6, 2, 5, 4].map((s) => entry(s));
    const out = await sync(c, entries);
    expect(out.results.map((r) => r.stage)).toEqual([3, 1, 6, 2, 5, 4]); // input order
    expect(out.results.every((r) => r.accepted)).toBe(true);
    const sixth = out.results[2]!;
    expect(sixth).toMatchObject({ stage: 6, levelUps: 1, level: 2, rewards: { hammer: 1, chisel: 0, sparks: 0 } });
    expect(out.results.filter((r) => r.levelUps > 0)).toHaveLength(1);
    expect(out.profile).toMatchObject({ totalXp: 60, level: 2, rank: "Apprentice", hints: { hammer: 4 }, campaignCompleted: 6 });
  });

  it("takes off hints used, and accepts words the hints completed", async () => {
    const c = await client();
    // Stage 2 is MAIN, MAN, AIM; leaving out MAN leaves one cell only a hint could show.
    const p = puzzle(2);
    expect(p.words.map((w) => w.w)).toContain("MAN");
    const out = await sync(c, [entry(2, { foundWords: ["MAIN", "AIM"], hintsUsed: { hammer: 1 } })]);
    expect(out.results[0]).toMatchObject({ accepted: true, xp: 10 });
    expect(out.results[0]).not.toHaveProperty("hintsClamped");
    expect(out.profile).toMatchObject({ hints: { hammer: 2 }, stats: { wordsForged: 2 } });
  });

  it("never lets hint stock go below zero, and says by how much it clamped", async () => {
    const c = await client();
    const out = await sync(c, [entry(1, { hintsUsed: { hammer: 5, chisel: 1 } })]);
    expect(out.results[0]).toMatchObject({ accepted: true, hintsClamped: { hammer: 2, chisel: 1, sparks: 0 } });
    expect(out.profile.hints).toEqual({ hammer: 0, chisel: 0, sparks: 0 });
  });
});

describe("POST /v1/solo/sync: rejecting", () => {
  it.each<[string, (e: Record<string, unknown>) => Record<string, unknown>, string]>([
    ["a stage that isn't in the campaign", (e) => ({ ...e, stage: 9999, puzzleId: "c-9999" }), "unknown_stage"],
    ["the wrong puzzle for the stage", (e) => ({ ...e, puzzleId: "c-0002" }), "puzzle_mismatch"],
    ["a word that isn't in the grid", (e) => ({ ...e, foundWords: [...(e.foundWords as string[]), "ZZZ"] }), "unknown_word"],
    ["a non-word", (e) => ({ ...e, foundWords: ["FE-AR"] }), "unknown_word"],
    ["a bonus word that isn't in the list", (e) => ({ ...e, bonusWords: ["QQQ"] }), "unknown_bonus_word"],
    ["a grid word claimed as bonus", (e) => ({ ...e, bonusWords: [(e.foundWords as string[])[0]] }), "unknown_bonus_word"],
    ["missing words with no hints to explain them", (e) => ({ ...e, foundWords: (e.foundWords as string[]).slice(1) }), "incomplete"],
    ["too fast", (e) => ({ ...e, durationMs: 1_000 }), "too_fast"],
    ["completed in the future", (e) => ({ ...e, completedAt: Date.now() + 3600_000 }), "bad_completed_at"],
    ["completed before the game existed", (e) => ({ ...e, completedAt: 1_000 }), "bad_completed_at"],
  ])("rejects %s", async (_, change, reason) => {
    const c = await client();
    const out = await sync(c, [change(entry(1))]);
    expect(out.results[0]).toMatchObject({ accepted: false, reason, xp: 0, levelUps: 0 });
    expect(out.profile).toMatchObject({ totalXp: 0, campaignCompleted: 0, hints: { hammer: 3 } });
  });

  it.each<[string, unknown, string]>([
    ["not an object", 7, "entry is not an object"],
    ["no stage", { ...entry(1), stage: undefined }, "stage"],
    ["no foundWords", { ...entry(1), foundWords: undefined }, "foundWords"],
    ["negative hint use", { ...entry(1), hintsUsed: { hammer: -1 } }, "hintsUsed.hammer"],
    ["a bad pickup", { ...entry(1), pickups: [{ cell: 0, kind: "gold" }] }, "pickups"],
    ["no durationMs", { ...entry(1), durationMs: "60s" }, "durationMs"],
  ])("marks an entry with %s as invalid_entry", async (_, raw, detail) => {
    const c = await client();
    const out = await sync(c, [raw]);
    expect(out.results[0]).toMatchObject({ accepted: false, reason: "invalid_entry", detail });
  });

  it("counts a stage once, within a batch and across syncs", async () => {
    const c = await client();
    const first = await sync(c, [entry(1), entry(1, { completedAt: T0 + 999_000 })]);
    expect(first.results.map((r) => [r.accepted, r.reason])).toEqual([
      [true, undefined],
      [false, "duplicate"],
    ]);
    const again = await sync(c, [entry(1), entry(2)]);
    expect(again.results.map((r) => [r.stage, r.accepted, r.reason])).toEqual([
      [1, false, "duplicate"],
      [2, true, undefined],
    ]);
    expect(again.profile).toMatchObject({ totalXp: 20, stats: { soloDone: 2 } });
  });

  it("rejects bad bodies as a whole", async () => {
    const c = await client();
    for (const [payload, error] of [
      [{}, "invalid_body"],
      [{ entries: "x" }, "invalid_body"],
      [[entry(1)], "invalid_body"],
      [{ entries: Array.from({ length: MAX_SYNC_ENTRIES + 1 }, (_, i) => entry(1 + (i % 50))) }, "too_many_entries"],
    ] as const) {
      const res = await c.post("/v1/solo/sync", payload);
      expect(res.status).toBe(400);
      expect(await body(res)).toMatchObject({ error });
    }
  });

  it("accepts an empty batch and just returns the profile", async () => {
    const c = await client();
    const out = await sync(c, []);
    expect(out).toMatchObject({ results: [], profile: { id: c.uid, totalXp: 0 } });
  });
});

describe("POST /v1/solo/sync: pickups", () => {
  it("grants a pickup from the shared vectors (user-123, c-0012, 9 cells → cell 0, hammer)", async () => {
    // shared/pickups.md lists this at level 50; a Hammer Strike is a Hammer Strike at any level.
    expect(campaignPuzzle(12, puzzle(12)).cellCount).toBe(9);
    const c = await client("user-123");
    await c.del("/v1/me"); // in case another run left this fixed uid behind
    const out = await sync(c, [entry(12, { pickups: [{ cell: 0, kind: "hammer" }] })]);
    expect(out.results[0]).toMatchObject({ accepted: true, pickups: [{ cell: 0, kind: "hammer" }], pickupsRejected: 0 });
    expect(out.profile.hints).toMatchObject({ hammer: 4 });
    await c.del("/v1/me");
  });

  it("doesn't grant pickups the server can't reproduce, but still counts the puzzle", async () => {
    const c = await client("user-123-other");
    const out = await sync(c, [entry(12, { pickups: [{ cell: 0, kind: "hammer" }] })]);
    expect(pickupsFor(c.uid, "c-0012", 9, 1)).toEqual([]);
    expect(out.results[0]).toMatchObject({ accepted: true, pickups: [], pickupsRejected: 1 });
    expect(out.profile.hints).toMatchObject({ hammer: 3 });
  });

  it("checks pickups against the install id they were seeded with, and remembers it", async () => {
    const c = await client();
    const seed = "install-0123456789abcdef0123456789abcdef";
    const expected = pickupsFor(seed, "c-0027", campaignPuzzle(27, puzzle(27)).cellCount, 1);
    expect(expected).toHaveLength(2);
    const claims = expected.map((p) => ({ cell: p.index, kind: p.kind }));
    const out = await sync(c, [entry(27, { pickupSeed: seed, pickups: claims })]);
    expect(out.results[0]).toMatchObject({ accepted: true, pickups: claims, pickupsRejected: 0 });
    expect(out.profile.hints).toMatchObject({ hammer: 5 });
    const seeds = await env.DB.prepare("SELECT seed FROM pickup_seeds WHERE user_id = ?").bind(c.uid).all();
    expect(seeds.results).toEqual([{ seed }]);
  });

  it("refuses a pickup seed that is neither the uid nor an install id", async () => {
    const c = await client();
    const out = await sync(c, [entry(12, { pickupSeed: "user-123", pickups: [{ cell: 0, kind: "hammer" }] })]);
    expect(out.results[0]).toMatchObject({ accepted: true, pickups: [], pickupsRejected: 1 });
  });
});

describe("POST /v1/solo/sync: concurrency", () => {
  it("counts a stage once when the same sync arrives twice at the same time", async () => {
    const c = await client();
    await c.get("/v1/me");
    const send = () => c.post("/v1/solo/sync", { entries: [entry(1), entry(2)] });
    const responses = await Promise.all([send(), send()]);
    const accepted = (await Promise.all(responses.map((r) => r.json() as Promise<SyncBody>)))
      .flatMap((b) => b.results)
      .filter((r) => r.accepted);
    expect(accepted).toHaveLength(2);
    const me = await body(await c.get("/v1/me"));
    expect(me).toMatchObject({ totalXp: 20, stats: { soloDone: 2 } });
  });
});

describe("writeSync", () => {
  it("writes nothing if the profile changed since it was read", async () => {
    const c = await client();
    const now = Date.now();
    const stale = await ensureAccount(env.DB, c.uid, now);
    const puzzles = await loadCampaignPuzzles(env.DB, [1]);
    const outcome = evaluateSync({ uid: c.uid, now, state: await loadSoloState(env.DB, stale, [1]), entries: [entry(1)], puzzles });
    expect(outcome.accepted).toHaveLength(1);

    // Something else writes the profile in between.
    await env.DB.prepare("UPDATE profiles SET xp = 5, updated_at = updated_at + 1 WHERE user_id = ?").bind(c.uid).run();
    expect(await writeSync(env.DB, stale, outcome, now)).toBe(false);

    const after = (await loadAccount(env.DB, c.uid))!;
    expect(after).toMatchObject({ totalXp: 5, campaignCompleted: 0, hints: { hammer: 3 } });
    const rows = await env.DB.prepare(
      "SELECT (SELECT COUNT(*) FROM solo_results WHERE user_id = ?1) + (SELECT COUNT(*) FROM xp_events WHERE user_id = ?1) AS n",
    )
      .bind(c.uid)
      .first<{ n: number }>();
    expect(rows?.n).toBe(0);

    // With the current version it goes through.
    expect(await writeSync(env.DB, after, outcome, now)).toBe(true);
  });
});

describe("POST /v1/solo/sync: auth", () => {
  it("needs a token", async () => {
    const res = await request("/v1/solo/sync", { method: "POST", body: JSON.stringify({ entries: [] }) });
    expect(res.status).toBe(401);
  });
});

describe("POST /v1/solo/sync: the Master Forge (shared/master-forge.md)", () => {
  const N = env.TEST_CAMPAIGN.length;
  /** Master Forge stage `s`, playing campaign stage `b`'s puzzle. */
  const master = (s: number, b: number, extra: Record<string, unknown> = {}) => ({ ...entry(b), stage: s, completedAt: T0 + (s % 1000) * 1000, ...extra });

  it("loads the campaign puzzle each stage past the last one plays", async () => {
    const puzzles = await loadCampaignPuzzles(env.DB, [N + 1, 1, 2 * N + 5, 10 * N, 10 * N + 1]);
    expect([...puzzles.keys()].sort((x, y) => x - y)).toEqual([1, N + 1, 2 * N + 5, 10 * N]);
    expect(puzzles.get(N + 1)).toMatchObject({ stage: N + 1, id: "c-0001" });
    expect(puzzles.get(2 * N + 5)!.id).toBe("c-0005");
    expect(puzzles.get(10 * N)!.id).toBe(puzzle(N).id);
    expect(puzzles.get(N + 1)!.gridWords).toEqual(puzzles.get(1)!.gridWords);
  });

  it("counts stages past the last like campaign stages, each once, up to 10 times the campaign", async () => {
    const c = await setUpClient();
    const p1 = puzzle(1);
    const out = await sync(c, [
      master(N + 1, 1, { bonusWords: p1.bonus.slice(0, 2) }),
      master(N + 2, 1), // stage N + 2 plays stage 2's puzzle, not stage 1's
      master(2 * N + 1, 1),
      master(10 * N, N),
      master(10 * N + 1, 1),
    ]);
    expect(out.results.map((r) => [r.stage, r.accepted, r.reason, r.xp])).toEqual([
      [N + 1, true, undefined, 12],
      [N + 2, false, "puzzle_mismatch", 0],
      [2 * N + 1, true, undefined, 10],
      [10 * N, true, undefined, 10],
      [10 * N + 1, false, "unknown_stage", 0],
    ]);
    expect(out.profile).toMatchObject({ totalXp: 32, campaignCompleted: 10 * N, nextStage: 10 * N + 1, scrapBin: 2, stats: { soloDone: 3 } });
    expect((await sync(c, [master(N + 1, 1)])).results[0]).toMatchObject({ accepted: false, reason: "duplicate" });

    // Work Orders count them as campaign puzzles.
    const board = await body<Record<string, any>>(await c.get("/v1/me/board"));
    expect(board.orders.weekly[1]).toMatchObject({ kind: "solo_puzzles", progress: 3 });
    const done = await env.DB.prepare("SELECT stage FROM solo_results WHERE user_id = ?1 ORDER BY stage").bind(c.uid).all();
    expect(done.results.map((r) => r.stage)).toEqual([N + 1, 2 * N + 1, 10 * N]);
  });

  it("seeds pickups from the puzzle id, as for the campaign stage", async () => {
    const c = await client();
    // Find a campaign puzzle with a pickup for this player, and play it as a Master Forge stage.
    let b = 1;
    for (; b <= N; b++) if (pickupsFor(c.uid, puzzle(b).id, campaignPuzzle(b, puzzle(b)).cellCount, 1).length > 0) break;
    const claims = pickupsFor(c.uid, puzzle(b).id, campaignPuzzle(b, puzzle(b)).cellCount, 1).map((p) => ({ cell: p.index, kind: p.kind }));
    const out = await sync(c, [master(N + b, b, { pickups: claims })]);
    expect(out.results[0]).toMatchObject({ accepted: true, pickups: claims, pickupsRejected: 0 });
  });
});
