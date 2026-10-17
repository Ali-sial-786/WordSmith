import { describe, expect, it } from "vitest";
import { loadBankRows } from "../../scripts/build-bank-sql.mjs";
import { mulberry32 } from "../../src/rules/pickups";
import {
  cellKey,
  emberKind,
  emptyCells,
  hammerCell,
  indexMold,
  newlyComplete,
  parseMpPuzzle,
  placeEmbers,
  shuffleLetters,
  slotCells,
  sparkCells,
} from "../../src/rules/mold";
import { EXAMPLE, playback } from "./fixtures";

describe("parseMpPuzzle", () => {
  it("numbers slots in reading order, whatever the file's order", () => {
    const p = parseMpPuzzle(EXAMPLE);
    expect(p.slots).toEqual([
      { slot: 0, x: 0, y: 0, d: "a", len: 4, word: "TEAR" },
      { slot: 1, x: 1, y: 0, d: "d", len: 3, word: "EAT" },
      { slot: 2, x: 3, y: 0, d: "d", len: 4, word: "RATE" },
    ]);
    expect(p).toMatchObject({ id: "m-99999", letters: "RTAE", heat: 1, size: 1, cols: 4, rows: 4 });
  });

  it("puts across before down at the same cell", () => {
    const p = parseMpPuzzle({ ...EXAMPLE, words: [{ w: "TEA", x: 0, y: 0, d: "d" }, { w: "TEAR", x: 0, y: 0, d: "a" }] });
    expect(p.slots.map((s) => s.d)).toEqual(["a", "d"]);
  });

  it.each([
    [{ ...EXAMPLE, id: undefined }, /no id/],
    [{ ...EXAMPLE, letters: "rtae" }, /letters/],
    [{ ...EXAMPLE, heat: 7 }, /heat/],
    [{ ...EXAMPLE, size: 0 }, /size/],
    [{ ...EXAMPLE, cols: 11 }, /grid size/],
    [{ ...EXAMPLE, words: [] }, /no words/],
    [{ ...EXAMPLE, words: [{ w: "TEARS", x: 0, y: 0, d: "a" }] }, /off the grid/],
    [{ ...EXAMPLE, words: [{ w: "RATE", x: 3, y: 1, d: "d" }] }, /off the grid/],
    [{ ...EXAMPLE, words: [{ w: "TO", x: 0, y: 0, d: "a" }] }, /bad word/],
    [{ ...EXAMPLE, bonus: [1] }, /bonus/],
  ])("refuses a broken puzzle", (data, error) => {
    expect(() => parseMpPuzzle(data)).toThrow(error);
  });

  it("reads every puzzle in the real bank, with consistent crossings", () => {
    for (const row of loadBankRows()) {
      const p = parseMpPuzzle(JSON.parse(row.data));
      expect(p.size).toBe(row.size);
      const letters = new Map<string, string>();
      for (const s of p.slots) {
        slotCells(s).forEach((c, i) => {
          const key = cellKey(c.x, c.y);
          const before = letters.get(key);
          if (before !== undefined) expect(before).toBe(s.word[i]);
          letters.set(key, s.word[i]!);
        });
      }
      expect(indexMold(p).cells.size).toBe(letters.size);
    }
  });
});

describe("indexMold", () => {
  it("lists each letter cell once, by row then column, with its slots", () => {
    const index = indexMold(parseMpPuzzle(EXAMPLE));
    const cells = [...index.cells.values()];
    expect(cells.map((c) => c.key)).toEqual(["0,0", "1,0", "2,0", "3,0", "1,1", "3,1", "1,2", "3,2", "3,3"]);
    expect(cells.map((c) => c.letter).join("")).toBe("TEARAATTE");
    expect(index.cells.get("1,0")!.slots).toEqual([0, 1]);
    expect(index.cells.get("3,3")!.slots).toEqual([2]);
    expect(index.slotByWord.get("EAT")!.slot).toBe(1);
  });

  it("finds slots that filled cells complete", () => {
    const index = indexMold(parseMpPuzzle(EXAMPLE));
    const filled = new Set(["0,0", "1,0", "2,0", "3,0", "1,1", "1,2"]);
    expect(newlyComplete(index, filled, new Set()).map((s) => s.word)).toEqual(["TEAR", "EAT"]);
    expect(newlyComplete(index, filled, new Set([0])).map((s) => s.word)).toEqual(["EAT"]);
    expect(emptyCells(index, filled).map((c) => c.key)).toEqual(["3,1", "3,2", "3,3"]);
  });
});

