import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { CoopRound } from "../../src/rules/coop-round";
import { cellKey, indexMold, slotCells } from "../../src/rules/mold";
import { totalXpForLevel } from "../../src/rules/progression";
import { ROOM_CODE_RE } from "../../src/rules/room";
import { befriend, body, client, setUpClient, type Client } from "./helpers";
import { closeAll, connect, openSocket, sleep, type Message, type Socket } from "./sockets";

type Smith = Client & { username: string };

interface BankPuzzle {
  id: string;
  letters: string;
  heat: number;
  size: number;
  cols: number;
  rows: number;
  words: { w: string; x: number; y: number; d: "a" | "d" }[];
  bonus: string[];
}

const bank: BankPuzzle[] = env.TEST_BANK.map((r) => JSON.parse(r.data) as BankPuzzle);

function stub(code: string) {
  return env.ROOM.get(env.ROOM.idFromName(code));
}

async function createRoom(c: Client): Promise<string> {
  const res = await c.post("/v1/rooms", { mode: "coop" });
  expect(res.status, await res.clone().text()).toBe(200);
  const { code } = await body<{ code: string }>(res);
  return code;
}

async function join(c: Client, code: string): Promise<Socket> {
  const s = await connect(c, `/v1/ws/room/${code}`);
  await s.next({ op: "SNAPSHOT" });
  return s;
}

/** The round as the room stores it, answers and all. */
async function roundOf(code: string): Promise<CoopRound> {
  return runInDurableObject(stub(code), (_instance, state) => state.storage.kv.get<CoopRound>("round")!);
}

/** Puts embers exactly where a test wants them (rounds get random ones 1 time in 5). */
async function setEmbers(code: string, embers: { x: number; y: number }[]): Promise<void> {
  await runInDurableObject(stub(code), (_instance, state) => {
    state.storage.kv.put("round", { ...state.storage.kv.get<CoopRound>("round")!, embers });
  });
  // So the room reads it back from storage.
  await evictDurableObject(stub(code));
}

/**
 * Makes the room pick a known puzzle: every other bank puzzle at this heat
 * and size is marked as seen by `uid` just now.
 */
async function forcePuzzle(uid: string, heat: number, size: number, want: (p: BankPuzzle) => boolean): Promise<BankPuzzle> {
  const pool = bank.filter((p) => p.heat === heat && p.size === size);
  const target = pool.find(want);
  if (target === undefined) throw new Error("no such puzzle in the bank");
  const insert = env.DB.prepare("INSERT OR REPLACE INTO puzzle_seen (user_id, puzzle_id, seen_at) VALUES (?1, ?2, ?3)");
  await env.DB.batch(pool.filter((p) => p !== target).map((p) => insert.bind(uid, p.id, Date.now())));
  return target;
}

async function hints(uid: string): Promise<Record<string, number>> {
  const { results } = await env.DB.prepare("SELECT item, count FROM inventory WHERE user_id = ?1").bind(uid).all<{ item: string; count: number }>();
  return Object.fromEntries(results.map((r) => [r.item, r.count]));
}

/** START, then skip the 3 s countdown by running the alarm. */
async function startRound(host: Socket, code: string, others: Socket[] = []): Promise<Message> {
  host.send({ op: "START" });
  const start = await host.next({ op: "ROUND_START" });
  for (const s of others) await s.next({ op: "ROUND_START" });
  expect(await runDurableObjectAlarm(stub(code))).toBe(true);
  for (const s of [host, ...others]) await s.next({ op: "LOBBY", phase: "round" });
  return start;
}

/** Text of a message with the anvil letters left out, to look for leaked words. */
function withoutLetters(m: Message): string {
  return JSON.stringify(m, (k, v) => (k === "letters" ? undefined : v));
}

describe("POST /v1/rooms and GET /v1/rooms/:code", () => {
  it("creates a co-op room with the caller as host", async () => {
    const a = await setUpClient();
    const code = await createRoom(a);
    expect(code).toMatch(ROOM_CODE_RE);

    const res = await a.get(`/v1/rooms/${code.toLowerCase()}`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      code,
      mode: "coop",
      phase: "lobby",
      host: { id: a.uid, username: a.username },
      players: 1,
      maxPlayers: 4,
      seated: true,
    });
    // Someone else sees the room, but not as theirs.
    const b = await setUpClient();
    expect(await body(await b.get(`/v1/rooms/${code}`))).toMatchObject({ players: 1, seated: false });

    // A code in use can't be opened again (POST /v1/rooms then tries another).
    const other = { id: "someone", username: "Someone", avatar: "avatar_02", level: 1 };
    expect(await stub(code).create(code, "coop", other)).toBe(false);
    expect(await body(await a.get(`/v1/rooms/${code}`))).toMatchObject({ host: { id: a.uid } });
  });

  it("refuses bad requests", async () => {
    const a = await setUpClient();
    expect((await a.post("/v1/rooms", { mode: "solo" })).status).toBe(400);
    expect(await body(await a.post("/v1/rooms", { mode: "solo" }))).toMatchObject({ error: "invalid_mode" });
    expect(await body(await a.post("/v1/rooms", {}))).toMatchObject({ error: "invalid_mode" });

    const notSetUp = await client();
    const res = await notSetUp.post("/v1/rooms", { mode: "coop" });
    expect(res.status).toBe(403);
    expect(await res.json()).toMatchObject({ error: "setup_required" });

    for (const code of ["ZZZZZZ", "abc", "OOOOOO", "ABCDEFG"]) {
      const r = await a.get(`/v1/rooms/${code}`);
      expect(r.status).toBe(404);
      expect(await r.json()).toEqual({ error: "room_not_found" });
    }
  });
});

