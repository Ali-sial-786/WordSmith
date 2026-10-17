import { describe, expect, it } from "vitest";
import {
  HINT_KINDS,
  HINT_UNLOCK_LEVEL,
  type HintCounts,
  RANK_UP_LEVELS,
  STARTING_HINTS,
  addToScrapBin,
  applyXp,
  coopRoundXp,
  isHintUnlocked,
  isRankUpLevel,
  levelFromTotalXp,
  levelProgress,
  levelUpRewards,
  rankForLevel,
  rewardsForReachingLevel,
  soloPuzzleXp,
  totalXpForLevel,
  unlockedHints,
  vsSeriesXp,
  xpToNext,
} from "../../src/rules/progression";

const hints = (hammer: number, chisel: number, sparks: number): HintCounts => ({ hammer, chisel, sparks });

function add(a: HintCounts, b: HintCounts): HintCounts {
  return hints(a.hammer + b.hammer, a.chisel + b.chisel, a.sparks + b.sparks);
}

describe("XP to next level", () => {
  it("is 50 + 10 × level (DESIGN.md examples)", () => {
    expect(xpToNext(1)).toBe(60);
    expect(xpToNext(10)).toBe(150);
    expect(xpToNext(50)).toBe(550);
  });

  it("sums to the lifetime XP for each level", () => {
    expect(totalXpForLevel(1)).toBe(0);
    expect(totalXpForLevel(2)).toBe(60);
    expect(totalXpForLevel(3)).toBe(130);
    expect(totalXpForLevel(11)).toBe(1050);
    let sum = 0;
    for (let level = 1; level <= 300; level++) {
      expect(totalXpForLevel(level)).toBe(sum);
      sum += xpToNext(level);
    }
  });
});

describe("levelFromTotalXp", () => {
  it.each([
    [0, 1],
    [59, 1],
    [60, 2],
    [129, 2],
    [130, 3],
    [1049, 10],
    [1050, 11],
  ])("%i XP is level %i", (xp, level) => {
    expect(levelFromTotalXp(xp)).toBe(level);
  });

  it("treats negative XP as level 1", () => {
    expect(levelFromTotalXp(-10)).toBe(1);
  });

  it("is exact at every level boundary", () => {
    for (let level = 2; level <= 300; level++) {
      expect(levelFromTotalXp(totalXpForLevel(level))).toBe(level);
      expect(levelFromTotalXp(totalXpForLevel(level) - 1)).toBe(level - 1);
    }
  });

  it("reports progress through the current level", () => {
    expect(levelProgress(0)).toEqual({ level: 1, xpIntoLevel: 0, xpForLevel: 60 });
    expect(levelProgress(100)).toEqual({ level: 2, xpIntoLevel: 40, xpForLevel: 70 });
    expect(levelProgress(1050)).toEqual({ level: 11, xpIntoLevel: 0, xpForLevel: 160 });
  });
});

describe("ranks", () => {
  it.each([
    [1, "Apprentice"],
    [9, "Apprentice"],
    [10, "Journeyman"],
    [24, "Journeyman"],
    [25, "Smith"],
    [49, "Smith"],
    [50, "Master Smith"],
    [79, "Master Smith"],
    [80, "Grandmaster"],
    [119, "Grandmaster"],
    [120, "Legend"],
    [999, "Legend"],
  ])("level %i is %s", (level, name) => {
    expect(rankForLevel(level).name).toBe(name);
  });

  it("ranks up at 10, 25, 50, 80 and 120", () => {
    expect(RANK_UP_LEVELS).toEqual([10, 25, 50, 80, 120]);
    expect(isRankUpLevel(25)).toBe(true);
    expect(isRankUpLevel(1)).toBe(false);
    expect(isRankUpLevel(30)).toBe(false);
  });
});

describe("hint unlocks", () => {
  it("unlocks Hammer at 1, Chisel at 5, Spark Shower at 12", () => {
    expect(HINT_UNLOCK_LEVEL).toEqual({ hammer: 1, chisel: 5, sparks: 12 });
    expect(isHintUnlocked("chisel", 4)).toBe(false);
    expect(isHintUnlocked("chisel", 5)).toBe(true);
    expect(isHintUnlocked("sparks", 11)).toBe(false);
    expect(isHintUnlocked("sparks", 12)).toBe(true);
    expect(unlockedHints(1)).toEqual(["hammer"]);
    expect(unlockedHints(5)).toEqual(["hammer", "chisel"]);
    expect(unlockedHints(12)).toEqual(["hammer", "chisel", "sparks"]);
  });

  it("starts players with 3 Hammer Strikes", () => {
    expect(STARTING_HINTS).toEqual(hints(3, 0, 0));
  });
});

