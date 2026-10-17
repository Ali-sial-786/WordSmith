import { describe, expect, it } from "vitest";
import { campaignPuzzle } from "../../src/rules/campaign";
import {
  addDays,
  applyDaily,
  checkDaily,
  dailyHeat,
  dailyIndex,
  dailyPuzzleId,
  dailyXp,
  isCompletableDay,
  isDate,
  parseDailyCompletion,
  streakEndingOn,
  streaks,
  utcDate,
  type DailyCompletion,
} from "../../src/rules/daily";
import { fnv1a32 } from "../../src/rules/pickups";
import { totalXpForLevel } from "../../src/rules/progression";
import { CROSSED, EXAMPLE } from "./fixtures";

const at = (iso: string) => Date.parse(iso);
const example = campaignPuzzle(0, EXAMPLE);

function completion(extra: Partial<DailyCompletion> = {}): DailyCompletion {
  return {
    date: "2026-10-17",
    foundWords: ["TEAR", "EAT", "RATE"],
    bonusWords: [],
    hintsUsed: { hammer: 0, chisel: 0, sparks: 0 },
    durationMs: 60_000,
    ...extra,
  };
}

describe("days", () => {
  it("are UTC dates", () => {
    expect(utcDate(at("2026-10-17T23:59:59.999Z"))).toBe("2026-10-17");
    expect(utcDate(at("2026-10-18T00:00:00Z"))).toBe("2026-10-18");
    expect(addDays("2026-12-31", 1)).toBe("2027-01-01");
    expect(addDays("2026-03-01", -1)).toBe("2026-02-28");
    expect(dailyPuzzleId("2026-10-17")).toBe("daily-2026-10-17");
  });

  it.each([
    ["2026-10-17", true],
    ["2028-02-29", true],
    ["2026-02-29", false],
    ["2026-13-01", false],
    ["2026-1-01", false],
    ["2026-10-17T00:00:00Z", false],
    [20261017, false],
    [null, false],
  ])("isDate(%j) is %s", (value, ok) => {
    expect(isDate(value)).toBe(ok);
  });

  it("set the heat by weekday: Monday Ember … Saturday White Heat, Sunday Cherry Red", () => {
    const week = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18"];
    expect(week.map(dailyHeat)).toEqual([1, 2, 3, 4, 5, 6, 3]);
  });

  it("pick the puzzle from the date, the same for everyone", () => {
    expect(dailyIndex("2026-10-17", 40)).toBe(fnv1a32("daily:2026-10-17") % 40);
    const picks = new Set<number>();
    for (let d = 0; d < 60; d++) {
      const i = dailyIndex(addDays("2026-10-01", d), 40);
      expect(i).toBeGreaterThanOrEqual(0);
      expect(i).toBeLessThan(40);
      picks.add(i);
    }
    expect(picks.size).toBeGreaterThan(20);
    expect(() => dailyIndex("2026-10-17", 0)).toThrow(RangeError);
  });

  it("accept today, or yesterday in the first hour of today", () => {
    expect(isCompletableDay("2026-10-17", at("2026-10-17T23:59:00Z"))).toBe(true);
    expect(isCompletableDay("2026-10-16", at("2026-10-17T00:59:59.999Z"))).toBe(true);
    expect(isCompletableDay("2026-10-16", at("2026-10-17T01:00:00Z"))).toBe(false);
    expect(isCompletableDay("2026-10-15", at("2026-10-17T00:10:00Z"))).toBe(false);
    expect(isCompletableDay("2026-10-18", at("2026-10-17T23:59:00Z"))).toBe(false);
  });
});

describe("streaks", () => {
  it("count days in a row ending today, or yesterday while today isn't done", () => {
    expect(streaks([], "2026-10-17")).toEqual({ streak: 0, best: 0 });
    expect(streaks(["2026-10-17"], "2026-10-17")).toEqual({ streak: 1, best: 1 });
    expect(streaks(["2026-10-15", "2026-10-16"], "2026-10-17")).toEqual({ streak: 2, best: 2 });
    expect(streaks(["2026-10-15", "2026-10-16", "2026-10-17"], "2026-10-17")).toEqual({ streak: 3, best: 3 });
    // A missed day breaks it, but the best is kept.
    expect(streaks(["2026-10-14", "2026-10-15"], "2026-10-17")).toEqual({ streak: 0, best: 2 });
    expect(streaks(["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-16", "2026-10-17"], "2026-10-17")).toEqual({ streak: 2, best: 4 });
    // Across a month and a year.
    expect(streaks(["2026-12-30", "2026-12-31", "2027-01-01"], "2027-01-02")).toEqual({ streak: 3, best: 3 });
  });

  it("end on a given day", () => {
    const days = new Set(["2026-10-15", "2026-10-16"]);
    expect(streakEndingOn(days, "2026-10-16")).toBe(2);
    expect(streakEndingOn(days, "2026-10-17")).toBe(0);
  });

  it("pay 25 XP plus 5 per day beyond the first, up to 55", () => {
    expect([0, 1, 2, 3, 6, 7, 8, 100].map(dailyXp)).toEqual([25, 25, 30, 35, 50, 55, 55, 55]);
  });
});

