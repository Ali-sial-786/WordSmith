import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { pickPuzzle, recordSeen } from "../../src/db/rooms";
import type { HeatTier } from "../../src/rules/heat";
import { PUZZLE_REPEAT_WINDOW_MS } from "../../src/rules/room";
import { uniqueUid } from "./helpers";

const DAY = 24 * 3600_000;

/** Ember size-1 bank puzzles (what an Ember Versus round uses), in bank order. */
const pool = env.TEST_BANK.filter((r) => r.heat === 1 && r.size === 1).map((r) => r.id);

/** `uid` had each of `ids` in the last few days, one a second apart, `ids[0]` longest ago. */
async function saw(uid: string, ids: readonly string[], from: number): Promise<void> {
  const insert = env.DB.prepare("INSERT OR REPLACE INTO puzzle_seen (user_id, puzzle_id, seen_at) VALUES (?1, ?2, ?3)");
  await env.DB.batch(ids.map((id, i) => insert.bind(uid, id, from + 1000 * i)));
}

/**
 * `veteran` plays `games` Ember Versus games in a row, each against someone
 * new, as a room does: pick, then record that both have seen it. `seen`
 * (when the veteran last had each puzzle) is kept up to date for checks.
 */
async function games(veteran: string, count: number, seen: Map<string, number>, check: (id: string) => void = () => {}): Promise<string[]> {
  const picks: string[] = [];
  for (let i = 0; i < count; i++) {
    const rival = uniqueUid("rival");
    const now = Date.now();
    const puzzle = await pickPuzzle(env.DB, { heat: 1, size: 1, playerIds: [veteran, rival], seenSince: now - PUZZLE_REPEAT_WINDOW_MS });
    expect(puzzle).not.toBeNull();
    check(puzzle!.id);
    picks.push(puzzle!.id);
    await recordSeen(env.DB, puzzle!.id, [veteran, rival], now + i);
    seen.set(puzzle!.id, now + i);
  }
  return picks;
}

describe("choosing a bank puzzle", () => {
  it("gives a veteran the puzzles they haven't had first, in a random order, whoever they play", async () => {
    expect(pool.length).toBeGreaterThanOrEqual(24);
    const unseen = pool.slice(-12);
    const runs: string[][] = [];
    for (const veteran of [uniqueUid("vet"), uniqueUid("vet")]) {
      const history = new Map<string, number>();
      await saw(veteran, pool.slice(0, -12), Date.now() - 5 * DAY);
      const picks = await games(veteran, 12, history);
      // Every one they hadn't had, once each.
      expect([...picks].sort()).toEqual([...unseen].sort());
      runs.push(picks);
    }
    // Two veterans with the same history get them in different orders (1 chance in 12! of a clash).
    expect(runs[0]).not.toEqual(runs[1]);
  });

  it("still varies once a veteran has had every puzzle: random among those they had longest ago", async () => {
    const third = Math.ceil(pool.length / 3);
    const runs: string[][] = [];
    for (const veteran of [uniqueUid("vet"), uniqueUid("vet")]) {
      const seen = new Map<string, number>();
      const from = Date.now() - 5 * DAY;
      await saw(veteran, pool, from);
      pool.forEach((id, i) => seen.set(id, from + 1000 * i));
      const picks = await games(veteran, 12, seen, (id) => {
        // At the moment of the pick, it was among the third the veteran had longest ago.
        const oldest = [...seen].sort((a, b) => a[1] - b[1]).slice(0, third).map(([x]) => x);
        expect(oldest).toContain(id);
      });
      // Never the same puzzle twice in a run this short, since a pick becomes the newest.
      expect(new Set(picks).size).toBe(picks.length);
      runs.push(picks);
    }
    // Not the fixed oldest-first order, and not the same run twice.
    expect(runs[0]).not.toEqual(pool.slice(0, 12));
    expect(runs[0]).not.toEqual(runs[1]);
  });

  it("only counts what the room's own players have seen, in the last 60 days", async () => {
    const [a, b, c] = [uniqueUid("a"), uniqueUid("b"), uniqueUid("c")];
    const target = pool[3]!;
    // A had all but the target in the last day, B the target just now, C the target long ago.
    await saw(a, pool.filter((id) => id !== target), Date.now() - DAY);
    await saw(b, [target], Date.now());
    await saw(c, [target], Date.now() - 61 * DAY);
    const pick = (ids: string[]) => pickPuzzle(env.DB, { heat: 1, size: 1, playerIds: ids, seenSince: Date.now() - PUZZLE_REPEAT_WINDOW_MS });
    for (let i = 0; i < 5; i++) expect((await pick([a, c]))!.id).toBe(target);
    // With B in the room, nothing is fresh: one of the third seen longest ago, which the target isn't.
    for (let i = 0; i < 5; i++) expect((await pick([a, b]))!.id).not.toBe(target);
  });

  it("skips the room's own latest puzzles unless nothing else is left", async () => {
    const avoid = pool.slice(1);
    for (let i = 0; i < 5; i++) {
      const puzzle = await pickPuzzle(env.DB, { heat: 1, size: 1, playerIds: [uniqueUid()], seenSince: 0, avoid });
      expect(puzzle!.id).toBe(pool[0]);
    }
    expect(await pickPuzzle(env.DB, { heat: 1, size: 1, playerIds: [], seenSince: 0, avoid: pool })).not.toBeNull();
  });

  it("falls back to the nearest size, then the nearest heat", async () => {
    const at = async (heat: number, size: number) => {
      const puzzle = await pickPuzzle(env.DB, { heat: heat as HeatTier, size, playerIds: [], seenSince: 0 });
      return env.TEST_BANK.find((r) => r.id === puzzle!.id)!;
    };
    // The bank has every heat 1–6 and size 1–4.
    expect(await at(2, 9)).toMatchObject({ heat: 2, size: 4 });
    expect(await at(2, 0)).toMatchObject({ heat: 2, size: 1 });
    expect(await at(9, 3)).toMatchObject({ heat: 6, size: 3 });
  });
});
