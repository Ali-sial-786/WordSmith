import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { CoopRound } from "../../src/rules/coop-round";
import { totalXpForLevel } from "../../src/rules/progression";
import { survivalHeatMs, SURVIVAL_CAP_MS, SURVIVAL_GRACE_MS, type HeatClock } from "../../src/rules/survival";
import type { VsRound, VsSeries } from "../../src/rules/vs-round";
import { body, setUpClient, type Client } from "./helpers";
import { closeAll, connect, sleep, type Message, type Socket } from "./sockets";

type Smith = Client & { username: string };

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

/** The round as the room stores it, answers, heat order and clocks included. */
async function roundOf<R = CoopRound>(code: string): Promise<R> {
  return runInDurableObject(stub(code), (_instance, state) => state.storage.kv.get<R>("round")!);
}

/** Changes the stored round (no embers, say, or a chosen heat order), then evicts the room so it reads it back. */
async function patchRound<R>(code: string, patch: (r: R) => R): Promise<void> {
  await runInDurableObject(stub(code), (_instance, state) => {
    state.storage.kv.put("round", patch(state.storage.kv.get<R>("round")!));
  });
  await evictDurableObject(stub(code));
}

/** Waits until the stored round satisfies `ok` (a close handler runs a moment after the socket closes). */
async function roundWhere<R>(code: string, ok: (r: R) => boolean): Promise<R> {
  for (let i = 0; i < 40; i++) {
    const r = await roundOf<R>(code);
    if (ok(r)) return r;
    await sleep(50);
  }
  throw new Error("the round never got there");
}

/** Makes the room pick this bank puzzle: every other one at its heat and size is marked as seen by `uid` just now. */
async function forcePuzzle(uid: string, id: string): Promise<void> {
  const target = env.TEST_BANK.find((r) => r.id === id)!;
  const others = env.TEST_BANK.filter((r) => r.heat === target.heat && r.size === target.size && r.id !== id);
  const insert = env.DB.prepare("INSERT OR REPLACE INTO puzzle_seen (user_id, puzzle_id, seen_at) VALUES (?1, ?2, ?3)");
  await env.DB.batch(others.map((p) => insert.bind(uid, p.id, Date.now())));
}

/** START (or AGAIN), then skip the 3 s countdown by running the alarm. Returns the first socket's ROUND_START. */
async function start(host: Socket, code: string, sockets: Socket[], op: "START" | "AGAIN" = "START"): Promise<Message> {
  host.send({ op });
  const first = await sockets[0]!.next({ op: "ROUND_START" });
  for (const s of sockets.slice(1)) await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first;
}

/**
 * Skipping the countdown leaves `startsAt` 3 s ahead of the clock, and time
 * before it isn't a pause; so the round's countdowns are moved to have
 * started a second ago.
 */
function startedAlready(clock: HeatClock): HeatClock {
  const startsAt = Date.now() - 1000;
  return { ...clock, startsAt, deadline: startsAt + clock.durationMs };
}