describe("GET /v1/ws/room/:code refusals", () => {
  it("refuses before upgrading", async () => {
    const a = await setUpClient();
    const code = await createRoom(a);

    const missing = await openSocket(a, "/v1/ws/room/ZZZZZZ");
    expect(missing.status).toBe(404);
    expect(await missing.json()).toEqual({ error: "room_not_found" });
    expect((await openSocket(a, "/v1/ws/room/bad")).status).toBe(404);

    const notSetUp = await client();
    const res = await openSocket(notSetUp, `/v1/ws/room/${code}`);
    expect(res.status).toBe(403);
    expect(await res.json()).toMatchObject({ error: "setup_required" });

    const noToken = await openSocket({ ...a, token: "not.a.token" }, `/v1/ws/room/${code}`);
    expect(noToken.status).toBe(401);
  });

  it("holds 4 players, and newcomers wait for the round to end", async () => {
    const players = await Promise.all([0, 1, 2, 3, 4].map(() => setUpClient()));
    const [host, ...rest] = players as [Smith, ...Smith[]];
    const code = await createRoom(host);
    const sockets = [await join(host, code)];
    for (const p of rest.slice(0, 3)) sockets.push(await join(p, code));
    const lobby = await sockets[0]!.next({ op: "LOBBY" });
    void lobby;
    const last = sockets[3]!.seen.find((m) => m.op === "SNAPSHOT")!;
    expect(last.lobby.players.map((p: Message) => p.color)).toEqual([0, 1, 2, 3]);

    const full = await openSocket(rest[3]!, `/v1/ws/room/${code}`);
    expect(full.status).toBe(409);
    expect(await full.json()).toEqual({ error: "room_full" });

    // One leaves; the round starts with three; the fifth can't join mid-round.
    sockets[3]!.send({ op: "LEAVE" });
    expect((await sockets[3]!.closed).code).toBe(4002);
    await startRound(sockets[0]!, code, sockets.slice(1, 3));
    const busy = await openSocket(rest[3]!, `/v1/ws/room/${code}`);
    expect(busy.status).toBe(409);
    expect(await busy.json()).toEqual({ error: "round_in_progress" });

    // Someone already in the room may always come back.
    sockets[2]!.ws.close();
    await sockets[0]!.next({ op: "LOBBY" });
    const back = await connect(rest[1]!, `/v1/ws/room/${code}`);
    expect((await back.next({ op: "SNAPSHOT" })).round).toBeDefined();
    for (const s of [...sockets.slice(0, 2), back]) s.ws.close();
  });
});

