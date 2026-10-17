import { describe, expect, it } from "vitest";
import {
  applyEmberCollected,
  applyHint,
  applySubmit,
  coopAward,
  coopResults,
  filledCells,
  hintProblem,
  isComplete,
  newCoopRound,
  roundSnapshot,
  roundStartFields,
  scoresOf,
  type CoopRound,
} from "../../src/rules/coop-round";
import { parseMpPuzzle, type Pos } from "../../src/rules/mold";
import { mulberry32 } from "../../src/rules/pickups";
import { EXAMPLE, playback } from "./fixtures";

const T0 = 1_800_000_000_000;
const puzzle = parseMpPuzzle(EXAMPLE);

/** A round of the example puzzle for players `a` and `b`, with the given embers. */
function round(embers: Pos[] = []): CoopRound {
  // 0.5 ≥ 0.2: no embers from the dice; the test places its own.
  const r = newCoopRound({ round: 1, heat: 1, matchId: "match-1", puzzle, playerIds: ["a", "b"], startsAt: T0, rand: playback(0.5) });
  r.embers = embers;
  return r;
}

describe("newCoopRound", () => {
  it("starts the clock, shuffles the anvil and maybe places embers", () => {
    for (let seed = 0; seed < 50; seed++) {
      const r = newCoopRound({ round: 2, heat: 3, matchId: "m", puzzle, playerIds: ["a"], startsAt: T0, rand: mulberry32(seed) });
      expect(r.endsAt - r.startsAt).toBe(210_000); // Cherry Red: 3:30
      expect([...r.letters].sort().join("")).toBe("AERT");
      expect(["TEAR", "RATE"]).not.toContain(r.letters);
      expect(r.embers.length).toBeLessThanOrEqual(2);
    }
  });

  it("tells clients the mold's shape, never its words", () => {
    const r = round([{ x: 3, y: 3 }]);
    const fields = roundStartFields(r, T0 - 3000);
    expect(fields).toEqual({
      round: 1,
      heat: 1,
      startsAt: T0,
      endsAt: T0 + 180_000,
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
    });
    const text = JSON.stringify({ ...roundSnapshot(r, T0), letters: undefined });
    for (const w of [...EXAMPLE.words.map((w) => w.w), ...EXAMPLE.bonus]) expect(text).not.toContain(w);
  });
});

describe("applySubmit", () => {
  it("gives each word to its first sender, and tells later ones who has it", () => {
    const r = round();
    expect(applySubmit(r, "a", "tear")).toEqual({ result: "claimed", word: "TEAR", slot: 0, points: 40, auto: [], ember: null, complete: false });
    expect(applySubmit(r, "b", "TEAR")).toEqual({ result: "already", word: "TEAR", by: "a" });
    expect(applySubmit(r, "a", "TEAR")).toEqual({ result: "already", word: "TEAR", by: "a" });
    // Letters another player's word filled still score: only hinted ones don't.
    expect(applySubmit(r, "b", "eat")).toMatchObject({ result: "claimed", slot: 1, points: 30 });
    expect(scoresOf(r)).toEqual({ a: 40, b: 30 });
  });

  it("scores a bonus word once per round, for whoever finds it first", () => {
    const r = round();
    expect(applySubmit(r, "b", "tea")).toEqual({ result: "bonus", word: "TEA", points: 9 });
    expect(applySubmit(r, "a", "TEA")).toEqual({ result: "already", word: "TEA", by: "b" });
    expect(scoresOf(r)).toEqual({ a: 0, b: 9 });
  });

  it.each(["rta", "tears", "te", "", "t3a", "tree"])("refuses %j", (word) => {
    const r = round();
    expect(applySubmit(r, "a", word)).toEqual({ result: "invalid" });
    expect(r.claims).toEqual([]);
  });

  it("fills in a crossing slot this claim completed, scoring nothing", () => {
    const r = round();
    // TEAR's own cells by hand, then both crossing words.
    for (const cell of [{ x: 0, y: 0 }, { x: 2, y: 0 }]) expect(applyHint(r, "a", { kind: "chisel", ...cell }, playback(0)).ok).toBe(true);
    expect(applySubmit(r, "b", "EAT")).toMatchObject({ result: "claimed", auto: [], complete: false });
    expect(applySubmit(r, "a", "RATE")).toEqual({
      result: "claimed",
      word: "RATE",
      slot: 2,
      points: 40,
      auto: [{ slot: 0, word: "TEAR" }],
      ember: null,
      complete: true,
    });
    expect(applySubmit(r, "b", "TEAR")).toEqual({ result: "already", word: "TEAR", by: null });
    expect(scoresOf(r)).toEqual({ a: 40, b: 30 });
    expect(isComplete(r)).toBe(true);
  });

  it("takes hinted letters off a word's points", () => {
    const r = round();
    applyHint(r, "a", { kind: "chisel", x: 3, y: 3 }, playback(0));
    applyHint(r, "b", { kind: "chisel", x: 3, y: 1 }, playback(0));
    expect(applySubmit(r, "b", "RATE")).toMatchObject({ points: 20 });
  });
});

