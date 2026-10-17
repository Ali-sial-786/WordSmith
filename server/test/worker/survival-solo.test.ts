import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { body, client, request, uniqueName, type Client } from "./helpers";

interface PuzzleJson {
  id: string;
  words: { w: string }[];
}

function puzzle(stage: number): PuzzleJson {
  return JSON.parse(env.TEST_CAMPAIGN[stage - 1]!.data) as PuzzleJson;
}

/** A puzzle of a run: cleared with every grid word typed, unless told otherwise. */
function cleared(stage: number, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const p = puzzle(stage);
  return { stage, puzzleId: p.id, foundWords: p.words.map((w) => w.w), hintsUsed: {}, cleared: true, ...overrides };
}

function wordsOf(...stages: number[]): number {
  return stages.reduce((n, s) => n + puzzle(s).words.length, 0);
}

/** A run that ended five minutes ago, with stages 1 and 2 cleared and one word of stage 3 before the melt. */
function run(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const now = Date.now();
  return {
    runId: crypto.randomUUID(),
    startedAt: now - 30 * 60_000,
    endedAt: now - 5 * 60_000,
    saved: 5,
    puzzles: [cleared(1), cleared(2), cleared(3, { foundWords: [puzzle(3).words[0]!.w], cleared: false, hintsUsed: { hammer: 1 } })],
    ...overrides,
  };
}

interface RunBody {
  profile: Record<string, any>;
  xp: { xp: number; level: number; levelUps: number; rewards: Record<string, number> };
  best: { puzzles: number; words: number; saved: number; at: number };
  newBest: boolean;
  duplicate?: boolean;
}

async function send(c: Client, r: Record<string, unknown>): Promise<RunBody> {
  const res = await c.post("/v1/survival/solo", r);
  expect(res.status, await res.clone().text()).toBe(200);
  return body<RunBody>(res);
}

