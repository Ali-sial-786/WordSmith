import { describe, expect, it } from "vitest";
import { totalXpForLevel } from "../../src/rules/progression";
import { addRewards, asGranted, grantReward, isEmptyReward, NO_REWARD, reward } from "../../src/rules/rewards";

describe("rewards", () => {
  it("always have every field", () => {
    expect(reward(15)).toEqual({ xp: 15, hints: { hammer: 0, chisel: 0, sparks: 0 } });
    expect(reward(0, { sparks: 1 })).toEqual({ xp: 0, hints: { hammer: 0, chisel: 0, sparks: 1 } });
    expect(isEmptyReward(NO_REWARD)).toBe(true);
    expect(isEmptyReward(reward(0, { hammer: 1 }))).toBe(false);
    expect(addRewards(reward(10, { hammer: 1 }), reward(5, { hammer: 2, sparks: 1 }))).toEqual({ xp: 15, hints: { hammer: 3, chisel: 0, sparks: 1 } });
  });

  it("give locked hint types as the same number of Hammer Strikes", () => {
    const r = reward(100, { hammer: 1, chisel: 2, sparks: 1 });
    expect(asGranted(r, 1)).toEqual({ xp: 100, hints: { hammer: 4, chisel: 0, sparks: 0 } });
    expect(asGranted(r, 5)).toEqual({ xp: 100, hints: { hammer: 2, chisel: 2, sparks: 0 } });
    expect(asGranted(r, 12)).toEqual(r);
  });

  it("judge the lock at the level before their XP", () => {
    // 100 XP takes a player from just below level 12 to past it; the Spark Shower is still a Hammer Strike.
    const g = grantReward(totalXpForLevel(12) - 1, reward(100, { sparks: 1 }));
    expect(g.granted).toEqual({ xp: 100, hints: { hammer: 1, chisel: 0, sparks: 0 } });
    expect(g.award).toMatchObject({ previousLevel: 11, level: 12, levelsGained: 1 });
    // Level 12's own reward (1 Hammer Strike) comes on top.
    expect(g.gained).toEqual({ hammer: 2, chisel: 0, sparks: 0 });
  });

  it("add the XP with level-ups and their rewards", () => {
    const g = grantReward(0, reward(15));
    expect(g.award).toMatchObject({ totalXp: 15, level: 1, levelsGained: 0 });
    expect(g.gained).toEqual({ hammer: 0, chisel: 0, sparks: 0 });
    const up = grantReward(totalXpForLevel(5) - 10, reward(30, { chisel: 1 }));
    expect(up.granted.hints).toEqual({ hammer: 1, chisel: 0, sparks: 0 });
    // Reaching level 5: a Hammer Strike and (now unlocked) a Chisel.
    expect(up.gained).toEqual({ hammer: 2, chisel: 1, sparks: 0 });
  });
});
