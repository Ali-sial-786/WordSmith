/**
 * Versus on the total score (shared/room-protocol.md "Total score"): every
 * round is played, and the series goes to the most letters filled over all
 * of them, then the most bonus words.
 */

import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { VsRound } from "../../src/rules/vs-round";
import { body, setUpClient, type Client } from "./helpers";
import { closeAll, connect, sleep, type Message, type Socket } from "./sockets";

type Smith = Client & { username: string };

function stub(code: string) {
  return env.ROOM.get(env.ROOM.idFromName(code));
}

async function room(c: Client, mode: "vs" | "team" | "coop"): Promise<string> {
  const res = await c.post("/v1/rooms", { mode });
  expect(res.status).toBe(200);
  return (await body<{ code: string }>(res)).code;
}

async function join(c: Client, code: string): Promise<Socket> {
  const s = await connect(c, `/v1/ws/room/${code}`);
  await s.next({ op: "SNAPSHOT" });
  return s;
}

async function roundOf(code: string): Promise<VsRound> {
  return runInDurableObject(stub(code), (_instance, state) => state.storage.kv.get<VsRound>("round")!);
}

const lastSubmit = new WeakMap<Socket, number>();

/** Sends a word and waits for its WORD_RESULT, keeping each socket under the SUBMIT rate limit. */
async function forge(s: Socket, word: string, seq: number): Promise<Message> {
  const wait = (lastSubmit.get(s) ?? 0) + 270 - Date.now();
  if (wait > 0) await sleep(wait);
  lastSubmit.set(s, Date.now());
  s.send({ op: "SUBMIT", word, seq });
  return s.next({ op: "WORD_RESULT", seq });
}

/** START, then skip the countdown. */
async function start(host: Socket, code: string, sockets: Socket[]): Promise<Message> {
  host.send({ op: "START" });
  let first: Message | null = null;
  for (const s of sockets) first = await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first!;
}

/** After the standings: the next countdown, then the round. */
async function nextRound(code: string, sockets: Socket[]): Promise<Message> {
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  let first: Message | null = null;
  for (const s of sockets) first = await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first!;
}

/** The round's shortest grid word, which fills no other slot by itself. */
async function shortest(code: string): Promise<string> {
  const { puzzle } = await roundOf(code);
  return [...puzzle.slots].sort((a, b) => a.len - b.len)[0]!.word;
}