describe("level-up rewards (DESIGN.md §3.2)", () => {
  it.each<[number, HintCounts]>([
    [1, hints(0, 0, 0)], // nobody "reaches" level 1
    [2, hints(1, 0, 0)],
    [4, hints(1, 0, 0)],
    [5, hints(1, 1, 0)], // Chisel unlocks at 5, and 5 is a 5th level
    [10, hints(2, 2, 0)], // rank-up bundle of the unlocked types; Spark Shower isn't unlocked yet
    [12, hints(1, 0, 0)], // Spark Shower unlocks, but 12 isn't a 10th level
    [15, hints(1, 1, 0)],
    [20, hints(1, 1, 1)], // first Spark Shower from levelling
    [25, hints(2, 2, 1)], // rank-up bundle now includes Spark Shower
    [30, hints(1, 1, 1)],
    [50, hints(2, 2, 2)],
    [80, hints(2, 2, 2)],
    [120, hints(2, 2, 2)],
    [121, hints(1, 0, 0)],
  ])("reaching level %i gives %o", (level, expected) => {
    expect(rewardsForReachingLevel(level)).toEqual(expected);
  });

  it("adds up every level crossed in one jump", () => {
    expect(levelUpRewards(1, 2)).toEqual(hints(1, 0, 0));
    expect(levelUpRewards(9, 11)).toEqual(hints(3, 2, 0));
    expect(levelUpRewards(1, 10)).toEqual(hints(10, 3, 0));
    expect(levelUpRewards(1, 25)).toEqual(hints(26, 7, 2));
  });

  it("gives nothing without a level-up", () => {
    expect(levelUpRewards(5, 5)).toEqual(hints(0, 0, 0));
    expect(levelUpRewards(10, 3)).toEqual(hints(0, 0, 0));
  });

  it("is the same whether you level in one jump or several", () => {
    for (const [a, b, c] of [
      [1, 7, 30],
      [3, 12, 13],
      [9, 10, 26],
      [40, 81, 125],
    ] as const) {
      expect(add(levelUpRewards(a, b), levelUpRewards(b, c))).toEqual(levelUpRewards(a, c));
    }
  });

  it("never grants a locked hint type", () => {
    for (let level = 1; level <= 150; level++) {
      const r = rewardsForReachingLevel(level);
      for (const kind of HINT_KINDS) if (!isHintUnlocked(kind, level)) expect(r[kind]).toBe(0);
    }
  });
});

describe("applyXp", () => {
  it("handles XP without a level-up", () => {
    const a = applyXp(0, 59);
    expect(a).toMatchObject({ previousTotalXp: 0, totalXp: 59, previousLevel: 1, level: 1, levelsGained: 0, rankChanged: false });
    expect(a.rewards).toEqual(hints(0, 0, 0));
  });

  it("handles one level-up", () => {
    const a = applyXp(0, 60);
    expect(a).toMatchObject({ level: 2, levelsGained: 1 });
    expect(a.rewards).toEqual(hints(1, 0, 0));
  });

  it("handles several level-ups at once", () => {
    const a = applyXp(50, 100);
    expect(a).toMatchObject({ totalXp: 150, previousLevel: 1, level: 3, levelsGained: 2 });
    expect(a.rewards).toEqual(hints(2, 0, 0));
  });

  it("flags a rank-up", () => {
    const a = applyXp(totalXpForLevel(10) - 1, 1);
    expect(a.level).toBe(10);
    expect(a.rank.name).toBe("Journeyman");
    expect(a.rankChanged).toBe(true);
    expect(a.rewards).toEqual(hints(2, 2, 0));
  });

  it("only accepts a non-negative whole amount", () => {
    expect(() => applyXp(0, -1)).toThrow(RangeError);
    expect(() => applyXp(0, 1.5)).toThrow(RangeError);
    expect(applyXp(100, 0).levelsGained).toBe(0);
  });
});

describe("XP per mode (DESIGN.md §4.2)", () => {
  it("solo: 10, plus 1 per bonus word up to +5", () => {
    expect(soloPuzzleXp(0)).toBe(10);
    expect(soloPuzzleXp(3)).toBe(13);
    expect(soloPuzzleXp(5)).toBe(15);
    expect(soloPuzzleXp(12)).toBe(15);
  });

  it("co-op: 20, +1 per 10 points, +20 for filling the mold, +10 for MVP", () => {
    expect(coopRoundXp({ points: 0, teamFilledMold: false, isMvp: false })).toBe(20);
    expect(coopRoundXp({ points: 9, teamFilledMold: false, isMvp: false })).toBe(20);
    expect(coopRoundXp({ points: 60, teamFilledMold: true, isMvp: false })).toBe(46);
    expect(coopRoundXp({ points: 125, teamFilledMold: true, isMvp: true })).toBe(62);
  });

  it("versus: 5 per round played, +10 per round won, +30 for the series", () => {
    expect(vsSeriesXp({ roundsPlayed: 5, roundsWon: 0, wonSeries: false })).toBe(25);
    expect(vsSeriesXp({ roundsPlayed: 3, roundsWon: 2, wonSeries: true })).toBe(65);
  });
});

describe("Scrap Bin", () => {
  it("smelts every 10 bonus words into a Hammer Strike and carries the rest", () => {
    expect(addToScrapBin(0, 0)).toEqual({ bin: 0, hammers: 0 });
    expect(addToScrapBin(7, 2)).toEqual({ bin: 9, hammers: 0 });
    expect(addToScrapBin(7, 3)).toEqual({ bin: 0, hammers: 1 });
    expect(addToScrapBin(9, 25)).toEqual({ bin: 4, hammers: 3 });
  });
});
