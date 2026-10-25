/**
 * The Forge Board (shared/forge-board.md) and Masterworks
 * (shared/masterworks.md) through the Worker: GET /v1/me/board, every claim,
 * gifts, Work Orders progress from solo sync, the daily, co-op and Versus,
 * Weekly Trials XP from every source, and account deletion.
 *
 * Most tests move the clock with Vitest's fake `Date` (as daily.test.ts
 * does), so days and weeks go by without waiting. The room tests run on
 * the real clock.
 */

import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { isoWeek } from "../../src/rules/board";
import { campaignPuzzle } from "../../src/rules/campaign";
import type { CoopRound } from "../../src/rules/coop-round";
import { utcDate } from "../../src/rules/daily";
import { gildedCell } from "../../src/rules/masterworks";
import { advance, dailyKinds, orderCounts, weeklyLetter, type OrderKind, type PlayFacts } from "../../src/rules/orders";
import type { VsRound } from "../../src/rules/vs-round";
import { befriend, body, client, setUpClient, uniqueUid, type Client } from "./helpers";
import { closeAll, connect, sleep, type Message, type Socket } from "./sockets";

type Smith = Client & { username: string };

const ZERO = { hammer: 0, chisel: 0, sparks: 0 };

/** Moves the clock and gives `c` a token signed at the new time (tokens last an hour). */
async function at(iso: string, c: Smith): Promise<Smith> {
  vi.setSystemTime(new Date(iso));
  return { ...(await client(c.uid)), username: c.username };
}

/** Moves the clock and makes a set-up player. */
async function smithAt(iso: string): Promise<Smith> {
  vi.setSystemTime(new Date(iso));
  return setUpClient();
}

function useFakeDate(): void {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] });
  });
  afterEach(() => {
    vi.useRealTimers();
  });
}

async function board(c: Client): Promise<Message> {
  const res = await c.get("/v1/me/board");
  expect(res.status, await res.clone().text()).toBe(200);
  return body<Message>(res);
}

async function post(c: Client, path: string, payload: unknown = {}): Promise<{ status: number; body: Message }> {
  const res = await c.post(path, payload);
  return { status: res.status, body: await body<Message>(res) };
}

function order(b: Message, slot: string): Message {
  return [...b.orders.daily, ...b.orders.weekly].find((o: Message) => o.slot === slot);
}

async function count(sql: string, ...binds: unknown[]): Promise<number> {
  return (await env.DB.prepare(sql).bind(...binds).first<number>("n")) ?? 0;
}

// ---------------------------------------------------------------------------
// Solo sync and the daily, as the app sends them
// ---------------------------------------------------------------------------

interface PuzzleJson {
  id: string;
  words: { w: string }[];
  bonus: string[];
}

function stage(n: number): PuzzleJson {
  return JSON.parse(env.TEST_CAMPAIGN[n - 1]!.data) as PuzzleJson;
}

/** A queue entry for `n` the server accepts: every grid word typed, no hints. */
function entry(n: number, extra: Record<string, unknown> = {}): Record<string, unknown> {
  const p = stage(n);
  return {
    stage: n,
    puzzleId: p.id,
    foundWords: p.words.map((w) => w.w),
    bonusWords: [],
    hintsUsed: {},
    pickups: [],
    gilded: [],
    durationMs: 60_000,
    completedAt: Date.now() - 3600_000 + n,
    ...extra,
  };
}

async function sync(c: Client, entries: unknown[]): Promise<Message> {
  const res = await c.post("/v1/solo/sync", { entries });
  expect(res.status, await res.clone().text()).toBe(200);
  return body<Message>(res);
}

/** Today's Daily Commission, solved with every word typed. */
async function completeDaily(c: Client, date?: string): Promise<Message> {
  const daily = await body<Message>(await c.get(date === undefined ? "/v1/daily" : `/v1/daily?date=${date}`));
  const words = (daily.puzzle.words as { w: string }[]).map((w) => w.w);
  const res = await c.post("/v1/daily/complete", { date: daily.date, foundWords: words, durationMs: 1000 * words.length });
  expect(res.status, await res.clone().text()).toBe(200);
  return body<Message>(res);
}

// ---------------------------------------------------------------------------

