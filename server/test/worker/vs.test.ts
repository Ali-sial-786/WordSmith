import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { slotCells } from "../../src/rules/mold";
import { totalXpForLevel } from "../../src/rules/progression";
import type { VsRound, VsSeries } from "../../src/rules/vs-round";
import { befriend, body, setUpClient, type Client } from "./helpers";
import { closeAll, connect, openSocket, sleep, type Message, type Socket } from "./sockets";

type Smith = Client & { username: string };

function stub(code: string) {
  return env.ROOM.get(env.ROOM.idFromName(code));
}

async function createVsRoom(c: Client): Promise<string> {
  const res = await c.post("/v1/rooms", { mode: "vs" });
  expect(res.status, await res.clone().text()).toBe(200);
  return (await body<{ code: string }>(res)).code;
}

async function join(c: Client, code: string): Promise<Socket> {
  const s = await connect(c, `/v1/ws/room/${code}`);
  await s.next({ op: "SNAPSHOT" });
  return s;
}

/** The round as the room stores it: the puzzle with its answers, and every racer's mold. */
async function roundOf(code: string): Promise<VsRound> {
  return runInDurableObject(stub(code), (_instance, state) => state.storage.kv.get<VsRound>("round")!);
}

async function seriesOf(code: string): Promise<VsSeries> {
  return runInDurableObject(stub(code), (_instance, state) => state.storage.kv.get<VsSeries>("series")!);
}

/** Puts embers exactly where a test wants them (rounds get random ones 1 time in 5). */
async function setEmbers(code: string, embers: { x: number; y: number }[]): Promise<void> {
  await runInDurableObject(stub(code), (_instance, state) => {
    state.storage.kv.put("round", { ...state.storage.kv.get<VsRound>("round")!, embers });
  });
  // So the room reads it back from storage.
  await evictDurableObject(stub(code));
}

async function hints(uid: string): Promise<Record<string, number>> {
  const { results } = await env.DB.prepare("SELECT item, count FROM inventory WHERE user_id = ?1").bind(uid).all<{ item: string; count: number }>();
  return Object.fromEntries(results.map((r) => [r.item, r.count]));
}

/** The next LOBBY on `s` in which `uid` is (or isn't) connected, skipping older ones still queued. */
async function lobbyWhere(s: Socket, uid: string, connected: boolean): Promise<Message> {
  for (;;) {
    const lobby = await s.next({ op: "LOBBY" });
    if (lobby.players.some((p: Message) => p.id === uid && p.connected === connected)) return lobby;
  }
}

/**
 * Makes the room pick a known puzzle: every other size-1 bank puzzle at
 * this heat is marked as seen by `uid` just now.
 */