describe("parseDailyCompletion", () => {
  it("reads a completion, with bonus words and hints optional", () => {
    expect(parseDailyCompletion({ date: "2026-10-17", foundWords: ["tear"], durationMs: 5000 })).toEqual({
      ok: true,
      completion: { date: "2026-10-17", foundWords: ["tear"], bonusWords: [], hintsUsed: { hammer: 0, chisel: 0, sparks: 0 }, durationMs: 5000 },
    });
    expect(parseDailyCompletion({ date: "2026-10-17", foundWords: [], bonusWords: ["TEA"], hintsUsed: { chisel: 2 }, durationMs: 0 })).toMatchObject({
      ok: true,
      completion: { hintsUsed: { hammer: 0, chisel: 2, sparks: 0 } },
    });
  });

  it.each([
    [{ foundWords: [], durationMs: 1 }, "date"],
    [{ date: "17/10/2026", foundWords: [], durationMs: 1 }, "date"],
    [{ date: "2026-10-17", durationMs: 1 }, "foundWords"],
    [{ date: "2026-10-17", foundWords: [3], durationMs: 1 }, "foundWords"],
    [{ date: "2026-10-17", foundWords: [], bonusWords: "TEA", durationMs: 1 }, "bonusWords"],
    [{ date: "2026-10-17", foundWords: [], hintsUsed: { hammer: -1 }, durationMs: 1 }, "hintsUsed.hammer"],
    [{ date: "2026-10-17", foundWords: [], hintsUsed: [], durationMs: 1 }, "hintsUsed"],
    [{ date: "2026-10-17", foundWords: [] }, "durationMs"],
    [{ date: "2026-10-17", foundWords: [], durationMs: 1.5 }, "durationMs"],
  ])("refuses %j (%s)", (body, detail) => {
    expect(parseDailyCompletion(body)).toEqual({ ok: false, detail });
  });
});

describe("checkDaily", () => {
  it("accepts every word typed", () => {
    expect(checkDaily(completion(), example)).toBeNull();
    expect(checkDaily(completion({ foundWords: ["tear", "Eat", "RATE", "NOPE"] }), example)).toBeNull();
  });

  it("is incomplete unless the hints used could show the letters no typed word covers", () => {
    // Without RATE, three of its cells (3,1) (3,2) (3,3) are uncovered.
    expect(checkDaily(completion({ foundWords: ["TEAR", "EAT"] }), example)).toBe("incomplete");
    expect(checkDaily(completion({ foundWords: ["TEAR", "EAT"], hintsUsed: { hammer: 2, chisel: 0, sparks: 0 } }), example)).toBe("incomplete");
    expect(checkDaily(completion({ foundWords: ["TEAR", "EAT"], hintsUsed: { hammer: 2, chisel: 1, sparks: 0 } }), example)).toBeNull();
    expect(checkDaily(completion({ foundWords: [], hintsUsed: { hammer: 0, chisel: 0, sparks: 2 } }), example)).toBeNull();
  });

  it("doesn't need a slot that filled in by itself from its crossing words", () => {
    const crossed = campaignPuzzle(0, CROSSED);
    expect(checkDaily(completion({ foundWords: ["ABC", "DEF", "BAF"] }), crossed)).toBeNull();
    expect(checkDaily(completion({ foundWords: ["ABC", "DEF"] }), crossed)).toBe("incomplete");
  });

  it("wants at least 1 s per word typed", () => {
    expect(checkDaily(completion({ durationMs: 2999 }), example)).toBe("too_fast");
    expect(checkDaily(completion({ durationMs: 3000 }), example)).toBeNull();
  });
});

describe("applyDaily", () => {
  const state = { totalXp: 0, scrapBin: 8, hints: { hammer: 1, chisel: 0, sparks: 0 }, wordsForged: 10, longestWord: "ANT" };

  it("pays the streak's XP, fills the Scrap Bin with valid bonus words and takes off the hints used", () => {
    const out = applyDaily(
      state,
      completion({ bonusWords: ["tea", "TEA", "ARE", "XYZ", "TEAR"], hintsUsed: { hammer: 2, chisel: 1, sparks: 0 } }),
      example,
      2,
    );
    expect(out.xp).toBe(30);
    expect(out.award).toMatchObject({ level: 1, levelsGained: 0 });
    // TEA and ARE (TEAR is a grid word, XYZ isn't a word here): 8 + 2 = 10, one Hammer Strike.
    expect(out.scrap).toEqual({ bin: 0, hammers: 1 });
    // Hammers: 1 + 1 smelted - 2 used = 0. The Chisel wasn't there: clamped.
    expect(out.hintsClamped).toEqual({ hammer: 0, chisel: 1, sparks: 0 });
    expect(out.state).toEqual({ totalXp: 30, scrapBin: 0, hints: { hammer: 0, chisel: 0, sparks: 0 }, wordsForged: 13, longestWord: "TEAR" });
  });

  it("gives level-up rewards after the hints are taken", () => {
    const out = applyDaily({ ...state, totalXp: totalXpForLevel(2) - 10 }, completion({ hintsUsed: { hammer: 1, chisel: 0, sparks: 0 } }), example, 7);
    expect(out.xp).toBe(55);
    expect(out.award).toMatchObject({ level: 2, levelsGained: 1, rewards: { hammer: 1, chisel: 0, sparks: 0 } });
    expect(out.state.hints).toEqual({ hammer: 1, chisel: 0, sparks: 0 });
    expect(out.hintsClamped).toBeNull();
  });
});