describe("embers", () => {
  it("go to whoever forges a word through them", () => {
    const r = round([{ x: 1, y: 0 }]);
    // (1,0) is in both TEAR and EAT; EAT gets there first.
    const out = applySubmit(r, "b", "EAT");
    expect(out).toMatchObject({ result: "claimed", ember: { x: 1, y: 0 } });
    expect(r.embers).toEqual([]);
    applyEmberCollected(r, { x: 1, y: 0 }, "b", "hammer");
    expect(r.collected).toEqual([{ x: 1, y: 0, by: "b", kind: "hammer" }]);
    expect(applySubmit(r, "a", "TEAR")).toMatchObject({ ember: null });
  });

  it("stay on a hinted cell, and are lost if their word fills in by itself", () => {
    const r = round([{ x: 0, y: 0 }]);
    applyHint(r, "a", { kind: "chisel", x: 0, y: 0 }, playback(0));
    expect(roundStartFields(r, T0).pickups).toEqual([{ x: 0, y: 0 }]);
    applyHint(r, "a", { kind: "chisel", x: 2, y: 0 }, playback(0));
    applySubmit(r, "b", "EAT");
    expect(applySubmit(r, "a", "RATE")).toMatchObject({ auto: [{ slot: 0, word: "TEAR" }], ember: null });
    expect(r.embers).toEqual([]);
  });
});

describe("hints", () => {
  it("Chisel needs an empty letter cell", () => {
    const r = round();
    applySubmit(r, "a", "TEAR");
    expect(hintProblem(r, { kind: "chisel", x: 1, y: 0 })).toBe("bad_cell");
    expect(hintProblem(r, { kind: "chisel", x: 0, y: 1 })).toBe("bad_cell");
    expect(hintProblem(r, { kind: "chisel", x: 9, y: 9 })).toBe("bad_cell");
    expect(hintProblem(r, { kind: "chisel", x: 1, y: 1 })).toBeNull();
    expect(applyHint(r, "b", { kind: "chisel", x: 1, y: 0 }, playback(0))).toEqual({ ok: false, code: "bad_cell" });
    expect(applyHint(r, "b", { kind: "chisel", x: 1, y: 1 }, playback(0))).toEqual({
      ok: true,
      cells: [{ x: 1, y: 1, letter: "A" }],
      auto: [],
      complete: false,
    });
    expect(r.hints).toEqual([{ by: "b", kind: "chisel" }]);
  });

  it("Hammer Strike shows one empty cell, and can finish the mold", () => {
    const r = round();
    applySubmit(r, "a", "EAT");
    applySubmit(r, "a", "RATE");
    const first = applyHint(r, "b", { kind: "hammer" }, playback(0));
    expect(first).toEqual({ ok: true, cells: [{ x: 0, y: 0, letter: "T" }], auto: [], complete: false });
    const last = applyHint(r, "b", { kind: "hammer" }, playback(0));
    expect(last).toEqual({ ok: true, cells: [{ x: 2, y: 0, letter: "A" }], auto: [{ slot: 0, word: "TEAR" }], complete: true });
    expect(hintProblem(r, { kind: "hammer" })).toBe("bad_cell");
  });

  it("Spark Shower shows up to 5 empty cells", () => {
    const r = round();
    const out = applyHint(r, "a", { kind: "sparks" }, mulberry32(7));
    expect(out.ok && out.cells.length).toBe(5);
    expect(filledCells(r).size).toBe(5);
    const again = applyHint(r, "a", { kind: "sparks" }, mulberry32(8));
    expect(again.ok && again.cells.length).toBe(4);
    expect(again.ok && again.complete).toBe(true);
    // Every slot filled itself in: nobody scores.
    expect(r.auto.map((s) => s.slot).sort()).toEqual([0, 1, 2]);
    expect(scoresOf(r)).toEqual({ a: 0, b: 0 });
  });
});

