import { describe, expect, it } from "vitest";
import {
  HEAT_TIERS,
  type HeatTier,
  chosenHeat,
  coopTimerMs,
  isHeatChoice,
  isHeatTier,
  heatForLevel,
  heatInfo,
  heatName,
  medianLevel,
  vsHeat,
  vsRoundTimerMs,
} from "../../src/rules/heat";

describe("heatForLevel", () => {
  it.each([
    [1, 1],
    [5, 1],
    [6, 2],
    [15, 2],
    [16, 3],
    [30, 3],
    [31, 4],
    [50, 4],
    [51, 5],
    [80, 5],
    [81, 6],
    [500, 6],
  ])("level %i is heat %i", (level, tier) => {
    expect(heatForLevel(level)).toBe(tier);
  });

  it("treats levels below 1 as level 1", () => {
    expect(heatForLevel(0)).toBe(1);
  });

  it("covers every level from 1 to 200 with no gaps", () => {
    let previous = 1;
    for (let level = 1; level <= 200; level++) {
      const tier = heatForLevel(level);
      expect(tier === previous || tier === previous + 1).toBe(true);
      const info = heatInfo(tier);
      expect(level).toBeGreaterThanOrEqual(info.minLevel);
      if (info.maxLevel !== null) expect(level).toBeLessThanOrEqual(info.maxLevel);
      previous = tier;
    }
  });
});

describe("tier details (DESIGN.md §5)", () => {
  it("names the tiers", () => {
    expect(([1, 2, 3, 4, 5, 6] as HeatTier[]).map(heatName)).toEqual([
      "Ember",
      "Dull Red",
      "Cherry Red",
      "Orange",
      "Yellow",
      "White Heat",
    ]);
  });

  it("sets the co-op timer", () => {
    expect(([1, 2, 3, 4, 5, 6] as HeatTier[]).map(coopTimerMs)).toEqual([
      180_000, 210_000, 270_000, 270_000, 300_000, 300_000,
    ]);
  });

  it("sets the versus round timer", () => {
    expect(([1, 2, 3, 4, 5, 6] as HeatTier[]).map(vsRoundTimerMs)).toEqual([
      120_000, 150_000, 210_000, 210_000, 240_000, 240_000,
    ]);
  });

  it("has contiguous level ranges", () => {
    for (let i = 1; i < HEAT_TIERS.length; i++) {
      expect(HEAT_TIERS[i]!.minLevel).toBe(HEAT_TIERS[i - 1]!.maxLevel! + 1);
    }
    expect(HEAT_TIERS.at(-1)!.maxLevel).toBeNull();
  });

  it("rejects unknown tiers", () => {
    expect(() => heatInfo(7 as HeatTier)).toThrow(RangeError);
  });
});

describe("medianLevel", () => {
  it("takes the middle level of an odd-sized room", () => {
    expect(medianLevel([7])).toBe(7);
    expect(medianLevel([80, 1, 3])).toBe(3);
    expect(medianLevel([10, 50, 20, 90, 5])).toBe(20);
  });

  it("averages the two middle levels of an even-sized room, rounding down", () => {
    expect(medianLevel([10, 20])).toBe(15);
    expect(medianLevel([5, 6])).toBe(5);
    expect(medianLevel([100, 1, 3, 2])).toBe(2);
  });

  it("doesn't reorder the caller's array", () => {
    const levels = [30, 10, 20];
    medianLevel(levels);
    expect(levels).toEqual([30, 10, 20]);
  });

  it("needs at least one level", () => {
    expect(() => medianLevel([])).toThrow(RangeError);
  });
});

describe("vsHeat", () => {
  it("uses the median level", () => {
    expect(vsHeat([1, 50, 90])).toBe(4);
    expect(vsHeat([5, 6])).toBe(1);
    expect(vsHeat([1, 1, 81, 81, 81])).toBe(6);
  });
});

describe("the host's heat (CONFIG)", () => {
  it("is a tier from 1 to 6, or auto", () => {
    for (const ok of [1, 2, 3, 4, 5, 6, "auto"]) expect(isHeatChoice(ok)).toBe(true);
    for (const bad of [0, 7, 2.5, "3", "Auto", null, undefined, true, {}]) expect(isHeatChoice(bad)).toBe(false);
    expect(isHeatTier("auto")).toBe(false);
  });

  it("plays the tier picked, or what auto gives", () => {
    expect(chosenHeat("auto", 2)).toBe(2);
    expect(chosenHeat(5, 2)).toBe(5);
    expect(chosenHeat(1, 6)).toBe(1);
  });
});