async function forcePuzzle(uid: string, heat: number, want: (p: { id: string; bonus: string[] }) => boolean): Promise<string> {
  const pool = env.TEST_BANK.filter((r) => r.heat === heat && r.size === 1).map((r) => JSON.parse(r.data) as { id: string; bonus: string[] });
  const target = pool.find(want);
  if (target === undefined) throw new Error("no such puzzle in the bank");
  const insert = env.DB.prepare("INSERT OR REPLACE INTO puzzle_seen (user_id, puzzle_id, seen_at) VALUES (?1, ?2, ?3)");
  await env.DB.batch(pool.filter((p) => p !== target).map((p) => insert.bind(uid, p.id, Date.now())));
  return target.id;
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

/** Forges every word still missing from `uid`'s mold (crossing slots fill in by themselves). Returns the last result. */
async function fillMold(s: Socket, code: string, uid: string, seq: number): Promise<Message> {
  const { puzzle } = await roundOf(code);
  let last: Message | null = null;
  for (const slot of puzzle.slots) {
    const mold = (await roundOf(code)).molds[uid]!;
    if ([...mold.claims, ...mold.auto].some((c) => c.slot === slot.slot)) continue;
    last = await forge(s, slot.word, seq++);
    expect(last.result).toBe("claimed");
  }
  return last!;
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
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "countdown" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  return first!;
}

/** Text of a message with the anvil letters left out, to look for leaked words. */
function withoutLetters(m: Message): string {
  return JSON.stringify(m, (k, v) => (k === "letters" ? undefined : v));
}

const NO_HINTS = { hammer: 0, chisel: 0, sparks: 0 };

describe("Versus rooms", () => {
  it("are created with POST /v1/rooms, hold 5, and list for friends", async () => {
    const host = await setUpClient();
    const friend = await setUpClient();
    await befriend(host, friend);
    const hub = await connect(friend, "/v1/ws/hub");
    expect(await hub.next({ op: "OPEN_ROOMS" })).toEqual({ op: "OPEN_ROOMS", rooms: [] });

    const code = await createVsRoom(host);
    expect(await body(await host.get(`/v1/rooms/${code}`))).toEqual({
      code,
      mode: "vs",
      phase: "lobby",
      host: { id: host.uid, username: host.username },
      players: 1,
      maxPlayers: 5,
      seated: true,
    });
    const listing = { code, mode: "vs", hostId: host.uid, hostUsername: host.username, max: 5 };
    expect(await hub.next({ op: "OPEN_ROOMS" })).toEqual({ op: "OPEN_ROOMS", rooms: [{ ...listing, players: 1 }] });

    const sh = await connect(host, `/v1/ws/room/${code}`);
    await sh.next({ op: "WELCOME" });
    const snap = await sh.next({ op: "SNAPSHOT" });
    expect(snap).toEqual({
      op: "SNAPSHOT",
      lobby: {
        code,
        mode: "vs",
        phase: "lobby",
        hostId: host.uid,
        heat: 1,
        players: [{ id: host.uid, username: host.username, avatar: "avatar_01", level: 1, color: 0, ready: false, connected: true }],
        series: 3,
      },
    });
    const sf = await join(friend, code);
    expect(await hub.next({ op: "OPEN_ROOMS" })).toEqual({ op: "OPEN_ROOMS", rooms: [{ ...listing, players: 2 }] });
    await start(sh, code, [sh, sf]);
    expect(await hub.next({ op: "OPEN_ROOMS" })).toEqual({ op: "OPEN_ROOMS", rooms: [] });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // the round's timer
    await closeAll(hub, sh, sf);
  });

  it("checks CONFIG, START and HINT, and takes its heat from the median level", async () => {
    const [a, b, c, d] = (await Promise.all([0, 1, 2, 3].map(() => setUpClient()))) as [Smith, Smith, Smith, Smith];
    // Levels 1, 16 and 31: the median 16 is Cherry Red (heat 3, 2:30 rounds).
    await env.DB.prepare("UPDATE profiles SET xp = ?2 WHERE user_id = ?1").bind(b.uid, totalXpForLevel(16)).run();
    await env.DB.prepare("UPDATE profiles SET xp = ?2 WHERE user_id = ?1").bind(c.uid, totalXpForLevel(31)).run();
    const code = await createVsRoom(a);
    const sa = await join(a, code);

    // Alone: not enough players. HINT is never allowed; SUBMIT waits for a round.
    sa.send({ op: "START" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_enough_players" });
    sa.send({ op: "HINT", kind: "hammer" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "no_hints" });
    sa.send({ op: "SUBMIT", word: "EARLY", seq: 0 });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });

    const sb = await join(b, code);
    // A second player who has dropped doesn't count.
    sb.ws.close();
    await lobbyWhere(sa, b.uid, false);
    sa.send({ op: "START" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_enough_players" });
    const sb2 = await join(b, code);
    const sc = await join(c, code);
    const lobby = await sa.next({ op: "LOBBY", heat: 3 });
    expect(lobby.players.map((p: Message) => [p.level, p.color])).toEqual([
      [1, 0],
      [16, 1],
      [31, 2],
    ]);

    // CONFIG: the host's, in the lobby, one of 3, 5, 7 and 10.
    sb2.send({ op: "CONFIG", series: 5 });
    expect(await sb2.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    for (const bad of [4, "5", 0]) {
      sa.send({ op: "CONFIG", series: bad });
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    }
    sa.send({ op: "CONFIG", series: 7 });
    expect(await sc.next({ op: "LOBBY", series: 7 })).toMatchObject({ series: 7, heat: 3 });
    sb2.send({ op: "START" });
    expect(await sb2.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });

    const first = await start(sa, code, [sa, sb2, sc]);
    expect(first).toMatchObject({ round: 1, heat: 3, series: 7, regular: 1, suddenDeath: false, players: [a.uid, b.uid, c.uid] });
    expect(first.endsAt - first.startsAt).toBe(150_000);
    expect(first.tally).toEqual({ [a.uid]: 0, [b.uid]: 0, [c.uid]: 0 });
    // Past the per-socket limit for messages other than SUBMIT (a burst of 10, then 2 a second).
    await sleep(1600);
    sa.send({ op: "CONFIG", series: 3 });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });
    sa.send({ op: "HINT", kind: "hammer" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "no_hints" });
    sa.send({ op: "START" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });

    // Newcomers wait for the series to end: during the round…
    const busy = await openSocket(d, `/v1/ws/room/${code}`);
    expect(busy.status).toBe(409);
    expect(await busy.json()).toEqual({ error: "round_in_progress" });
    // …and the standings.
    const round = await roundOf(code);
    sa.send({ op: "SUBMIT", word: round.puzzle.slots[0]!.word, seq: 1 });
    await sa.next({ op: "PROGRESS" });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await sa.next({ op: "LOBBY", phase: "standings" })).toMatchObject({ heat: 3 });
    const standing = await openSocket(d, `/v1/ws/room/${code}`);
    expect(standing.status).toBe(409);
    expect(await standing.json()).toEqual({ error: "round_in_progress" });
    // …and the next countdown. Someone already seated may always come back.
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await sa.next({ op: "LOBBY", phase: "countdown" });
    expect((await openSocket(d, `/v1/ws/room/${code}`)).status).toBe(409);
    sc.ws.close();
    await lobbyWhere(sa, c.uid, false);
    const back = await connect(c, `/v1/ws/room/${code}`);
    const snap = await back.next({ op: "SNAPSHOT" });
    expect(snap.lobby.phase).toBe("countdown");
    expect(snap.round).toMatchObject({ round: 2, regular: 2, mine: { claims: [], auto: [] } });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // into round 2
    expect(await runDurableObjectAlarm(stub(code))).toBe(true); // its timer
    await closeAll(sa, sb2, back);
  });

  it(
    "plays a 5-player best of 3: a finished round, a timed-out round, a round nobody scores, then sudden death",
    async () => {
      const players = (await Promise.all([0, 1, 2, 3, 4, 5].map(() => setUpClient()))) as Smith[];
      const [a, b, c, d, e, f] = players as [Smith, Smith, Smith, Smith, Smith, Smith];
      const five = [a, b, c, d, e];
      const ids = five.map((p) => p.uid);
      const first = await forcePuzzle(a.uid, 1, (p) => p.bonus.length >= 1);
      const code = await createVsRoom(a);
      const sockets: Socket[] = [];
      for (const p of five) sockets.push(await join(p, code));
      let [sa, sb, sc, sd, se] = sockets as [Socket, Socket, Socket, Socket, Socket];
      expect(se.seen.find((m) => m.op === "SNAPSHOT")!.lobby.players.map((p: Message) => p.color)).toEqual([0, 1, 2, 3, 4]);
      const full = await openSocket(f, `/v1/ws/room/${code}`);
      expect(full.status).toBe(409);
      expect(await full.json()).toEqual({ error: "room_full" });

      // Round 1: B forges a word; A fills their mold first.
      const start1 = await start(sa, code, sockets);
      expect(start1).toMatchObject({ round: 1, heat: 1, series: 3, regular: 1, suddenDeath: false, players: ids });
      expect(start1.endsAt - start1.startsAt).toBe(120_000);
      expect(start1.tally).toEqual(Object.fromEntries(ids.map((id) => [id, 0])));
      await setEmbers(code, []);
      const r1 = await roundOf(code);
      expect(r1.puzzle.id).toBe(first);
      for (const w of [...r1.puzzle.slots.map((s) => s.word), ...r1.puzzle.bonus]) expect(withoutLetters(start1)).not.toContain(w);
      // (Players from earlier tests in this file may have had it too.)
      const seen = await env.DB.prepare("SELECT user_id FROM puzzle_seen WHERE puzzle_id = ?1 AND user_id IN (SELECT value FROM json_each(?2))")
        .bind(r1.puzzle.id, JSON.stringify([...ids, f.uid]))
        .all<{ user_id: string }>();
      expect(seen.results.map((r) => r.user_id).sort()).toEqual([...ids].sort());

      const w1 = r1.puzzle.slots[0]!;
      expect(await forge(sb, w1.word.toLowerCase(), 1)).toEqual({ op: "WORD_RESULT", seq: 1, word: w1.word, result: "claimed", slot: w1.slot, auto: [] });
      for (const s of sockets) expect(await s.next({ op: "PROGRESS", id: b.uid })).toEqual({ op: "PROGRESS", id: b.uid, filled: w1.len, total: r1.total });
      expect(await forge(sb, w1.word, 2)).toEqual({ op: "WORD_RESULT", seq: 2, word: w1.word, result: "already" });
      expect(await forge(sb, "QQQ", 3)).toEqual({ op: "WORD_RESULT", seq: 3, word: "QQQ", result: "invalid" });
      // A bonus word goes to A's Scrap Bin and never counts as progress.
      const bonus = r1.puzzle.bonus[0]!;
      expect(await forge(sa, bonus, 1)).toEqual({ op: "WORD_RESULT", seq: 1, word: bonus, result: "bonus" });
      expect(await forge(sa, bonus, 2)).toMatchObject({ result: "already" });
      // B's word is still A's to forge.
      expect(await forge(sa, w1.word, 3)).toMatchObject({ result: "claimed", slot: w1.slot });
      await fillMold(sa, code, a.uid, 10);
      const end1 = await sa.next({ op: "ROUND_END" });
      expect(end1).toMatchObject({
        op: "ROUND_END",
        round: 1,
        reason: "finished",
        winner: a.uid,
        how: "finished",
        tally: { [a.uid]: 1, [b.uid]: 0, [c.uid]: 0, [d.uid]: 0, [e.uid]: 0 },
        answers: r1.puzzle.slots.map((s) => ({ slot: s.slot, word: s.word })),
        next: { round: 2, suddenDeath: false, players: ids },
      });
      expect(end1.progress).toEqual(ids.map((id) => ({ id, filled: id === a.uid ? r1.total : id === b.uid ? w1.len : 0, total: r1.total })));
      // Now the round is over, everyone's mold: A's every slot, B's one word.
      const allSlots = r1.puzzle.slots.map((s) => s.slot).sort((x, y) => x - y);
      expect(end1.molds).toEqual(Object.fromEntries(ids.map((id) => [id, id === a.uid ? allSlots : id === b.uid ? [w1.slot] : []])));
      expect(typeof end1.standingsEndsAt).toBe("number");
      for (const s of sockets) await s.next({ op: "LOBBY", phase: "standings" });
      expect(await forge(sb, w1.word, 4)).toMatchObject({ result: "too_late" });

      // A racer who drops during the standings gets them back.
      se.ws.close();
      await lobbyWhere(sa, e.uid, false);
      se = await connect(e, `/v1/ws/room/${code}`);
      const snapStandings = await se.next({ op: "SNAPSHOT" });
      expect(snapStandings.lobby.phase).toBe("standings");
      expect(snapStandings.standings).toEqual({ ...end1, op: undefined });
      expect(snapStandings.round).toBeUndefined();
      expect(snapStandings.results).toBeUndefined();
      sockets[4] = se;

      // Round 2 runs out of time. B and C have the same letters; B got there first.
      const start2 = await nextRound(code, sockets);
      await setEmbers(code, []);
      expect(start2).toMatchObject({ round: 2, regular: 2, suddenDeath: false, players: ids, tally: end1.tally });
      const r2 = await roundOf(code);
      expect(r2.puzzle.id).not.toBe(r1.puzzle.id);
      const w2 = r2.puzzle.slots[0]!;
      await forge(sb, w2.word, 20);
      await forge(sc, w2.word, 20);
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      const end2 = await sa.next({ op: "ROUND_END" });
      expect(end2).toMatchObject({ round: 2, reason: "timeout", winner: b.uid, how: "timeout", next: { round: 3, suddenDeath: false } });
      expect(end2.tally).toMatchObject({ [a.uid]: 1, [b.uid]: 1 });
      expect(end2.molds).toEqual(Object.fromEntries(ids.map((id) => [id, id === b.uid || id === c.uid ? [w2.slot] : []])));

      // Round 3: nobody forges anything, so nobody wins; A and B are tied on top.
      const start3 = await nextRound(code, sockets);
      await setEmbers(code, []);
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      const end3 = await sa.next({ op: "ROUND_END" });
      expect(end3).toMatchObject({ round: 3, reason: "timeout", winner: null, how: "none" });
      expect(end3.next).toEqual({ round: 4, suddenDeath: true, players: [a.uid, b.uid] });

      // Round 4: sudden death between A and B; everyone else watches.
      const start4 = await nextRound(code, sockets);
      await setEmbers(code, []);
      expect(start4).toMatchObject({ round: 4, regular: null, suddenDeath: true, players: [a.uid, b.uid], tally: end3.tally });
      const r4 = await roundOf(code);
      sc.send({ op: "SUBMIT", word: r4.puzzle.slots[0]!.word, seq: 30 });
      expect(await sc.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_playing" });
      // A watcher rejoining sees an empty mold of their own, and everyone's progress.
      sd.ws.close();
      await lobbyWhere(sa, d.uid, false);
      sd = await connect(d, `/v1/ws/room/${code}`);
      const watching = (await sd.next({ op: "SNAPSHOT" })).round;
      expect(watching).toMatchObject({ round: 4, suddenDeath: true, players: [a.uid, b.uid], mine: { claims: [], auto: [] } });
      expect(watching.progress).toEqual([a.uid, b.uid].map((id) => ({ id, filled: 0, total: r4.total })));
      sockets[3] = sd;
      await forge(sa, r4.puzzle.slots.at(-1)!.word, 40);
      await fillMold(sb, code, b.uid, 40);
      const end4 = await sa.next({ op: "ROUND_END" });
      expect(end4).toMatchObject({ round: 4, reason: "finished", winner: b.uid, how: "finished", next: null, standingsEndsAt: null });
      expect(end4.tally).toEqual({ [a.uid]: 1, [b.uid]: 2, [c.uid]: 0, [d.uid]: 0, [e.uid]: 0 });

      // SERIES_END, once the XP is written.
      const series = await sb.next({ op: "SERIES_END" });
      expect(series).toMatchObject({ winner: b.uid, early: false, forfeit: false, rounds: 4 });
      expect(series.podium).toEqual([
        { id: b.uid, username: b.username, wins: 2, place: 1 },
        { id: a.uid, username: a.username, wins: 1, place: 2 },
        { id: c.uid, username: c.username, wins: 0, place: 3 },
        { id: d.uid, username: d.username, wins: 0, place: 3 },
        { id: e.uid, username: e.username, wins: 0, place: 3 },
      ]);
      // 5 per round raced, 10 per round won, 30 for the series. B passes level 2 (60 XP).
      expect(series.xp).toEqual({
        [b.uid]: { xp: 70, level: 2, levelUps: 1, rewards: { hammer: 1, chisel: 0, sparks: 0 }, scrapHammers: 0, pickups: NO_HINTS },
        [a.uid]: { xp: 30, level: 1, levelUps: 0, rewards: NO_HINTS, scrapHammers: 0, pickups: NO_HINTS },
        [c.uid]: { xp: 15, level: 1, levelUps: 0, rewards: NO_HINTS, scrapHammers: 0, pickups: NO_HINTS },
        [d.uid]: { xp: 15, level: 1, levelUps: 0, rewards: NO_HINTS, scrapHammers: 0, pickups: NO_HINTS },
        [e.uid]: { xp: 15, level: 1, levelUps: 0, rewards: NO_HINTS, scrapHammers: 0, pickups: NO_HINTS },
      });
      // Every round, sudden death included: how it went and everyone's mold, with its shape.
      expect(series.history).toEqual(
        (
          [
            [start1, end1],
            [start2, end2],
            [start3, end3],
            [start4, end4],
          ] as const
        ).map(([s, e]) => ({
          round: e.round,
          suddenDeath: s.suddenDeath,
          reason: e.reason,
          winner: e.winner,
          how: e.how,
          cols: s.cols,
          rows: s.rows,
          slots: s.slots,
          progress: e.progress,
          molds: e.molds,
        })),
      );
      expect(series.history.map((h: Message) => h.suddenDeath)).toEqual([false, false, false, true]);
      for (const s of sockets) {
        if (s !== sb) expect(await s.next({ op: "SERIES_END" })).toEqual(series);
        const lobby = await s.next({ op: "LOBBY", phase: "results" });
        expect(lobby.series).toBe(3);
        expect(lobby.players.find((p: Message) => p.id === b.uid).level).toBe(2);
      }

      // Everything is in D1, once.
      const s4 = await seriesOf(code);
      const match = await env.DB.prepare("SELECT mode, code, started_at, summary FROM matches WHERE id = ?1").bind(s4.matchId).first<Message>();
      expect(match).toMatchObject({ mode: "vs", code, started_at: start1.startsAt });
      expect(JSON.parse(match!.summary as string)).toMatchObject({ series: 3, rounds: 4, winner: b.uid, early: false, forfeit: false });
      const rows = await env.DB.prepare("SELECT user_id, placement, rounds_won, xp FROM match_players WHERE match_id = ?1 ORDER BY placement, user_id")
        .bind(s4.matchId)
        .all<Message>();
      expect(rows.results).toHaveLength(5);
      for (const r of rows.results) expect(r).toMatchObject({ xp: series.xp[r.user_id].xp, rounds_won: end4.tally[r.user_id] });
      for (const p of five) {
        const profile = await me(p);
        expect(profile.totalXp).toBe(series.xp[p.uid].xp);
        expect(profile.stats).toMatchObject({ vsSeries: 1, vsSeriesWon: p === b ? 1 : 0, vsRoundsWon: end4.tally[p.uid] });
        const events = await env.DB.prepare("SELECT source, amount, ref FROM xp_events WHERE user_id = ?1").bind(p.uid).all();
        expect(events.results).toEqual([{ source: "vs", amount: series.xp[p.uid].xp, ref: s4.matchId }]);
      }
      expect((await me(a)).scrapBin).toBe(1);
      expect((await me(a)).stats.wordsForged).toBeGreaterThanOrEqual(r1.puzzle.slots.length - 1);
      expect(await hints(b.uid)).toMatchObject({ hammer: 4 });
      const board = await body<{ entries: Message[] }>(await b.get("/v1/leaderboard"));
      expect(board.entries.find((x) => x.id === b.uid)).toMatchObject({ vsSeriesWon: 1, vsRoundsWon: 2 });

      // A rejoin during results gets the series and the last round.
      sc.ws.close();
      await lobbyWhere(sa, c.uid, false);
      sc = await connect(c, `/v1/ws/room/${code}`);
      const snapResults = await sc.next({ op: "SNAPSHOT" });
      expect(snapResults.results).toEqual({ ...series, op: undefined });
      expect(snapResults.standings).toEqual({ ...end4, op: undefined });
      expect(snapResults.round).toBeUndefined();
      sockets[2] = sc;
      expect(await forge(sc, r4.puzzle.slots[0]!.word, 50)).toMatchObject({ result: "too_late" });

      // AGAIN: the host's, for a new series of the same length.
      sb.send({ op: "AGAIN" });
      expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
      const again = await start(sa, code, sockets, "AGAIN");
      expect(again).toMatchObject({ round: 1, regular: 1, series: 3, players: ids });
      expect(again.tally).toEqual(Object.fromEntries(ids.map((id) => [id, 0])));
      expect((await seriesOf(code)).matchId).not.toBe(s4.matchId);
      expect(await runDurableObjectAlarm(stub(code))).toBe(true); // its timer
      await closeAll(...sockets);
    },
    60_000,
  );

  it(
    "clinches early, grants embers at the end, and writes XP once even when D1 fails",
    async () => {
      const a = await setUpClient();
      const b = await setUpClient();
      const code = await createVsRoom(a);
      const sa = await join(a, code);
      const sb = await join(b, code);
      await start(sa, code, [sa, sb]);
      const r1 = await roundOf(code);
      const [w1] = r1.puzzle.slots;
      const ember = slotCells(w1!)[0]!;
      await setEmbers(code, [ember]);
      expect(await hints(a.uid)).toMatchObject({ hammer: 3 });

      // Both forge the word through the ember: each collects it (level 1: a Hammer Strike), but not yet.
      expect(await forge(sa, w1!.word, 1)).toMatchObject({ result: "claimed", pickup: "hammer" });
      expect(await forge(sb, w1!.word, 1)).toMatchObject({ result: "claimed", pickup: "hammer" });
      expect(await hints(a.uid)).toMatchObject({ hammer: 3 });
      await fillMold(sa, code, a.uid, 2);
      expect(await sb.next({ op: "ROUND_END" })).toMatchObject({ winner: a.uid, next: { round: 2 } });

      // Round 2: A again, which puts the series out of B's reach. D1 is down when it ends.
      await nextRound(code, [sa, sb]);
      await setEmbers(code, []);
      await env.DB.prepare("ALTER TABLE match_players RENAME TO match_players_away").run();
      let end: Message;
      let series: Message;
      try {
        await fillMold(sa, code, a.uid, 20);
        end = await sb.next({ op: "ROUND_END" });
        series = await sb.next({ op: "SERIES_END" });
      } finally {
        await env.DB.prepare("ALTER TABLE match_players_away RENAME TO match_players").run();
      }
      expect(end).toMatchObject({ round: 2, winner: a.uid, how: "finished", next: null, standingsEndsAt: null });
      expect(series).toMatchObject({ winner: a.uid, early: true, forfeit: false, rounds: 2, xp: {} });
      const { matchId } = await seriesOf(code);
      expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM matches WHERE id = ?1").bind(matchId).first("n")).toBe(0);
      const award = await runInDurableObject(stub(code), (_i, state) => state.storage.kv.get<Record<string, unknown>>("award"));
      expect(award).toMatchObject({ kind: "vs", attempts: 1, announced: true });

      // The alarm retries it. A: 10 + 20 + 30 = 60 XP, level 2. B: 10 XP.
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      const xpA = await env.DB.prepare("SELECT xp FROM match_players WHERE match_id = ?1 AND user_id = ?2").bind(matchId, a.uid).first("xp");
      expect(xpA).toBe(60);
      expect((await me(a)).totalXp).toBe(60);
      expect((await me(b)).totalXp).toBe(10);
      // Embers and the level-up reward are in the stock now.
      expect(await hints(a.uid)).toMatchObject({ hammer: 3 + 1 + 1 });
      expect(await hints(b.uid)).toMatchObject({ hammer: 3 + 1 });
      sb.ws.close();
      const back = await connect(b, `/v1/ws/room/${code}`);
      const snap = await back.next({ op: "SNAPSHOT" });
      expect(snap.results.xp[a.uid]).toEqual({ xp: 60, level: 2, levelUps: 1, rewards: { hammer: 1, chisel: 0, sparks: 0 }, scrapHammers: 0, pickups: { hammer: 1, chisel: 0, sparks: 0 } });
      expect(snap.results.xp[b.uid]).toMatchObject({ xp: 10, pickups: { hammer: 1, chisel: 0, sparks: 0 } });

      // A write cut off after D1 had it, then repeated: nothing is paid twice.
      await runInDurableObject(stub(code), (_i, state) => state.storage.kv.put("award", { ...award, retryAt: 0 }));
      await evictDurableObject(stub(code));
      expect((await a.get(`/v1/rooms/${code}`)).status).toBe(200);
      await runInDurableObject(stub(code), (_i, state) => expect(state.storage.kv.get("award")).toBeUndefined());
      for (const p of [a, b]) {
        const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM xp_events WHERE user_id = ?1").bind(p.uid).first("n");
        expect(n).toBe(1);
      }
      expect((await me(a)).totalXp).toBe(60);
      expect(await hints(a.uid)).toMatchObject({ hammer: 5 });
      expect((await me(a)).stats).toMatchObject({ vsSeries: 1, vsSeriesWon: 1, vsRoundsWon: 2 });
      await closeAll(sa, back);
    },
    30_000,
  );

  it(
    "sums up every round in SERIES_END, for someone back during results too, and AGAIN starts afresh",
    async () => {
      const a = await setUpClient();
      const b = await setUpClient();
      const code = await createVsRoom(a);
      const sa = await join(a, code);
      let sb = await join(b, code);
      // A best of 3 that goes the distance: A, B, then A each forge one word and win on time.
      const winners = [a, b, a];
      const starts: Message[] = [];
      const ends: Message[] = [];
      for (const [i, winner] of winners.entries()) {
        starts.push(i === 0 ? await start(sa, code, [sa, sb]) : await nextRound(code, [sa, sb]));
        await setEmbers(code, []);
        const { puzzle } = await roundOf(code);
        await forge(winner === a ? sa : sb, puzzle.slots[0]!.word, 10 * i + 1);
        expect(await runDurableObjectAlarm(stub(code))).toBe(true);
        ends.push(await sa.next({ op: "ROUND_END", round: i + 1 }));
      }
      const series = await sb.next({ op: "SERIES_END" });
      expect(series).toMatchObject({ winner: a.uid, early: false, forfeit: false, rounds: 3 });
      expect(series.history).toEqual(
        starts.map((s, i) => ({
          round: i + 1,
          suddenDeath: false,
          reason: "timeout",
          winner: winners[i]!.uid,
          how: "timeout",
          cols: s.cols,
          rows: s.rows,
          slots: s.slots,
          progress: ends[i]!.progress,
          molds: { [a.uid]: winners[i] === a ? [0] : [], [b.uid]: winners[i] === b ? [0] : [] },
        })),
      );
      await sa.next({ op: "SERIES_END" });
      await sa.next({ op: "LOBBY", phase: "results" });

      // Back during results: the same summary, from the SNAPSHOT.
      sb.ws.close();
      await lobbyWhere(sa, b.uid, false);
      sb = await connect(b, `/v1/ws/room/${code}`);
      const snap = await sb.next({ op: "SNAPSHOT" });
      expect(snap.results).toEqual({ ...series, op: undefined });
      expect(snap.results.history).toHaveLength(3);

      // A new series keeps nothing of the last one.
      await start(sa, code, [sa, sb], "AGAIN");
      expect((await seriesOf(code)).history).toBeUndefined();
      expect(await runDurableObjectAlarm(stub(code))).toBe(true); // its timer
      const next = await sa.next({ op: "ROUND_END" });
      expect(next).toMatchObject({ round: 1, how: "none" });
      expect((await seriesOf(code)).history!.map((h) => h.round)).toEqual([1]);
      await closeAll(sa, sb);
    },
    30_000,
  );

  it(
    "keeps a dropped racer's mold, goes on without one who runs out of time, and is a forfeit when only one is left",
    async () => {
      const [a, b, c] = (await Promise.all([0, 1, 2].map(() => setUpClient()))) as [Smith, Smith, Smith];
      const code = await createVsRoom(a);
      const sa = await join(a, code);
      const sb = await join(b, code);
      const sc = await join(c, code);
      sa.send({ op: "CONFIG", series: 5 });
      await sc.next({ op: "LOBBY", series: 5 });
      await start(sa, code, [sa, sb, sc]);
      await setEmbers(code, []);
      const round = await roundOf(code);
      const [w1, w2] = round.puzzle.slots;

      // B forges a word and drops: their mold freezes.
      await forge(sb, w1!.word, 1);
      sb.ws.close();
      const dropped = await lobbyWhere(sa, b.uid, false);
      expect(dropped.phase).toBe("round");
      expect(dropped.players.find((p: Message) => p.id === b.uid)).toMatchObject({ connected: false, color: 1 });
      await forge(sa, w2!.word, 1);

      // Back within 30 s: the SNAPSHOT has B's own mold and everyone's progress, and B carries on.
      const back = await connect(b, `/v1/ws/room/${code}`);
      expect(await back.next()).toMatchObject({ op: "WELCOME", you: b.uid });
      const snap = await back.next({ op: "SNAPSHOT" });
      expect(snap.lobby.phase).toBe("round");
      expect(snap.lobby.players.find((p: Message) => p.id === b.uid)).toMatchObject({ connected: true, color: 1 });
      expect(snap.round).toMatchObject({ round: 1, series: 5, letters: round.letters, endsAt: round.endsAt, players: [a.uid, b.uid, c.uid] });
      expect(snap.round.mine).toEqual({ claims: [{ slot: w1!.slot, word: w1!.word }], auto: [] });
      expect(snap.round.progress).toEqual([
        { id: a.uid, filled: w2!.len, total: round.total },
        { id: b.uid, filled: w1!.len, total: round.total },
        { id: c.uid, filled: 0, total: round.total },
      ]);
      const others = round.puzzle.slots.filter((s) => s.slot !== w1!.slot).map((s) => s.word);
      for (const w of [...others, ...round.puzzle.bonus]) expect(withoutLetters(snap)).not.toContain(`"${w}"`);
      expect(await forge(back, w1!.word, 2)).toMatchObject({ result: "already" });
      expect(await forge(back, w2!.word, 3)).toMatchObject({ result: "claimed" });

      // C drops and doesn't come back: out of the series, but still listed until it ends.
      await lobbyWhere(sa, b.uid, true);
      sc.ws.close();
      await lobbyWhere(sa, c.uid, false);
      // The alarm is C's rejoin deadline (30 s), well before the round's timer.
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      const lobby = await sa.next({ op: "LOBBY" });
      expect(lobby.phase).toBe("round");
      expect(lobby.players.map((p: Message) => [p.id, p.connected])).toEqual([
        [a.uid, true],
        [b.uid, true],
        [c.uid, false],
      ]);
      expect((await seriesOf(code)).racers.map((r) => r.out)).toEqual([false, false, true]);

      // Then B leaves: A is the only one left and wins by forfeit. The round ends there (A has more letters than nobody).
      back.send({ op: "LEAVE" });
      expect((await back.closed).code).toBe(4002);
      const end = await sa.next({ op: "ROUND_END" });
      expect(end).toMatchObject({ round: 1, reason: "timeout", winner: a.uid, how: "timeout", next: null, standingsEndsAt: null });
      // B and C left, but their molds are still shown.
      expect(end.molds).toEqual({ [a.uid]: [w2!.slot], [b.uid]: [w1!.slot, w2!.slot].sort((x, y) => x - y), [c.uid]: [] });
      const series = await sa.next({ op: "SERIES_END" });
      expect(series).toMatchObject({ winner: a.uid, early: false, forfeit: true, rounds: 1 });
      expect(series.podium).toEqual([
        { id: a.uid, username: a.username, wins: 1, place: 1 },
        { id: b.uid, username: b.username, wins: 0, place: 2 },
        { id: c.uid, username: c.username, wins: 0, place: 2 },
      ]);
      // Racers who left still get their XP: 5 for the round they raced.
      expect(Object.fromEntries(Object.entries(series.xp as Record<string, Message>).map(([id, x]) => [id, x.xp]))).toEqual({
        [a.uid]: 5 + 10 + 30,
        [b.uid]: 5,
        [c.uid]: 5,
      });
      // The round the forfeit ended is in the history, with the molds of those who left.
      expect(series.history).toEqual([
        {
          round: 1,
          suddenDeath: false,
          reason: "timeout",
          winner: a.uid,
          how: "timeout",
          cols: round.puzzle.cols,
          rows: round.puzzle.rows,
          slots: round.puzzle.slots.map(({ slot, x, y, d, len }) => ({ slot, x, y, d, len })),
          progress: end.progress,
          molds: end.molds,
        },
      ]);
      const results = await sa.next({ op: "LOBBY", phase: "results" });
      expect(results.players.map((p: Message) => p.id)).toEqual([a.uid]);
      expect((await me(c)).stats).toMatchObject({ vsSeries: 1, vsSeriesWon: 0 });

      // During results anyone may join again.
      const sc2 = await connect(c, `/v1/ws/room/${code}`);
      const again = await sc2.next({ op: "SNAPSHOT" });
      expect(again.lobby.phase).toBe("results");
      expect(again.results).toMatchObject({ forfeit: true, winner: a.uid });
      expect(again.results.history).toEqual(series.history);
      expect(again.standings).toMatchObject({ round: 1, winner: a.uid });
      await closeAll(sa, sc2);
    },
    30_000,
  );

  it("ends the series with what was played if the room closes in the middle of it", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const code = await createVsRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    await start(sa, code, [sa, sb]);
    await setEmbers(code, []);
    const round = await roundOf(code);
    await forge(sa, round.puzzle.slots[0]!.word, 1);
    // Nobody has sent anything for 30 minutes by the time the round's timer runs out.
    await runInDurableObject(stub(code), (_i, state) => {
      state.storage.kv.put("room", { ...state.storage.kv.get<Record<string, unknown>>("room")!, lastActivity: 0 });
    });
    await evictDurableObject(stub(code));
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await sb.next({ op: "ROUND_END" })).toMatchObject({ round: 1, winner: a.uid, next: { round: 2 } });
    const series = await sb.next({ op: "SERIES_END" });
    expect(series).toMatchObject({ winner: null, early: false, forfeit: false, rounds: 1 });
    expect(series.xp[a.uid]).toMatchObject({ xp: 15 });
    expect(series.xp[b.uid]).toMatchObject({ xp: 5 });
    expect(await sb.closed).toEqual({ code: 4000, reason: "room_closed" });
    expect((await me(a)).stats).toMatchObject({ vsSeries: 1, vsSeriesWon: 0, vsRoundsWon: 1 });
    expect((await a.get(`/v1/rooms/${code}`)).status).toBe(404);
  });

  it("ends a series by forfeit during the standings, without another ROUND_END", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const code = await createVsRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    await start(sa, code, [sa, sb]);
    const round = await roundOf(code);
    await forge(sb, round.puzzle.slots[0]!.word, 1);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await sa.next({ op: "ROUND_END" })).toMatchObject({ winner: b.uid, next: { round: 2 } });
    await sa.next({ op: "LOBBY", phase: "standings" });
    sb.send({ op: "LEAVE" });
    await sb.closed;
    const series = await sa.next({ op: "SERIES_END" });
    expect(series).toMatchObject({ winner: a.uid, forfeit: true, rounds: 1 });
    // Just the round played: leaving during the standings adds none.
    expect(series.history.map((h: Message) => [h.round, h.winner, h.how])).toEqual([[1, b.uid, "timeout"]]);
    // B won the round, but left: they keep the win on the podium.
    expect(series.podium.map((p: Message) => [p.id, p.wins, p.place])).toEqual([
      [b.uid, 1, 1],
      [a.uid, 0, 2],
    ]);
    expect(sa.seen.filter((m) => m.op === "ROUND_END")).toHaveLength(1);
    expect((await sa.next({ op: "LOBBY", phase: "results" })).players.map((p: Message) => p.id)).toEqual([a.uid]);
    await closeAll(sa);
  });
});
