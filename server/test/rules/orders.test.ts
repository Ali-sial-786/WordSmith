import { describe, expect, it } from "vitest";
import {
  addFacts,
  advance,
  chestReady,
  DAILY_POOL,
  DAILY_SLOTS,
  dailyKinds,
  dailyOrder,
  dailyOrders,
  FRIENDS_KINDS,
  HUNT_LETTERS,
  isDailySlot,
  isOrderSlot,
  orderCounts,
  orderReward,
  ordersState,
  swapAvailable,
  swapKind,
  weeklyLetter,
  weeklyOrders,
  type OrderKind,
  type OrderRow,
} from "../../src/rules/orders";
import { fnv1a32, mulberry32 } from "../../src/rules/pickups";
import { addDays } from "../../src/rules/daily";
import { playback } from "./fixtures";

// Also listed in shared/forge-board.md ("Test vectors"), for the app.
describe("choosing the orders", () => {
  it.each<[string, OrderKind[]]>([
    ["2026-10-12", ["daily", "no_hints", "long_words"]],
    ["2026-10-17", ["daily", "coop_rounds", "words"]],
    ["2026-10-18", ["bonus_words", "no_hints", "long_words"]],
    ["2026-10-19", ["solo_puzzles", "bonus_words", "words"]],
    ["2026-11-01", ["vs_series", "bonus_words", "solo_puzzles"]],
  ])("the daily orders on %s", (date, kinds) => {
    expect(dailyKinds(date)).toEqual(kinds);
  });

  it("skips a second friends kind", () => {
    // The shuffle puts solo_puzzles, coop_rounds, vs_series first on 2026-10-01.
    expect(dailyKinds("2026-10-01")).toEqual(["solo_puzzles", "coop_rounds", "long_words"]);
    for (let d = 0; d < 400; d++) {
      const kinds = dailyKinds(addDays("2026-01-01", d));
      expect(kinds).toHaveLength(3);
      expect(new Set(kinds).size).toBe(3);
      expect(kinds.filter((k) => FRIENDS_KINDS.has(k)).length).toBeLessThanOrEqual(1);
      for (const k of kinds) expect(DAILY_POOL).toContain(k);
    }
  });

  it("is a Fisher–Yates shuffle of the pool with the day's seed", () => {
    const rand = mulberry32(fnv1a32("orders:2026-10-17"));
    const pool = [...DAILY_POOL];
    for (let i = pool.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [pool[i], pool[j]] = [pool[j]!, pool[i]!];
    }
    expect(pool.slice(0, 3)).toEqual(dailyKinds("2026-10-17"));
  });

  it("gives each daily kind its target", () => {
    expect(dailyOrders("2026-10-17")).toEqual([
      { slot: "d0", kind: "daily", target: 1, letter: null },
      { slot: "d1", kind: "coop_rounds", target: 1, letter: null },
      { slot: "d2", kind: "words", target: 40, letter: null },
    ]);
    expect(["solo_puzzles", "bonus_words", "words", "long_words", "daily", "no_hints"].map((k) => dailyOrder("d0", k as OrderKind).target)).toEqual([
      3, 10, 40, 3, 1, 1,
    ]);
  });

  it.each([
    ["2026-W41", "M"],
    ["2026-W42", "T"],
    ["2026-W01", "K"],
    ["2027-W01", "S"],
  ])("the letter hunt in %s is %s", (week, letter) => {
    expect(weeklyLetter(week)).toBe(letter);
    expect(weeklyLetter(week)).toBe(HUNT_LETTERS[fnv1a32(`letter:${week}`) % 16]);
  });

  it("has a letter hunt and 15 campaign puzzles every week", () => {
    expect(weeklyOrders("2026-W42")).toEqual([
      { slot: "w0", kind: "letter_hunt", target: 40, letter: "T" },
      { slot: "w1", kind: "solo_puzzles", target: 15, letter: null },
    ]);
  });

  it("knows its slots", () => {
    expect(DAILY_SLOTS.every(isDailySlot)).toBe(true);
    expect(["w0", "w1", "d0"].every(isOrderSlot)).toBe(true);
    for (const bad of ["d3", "w2", "chest", "swap", "", 0, null]) expect(isOrderSlot(bad)).toBe(false);
    expect(isDailySlot("w0")).toBe(false);
  });
});

describe("swapKind", () => {
  it("picks a pool kind that isn't one of today's", () => {
    const today: OrderKind[] = ["daily", "no_hints", "long_words"];
    // Candidates in pool order: solo_puzzles, bonus_words, words, coop_rounds, vs_series.
    expect(swapKind(today, 1, playback(0))).toBe("solo_puzzles");
    expect(swapKind(today, 1, playback(0.99))).toBe("vs_series");
    for (let i = 0; i < 200; i++) {
      const kind = swapKind(today, i % 3, Math.random);
      expect(today).not.toContain(kind);
    }
  });

  it("never makes a second friends kind", () => {
    const today: OrderKind[] = ["daily", "coop_rounds", "words"];
    for (let i = 0; i < 200; i++) expect(FRIENDS_KINDS.has(swapKind(today, 0, Math.random))).toBe(false);
    // Replacing the friends kind itself may bring the other one.
    const kinds = new Set(Array.from({ length: 300 }, () => swapKind(today, 1, Math.random)));
    expect(kinds).toContain("vs_series");
    expect(kinds).not.toContain("coop_rounds");
  });
});

