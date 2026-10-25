import { describe, expect, it } from "vitest";
import { loadBankRows } from "../../scripts/build-bank-sql.mjs";
import { parseMpPuzzle, type Pos } from "../../src/rules/mold";
import { mulberry32 } from "../../src/rules/pickups";
import { totalXpForLevel } from "../../src/rules/progression";
import type { SeriesLength } from "../../src/rules/vs";
import {
  activeRacers,
  applyVsPickup,
  applyVsSubmit,
  canRace,
  endVsRound,
  markOut,
  MAX_HISTORY,
  mineOf,
  newVsRound,
  newVsSeries,
  progressOf,
  recordRound,
  resolveRound,
  seriesDecision,
  STANDINGS_MS,
  stopSeries,
  tallyOf,
  vsAward,
  vsRoundSnapshot,
  vsRoundStartFields,
  vsSeriesResults,
  type VsRound,
  type VsRoundEnd,
  type VsSeries,
} from "../../src/rules/vs-round";
import { CROSSED, EXAMPLE, playback } from "./fixtures";

const T0 = 1_800_000_000_000;
const example = parseMpPuzzle(EXAMPLE);
const crossed = parseMpPuzzle(CROSSED);

/** A round with no embers from the dice (0.5 ≥ 0.2); tests place their own. */
function round(players: string[], opts: { puzzle?: typeof example; embers?: Pos[]; n?: number; suddenDeath?: boolean } = {}): VsRound {
  const r = newVsRound({
    round: opts.n ?? 1,
    suddenDeath: opts.suddenDeath ?? false,
    heat: 1,
    puzzle: opts.puzzle ?? example,
    playerIds: players,
    startsAt: T0,
    rand: playback(0.5),
  });
  return { ...r, embers: opts.embers ?? [] };
}

function series(players: string[], length: SeriesLength = 3): VsSeries {
  return newVsSeries({ matchId: "series-1", length, heat: 1, racerIds: players, startedAt: T0 });
}

/** Plays a round where `winner` (if any) forges a word and nobody else does. */
function play(s: VsSeries, winner: string | null, players = activeRacers(s)): void {
  const r = round(players, { n: s.played + 1 });
  if (winner !== null) applyVsSubmit(r, winner, "TEAR");
  recordRound(s, r, resolveRound(r, activeRacers(s)));
}

describe("newVsRound", () => {
  it("gives everyone the same anvil and embers, an empty mold each, and the VS clock", () => {
    for (let seed = 0; seed < 50; seed++) {
      const r = newVsRound({ round: 2, suddenDeath: false, heat: 3, puzzle: example, playerIds: ["a", "b"], startsAt: T0, rand: mulberry32(seed) });
      expect(r.endsAt - r.startsAt).toBe(210_000); // Cherry Red: 3:30
      expect([...r.letters].sort().join("")).toBe("AERT");
      expect(["TEAR", "RATE"]).not.toContain(r.letters);
      expect(r.embers.length).toBeLessThanOrEqual(2);
      expect(r.total).toBe(9);
      expect(r.regular).toBe(2);
      expect(Object.keys(r.molds)).toEqual(["a", "b"]);
    }
    expect(newVsRound({ round: 4, suddenDeath: true, heat: 1, puzzle: example, playerIds: ["a"], startsAt: T0, rand: playback(0.5) })).toMatchObject({
      round: 4,
      regular: null,
      endsAt: T0 + 120_000,
    });
  });

  it("tells clients the mold's shape and the series, never its words", () => {
    const s = series(["a", "b", "c"], 5);
    s.racers[0]!.wins = 1;
    const r = round(["a", "b"], { n: 6, suddenDeath: true, embers: [{ x: 3, y: 3 }] });
    const fields = vsRoundStartFields(r, s, T0 - 3000);
    expect(fields).toEqual({
      round: 6,
      heat: 1,
      startsAt: T0,
      endsAt: T0 + 120_000,
      serverNow: T0 - 3000,
      letters: r.letters,
      cols: 4,
      rows: 4,
      slots: [
        { slot: 0, x: 0, y: 0, d: "a", len: 4 },
        { slot: 1, x: 1, y: 0, d: "d", len: 3 },
        { slot: 2, x: 3, y: 0, d: "d", len: 4 },
      ],
      pickups: [{ x: 3, y: 3 }],
      series: 5,
      regular: null,
      suddenDeath: true,
      players: ["a", "b"],
      tally: { a: 1, b: 0, c: 0 },
    });
    applyVsSubmit(r, "a", "EAT");
    const snap = vsRoundSnapshot(r, s, "b", T0);
    expect(snap.mine).toEqual({ claims: [], auto: [] });
    expect(snap.progress).toEqual([
      { id: "a", filled: 3, total: 9 },
      { id: "b", filled: 0, total: 9 },
    ]);
    const text = JSON.stringify({ ...snap, letters: undefined });
    for (const w of [...EXAMPLE.words.map((w) => w.w), ...EXAMPLE.bonus]) expect(text).not.toContain(w);
    expect(vsRoundSnapshot(r, s, "a", T0).mine).toEqual({ claims: [{ slot: 1, word: "EAT" }], auto: [] });
    // Someone watching has no mold at all.
    expect(mineOf(r, "c")).toEqual({ claims: [], auto: [] });
  });
});