describe("weekly_xp", () => {
  it("follows every xp_events row into its ISO week, as isoWeek() does", async () => {
    const uid = uniqueUid("weeks");
    const days: number[] = [];
    // Across year ends (2026 has 53 weeks), and the first minute and last millisecond of a week.
    for (let d = 0; d < 40; d++) days.push(Date.parse("2026-12-15T12:00:00Z") + d * 86_400_000);
    days.push(Date.parse("2026-10-19T00:00:00Z"), Date.parse("2026-10-18T23:59:59.999Z"), Date.parse("2021-01-03T10:00:00Z"), Date.parse("2024-12-30T00:00:01Z"));
    const insert = env.DB.prepare("INSERT INTO xp_events (user_id, source, amount, ref, created_at) VALUES (?1, 'test', ?2, NULL, ?3)");
    await env.DB.batch(days.map((t, i) => insert.bind(uid, i + 1, t)));
    await env.DB.prepare("INSERT INTO xp_events (user_id, source, amount, ref, created_at) VALUES (?1, 'test', 0, NULL, ?2)")
      .bind(uid, Date.parse("2030-06-01T00:00:00Z"))
      .run();

    const want = new Map<string, number>();
    days.forEach((t, i) => want.set(isoWeek(utcDate(t)), (want.get(isoWeek(utcDate(t))) ?? 0) + i + 1));
    const { results } = await env.DB.prepare("SELECT week, xp FROM weekly_xp WHERE user_id = ?1").bind(uid).all<{ week: string; xp: number }>();
    expect(new Map(results.map((r) => [r.week, r.xp]))).toEqual(want);
    expect(want.get("2026-W53")).toBeGreaterThan(0);
    expect(want.has("2020-W53") && want.has("2025-W01")).toBe(true);
  });
});

describe("GET /v1/me/board", () => {
  useFakeDate();

  it("needs a set-up account, for every board route", async () => {
    vi.setSystemTime(new Date("2026-10-17T09:00:00Z"));
    const c = await client();
    expect((await c.get("/v1/me/board")).status).toBe(403);
    for (const path of ["/v1/me/stoke/claim", "/v1/me/orders/swap", "/v1/me/orders/claim", "/v1/me/trials/claim", "/v1/me/gifts/claim", "/v1/friends/x/gift"]) {
      expect(await post(c, path, { slot: "d0" })).toMatchObject({ status: 403, body: { error: "setup_required" } });
    }
  });

  it("shows a new player's board, with friends in the standings", async () => {
    const a = await smithAt("2026-10-17T09:00:00Z");
    const f = await setUpClient(undefined, "avatar_05");
    await befriend(a, f);
    const b = await board(a);
    const hammer = (n: number) => ({ ...ZERO, hammer: n });
    expect(b).toMatchObject({
      date: "2026-10-17",
      week: "2026-W42",
      stoke: { day: 1, claimedToday: false },
      orders: {
        chest: { reward: { xp: 30, hints: { ...ZERO, chisel: 1 } }, ready: false, claimed: false },
        swapAvailable: true,
        dailyEndsAt: Date.parse("2026-10-18T00:00:00Z"),
        weeklyEndsAt: Date.parse("2026-10-19T00:00:00Z"),
      },
      trials: { week: "2026-W42", endsAt: Date.parse("2026-10-19T00:00:00Z"), lastWeek: null },
      gifts: { pending: [], sentToday: [], claimedToday: 0, claimLimit: 5 },
    });
    expect(b.stoke.track).toHaveLength(7);
    expect(b.stoke.track[0]).toEqual({ xp: 15, hints: ZERO });
    expect(b.orders.daily).toEqual([
      { slot: "d0", kind: "daily", target: 1, progress: 0, letter: null, friends: false, reward: { xp: 20, hints: hammer(1) }, claimed: false },
      { slot: "d1", kind: "coop_rounds", target: 1, progress: 0, letter: null, friends: true, reward: { xp: 20, hints: hammer(1) }, claimed: false },
      { slot: "d2", kind: "words", target: 30, progress: 0, letter: null, friends: false, reward: { xp: 20, hints: hammer(1) }, claimed: false },
    ]);
    expect(b.orders.weekly.map((o: Message) => [o.slot, o.kind, o.target, o.letter])).toEqual([
      ["w0", "letter_hunt", 40, "T"],
      ["w1", "solo_puzzles", 15, null],
    ]);
    const byName = [a, f].sort((x, y) => x.username.toLowerCase().localeCompare(y.username.toLowerCase()));
    expect(b.trials.standings).toEqual(
      byName.map((p) => ({ id: p.uid, username: p.username, avatar: p === f ? "avatar_05" : "avatar_01", level: 1, xp: 0, me: p === a })),
    );
    // Reading the board writes nothing.
    expect(await count("SELECT COUNT(*) AS n FROM work_orders WHERE user_id = ?1", a.uid)).toBe(0);
  });
});