describe("a co-op round", () => {
  it("runs from lobby to results, refereeing every word", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const target = await forcePuzzle(a.uid, 1, 2, (p) => p.bonus.length >= 2 && p.words.length >= 5);
    const code = await createRoom(a);

    const sa = await connect(a, `/v1/ws/room/${code}`);
    expect(sa.protocol).toBe("wordsmith.v1");
    expect(await sa.next()).toMatchObject({ op: "WELCOME", you: a.uid, protocol: 1 });
    const snap = await sa.next({ op: "SNAPSHOT" });
    expect(snap.round).toBeUndefined();
    expect(snap.lobby).toEqual({
      code,
      mode: "coop",
      phase: "lobby",
      hostId: a.uid,
      heat: 1,
      heatChoice: "auto",
      autoHeat: 1,
      players: [{ id: a.uid, username: a.username, avatar: "avatar_01", level: 1, color: 0, ready: false, connected: true }],
    });

    const sb = await join(b, code);
    const lobby = await sa.next({ op: "LOBBY" });
    expect(lobby.players.map((p: Message) => [p.id, p.color, p.connected])).toEqual([
      [a.uid, 0, true],
      [b.uid, 1, true],
    ]);

    sb.send({ op: "READY", ready: true });
    expect((await sa.next({ op: "LOBBY" })).players[1].ready).toBe(true);
    sb.send({ op: "START" });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    sa.send({ op: "AGAIN" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });
    sa.send({ op: "SUBMIT", word: "EARLY", seq: 0 });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });

    // START: the countdown and the mold's shape, never its words.
    sa.send({ op: "START" });
    const start = await sb.next({ op: "ROUND_START" });
    expect(start).toMatchObject({ round: 1, heat: 1, cols: target.cols, rows: target.rows });
    expect(start.endsAt - start.startsAt).toBe(180_000);
    expect(start.startsAt - start.serverNow).toBe(3000);
    expect([...start.letters].sort().join("")).toBe([...target.letters].sort().join(""));
    expect(start.slots).toHaveLength(target.words.length);
    for (const s of start.slots) expect(Object.keys(s).sort()).toEqual(["d", "len", "slot", "x", "y"]);
    for (const w of [...target.words.map((w) => w.w), ...target.bonus]) expect(withoutLetters(start)).not.toContain(w);
    const countdown = await sb.next({ op: "LOBBY" });
    expect(countdown.phase).toBe("countdown");
    expect(countdown.players.every((p: Message) => p.ready === false)).toBe(true);
    await sa.next({ op: "ROUND_START" });

    // Both players have now seen this puzzle.
    const seen = await env.DB.prepare("SELECT user_id FROM puzzle_seen WHERE puzzle_id = ?1 ORDER BY user_id")
      .bind(target.id)
      .all<{ user_id: string }>();
    expect(seen.results.map((r) => r.user_id).sort()).toEqual([a.uid, b.uid].sort());

    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    await sa.next({ op: "LOBBY", phase: "round" });
    await sb.next({ op: "LOBBY", phase: "round" });
    await setEmbers(code, []);
    const round = await roundOf(code);
    expect(round.puzzle.id).toBe(target.id);
    const slots = round.puzzle.slots;

    // The same word from both at once: exactly one gets it.
    const first = slots.find((s) => s.len === Math.max(...slots.map((x) => x.len)))!;
    sa.send({ op: "SUBMIT", word: first.word.toLowerCase(), seq: 1 });
    sb.send({ op: "SUBMIT", word: first.word, seq: 1 });
    const ra = await sa.next({ op: "WORD_RESULT" });
    const rb = await sb.next({ op: "WORD_RESULT" });
    const outcomes = [ra.result, rb.result].sort();
    expect(outcomes).toEqual(["already", "claimed"]);
    const [winner, loserResult] = ra.result === "claimed" ? [a.uid, rb] : [b.uid, ra];
    expect(loserResult).toEqual({ op: "WORD_RESULT", seq: 1, word: first.word, result: "already", by: winner });
    expect(ra.result === "claimed" ? ra : rb).toEqual({ op: "WORD_RESULT", seq: 1, word: first.word, result: "claimed", points: 10 * first.len });
    // Everyone hears about it (the loser before their own answer).
    for (const s of [sa, sb]) {
      const claimed = s.seen.find((m) => m.op === "CLAIMED")!;
      expect(claimed).toMatchObject({ slot: first.slot, word: first.word, by: winner, points: 10 * first.len, auto: [] });
      expect(claimed.scores).toEqual({ [a.uid]: winner === a.uid ? 10 * first.len : 0, [b.uid]: winner === b.uid ? 10 * first.len : 0 });
    }

    // Not a word.
    sa.send({ op: "SUBMIT", word: "qqq", seq: 2 });
    expect(await sa.next({ op: "WORD_RESULT" })).toEqual({ op: "WORD_RESULT", seq: 2, word: "QQQ", result: "invalid" });

    // A bonus word, once.
    const bonusWord = target.bonus[0]!;
    sb.send({ op: "SUBMIT", word: bonusWord, seq: 2 });
    expect(await sb.next({ op: "WORD_RESULT" })).toEqual({
      op: "WORD_RESULT",
      seq: 2,
      word: bonusWord,
      result: "bonus",
      points: 3 * bonusWord.length,
    });
    expect(await sa.next({ op: "BONUS" })).toMatchObject({ word: bonusWord, by: b.uid, points: 3 * bonusWord.length });
    sa.send({ op: "SUBMIT", word: bonusWord, seq: 3 });
    expect(await sa.next({ op: "WORD_RESULT" })).toMatchObject({ seq: 3, result: "already", by: b.uid });

    // Hints: B is level 1, so no Chisel; A spends a Hammer Strike from their own stock.
    const empty = indexMold(round.puzzle);
    const emptyCell = [...empty.cells.values()].find((c) => !slotCells(first).some((p) => cellKey(p.x, p.y) === c.key))!;
    sb.send({ op: "HINT", kind: "chisel", x: emptyCell.x, y: emptyCell.y });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "hint_locked" });
    expect(await hints(a.uid)).toMatchObject({ hammer: 3 });
    sa.send({ op: "HINT", kind: "hammer" });
    const reveal = await sb.next({ op: "REVEAL" });
    expect(reveal).toMatchObject({ by: a.uid, kind: "hammer" });
    expect(reveal.cells).toHaveLength(1);
    const hinted = reveal.cells[0] as { x: number; y: number; letter: string };
    expect(empty.cells.get(cellKey(hinted.x, hinted.y))?.letter).toBe(hinted.letter);
    await sa.next({ op: "REVEAL" });
    expect(await hints(a.uid)).toMatchObject({ hammer: 2 });
    await env.DB.prepare("UPDATE inventory SET count = 0 WHERE user_id = ?1 AND item = 'hammer'").bind(a.uid).run();
    sa.send({ op: "HINT", kind: "hammer" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "no_hint" });
    sa.send({ op: "HINT", kind: "lightning" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });

    // Forge the rest, taking turns (and keeping under the rate limit).
    await sleep(1000);
    const sockets = { [a.uid]: sa, [b.uid]: sb };
    let turn = 0;
    let seq = 10;
    let roundEnd: Message | null = null;
    for (const slot of slots) {
      const state = await roundOf(code);
      if (state.claims.some((c) => c.slot === slot.slot) || state.auto.some((c) => c.slot === slot.slot)) continue;
      const who = [a.uid, b.uid][turn++ % 2]!;
      const s = sockets[who]!;
      const hintedHere = slotCells(slot).filter((p) => state.revealed.some((r) => r.x === p.x && r.y === p.y)).length;
      s.send({ op: "SUBMIT", word: slot.word, seq: ++seq });
      const result = await s.next({ op: "WORD_RESULT", seq });
      expect(result).toMatchObject({ result: "claimed", points: 10 * (slot.len - hintedHere) });
      await s.next({ op: "CLAIMED", slot: slot.slot });
      await sleep(150);
    }
    roundEnd = await sa.next({ op: "ROUND_END" });
    await sa.next({ op: "LOBBY", phase: "results" });

    const final = await roundOf(code);
    const scores: Record<string, number> = { [a.uid]: 0, [b.uid]: 0 };
    for (const c of final.claims) scores[c.by]! += c.points;
    scores[b.uid]! += 3 * bonusWord.length;
    const mvp = scores[a.uid]! === scores[b.uid]! ? null : scores[a.uid]! > scores[b.uid]! ? a.uid : b.uid;
    expect(roundEnd).toMatchObject({
      reason: "complete",
      teamScore: scores[a.uid]! + scores[b.uid]!,
      stars: 3,
      answers: slots.map((s) => ({ slot: s.slot, word: s.word })),
    });
    expect(roundEnd.filled).toBe(roundEnd.total);
    expect(roundEnd.total).toBe(empty.cells.size);
    if (mvp !== null) expect(roundEnd.mvp).toBe(mvp);
    const theMvp = roundEnd.mvp as string;
    const byId = Object.fromEntries((roundEnd.players as Message[]).map((p) => [p.id, p]));
    expect(byId[a.uid]).toMatchObject({ points: scores[a.uid], username: a.username });
    expect(byId[b.uid]).toMatchObject({ points: scores[b.uid], bonus: 1 });
    for (const id of [a.uid, b.uid]) {
      const expected = 20 + Math.floor(scores[id]! / 10) + 20 + (theMvp === id ? 10 : 0);
      expect(roundEnd.xp[id]).toMatchObject({ xp: expected, levelUps: expected >= 60 ? 1 : 0, level: expected >= 60 ? 2 : 1 });
    }
    expect((await sb.next({ op: "ROUND_END" })).xp).toEqual(roundEnd.xp);

    // Everything is in D1.
    const match = await env.DB.prepare("SELECT mode, code, summary FROM matches WHERE id = ?1").bind(final.matchId).first<Message>();
    expect(match).toMatchObject({ mode: "coop", code });
    expect(JSON.parse(match!.summary as string)).toMatchObject({ puzzleId: target.id, reason: "complete", stars: 3, mvp: theMvp });
    const rows = await env.DB.prepare("SELECT user_id, points, xp, placement FROM match_players WHERE match_id = ?1")
      .bind(final.matchId)
      .all<{ user_id: string; points: number; xp: number; placement: number }>();
    expect(rows.results).toHaveLength(2);
    for (const r of rows.results) {
      expect(r.points).toBe(scores[r.user_id]);
      expect(r.xp).toBe(roundEnd.xp[r.user_id].xp);
    }
    for (const id of [a.uid, b.uid]) {
      const me = await body<Message>(await (id === a.uid ? a : b).get("/v1/me"));
      expect(me.totalXp).toBe(roundEnd.xp[id].xp);
      expect(me.stats).toMatchObject({ coopRounds: 1, coopMvps: theMvp === id ? 1 : 0, wordsForged: byId[id]!.words });
      expect(me.stats.longestWord).toBe(byId[id]!.longest);
      const xpEvents = await env.DB.prepare("SELECT source, amount, ref FROM xp_events WHERE user_id = ?1").bind(id).all();
      expect(xpEvents.results).toEqual([{ source: "coop", amount: roundEnd.xp[id].xp, ref: final.matchId }]);
    }
    expect((await hints(b.uid)).hammer).toBe(3 + roundEnd.xp[b.uid].rewards.hammer);

    // Words after the end are too late; AGAIN is the host's.
    sb.send({ op: "SUBMIT", word: first.word, seq: 99 });
    expect(await sb.next({ op: "WORD_RESULT" })).toMatchObject({ seq: 99, result: "too_late" });
    sb.send({ op: "AGAIN" });
    expect(await sb.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_host" });
    sa.send({ op: "AGAIN" });
    const again = await sb.next({ op: "ROUND_START" });
    expect(again.round).toBe(2);
    expect((await sb.next({ op: "LOBBY" })).phase).toBe("countdown");
    const second = await roundOf(code);
    expect(second.puzzle.id).not.toBe(target.id);
    // Don't leave a countdown alarm to go off after the test.
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    sa.ws.close();
    sb.ws.close();
  });

  it("ends on time with the alarm, and still pays XP for taking part", async () => {
    const a = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    const start = await startRound(sa, code);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    const end = await sa.next({ op: "ROUND_END" });
    const round = await roundOf(code);
    expect(end).toMatchObject({ reason: "timeout", teamScore: 0, filled: 0, stars: 0, mvp: null });
    expect(end.total).toBeGreaterThan(0);
    expect(end.answers).toHaveLength(start.slots.length);
    expect(end.players).toEqual([{ id: a.uid, username: a.username, points: 0, words: 0, longest: "", bonus: 0 }]);
    expect(end.xp).toEqual({
      [a.uid]: { xp: 20, level: 1, levelUps: 0, rewards: { hammer: 0, chisel: 0, sparks: 0 }, scrapHammers: 0, heatBonus: 0, tiersAbove: 0 },
    });
    expect((await sa.next({ op: "LOBBY" })).phase).toBe("results");

    const match = await env.DB.prepare("SELECT ended_at, started_at FROM matches WHERE id = ?1").bind(round.matchId).first<Message>();
    expect(match).toEqual({ started_at: round.startsAt, ended_at: round.endsAt });
    sa.send({ op: "SUBMIT", word: round.puzzle.slots[0]!.word, seq: 1 });
    expect(await sa.next({ op: "WORD_RESULT" })).toMatchObject({ result: "too_late" });

    // A rejoin during results gets the results, and the finished board.
    sa.ws.close();
    const again = await connect(a, `/v1/ws/room/${code}`);
    const snap = await again.next({ op: "SNAPSHOT" });
    expect(snap.lobby.phase).toBe("results");
    expect(snap.results).toMatchObject({ reason: "timeout", xp: end.xp });
    expect(snap.round.round).toBe(1);
    again.ws.close();
  });

  it("sends results without XP if D1 fails, then writes them on a retry", async () => {
    const a = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    await startRound(sa, code);
    const round = await roundOf(code);
    await env.DB.prepare("ALTER TABLE match_players RENAME TO match_players_away").run();
    try {
      expect(await runDurableObjectAlarm(stub(code))).toBe(true);
      expect(await sa.next({ op: "ROUND_END" })).toMatchObject({ reason: "timeout", xp: {} });
    } finally {
      await env.DB.prepare("ALTER TABLE match_players_away RENAME TO match_players").run();
    }
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM matches WHERE id = ?1").bind(round.matchId).first("n")).toBe(0);

    // The alarm retries it.
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    const row = await env.DB.prepare("SELECT xp FROM match_players WHERE match_id = ?1 AND user_id = ?2").bind(round.matchId, a.uid).first("xp");
    expect(row).toBe(20);
    expect((await body<Message>(await a.get("/v1/me"))).totalXp).toBe(20);
    // A rejoin now sees the XP too, and a further retry changes nothing.
    sa.ws.close();
    const back = await connect(a, `/v1/ws/room/${code}`);
    expect((await back.next({ op: "SNAPSHOT" })).results.xp[a.uid]).toMatchObject({ xp: 20 });
    await runInDurableObject(stub(code), (_i, state) => expect(state.storage.kv.get("award")).toBeUndefined());
    back.ws.close();
  });

  it("gives a collected ember to whoever forges its word", async () => {
    const a = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    await startRound(sa, code);
    const round = await roundOf(code);
    const slot = round.puzzle.slots[0]!;
    await setEmbers(code, [slotCells(slot)[0]!]);

    const before = (await hints(a.uid)).hammer!;
    sa.send({ op: "SUBMIT", word: slot.word, seq: 1 });
    // Level 1 has only unlocked Hammer Strikes, so that's what the ember becomes.
    expect(await sa.next({ op: "CLAIMED" })).toMatchObject({ slot: slot.slot, pickup: "hammer" });
    await sleep(50);
    expect((await hints(a.uid)).hammer).toBe(before + 1);
    expect((await roundOf(code)).embers).toEqual([]);
    sa.ws.close();
  });
});

