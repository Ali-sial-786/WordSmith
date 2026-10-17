import { describe, expect, it } from "vitest";
import { campaignPuzzle, type CampaignPuzzle } from "../../src/rules/campaign";
import { pickupsFor } from "../../src/rules/pickups";
import { noHints, totalXpForLevel } from "../../src/rules/progression";
import {
  checkEntry,
  checkPickups,
  evaluateSync,
  MAX_INSTALL_SEEDS,
  MIN_MS_PER_FOUND_WORD,
  parseSyncEntry,
  type SoloState,
  type SyncEntry,
} from "../../src/rules/sync";

const NOW = Date.UTC(2026, 9, 17, 12);

/**
 * A puzzle for `stage` with `words` three-letter words laid out on separate
 * rows, so it has 3 × words cells. Word i is the letter i repeated ("AAA", "BBB", …).
 */
function synthetic(stage: number, words: number, bonus: string[] = ["XYZ", "ZYX", "YZX"]): CampaignPuzzle {
  return campaignPuzzle(stage, {
    id: `c-${String(stage).padStart(4, "0")}`,
    letters: "ABC",
    words: Array.from({ length: words }, (_, i) => ({ w: String.fromCharCode(65 + i).repeat(3), x: 0, y: 2 * i, d: "a" })),
    bonus,
  });
}

function gridWords(p: CampaignPuzzle): string[] {
  return [...p.gridWords];
}

function entry(p: CampaignPuzzle, overrides: Partial<SyncEntry> = {}): SyncEntry {
  return {
    stage: p.stage,
    puzzleId: p.id,
    foundWords: gridWords(p),
    bonusWords: [],
    hintsUsed: noHints(),
    pickups: [],
    pickupSeed: null,
    durationMs: 60_000,
    completedAt: NOW - 3600_000 + p.stage,
    ...overrides,
  };
}

function state(overrides: Partial<SoloState> = {}): SoloState {
  return {
    totalXp: 0,
    scrapBin: 0,
    hints: { hammer: 3, chisel: 0, sparks: 0 },
    campaignCompleted: 0,
    wordsForged: 0,
    longestWord: "",
    soloDone: 0,
    masterworkPieces: 0,
    completedStages: new Set(),
    installSeeds: new Set(),
    ...overrides,
  };
}

function puzzles(...ps: CampaignPuzzle[]): Map<number, CampaignPuzzle> {
  return new Map(ps.map((p) => [p.stage, p]));
}

describe("parseSyncEntry", () => {
  const raw = {
    stage: 3,
    puzzleId: "c-0003",
    foundWords: ["AAA"],
    bonusWords: ["XYZ"],
    hintsUsed: { hammer: 1, sparks: 2, turn: 9 },
    pickups: [{ cell: 2, kind: "chisel" }],
    pickupSeed: "install-0123456789abcdef0123456789abcdef",
    durationMs: 1234,
    completedAt: NOW,
  };

  it("reads the app's queue entry", () => {
    expect(parseSyncEntry(raw)).toEqual({
      ok: true,
      entry: { ...raw, hintsUsed: { hammer: 1, chisel: 0, sparks: 2 }, pickups: [{ cell: 2, kind: "chisel" }] },
    });
  });

  it("defaults the optional fields", () => {
    const { bonusWords: _b, hintsUsed: _h, pickups: _p, pickupSeed: _s, ...bare } = raw;
    expect(parseSyncEntry(bare)).toMatchObject({
      ok: true,
      entry: { bonusWords: [], hintsUsed: noHints(), pickups: [], pickupSeed: null },
    });
  });

  it("also takes TECH.md's pickupsCollected", () => {
    const { pickups, ...rest } = raw;
    expect(parseSyncEntry({ ...rest, pickupsCollected: pickups })).toMatchObject({ ok: true, entry: { pickups } });
  });

  it.each<[string, unknown, number | null]>([
    ["stage", { ...raw, stage: 0 }, null],
    ["stage", { ...raw, stage: 1.5 }, null],
    ["puzzleId", { ...raw, puzzleId: 3 }, 3],
    ["foundWords", { ...raw, foundWords: "AAA" }, 3],
    ["foundWords", { ...raw, foundWords: ["A".repeat(17)] }, 3],
    ["foundWords", { ...raw, foundWords: Array(65).fill("AAA") }, 3],
    ["bonusWords", { ...raw, bonusWords: [1] }, 3],
    ["hintsUsed", { ...raw, hintsUsed: [1] }, 3],
    ["hintsUsed.hammer", { ...raw, hintsUsed: { hammer: -1 } }, 3],
    ["hintsUsed.chisel", { ...raw, hintsUsed: { chisel: 0.5 } }, 3],
    ["pickups", { ...raw, pickups: [{ cell: -1, kind: "hammer" }] }, 3],
    ["pickups", { ...raw, pickups: [{ cell: 1, kind: "turn" }] }, 3],
    ["pickups", { ...raw, pickups: Array(9).fill({ cell: 1, kind: "hammer" }) }, 3],
    ["pickupSeed", { ...raw, pickupSeed: "" }, 3],
    ["durationMs", { ...raw, durationMs: -1 }, 3],
    ["completedAt", { ...raw, completedAt: "today" }, 3],
  ])("refuses a bad %s", (detail, input, stage) => {
    expect(parseSyncEntry(input)).toEqual({ ok: false, stage, detail });
  });
});

