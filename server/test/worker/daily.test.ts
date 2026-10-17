import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { dailyIndex } from "../../src/rules/daily";
import { body, client, setUpClient, type Client } from "./helpers";

type Message = Record<string, any>;
interface PuzzleJson {
  id: string;
  letters: string;
  heat: number;
  size: number;
  cols: number;
  rows: number;
  words: { w: string; x: number; y: number; d: "a" | "d" }[];
  bonus: string[];
}

// The clock is injected: only `Date` is faked, so nothing sleeps.
beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
});
afterEach(() => {
  vi.useRealTimers();
});

/** Moves the clock and gives `c` a token signed at the new time (tokens last an hour). */
async function at(iso: string, c?: Client): Promise<Client> {
  vi.setSystemTime(new Date(iso));
  return client(c?.uid);
}

/** The bank puzzle the server should pick for `date` at `heat`, worked out here from the bank file. */
function expectedPuzzle(date: string, heat: number): PuzzleJson {
  const candidates = env.TEST_BANK.filter((r) => r.heat === heat && r.size === 1).sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return JSON.parse(candidates[dailyIndex(date, candidates.length)]!.data) as PuzzleJson;
}

function cellsOf(w: { w: string; x: number; y: number; d: "a" | "d" }): string[] {
  return [...w.w].map((_, i) => (w.d === "a" ? `${w.x + i},${w.y}` : `${w.x},${w.y + i}`));
}

/** Forges the whole daily puzzle: every word typed, 1 s each. */
function solved(daily: Message, extra: Record<string, unknown> = {}): Record<string, unknown> {
  const words = (daily.puzzle.words as { w: string }[]).map((w) => w.w);
  return { date: daily.date, foundWords: words, bonusWords: [], hintsUsed: { hammer: 0, chisel: 0, sparks: 0 }, durationMs: 1000 * words.length, ...extra };
}

async function daily(c: Client): Promise<Message> {
  const res = await c.get("/v1/daily");
  expect(res.status, await res.clone().text()).toBe(200);
  return body<Message>(res);
}

async function complete(c: Client, payload: Record<string, unknown>): Promise<{ status: number; body: Message }> {
  const res = await c.post("/v1/daily/complete", payload);
  return { status: res.status, body: await body<Message>(res) };
}

async function hints(uid: string): Promise<Record<string, number>> {
  const { results } = await env.DB.prepare("SELECT item, count FROM inventory WHERE user_id = ?1").bind(uid).all<{ item: string; count: number }>();
  return Object.fromEntries(results.map((r) => [r.item, r.count]));
}

describe("GET /v1/daily", () => {
  it("serves the day's puzzle, the same for everyone, at the weekday's heat", async () => {
    await at("2026-10-17T09:00:00Z"); // a Saturday: White Heat
    const a = await setUpClient();
    const b = await setUpClient();
    const today = await daily(a);
    const bank = expectedPuzzle("2026-10-17", 6);
    expect(today).toEqual({
      date: "2026-10-17",
      heat: 6,
      puzzle: { id: "daily-2026-10-17", letters: bank.letters, heat: 6, cols: bank.cols, rows: bank.rows, words: bank.words, bonus: bank.bonus },
      completed: false,
      streak: 0,
      best: 0,
      total: 0,
    });
    expect((await daily(b)).puzzle).toEqual(today.puzzle);

    // Monday is Ember, Sunday Cherry Red; each day has its own puzzle.
    const monday = await daily(await at("2026-10-12T23:59:00Z", a));
    expect(monday).toMatchObject({ date: "2026-10-12", heat: 1, puzzle: { id: "daily-2026-10-12", letters: expectedPuzzle("2026-10-12", 1).letters } });
    const sunday = await daily(await at("2026-10-18T00:00:00Z", a));
    expect(sunday).toMatchObject({ date: "2026-10-18", heat: 3, puzzle: { words: expectedPuzzle("2026-10-18", 3).words } });
  });

  it("needs a set-up account", async () => {
    await at("2026-10-17T09:00:00Z");
    const c = await client();
    expect((await c.get("/v1/daily")).status).toBe(403);
    const res = await c.post("/v1/daily/complete", { date: "2026-10-17", foundWords: [], durationMs: 0 });
    expect(res.status).toBe(403);
    expect(await res.json()).toMatchObject({ error: "setup_required" });
  });
});

