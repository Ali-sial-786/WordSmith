import { describe, expect, it } from "vitest";
import {
  boardBody,
  dayEndsAt,
  GIFT_CLAIM_LIMIT,
  giftsToClaim,
  isoWeek,
  lastWeekResult,
  previousWeek,
  standings,
  STOKE_TRACK,
  stokeView,
  TRIAL_PRIZES,
  weekEndsAt,
  weekStart,
  type BoardData,
  type TrialPlayer,
} from "../../src/rules/board";
import { addDays } from "../../src/rules/daily";
import { totalXpForLevel } from "../../src/rules/progression";

describe("weeks", () => {
  it.each([
    ["2026-10-12", "2026-W42"],
    ["2026-10-17", "2026-W42"],
    ["2026-10-18", "2026-W42"],
    ["2026-10-19", "2026-W43"],
    ["2026-01-01", "2026-W01"],
    ["2025-12-29", "2026-W01"],
    ["2025-12-28", "2025-W52"],
    ["2027-01-01", "2026-W53"],
    ["2027-01-03", "2026-W53"],
    ["2027-01-04", "2027-W01"],
    ["2024-12-30", "2025-W01"],
    ["2021-01-03", "2020-W53"],
  ])("%s is in %s", (date, week) => {
    expect(isoWeek(date)).toBe(week);
  });

  it("start on Monday and end at the next Monday 00:00 UTC", () => {
    expect(weekStart("2026-10-17")).toBe("2026-10-12");
    expect(weekStart("2026-10-12")).toBe("2026-10-12");
    expect(weekStart("2026-10-18")).toBe("2026-10-12");
    expect(weekEndsAt("2026-10-17")).toBe(Date.parse("2026-10-19T00:00:00Z"));
    expect(weekEndsAt("2026-10-18")).toBe(Date.parse("2026-10-19T00:00:00Z"));
    expect(dayEndsAt("2026-10-17")).toBe(Date.parse("2026-10-18T00:00:00Z"));
    expect(previousWeek("2026-10-17")).toBe("2026-W41");
    expect(previousWeek("2026-01-01")).toBe("2025-W52");
  });

  it("are seven days each, every day of a year", () => {
    let week = isoWeek("2025-12-29");
    let days = 0;
    for (let d = 0; d < 800; d++) {
      const w = isoWeek(addDays("2025-12-29", d));
      if (w !== week) {
        expect(days).toBe(7);
        week = w;
        days = 0;
      }
      days++;
    }
  });
});

describe("the Daily Stoke", () => {
  it("has a 7-day track", () => {
    expect(STOKE_TRACK.map((r) => [r.xp, r.hints.hammer, r.hints.chisel, r.hints.sparks])).toEqual([
      [15, 0, 0, 0],
      [0, 1, 0, 0],
      [25, 0, 0, 0],
      [0, 0, 1, 0],
      [35, 0, 0, 0],
      [0, 2, 0, 0],
      [50, 0, 0, 1],
    ]);
  });

  it("takes the next step with each claim, missed days or not, and starts again after day 7", () => {
    const today = "2026-10-17";
    expect(stokeView({ claims: 0, last: null }, today)).toEqual({ day: 1, claimedToday: false });
    expect(stokeView({ claims: 1, last: today }, today)).toEqual({ day: 1, claimedToday: true });
    expect(stokeView({ claims: 3, last: "2026-10-01" }, today)).toEqual({ day: 4, claimedToday: false });
    expect(stokeView({ claims: 7, last: today }, today)).toEqual({ day: 7, claimedToday: true });
    expect(stokeView({ claims: 7, last: "2026-10-16" }, today)).toEqual({ day: 1, claimedToday: false });
    expect(stokeView({ claims: 15, last: "2026-10-16" }, today)).toEqual({ day: 2, claimedToday: false });
  });
});

function player(id: string, username: string, weekXp: number, lastWeekXp: number, totalXp = 0): TrialPlayer {
  return { id, username, avatar: "avatar_01", totalXp, weekXp, lastWeekXp };
}

describe("the Weekly Trials", () => {
  it("rank me and my friends by XP this week, ties by username ignoring case, 0 XP included", () => {
    const players = [player("u1", "zed", 40, 0), player("u2", "Ali", 90, 0, totalXpForLevel(14)), player("u3", "bob", 40, 0), player("u4", "carl", 0, 0)];
    expect(standings(players, "u3")).toEqual([
      { id: "u2", username: "Ali", avatar: "avatar_01", level: 14, xp: 90, me: false },
      { id: "u3", username: "bob", avatar: "avatar_01", level: 1, xp: 40, me: true },
      { id: "u1", username: "zed", avatar: "avatar_01", level: 1, xp: 40, me: false },
      { id: "u4", username: "carl", avatar: "avatar_01", level: 1, xp: 0, me: false },
    ]);
  });

  it("give a prize for the top 3 last week when two or more earned XP", () => {
    const players = [player("a", "a", 0, 300), player("b", "b", 0, 200), player("c", "c", 0, 100), player("d", "d", 0, 50), player("e", "e", 0, 0)];
    expect(lastWeekResult(players, "a")).toEqual({ place: 1, of: 4, reward: TRIAL_PRIZES[0] });
    expect(lastWeekResult(players, "b")).toEqual({ place: 2, of: 4, reward: TRIAL_PRIZES[1] });
    expect(lastWeekResult(players, "c")).toEqual({ place: 3, of: 4, reward: TRIAL_PRIZES[2] });
    expect(lastWeekResult(players, "d")).toEqual({ place: 4, of: 4, reward: null });
    // No XP last week: no result at all.
    expect(lastWeekResult(players, "e")).toBeNull();
    expect(lastWeekResult(players, "nobody")).toBeNull();
    expect(TRIAL_PRIZES.map((r) => [r.xp, r.hints.hammer, r.hints.chisel, r.hints.sparks])).toEqual([
      [100, 0, 0, 1],
      [50, 0, 1, 0],
      [0, 2, 0, 0],
    ]);
  });

  it("give no prize when I was the only one with XP, and share a place on equal XP", () => {
    expect(lastWeekResult([player("a", "a", 0, 300), player("b", "b", 0, 0)], "a")).toEqual({ place: 1, of: 1, reward: null });
    const tied = [player("a", "a", 0, 100), player("b", "b", 0, 100), player("c", "c", 0, 20)];
    expect(lastWeekResult(tied, "b")).toEqual({ place: 1, of: 3, reward: TRIAL_PRIZES[0] });
    expect(lastWeekResult(tied, "c")).toEqual({ place: 3, of: 3, reward: TRIAL_PRIZES[2] });
  });
});