describe("applyVsSubmit", () => {
  it("referees each racer against their own mold", () => {
    const r = round(["a", "b"]);
    expect(applyVsSubmit(r, "a", "tear")).toEqual({
      result: "claimed",
      word: "TEAR",
      slot: 0,
      auto: [],
      ember: null,
      filled: 4,
      total: 9,
      complete: false,
    });
    // Nobody can take a word from someone else.
    expect(applyVsSubmit(r, "b", "TEAR")).toMatchObject({ result: "claimed", slot: 0, filled: 4 });
    expect(applyVsSubmit(r, "a", "TEAR")).toEqual({ result: "already", word: "TEAR" });
    // EAT shares its first letter with TEAR, so it adds two cells.
    expect(applyVsSubmit(r, "a", "eat")).toMatchObject({ result: "claimed", slot: 1, filled: 6 });
    expect(progressOf(r)).toEqual([
      { id: "a", filled: 6, total: 9 },
      { id: "b", filled: 4, total: 9 },
    ]);
  });

  it("puts bonus words in the racer's Scrap Bin without counting them as progress", () => {
    const r = round(["a", "b"]);
    expect(applyVsSubmit(r, "a", "tea")).toEqual({ result: "bonus", word: "TEA" });
    expect(applyVsSubmit(r, "a", "TEA")).toEqual({ result: "already", word: "TEA" });
    expect(applyVsSubmit(r, "b", "TEA")).toEqual({ result: "bonus", word: "TEA" });
    expect(r.molds.a).toMatchObject({ bonus: ["TEA"], filled: 0, reachedAt: 0 });
  });

  it.each(["rta", "tears", "te", "", "t3a", "tree"])("refuses %j", (word) => {
    const r = round(["a"]);
    expect(applyVsSubmit(r, "a", word)).toEqual({ result: "invalid" });
    expect(r.molds.a!.claims).toEqual([]);
  });

  it("refuses words from someone who isn't racing", () => {
    expect(applyVsSubmit(round(["a"]), "watcher", "TEAR")).toEqual({ result: "invalid" });
  });

  it("fills in a slot whose every letter its crossing words filled, on that mold only", () => {
    const r = round(["a", "b"], { puzzle: crossed });
    expect(r.total).toBe(9);
    applyVsSubmit(r, "a", "ABC");
    applyVsSubmit(r, "a", "DEF");
    applyVsSubmit(r, "b", "ABC");
    expect(applyVsSubmit(r, "a", "BAF")).toEqual({
      result: "claimed",
      word: "BAF",
      slot: 3,
      auto: [{ slot: 1, word: "CDF" }],
      ember: null,
      filled: 9,
      total: 9,
      complete: true,
    });
    expect(applyVsSubmit(r, "a", "CDF")).toEqual({ result: "already", word: "CDF" });
    expect(applyVsSubmit(r, "b", "CDF")).toMatchObject({ result: "claimed", auto: [] });
    expect(mineOf(r, "a")).toEqual({
      claims: [
        { slot: 0, word: "ABC" },
        { slot: 2, word: "DEF" },
        { slot: 3, word: "BAF" },
      ],
      auto: [{ slot: 1, word: "CDF" }],
    });
  });

  it("stamps every gain with a fresh counter value, so ties always break", () => {
    const r = round(["a", "b"]);
    applyVsSubmit(r, "b", "EAT");
    applyVsSubmit(r, "a", "EAT");
    applyVsSubmit(r, "a", "TEA"); // bonus: no progress
    expect([r.molds.b!.reachedAt, r.molds.a!.reachedAt]).toEqual([1, 2]);
    expect(resolveRound(r, ["a", "b"])).toEqual({ winner: "b", how: "timeout" });
  });
});