describe("the Daily Stoke", () => {
  useFakeDate();

  it("gives the next step once a day, missed days or not, with locked types as Hammer Strikes", async () => {
    let a = await smithAt("2026-10-10T08:00:00Z");
    const first = await post(a, "/v1/me/stoke/claim");
    expect(first.status, JSON.stringify(first.body)).toBe(200);
    expect(first.body.reward).toEqual({ xp: 15, hints: ZERO });
    expect(first.body.profile).toMatchObject({ totalXp: 15 });
    expect(first.body.board.stoke).toMatchObject({ day: 1, claimedToday: true });
    expect(await post(a, "/v1/me/stoke/claim")).toMatchObject({ status: 409, body: { error: "already_claimed" } });

    a = await at("2026-10-11T23:59:00Z", a);
    expect((await board(a)).stoke).toMatchObject({ day: 2, claimedToday: false });
    expect((await post(a, "/v1/me/stoke/claim")).body).toMatchObject({ reward: { xp: 0, hints: { ...ZERO, hammer: 1 } }, profile: { hints: { hammer: 4 } } });
    // Two days missed: the track just goes on.
    a = await at("2026-10-14T10:00:00Z", a);
    expect((await post(a, "/v1/me/stoke/claim")).body.reward).toEqual({ xp: 25, hints: ZERO });
    // Day 4's Chisel is a Hammer Strike below level 5.
    a = await at("2026-10-15T10:00:00Z", a);
    expect((await post(a, "/v1/me/stoke/claim")).body.reward).toEqual({ xp: 0, hints: { ...ZERO, hammer: 1 } });
    for (const [day, want] of [
      ["2026-10-16", { xp: 35, hints: ZERO }],
      ["2026-10-17", { xp: 0, hints: { ...ZERO, hammer: 2 } }],
      // Day 7's Spark Shower too, below level 12.
      ["2026-10-18", { xp: 50, hints: { ...ZERO, hammer: 1 } }],
      // And round again.
      ["2026-10-19", { xp: 15, hints: ZERO }],
    ] as const) {
      a = await at(`${day}T10:00:00Z`, a);
      expect((await post(a, "/v1/me/stoke/claim")).body.reward).toEqual(want);
    }
    const events = await env.DB.prepare("SELECT source, amount, ref FROM xp_events WHERE user_id = ?1 ORDER BY id").bind(a.uid).all();
    expect(events.results).toEqual([
      { source: "board", amount: 15, ref: "stoke:2026-10-10" },
      { source: "board", amount: 25, ref: "stoke:2026-10-14" },
      { source: "board", amount: 35, ref: "stoke:2026-10-16" },
      { source: "board", amount: 50, ref: "stoke:2026-10-18" },
      { source: "board", amount: 15, ref: "stoke:2026-10-19" },
    ]);
    // The XP counts towards the Weekly Trials: 15 in week 41, 110 in week 42, 15 in week 43.
    const weeks = await env.DB.prepare("SELECT week, xp FROM weekly_xp WHERE user_id = ?1 ORDER BY week").bind(a.uid).all();
    expect(weeks.results).toEqual([
      { week: "2026-W41", xp: 15 },
      { week: "2026-W42", xp: 110 },
      { week: "2026-W43", xp: 15 },
    ]);
    expect((await board(a)).trials.standings[0]).toMatchObject({ id: a.uid, xp: 15, me: true });
  });

  it("grants once when two claims arrive together", async () => {
    const a = await smithAt("2026-10-17T09:00:00Z");
    const results = await Promise.all([post(a, "/v1/me/stoke/claim"), post(a, "/v1/me/stoke/claim")]);
    expect(results.map((r) => r.status).sort()).toEqual([200, 409]);
    expect(results.find((r) => r.status === 409)!.body).toMatchObject({ error: "already_claimed" });
    expect((await body<Message>(await a.get("/v1/me"))).totalXp).toBe(15);
  });
});