describe("hint cells", () => {
  const index = indexMold(parseMpPuzzle(EXAMPLE));

  it("Hammer Strike: one random empty cell", () => {
    const filled = new Set(["0,0", "1,0"]);
    expect(hammerCell(index, filled, playback(0))!.key).toBe("2,0");
    expect(hammerCell(index, filled, playback(0.999))!.key).toBe("3,3");
    expect(hammerCell(index, new Set(index.cells.keys()), playback(0))).toBeNull();
  });

  it("Spark Shower: 5 empty cells, reaching every slot first", () => {
    for (let seed = 0; seed < 200; seed++) {
      const cells = sparkCells(index, new Set(), mulberry32(seed));
      expect(cells).toHaveLength(5);
      expect(new Set(cells.map((c) => c.key)).size).toBe(5);
      // The first picks touch every slot before any slot gets a second.
      const firstThree = new Set(cells.slice(0, 3).flatMap((c) => c.slots));
      expect(firstThree).toEqual(new Set([0, 1, 2]));
    }
  });

  it("Spark Shower: fewer when fewer cells are empty", () => {
    const filled = new Set([...index.cells.keys()].slice(0, 7));
    const cells = sparkCells(index, filled, mulberry32(1));
    expect(cells.map((c) => c.key).sort()).toEqual(["3,2", "3,3"]);
  });
});

describe("embers", () => {
  const index = indexMold(parseMpPuzzle(EXAMPLE));

  it("come about 1 round in 5, sometimes two, never two on one word", () => {
    let rounds = 0;
    let withEmbers = 0;
    let doubles = 0;
    for (let seed = 0; seed < 5000; seed++) {
      const embers = placeEmbers(index, mulberry32(seed));
      rounds++;
      if (embers.length > 0) withEmbers++;
      if (embers.length === 2) {
        doubles++;
        const [a, b] = embers.map((e) => index.cells.get(cellKey(e.x, e.y))!);
        expect(a!.slots.some((s) => b!.slots.includes(s))).toBe(false);
      }
      for (const e of embers) expect(index.cells.has(cellKey(e.x, e.y))).toBe(true);
    }
    expect(withEmbers / rounds).toBeGreaterThan(0.17);
    expect(withEmbers / rounds).toBeLessThan(0.23);
    expect(doubles).toBeGreaterThan(0);
  });

  it("place one when no cell is clear of the first one's words", () => {
    const tiny = indexMold(parseMpPuzzle({ ...EXAMPLE, cols: 4, rows: 1, words: [{ w: "TEAR", x: 0, y: 0, d: "a" }] }));
    expect(placeEmbers(tiny, playback(0.1, 0.1, 0.5))).toEqual([{ x: 2, y: 0 }]);
    expect(placeEmbers(tiny, playback(0.3))).toEqual([]);
  });

  it("turn into a hint the collector has unlocked", () => {
    expect(emberKind(playback(0.5), 1)).toBe("hammer");
    expect(emberKind(playback(0.8), 1)).toBe("hammer");
    expect(emberKind(playback(0.8), 5)).toBe("chisel");
    expect(emberKind(playback(0.97), 5)).toBe("hammer");
    expect(emberKind(playback(0.97), 12)).toBe("sparks");
  });
});

describe("shuffleLetters", () => {
  it("keeps the tiles, and never spells a word to avoid", () => {
    for (let seed = 0; seed < 100; seed++) {
      const out = shuffleLetters("RTAE", mulberry32(seed), new Set(["RATE", "TEAR"]));
      expect([...out].sort().join("")).toBe("AERT");
      expect(["RATE", "TEAR"]).not.toContain(out);
    }
  });

  it("falls back to the puzzle's order", () => {
    // rand() = 0.999 always leaves the tiles where they are.
    expect(shuffleLetters("RTAE", playback(0.999), new Set(["RTAE"]))).toBe("RTAE");
  });
});