describe("Versus on the total score", () => {
  it("is the host's pick, in a Versus room only", async () => {
    const [a, b] = (await Promise.all([0, 1].map(() => setUpClient()))) as [Smith, Smith];
    const code = await room(a, "vs");
    const sa = await join(a, code);
    const sb = await join(b, code);
    sb.send({ op: "CONFIG", scoring: "total" });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    sa.send({ op: "CONFIG", scoring: "points" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    sa.send({ op: "CONFIG", scoring: "total" });
    expect(await sb.next({ op: "LOBBY", scoring: "total" })).toMatchObject({ mode: "vs", series: 3 });

    for (const mode of ["team", "coop"] as const) {
      const other = await room(a, mode);
      const so = await join(a, other);
      so.send({ op: "CONFIG", scoring: "total" });
      expect(await so.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
      await closeAll(so);
    }
    await closeAll(sa, sb);
  });

  it("plays all three rounds, and goes to the most letters even with fewer round wins", async () => {
    const [a, b] = (await Promise.all([0, 1].map(() => setUpClient()))) as [Smith, Smith];
    const code = await room(a, "vs");
    const sa = await join(a, code);
    const sb = await join(b, code);
    sa.send({ op: "CONFIG", scoring: "total" });
    await sb.next({ op: "LOBBY", scoring: "total" });

    const first = await start(sa, code, [sa, sb]);
    expect(first).toMatchObject({ scoring: "total", scores: { [a.uid]: 0, [b.uid]: 0 }, bonusTally: { [a.uid]: 0, [b.uid]: 0 } });

    // Rounds 1 and 2: a forges one short word each, and wins both at the timer.
    let seq = 1;
    let aScore = 0;
    for (let round = 1; round <= 2; round++) {
      if (round === 2) await nextRound(code, [sa, sb]);
      const word = await shortest(code);
      expect(await forge(sa, word, seq++)).toMatchObject({ result: "claimed" });
      aScore += word.length;
      expect(await runDurableObjectAlarm(stub(code))).toBe(true); // the round's timer
      const end = await sb.next({ op: "ROUND_END" });
      expect(end).toMatchObject({ winner: a.uid, how: "timeout", scoring: "total", scores: { [a.uid]: aScore, [b.uid]: 0 } });
      // 2-0 with one to go would end a round-wins series; this one goes on.
      expect(end.next).toMatchObject({ round: round + 1, suddenDeath: false });
    }

    // Round 3: b fills the whole mold, and that's more letters than a's two words.
    await nextRound(code, [sa, sb]);
    const r = await roundOf(code);
    expect(r.total).toBeGreaterThan(aScore);
    for (const slot of r.puzzle.slots) {
      const mold = (await roundOf(code)).molds[b.uid]!;
      if ([...mold.claims, ...mold.auto].some((c) => c.slot === slot.slot)) continue;
      await forge(sb, slot.word, seq++);
    }
    const last = await sa.next({ op: "ROUND_END" });
    expect(last).toMatchObject({ winner: b.uid, how: "finished", next: null, scores: { [a.uid]: aScore, [b.uid]: r.total } });
    const end = await sa.next({ op: "SERIES_END" });
    expect(end).toMatchObject({ winner: b.uid, scoring: "total", rounds: 3, early: false, forfeit: false });
    expect(end.podium.map((p: Message) => [p.id, p.place, p.wins, p.score, p.bonus])).toEqual([
      [b.uid, 1, 1, r.total, 0],
      [a.uid, 2, 2, aScore, 0],
    ]);

    // D1 keeps how it was won, and the winner's place.
    const row = await env.DB.prepare("SELECT m.summary, p.placement AS place, p.points FROM matches m JOIN match_players p ON p.match_id = m.id WHERE p.user_id = ?1")
      .bind(b.uid)
      .first<{ summary: string; place: number; points: number }>();
    expect([row?.place, row?.points]).toEqual([1, r.total]);
    expect(JSON.parse(row!.summary)).toMatchObject({ scoring: "total", winner: b.uid });
    await closeAll(sa, sb);
  });

  it("goes to a tiebreaker round when the leaders are level on letters and bonus words", async () => {
    const [a, b] = (await Promise.all([0, 1].map(() => setUpClient()))) as [Smith, Smith];
    const code = await room(a, "vs");
    const sa = await join(a, code);
    const sb = await join(b, code);
    sa.send({ op: "CONFIG", scoring: "total" });
    await sb.next({ op: "LOBBY", scoring: "total" });
    await start(sa, code, [sa, sb]);

    // Round 1: both forge the same short word; rounds 2 and 3: nothing. Level on letters, no bonus words.
    let seq = 1;
    const word = await shortest(code);
    await forge(sa, word, seq++);
    await forge(sb, word, seq++);
    for (let round = 1; round <= 3; round++) {
      if (round > 1) await nextRound(code, [sa, sb]);
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      const end = await sb.next({ op: "ROUND_END" });
      expect(end.scores).toEqual({ [a.uid]: word.length, [b.uid]: word.length });
      if (round === 3) expect(end.next).toMatchObject({ round: 4, suddenDeath: true, players: [a.uid, b.uid] });
    }

    // The tiebreaker: b forges a word, and takes the series at the timer.
    const tiebreaker = await nextRound(code, [sa, sb]);
    expect(tiebreaker).toMatchObject({ round: 4, suddenDeath: true, scoring: "total" });
    await forge(sb, await shortest(code), seq++);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await sa.next({ op: "ROUND_END" })).toMatchObject({ winner: b.uid, next: null });
    const end = await sa.next({ op: "SERIES_END" });
    expect(end).toMatchObject({ winner: b.uid, scoring: "total", tiebreak: true, rounds: 4 });
    expect(end.podium.map((p: Message) => [p.id, p.place])).toEqual([
      [b.uid, 1],
      [a.uid, 2],
    ]);
    await closeAll(sa, sb);
  });
});
