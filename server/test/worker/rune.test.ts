/**
 * Rune Grid and Team Rune Grid (shared/rune-grid.md): the letter-grid race,
 * through real sockets, D1 and alarms.
 */

import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { RuneRound, RuneSeries } from "../../src/rules/rune";
import { body, setUpClient, type Client } from "./helpers";
import { closeAll, connect, sleep, type Message, type Socket } from "./sockets";

function stub(code: string) {
  return env.ROOM.get(env.ROOM.idFromName(code));
}

async function createRoom(c: Client, mode: "rune" | "runeteam"): Promise<string> {
  const res = await c.post("/v1/rooms", { mode });
  expect(res.status, await res.clone().text()).toBe(200);
  return (await body<{ code: string }>(res)).code;
}

async function join(c: Client, code: string): Promise<Socket> {
  const s = await connect(c, `/v1/ws/room/${code}`);
  await s.next({ op: "SNAPSHOT" });
  return s;
}

/** The round as the room stores it, with every word on the board. */
async function roundOf(code: string): Promise<RuneRound> {
  return runInDurableObject(stub(code), (_instance, state) => state.storage.kv.get<RuneRound>("round")!);
}

async function seriesOf(code: string): Promise<RuneSeries> {
  return runInDurableObject(stub(code), (_instance, state) => state.storage.kv.get<RuneSeries>("series")!);
}

const lastSubmit = new WeakMap<Socket, number>();

/** Sends a word and waits for its WORD_RESULT, keeping each socket under the SUBMIT rate limit. */
async function find(s: Socket, word: string, seq: number): Promise<Message> {
  const wait = (lastSubmit.get(s) ?? 0) + 270 - Date.now();
  if (wait > 0) await sleep(wait);
  lastSubmit.set(s, Date.now());
  s.send({ op: "SUBMIT", word, seq });
  return s.next({ op: "WORD_RESULT", seq });
}

/** The next LOBBY on `s` whose `key` is `value`, skipping older ones still queued. */
async function lobbyWith(s: Socket, check: (m: Message) => boolean): Promise<Message> {
  for (;;) {
    const lobby = await s.next({ op: "LOBBY" });
    if (check(lobby)) return lobby;
  }
}

/** START (or AGAIN), then skip the 3 s countdown by running the alarm. */
async function start(host: Socket, code: string, sockets: Socket[], op: "START" | "AGAIN" = "START"): Promise<Message> {
  host.send({ op });
  let first: Message | null = null;
  for (const s of sockets) first = await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first!;
}

/** After the standings: the alarm starts the next countdown, and the next alarm the round. */
async function nextRound(code: string, sockets: Socket[]): Promise<Message> {
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  let first: Message | null = null;
  for (const s of sockets) first = await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first!;
}

