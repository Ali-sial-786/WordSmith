import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { coopTimerMs, vsRoundTimerMs } from "../../src/rules/heat";
import type { MpPuzzle } from "../../src/rules/mold";
import { totalXpForLevel } from "../../src/rules/progression";
import { body, setUpClient, type Client } from "./helpers";
import { closeAll, connect, sleep, type Message, type Socket } from "./sockets";

const NO_HINTS = { hammer: 0, chisel: 0, sparks: 0 };

function stub(code: string) {
  return env.ROOM.get(env.ROOM.idFromName(code));
}

async function createRoom(c: Client, mode: "coop" | "vs"): Promise<string> {
  const res = await c.post("/v1/rooms", { mode });
  expect(res.status, await res.clone().text()).toBe(200);
  return (await body<{ code: string }>(res)).code;
}

async function join(c: Client, code: string): Promise<Socket> {
  const s = await connect(c, `/v1/ws/room/${code}`);
  await s.next({ op: "SNAPSHOT" });
  return s;
}

async function setLevel(c: Client, level: number): Promise<void> {
  await env.DB.prepare("UPDATE profiles SET xp = ?2, level = ?3 WHERE user_id = ?1").bind(c.uid, totalXpForLevel(level), level).run();
}

/** The round's puzzle, answers and all. */
async function puzzleOf(code: string): Promise<MpPuzzle> {
  return runInDurableObject(stub(code), (_i, state) => state.storage.kv.get<{ puzzle: MpPuzzle }>("round")!.puzzle);
}

/** START or AGAIN, then the countdown alarm. */
async function start(host: Socket, code: string, sockets: Socket[], op: "START" | "AGAIN" = "START"): Promise<Message> {
  host.send({ op });
  let first: Message | null = null;
  for (const s of sockets) first = await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first!;
}

/** Versus: one word for `s`, so they win the round when it times out. */
async function forgeOne(s: Socket, code: string, seq: number): Promise<void> {
  const word = (await puzzleOf(code)).slots[0]!.word;
  s.send({ op: "SUBMIT", word, seq });
  expect(await s.next({ op: "WORD_RESULT", seq })).toMatchObject({ result: "claimed" });
}

/** Versus: after the standings, the next countdown and then the round. */
async function nextRound(code: string, sockets: Socket[]): Promise<Message> {
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  let first: Message | null = null;
  for (const s of sockets) first = await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first!;
}

/** Who has a `puzzle_seen` row for `puzzleId`, among `uids`. */
async function seenBy(puzzleId: string, uids: string[]): Promise<string[]> {
  const { results } = await env.DB.prepare("SELECT user_id FROM puzzle_seen WHERE puzzle_id = ?1 AND user_id IN (SELECT value FROM json_each(?2))")
    .bind(puzzleId, JSON.stringify(uids))
    .all<{ user_id: string }>();
  return results.map((r) => r.user_id).sort();
}