describe("embers in Versus", () => {
  it("sit on the same cells for everyone, and each racer collects one once", () => {
    const r = round(["a", "b"], { embers: [{ x: 1, y: 0 }] });
    expect(applyVsSubmit(r, "a", "EAT")).toMatchObject({ ember: { x: 1, y: 0 } });
    applyVsPickup(r, "a", { x: 1, y: 0 }, "hammer");
    // TEAR crosses the same cell, but a already has that ember.
    expect(applyVsSubmit(r, "a", "TEAR")).toMatchObject({ ember: null });
    // b still finds it, through either word.
    expect(applyVsSubmit(r, "b", "TEAR")).toMatchObject({ ember: { x: 1, y: 0 } });
    applyVsPickup(r, "b", { x: 1, y: 0 }, "chisel");
    expect(applyVsSubmit(r, "b", "RATE")).toMatchObject({ ember: null });
    expect(r.embers).toEqual([{ x: 1, y: 0 }]);
    expect(r.molds.a!.pickups).toEqual([{ x: 1, y: 0, kind: "hammer" }]);
    expect(r.molds.b!.pickups).toEqual([{ x: 1, y: 0, kind: "chisel" }]);
  });
});

describe("resolveRound", () => {
  it("only lets racers still in the series win", () => {
    const r = round(["a", "b", "c"]);
    applyVsSubmit(r, "a", "RATE");
    applyVsSubmit(r, "b", "EAT");
    expect(resolveRound(r, ["a", "b", "c"])).toEqual({ winner: "a", how: "timeout" });
    expect(resolveRound(r, ["b", "c"])).toEqual({ winner: "b", how: "timeout" });
    expect(resolveRound(r, ["c"])).toEqual({ winner: null, how: "none" });
    // Watchers (not racing this round) never win it.
    expect(resolveRound(round(["a"]), ["a", "b"])).toEqual({ winner: null, how: "none" });
  });

  it("is finished once someone filled every letter", () => {
    const r = round(["a", "b"]);
    for (const w of ["TEAR", "EAT", "RATE"]) applyVsSubmit(r, "b", w);
    expect(resolveRound(r, ["a", "b"])).toEqual({ winner: "b", how: "finished" });
  });
});