describe("gifts", () => {
  it("collect up to 5 a day", () => {
    expect(GIFT_CLAIM_LIMIT).toBe(5);
    expect(giftsToClaim(0, 0)).toBe(0);
    expect(giftsToClaim(3, 0)).toBe(3);
    expect(giftsToClaim(8, 0)).toBe(5);
    expect(giftsToClaim(8, 4)).toBe(1);
    expect(giftsToClaim(8, 5)).toBe(0);
    expect(giftsToClaim(8, 9)).toBe(0);
  });
});

describe("boardBody", () => {
  const now = Date.parse("2026-10-17T09:00:00Z");
  const data: BoardData = {
    uid: "me",
    now,
    stoke: { claims: 2, last: "2026-10-16" },
    orders: [
      { period: "d:2026-10-17", slot: "d2", kind: "words", target: 30, progress: 12, letter: null, claimed: false },
      { period: "w:2026-W42", slot: "w1", kind: "solo_puzzles", target: 15, progress: 15, letter: null, claimed: true },
    ],
    players: [player("me", "Ali", 120, 300), player("f1", "sam", 340, 100)],
    trialClaimed: false,
    pendingGifts: [{ id: 17, from: { id: "f1", username: "sam", avatar: "avatar_05" }, sentAt: now - 1000 }],
    sentToday: ["f1"],
    claimedToday: 1,
  };

  it("has everything the Forge Hall shows", () => {
    const b = boardBody(data);
    expect(b.date).toBe("2026-10-17");
    expect(b.week).toBe("2026-W42");
    expect(b.stoke).toEqual({ day: 3, claimedToday: false, track: STOKE_TRACK });
    expect(b.orders.daily).toEqual([
      { slot: "d0", kind: "daily", target: 1, progress: 0, letter: null, friends: false, reward: { xp: 20, hints: { hammer: 1, chisel: 0, sparks: 0 } }, claimed: false },
      { slot: "d1", kind: "coop_rounds", target: 1, progress: 0, letter: null, friends: true, reward: { xp: 20, hints: { hammer: 1, chisel: 0, sparks: 0 } }, claimed: false },
      { slot: "d2", kind: "words", target: 30, progress: 12, letter: null, friends: false, reward: { xp: 20, hints: { hammer: 1, chisel: 0, sparks: 0 } }, claimed: false },
    ]);
    expect(b.orders.weekly).toEqual([
      { slot: "w0", kind: "letter_hunt", target: 40, progress: 0, letter: "T", friends: false, reward: { xp: 100, hints: { hammer: 0, chisel: 0, sparks: 1 } }, claimed: false },
      { slot: "w1", kind: "solo_puzzles", target: 15, progress: 15, letter: null, friends: false, reward: { xp: 60, hints: { hammer: 0, chisel: 1, sparks: 0 } }, claimed: true },
    ]);
    expect(b.orders).toMatchObject({
      chest: { reward: { xp: 30, hints: { hammer: 0, chisel: 1, sparks: 0 } }, ready: false, claimed: false },
      swapAvailable: true,
      dailyEndsAt: Date.parse("2026-10-18T00:00:00Z"),
      weeklyEndsAt: Date.parse("2026-10-19T00:00:00Z"),
    });
    expect(b.trials).toEqual({
      week: "2026-W42",
      endsAt: Date.parse("2026-10-19T00:00:00Z"),
      standings: [
        { id: "f1", username: "sam", avatar: "avatar_01", level: 1, xp: 340, me: false },
        { id: "me", username: "Ali", avatar: "avatar_01", level: 1, xp: 120, me: true },
      ],
      lastWeek: { week: "2026-W41", place: 1, of: 2, reward: TRIAL_PRIZES[0], claimed: false },
    });
    expect(b.gifts).toEqual({ pending: data.pendingGifts, sentToday: ["f1"], claimedToday: 1, claimLimit: 5 });
  });

  it("has no last week when I earned nothing then", () => {
    expect(boardBody({ ...data, players: [player("me", "Ali", 0, 0)] }).trials.lastWeek).toBeNull();
  });
});