describe("Work Orders", () => {
  useFakeDate();

  it("count solo sync, pay each order once, open the chest, and start afresh the next day", async () => {
    // Monday 2026-10-19: solo_puzzles, bonus_words, words.
    let a = await smithAt("2026-10-19T09:00:00Z");
    expect(dailyKinds("2026-10-19")).toEqual(["solo_puzzles", "bonus_words", "words"]);
    expect(await post(a, "/v1/me/orders/claim", { slot: "d0" })).toMatchObject({ status: 409, body: { error: "not_done" } });

    // Stages 1–10: 30 grid words, and 12 bonus words from the first three.
    const entries = Array.from({ length: 10 }, (_, i) => entry(i + 1, i < 3 ? { bonusWords: stage(i + 1).bonus } : {}));
    expect(entries.flatMap((e) => e.bonusWords as string[]).length).toBeGreaterThanOrEqual(10);
    const out = await sync(a, entries);
    expect(out.results.every((r: Message) => r.accepted)).toBe(true);
    const forged = entries.flatMap((e) => e.foundWords as string[]);
    const letter = weeklyLetter("2026-W43");
    let b = await board(a);
    expect(b.orders.daily.map((o: Message) => [o.kind, o.progress, o.target])).toEqual([
      ["solo_puzzles", 3, 3],
      ["bonus_words", 10, 10],
      ["words", 30, 30],
    ]);
    expect(order(b, "w0")).toMatchObject({ kind: "letter_hunt", letter, progress: forged.filter((w) => w.includes(letter)).length });
    expect(order(b, "w1")).toMatchObject({ kind: "solo_puzzles", progress: 10, target: 15 });

    const xpBefore = out.profile.totalXp as number;
    const d0 = await post(a, "/v1/me/orders/claim", { slot: "d0" });
    expect(d0.status, JSON.stringify(d0.body)).toBe(200);
    expect(d0.body.reward).toEqual({ xp: 20, hints: { ...ZERO, hammer: 1 } });
    expect(d0.body.profile.totalXp).toBe(xpBefore + 20);
    expect(order(d0.body.board, "d0")).toMatchObject({ claimed: true });
    expect(await post(a, "/v1/me/orders/claim", { slot: "d0" })).toMatchObject({ status: 409, body: { error: "already_claimed" } });
    expect(await post(a, "/v1/me/orders/claim", { slot: "chest" })).toMatchObject({ status: 409, body: { error: "not_done" } });
    expect(await post(a, "/v1/me/orders/claim", { slot: "w1" })).toMatchObject({ status: 409, body: { error: "not_done" } });
    for (const slot of ["d1", "d2"]) expect((await post(a, "/v1/me/orders/claim", { slot })).status).toBe(200);
    b = await board(a);
    expect(b.orders.chest).toMatchObject({ ready: true, claimed: false });
    // Level 3: the chest's Chisel is a Hammer Strike.
    const chest = await post(a, "/v1/me/orders/claim", { slot: "chest" });
    expect(chest.body).toMatchObject({ reward: { xp: 30, hints: { ...ZERO, hammer: 1 } }, board: { orders: { chest: { ready: true, claimed: true } } } });
    expect(await post(a, "/v1/me/orders/claim", { slot: "chest" })).toMatchObject({ status: 409, body: { error: "already_claimed" } });
    expect((await body<Message>(await a.get("/v1/me"))).totalXp).toBe(xpBefore + 90);

    for (const slot of [undefined, "d3", "swap", 7]) {
      expect(await post(a, "/v1/me/orders/claim", { slot })).toMatchObject({ status: 400, body: { error: "invalid_slot" } });
    }

    // Tuesday's orders start from nothing; the week's go on.
    a = await at("2026-10-20T09:00:00Z", a);
    b = await board(a);
    expect(b.orders.daily.map((o: Message) => [o.progress, o.claimed])).toEqual([
      [0, false],
      [0, false],
      [0, false],
    ]);
    expect(b.orders.chest).toEqual({ reward: { xp: 30, hints: { ...ZERO, chisel: 1 } }, ready: false, claimed: false });
    expect(order(b, "w1")).toMatchObject({ progress: 10 });
    // Five more campaign puzzles finish the weekly one.
    await sync(a, [11, 12, 13, 14, 15].map((n) => entry(n)));
    const w1 = await post(a, "/v1/me/orders/claim", { slot: "w1" });
    expect(w1.body).toMatchObject({ reward: { xp: 60 } });
    expect(order(w1.body.board, "w1")).toMatchObject({ progress: 15, claimed: true });
    const refs = await env.DB.prepare("SELECT ref FROM xp_events WHERE user_id = ?1 AND source = 'board' ORDER BY id").bind(a.uid).all();
    expect(refs.results.map((r) => r.ref)).toEqual([
      "order:d:2026-10-19:d0",
      "order:d:2026-10-19:d1",
      "order:d:2026-10-19:d2",
      "chest:2026-10-19",
      "order:w:2026-W43:w1",
    ]);
  });

  it("count the Daily Commission (late days too) and campaign puzzles with no hints", async () => {
    // Saturday 2026-10-17 has a `daily` order; a late day counts for it, on the day it's sent.
    let a = await smithAt("2026-10-17T09:00:00Z");
    expect(order(await board(a), "d0")).toMatchObject({ kind: "daily", progress: 0 });
    const late = await completeDaily(a, "2026-10-05");
    expect(late).toMatchObject({ late: true, xp: 15 });
    expect(order(await board(a), "d0")).toMatchObject({ kind: "daily", progress: 1 });
    // A repeat doesn't count again.
    expect(await completeDaily(a, "2026-10-05")).toMatchObject({ alreadyDone: true });
    expect(order(await board(a), "d0")).toMatchObject({ progress: 1 });

    // Sunday 2026-10-18: bonus_words, no_hints, long_words.
    a = await at("2026-10-18T09:00:00Z", a);
    expect(dailyKinds("2026-10-18")).toEqual(["bonus_words", "no_hints", "long_words"]);
    const withBonus = [2, 3, 4, 5].find((s) => stage(s).bonus.length >= 3)!;
    await sync(a, [entry(1, { hintsUsed: { hammer: 1 } }), entry(withBonus, { bonusWords: stage(withBonus).bonus.slice(0, 3) })]);
    const b = await board(a);
    expect(order(b, "d0")).toMatchObject({ kind: "bonus_words", progress: 3 });
    expect(order(b, "d1")).toMatchObject({ kind: "no_hints", progress: 1 });
  });

  it("swap one unfinished daily order a day", async () => {
    // Saturday 2026-10-17: daily, coop_rounds, words.
    const a = await smithAt("2026-10-17T09:00:00Z");
    await completeDaily(a);
    expect(await post(a, "/v1/me/orders/swap", { slot: "d0" })).toMatchObject({ status: 409, body: { error: "order_done" } });
    for (const slot of ["w0", "chest", "d3", undefined]) {
      expect(await post(a, "/v1/me/orders/swap", { slot })).toMatchObject({ status: 400, body: { error: "invalid_slot" } });
    }

    const swap = await post(a, "/v1/me/orders/swap", { slot: "d1" });
    expect(swap.status, JSON.stringify(swap.body)).toBe(200);
    expect(swap.body.reward).toEqual({ xp: 0, hints: ZERO });
    const swapped = order(swap.body.board, "d1");
    expect(["daily", "coop_rounds", "words"]).not.toContain(swapped.kind);
    expect(swapped).toMatchObject({ progress: 0, claimed: false });
    expect(swap.body.board.orders.swapAvailable).toBe(false);
    expect(order(swap.body.board, "d0")).toMatchObject({ kind: "daily", progress: 1 });
    expect(await post(a, "/v1/me/orders/swap", { slot: "d2" })).toMatchObject({ status: 409, body: { error: "swap_used" } });

    // Later progress keeps the swapped kind, and counts for it.
    const words = order(swap.body.board, "d2").progress as number;
    const facts: PlayFacts = { soloPuzzles: 2, noHintPuzzles: 2, forged: [...(entry(1).foundWords as string[]), ...(entry(2).foundWords as string[])] };
    await sync(a, [entry(1), entry(2)]);
    const b = await board(a);
    expect(order(b, "d1")).toMatchObject({ kind: swapped.kind, progress: advance({ kind: swapped.kind as OrderKind, target: swapped.target as number }, 0, orderCounts(facts, "T")) });
    expect(order(b, "d2")).toMatchObject({ kind: "words", progress: Math.min(30, words + 6) });
  });

  it("pay once when two claims of the same order arrive together", async () => {
    const a = await smithAt("2026-10-17T09:00:00Z");
    const done = await completeDaily(a);
    const results = await Promise.all([post(a, "/v1/me/orders/claim", { slot: "d0" }), post(a, "/v1/me/orders/claim", { slot: "d0" })]);
    expect(results.map((r) => r.status).sort()).toEqual([200, 409]);
    expect((await body<Message>(await a.get("/v1/me"))).totalXp).toBe((done.xp as number) + 20);
  });
});