describe("POST /v1/survival/solo", () => {
  it("records a run: XP, hints, words forged, the best run and Work Orders", async () => {
    const c = await client();
    expect(await body(await c.get("/v1/me"))).toMatchObject({ survivalBest: null });

    const r = run();
    const words = wordsOf(1, 2) + 1;
    const out = await send(c, r);
    // 1 per word, 8 per cleared puzzle.
    expect(out).toEqual({
      profile: out.profile,
      xp: { xp: words + 16, level: 1, levelUps: 0, rewards: { hammer: 0, chisel: 0, sparks: 0 } },
      best: { puzzles: 2, words, saved: 5, at: r.endedAt },
      newBest: true,
    });
    expect(out.profile).toMatchObject({
      id: c.uid,
      totalXp: words + 16,
      hints: { hammer: 2, chisel: 0, sparks: 0 },
      survivalBest: out.best,
      stats: { wordsForged: words, soloDone: 0 },
      // A Crucible run isn't campaign progress.
      campaignCompleted: 0,
    });
    expect(await body(await c.get("/v1/me"))).toMatchObject({ survivalBest: out.best, totalXp: words + 16 });

    const row = await env.DB.prepare("SELECT at, puzzles, words, saved, xp FROM survival_runs WHERE uid = ?1 AND run_id = ?2").bind(c.uid, r.runId).first();
    expect(row).toEqual({ at: r.endedAt, puzzles: 2, words, saved: 5, xp: words + 16 });
    expect(await env.DB.prepare("SELECT puzzles, words, saved, at FROM survival_best WHERE uid = ?1").bind(c.uid).first()).toEqual(out.best);
    const events = await env.DB.prepare("SELECT source, amount, ref FROM xp_events WHERE user_id = ?1").bind(c.uid).all();
    expect(events.results).toEqual([{ source: "survival", amount: words + 16, ref: r.runId }]);
    // Cleared puzzles count towards the weekly 15 puzzles, as campaign puzzles do.
    const weekly = await env.DB.prepare("SELECT kind, progress FROM work_orders WHERE user_id = ?1 AND slot = 'w1'").bind(c.uid).first();
    expect(weekly).toEqual({ kind: "solo_puzzles", progress: 2 });
  });

  it("answers a run sent again as a duplicate, without paying twice", async () => {
    const c = await client();
    const r = run();
    const first = await send(c, r);
    const again = await send(c, r);
    expect(again).toEqual({
      profile: first.profile,
      xp: { ...first.xp, levelUps: 0 },
      best: first.best,
      newBest: true,
      duplicate: true,
    });
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM xp_events WHERE user_id = ?1").bind(c.uid).first("n");
    expect(n).toBe(1);
    // Even once it would no longer pass the checks.
    const late = await send(c, { ...r, startedAt: Date.now() - 48 * 3600_000 });
    expect(late).toMatchObject({ duplicate: true, xp: { xp: first.xp.xp } });
  });

  it("keeps the best run: most puzzles cleared, then most words, then most saved", async () => {
    const c = await client();
    const one = run({ saved: 2, puzzles: [cleared(1)] });
    expect(await send(c, one)).toMatchObject({ newBest: true, best: { puzzles: 1, words: 3, saved: 2 } });
    // More words and as many saves, but nothing cleared: not better.
    const wordy = run({ saved: 2, puzzles: [cleared(4, { cleared: false }), cleared(5, { cleared: false })] });
    const second = await send(c, wordy);
    expect(second).toMatchObject({ newBest: false, best: { puzzles: 1, words: 3, saved: 2, at: one.endedAt } });
    expect(second.profile.survivalBest).toEqual(second.best);
    // The same puzzle cleared with the same words: saves break the tie.
    expect(await send(c, run({ saved: 1, puzzles: [cleared(1)] }))).toMatchObject({ newBest: false });
    expect(await send(c, run({ saved: 2, puzzles: [cleared(1)] }))).toMatchObject({ newBest: false });
    const better = run({ saved: 3, puzzles: [cleared(1)] });
    expect(await send(c, better)).toMatchObject({ newBest: true, best: { puzzles: 1, saved: 3, at: better.endedAt } });
    expect(await env.DB.prepare("SELECT saved, at FROM survival_best WHERE uid = ?1").bind(c.uid).first()).toEqual({ saved: 3, at: better.endedAt });
    // A duplicate of a run that's no longer the best says so.
    expect(await send(c, one)).toMatchObject({ duplicate: true, newBest: false, best: { saved: 3 } });
  });

  it("takes hints off the stock without going below zero, and caps XP at 150", async () => {
    const c = await client();
    const stages = Array.from({ length: 20 }, (_, i) => i + 1);
    const out = await send(
      c,
      run({
        startedAt: Date.now() - 3 * 3600_000,
        saved: 20,
        puzzles: stages.map((s) => cleared(s, s === 1 ? { hintsUsed: { hammer: 50, chisel: 2 } } : {})),
      }),
    );
    // 150 XP is level 3 (130), each level-up paying a Hammer Strike after the hints came off.
    expect(out.xp).toEqual({ xp: 150, level: 3, levelUps: 2, rewards: { hammer: 2, chisel: 0, sparks: 0 } });
    expect(out.profile).toMatchObject({ totalXp: 150, level: 3, hints: { hammer: 2, chisel: 0, sparks: 0 } });
    expect(out.best).toMatchObject({ puzzles: 20, saved: 20, words: wordsOf(...stages) });
  });

  it.each<[string, (r: Record<string, unknown>) => Record<string, unknown>]>([
    ["more than 50 puzzles", (r) => ({ ...r, puzzles: Array.from({ length: 51 }, () => cleared(1)) })],
    ["a puzzle that isn't shaped right", (r) => ({ ...r, puzzles: [{ stage: 1, puzzleId: puzzle(1).id, foundWords: [] }] })],
    ["a missing runId", (r) => ({ ...r, runId: undefined })],
    ["a stage that isn't in the campaign", (r) => ({ ...r, puzzles: [cleared(1, { stage: 99_999 })] })],
    ["another stage's puzzle", (r) => ({ ...r, puzzles: [cleared(1, { puzzleId: puzzle(2).id })] })],
    ["a stage beyond 30 for a new player", (r) => ({ ...r, puzzles: [cleared(31)] })],
    ["a word that isn't a grid word", (r) => ({ ...r, puzzles: [cleared(1, { foundWords: [...puzzle(1).words.map((w) => w.w), "QQQ"] })] })],
    ["a cleared puzzle its words and hints can't fill", (r) => ({ ...r, puzzles: [cleared(2, { foundWords: [puzzle(2).words[0]!.w] })] })],
    ["a start more than 24 h ago", (r) => ({ ...r, startedAt: Date.now() - 24 * 3600_000 - 60_000 })],
    ["an end in the future", (r) => ({ ...r, endedAt: Date.now() + 11 * 60_000 })],
    ["an end before the start", (r) => ({ ...r, endedAt: (r.startedAt as number) - 1 })],
    ["under 1 s per word", (r) => ({ ...r, endedAt: (r.startedAt as number) + 1000 })],
    ["more saves than words", (r) => ({ ...r, saved: 500 })],
  ])("refuses %s with invalid_run, recording nothing", async (_name, change) => {
    const c = await client();
    const res = await c.post("/v1/survival/solo", change(run()));
    expect(res.status).toBe(400);
    expect(await body(res)).toMatchObject({ error: "invalid_run", message: expect.any(String) });
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM survival_runs WHERE uid = ?1").bind(c.uid).first("n")).toBe(0);
    expect(await body(await c.get("/v1/me"))).toMatchObject({ totalXp: 0, survivalBest: null, hints: { hammer: 3 } });
  });

  it("lets a run reach 10 stages past the furthest the player has played", async () => {
    const c = await client();
    await c.get("/v1/me");
    await env.DB.prepare("INSERT INTO solo_results (user_id, stage, completed_at) VALUES (?1, 40, ?2)").bind(c.uid, Date.now()).run();
    expect(await send(c, run({ saved: 0, puzzles: [cleared(50)] }))).toMatchObject({ best: { puzzles: 1 } });
    const res = await c.post("/v1/survival/solo", run({ saved: 0, puzzles: [cleared(51)] }));
    expect(await body(res)).toMatchObject({ error: "invalid_run", message: "puzzles[0]: stage 51 is beyond 50" });
  });

  it("needs a token, and is deleted with the account", async () => {
    const res = await request("/v1/survival/solo", { method: "POST", body: JSON.stringify(run()) });
    expect(res.status).toBe(401);

    const c = await client();
    await send(c, run());
    expect((await c.del("/v1/me")).status).toBe(200);
    for (const table of ["survival_runs", "survival_best"]) {
      expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE uid = ?1`).bind(c.uid).first("n")).toBe(0);
    }
  });

  it("puts survivalBest in every profile body", async () => {
    const c = await client();
    const out = await send(c, run());
    const setup = await c.post("/v1/me/setup", { username: uniqueName("crux"), avatar: "avatar_02" });
    expect(await body(setup)).toMatchObject({ survivalBest: out.best });
    const synced = await c.post("/v1/solo/sync", { entries: [] });
    expect((await body<RunBody>(synced)).profile).toMatchObject({ survivalBest: out.best });
  });
});