describe("rewards", () => {
  it("pays each order as configured", () => {
    expect(orderReward("d1")).toEqual({ xp: 20, hints: { hammer: 1, chisel: 0, sparks: 0 } });
    expect(orderReward("w0")).toEqual({ xp: 100, hints: { hammer: 0, chisel: 0, sparks: 1 } });
    expect(orderReward("w1")).toEqual({ xp: 60, hints: { hammer: 0, chisel: 1, sparks: 0 } });
  });
});

describe("orderCounts", () => {
  it("turns facts about a play into counts, leaving out kinds it doesn't help", () => {
    const counts = orderCounts(
      { soloPuzzles: 2, noHintPuzzles: 1, bonusWords: 4, forged: ["TEAR", "THREAD", "STREAM", "ANVIL", "FORGES"] },
      "T",
    );
    expect(counts).toEqual({ solo_puzzles: 2, no_hints: 1, bonus_words: 4, words: 5, long_words: 3, letter_hunt: 3 });
    expect(orderCounts({ dailies: 1, forged: ["EAT"] }, "Q")).toEqual({ daily: 1, words: 1 });
    expect(orderCounts({ coopRounds: 1 }, "T")).toEqual({ coop_rounds: 1 });
    expect(orderCounts({ vsSeries: 1, bonusWords: 0 }, "T")).toEqual({ vs_series: 1 });
    expect(orderCounts({}, "T")).toEqual({});
  });

  it("adds facts together", () => {
    const sum = addFacts({ soloPuzzles: 1, forged: ["A"] }, { soloPuzzles: 2, bonusWords: 3, forged: ["B"] });
    expect(sum).toMatchObject({ soloPuzzles: 3, bonusWords: 3, forged: ["A", "B"], dailies: 0 });
  });

  it("stops progress at the target", () => {
    expect(advance({ kind: "words", target: 40 }, 35, { words: 4 })).toBe(39);
    expect(advance({ kind: "words", target: 40 }, 35, { words: 9 })).toBe(40);
    expect(advance({ kind: "daily", target: 1 }, 0, { words: 9 })).toBe(0);
  });
});

describe("ordersState", () => {
  const row = (slot: string, extra: Partial<OrderRow> = {}): OrderRow => ({
    period: "d:2026-10-17",
    slot,
    kind: "words",
    target: 30,
    progress: 0,
    letter: null,
    claimed: false,
    ...extra,
  });

  it("fills in the configured orders where there are no rows", () => {
    const s = ordersState("2026-10-17", "2026-W42", []);
    expect(s.daily.map((o) => [o.slot, o.kind, o.progress, o.claimed])).toEqual([
      ["d0", "daily", 0, false],
      ["d1", "coop_rounds", 0, false],
      ["d2", "words", 0, false],
    ]);
    expect(s.weekly.map((o) => [o.slot, o.kind, o.letter])).toEqual([
      ["w0", "letter_hunt", "T"],
      ["w1", "solo_puzzles", null],
    ]);
    expect(s).toMatchObject({ swapUsed: false, chestClaimed: false });
    expect(chestReady(s)).toBe(false);
    expect(swapAvailable(s)).toBe(true);
  });

  it("reads progress, claims, a swapped kind, the swap and the chest from rows", () => {
    const rows = [
      row("d0", { kind: "daily", target: 1, progress: 1, claimed: true }),
      row("d1", { kind: "bonus_words", target: 10, progress: 4 }),
      row("d2", { progress: 30, claimed: true }),
      row("swap", { kind: "d1", target: 0 }),
      { ...row("w0", { kind: "letter_hunt", target: 40, progress: 12, letter: "T" }), period: "w:2026-W42" },
      // Another day's rows don't count.
      { ...row("d1", { progress: 30 }), period: "d:2026-10-16" },
    ];
    const s = ordersState("2026-10-17", "2026-W42", rows);
    expect(s.daily.map((o) => [o.kind, o.progress, o.claimed])).toEqual([
      ["daily", 1, true],
      ["bonus_words", 4, false],
      ["words", 30, true],
    ]);
    expect(s.weekly[0]).toMatchObject({ kind: "letter_hunt", progress: 12, letter: "T" });
    expect(s.swapUsed).toBe(true);
    expect(swapAvailable(s)).toBe(false);
    expect(chestReady(s)).toBe(false);

    const all = ordersState("2026-10-17", "2026-W42", [...rows.slice(0, 3).map((r) => ({ ...r, claimed: true })), row("chest", { claimed: true })]);
    expect(chestReady(all)).toBe(true);
    expect(all.chestClaimed).toBe(true);
  });

  it("has no swap to offer once every daily order is finished or claimed", () => {
    const s = ordersState("2026-10-17", "2026-W42", [
      row("d0", { kind: "daily", target: 1, progress: 1 }),
      row("d1", { kind: "coop_rounds", target: 1, claimed: true, progress: 1 }),
      row("d2", { progress: 30 }),
    ]);
    expect(swapAvailable(s)).toBe(false);
  });
});