describe("the Weekly Trials", () => {
  useFakeDate();

  it("rank last week's XP among friends, pay the top 3 once, and count prizes as XP this week", async () => {
    vi.setSystemTime(new Date("2026-10-10T09:00:00Z")); // Saturday, week 41
    let a = await setUpClient();
    let b = await setUpClient();
    let c = await setUpClient();
    await befriend(a, b);
    await befriend(a, c);
    await post(a, "/v1/me/stoke/claim"); // 15
    await post(b, "/v1/me/stoke/claim"); // 15
    await completeDaily(b); // + 25

    // Monday, week 42.
    a = await at("2026-10-12T09:00:00Z", a);
    b = await at("2026-10-12T09:00:00Z", b);
    c = await at("2026-10-12T09:00:00Z", c);
    const ab = await board(a);
    expect(ab.trials.lastWeek).toEqual({ week: "2026-W41", place: 2, of: 2, reward: { xp: 50, hints: { ...ZERO, chisel: 1 } }, claimed: false });
    expect(ab.trials.standings.map((s: Message) => s.xp)).toEqual([0, 0, 0]);
    expect((await board(b)).trials.lastWeek).toMatchObject({ place: 1, of: 2, reward: { xp: 100, hints: { ...ZERO, sparks: 1 } } });
    expect((await board(c)).trials.lastWeek).toBeNull();

    const prize = await post(a, "/v1/me/trials/claim");
    expect(prize.status, JSON.stringify(prize.body)).toBe(200);
    // Level 1: the Chisel is a Hammer Strike.
    expect(prize.body.reward).toEqual({ xp: 50, hints: { ...ZERO, hammer: 1 } });
    expect(prize.body.board.trials.lastWeek).toMatchObject({ claimed: true });
    expect(prize.body.board.trials.standings[0]).toMatchObject({ id: a.uid, xp: 50, me: true });
    expect(await post(a, "/v1/me/trials/claim")).toMatchObject({ status: 409, body: { error: "already_claimed" } });
    expect(await post(c, "/v1/me/trials/claim")).toMatchObject({ status: 409, body: { error: "no_prize" } });

    // Week 43: only A earned XP in week 42 (the prize), so there's no prize for being alone.
    a = await at("2026-10-19T09:00:00Z", a);
    expect((await board(a)).trials.lastWeek).toEqual({ week: "2026-W42", place: 1, of: 1, reward: null, claimed: false });
    expect(await post(a, "/v1/me/trials/claim")).toMatchObject({ status: 409, body: { error: "no_prize" } });
  });
});