describe("checkEntry", () => {
  const p = synthetic(5, 4); // 12 cells
  const none = new Set<number>();

  it("accepts a fully typed puzzle", () => {
    expect(checkEntry(entry(p), p, none, NOW)).toBeNull();
  });

  it("knows the stage and its puzzle", () => {
    expect(checkEntry(entry(p), undefined, none, NOW)).toBe("unknown_stage");
    expect(checkEntry(entry(p, { puzzleId: "c-0006" }), p, none, NOW)).toBe("puzzle_mismatch");
    expect(checkEntry(entry(p), p, new Set([5]), NOW)).toBe("duplicate");
  });

  it("checks completedAt is plausible", () => {
    expect(checkEntry(entry(p, { completedAt: NOW + 9 * 60_000 }), p, none, NOW)).toBeNull();
    expect(checkEntry(entry(p, { completedAt: NOW + 11 * 60_000 }), p, none, NOW)).toBe("bad_completed_at");
    expect(checkEntry(entry(p, { completedAt: Date.UTC(2025, 11, 31) }), p, none, NOW)).toBe("bad_completed_at");
  });

  it("only accepts the puzzle's own words", () => {
    expect(checkEntry(entry(p, { foundWords: ["aaa", "BBB", "CCC", "DDD"] }), p, none, NOW)).toBeNull();
    expect(checkEntry(entry(p, { foundWords: [...gridWords(p), "EEE"] }), p, none, NOW)).toBe("unknown_word");
    expect(checkEntry(entry(p, { foundWords: ["A A A"] }), p, none, NOW)).toBe("unknown_word");
    expect(checkEntry(entry(p, { bonusWords: ["XYZ"] }), p, none, NOW)).toBeNull();
    expect(checkEntry(entry(p, { bonusWords: ["AAA"] }), p, none, NOW)).toBe("unknown_bonus_word");
  });

  it("needs hints to explain every cell no typed word covers", () => {
    const typed = ["AAA", "BBB", "CCC"]; // DDD's 3 cells left
    expect(checkEntry(entry(p, { foundWords: typed }), p, none, NOW)).toBe("incomplete");
    expect(checkEntry(entry(p, { foundWords: typed, hintsUsed: { hammer: 2, chisel: 0, sparks: 0 } }), p, none, NOW)).toBe("incomplete");
    expect(checkEntry(entry(p, { foundWords: typed, hintsUsed: { hammer: 2, chisel: 1, sparks: 0 } }), p, none, NOW)).toBeNull();
    // One Spark Shower shows up to 5 letters.
    expect(checkEntry(entry(p, { foundWords: ["AAA", "BBB"], hintsUsed: { hammer: 1, chisel: 0, sparks: 1 } }), p, none, NOW)).toBeNull();
    // All by hints: no typed words at all.
    expect(checkEntry(entry(p, { foundWords: [], hintsUsed: { hammer: 2, chisel: 0, sparks: 2 } }), p, none, NOW)).toBeNull();
  });

  it(`wants at least ${MIN_MS_PER_FOUND_WORD} ms per typed word`, () => {
    expect(checkEntry(entry(p, { durationMs: 4 * MIN_MS_PER_FOUND_WORD }), p, none, NOW)).toBeNull();
    expect(checkEntry(entry(p, { durationMs: 4 * MIN_MS_PER_FOUND_WORD - 1 }), p, none, NOW)).toBe("too_fast");
    // Only typed words count.
    expect(checkEntry(entry(p, { foundWords: [], hintsUsed: { hammer: 12, chisel: 0, sparks: 0 }, durationMs: 0 }), p, none, NOW)).toBeNull();
  });
});