describe("Chisel and Spark Shower", () => {
  it("reveals the chosen cell, then up to 5 spread out, and hinted letters score nothing", async () => {
    const a = await setUpClient();
    // Level 12: Chisel and Spark Shower unlocked, and heat 2.
    await env.DB.prepare("UPDATE profiles SET xp = ?2, level = 12 WHERE user_id = ?1").bind(a.uid, totalXpForLevel(12)).run();
    await env.DB.prepare("UPDATE inventory SET count = 1 WHERE user_id = ?1 AND item IN ('chisel', 'sparks')").bind(a.uid).run();
    const code = await createRoom(a);
    const sa = await join(a, code);
    const start = await startRound(sa, code);
    expect(start.heat).toBe(2);
    await setEmbers(code, []);
    const round = await roundOf(code);
    const index = indexMold(round.puzzle);
    const [w1, ...others] = round.puzzle.slots;

    sa.send({ op: "SUBMIT", word: w1!.word, seq: 1 });
    await sa.next({ op: "CLAIMED" });
    const filled = slotCells(w1!)[0]!;
    for (const cell of [filled, { x: 9, y: 9 }]) {
      sa.send({ op: "HINT", kind: "chisel", ...cell });
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_cell" });
    }
    expect(await hints(a.uid)).toMatchObject({ chisel: 1, sparks: 1 });

    // Chisel the first cell of a word nobody has, that w1 doesn't cross.
    const target = others.find((s) => slotCells(s).some((c) => !slotCells(w1!).some((d) => d.x === c.x && d.y === c.y)))!;
    const cell = slotCells(target).find((c) => !slotCells(w1!).some((d) => d.x === c.x && d.y === c.y))!;
    sa.send({ op: "HINT", kind: "chisel", x: cell.x, y: cell.y });
    const chiselled = await sa.next({ op: "REVEAL" });
    expect(chiselled).toMatchObject({ by: a.uid, kind: "chisel", cells: [{ ...cell, letter: index.cells.get(cellKey(cell.x, cell.y))!.letter }] });
    expect(await hints(a.uid)).toMatchObject({ chisel: 0, sparks: 1 });
    sa.send({ op: "HINT", kind: "chisel", x: cell.x, y: cell.y });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_cell" });

    sa.send({ op: "HINT", kind: "sparks" });
    const sparks = await sa.next({ op: "REVEAL" });
    expect(sparks.kind).toBe("sparks");
    const before = new Set([...slotCells(w1!).map((c) => cellKey(c.x, c.y)), cellKey(cell.x, cell.y)]);
    const keys = (sparks.cells as { x: number; y: number; letter: string }[]).map((c) => cellKey(c.x, c.y));
    expect(keys.length).toBe(Math.min(5, index.cells.size - before.size));
    expect(new Set(keys).size).toBe(keys.length);
    for (const c of sparks.cells as { x: number; y: number; letter: string }[]) {
      expect(before.has(cellKey(c.x, c.y))).toBe(false);
      expect(index.cells.get(cellKey(c.x, c.y))!.letter).toBe(c.letter);
    }
    expect(await hints(a.uid)).toMatchObject({ chisel: 0, sparks: 0 });

    // A slot the hints filled completely belongs to nobody.
    for (const auto of [...chiselled.auto, ...sparks.auto] as { slot: number; word: string }[]) {
      await sleep(260);
      sa.send({ op: "SUBMIT", word: auto.word, seq: 100 + auto.slot });
      expect(await sa.next({ op: "WORD_RESULT", seq: 100 + auto.slot })).toMatchObject({ result: "already", by: null });
    }
    // The chiselled word scores 10 for each letter no hint showed.
    const state = await roundOf(code);
    if (!state.auto.some((x) => x.slot === target.slot)) {
      const hinted = slotCells(target).filter((c) => state.revealed.some((r) => r.x === c.x && r.y === c.y)).length;
      await sleep(260);
      sa.send({ op: "SUBMIT", word: target.word, seq: 2 });
      expect(await sa.next({ op: "WORD_RESULT", seq: 2 })).toMatchObject({ result: "claimed", points: 10 * (target.len - hinted) });
      expect(hinted).toBeGreaterThanOrEqual(1);
    }
    sa.ws.close();
  });
});