describe("gifts", () => {
  useFakeDate();

  it("go to friends once a day, and are collected as Hammer Strikes", async () => {
    vi.setSystemTime(new Date("2026-10-17T09:00:00Z"));
    let a = await setUpClient();
    let b = await setUpClient(undefined, "avatar_07");
    const stranger = await setUpClient();
    await befriend(a, b);

    expect(await post(a, `/v1/friends/${b.uid}/gift`)).toEqual({ status: 200, body: { ok: true } });
    expect(await post(a, `/v1/friends/${b.uid}/gift`)).toMatchObject({ status: 409, body: { error: "already_sent" } });
    expect(await post(a, `/v1/friends/${stranger.uid}/gift`)).toMatchObject({ status: 404, body: { error: "not_friends" } });
    expect(await post(a, "/v1/friends/nobody-at-all/gift")).toMatchObject({ status: 404, body: { error: "not_friends" } });
    expect(await post(a, `/v1/friends/${a.uid}/gift`)).toMatchObject({ status: 400, body: { error: "cannot_gift_self" } });
    expect((await board(a)).gifts).toMatchObject({ sentToday: [b.uid], pending: [] });

    const bb = await board(b);
    expect(bb.gifts.pending).toEqual([{ id: expect.any(Number), from: { id: a.uid, username: a.username, avatar: "avatar_01" }, sentAt: Date.now() }]);
    const claimed = await post(b, "/v1/me/gifts/claim");
    expect(claimed.status, JSON.stringify(claimed.body)).toBe(200);
    expect(claimed.body.reward).toEqual({ xp: 0, hints: { ...ZERO, hammer: 1 } });
    expect(claimed.body.profile.hints.hammer).toBe(4);
    expect(claimed.body.board.gifts).toMatchObject({ pending: [], claimedToday: 1 });
    expect(await post(b, "/v1/me/gifts/claim")).toMatchObject({ status: 409, body: { error: "nothing_to_claim" } });

    // Tomorrow A may send another. Removing the friend leaves it waiting.
    a = await at("2026-10-18T09:00:00Z", a);
    b = await at("2026-10-18T09:00:00Z", b);
    expect((await board(a)).gifts.sentToday).toEqual([]);
    expect((await post(a, `/v1/friends/${b.uid}/gift`)).status).toBe(200);
    expect((await b.del(`/v1/friends/${a.uid}`)).status).toBe(200);
    expect((await board(b)).gifts.pending).toHaveLength(1);
    expect((await post(b, "/v1/me/gifts/claim")).body.reward).toEqual({ xp: 0, hints: { ...ZERO, hammer: 1 } });
    expect(await post(a, `/v1/friends/${b.uid}/gift`)).toMatchObject({ status: 404, body: { error: "not_friends" } });
  });

  it("are collected 5 a day at most, oldest first, and expire after 7 days", async () => {
    vi.setSystemTime(new Date("2026-10-10T09:00:00Z"));
    let x = await setUpClient();
    const friends: Smith[] = [];
    for (let i = 0; i < 7; i++) {
      const f = await setUpClient();
      await befriend(f, x);
      friends.push(f);
    }
    // The first sends on the 10th; the rest a week later, a minute apart.
    expect((await post(friends[0]!, `/v1/friends/${x.uid}/gift`)).status).toBe(200);
    x = await at("2026-10-17T08:59:00Z", x);
    for (const [i, f] of friends.slice(1).entries()) {
      vi.setSystemTime(new Date(Date.parse("2026-10-17T08:00:00Z") + i * 60_000));
      expect((await post(await client(f.uid), `/v1/friends/${x.uid}/gift`)).status).toBe(200);
    }
    // One minute before it expires, the first is still there.
    x = await at("2026-10-17T08:59:00Z", x);
    expect((await board(x)).gifts.pending).toHaveLength(7);
    x = await at("2026-10-17T09:00:00Z", x);
    const waiting = (await board(x)).gifts.pending as Message[];
    expect(waiting.map((g) => g.from.id)).toEqual(friends.slice(1).map((f) => f.uid));

    const results = await Promise.all([post(x, "/v1/me/gifts/claim"), post(x, "/v1/me/gifts/claim")]);
    expect(results.map((r) => r.status).sort()).toEqual([200, 409]);
    const first = results.find((r) => r.status === 200)!.body;
    expect(first.reward).toEqual({ xp: 0, hints: { ...ZERO, hammer: 5 } });
    expect(first.board.gifts).toMatchObject({ claimedToday: 5 });
    expect(first.board.gifts.pending.map((g: Message) => g.from.id)).toEqual([friends[6]!.uid]);
    expect(await post(x, "/v1/me/gifts/claim")).toMatchObject({ status: 409, body: { error: "nothing_to_claim" } });
    expect((await body<Message>(await x.get("/v1/me"))).hints.hammer).toBe(3 + 5);

    x = await at("2026-10-18T09:00:00Z", x);
    expect((await post(x, "/v1/me/gifts/claim")).body.reward.hints.hammer).toBe(1);
  });
});