describe("the series", () => {
  it("records each round: wins, rounds raced, words, bonus words and embers", () => {
    const s = series(["a", "b", "c"]);
    const r = round(["a", "b"], { embers: [{ x: 3, y: 3 }] });
    applyVsSubmit(r, "a", "RATE");
    applyVsPickup(r, "a", { x: 3, y: 3 }, "sparks");
    applyVsSubmit(r, "a", "EAT");
    applyVsSubmit(r, "b", "TEA");
    recordRound(s, r, resolveRound(r, activeRacers(s)));
    expect(s.played).toBe(1);
    expect(s.racers).toEqual([
      { id: "a", wins: 1, rounds: 1, words: 2, longest: "RATE", bonus: 0, score: 7, pickups: { hammer: 0, chisel: 0, sparks: 1 }, out: false },
      { id: "b", wins: 0, rounds: 1, words: 0, longest: "", bonus: 1, score: 0, pickups: { hammer: 0, chisel: 0, sparks: 0 }, out: false },
      { id: "c", wins: 0, rounds: 0, words: 0, longest: "", bonus: 0, score: 0, pickups: { hammer: 0, chisel: 0, sparks: 0 }, out: false },
    ]);
    expect(tallyOf(s)).toEqual({ a: 1, b: 0, c: 0 });
    // The words each racer forged, for their Work Orders; bonus words aren't.
    expect(s.forged).toEqual({ a: ["RATE", "EAT"], b: [] });
    const r2 = round(["a", "b"], { n: 2 });
    applyVsSubmit(r2, "b", "TEAR");
    recordRound(s, r2, resolveRound(r2, activeRacers(s)));
    expect(s.forged).toEqual({ a: ["RATE", "EAT"], b: ["TEAR"] });
  });

  it("plays the regular rounds, then sudden death between the tied leaders, replayed until someone wins", () => {
    const s = series(["a", "b", "c"]);
    expect(seriesDecision(s)).toEqual({ over: false, next: { round: 1, suddenDeath: false, players: ["a", "b", "c"] } });
    play(s, "a");
    play(s, "b");
    play(s, null);
    expect(seriesDecision(s)).toEqual({ over: false, next: { round: 4, suddenDeath: true, players: ["a", "b"] } });
    play(s, null, ["a", "b"]);
    expect(seriesDecision(s)).toEqual({ over: false, next: { round: 5, suddenDeath: true, players: ["a", "b"] } });
    play(s, "b", ["a", "b"]);
    expect(seriesDecision(s)).toEqual({ over: true, winner: "b", early: false, forfeit: false });
  });

  it("ends early once nobody can catch the leader", () => {
    const s = series(["a", "b"], 5);
    play(s, "a");
    play(s, "a");
    expect(seriesDecision(s).over).toBe(false);
    play(s, "a");
    expect(seriesDecision(s)).toEqual({ over: true, winner: "a", early: true, forfeit: false });
  });

  it("goes on without racers who left, and is a forfeit once only one is left", () => {
    const s = series(["a", "b", "c"]);
    play(s, "c");
    expect(markOut(s, "c")).toBe(true);
    expect(markOut(s, "c")).toBe(false);
    expect(markOut(s, "nobody")).toBe(false);
    expect(canRace(s, "c")).toBe(false);
    expect(canRace(s, "a")).toBe(true);
    // c keeps their win, but the series is decided among a and b.
    expect(seriesDecision(s)).toEqual({ over: false, next: { round: 2, suddenDeath: false, players: ["a", "b"] } });
    markOut(s, "b");
    expect(seriesDecision(s)).toEqual({ over: true, winner: "a", early: false, forfeit: true });
    expect(tallyOf(s)).toEqual({ a: 0, b: 0, c: 1 });
  });

  it("is decided when a sudden-death player leaves and one tied leader is left", () => {
    const s = series(["a", "b", "c"]);
    play(s, "a");
    play(s, "b");
    play(s, "c");
    expect(seriesDecision(s)).toMatchObject({ next: { suddenDeath: true, players: ["a", "b", "c"] } });
    markOut(s, "b");
    expect(seriesDecision(s)).toMatchObject({ next: { suddenDeath: true, players: ["a", "c"] } });
    markOut(s, "c");
    expect(seriesDecision(s)).toEqual({ over: true, winner: "a", early: false, forfeit: true });

    // With someone left watching, the last tied leader simply wins.
    const t = series(["a", "b", "c"], 5);
    for (const w of ["a", "b", "a", "b", "c"]) play(t, w);
    expect(seriesDecision(t)).toMatchObject({ next: { round: 6, suddenDeath: true, players: ["a", "b"] } });
    markOut(t, "b");
    expect(seriesDecision(t)).toEqual({ over: true, winner: "a", early: false, forfeit: false });
  });

  it("stops with no winner when the room closes before it's decided", () => {
    const s = series(["a", "b"]);
    play(s, "a");
    expect(stopSeries(s)).toEqual({ winner: null, early: false, forfeit: false });
    play(s, "a");
    expect(stopSeries(s)).toEqual({ winner: "a", early: true, forfeit: false });
  });
});