describe("checkPickups against shared/pickups.md", () => {
  // A 30-cell c-0010, as in the vectors.
  const c10 = synthetic(10, 10);
  // A 30-cell c-0074 and a 24-cell c-0032.
  const c74 = synthetic(74, 10);
  const c32 = synthetic(32, 8);
  const claim = (cell: number, kind: "hammer" | "chisel" | "sparks" = "hammer") => ({ cell, kind });

  it("uses the vectors' cell counts", () => {
    expect([c10.cellCount, c74.cellCount, c32.cellCount]).toEqual([30, 30, 24]);
  });

  it("grants (10, chisel) for user-123 on c-0010 at level 20, and a hammer at level 1", () => {
    const e = entry(c10, { pickups: [claim(10, "chisel")] });
    expect(checkPickups("user-123", e, c10, 20, new Set())).toEqual({ granted: [claim(10, "chisel")], rejected: 0, newSeed: null });
    // The server's level wins: at level 1 the same cell is a Hammer Strike, whatever was claimed.
    expect(checkPickups("user-123", e, c10, 1, new Set())).toEqual({ granted: [claim(10, "hammer")], rejected: 0, newSeed: null });
  });

  it("grants (19, sparks) on c-0074 only from level 12", () => {
    const e = entry(c74, { pickups: [claim(19, "sparks")] });
    expect(checkPickups("user-123", e, c74, 12, new Set()).granted).toEqual([claim(19, "sparks")]);
    expect(checkPickups("user-123", e, c74, 11, new Set()).granted).toEqual([claim(19, "hammer")]);
  });

  it("grants (7, hammer) on c-0032 and nothing for other cells", () => {
    const e = entry(c32, { pickups: [claim(7), claim(8), claim(7)] });
    expect(checkPickups("user-123", e, c32, 3, new Set())).toEqual({ granted: [claim(7)], rejected: 2, newSeed: null });
  });

  it("finds nothing for abc on c-0001", () => {
    const c1 = synthetic(1, 4);
    expect(checkPickups("abc", entry(c1, { pickups: [claim(0)] }), c1, 1, new Set())).toEqual({ granted: [], rejected: 1, newSeed: null });
  });

  it("seeds with an install id when given one, and asks to remember it", () => {
    const seed = "install-" + "ab".repeat(16);
    const p = synthetic(10, 10);
    const expected = pickupsFor(seed, p.id, p.cellCount, 20);
    const e = entry(p, { pickupSeed: seed, pickups: expected.map((x) => claim(x.index, x.kind)) });
    const check = checkPickups("account-uid", e, p, 20, new Set());
    expect(check.granted).toHaveLength(expected.length);
    expect(check.newSeed).toBe(expected.length > 0 ? seed : null);
  });

  it(`refuses other seeds, and new install ids past ${MAX_INSTALL_SEEDS}`, () => {
    const e = entry(c10, { pickupSeed: "user-123", pickups: [claim(10)] });
    expect(checkPickups("me", e, c10, 20, new Set())).toEqual({ granted: [], rejected: 1, newSeed: null });

    const seeds = new Set(Array.from({ length: MAX_INSTALL_SEEDS }, (_, i) => `install-${String(i).repeat(32)}`));
    const fresh = "install-" + "f".repeat(32);
    expect(checkPickups("me", entry(c10, { pickupSeed: fresh, pickups: [claim(0)] }), c10, 20, seeds)).toMatchObject({ granted: [], rejected: 1 });
    // A known one still works.
    const known = [...seeds][0]!;
    const got = pickupsFor(known, c10.id, c10.cellCount, 20);
    const result = checkPickups("me", entry(c10, { pickupSeed: known, pickups: got.map((x) => claim(x.index, x.kind)) }), c10, 20, seeds);
    expect(result).toMatchObject({ granted: got.map((x) => claim(x.index, x.kind)), newSeed: null });
  });
});