describe("Rune Grid", () => {
  it(
    "sets up in the lobby, plays its rounds on fresh grids, scores unique words double, and ends on the total with XP",
    async () => {
      const a = await setUpClient();
      const b = await setUpClient();
      const code = await createRoom(a, "rune");
      const sa = await join(a, code);
      const sb = await join(b, code);

      // The lobby has the settings, and no series, variant or scoring.
      const first = await sa.next({ op: "LOBBY" });
      expect(first).toMatchObject({ mode: "rune", rune: { size: 4, seconds: 180, min: 3, rounds: 3, teamScoring: "pooled" } });
      expect(first).not.toHaveProperty("series");
      expect(first).not.toHaveProperty("scoring");

      // Only the host sets it up, with known settings; team scoring is Team Rune Grid's.
      sb.send({ op: "CONFIG", rune: { size: 5 } });
      expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
      sa.send({ op: "CONFIG", rune: { size: 7 } });
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
      sa.send({ op: "CONFIG", rune: { teamScoring: "sum" } });
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
      sa.send({ op: "CONFIG", series: 5 });
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
      sa.send({ op: "CONFIG", rune: { size: 5, seconds: 60, rounds: 3, min: 3 } });
      expect(await lobbyWith(sb, (l) => l.rune.size === 5)).toMatchObject({ rune: { size: 5, seconds: 60, min: 3, rounds: 3 } });

      // Round 1: the same 5×5 grid for everyone, and nothing of its words.
      const roundStart = await start(sa, code, [sa, sb]);
      expect(roundStart).toMatchObject({ game: "rune", round: 1, rounds: 3, tiebreak: false, size: 5, min: 3, seconds: 60, players: [a.uid, b.uid] });
      expect(roundStart.tiles).toHaveLength(25);
      expect(roundStart.endsAt - roundStart.startsAt).toBe(60_000);
      expect(roundStart.totals).toEqual({ [a.uid]: 0, [b.uid]: 0 });
      const round = await roundOf(code);
      expect(JSON.stringify(roundStart)).not.toContain(`"${round.words[0]}"`);
      expect(round.words.length).toBeGreaterThan(20);

      // A finds the longest word and a short one; B finds the short one too.
      const [long] = round.words;
      const short = round.words.findLast((w) => w.length === 3) ?? round.words.at(-1)!;
      expect(await find(sa, long!.toLowerCase(), 1)).toMatchObject({ result: "found", word: long, points: Math.max(1, long!.length - 2) });
      expect(await sb.next({ op: "RUNE_TALLY", id: a.uid })).toEqual({ op: "RUNE_TALLY", id: a.uid, words: 1 });
      expect(await find(sa, long!, 2)).toMatchObject({ result: "already", by: a.uid });
      expect(await find(sa, "QQQQ", 3)).toMatchObject({ result: "invalid" });
      expect(await find(sa, short, 4)).toMatchObject({ result: "found" });
      expect(await find(sb, short, 5)).toMatchObject({ result: "found" });
      // No hints in Rune Grid.
      sa.send({ op: "HINT", kind: "hammer" });
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "no_hints" });

      // Back mid-round: the SNAPSHOT has the grid, my words and everyone's tally.
      sb.ws.close();
      await lobbyWith(sa, (l) => l.players.some((p: Message) => p.id === b.uid && !p.connected));
      let sb2 = await connect(b, `/v1/ws/room/${code}`);
      const snap = await sb2.next({ op: "SNAPSHOT" });
      expect(snap.round).toMatchObject({ game: "rune", round: 1, tiles: roundStart.tiles, tally: { [a.uid]: 2, [b.uid]: 1 } });
      expect(snap.round.mine).toEqual([{ word: short, by: b.uid, points: Math.max(1, short.length - 2) }]);

      // Time's up: the long word was A's alone (doubled), the short one shared.
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      const end = await sa.next({ op: "ROUND_END" });
      const longPoints = Math.max(1, long!.length - 2) * 2;
      const shortPoints = Math.max(1, short.length - 2);
      expect(end).toMatchObject({
        game: "rune",
        round: 1,
        winner: a.uid,
        points: { [a.uid]: longPoints + shortPoints, [b.uid]: shortPoints },
        totals: { [a.uid]: longPoints + shortPoints, [b.uid]: shortPoints },
        next: { round: 2, tiebreak: false, players: [a.uid, b.uid] },
        tiles: roundStart.tiles,
        total: round.words.length,
      });
      expect(end.found[a.uid]).toEqual([
        { word: long, points: longPoints, unique: true },
        { word: short, points: shortPoints, unique: false },
      ]);
      expect(end.words[0]).toBe(long);
      await lobbyWith(sa, (l) => l.phase === "standings");
      // Too late now.
      expect(await find(sb2, short, 6)).toMatchObject({ result: "too_late" });

      // Everyone ready skips the standings.
      sa.send({ op: "NEXT" });
      sb2.send({ op: "NEXT" });
      const second = await sa.next({ op: "ROUND_START" });
      expect(second).toMatchObject({ round: 2, totals: { [a.uid]: longPoints + shortPoints, [b.uid]: shortPoints } });
      expect(second.tiles).not.toEqual(roundStart.tiles);
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      await lobbyWith(sa, (l) => l.phase === "round");

      // Round 2: B finds the three longest words; round 3: nobody finds anything.
      const round2 = await roundOf(code);
      let seq = 10;
      let bPoints = 0;
      for (const w of round2.words.slice(0, 3)) {
        expect(await find(sb2, w, seq++)).toMatchObject({ result: "found" });
        bPoints += Math.max(1, w.length - 2) * 2;
      }
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      expect(await sa.next({ op: "ROUND_END" })).toMatchObject({ round: 2, winner: b.uid });
      await nextRound(code, [sa]);
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      const last = await sa.next({ op: "ROUND_END" });
      expect(last).toMatchObject({ round: 3, winner: null, next: null, standingsEndsAt: null });

      // The results: on the total, written as a Versus series with XP.
      const series = await sa.next({ op: "SERIES_END" });
      const aTotal = longPoints + shortPoints;
      const bTotal = shortPoints + bPoints;
      const winner = aTotal > bTotal ? a.uid : b.uid;
      expect(series).toMatchObject({ game: "rune", winner, scoring: "total", rounds: 3, forfeit: false, early: false, history: [] });
      expect(series.podium.map((p: Message) => [p.id, p.place, p.score])).toEqual(
        winner === a.uid
          ? [
              [a.uid, 1, aTotal],
              [b.uid, 2, bTotal],
            ]
          : [
              [b.uid, 1, bTotal],
              [a.uid, 2, aTotal],
            ],
      );
      expect(series.rune.history.map((h: Message) => h.round)).toEqual([1, 2, 3]);
      expect(series.rune.words).toEqual({ [a.uid]: 2, [b.uid]: 4 });
      expect(series.rune.settings).toMatchObject({ size: 5, seconds: 60, rounds: 3 });
      expect(series.xp[a.uid].xp).toBeGreaterThan(0);
      expect(series.xp[b.uid].xp).toBeGreaterThan(0);
      const lobby = await lobbyWith(sa, (l) => l.phase === "results");
      expect(lobby.rune).toMatchObject({ size: 5 });

      // Back during the results: the SERIES_END and the last round, from the SNAPSHOT.
      sb2.ws.close();
      await lobbyWith(sa, (l) => l.players.some((p: Message) => p.id === b.uid && !p.connected));
      sb2 = await connect(b, `/v1/ws/room/${code}`);
      const again = await sb2.next({ op: "SNAPSHOT" });
      expect(again.results).toMatchObject({ game: "rune", winner });
      expect(again.standings).toMatchObject({ game: "rune", round: 3 });

      // The match is in D1, marked as Rune Grid.
      const match = await env.DB.prepare("SELECT mode, summary FROM matches WHERE id = ?1")
        .bind((await seriesOf(code)).matchId)
        .first<{ mode: string; summary: string }>();
      expect(match!.mode).toBe("vs");
      expect(JSON.parse(match!.summary)).toMatchObject({ game: "rune", scoring: "total", rune: { size: 5 } });

      // The host can switch it to Team Rune Grid, which deals out teams.
      sa.send({ op: "CONFIG", mode: "runeteam", rune: { teamScoring: "sum" } });
      const team = await lobbyWith(sb2, (l) => l.mode === "runeteam");
      expect(team).toMatchObject({ phase: "lobby", rune: { size: 5, teamScoring: "sum" } });
      expect(team.players.map((p: Message) => p.team)).toEqual([0, 1]);
      await closeAll(sa, sb2);
    },
    30_000,
  );

  it("ends by forfeit when the other racer leaves, and a lone tie goes to a tiebreaker between the leaders", async () => {
    const [a, b, c] = await Promise.all([setUpClient(), setUpClient(), setUpClient()]);
    const code = await createRoom(a, "rune");
    const sa = await join(a, code);
    const sb = await join(b, code);
    const sc = await join(c, code);
    sa.send({ op: "CONFIG", rune: { rounds: 1 } });
    await lobbyWith(sa, (l) => l.rune.rounds === 1);
    await start(sa, code, [sa, sb, sc]);

    // A and B find a word of the same length each, C nothing: a tie between A and B.
    const round = await roundOf(code);
    const pair = round.words.filter((w) => w.length === round.words.at(-1)!.length).slice(0, 2);
    expect(await find(sa, pair[0]!, 1)).toMatchObject({ result: "found" });
    expect(await find(sb, pair[1]!, 2)).toMatchObject({ result: "found" });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    const end = await sa.next({ op: "ROUND_END" });
    expect(end).toMatchObject({ winner: null, next: { round: 2, tiebreak: true, players: [a.uid, b.uid] } });

    // The tiebreaker: only A and B race; C watches.
    const tiebreak = await nextRound(code, [sa, sb, sc]);
    expect(tiebreak).toMatchObject({ round: 2, tiebreak: true, players: [a.uid, b.uid] });
    sc.send({ op: "SUBMIT", word: (await roundOf(code)).words[0], seq: 9 });
    expect(await sc.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_playing" });

    // B leaves mid-round: out, but C is still in the game, so it goes on; A wins it on the total.
    sb.send({ op: "LEAVE" });
    await lobbyWith(sa, (l) => l.players.some((p: Message) => p.id === b.uid && !p.connected));
    expect((await seriesOf(code)).racers.find((r) => r.id === b.uid)!.out).toBe(true);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    const decided = await sa.next({ op: "ROUND_END" });
    expect(decided).toMatchObject({ round: 2, next: null });
    const series = await sa.next({ op: "SERIES_END" });
    expect(series).toMatchObject({ game: "rune", winner: a.uid, forfeit: false });
    await closeAll(sa, sc);
  });
});