describe("Masterworks", () => {
  /** The first stages (from 1) with a gilded cell for `uid`, with the cell. */
  function gildedStages(uid: string, n: number): { stage: number; cell: number }[] {
    const out: { stage: number; cell: number }[] = [];
    for (let s = 1; out.length < n; s++) {
      const p = campaignPuzzle(s, stage(s));
      const cell = gildedCell(uid, p.id, p.cellCount, 1);
      if (cell !== null) out.push({ stage: s, cell });
    }
    return out;
  }

  it("count a piece for the right gilded cell, and finish a Masterwork in the sync", async () => {
    const c = await setUpClient();
    expect((await body<Message>(await c.get("/v1/me"))).masterworks).toEqual({ pieces: 0 });
    const [g1, g2, g3] = gildedStages(c.uid, 3);
    const out = await sync(c, [entry(g1!.stage, { gilded: [g1!.cell] }), entry(g2!.stage, { gilded: [(g2!.cell + 1) % 3] })]);
    expect(out.results[0]).toMatchObject({ accepted: true, gilded: [g1!.cell] });
    expect(out.results[1]).toMatchObject({ accepted: true });
    expect(out.results[1]).not.toHaveProperty("gilded");
    expect(out.profile.masterworks).toEqual({ pieces: 1 });

    // The sixth piece finishes the Horseshoe: 100 XP, and at this level the Chisel and Spark Shower are Hammer Strikes.
    await env.DB.prepare("UPDATE profiles SET masterwork_pieces = 5 WHERE user_id = ?1").bind(c.uid).run();
    const before = await body<Message>(await c.get("/v1/me"));
    const done = await sync(c, [entry(g3!.stage, { gilded: [g3!.cell] })]);
    const result = done.results[0];
    expect(result).toMatchObject({ accepted: true, gilded: [g3!.cell], masterwork: { id: "horseshoe", reward: { xp: 100, hints: { ...ZERO, hammer: 2 } } } });
    expect(done.profile.masterworks).toEqual({ pieces: 6 });
    expect(done.profile.totalXp).toBe(before.totalXp + result.xp + 100);
    expect(done.profile.hints.hammer).toBe(before.hints.hammer + 2 + result.rewards.hammer);
    const events = await env.DB.prepare("SELECT source, amount, ref FROM xp_events WHERE user_id = ?1 AND source = 'masterwork'").bind(c.uid).all();
    expect(events.results).toEqual([{ source: "masterwork", amount: 100, ref: "horseshoe" }]);
    // All of it is this week's XP.
    const week = isoWeek(utcDate(Date.now()));
    expect(await count("SELECT xp AS n FROM weekly_xp WHERE user_id = ?1 AND week = ?2", c.uid, week)).toBe(done.profile.totalXp);
  });
});

