/**
 * Between rounds (shared/room-protocol.md, "Between rounds"): the Versus
 * standings last 30 s and co-op waits 20 s after AGAIN, and either ends as
 * soon as everyone who'll play the next round is ready (NEXT).
 */

import { runDurableObjectAlarm } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { COOP_NEXT_MS } from "../../src/rules/room";
import { STANDINGS_MS } from "../../src/rules/vs-round";
import { body, setUpClient, type Client } from "./helpers";

type Smith = Client & { username: string };
import { closeAll, connect, sleep, type Message, type Socket } from "./sockets";

function stub(code: string) {
  return env.ROOM.get(env.ROOM.idFromName(code));
}

async function room(c: Client, mode: "coop" | "vs"): Promise<string> {
  const res = await c.post("/v1/rooms", { mode });
  expect(res.status).toBe(200);
  return (await body<{ code: string }>(res)).code;
}

async function join(c: Client, code: string): Promise<Socket> {
  const s = await connect(c, `/v1/ws/room/${code}`);
  await s.next({ op: "SNAPSHOT" });
  return s;
}

/** START, then the countdown, then the round's timer: the round ends with nobody having forged anything. */
async function playARound(host: Socket, code: string, sockets: Socket[], end: "ROUND_END" = "ROUND_END"): Promise<Message> {
  host.send({ op: "START" });
  for (const s of sockets) await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true); // into the round
  expect(await runDurableObjectAlarm(stub(code))).toBe(true); // its timer
  let last: Message | null = null;
  for (const s of sockets) last = await s.next({ op: end });
  return last!;
}

/** The next LOBBY on `s` that has a `nextAt` (or, with `waiting: false`, none). */
async function lobbyWaiting(s: Socket, waiting = true): Promise<Message> {
  for (;;) {
    const lobby = await s.next({ op: "LOBBY" });
    if ((typeof lobby.nextAt === "number") === waiting) return lobby;
  }
}

const readyOf = (lobby: Message, uid: string) => lobby.players.find((p: Message) => p.id === uid)?.ready;

/** The next LOBBY on `s` in which `uid` is ready, skipping older ones still queued. */
async function lobbyReady(s: Socket, uid: string): Promise<Message> {
  for (;;) {
    const lobby = await s.next({ op: "LOBBY" });
    if (readyOf(lobby, uid) === true) return lobby;
  }
}

describe("co-op: the wait after AGAIN", () => {
  it("lasts 20 s, with the host ready, and starts as soon as everyone else is too", async () => {
    const [a, b, c] = (await Promise.all([0, 1, 2].map(() => setUpClient()))) as [Smith, Smith, Smith];
    const code = await room(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    const sc = await join(c, code);

    // Not ready for anything yet: there's no wait in the lobby.
    sb.send({ op: "NEXT" });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });

    await playARound(sa, code, [sa, sb, sc]);
    const before = Date.now();
    sa.send({ op: "AGAIN" });
    const waiting = await lobbyWaiting(sb);
    expect(waiting.phase).toBe("results");
    expect(waiting.nextAt - before).toBeGreaterThanOrEqual(COOP_NEXT_MS - 1000);
    expect(waiting.nextAt - Date.now()).toBeLessThanOrEqual(COOP_NEXT_MS);
    expect([readyOf(waiting, a.uid), readyOf(waiting, b.uid), readyOf(waiting, c.uid)]).toEqual([true, false, false]);

    // Another AGAIN changes nothing; b being ready isn't everyone.
    sa.send({ op: "AGAIN" });
    sb.send({ op: "NEXT" });
    const oneMore = await lobbyReady(sa, b.uid);
    expect(oneMore.nextAt).toBe(waiting.nextAt);
    expect(sa.seen.some((m) => m.op === "ROUND_START" && m.round === 2)).toBe(false);

    // c too: the countdown starts now, and readiness is cleared for next time.
    sc.send({ op: "NEXT" });
    expect(await sa.next({ op: "ROUND_START" })).toMatchObject({ round: 2 });
    const counting = await lobbyWaiting(sa, false);
    expect(counting.phase).toBe("countdown");
    expect(counting.players.every((p: Message) => p.ready === false)).toBe(true);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // into round 2
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // its timer
    await closeAll(sa, sb, sc);
  });

  it("starts by itself when the wait runs out", async () => {
    const [a, b] = (await Promise.all([0, 1].map(() => setUpClient()))) as [Smith, Smith];
    const code = await room(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    await playARound(sa, code, [sa, sb]);
    sa.send({ op: "AGAIN" });
    await lobbyWaiting(sb);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // the wait's end
    expect(await sb.next({ op: "ROUND_START" })).toMatchObject({ round: 2 });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await closeAll(sa, sb);
  });

  it("starts when the only player who wasn't ready leaves", async () => {
    const [a, b, c] = (await Promise.all([0, 1, 2].map(() => setUpClient()))) as [Smith, Smith, Smith];
    const code = await room(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    const sc = await join(c, code);
    await playARound(sa, code, [sa, sb, sc]);
    sa.send({ op: "AGAIN" });
    await lobbyWaiting(sa);
    sb.send({ op: "NEXT" });
    await lobbyReady(sa, b.uid);
    sc.send({ op: "LEAVE" });
    expect(await sa.next({ op: "ROUND_START" })).toMatchObject({ round: 2 });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await closeAll(sa, sb);
  });
});

describe("Versus: the standings", () => {
  it("last 30 s, and end as soon as every racer is ready", async () => {
    const [a, b] = (await Promise.all([0, 1].map(() => setUpClient()))) as [Smith, Smith];
    const code = await room(a, "vs");
    const sa = await join(a, code);
    const sb = await join(b, code);
    const ended = Date.now();
    const end = await playARound(sa, code, [sa, sb]);
    expect(end.next).toMatchObject({ round: 2 });
    expect(end.standingsEndsAt - ended).toBeGreaterThanOrEqual(STANDINGS_MS - 1000);
    expect(STANDINGS_MS).toBe(30_000);
    await sa.next({ op: "LOBBY", phase: "standings" });

    sa.send({ op: "NEXT" });
    const one = await lobbyReady(sb, a.uid);
    expect([one.phase, readyOf(one, b.uid)]).toEqual(["standings", false]);
    sb.send({ op: "NEXT" });
    expect(await sa.next({ op: "ROUND_START" })).toMatchObject({ round: 2 });
    const counting = await sa.next({ op: "LOBBY", phase: "countdown" });
    expect(counting.players.every((p: Message) => p.ready === false)).toBe(true);

    // NEXT is for between rounds.
    await sleep(600);
    sa.send({ op: "NEXT" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // into round 2
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // its timer
    await closeAll(sa, sb);
  });
});
