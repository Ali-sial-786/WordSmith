/**
 * Team Versus rooms (shared/room-protocol.md "Team Versus"): two teams,
 * TEAM moves, even teams to start, and the two ways a round is won.
 */

import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { VsRound, VsSeries } from "../../src/rules/vs-round";
import { befriend, body, setUpClient, type Client } from "./helpers";
import { closeAll, connect, openSocket, sleep, type Message, type Socket } from "./sockets";

type Smith = Client & { username: string };

function stub(code: string) {
  return env.ROOM.get(env.ROOM.idFromName(code));
}

async function createTeamRoom(c: Client): Promise<string> {
  const res = await c.post("/v1/rooms", { mode: "team" });
  expect(res.status, await res.clone().text()).toBe(200);
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

async function seriesOf(code: string): Promise<VsSeries> {
  return runInDurableObject(stub(code), (_instance, state) => state.storage.kv.get<VsSeries>("series")!);
}

async function me(c: Client): Promise<Message> {
  return body<Message>(await c.get("/v1/me"));
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

/** Forges every word still missing from `uid`'s mold. */
async function fillMold(s: Socket, code: string, uid: string, seq: number): Promise<void> {
  const { puzzle } = await roundOf(code);
  for (const slot of puzzle.slots) {
    const mold = (await roundOf(code)).molds[uid]!;
    if ([...mold.claims, ...mold.auto].some((c) => c.slot === slot.slot)) continue;
    expect((await forge(s, slot.word, seq++)).result).toBe("claimed");
  }
}

/** START (or AGAIN), then skip the countdown. */
async function start(host: Socket, code: string, sockets: Socket[], op: "START" | "AGAIN" = "START"): Promise<Message> {
  host.send({ op });
  let first: Message | null = null;
  for (const s of sockets) first = await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first!;
}

/** After the standings: into the next round. */
async function nextRound(code: string, sockets: Socket[]): Promise<Message> {
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  let first: Message | null = null;
  for (const s of sockets) first = await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first!;
}

/** The next LOBBY on `s` whose players are on these teams. */
async function lobbyWithTeams(s: Socket, teams: Record<string, number>): Promise<Message> {
  for (;;) {
    const lobby = await s.next({ op: "LOBBY" });
    if (Object.entries(teams).every(([id, team]) => lobby.players.some((p: Message) => p.id === id && p.team === team))) return lobby;
  }
}

/** Four smiths in a Team Versus room: a and c on Copper, b and d on Cobalt (as they join). */
async function fourInARoom(): Promise<{ smiths: [Smith, Smith, Smith, Smith]; code: string; sockets: [Socket, Socket, Socket, Socket] }> {
  const smiths = (await Promise.all([0, 1, 2, 3].map(() => setUpClient()))) as [Smith, Smith, Smith, Smith];
  const code = await createTeamRoom(smiths[0]);
  const sockets: Socket[] = [];
  for (const s of smiths) sockets.push(await join(s, code));
  return { smiths, code, sockets: sockets as [Socket, Socket, Socket, Socket] };
}

describe("Team Versus rooms", () => {
  it("hold six, put newcomers on the smaller team, and list for friends", async () => {
    const host = await setUpClient();
    const friend = await setUpClient();
    await befriend(host, friend);
    const hub = await connect(friend, "/v1/ws/hub");
    await hub.next({ op: "OPEN_ROOMS" });
    const code = await createTeamRoom(host);
    expect(await body(await host.get(`/v1/rooms/${code}`))).toMatchObject({ code, mode: "team", maxPlayers: 6, players: 1 });
    expect(await hub.next({ op: "OPEN_ROOMS" })).toEqual({
      op: "OPEN_ROOMS",
      rooms: [{ code, mode: "team", hostId: host.uid, hostUsername: host.username, players: 1, max: 6 }],
    });

    const sh = await connect(host, `/v1/ws/room/${code}`);
    const snap = await sh.next({ op: "SNAPSHOT" });
    expect(snap.lobby).toMatchObject({ mode: "team", series: 3, rule: "combined" });
    expect(snap.lobby.players).toEqual([expect.objectContaining({ id: host.uid, color: 0, team: 0 })]);

    const others = (await Promise.all([0, 1, 2, 3, 4, 5].map(() => setUpClient()))) as Smith[];
    const sockets = [sh];
    for (const o of others.slice(0, 5)) sockets.push(await join(o, code));
    const lobby = sockets[5]!.seen.find((m) => m.op === "SNAPSHOT")!.lobby;
    expect(lobby.players.map((p: Message) => [p.color, p.team])).toEqual([
      [0, 0],
      [1, 1],
      [2, 0],
      [3, 1],
      [4, 0],
      [5, 1],
    ]);
    const full = await openSocket(others[5]!, `/v1/ws/room/${code}`);
    expect(full.status).toBe(409);
    expect(await full.json()).toEqual({ error: "room_full" });
    await closeAll(hub, ...sockets);
  });

  it("moves players between teams, and starts only with even teams", async () => {
    const [a, b, c] = (await Promise.all([0, 1, 2].map(() => setUpClient()))) as [Smith, Smith, Smith];
    const code = await createTeamRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    const sc = await join(c, code);
    await lobbyWithTeams(sa, { [a.uid]: 0, [b.uid]: 1, [c.uid]: 0 });

    // Three players can't be two even teams.
    sa.send({ op: "START" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "uneven_teams" });

    // Anyone moves themselves; only the host moves someone else.
    sc.send({ op: "TEAM", team: 1 });
    await lobbyWithTeams(sa, { [c.uid]: 1 });
    sb.send({ op: "TEAM", team: 0, id: c.uid });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    sa.send({ op: "TEAM", team: 0, id: "nobody" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_in_room" });
    sa.send({ op: "TEAM", team: 2 });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });

    // A fourth, then a full team of three.
    const d = await setUpClient();
    const sd = await join(d, code);
    await lobbyWithTeams(sa, { [d.uid]: 0 });
    sa.send({ op: "TEAM", team: 1 });
    await lobbyWithTeams(sa, { [a.uid]: 1, [b.uid]: 1, [c.uid]: 1, [d.uid]: 0 });
    sd.send({ op: "TEAM", team: 1 });
    expect(await sd.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "team_full" });
    sa.send({ op: "START" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "uneven_teams" });

    // CONFIG rule: the host's; survival isn't for teams.
    sb.send({ op: "CONFIG", rule: "first" });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    sa.send({ op: "CONFIG", rule: "fastest" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    sa.send({ op: "CONFIG", variant: "survival" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    sa.send({ op: "CONFIG", rule: "first" });
    expect(await sb.next({ op: "LOBBY", rule: "first" })).toMatchObject({ rule: "first" });

    // Leaving the lobby takes the player off their team: 2 against 1, still uneven.
    sd.send({ op: "LEAVE" });
    await sa.next({ op: "LOBBY" });
    sb.send({ op: "TEAM", team: 0 });
    const even = await lobbyWithTeams(sa, { [a.uid]: 1, [b.uid]: 0, [c.uid]: 1 });
    expect(even.players).toHaveLength(3);
    sa.send({ op: "START" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "uneven_teams" });
    await sleep(1200); // past the per-socket limit
    // With c gone it's one against one, which is even.
    sc.send({ op: "LEAVE" });
    await sa.next({ op: "LOBBY" });
    const first = await start(sa, code, [sa, sb]);
    expect(first).toMatchObject({ rule: "first", teams: { [a.uid]: 1, [b.uid]: 0 }, teamTally: [0, 0], players: [a.uid, b.uid] });
    // TEAM waits for the series to end.
    sb.send({ op: "TEAM", team: 1 });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // the round's timer
    await closeAll(sa, sb);
  });

  it(
    "combined: a team wins once both its smiths have filled their molds, and the series is written as Versus",
    async () => {
      const { smiths, code, sockets } = await fourInARoom();
      const [a, b, c, d] = smiths;
      const [sa, sb, sc, sd] = sockets;
      const ids = smiths.map((s) => s.uid);

      const start1 = await start(sa, code, sockets);
      expect(start1).toMatchObject({
        rule: "combined",
        teams: { [a.uid]: 0, [b.uid]: 1, [c.uid]: 0, [d.uid]: 1 },
        teamTally: [0, 0],
        players: ids,
      });

      // Round 1: a fills their mold, and the round goes on; c fills theirs and Copper wins.
      await fillMold(sa, code, a.uid, 1);
      await fillMold(sb, code, b.uid, 1);
      expect(sd.seen.some((m) => m.op === "ROUND_END")).toBe(false);
      await fillMold(sc, code, c.uid, 1);
      const end1 = await sd.next({ op: "ROUND_END" });
      const total = (await roundOf(code)).total;
      expect(end1).toMatchObject({
        round: 1,
        reason: "finished",
        winner: null,
        how: "finished",
        team: 0,
        teamScores: [2 * total, total],
        teamTally: [1, 0],
        rule: "combined",
        tally: { [a.uid]: 1, [c.uid]: 1, [b.uid]: 0, [d.uid]: 0 },
        next: { round: 2, suddenDeath: false, players: ids },
      });

      // Round 2: the timer, with Copper ahead on letters added up: Copper takes the series 2–0.
      const start2 = await nextRound(code, sockets);
      expect(start2.teamTally).toEqual([1, 0]);
      const r2 = await roundOf(code);
      const [w1, w2] = r2.puzzle.slots;
      await forge(sa, w1!.word, 50);
      await forge(sc, w2!.word, 50);
      await forge(sd, w1!.word, 50);
      expect(await runDurableObjectAlarm(stub(code))).toBe(true); // the timer
      const end2 = await sa.next({ op: "ROUND_END" });
      expect(end2).toMatchObject({ how: "timeout", team: 0, teamTally: [2, 0], next: null });
      const series = await sa.next({ op: "SERIES_END" });
      expect(series).toMatchObject({ winner: null, team: 0, rule: "combined", teamTally: [2, 0], early: true, forfeit: false, rounds: 2 });
      expect(series.podium.map((p: Message) => [p.id, p.team, p.place, p.wins])).toEqual([
        [a.uid, 0, 1, 2],
        [c.uid, 0, 1, 2],
        [b.uid, 1, 2, 0],
        [d.uid, 1, 2, 0],
      ]);
      expect(series.history.map((h: Message) => [h.team, h.teamScores?.[0] > h.teamScores?.[1]])).toEqual([
        [0, true],
        [0, true],
      ]);
      // 5 per round raced, 10 per round the team won, 30 for the series.
      expect(series.xp[a.uid].xp).toBe(10 + 20 + 30);
      expect(series.xp[b.uid].xp).toBe(10);

      const { matchId } = await seriesOf(code);
      const match = await env.DB.prepare("SELECT mode, summary FROM matches WHERE id = ?1").bind(matchId).first<Message>();
      expect(match!.mode).toBe("vs");
      expect(JSON.parse(match!.summary as string)).toMatchObject({
        teams: { rule: "combined", winner: 0, members: { [a.uid]: 0, [b.uid]: 1, [c.uid]: 0, [d.uid]: 1 } },
      });
      for (const s of smiths) {
        const won = s === a || s === c;
        expect((await me(s)).stats).toMatchObject({ vsSeries: 1, vsSeriesWon: won ? 1 : 0, vsRoundsWon: won ? 2 : 0 });
      }

      // AGAIN keeps the teams.
      const again = await start(sa, code, sockets, "AGAIN");
      expect(again).toMatchObject({ round: 1, teamTally: [0, 0], teams: start1.teams });
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      await closeAll(...sockets);
    },
    60_000,
  );

  it(
    "first: whoever finishes first wins the round for their team, and a team that leaves forfeits",
    async () => {
      const { smiths, code, sockets } = await fourInARoom();
      const [a, b, , d] = smiths;
      const [sa, sb, sc, sd] = sockets;
      sa.send({ op: "CONFIG", rule: "first" });
      await sd.next({ op: "LOBBY", rule: "first" });

      await start(sa, code, sockets);
      await fillMold(sd, code, d.uid, 1);
      const end1 = await sa.next({ op: "ROUND_END" });
      expect(end1).toMatchObject({ winner: d.uid, how: "finished", team: 1, teamTally: [0, 1], rule: "first" });

      // Round 2: Cobalt leaves, and Copper wins by forfeit.
      await nextRound(code, sockets);
      sb.send({ op: "LEAVE" });
      await sa.next({ op: "LOBBY" });
      sd.send({ op: "LEAVE" });
      const end2 = await sa.next({ op: "ROUND_END" });
      expect(end2).toMatchObject({ round: 2, next: null });
      const series = await sa.next({ op: "SERIES_END" });
      expect(series).toMatchObject({ team: 0, forfeit: true, teamTally: [0, 1] });
      expect(series.podium.filter((p: Message) => p.place === 1).map((p: Message) => p.team)).toEqual([0, 0]);
      expect(series.xp[b.uid]).toBeDefined();
      expect((await me(a)).stats).toMatchObject({ vsSeriesWon: 1 });
      expect((await me(d)).stats).toMatchObject({ vsSeriesWon: 0, vsRoundsWon: 1 });
      await closeAll(sa, sc);
    },
    60_000,
  );

  it("keeps TEAM and rule out of other rooms", async () => {
    const a = await setUpClient();
    const res = await a.post("/v1/rooms", { mode: "vs" });
    const { code } = await body<{ code: string }>(res);
    const sa = await join(a, code);
    expect(sa.seen.find((m) => m.op === "SNAPSHOT")!.lobby).not.toHaveProperty("rule");
    sa.send({ op: "TEAM", team: 1 });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    sa.send({ op: "CONFIG", rule: "first" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    expect((await a.post("/v1/rooms", { mode: "teams" })).status).toBe(400);
    await closeAll(sa);
  });
});