describe("endVsRound", () => {
  it("resolves the round and plans the next one after the standings", () => {
    const s = series(["a", "b"]);
    const r = round(["a", "b"]);
    applyVsSubmit(r, "b", "EAT");
    const end = endVsRound(s, r, "timeout", T0 + 50_000);
    expect(end).toEqual({
      fields: {
        round: 1,
        reason: "timeout",
        winner: "b",
        how: "timeout",
        progress: [
          { id: "a", filled: 0, total: 9 },
          { id: "b", filled: 3, total: 9 },
        ],
        molds: { a: [], b: [1] },
        tally: { a: 0, b: 1 },
        answers: [
          { slot: 0, word: "TEAR" },
          { slot: 1, word: "EAT" },
          { slot: 2, word: "RATE" },
        ],
        next: { round: 2, suddenDeath: false, players: ["a", "b"] },
        standingsEndsAt: T0 + 50_000 + STANDINGS_MS,
      },
      outcome: null,
    });
  });

  it("has no next round once the series is decided, or when told to stop", () => {
    const s = series(["a", "b"]);
    play(s, "a");
    const r = round(["a", "b"], { n: 2 });
    for (const w of ["TEAR", "EAT", "RATE"]) applyVsSubmit(r, "a", w);
    const end = endVsRound(s, r, "finished", T0);
    expect(end.fields).toMatchObject({ round: 2, winner: "a", how: "finished", next: null, standingsEndsAt: null, tally: { a: 2, b: 0 } });
    expect(end.outcome).toEqual({ winner: "a", early: true, forfeit: false });

    const t = series(["a", "b"]);
    const stopped = endVsRound(t, round(["a", "b"]), "timeout", T0, true);
    expect(stopped.fields).toMatchObject({ how: "none", next: null, standingsEndsAt: null });
    expect(stopped.outcome).toEqual({ winner: null, early: false, forfeit: false });
  });

  it("shows every racer's mold once it's over: the slots forged or filled in by themselves, sorted", () => {
    // Finished: a's last word fills CDF (slot 1) in by itself.
    const r = round(["a", "b"], { puzzle: crossed });
    for (const w of ["DEF", "ABC", "BAF"]) applyVsSubmit(r, "a", w);
    applyVsSubmit(r, "b", "CDF");
    applyVsSubmit(r, "b", "ABC");
    applyVsSubmit(r, "b", "BAD"); // bonus: not on the mold
    expect(r.molds.a!.auto).toEqual([{ slot: 1, word: "CDF" }]);
    expect(endVsRound(series(["a", "b"]), r, "finished", T0).fields).toMatchObject({ winner: "a", molds: { a: [0, 1, 2, 3], b: [0, 1] } });

    // Timeout: someone with nothing has an empty mold.
    const t = round(["a", "b", "c"]);
    applyVsSubmit(t, "c", "RATE");
    applyVsSubmit(t, "c", "TEAR");
    applyVsSubmit(t, "a", "EAT");
    expect(endVsRound(series(["a", "b", "c"]), t, "timeout", T0).fields.molds).toEqual({ a: [1], b: [], c: [0, 2] });
  });

  it("keeps the mold of a racer who left mid-round, and has none for someone watching", () => {
    // Sudden death between a and b, c watching; b leaves before it ends.
    const s = series(["a", "b", "c"]);
    for (const w of ["a", "b", null]) play(s, w);
    const r = round(["a", "b"], { n: 4, suddenDeath: true });
    applyVsSubmit(r, "a", "EAT");
    applyVsSubmit(r, "b", "RATE");
    applyVsSubmit(r, "b", "TEAR");
    markOut(s, "b");
    const end = endVsRound(s, r, "timeout", T0, true);
    expect(end.fields).toMatchObject({ winner: "a", how: "timeout" });
    expect(end.fields.molds).toEqual({ a: [1], b: [0, 2] });
  });
});