describe("evaluateSync", () => {
  const uid = "player";

  it("returns results in input order and applies entries in completedAt order", () => {
    const ps = [1, 2, 3, 4, 5, 6].map((s) => synthetic(s, 3));
    // 6 × 10 XP = level 2 on whichever is applied last: stage 1 here.
    const entries = ps.map((p) => entry(p, { completedAt: NOW - p.stage * 1000 }));
    const out = evaluateSync({ uid, now: NOW, state: state(), entries, puzzles: puzzles(...ps) });
    expect(out.results.map((r) => r.stage)).toEqual([1, 2, 3, 4, 5, 6]);
    expect(out.results[0]).toMatchObject({ accepted: true, levelUps: 1, level: 2, rewards: { hammer: 1 } });
    expect(out.results.slice(1).every((r) => r.levelUps === 0)).toBe(true);
    expect(out.accepted.map((a) => a.stage)).toEqual([6, 5, 4, 3, 2, 1]);
    expect(out.state).toMatchObject({ totalXp: 60, campaignCompleted: 6, soloDone: 6, wordsForged: 18, hints: { hammer: 4 } });
  });

  it("uses each puzzle's starting level for its pickups", () => {
    // Start 1 XP short of level 5 (Chisel unlocks), on a 30-cell c-0010 for user-123,
    // whose pickup at cell 10 is a Chisel from level 5.
    const before = synthetic(9, 3);
    const c10 = synthetic(10, 10);
    const s = state({ totalXp: totalXpForLevel(5) - 10 });
    const claimChisel = { cell: 10, kind: "chisel" as const };

    // c-0010 first: it starts at level 4, so the Chisel is a Hammer Strike.
    const first = evaluateSync({
      uid: "user-123",
      now: NOW,
      state: s,
      entries: [entry(c10, { completedAt: NOW - 2000, pickups: [claimChisel] }), entry(before, { completedAt: NOW - 1000 })],
      puzzles: puzzles(before, c10),
    });
    expect(first.results[0]).toMatchObject({ pickups: [{ cell: 10, kind: "hammer" }], levelUps: 1, level: 5 });

    // c-0009 first takes the player to level 5, so c-0010 starts at 5 and the Chisel stays one.
    const second = evaluateSync({
      uid: "user-123",
      now: NOW,
      state: s,
      entries: [entry(c10, { completedAt: NOW - 1000, pickups: [claimChisel] }), entry(before, { completedAt: NOW - 2000 })],
      puzzles: puzzles(before, c10),
    });
    expect(second.results[0]).toMatchObject({ pickups: [claimChisel], levelUps: 0 });
    // Level 5 also brings a Chisel as a level-up reward.
    expect(second.results[1]).toMatchObject({ levelUps: 1, rewards: { hammer: 1, chisel: 1, sparks: 0 } });
    expect(second.state.hints).toEqual({ hammer: 4, chisel: 2, sparks: 0 });
  });

  it("grants a rank-up bundle", () => {
    const p = synthetic(1, 3);
    const out = evaluateSync({ uid, now: NOW, state: state({ totalXp: totalXpForLevel(10) - 10 }), entries: [entry(p)], puzzles: puzzles(p) });
    // Level 10: +1 hammer, +1 chisel (every 5th), and one of each unlocked type for the rank.
    expect(out.results[0]).toMatchObject({ level: 10, rewards: { hammer: 2, chisel: 2, sparks: 0 } });
  });

  it("lets pickups and the Scrap Bin pay for hints used in the same puzzle, but not level-up rewards", () => {
    const p = synthetic(1, 3, Array.from({ length: 12 }, (_, i) => `B${String.fromCharCode(65 + i)}X`));
    const s = state({ hints: noHints(), scrapBin: 9, totalXp: totalXpForLevel(2) - 11 });
    // One bonus word fills the bin → a hammer, which pays for the one hammer used.
    const out = evaluateSync({
      uid,
      now: NOW,
      state: s,
      entries: [entry(p, { bonusWords: [[...p.bonus][0]!], hintsUsed: { hammer: 2, chisel: 0, sparks: 0 } })],
      puzzles: puzzles(p),
    });
    expect(out.results[0]).toMatchObject({ scrapHammers: 1, levelUps: 1, rewards: { hammer: 1 }, hintsClamped: { hammer: 1, chisel: 0, sparks: 0 } });
    // 0 + 1 (scrap) − 2 (used) → clamped to 0, then + 1 (level 2).
    expect(out.state.hints).toEqual({ hammer: 1, chisel: 0, sparks: 0 });
    expect(out.state.scrapBin).toBe(0);
  });

  it("caps solo XP at 15 and counts bonus words once", () => {
    const bonus = Array.from({ length: 8 }, (_, i) => `Q${String.fromCharCode(65 + i)}Q`);
    const p = synthetic(1, 3, bonus);
    const out = evaluateSync({ uid, now: NOW, state: state(), entries: [entry(p, { bonusWords: [...bonus, ...bonus] })], puzzles: puzzles(p) });
    expect(out.results[0]).toMatchObject({ xp: 15, scrapHammers: 0 });
    expect(out.state.scrapBin).toBe(8);
  });

  it("keeps campaignCompleted at the highest stage, even with gaps", () => {
    const p3 = synthetic(3, 3);
    const p7 = synthetic(7, 3);
    const out = evaluateSync({ uid, now: NOW, state: state({ campaignCompleted: 5 }), entries: [entry(p3), entry(p7)], puzzles: puzzles(p3, p7) });
    expect(out.state.campaignCompleted).toBe(7);
  });

  it("keeps the longest word, the first one on ties", () => {
    const p = campaignPuzzle(1, {
      id: "c-0001",
      letters: "ABCDE",
      words: [
        { w: "ABCD", x: 0, y: 0, d: "a" },
        { w: "BCDE", x: 0, y: 2, d: "a" },
      ],
      bonus: [],
    });
    const out = evaluateSync({ uid, now: NOW, state: state({ longestWord: "XYZ" }), entries: [entry(p)], puzzles: puzzles(p) });
    expect(out.state.longestWord).toBe("ABCD");
    const kept = evaluateSync({ uid, now: NOW, state: state({ longestWord: "LONGER" }), entries: [entry(p)], puzzles: puzzles(p) });
    expect(kept.state.longestWord).toBe("LONGER");
  });

  it("rejects duplicates within a batch and leaves the state alone for rejects", () => {
    const p = synthetic(1, 3);
    const out = evaluateSync({
      uid,
      now: NOW,
      state: state(),
      entries: [entry(p), entry(p, { completedAt: NOW - 1 }), "junk", entry(p, { stage: 2, puzzleId: "c-0002" })],
      puzzles: puzzles(p),
    });
    expect(out.results.map((r) => (r.accepted ? "ok" : r.reason))).toEqual(["ok", "duplicate", "invalid_entry", "unknown_stage"]);
    expect(out.state.totalXp).toBe(10);
    expect(out.accepted).toHaveLength(1);
  });

  it("collects new install seeds once", () => {
    const seed = "install-" + "c".repeat(32);
    const ps = Array.from({ length: 40 }, (_, i) => synthetic(i + 1, 10));
    const withPickups = ps.filter((p) => pickupsFor(seed, p.id, p.cellCount, 1).length > 0).slice(0, 2);
    expect(withPickups).toHaveLength(2);
    const entries = withPickups.map((p) =>
      entry(p, { pickupSeed: seed, pickups: pickupsFor(seed, p.id, p.cellCount, 1).map((x) => ({ cell: x.index, kind: x.kind })) }),
    );
    const out = evaluateSync({ uid, now: NOW, state: state(), entries, puzzles: puzzles(...withPickups) });
    expect(out.newInstallSeeds).toEqual([seed]);
    expect([...out.state.installSeeds]).toEqual([seed]);
  });
});