describe("the host's heat in co-op", () => {
  it("is checked, set in the lobby or results, played by the round, and kept through AGAIN", async () => {
    const [a, b] = [await setUpClient(), await setUpClient()];
    const code = await createRoom(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    // Auto: the host's level 1, Ember.
    expect(sb.seen.find((m) => m.op === "SNAPSHOT")!.lobby).toMatchObject({ heat: 1, heatChoice: "auto", autoHeat: 1 });

    // Bad values first, then someone else's.
    for (const bad of [0, 7, "4"]) {
      sa.send({ op: "CONFIG", heat: bad });
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    }
    sa.send({ op: "CONFIG", heat: 4, series: 5 });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    sb.send({ op: "CONFIG", heat: 4 });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });

    // The host's pick: Orange, for everyone to see.
    sa.send({ op: "CONFIG", heat: 4 });
    expect(await sb.next({ op: "LOBBY", heatChoice: 4 })).toMatchObject({ heat: 4, autoHeat: 1 });
    await sa.next({ op: "LOBBY", heatChoice: 4 });
    // The same pick again changes nothing.
    sa.send({ op: "CONFIG", heat: 4 });
    expect((await sa.drain()).filter((m) => m.op === "LOBBY")).toEqual([]);

    // The round plays it, with its timer.
    const first = await start(sa, code, [sa, sb]);
    expect(first.heat).toBe(4);
    expect(first.endsAt - first.startsAt).toBe(coopTimerMs(4));
    sa.send({ op: "CONFIG", heat: 2 });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });

    // Level 1 smiths at Orange: 20 XP × (1.6 + 3 tiers up × 0.2) = 44.
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    const end = await sa.next({ op: "ROUND_END" });
    for (const id of [a.uid, b.uid]) expect(end.xp[id]).toMatchObject({ xp: 44, heatBonus: 24, tiersAbove: 3 });
    expect(await sa.next({ op: "LOBBY", phase: "results" })).toMatchObject({ heat: 4, heatChoice: 4 });

    // AGAIN keeps it.
    await sleep(1000);
    const again = await start(sa, code, [sa, sb], "AGAIN");
    expect(again).toMatchObject({ round: 2, heat: 4 });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await sa.next({ op: "ROUND_END" });

    // In results the host can change it for the next round: back to auto.
    sa.send({ op: "CONFIG", heat: "auto" });
    expect(await sb.next({ op: "LOBBY", heatChoice: "auto" })).toMatchObject({ heat: 1, autoHeat: 1 });
    await sleep(500);
    const third = await start(sa, code, [sa, sb], "AGAIN");
    expect(third).toMatchObject({ round: 3, heat: 1 });
    expect(third.endsAt - third.startsAt).toBe(coopTimerMs(1));
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await closeAll(sa, sb);
  });
});

describe("the host's heat in Versus", () => {
  it("is the host's to pick, and pays a newcomer playing up more than a veteran", async () => {
    const [pro, rookie] = [await setUpClient(), await setUpClient()];
    await setLevel(pro, 90);
    const code = await createRoom(pro, "vs");
    const sp = await join(pro, code);
    const sr = await join(rookie, code);
    // Auto: the median of levels 90 and 1 is 45, Orange.
    expect(await sp.next({ op: "LOBBY" })).toMatchObject({ heat: 4, heatChoice: "auto", autoHeat: 4 });

    sr.send({ op: "CONFIG", heat: 6 });
    expect(await sr.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    sp.send({ op: "CONFIG", heat: 6, series: 3 });
    expect(await sr.next({ op: "LOBBY", heatChoice: 6 })).toMatchObject({ heat: 6, autoHeat: 4, series: 3 });

    // White Heat for the whole series, with its timer; no changes mid-series.
    const first = await start(sp, code, [sp, sr]);
    expect(first).toMatchObject({ round: 1, heat: 6 });
    expect(first.endsAt - first.startsAt).toBe(vsRoundTimerMs(6));
    sp.send({ op: "CONFIG", heat: 1 });
    expect(await sp.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });
    await forgeOne(sp, code, 1);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await sp.next({ op: "ROUND_END" })).toMatchObject({ winner: pro.uid });
    expect(await sr.next({ op: "LOBBY", phase: "standings" })).toMatchObject({ heat: 6 });
    sp.send({ op: "CONFIG", heat: 1 });
    expect(await sp.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });

    expect(await nextRound(code, [sp, sr])).toMatchObject({ round: 2, heat: 6 });
    await forgeOne(sp, code, 2);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    const series = await sr.next({ op: "SERIES_END" });
    expect(series.winner).toBe(pro.uid);
    // The pro at their own heat: (2 × 5 + 2 × 10 + 30) × 2.0. The rookie, 5 tiers up: 2 × 5 × 3.0.
    expect(series.xp[pro.uid]).toEqual({ xp: 120, level: 90, levelUps: 0, rewards: NO_HINTS, scrapHammers: 0, heatBonus: 60, tiersAbove: 0, pickups: expect.any(Object) });
    expect(series.xp[rookie.uid]).toMatchObject({ xp: 30, heatBonus: 20, tiersAbove: 5 });
    const summary = await env.DB.prepare("SELECT summary FROM matches WHERE mode = 'vs' AND code = ?1").bind(code).first<string>("summary");
    expect(JSON.parse(summary!)).toMatchObject({ heat: 6 });

    // In results: a new heat for the next series, but the length was set in the lobby.
    await sleep(600);
    sp.send({ op: "CONFIG", heat: 1 });
    expect(await sr.next({ op: "LOBBY", heatChoice: 1 })).toMatchObject({ phase: "results", heat: 1 });
    sp.send({ op: "CONFIG", series: 5 });
    expect(await sp.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });
    await sleep(600);
    expect(await start(sp, code, [sp, sr], "AGAIN")).toMatchObject({ round: 1, heat: 1 });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // the round's timer
    await closeAll(sp, sr);
  });
});

