/**
 * Switching a room's mode (shared/room-protocol.md "Switching mode"): the
 * host's CONFIG `mode` keeps everyone in the room, back in the lobby.
 */

import { describe, expect, it } from "vitest";
import { body, setUpClient, type Client } from "./helpers";
import { closeAll, connect, type Message, type Socket } from "./sockets";

type Smith = Client & { username: string };

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

async function smiths(n: number): Promise<Smith[]> {
  return (await Promise.all(Array.from({ length: n }, () => setUpClient()))) as Smith[];
}

describe("switching a room's mode", () => {
  it("is the host's call, keeps everyone seated, and sets the new mode up", async () => {
    const [a, b, c] = (await smiths(3)) as [Smith, Smith, Smith];
    const code = await room(a, "coop");
    const sa = await join(a, code);
    const sb = await join(b, code);
    const sc = await join(c, code);
    sb.send({ op: "READY", ready: true });
    for (;;) {
      const lobby = await sa.next({ op: "LOBBY" });
      if (lobby.players.some((p: Message) => p.id === b.uid && p.ready)) break;
    }

    sb.send({ op: "CONFIG", mode: "vs" });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    sa.send({ op: "CONFIG", mode: "solo" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });

    // Co-op to Versus: the default series, nobody ready, the same code.
    sa.send({ op: "CONFIG", mode: "vs" });
    const vs = await sc.next({ op: "LOBBY", mode: "vs" });
    expect(vs).toMatchObject({ code, phase: "lobby", series: 3, scoring: "rounds", hostId: a.uid });
    expect(vs.players.map((p: Message) => [p.id, p.ready])).toEqual([
      [a.uid, false],
      [b.uid, false],
      [c.uid, false],
    ]);
    expect(await body(await a.get(`/v1/rooms/${code}`))).toMatchObject({ mode: "vs", maxPlayers: 5 });

    // Versus to Team Versus, with a Versus setting in the same message: dealt onto teams in join order.
    sa.send({ op: "CONFIG", mode: "team", rule: "first" });
    const team = await sb.next({ op: "LOBBY", mode: "team" });
    expect(team).toMatchObject({ rule: "first" });
    expect(team.players.map((p: Message) => [p.id, p.team])).toEqual([
      [a.uid, 0],
      [b.uid, 1],
      [c.uid, 0],
    ]);
    expect(new Set(team.players.map((p: Message) => p.color)).size).toBe(3);

    // And back to co-op: no teams, no series.
    sa.send({ op: "CONFIG", mode: "coop" });
    const coop = await sa.next({ op: "LOBBY", mode: "coop" });
    expect(coop).not.toHaveProperty("series");
    expect(coop.players.every((p: Message) => p.team === undefined)).toBe(true);
    await closeAll(sa, sb, sc);
  });

  it("turns down a mode with fewer seats than the room has players", async () => {
    const five = await smiths(5);
    const code = await room(five[0]!, "vs");
    const sockets: Socket[] = [];
    for (const s of five) sockets.push(await join(s, code));
    sockets[0]!.send({ op: "CONFIG", mode: "coop" });
    expect(await sockets[0]!.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "too_many_players" });
    // Team Versus seats six.
    sockets[0]!.send({ op: "CONFIG", mode: "team" });
    expect(await sockets[1]!.next({ op: "LOBBY", mode: "team" })).toMatchObject({ phase: "lobby" });
    await closeAll(...sockets);
  });
});