async function survival(host: Socket, others: Socket[] = []): Promise<void> {
  host.send({ op: "CONFIG", variant: "survival" });
  for (const s of [host, ...others]) await s.next({ op: "LOBBY", variant: "survival" });
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

/** Where a message is in what a socket has seen. */
function indexOf(s: Socket, match: Partial<Message>): number {
  return s.seen.findIndex((m) => Object.entries(match).every(([k, v]) => m[k] === v));
}

function doneSlots(r: { claims: { slot: number }[]; auto: { slot: number }[] }): Set<number> {
  return new Set([...r.claims, ...r.auto].map((s) => s.slot));
}

describe("survival co-op", () => {
  it("heats one word at a time, and a melt ends the round", async () => {
    const a = await setUpClient();
    const code = await createRoom(a, "coop");
    const sa = await join(a, code);
    await survival(sa);
    const startMsg = await start(sa, code, [sa]);
    expect(startMsg).toMatchObject({ variant: "survival", heat: 1 });
    expect(startMsg.endsAt - startMsg.startsAt).toBe(SURVIVAL_CAP_MS);
    await patchRound<CoopRound>(code, (r) => ({ ...r, embers: [] }));
    const round = await roundOf(code);
    const { order } = round.survival!;
    const slots = round.puzzle.slots;
    const shortest = Math.min(...slots.map((s) => s.len));
    const first = slots[order[0]!]!;
    expect(first.len).toBe(shortest);
    expect(startMsg.heated).toEqual({
      slot: first.slot,
      startsAt: startMsg.startsAt,
      deadline: startMsg.startsAt + survivalHeatMs(shortest, 1, 0),
      durationMs: survivalHeatMs(shortest, 1, 0),
      saved: 0,
      serverNow: startMsg.serverNow,
    });

    // Another word: the heat stays where it is.
    const other = slots[order[1]!]!;
    expect(await forge(sa, other.word, 1)).toMatchObject({ result: "claimed" });
    await sa.next({ op: "CLAIMED", slot: other.slot });
    expect((await sa.drain()).filter((m) => m.op === "HEATED")).toEqual([]);

    // The heated word: saved, and the next one in the order heats up from now.
    const before = Date.now();
    expect(await forge(sa, first.word, 2)).toMatchObject({ result: "claimed" });
    const heated = await sa.next({ op: "HEATED" });
    const state = await roundOf(code);
    const next = order.find((s) => !doneSlots(state).has(s))!;
    expect(heated).toMatchObject({ op: "HEATED", slot: next, saved: 1, durationMs: survivalHeatMs(slots[next]!.len, 1, 1) });
    expect(heated.deadline - heated.startsAt).toBe(heated.durationMs);
    expect(heated.startsAt).toBeGreaterThanOrEqual(before);
    expect(indexOf(sa, { op: "CLAIMED", slot: first.slot })).toBeLessThan(indexOf(sa, { op: "HEATED" }));

    // The next deadline is the melt (plus the grace); at it, MELT goes to everyone, then ROUND_END.
    const planned = await runInDurableObject(stub(code), (_i, s) => s.storage.kv.get<number>("alarm"));
    expect(planned).toBe(heated.deadline + SURVIVAL_GRACE_MS);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await sa.next({ op: "MELT" })).toEqual({ op: "MELT", slot: next });
    const end = await sa.next({ op: "ROUND_END" });
    expect(indexOf(sa, { op: "MELT" })).toBeLessThan(indexOf(sa, { op: "ROUND_END" }));
    expect(end).toMatchObject({ reason: "melted", variant: "survival", saved: 1, melted: { slot: next }, mvp: a.uid });
    expect(end.filled).toBeLessThan(end.total);
    // Co-op XP as for a timeout (20 + 1 per 10 points + 10 MVP), plus 2 for the word saved.
    const points = 10 * (other.len + first.len);
    expect(end.xp[a.uid]).toMatchObject({ xp: 20 + points / 10 + 10 + 2 });
    expect(await sa.next({ op: "LOBBY", phase: "results" })).toMatchObject({ variant: "survival" });

    const match = await env.DB.prepare("SELECT ended_at, summary FROM matches WHERE id = ?1").bind(round.matchId).first<Message>();
    expect(match!.ended_at).toBe(heated.deadline + SURVIVAL_GRACE_MS);
    expect(JSON.parse(match!.summary as string)).toMatchObject({ reason: "melted", variant: "survival", saved: 1, melted: { slot: next } });
    expect(await forge(sa, slots[next]!.word, 3)).toMatchObject({ result: "too_late" });

    // A rejoin during results: the finished board shows nothing heated, and the results say what melted.
    sa.ws.close();
    const back = await connect(a, `/v1/ws/room/${code}`);
    const snap = await back.next({ op: "SNAPSHOT" });
    expect(snap.round).toMatchObject({ variant: "survival", heated: null, saved: 1 });
    expect(snap.results).toMatchObject({ reason: "melted", melted: { slot: next }, saved: 1 });
    await closeAll(back);
  });

  it("moves the heat on when crossings or hints complete the heated word", async () => {
    // m-00078 (heat 1, for 2):  HAS fills in from MASH, ASH and HAMS; HAM and SHAM are left.
    //   M . H A M
    //   A . A . .
    //   S . M . .
    //   H A S . .
    //   . S . . .
    //   S H A M .
    const a = await setUpClient();
    const b = await setUpClient();
    await env.DB.prepare("UPDATE profiles SET xp = ?2, level = 5 WHERE user_id = ?1").bind(a.uid, totalXpForLevel(5)).run();
    await env.DB.prepare("UPDATE inventory SET count = 5 WHERE user_id = ?1 AND item = 'chisel'").bind(a.uid).run();
    await forcePuzzle(a.uid, "m-00078");
    const code = await createRoom(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    await survival(sa, [sb]);
    await start(sa, code, [sa, sb]);
    const round = await roundOf(code);
    expect(round.puzzle.id).toBe("m-00078");
    const slot = (word: string) => round.puzzle.slots.find((s) => s.word === word)!;
    const order = ["HAS", "HAM", "SHAM", "MASH", "HAMS", "ASH"].map((w) => slot(w).slot);
    const clock: HeatClock = {
      slot: slot("HAS").slot,
      startsAt: round.startsAt,
      deadline: round.startsAt + survivalHeatMs(3, 1, 0),
      durationMs: survivalHeatMs(3, 1, 0),
      saved: 0,
      pausedAt: null,
    };
    await patchRound<CoopRound>(code, (r) => ({ ...r, embers: [], survival: { order, clock, melted: null } }));

    // HAS's crossing words: the last one fills it in, which saves it.
    await forge(sa, "MASH", 1);
    await forge(sb, "ASH", 1);
    expect((await sb.drain()).filter((m) => m.op === "HEATED")).toEqual([]);
    await forge(sa, "HAMS", 2);
    for (const s of [sa, sb]) {
      expect(await s.next({ op: "CLAIMED", word: "HAMS" })).toMatchObject({ auto: [{ slot: slot("HAS").slot, word: "HAS" }] });
      expect(await s.next({ op: "HEATED" })).toMatchObject({ slot: slot("HAM").slot, saved: 1, durationMs: survivalHeatMs(3, 1, 1) });
    }

    // HAM's last two letters by Chisel: the hints save it too.
    sa.send({ op: "HINT", kind: "chisel", x: 3, y: 0 });
    expect(await sb.next({ op: "REVEAL" })).toMatchObject({ cells: [{ x: 3, y: 0, letter: "A" }], auto: [] });
    sa.send({ op: "HINT", kind: "chisel", x: 4, y: 0 });
    expect(await sb.next({ op: "REVEAL" })).toMatchObject({ auto: [{ slot: slot("HAM").slot, word: "HAM" }] });
    const heated = await sb.next({ op: "HEATED" });
    expect(heated).toMatchObject({ slot: slot("SHAM").slot, saved: 2, durationMs: survivalHeatMs(4, 1, 2) });
    expect(sb.seen.findIndex((m) => m.op === "REVEAL" && m.auto.length > 0)).toBeLessThan(indexOf(sb, { op: "HEATED", saved: 2 }));

    // The last word: no HEATED, and the round is complete with 3 saved (+6 XP each).
    await forge(sb, "SHAM", 2);
    const end = await sa.next({ op: "ROUND_END" });
    expect(end).toMatchObject({ reason: "complete", variant: "survival", saved: 3, melted: null });
    expect(sa.seen.filter((m) => m.op === "HEATED")).toHaveLength(2);
    const pointsB = (end.players as Message[]).find((p) => p.id === b.uid)!.points as number;
    expect(end.xp[b.uid].xp).toBe(20 + pointsB / 10 + 20 + (end.mvp === b.uid ? 10 : 0) + 6);
    await closeAll(sa, sb);
  });

  it("pauses the team's countdown only while nobody is connected, and resumes it on rejoin", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const code = await createRoom(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    await survival(sa, [sb]);
    await start(sa, code, [sa, sb]);
    await patchRound<CoopRound>(code, (r) => ({ ...r, survival: { ...r.survival!, clock: startedAlready(r.survival!.clock) } }));

    // One drops: the countdown goes on.
    sb.ws.close();
    await sa.next({ op: "LOBBY" });
    expect((await roundOf(code)).survival!.clock.pausedAt).toBeNull();
    // Both: it pauses, and the alarm is no longer the melt but B's rejoin time.
    sa.ws.close();
    const paused = await roundWhere<CoopRound>(code, (r) => r.survival!.clock.pausedAt !== null);
    const before = paused.survival!.clock;
    const room = await runInDurableObject(stub(code), (_i, s) => s.storage.kv.get<{ players: { id: string; graceUntil: number }[] }>("room")!);
    const planned = await runInDurableObject(stub(code), (_i, s) => s.storage.kv.get<number>("alarm"));
    expect(planned).toBe(room.players.find((p) => p.id === b.uid)!.graceUntil);

    // B is back: the deadline moves on by the pause, the SNAPSHOT shows it, and HEATED follows.
    await sleep(400);
    const back = await connect(b, `/v1/ws/room/${code}`);
    const snap = await back.next({ op: "SNAPSHOT" });
    const heated = await back.next({ op: "HEATED" });
    const after = (await roundOf(code)).survival!.clock;
    expect(after.pausedAt).toBeNull();
    expect(after.deadline - before.deadline).toBeGreaterThanOrEqual(400);
    expect(after.deadline - after.startsAt).toBe(after.durationMs);
    expect(snap.round).toMatchObject({ variant: "survival", saved: 0, heated: { slot: before.slot, deadline: after.deadline, startsAt: after.startsAt } });
    expect(heated).toMatchObject({ slot: before.slot, deadline: after.deadline, durationMs: before.durationMs, saved: 0 });
    expect(indexOf(back, { op: "SNAPSHOT" })).toBeLessThan(indexOf(back, { op: "HEATED" }));

    // A coming back too doesn't resume anything again.
    const a2 = await connect(a, `/v1/ws/room/${code}`);
    await a2.next({ op: "SNAPSHOT" });
    expect((await a2.drain()).filter((m) => m.op === "HEATED")).toEqual([]);
    await closeAll(back, a2);
  });
});

describe("survival Versus", () => {
  it("gives each racer their own heated word, and the first melt ends the round for everyone", async () => {
    const [a, b, c] = (await Promise.all([0, 1, 2].map(() => setUpClient()))) as [Smith, Smith, Smith];
    const code = await createVsRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    const sc = await join(c, code);
    const sockets = [sa, sb, sc];
    await survival(sa, [sb, sc]);
    const first = await start(sa, code, sockets);
    expect(first).toMatchObject({ variant: "survival", series: 3, players: [a.uid, b.uid, c.uid] });
    expect(first.endsAt - first.startsAt).toBe(SURVIVAL_CAP_MS);
    for (const s of sockets) expect(s.seen.find((m) => m.op === "ROUND_START")!.heated).toEqual(first.heated);
    await patchRound<VsRound>(code, (r) => ({ ...r, embers: [] }));
    const round = await roundOf<VsRound>(code);
    const { order } = round.survival!;
    const slots = round.puzzle.slots;
    expect(first.heated.slot).toBe(order[0]);

    // A forges their heated word: HEATED goes to A only, about A's own mold.
    expect(await forge(sa, slots[order[0]!]!.word, 1)).toMatchObject({ result: "claimed" });
    const heatedA = await sa.next({ op: "HEATED" });
    const moldA = (await roundOf<VsRound>(code)).molds[a.uid]!;
    const nextA = order.find((s) => !doneSlots(moldA).has(s))!;
    expect(heatedA).toMatchObject({ slot: nextA, saved: 1 });
    // B forges a word that isn't B's heated one: B's heat stays.
    expect(await forge(sb, slots[order[1]!]!.word, 1)).toMatchObject({ result: "claimed" });
    for (const s of [sb, sc]) expect((await s.drain()).filter((m) => m.op === "HEATED")).toEqual([]);
    // A saves another. C finds a bonus word (if the puzzle has one).
    expect(await forge(sa, slots[nextA]!.word, 2)).toMatchObject({ result: "claimed" });
    expect(await sa.next({ op: "HEATED" })).toMatchObject({ saved: 2 });
    const bin = round.puzzle.bonus.slice(0, 1);
    for (const w of bin) expect(await forge(sc, w, 2)).toMatchObject({ result: "bonus" });

    // A has the most letters, but A's countdown runs out first.
    const now = await roundOf<VsRound>(code);
    const clocks = now.survival!.clocks;
    const meltSlot = clocks[a.uid]!.slot!;
    const soonest = Math.min(clocks[b.uid]!.deadline, clocks[c.uid]!.deadline) - 5000;
    await patchRound<VsRound>(code, (r) => ({
      ...r,
      survival: { ...r.survival!, clocks: { ...r.survival!.clocks, [a.uid]: { ...r.survival!.clocks[a.uid]!, deadline: soonest } } },
    }));
    expect(now.molds[a.uid]!.filled).toBeGreaterThan(now.molds[b.uid]!.filled);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    for (const s of sockets) {
      expect(await s.next({ op: "MELT" })).toEqual({ op: "MELT", slot: meltSlot, id: a.uid });
      const end = await s.next({ op: "ROUND_END" });
      expect(end).toMatchObject({
        reason: "melted",
        winner: b.uid,
        how: "survived",
        variant: "survival",
        saved: { [a.uid]: 2, [b.uid]: 0, [c.uid]: 0 },
        melted: { id: a.uid, slot: meltSlot },
        tally: { [a.uid]: 0, [b.uid]: 1, [c.uid]: 0 },
        next: { round: 2, suddenDeath: false },
      });
      await s.next({ op: "LOBBY", phase: "standings" });
    }
    // The series' history, for the podium: the melt, everyone's words saved and Scrap Bin, and the words.
    const series = await runInDurableObject(stub(code), (_instance, state) => state.storage.kv.get<VsSeries>("series")!);
    expect(series.history).toEqual([
      expect.objectContaining({
        round: 1,
        reason: "melted",
        winner: b.uid,
        how: "survived",
        melted: { id: a.uid, slot: meltSlot },
        saved: { [a.uid]: 2, [b.uid]: 0, [c.uid]: 0 },
        letters: first.letters,
        answers: slots.map(({ slot, word }) => ({ slot, word })),
        bins: { [a.uid]: [], [b.uid]: [], [c.uid]: bin },
      }),
    ]);
    expect(await forge(sc, slots[order[0]!]!.word, 1)).toMatchObject({ result: "too_late" });

    // The next round of the series is survival too.
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await sb.next({ op: "ROUND_START" })).toMatchObject({ round: 2, variant: "survival" });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // into round 2
    await closeAll(...sockets);
  });

  it("pauses a racer's countdown while they're away, and resumes it when they're back", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const code = await createVsRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    await survival(sa, [sb]);
    await start(sa, code, [sa, sb]);
    await patchRound<VsRound>(code, (r) => ({
      ...r,
      survival: { ...r.survival!, clocks: Object.fromEntries(Object.entries(r.survival!.clocks).map(([id, c]) => [id, startedAlready(c)])) },
    }));

    sb.ws.close();
    const paused = await roundWhere<VsRound>(code, (r) => r.survival!.clocks[b.uid]!.pausedAt !== null);
    expect(paused.survival!.clocks[a.uid]!.pausedAt).toBeNull();
    const before = paused.survival!.clocks[b.uid]!;

    await sleep(400);
    const back = await connect(b, `/v1/ws/room/${code}`);
    const snap = await back.next({ op: "SNAPSHOT" });
    const heated = await back.next({ op: "HEATED" });
    const after = (await roundOf<VsRound>(code)).survival!.clocks[b.uid]!;
    expect(after.pausedAt).toBeNull();
    expect(after.deadline - before.deadline).toBeGreaterThanOrEqual(400);
    expect(snap.round).toMatchObject({ variant: "survival", saved: 0, heated: { slot: before.slot, deadline: after.deadline } });
    expect(heated).toMatchObject({ slot: before.slot, deadline: after.deadline, saved: 0 });
    // Only B hears about B's countdown.
    expect((await sa.drain()).filter((m) => m.op === "HEATED")).toEqual([]);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // A's melt, the soonest
    expect(await sa.next({ op: "MELT" })).toMatchObject({ id: a.uid });
    expect(await back.next({ op: "ROUND_END" })).toMatchObject({ reason: "melted", winner: null, how: "none", melted: { id: a.uid } });
    await closeAll(sa, back);
  });
});