describe("rooms and players coming and going", () => {
  it("keeps a dropped player's seat and points, and shows them the board when they're back", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    await startRound(sa, code, [sb]);
    const round = await roundOf(code);
    const word = round.puzzle.slots[0]!;

    sb.ws.close();
    const dropped = await sa.next({ op: "LOBBY" });
    expect(dropped.players.find((p: Message) => p.id === b.uid)).toMatchObject({ connected: false, color: 1 });
    sa.send({ op: "SUBMIT", word: word.word, seq: 1 });
    await sa.next({ op: "CLAIMED" });

    const back = await connect(b, `/v1/ws/room/${code}`);
    expect(await back.next()).toMatchObject({ op: "WELCOME", you: b.uid });
    const snap = await back.next({ op: "SNAPSHOT" });
    expect(snap.lobby.phase).toBe("round");
    expect(snap.lobby.players.find((p: Message) => p.id === b.uid)).toMatchObject({ connected: true, color: 1 });
    expect(snap.round).toMatchObject({ round: 1, letters: round.letters, endsAt: round.endsAt });
    expect(snap.round.claims).toEqual([{ slot: word.slot, word: word.word, by: a.uid, points: 10 * word.len }]);
    expect(snap.round.scores).toEqual({ [a.uid]: 10 * word.len, [b.uid]: 0 });
    // Only claimed words are in it.
    const others = round.puzzle.slots.filter((s) => s.slot !== word.slot).map((s) => s.word);
    for (const w of [...others, ...round.puzzle.bonus]) expect(withoutLetters(snap)).not.toContain(`"${w}"`);
    expect((await sa.next({ op: "LOBBY" })).players.find((p: Message) => p.id === b.uid).connected).toBe(true);
    sa.ws.close();
    back.ws.close();
  });

  it("hands the host role to the earliest joiner", async () => {
    const [a, b, c] = await Promise.all([setUpClient(), setUpClient(), setUpClient()]);
    const code = await createRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    const sc = await join(c, code);

    // The host leaves: B joined next.
    sa.send({ op: "LEAVE" });
    expect(await sa.closed).toMatchObject({ code: 4002 });
    let lobby = await sc.next({ op: "LOBBY", hostId: b.uid });
    expect(lobby.players.map((p: Message) => p.id)).toEqual([b.uid, c.uid]);

    // The new host drops and doesn't come back in time.
    sb.ws.close();
    lobby = await sc.next({ op: "LOBBY" });
    expect(lobby).toMatchObject({ hostId: b.uid });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    lobby = await sc.next({ op: "LOBBY", hostId: c.uid });
    expect(lobby.players.map((p: Message) => p.id)).toEqual([c.uid]);
    expect(await body(await c.get(`/v1/rooms/${code}`))).toMatchObject({ host: { id: c.uid, username: c.username }, players: 1 });

    // A newcomer gets the lowest free colour.
    const sa2 = await connect(a, `/v1/ws/room/${code}`);
    const snap = await sa2.next({ op: "SNAPSHOT" });
    expect(snap.lobby.players.map((p: Message) => [p.id, p.color])).toEqual([
      [c.uid, 2],
      [a.uid, 0],
    ]);
    sa2.ws.close();
    sc.ws.close();
  });

  it("closes 2 minutes after everyone has left, clearing its storage", async () => {
    const a = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    sa.send({ op: "LEAVE" });
    await sa.closed;
    expect((await a.get(`/v1/rooms/${code}`)).status).toBe(200);
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect((await a.get(`/v1/rooms/${code}`)).status).toBe(404);
    const keys = await runInDurableObject(stub(code), (_i, state) => [...state.storage.kv.list()].length);
    expect(keys).toBe(0);
    expect(await runInDurableObject(stub(code), (_i, state) => state.storage.getAlarm())).toBeNull();
    expect((await openSocket(a, `/v1/ws/room/${code}`)).status).toBe(404);
  });

  it("closes 30 minutes after the last message, telling everyone", async () => {
    const a = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    sa.send({ op: "EMOTE", emote: "gg" });
    await sa.next({ op: "EMOTE" });
    // Nobody has dropped, so the next deadline is the idle close.
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await sa.closed).toEqual({ code: 4000, reason: "room_closed" });
    expect((await a.get(`/v1/rooms/${code}`)).status).toBe(404);
  });

  it("closes a room nobody ever joined", async () => {
    const a = await setUpClient();
    const code = await createRoom(a);
    // First the creator's seat goes (30 s), then the room (2 min).
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect(await body(await a.get(`/v1/rooms/${code}`))).toMatchObject({ players: 0, host: null });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    expect((await a.get(`/v1/rooms/${code}`)).status).toBe(404);
  });

  it("keeps its round through eviction from memory", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    await startRound(sa, code, [sb]);
    const round = await roundOf(code);
    const [w1, w2] = round.puzzle.slots;
    sa.send({ op: "SUBMIT", word: w1!.word, seq: 1 });
    await sb.next({ op: "CLAIMED" });

    await evictDurableObject(stub(code));

    // The sockets hibernated with it; the claims, scores and timer are in storage.
    sb.send({ op: "SUBMIT", word: w1!.word, seq: 1 });
    expect(await sb.next({ op: "WORD_RESULT" })).toMatchObject({ result: "already", by: a.uid });
    sb.send({ op: "SUBMIT", word: w2!.word, seq: 2 });
    expect(await sa.next({ op: "CLAIMED", word: w2!.word })).toMatchObject({ by: b.uid });
    await evictDurableObject(stub(code));
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    const end = await sa.next({ op: "ROUND_END" });
    expect(end.reason).toBe("timeout");
    expect(end.players.map((p: Message) => p.words).sort()).toEqual([1, 1]);
    sa.ws.close();
    sb.ws.close();
  });

  it("rate-limits words and locks out a burst of invalid ones", async () => {
    const a = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    await startRound(sa, code);
    const round = await roundOf(code);

    for (let seq = 1; seq <= 8; seq++) sa.send({ op: "SUBMIT", word: "QQQ", seq });
    const results: string[] = [];
    for (let seq = 1; seq <= 8; seq++) results.push((await sa.next({ op: "WORD_RESULT", seq })).result);
    expect(results.filter((r) => r === "rate_limited").length).toBeGreaterThanOrEqual(3);

    // 10 invalid words inside 5 s: a 3 s lockout, even for a real word.
    await sleep(1100);
    for (let i = 0; i < 6; i++) {
      sa.send({ op: "SUBMIT", word: "QQQ", seq: 100 + i });
      expect((await sa.next({ op: "WORD_RESULT", seq: 100 + i })).result).toBe("invalid");
      await sleep(260);
    }
    sa.send({ op: "SUBMIT", word: round.puzzle.slots[0]!.word, seq: 200 });
    expect(await sa.next({ op: "WORD_RESULT", seq: 200 })).toMatchObject({ result: "rate_limited" });
    sa.ws.close();
  });

  it("relays emotes, answers PING, and refuses bad messages", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);
    sa.send({ op: "EMOTE", emote: "fire" });
    expect(await sb.next({ op: "EMOTE" })).toEqual({ op: "EMOTE", from: a.uid, emote: "fire" });
    expect(await sa.next({ op: "EMOTE" })).toEqual({ op: "EMOTE", from: a.uid, emote: "fire" });
    sa.send('{"op":"PING"}');
    expect(await sa.next({ op: "PONG" })).toEqual({ op: "PONG" });
    for (const raw of ["nope", "[]", '{"op":"EMOTE","emote":"rude"}', '{"op":"READY"}', '{"op":"SUBMIT","word":"A"}', '{"op":"HINT","kind":"chisel"}']) {
      sa.send(raw);
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    }
    sa.send({ op: "HINT", kind: "hammer" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "wrong_phase" });
    sa.ws.close();
    sb.ws.close();
  });
});