describe("the series' history", () => {
  /** EXAMPLE's shape: TEAR across the top, EAT and RATE down. */
  const shape = {
    cols: 4,
    rows: 4,
    slots: [
      { slot: 0, x: 0, y: 0, d: "a", len: 4 },
      { slot: 1, x: 1, y: 0, d: "d", len: 3 },
      { slot: 2, x: 3, y: 0, d: "d", len: 4 },
    ],
  };

  /** Ends the next round on time: `winner` (if any) forges TEAR, nobody else anything. */
  function finish(s: VsSeries, winner: string | null, players = activeRacers(s)): VsRoundEnd {
    const sudden = s.played >= s.length;
    const r = round(players, { n: s.played + 1, suddenDeath: sudden });
    if (winner !== null) applyVsSubmit(r, winner, "TEAR");
    return endVsRound(s, r, "timeout", T0);
  }

  /** EXAMPLE's words, by slot. */
  const answers = [
    { slot: 0, word: "TEAR" },
    { slot: 1, word: "EAT" },
    { slot: 2, word: "RATE" },
  ];

  it("sums up every round of a best of 3, in order, with each racer's mold, its shape, the words and the Scrap Bins", () => {
    const s = series(["a", "b", "c"]);
    expect(s.history).toBeUndefined();
    // Round 1: a fills the mold; b has EAT, and two bonus words (one found twice).
    const r1 = round(["a", "b", "c"]);
    applyVsSubmit(r1, "b", "EAT");
    for (const w of ["tea", "EAR", "TEA"]) applyVsSubmit(r1, "b", w);
    for (const w of ["TEAR", "ART", "EAT", "RATE"]) applyVsSubmit(r1, "a", w);
    endVsRound(s, r1, "finished", T0);
    // Round 2: b has the most letters when time runs out.
    const r2 = round(["a", "b", "c"], { n: 2 });
    applyVsSubmit(r2, "b", "RATE");
    applyVsSubmit(r2, "c", "EAT");
    applyVsSubmit(r2, "c", "RAT");
    endVsRound(s, r2, "timeout", T0);
    // Round 3: a again, which decides it.
    const third = finish(s, "a");
    expect(third.outcome).toEqual({ winner: "a", early: false, forfeit: false });

    const progress = (filled: Record<string, number>) => ["a", "b", "c"].map((id) => ({ id, filled: filled[id] ?? 0, total: 9 }));
    const letters = r1.letters;
    expect(s.history).toEqual([
      {
        round: 1,
        suddenDeath: false,
        reason: "finished",
        winner: "a",
        how: "finished",
        ...shape,
        progress: progress({ a: 9, b: 3 }),
        molds: { a: [0, 1, 2], b: [1], c: [] },
        letters,
        answers,
        bins: { a: ["ART"], b: ["TEA", "EAR"], c: [] },
      },
      {
        round: 2,
        suddenDeath: false,
        reason: "timeout",
        winner: "b",
        how: "timeout",
        ...shape,
        progress: progress({ b: 4, c: 3 }),
        molds: { a: [], b: [2], c: [1] },
        letters,
        answers,
        bins: { a: [], b: [], c: ["RAT"] },
      },
      {
        round: 3,
        suddenDeath: false,
        reason: "timeout",
        winner: "a",
        how: "timeout",
        ...shape,
        progress: progress({ a: 4 }),
        molds: { a: [0], b: [], c: [] },
        letters,
        answers,
        bins: { a: [], b: [], c: [] },
      },
    ]);
    // The same anvil as everyone got at the start, and every grid word as ROUND_END had them.
    expect(letters).toBe(vsRoundStartFields(r1, s, T0).letters);
    expect(s.history![2]!.answers).toEqual(third.fields.answers);
    // Copies: nothing found later changes what the history says.
    r1.molds.c!.bonus.push("ERA");
    expect(s.history![0]!.bins!.c).toEqual([]);
  });

  it("stays small enough for one message with every bonus word of the bank's biggest puzzle in five bins", () => {
    // The size-1 puzzle with the most bonus words: the worst case for a racer's Scrap Bin.
    const biggest = loadBankRows()
      .filter((row) => row.size === 1)
      .map((row) => parseMpPuzzle(JSON.parse(row.data)))
      .reduce((a, b) => (b.bonus.length > a.bonus.length ? b : a));
    const players = ["racer-a", "racer-b", "racer-c", "racer-d", "racer-e"].map((id) => `${id}-0123456789abcdef`);
    const r = round(players, { puzzle: biggest });
    for (const id of players) for (const w of [...biggest.bonus, ...biggest.slots.map((x) => x.word)]) applyVsSubmit(r, id, w);
    expect(r.molds[players[0]!]!.bonus.length).toBeGreaterThan(50);
    // Every round of the longest history goes like that.
    const s = series(players, 10);
    for (let n = 0; n < MAX_HISTORY; n++) endVsRound(s, r, "finished", T0);
    expect(s.history).toHaveLength(MAX_HISTORY);
    const bytes = new TextEncoder().encode(JSON.stringify({ op: "SERIES_END", history: s.history })).length;
    expect(bytes).toBeLessThan(1024 * 1024);
  });

  it("marks sudden death and lists only its racers, a round with no winner included", () => {
    const s = series(["a", "b", "c"]);
    finish(s, "a");
    finish(s, "b");
    expect(finish(s, null).fields.next).toEqual({ round: 4, suddenDeath: true, players: ["a", "b"] });
    finish(s, null, ["a", "b"]);
    expect(finish(s, "b", ["a", "b"]).outcome).toEqual({ winner: "b", early: false, forfeit: false });
    expect(s.history!.map((h) => [h.round, h.suddenDeath, h.winner, h.how])).toEqual([
      [1, false, "a", "timeout"],
      [2, false, "b", "timeout"],
      [3, false, null, "none"],
      [4, true, null, "none"],
      [5, true, "b", "timeout"],
    ]);
    expect(s.history![4]).toMatchObject({
      progress: [
        { id: "a", filled: 0, total: 9 },
        { id: "b", filled: 4, total: 9 },
      ],
      molds: { a: [], b: [0] },
    });
  });

  it("keeps the round a forfeit ended, racers who left included, and adds nothing for one decided between rounds", () => {
    const s = series(["a", "b", "c"], 5);
    finish(s, "c");
    // Round 2: b and c leave mid-round, so a wins it and the series.
    const r2 = round(["a", "b", "c"], { n: 2 });
    applyVsSubmit(r2, "a", "EAT");
    applyVsSubmit(r2, "b", "TEAR");
    markOut(s, "b");
    markOut(s, "c");
    const end = endVsRound(s, r2, "timeout", T0, true);
    expect(end.outcome).toEqual({ winner: "a", early: false, forfeit: true });
    expect(s.history).toHaveLength(2);
    expect(s.history![1]).toEqual({
      round: 2,
      suddenDeath: false,
      reason: "timeout",
      winner: "a",
      how: "timeout",
      ...shape,
      progress: end.fields.progress,
      molds: { a: [1], b: [0], c: [] },
      letters: r2.letters,
      answers,
      bins: { a: [], b: [], c: [] },
    });

    // Decided in the standings: the rounds played, and no more.
    const t = series(["a", "b"]);
    finish(t, "b");
    markOut(t, "b");
    expect(seriesDecision(t)).toMatchObject({ over: true, forfeit: true });
    expect(t.history!.map((h) => h.round)).toEqual([1]);
  });

  it(`keeps the latest ${MAX_HISTORY} rounds`, () => {
    const s = series(["a", "b"]);
    for (let i = 0; i < MAX_HISTORY + 2; i++) finish(s, null);
    expect(s.played).toBe(MAX_HISTORY + 2);
    expect(s.history).toHaveLength(MAX_HISTORY);
    expect([s.history![0]!.round, s.history!.at(-1)!.round]).toEqual([3, MAX_HISTORY + 2]);
  });
});