describe("Work Orders from rooms", () => {
  function stub(code: string) {
    return env.ROOM.get(env.ROOM.idFromName(code));
  }
  async function join(c: Client, code: string): Promise<Socket> {
    const s = await connect(c, `/v1/ws/room/${code}`);
    await s.next({ op: "SNAPSHOT" });
    return s;
  }
  async function room(c: Client, mode: "coop" | "vs"): Promise<string> {
    return (await body<{ code: string }>(await c.post("/v1/rooms", { mode }))).code;
  }
  async function begin(host: Socket, code: string, sockets: Socket[]): Promise<void> {
    host.send({ op: "START" });
    for (const s of sockets) await s.next({ op: "ROUND_START" });
    expect(await runDurableObjectAlarm(stub(code))).toBe(true);
    for (const s of sockets) await s.next({ op: "LOBBY", phase: "round" });
  }
  /** What the board should show for these facts, today. */
  function expected(facts: PlayFacts): Record<string, number> {
    const date = utcDate(Date.now());
    const counts = orderCounts(facts, weeklyLetter(isoWeek(date)));
    const out: Record<string, number> = {};
    dailyKinds(date).forEach((kind, i) => (out[`d${i}`] = advance({ kind, target: 99 }, 0, counts)));
    out.w0 = advance({ kind: "letter_hunt", target: 40 }, 0, counts);
    out.w1 = advance({ kind: "solo_puzzles", target: 15 }, 0, counts);
    return out;
  }
  /** A message `s` has had, read or not (next() moves past the ones it skips). */
  async function seen(s: Socket, op: string): Promise<Message> {
    const deadline = Date.now() + 3000;
    for (;;) {
      const m = s.seen.find((x) => x.op === op);
      if (m !== undefined) return m;
      if (Date.now() > deadline) throw new Error(`no ${op}`);
      await sleep(25);
    }
  }
  function progress(b: Message): Record<string, number> {
    return Object.fromEntries([...b.orders.daily, ...b.orders.weekly].map((o: Message) => [o.slot, Math.min(o.progress, 99)]));
  }

  it("count a co-op round, with the words the player forged and the bonus words they found", async () => {
    const a = await setUpClient();
    const code = await room(a, "coop");
    const sa = await join(a, code);
    await begin(sa, code, [sa]);
    const round = await runInDurableObject(stub(code), (_i, state) => state.storage.kv.get<CoopRound>("round")!);
    const forged: string[] = [];
    let seq = 1;
    // Some bank puzzles have no bonus words.
    const bonus = round.puzzle.bonus.slice(0, 1);
    for (const word of bonus) {
      sa.send({ op: "SUBMIT", word, seq });
      expect(await sa.next({ op: "WORD_RESULT", seq: seq++ })).toMatchObject({ result: "bonus" });
    }
    for (const slot of round.puzzle.slots) {
      await sleep(260);
      sa.send({ op: "SUBMIT", word: slot.word, seq });
      const r = await sa.next({ op: "WORD_RESULT", seq: seq++ });
      if (r.result === "claimed") forged.push(slot.word);
    }
    const end = await seen(sa, "ROUND_END");
    const b = await board(a);
    const want = expected({ coopRounds: 1, bonusWords: bonus.length, forged });
    for (const o of b.orders.daily as Message[]) expect(Math.min(o.progress, 99)).toBe(Math.min(want[o.slot]!, o.target));
    expect(order(b, "w0").progress).toBe(want.w0);
    expect(b.trials.standings[0]).toMatchObject({ id: a.uid, xp: end.xp[a.uid].xp });
    await closeAll(sa);
  });

  it("count a finished Versus series for everyone on its podium", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const code = await room(a, "vs");
    const sa = await join(a, code);
    const sb = await join(b, code);
    await begin(sa, code, [sa, sb]);
    const round = await runInDurableObject(stub(code), (_i, state) => state.storage.kv.get<VsRound>("round")!);
    const word = round.puzzle.slots[0]!.word;
    sa.send({ op: "SUBMIT", word, seq: 1 });
    expect(await sa.next({ op: "WORD_RESULT", seq: 1 })).toMatchObject({ result: "claimed" });
    // B leaves: A wins by forfeit, and the series is written.
    sb.send({ op: "LEAVE" });
    await sb.closed;
    const series = await sa.next({ op: "SERIES_END" });
    expect(series).toMatchObject({ forfeit: true, winner: a.uid });
    for (const [c, facts] of [
      [a, { vsSeries: 1, forged: [word] }],
      [b, { vsSeries: 1 }],
    ] as const) {
      const got = await board(c);
      const want = expected(facts);
      for (const o of got.orders.daily as Message[]) expect(Math.min(o.progress, 99)).toBe(Math.min(want[o.slot]!, o.target));
      expect(progress(got).w0).toBe(want.w0);
      expect(got.trials.standings.find((s: Message) => s.me).xp).toBe(series.xp[c.uid].xp);
    }
    await closeAll(sa);
  });
});

describe("deleting an account", () => {
  useFakeDate();

  it("deletes its board rows, gifts it sent or received included", async () => {
    vi.setSystemTime(new Date("2026-10-12T09:00:00Z"));
    const a = await setUpClient();
    const b = await setUpClient();
    const c = await setUpClient();
    await befriend(a, b);
    await befriend(a, c);
    await post(a, "/v1/me/stoke/claim");
    await post(b, "/v1/me/stoke/claim");
    await completeDaily(a);
    await post(a, "/v1/me/orders/swap", { slot: "d1" });
    expect((await post(a, `/v1/friends/${b.uid}/gift`)).status).toBe(200);
    expect((await post(c, `/v1/friends/${a.uid}/gift`)).status).toBe(200);
    expect((await post(b, `/v1/friends/${c.uid}/gift`)).status).toBe(404); // not friends: nothing to keep
    await env.DB.prepare("INSERT INTO trial_claims (user_id, week, claimed_at) VALUES (?1, '2026-W41', 0)").bind(a.uid).run();

    const tables = ["work_orders", "weekly_xp", "trial_claims"];
    for (const t of tables) expect(await count(`SELECT COUNT(*) AS n FROM ${t} WHERE user_id = ?1`, a.uid)).toBeGreaterThan(0);
    expect((await a.del("/v1/me")).status).toBe(200);
    for (const t of tables) expect(await count(`SELECT COUNT(*) AS n FROM ${t} WHERE user_id = ?1`, a.uid)).toBe(0);
    expect(await count("SELECT COUNT(*) AS n FROM gifts WHERE from_user = ?1 OR to_user = ?1", a.uid)).toBe(0);
    // Everyone else's are kept.
    expect(await count("SELECT COUNT(*) AS n FROM weekly_xp WHERE user_id = ?1", b.uid)).toBe(1);
    expect((await board(b)).gifts.pending).toEqual([]);
  });
});