describe("Team Rune Grid", () => {
  it("pooled: teammates share one list and see each other's words; the team's total wins", async () => {
    const [a, b, c, d] = await Promise.all([setUpClient(), setUpClient(), setUpClient(), setUpClient()]);
    const code = await createRoom(a, "runeteam");
    const sockets: Socket[] = [];
    for (const x of [a, b, c, d]) sockets.push(await join(x, code));
    const [sa, sb, sc, sd] = sockets as [Socket, Socket, Socket, Socket];
    // Copper: A and C; Cobalt: B and D (dealt in join order).
    const lobby = await lobbyWith(sa, (l) => l.players.length === 4);
    expect(lobby.players.map((p: Message) => p.team)).toEqual([0, 1, 0, 1]);
    sa.send({ op: "CONFIG", rune: { rounds: 1 } });
    await lobbyWith(sa, (l) => l.rune.rounds === 1 && l.rune.teamScoring === "pooled");

    const roundStart = await start(sa, code, sockets);
    expect(roundStart).toMatchObject({ teamScoring: "pooled", teams: { [a.uid]: 0, [b.uid]: 1, [c.uid]: 0, [d.uid]: 1 }, teamTotals: [0, 0] });
    const round = await roundOf(code);
    const [w1, w2] = round.words;
    // A finds w1: C sees it, and can't score it again; B (the other team) can.
    expect(await find(sa, w1!, 1)).toMatchObject({ result: "found" });
    expect(await sc.next({ op: "RUNE_WORD" })).toEqual({ op: "RUNE_WORD", word: w1, by: a.uid, points: Math.max(1, w1!.length - 2) });
    expect(await find(sc, w1!, 2)).toMatchObject({ result: "already", by: a.uid });
    expect(await find(sb, w1!, 3)).toMatchObject({ result: "found" });
    // D finds w2, which nobody on Copper has: unique.
    expect(await find(sd, w2!, 4)).toMatchObject({ result: "found" });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    const end = await sa.next({ op: "ROUND_END" });
    const p1 = Math.max(1, w1!.length - 2);
    const p2 = Math.max(1, w2!.length - 2) * 2;
    expect(end).toMatchObject({ teamPoints: [p1, p1 + p2], team: 1, teamTotals: [p1, p1 + p2], next: null });
    const series = await sa.next({ op: "SERIES_END" });
    expect(series).toMatchObject({ game: "rune", team: 1, winner: null });
    expect(series).not.toHaveProperty("rule");
    expect(series.podium.map((p: Message) => p.place)).toEqual([1, 1, 2, 2]);
    expect(series.rune.teamTotals).toEqual([p1, p1 + p2]);

    // Teams need the same number of smiths to start again.
    sd.send({ op: "TEAM", team: 0 });
    await lobbyWith(sa, (l) => l.players.filter((p: Message) => p.team === 0).length === 3);
    sa.send({ op: "AGAIN" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "uneven_teams" });
    await closeAll(...sockets);
  });
});