describe("vsSeriesResults and vsAward", () => {
  it("ranks the podium by wins (equal wins share a place, the winner first) and totals each racer", () => {
    const s = series(["a", "b", "c", "d"]);
    s.racers[0]!.wins = 1;
    s.racers[1]!.wins = 2;
    s.racers[2]!.wins = 2;
    s.racers[2]!.out = true;
    s.played = 6;
    // c left with as many wins as b; b won the series among those still in it.
    const results = vsSeriesResults(s, { winner: "b", early: false, forfeit: false });
    expect(results.rounds).toBe(6);
    expect(results.players.map((p) => [p.id, p.wins, p.place])).toEqual([
      ["b", 2, 1],
      ["c", 2, 1],
      ["a", 1, 3],
      ["d", 0, 4],
    ]);
  });

  it("pays 5 per round raced, 10 per round won and 30 for the series, with rewards, Scrap Bin and embers", () => {
    const s = series(["a", "b"]);
    Object.assign(s.racers[0]!, { wins: 2, rounds: 3, bonus: 4, pickups: { hammer: 1, chisel: 1, sparks: 0 } });
    Object.assign(s.racers[1]!, { wins: 1, rounds: 3, bonus: 0 });
    const [a, b] = vsSeriesResults(s, { winner: "a", early: false, forfeit: false }).players;
    // 15 + 20 + 30 = 65 XP takes a new player from level 1 to 2 (60 XP): +1 Hammer Strike.
    const award = vsAward(a!, true, { totalXp: 0, scrapBin: 8 }, 1);
    expect(award).toMatchObject({ amount: 65, heatBonus: 0, tiersAbove: 0 });
    expect(award.xp).toMatchObject({ level: 2, levelsGained: 1, rewards: { hammer: 1, chisel: 0, sparks: 0 } });
    expect(award.scrap).toEqual({ bin: 2, hammers: 1 });
    expect(award.gained).toEqual({ hammer: 3, chisel: 1, sparks: 0 });
    expect(vsAward(b!, false, { totalXp: 0, scrapBin: 0 }, 1)).toMatchObject({ amount: 25, gained: { hammer: 0, chisel: 0, sparks: 0 } });
  });

  it("pays more at a hotter heat, and most to a newcomer playing up", () => {
    const s = series(["new", "pro"]);
    Object.assign(s.racers[0]!, { wins: 1, rounds: 3 });
    Object.assign(s.racers[1]!, { wins: 2, rounds: 3 });
    const [pro, newcomer] = vsSeriesResults(s, { winner: "pro", early: false, forfeit: false }).players;
    const fresh = { totalXp: 0, scrapBin: 0 };
    const level90 = { totalXp: totalXpForLevel(90), scrapBin: 0 };
    // The newcomer: 15 + 10 = 25 XP at Ember, ×3.0 at White Heat (×2.0, and +0.2 for each of 5 tiers up).
    expect(vsAward(newcomer!, false, fresh, 1)).toMatchObject({ amount: 25, heatBonus: 0, tiersAbove: 0 });
    expect(vsAward(newcomer!, false, fresh, 6)).toMatchObject({ amount: 75, heatBonus: 50, tiersAbove: 5 });
    // The level 90 smith who won: 15 + 20 + 30 = 65, ×2.0 at their own heat, ×1.0 at Ember.
    expect(vsAward(pro!, true, level90, 6)).toMatchObject({ amount: 130, heatBonus: 65, tiersAbove: 0 });
    expect(vsAward(pro!, true, level90, 1)).toMatchObject({ amount: 65, heatBonus: 0, tiersAbove: 0 });
  });
});