describe("coopResults", () => {
  it("gives ★★★ for finishing with half the time left, ★★ for finishing", () => {
    const r = round();
    applySubmit(r, "a", "TEAR");
    applySubmit(r, "b", "EAT");
    applySubmit(r, "b", "RATE");
    expect(coopResults(r, "complete", T0 + 90_000).stars).toBe(3);
    expect(coopResults(r, "complete", T0 + 90_001).stars).toBe(2);
    const results = coopResults(r, "complete", T0 + 60_000);
    expect(results).toEqual({
      reason: "complete",
      teamScore: 110,
      filled: 9,
      total: 9,
      stars: 3,
      players: [
        { id: "a", points: 40, words: 1, longest: "TEAR", bonus: 0 },
        { id: "b", points: 70, words: 2, longest: "RATE", bonus: 0 },
      ],
      mvp: "b",
      answers: [
        { slot: 0, word: "TEAR" },
        { slot: 1, word: "EAT" },
        { slot: 2, word: "RATE" },
      ],
    });
  });

  it("gives ★ on time with 75% filled, otherwise none", () => {
    const r = round();
    applySubmit(r, "a", "TEAR");
    applySubmit(r, "b", "RATE"); // 7 of 9 cells
    expect(coopResults(r, "timeout", T0 + 180_000)).toMatchObject({ stars: 1, filled: 7, total: 9 });
    const s = round();
    applySubmit(s, "a", "RATE"); // 4 of 9
    expect(coopResults(s, "timeout", T0 + 180_000)).toMatchObject({ stars: 0, filled: 4 });
  });

  it("breaks an MVP tie for whoever got there first, counting bonus words", () => {
    const r = round();
    applySubmit(r, "b", "RATE");
    applySubmit(r, "a", "TEAR");
    expect(coopResults(r, "timeout", T0).mvp).toBe("b");
    applySubmit(r, "a", "TEA");
    expect(coopResults(r, "timeout", T0).mvp).toBe("a");
    expect(coopResults(round(), "timeout", T0).mvp).toBeNull();
  });
});

describe("coopAward", () => {
  it("adds co-op XP, level-ups and the Scrap Bin", () => {
    const player = { id: "a", points: 80, words: 2, longest: "RATE", bonus: 2 };
    const award = coopAward(player, { reason: "complete", mvp: "a" }, { totalXp: 10, scrapBin: 9 });
    expect(award.amount).toBe(20 + 8 + 20 + 10);
    expect(award.xp).toMatchObject({ totalXp: 68, level: 2, levelsGained: 1, rewards: { hammer: 1, chisel: 0, sparks: 0 } });
    expect(award.scrap).toEqual({ bin: 1, hammers: 1 });
    expect(coopAward({ ...player, points: 0, bonus: 0 }, { reason: "timeout", mvp: null }, { totalXp: 0, scrapBin: 0 }).amount).toBe(20);
  });
});