describe("POST /v1/daily/complete", () => {
  it("pays more for each day in a row, keeps the best streak, and lets yesterday's in for the first hour", async () => {
    let a: Client = await setUpClient(undefined, "avatar_01");
    // Monday.
    a = await at("2026-10-12T10:00:00Z", a);
    const mon = await daily(a);
    const first = await complete(a, solved(mon));
    expect(first.status, JSON.stringify(first.body)).toBe(200);
    expect(first.body).toMatchObject({ xp: 25, streak: 1, best: 1, alreadyDone: false, profile: { totalXp: 25 } });
    // Sending it again grants nothing.
    const again = await complete(a, solved(mon));
    expect(again.body).toMatchObject({ xp: 0, streak: 1, best: 1, alreadyDone: true, profile: { totalXp: 25 } });
    expect(await daily(a)).toMatchObject({ completed: true, streak: 1, best: 1 });

    // Tuesday: the streak carries over until today's is done.
    a = await at("2026-10-13T08:00:00Z", a);
    const tue = await daily(a);
    expect(tue).toMatchObject({ date: "2026-10-13", completed: false, streak: 1, best: 1 });
    expect((await complete(a, solved(tue))).body).toMatchObject({ xp: 30, streak: 2, best: 2 });

    // Wednesday is missed. Thursday starts again; the best stays.
    a = await at("2026-10-15T12:00:00Z", a);
    const thu = await daily(a);
    expect(thu).toMatchObject({ streak: 0, best: 2 });
    expect((await complete(a, solved(thu))).body).toMatchObject({ xp: 25, streak: 1, best: 2 });

    // Friday's, sent 30 minutes into Saturday: it still counts for Friday.
    a = await at("2026-10-16T22:00:00Z", a);
    const fri = await daily(a);
    a = await at("2026-10-17T00:30:00Z", a);
    expect((await daily(a)).date).toBe("2026-10-17");
    const late = await complete(a, solved(fri));
    expect(late.status, JSON.stringify(late.body)).toBe(200);
    expect(late.body).toMatchObject({ xp: 30, streak: 2, best: 2, alreadyDone: false });
    const sat = await daily(a);
    expect(sat).toMatchObject({ completed: false, streak: 2 });
    expect((await complete(a, solved(sat))).body).toMatchObject({ xp: 35, streak: 3, best: 3 });
    // An hour in, yesterday's would be late (shared/daily.md, "Calendar and
    // catch-up"), and this one is a repeat anyway.
    a = await at("2026-10-17T01:00:00Z", a);
    expect(await complete(a, solved(fri))).toMatchObject({ status: 200, body: { xp: 0, late: true, alreadyDone: true } });

    const me = await body<Message>(await a.get("/v1/me"));
    expect(me.totalXp).toBe(25 + 30 + 25 + 30 + 35);
    const events = await env.DB.prepare("SELECT source, amount, ref FROM xp_events WHERE user_id = ?1 ORDER BY id").bind(a.uid).all();
    expect(events.results).toEqual([
      { source: "daily", amount: 25, ref: "2026-10-12" },
      { source: "daily", amount: 30, ref: "2026-10-13" },
      { source: "daily", amount: 25, ref: "2026-10-15" },
      { source: "daily", amount: 30, ref: "2026-10-16" },
      { source: "daily", amount: 35, ref: "2026-10-17" },
    ]);
    const rows = await env.DB.prepare("SELECT date, xp FROM daily_completions WHERE user_id = ?1 ORDER BY date").bind(a.uid).all();
    expect(rows.results.map((r) => r.date)).toEqual(["2026-10-12", "2026-10-13", "2026-10-15", "2026-10-16", "2026-10-17"]);

    // Deleting the account deletes its completions.
    expect((await a.del("/v1/me")).status).toBe(200);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM daily_completions WHERE user_id = ?1").bind(a.uid).first("n")).toBe(0);
  });

  it("caps the streak bonus at +30", async () => {
    let a: Client = await setUpClient();
    // Six earlier days in a row, recorded directly.
    const insert = env.DB.prepare("INSERT INTO daily_completions (user_id, date, completed_at, xp) VALUES (?1, ?2, 0, 0)");
    await env.DB.batch(["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05", "2026-10-06"].map((d) => insert.bind(a.uid, d)));
    a = await at("2026-10-07T12:00:00Z", a);
    expect((await complete(a, solved(await daily(a)))).body).toMatchObject({ xp: 55, streak: 7, best: 7 });
    a = await at("2026-10-08T12:00:00Z", a);
    expect((await complete(a, solved(await daily(a)))).body).toMatchObject({ xp: 55, streak: 8, best: 8 });
  });

  it("takes the hints used, smelts bonus words, and records the puzzle as seen", async () => {
    let a: Client = await setUpClient();
    a = await at("2026-10-17T15:00:00Z", a);
    const today = await daily(a);
    const words = today.puzzle.words as PuzzleJson["words"];
    // Leave out the word with the most cells of its own, and show those with Hammer Strikes.
    const own = (w: PuzzleJson["words"][number]) => cellsOf(w).filter((c) => !words.some((o) => o !== w && cellsOf(o).includes(c))).length;
    const skipped = [...words].sort((x, y) => own(y) - own(x))[0]!;
    const typed = words.filter((w) => w !== skipped).map((w) => w.w.toLowerCase());
    const bonus = (today.puzzle.bonus as string[]).slice(0, 3);
    const payload = solved(today, { foundWords: typed, bonusWords: [...bonus, "NOTAWORD"], hintsUsed: { hammer: own(skipped), chisel: 0, sparks: 0 } });

    // One Hammer Strike short is incomplete.
    expect(await complete(a, { ...payload, hintsUsed: { hammer: own(skipped) - 1 } })).toMatchObject({ status: 400, body: { error: "incomplete" } });
    const done = await complete(a, payload);
    expect(done.status, JSON.stringify(done.body)).toBe(200);
    expect(done.body).toMatchObject({ xp: 25, alreadyDone: false });
    // 3 Hammer Strikes to start with; stock never goes below zero.
    expect(await hints(a.uid)).toMatchObject({ hammer: Math.max(3 - own(skipped), 0) });
    expect(done.body.profile).toMatchObject({ scrapBin: bonus.length, hints: { hammer: Math.max(3 - own(skipped), 0) } });
    expect(done.body.profile.stats).toMatchObject({ wordsForged: typed.length, soloDone: 0 });
    const bankId = expectedPuzzle("2026-10-17", 6).id;
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM puzzle_seen WHERE user_id = ?1 AND puzzle_id = ?2").bind(a.uid, bankId).first("n")).toBe(1);
  });

  it("refuses the wrong day, an unfinished mold, a too-quick one and a bad body", async () => {
    let a: Client = await setUpClient();
    a = await at("2026-10-17T15:00:00Z", a);
    const today = await daily(a);
    // Days before the 1st of last month, and days to come.
    for (const date of ["2026-08-31", "2026-10-18", "2026-11-01"]) {
      expect(await complete(a, solved(today, { date }))).toMatchObject({ status: 400, body: { error: "wrong_day" } });
    }
    const words = today.puzzle.words as { w: string }[];
    expect(await complete(a, solved(today, { foundWords: words.slice(1).map((w) => w.w) }))).toMatchObject({ status: 400, body: { error: "incomplete" } });
    expect(await complete(a, solved(today, { durationMs: 1000 * words.length - 1 }))).toMatchObject({ status: 400, body: { error: "too_fast" } });
    for (const bad of [{ date: "yesterday" }, { foundWords: "TEAR" }, { durationMs: -1 }, { hintsUsed: { hammer: "1" } }]) {
      expect(await complete(a, solved(today, bad))).toMatchObject({ status: 400, body: { error: "invalid_body" } });
    }
    // Nothing was granted.
    expect(await daily(a)).toMatchObject({ completed: false, streak: 0 });
    expect((await body<Message>(await a.get("/v1/me"))).totalXp).toBe(0);
  });
});