describe("a 5-player best of 3 with a timed-out round and sudden death", () => {
  it("plays out end to end", () => {
    const players = ["ali", "sam", "kim", "jo", "max"];
    const s = series(players);
    const end = (r: VsRound, reason: "finished" | "timeout") => endVsRound(s, r, reason, T0);

    // Round 1: ali fills the mold first.
    const r1 = round(players);
    applyVsSubmit(r1, "sam", "EAT");
    for (const w of ["TEAR", "EAT", "RATE"]) applyVsSubmit(r1, "ali", w);
    expect(end(r1, "finished").fields).toMatchObject({ winner: "ali", how: "finished", next: { round: 2, suddenDeath: false } });

    // Round 2: time runs out; sam and kim both have TEAR, sam got there first.
    const r2 = round(players, { n: 2 });
    applyVsSubmit(r2, "sam", "TEAR");
    applyVsSubmit(r2, "kim", "TEAR");
    applyVsSubmit(r2, "jo", "EAT");
    expect(end(r2, "timeout").fields).toMatchObject({ winner: "sam", how: "timeout", next: { round: 3 } });

    // Round 3: nobody forges anything.
    const r3 = round(players, { n: 3 });
    const third = end(r3, "timeout");
    expect(third.fields).toMatchObject({ winner: null, how: "none", tally: { ali: 1, sam: 1, kim: 0, jo: 0, max: 0 } });
    expect(third.fields.next).toEqual({ round: 4, suddenDeath: true, players: ["ali", "sam"] });

    // Sudden death between ali and sam only: sam fills the mold.
    const sd = round(["ali", "sam"], { n: 4, suddenDeath: true });
    expect(applyVsSubmit(sd, "kim", "TEAR")).toEqual({ result: "invalid" });
    for (const w of ["RATE", "EAT", "TEAR"]) applyVsSubmit(sd, "sam", w);
    const last = end(sd, "finished");
    expect(last.outcome).toEqual({ winner: "sam", early: false, forfeit: false });
    expect(last.fields.next).toBeNull();

    const results = vsSeriesResults(s, last.outcome!);
    expect(results.rounds).toBe(4);
    expect(results.players.map((p) => [p.id, p.wins, p.place, p.rounds])).toEqual([
      ["sam", 2, 1, 4],
      ["ali", 1, 2, 4],
      ["kim", 0, 3, 3],
      ["jo", 0, 3, 3],
      ["max", 0, 3, 3],
    ]);
    const xp = Object.fromEntries(results.players.map((p) => [p.id, vsAward(p, results.winner === p.id, { totalXp: 0, scrapBin: 0 }, 1).amount]));
    expect(xp).toEqual({ sam: 70, ali: 30, kim: 15, jo: 15, max: 15 });
  });
});