describe("room chat", () => {
  it("sends a line to everyone, starred, and keeps it for whoever joins later", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const c = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    const sb = await join(b, code);

    sa.send({ op: "CHAT", text: "  ready when\nyou are " });
    const line = await sb.next({ op: "CHAT" });
    expect(line).toEqual({ op: "CHAT", id: 1, from: a.uid, username: a.username, text: "ready when you are", at: expect.any(Number) });
    expect(await sa.next({ op: "CHAT" })).toEqual(line);
    sb.send({ op: "CHAT", text: "what the fuck, start!" });
    expect(await sa.next({ op: "CHAT" })).toMatchObject({ id: 2, from: b.uid, text: "what the ****, start!" });

    // History survives eviction and reaches a late joiner, oldest first.
    await evictDurableObject(stub(code));
    const sc = await connect(c, `/v1/ws/room/${code}`);
    const snapshot = await sc.next({ op: "SNAPSHOT" });
    expect(snapshot.chat.map((l: Message) => [l.id, l.text])).toEqual([
      [1, "ready when you are"],
      [2, "what the ****, start!"],
    ]);

    // Chat carries on mid-round.
    await startRound(sa, code, [sb, sc]);
    sc.send({ op: "CHAT", text: "gl" });
    expect(await sa.next({ op: "CHAT" })).toMatchObject({ id: 3, from: c.uid, text: "gl" });
    for (const raw of ['{"op":"CHAT","text":"   "}', '{"op":"CHAT"}']) {
      sa.send(raw);
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "bad_message" });
    }
    await closeAll(sa, sb, sc);
  });

  it("slows down a flood, keeping the latest 50 lines", async () => {
    const a = await setUpClient();
    const code = await createRoom(a);
    const sa = await join(a, code);
    for (let i = 1; i <= 7; i++) sa.send({ op: "CHAT", text: `line ${i}` });
    for (let i = 1; i <= 5; i++) expect(await sa.next({ op: "CHAT" })).toMatchObject({ text: `line ${i}` });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "chat_limit" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "chat_limit" });

    // A long-running room keeps only its latest lines.
    await runInDurableObject(stub(code), (_i, state) => {
      const lines = Array.from({ length: 50 }, (_, i) => ({ id: i + 1, from: a.uid, username: a.username, text: `old ${i + 1}`, at: 0 }));
      state.storage.kv.put("chat", { next: 51, lines });
    });
    await evictDurableObject(stub(code));
    await sleep(2100);
    sa.send({ op: "CHAT", text: "newest" });
    expect(await sa.next({ op: "CHAT" })).toMatchObject({ id: 51, text: "newest" });
    const chat = await runInDurableObject(stub(code), (_i, state) => state.storage.kv.get<{ lines: Message[] }>("chat")!.lines);
    expect(chat).toHaveLength(50);
    expect([chat[0]!.text, chat[49]!.text]).toEqual(["old 2", "newest"]);
    sa.ws.close();
  });
});

