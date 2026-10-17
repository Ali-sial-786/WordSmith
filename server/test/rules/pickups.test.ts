import { describe, expect, it } from "vitest";
import { type Pickup, fnv1a32, mulberry32, pickupsFor } from "../../src/rules/pickups";

// Every test vector in shared/pickups.md. The Dart engine must pass the same ones.
describe("shared/pickups.md test vectors", () => {
  it.each([
    ["", 0x811c9dc5],
    ["a", 0xe40c292c],
    ["wordsmith", 0xb0870248],
  ])("fnv1a32(%j)", (input, expected) => {
    expect(fnv1a32(input)).toBe(expected);
  });

  it("mulberry32(1) first three outputs", () => {
    const rand = mulberry32(1);
    expect([rand(), rand(), rand()].map((x) => x.toFixed(10))).toEqual(["0.6270739406", "0.0027357212", "0.5274470400"]);
  });

  it.each<[string, string, number, number, Pickup[]]>([
    ["user-123", "c-0010", 30, 20, [{ index: 10, kind: "chisel" }]],
    ["user-123", "c-0010", 30, 1, [{ index: 10, kind: "hammer" }]],
    ["user-123", "c-0032", 24, 3, [{ index: 7, kind: "hammer" }]],
    ["abc", "c-0001", 12, 1, []],
    ["user-123", "c-0012", 9, 50, [{ index: 0, kind: "hammer" }]],
    [
      "friend-7",
      "m-00033",
      40,
      30,
      [
        { index: 29, kind: "hammer" },
        { index: 2, kind: "hammer" },
      ],
    ],
  ])("pickupsFor(%j, %j, %i, %i)", (userId, puzzleId, cellCount, level, expected) => {
    expect(pickupsFor(userId, puzzleId, cellCount, level)).toEqual(expected);
  });
});

// Extra vectors for branches the shared file doesn't reach. Worth adding to
// shared/pickups.md so the Dart engine is checked on them too.
describe("extra vectors", () => {
  it("rolls a Spark Shower, which becomes a Hammer Strike below level 12", () => {
    expect(pickupsFor("user-123", "c-0074", 30, 12)).toEqual([{ index: 19, kind: "sparks" }]);
    expect(pickupsFor("user-123", "c-0074", 30, 11)).toEqual([{ index: 19, kind: "hammer" }]);
  });

  it("moves a second pickup that lands on a used cell to the next cell, wrapping around", () => {
    // Both pickups roll index 2 of 3; the second moves to (2 + 1) % 3 = 0.
    expect(pickupsFor("user-123", "c-0146", 3, 12)).toEqual([
      { index: 2, kind: "hammer" },
      { index: 0, kind: "hammer" },
    ]);
  });
});

describe("fnv1a32", () => {
  it("hashes UTF-8 bytes, not UTF-16 code units", () => {
    // "é" is two UTF-8 bytes (C3 A9).
    let h = 0x811c9dc5;
    for (const b of [0xc3, 0xa9]) h = Math.imul(h ^ b, 0x01000193) >>> 0;
    expect(fnv1a32("é")).toBe(h);
  });

  it("always returns an unsigned 32-bit integer", () => {
    for (const s of ["", "x", "user-123:c-0010", "a much longer string than usual ".repeat(10)]) {
      const h = fnv1a32(s);
      expect(Number.isInteger(h)).toBe(true);
      expect(h).toBeGreaterThanOrEqual(0);
      expect(h).toBeLessThan(2 ** 32);
    }
  });
});

describe("mulberry32", () => {
  it("stays in [0, 1)", () => {
    const rand = mulberry32(0xdeadbeef);
    for (let i = 0; i < 10_000; i++) {
      const x = rand();
      expect(x).toBeGreaterThanOrEqual(0);
      expect(x).toBeLessThan(1);
    }
  });
});

describe("pickupsFor", () => {
  it("is deterministic", () => {
    expect(pickupsFor("friend-7", "m-00033", 40, 30)).toEqual(pickupsFor("friend-7", "m-00033", 40, 30));
  });

  it("puts each pickup in a different cell inside the grid", () => {
    for (let i = 1; i <= 3000; i++) {
      const cellCount = 3 + (i % 20);
      const pickups = pickupsFor("user-123", `c-${String(i).padStart(4, "0")}`, cellCount, 50);
      const cells = pickups.map((p) => p.index);
      expect(new Set(cells).size).toBe(cells.length);
      for (const c of cells) {
        expect(c).toBeGreaterThanOrEqual(0);
        expect(c).toBeLessThan(cellCount);
      }
    }
  });

  it("roughly matches the documented odds", () => {
    let withPickups = 0;
    let doubles = 0;
    const kinds = { hammer: 0, chisel: 0, sparks: 0 };
    const N = 20_000;
    for (let i = 0; i < N; i++) {
      const pickups = pickupsFor(`player-${i % 7}`, `m-${String(i).padStart(5, "0")}`, 30, 50);
      if (pickups.length > 0) withPickups++;
      if (pickups.length === 2) doubles++;
      for (const p of pickups) kinds[p.kind]++;
    }
    const total = kinds.hammer + kinds.chisel + kinds.sparks;
    expect(withPickups / N).toBeCloseTo(0.2, 1);
    expect(doubles / withPickups).toBeCloseTo(0.15, 1);
    expect(kinds.hammer / total).toBeCloseTo(0.7, 1);
    expect(kinds.chisel / total).toBeCloseTo(0.25, 1);
    expect(kinds.sparks / total).toBeCloseTo(0.05, 1);
  });

  it("never places more pickups than there are cells", () => {
    // This seed rolls two pickups (see the shared vectors).
    expect(pickupsFor("friend-7", "m-00033", 1, 30)).toEqual([{ index: 0, kind: "hammer" }]);
  });

  it("rejects an empty or invalid cell count", () => {
    expect(() => pickupsFor("u", "c-0001", 0, 1)).toThrow(RangeError);
    expect(() => pickupsFor("u", "c-0001", 2.5, 1)).toThrow(RangeError);
  });
});