describe("puzzles in a room", () => {
  it("never repeat within a series, or after AGAIN, even if the seen records go missing", async () => {
    const [a, b] = [await setUpClient(), await setUpClient()];
    // Both had every Ember size-1 puzzle a few days ago: nothing is fresh.
    const insert = env.DB.prepare("INSERT OR REPLACE INTO puzzle_seen (user_id, puzzle_id, seen_at) VALUES (?1, ?2, ?3)");
    const pool = env.TEST_BANK.filter((r) => r.heat === 1 && r.size === 1);
    const before = Date.now() - 3 * 24 * 3600_000;
    await env.DB.batch(pool.flatMap((r, i) => [insert.bind(a.uid, r.id, before + i), insert.bind(b.uid, r.id, before + i)]));
    const code = await createRoom(a, "vs");
    const sa = await join(a, code);
    const sb = await join(b, code);
    sa.send({ op: "CONFIG", series: 5 });
    await sb.next({ op: "LOBBY", series: 5 });

    /** The round's puzzle, once its seen records are in, which are then lost: it's the freshest puzzle there is. */
    const played: string[] = [];
    const lose = async () => {
      const id = (await puzzleOf(code)).id;
      for (let i = 0; i < 40 && (await seenBy(id, [a.uid, b.uid])).length < 2; i++) await sleep(25);
      expect(await seenBy(id, [a.uid, b.uid])).toEqual([a.uid, b.uid].sort());
      await env.DB.prepare("DELETE FROM puzzle_seen WHERE puzzle_id = ?1").bind(id).run();
      played.push(id);
    };

    await start(sa, code, [sa, sb]);
    await lose();
    for (let round = 1; round <= 3; round++) {
      await forgeOne(sa, code, round);
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      await sa.next({ op: "ROUND_END" });
      if (round === 3) break;
      await nextRound(code, [sa, sb]);
      await lose();
    }
    expect(await sb.next({ op: "SERIES_END" })).toMatchObject({ winner: a.uid, rounds: 3 });
    await sleep(600);
    await start(sa, code, [sa, sb], "AGAIN");
    await lose();
    expect(new Set(played).size).toBe(4);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await closeAll(sa, sb);
  });

  it("are recorded as seen for everyone watching too", async () => {
    const [a, b, c] = [await setUpClient(), await setUpClient(), await setUpClient()];
    const code = await createRoom(a, "vs");
    const sa = await join(a, code);
    const sb = await join(b, code);
    let sc = await join(c, code);
    await start(sa, code, [sa, sb, sc]);
    const first = (await puzzleOf(code)).id;
    // C leaves the series, then comes back to watch it.
    sc.send({ op: "LEAVE" });
    await sc.closed;
    await forgeOne(sa, code, 1);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await sa.next({ op: "ROUND_END" });
    sc = await join(c, code);
    const second = await nextRound(code, [sa, sb, sc]);
    expect(second.players).toEqual([a.uid, b.uid]);
    const id = (await puzzleOf(code)).id;
    expect(id).not.toBe(first);
    for (let i = 0; i < 40 && (await seenBy(id, [a.uid, b.uid, c.uid])).length < 3; i++) await sleep(25);
    expect(await seenBy(id, [a.uid, b.uid, c.uid])).toEqual([a.uid, b.uid, c.uid].sort());
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // the round's timer
    await closeAll(sa, sb, sc);
  });
});