describe("open rooms in the hub", () => {
  it("lists a friend's joinable room until it starts", async () => {
    const host = await setUpClient();
    const friend = await setUpClient();
    const stranger = await setUpClient();
    await befriend(host, friend);
    const hf = await connect(friend, "/v1/ws/hub");
    const hs = await connect(stranger, "/v1/ws/hub");
    expect(await hf.next({ op: "OPEN_ROOMS" })).toEqual({ op: "OPEN_ROOMS", rooms: [] });
    await hs.next({ op: "OPEN_ROOMS" });

    const code = await createRoom(host);
    const listing = { code, mode: "coop", hostId: host.uid, hostUsername: host.username, max: 4 };
    expect(await hf.next({ op: "OPEN_ROOMS" })).toEqual({ op: "OPEN_ROOMS", rooms: [{ ...listing, players: 1 }] });

    const sh = await join(host, code);
    const sf = await join(friend, code);
    expect(await hf.next({ op: "OPEN_ROOMS" })).toEqual({ op: "OPEN_ROOMS", rooms: [{ ...listing, players: 2 }] });

    // A friend connecting later sees it at once.
    hf.ws.close();
    const hf2 = await connect(friend, "/v1/ws/hub");
    expect(await hf2.next({ op: "OPEN_ROOMS" })).toEqual({ op: "OPEN_ROOMS", rooms: [{ ...listing, players: 2 }] });

    await startRound(sh, code, [sf]);
    expect(await hf2.next({ op: "OPEN_ROOMS" })).toEqual({ op: "OPEN_ROOMS", rooms: [] });
    expect((await hs.drain()).filter((m) => m.op === "OPEN_ROOMS")).toEqual([]);
    await closeAll(hf2, hs, sh, sf);
  });
});
