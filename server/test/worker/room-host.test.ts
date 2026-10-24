import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { MpPuzzle } from "../../src/rules/mold";
import { totalXpForLevel } from "../../src/rules/progression";
import { body, setUpClient, type Client } from "./helpers";
import { closeAll, connect, sleep, type Message, type Socket } from "./sockets";

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

/** START or AGAIN, then the countdown alarm. */
async function start(host: Socket, code: string, sockets: Socket[], op: "START" | "AGAIN" = "START"): Promise<Message> {
  host.send({ op });
  // Co-op's AGAIN waits until everyone is ready (NEXT); the host already is.
  if (op === "AGAIN") for (const s of sockets) if (s !== host) s.send({ op: "NEXT" });
  let first: Message | null = null;
  for (const s of sockets) first = await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first!;
}

/** The next LOBBY on `s` whose host is `hostId`, skipping older ones still queued. */
const hostIs = (s: Socket, hostId: string) => s.next({ op: "LOBBY", hostId });

/** Drops `s` and waits until `watcher` hears of it. */
async function drop(s: Socket, uid: string, watcher: Socket): Promise<void> {
  s.ws.close();
  for (;;) {
    const lobby = await watcher.next({ op: "LOBBY" });
    if (lobby.players.some((p: Message) => p.id === uid && !p.connected)) return;
  }
}

describe("the host role", () => {
  it("goes to someone connected when the host leaves, and stays there when the others are back", async () => {
    const [a, b, c] = [await setUpClient(), await setUpClient(), await setUpClient()];
    const code = await createRoom(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    const sc = await join(c, code);
    // B, who joined next, is away (inside their rejoin time) when A leaves: C gets it.
    await drop(sb, b.uid, sc);
    sa.send({ op: "LEAVE" });
    await sa.closed;
    expect((await hostIs(sc, c.uid)).players.map((p: Message) => p.id)).toEqual([b.uid, c.uid]);
    const backB = await join(b, code);
    expect(backB.seen.find((m) => m.op === "SNAPSHOT")!.lobby.hostId).toBe(c.uid);
    // A comes back as a newcomer, not as host.
    const backA = await join(a, code);
    expect(backA.seen.find((m) => m.op === "SNAPSHOT")!.lobby).toMatchObject({ hostId: c.uid });
    sc.send({ op: "START" });
    await backA.next({ op: "ROUND_START" });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await closeAll(backA, backB, sc);
  });

  it("moves on in the lobby once the host has been away longer than the rejoin time", async () => {
    const [a, b] = [await setUpClient(), await setUpClient()];
    // A high-level host: the auto heat is theirs, then B's.
    await env.DB.prepare("UPDATE profiles SET xp = ?2, level = 40 WHERE user_id = ?1").bind(a.uid, totalXpForLevel(40)).run();
    const code = await createRoom(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    expect(sb.seen.find((m) => m.op === "SNAPSHOT")!.lobby).toMatchObject({ hostId: a.uid, heat: 4 });
    await drop(sa, a.uid, sb);
    // Inside the rejoin time A is still host; after it, B is, and the heat follows B's level.
    expect(await body(await b.get(`/v1/rooms/${code}`))).toMatchObject({ host: { id: a.uid } });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await hostIs(sb, b.uid)).toMatchObject({ heat: 1, autoHeat: 1 });
    // B can do what hosts do; A, back, can't.
    sb.send({ op: "CONFIG", heat: 2 });
    await sb.next({ op: "LOBBY", heatChoice: 2 });
    const back = await join(a, code);
    back.send({ op: "START" });
    expect(await back.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    expect(await start(sb, code, [sb, back])).toMatchObject({ heat: 2 });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await closeAll(sb, back);
  });

  it("moves on in results, so the others can forge again", async () => {
    const [a, b] = [await setUpClient(), await setUpClient()];
    const code = await createRoom(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    await start(sa, code, [sa, sb]);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await sb.next({ op: "ROUND_END" });
    await sb.next({ op: "LOBBY", phase: "results" });
    await drop(sa, a.uid, sb);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect((await hostIs(sb, b.uid)).players.map((p: Message) => p.id)).toEqual([b.uid]);
    expect(await start(sb, code, [sb], "AGAIN")).toMatchObject({ round: 2 });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await closeAll(sb);
  });

  it("moves on mid-round, and the old host coming back doesn't take it back", async () => {
    const [a, b] = [await setUpClient(), await setUpClient()];
    const code = await createRoom(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    await start(sa, code, [sa, sb]);
    await drop(sa, a.uid, sb);
    // A's rejoin time runs out before the round's timer.
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await hostIs(sb, b.uid)).toMatchObject({ phase: "round" });
    const back = await join(a, code);
    expect(back.seen.find((m) => m.op === "SNAPSHOT")!.lobby).toMatchObject({ hostId: b.uid, phase: "round" });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await back.next({ op: "ROUND_END" });
    back.send({ op: "AGAIN" });
    expect(await back.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    expect(await start(sb, code, [sb, back], "AGAIN")).toMatchObject({ round: 2 });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await closeAll(sb, back);
  });

  it("moves on mid-series in Versus, and the new host starts the rematch", async () => {
    const [a, b, c] = [await setUpClient(), await setUpClient(), await setUpClient()];
    const code = await createRoom(a, "vs");
    const sa = await join(a, code);
    const sb = await join(b, code);
    const sc = await join(c, code);
    await start(sa, code, [sa, sb, sc]);
    await drop(sa, a.uid, sb);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await hostIs(sc, b.uid);
    // B and C race on; B forges a word in each round and wins the best of 3 in two.
    const word = async () => runInDurableObject(stub(code), (_i, state) => state.storage.kv.get<{ puzzle: MpPuzzle }>("round")!.puzzle.slots[0]!.word);
    for (let round = 1; round <= 2; round++) {
      if (round === 2) {
        expect(await runDurableObjectAlarm(stub(code))).toBe(true);
        await sb.next({ op: "ROUND_START" });
        expect(await runDurableObjectAlarm(stub(code))).toBe(true);
        await sb.next({ op: "LOBBY", phase: "round" });
      }
      sb.send({ op: "SUBMIT", word: await word(), seq: round });
      expect(await sb.next({ op: "WORD_RESULT", seq: round })).toMatchObject({ result: "claimed" });
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      await sb.next({ op: "ROUND_END" });
    }
    expect(await sc.next({ op: "SERIES_END" })).toMatchObject({ winner: b.uid });
    await sleep(300);
    expect(await start(sb, code, [sb, sc], "AGAIN")).toMatchObject({ round: 1, players: [b.uid, c.uid] });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await closeAll(sb, sc);
  });
});
