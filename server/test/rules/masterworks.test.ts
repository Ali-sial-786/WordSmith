import { describe, expect, it } from "vitest";
import {
  finishedMasterworks,
  gildedCell,
  MASTERWORK_REWARD,
  MASTERWORKS,
  masterworksFinishedBetween,
  TOTAL_PIECES,
} from "../../src/rules/masterworks";
import { pickupsFor, type Pickup } from "../../src/rules/pickups";

// Every test vector in shared/masterworks.md (the app's Dart engine passes
// the same ones), with the pickups for the same inputs, which the gilded
// cell steps around.
describe("shared/masterworks.md test vectors", () => {
  it.each<[string, string, number, number, number | null, Pickup[]]>([
    ["user-123", "c-0010", 30, 20, null, [{ index: 10, kind: "chisel" }]],
    ["abc", "c-0001", 12, 1, null, []],
    ["friend-7", "c-0200", 40, 30, 14, []],
    ["user-123", "c-0074", 30, 12, 23, [{ index: 19, kind: "sparks" }]],
    ["u1", "c-0003", 9, 5, 4, []],
    // The raw index lands on the pickup's cell and steps forward.
    ["user-123", "c-0025", 3, 20, 1, [{ index: 0, kind: "hammer" }]],
    ["user-123", "c-0025", 12, 20, 4, [{ index: 3, kind: "hammer" }]],
    // Steps past the last cell to the first.
    ["user-123", "c-0205", 3, 20, 0, [{ index: 2, kind: "sparks" }]],
    // Steps past two pickups.
    [
      "user-123",
      "c-1306",
      3,
      20,
      2,
      [
        { index: 0, kind: "hammer" },
        { index: 1, kind: "hammer" },
      ],
    ],
    // Every cell is a pickup cell: no gilded cell.
    ["user-123", "c-0025", 1, 20, null, [{ index: 0, kind: "hammer" }]],
  ])("gildedCell(%j, %j, %i, %i) is %s", (userId, puzzleId, cellCount, level, expected, pickups) => {
    expect(pickupsFor(userId, puzzleId, cellCount, level)).toEqual(pickups);
    expect(gildedCell(userId, puzzleId, cellCount, level)).toBe(expected);
  });
});

describe("gildedCell", () => {
  it("is never on a pickup cell, always inside the grid, and in about 1 puzzle in 4", () => {
    let gilded = 0;
    const N = 20_000;
    for (let i = 0; i < N; i++) {
      const cellCount = 3 + (i % 25);
      const puzzleId = `c-${String(i).padStart(4, "0")}`;
      const cell = gildedCell(`player-${i % 7}`, puzzleId, cellCount, 30);
      if (cell === null) continue;
      gilded++;
      expect(cell).toBeGreaterThanOrEqual(0);
      expect(cell).toBeLessThan(cellCount);
      expect(pickupsFor(`player-${i % 7}`, puzzleId, cellCount, 30).map((p) => p.index)).not.toContain(cell);
    }
    expect(gilded / N).toBeCloseTo(0.25, 1);
  });

  it("is seeded apart from the pickups", () => {
    expect(gildedCell("user-123", "c-0074", 30, 12)).toBe(23);
    expect(gildedCell("install-0123456789abcdef0123456789abcdef", "c-0074", 30, 12)).not.toBe(gildedCell("user-123", "c-0074", 30, 12));
  });

  it("rejects an empty or invalid cell count", () => {
    expect(() => gildedCell("u", "c-0001", 0, 1)).toThrow(RangeError);
    expect(() => gildedCell("u", "c-0001", 1.5, 1)).toThrow(RangeError);
  });
});

describe("the Masterworks", () => {
  it("are twelve, 114 pieces in all", () => {
    expect(MASTERWORKS.map((m) => m.id)).toEqual([
      "horseshoe",
      "bell",
      "dagger",
      "lantern",
      "helm",
      "shield",
      "axe",
      "crown",
      "longsword",
      "astrolabe",
      "warhammer",
      "anvil",
    ]);
    expect(MASTERWORKS.map((m) => m.pieces)).toEqual([6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 12]);
    expect(TOTAL_PIECES).toBe(114);
    expect(MASTERWORK_REWARD).toEqual({ xp: 100, hints: { hammer: 0, chisel: 1, sparks: 1 } });
  });

  it("finish at the running totals 6, 12, 20, 28, … 114", () => {
    expect(finishedMasterworks(0)).toEqual([]);
    expect(finishedMasterworks(5)).toEqual([]);
    expect(finishedMasterworks(6).map((m) => m.id)).toEqual(["horseshoe"]);
    expect(finishedMasterworks(19)).toHaveLength(2);
    expect(finishedMasterworks(20)).toHaveLength(3);
    expect(finishedMasterworks(113)).toHaveLength(11);
    expect(finishedMasterworks(114)).toHaveLength(12);
    expect(finishedMasterworks(500)).toHaveLength(12);
    expect(masterworksFinishedBetween(5, 6).map((m) => m.id)).toEqual(["horseshoe"]);
    expect(masterworksFinishedBetween(6, 7)).toEqual([]);
    expect(masterworksFinishedBetween(27, 28).map((m) => m.id)).toEqual(["lantern"]);
    expect(masterworksFinishedBetween(113, 114).map((m) => m.id)).toEqual(["anvil"]);
    // Pieces after the twelfth build nothing.
    expect(masterworksFinishedBetween(114, 115)).toEqual([]);
  });
});