async function createVsRoom(c: Client): Promise<string> {
  return createRoom(c, "vs");
}

describe("CONFIG {variant}", () => {
  it("is the host's, in the lobby or results, for the next START or AGAIN", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const code = await createRoom(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    // A classic room never says so.
    expect(sa.seen.find((m) => m.op === "SNAPSHOT")!.lobby).not.toHaveProperty("variant");

    for (const bad of [{}, { variant: "hard" }, { variant: 1 }, { series: 5 }, { variant: "survival", series: 3 }]) {
      sa.send({ op: "CONFIG", ...bad });
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    }
    sb.send({ op: "CONFIG", variant: "survival" });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    await survival(sa, [sb]);
    const startMsg = await start(sa, code, [sa, sb]);
    expect(startMsg).toMatchObject({ variant: "survival" });
    await sleep(1600); // past the per-socket limit on messages other than SUBMIT
    sa.send({ op: "CONFIG", variant: "classic" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });

    // The melt ends the round; in results the host goes back to classic, and AGAIN plays it.
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await sa.next({ op: "ROUND_END" });
    await sa.next({ op: "LOBBY", phase: "results" });
    sa.send({ op: "CONFIG", variant: "classic" });
    expect(await sb.next({ op: "LOBBY", phase: "results", variant: undefined })).not.toHaveProperty("variant");
    const again = await start(sa, code, [sa, sb], "AGAIN");
    expect(again).not.toHaveProperty("variant");
    expect(again).not.toHaveProperty("heated");
    expect(again.endsAt - again.startsAt).toBe(180_000);
    expect((await roundOf(code)).survival).toBeUndefined();
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // its timer
    await closeAll(sa, sb);
  });

  it("goes with the series in Versus, which stays lobby-only", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const code = await createVsRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    for (const bad of [{ variant: "bogus" }, { variant: "survival", series: 4 }, {}]) {
      sa.send({ op: "CONFIG", ...bad });
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    }
    sa.send({ op: "CONFIG", variant: "survival", series: 5 });
    expect(await sb.next({ op: "LOBBY" })).toMatchObject({ series: 5, variant: "survival" });
    sa.send({ op: "CONFIG", series: 3 });
    expect(await sb.next({ op: "LOBBY" })).toMatchObject({ series: 3, variant: "survival" });
    await start(sa, code, [sa, sb]);
    sa.send({ op: "CONFIG", variant: "classic" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // a melt
    await sa.next({ op: "LOBBY", phase: "standings" });
    sa.send({ op: "CONFIG", variant: "classic" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });
    await closeAll(sa, sb);
  });
});

describe("survival snapshots", () => {
  it("show a racer their own heated word, and someone watching none", async () => {
    const [a, b, c] = (await Promise.all([0, 1, 2].map(() => setUpClient()))) as [Smith, Smith, Smith];
    const code = await createVsRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    const sc = await join(c, code);
    await survival(sa, [sb, sc]);
    await start(sa, code, [sa, sb, sc]);
    await patchRound<VsRound>(code, (r) => ({ ...r, embers: [] }));
    const round = await roundOf<VsRound>(code);
    const first = round.survival!.order[0]!;
    await forge(sa, round.puzzle.slots[first]!.word, 1);
    const heated = await sa.next({ op: "HEATED" });

    // A second socket for A (who never left): A's own countdown as it stands.
    const again = await connect(a, `/v1/ws/room/${code}`);
    const snap = (await again.next({ op: "SNAPSHOT" })).round;
    expect(snap).toMatchObject({ variant: "survival", saved: 1, mine: { claims: [{ slot: first }] } });
    expect(snap.heated).toEqual({ ...heated, op: undefined, serverNow: snap.serverNow });
    // B's is still the first one.
    sb.ws.close();
    const backB = await connect(b, `/v1/ws/room/${code}`);
    expect((await backB.next({ op: "SNAPSHOT" })).round).toMatchObject({ saved: 0, heated: { slot: first, saved: 0 } });

    // C leaves the series (it goes on between A and B) and comes back to watch: nothing heated.
    sc.send({ op: "LEAVE" });
    await sc.closed;
    const watcher = await connect(c, `/v1/ws/room/${code}`);
    const watching = (await watcher.next({ op: "SNAPSHOT" })).round;
    expect(watching).toMatchObject({ variant: "survival", heated: null, saved: 0, mine: { claims: [], auto: [] } });
    await closeAll(sa, again, backB, watcher);
  });
});
