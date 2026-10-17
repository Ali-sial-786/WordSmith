import { describe, expect, it } from "vitest";
import { loadCampaignRows } from "../../scripts/build-campaign-sql.mjs";
import { campaignPuzzle, campaignPuzzleId } from "../../src/rules/campaign";

describe("campaignPuzzleId", () => {
  it("pads the stage to 4 digits", () => {
    expect(campaignPuzzleId(1)).toBe("c-0001");
    expect(campaignPuzzleId(600)).toBe("c-0600");
  });
});

describe("campaignPuzzle", () => {
  // shared/puzzle-format.md's example: TEAR across the top, EAT and RATE down from it.
  const example = {
    id: "c-0001",
    letters: "RTAE",
    words: [
      { w: "TEAR", x: 0, y: 0, d: "a" },
      { w: "EAT", x: 1, y: 0, d: "d" },
      { w: "RATE", x: 3, y: 0, d: "d" },
    ],
    bonus: ["ARE", "ART"],
  };

  it("counts letter cells once at crossings and indexes them by row, then column", () => {
    const p = campaignPuzzle(1, example);
    // Row 0: T E A R (4); rows 1-2: E's column and R's column (2 each); row 3: R's column (1).
    expect(p.cellCount).toBe(4 + 2 + 2 + 1);
    expect(p.wordCells.get("TEAR")).toEqual([0, 1, 2, 3]);
    expect(p.wordCells.get("EAT")).toEqual([1, 4, 6]);
    expect(p.wordCells.get("RATE")).toEqual([3, 5, 7, 8]);
    expect([...p.gridWords]).toEqual(["TEAR", "EAT", "RATE"]);
    expect(p.bonus.has("ART")).toBe(true);
  });

  it("refuses data that isn't a puzzle", () => {
    expect(() => campaignPuzzle(1, null)).toThrow();
    expect(() => campaignPuzzle(1, { ...example, words: [] })).toThrow(/words/);
    expect(() => campaignPuzzle(1, { ...example, words: [{ w: "ab", x: 0, y: 0, d: "a" }] })).toThrow(/words/);
    expect(() => campaignPuzzle(1, { ...example, bonus: "ARE" })).toThrow(/bonus/);
  });

  it("parses every puzzle in the real campaign, which matches the format's rules", () => {
    const rows = loadCampaignRows();
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      const p = campaignPuzzle(row.stage, JSON.parse(row.data));
      expect(p.id).toBe(campaignPuzzleId(row.stage));
      expect(p.cellCount).toBeGreaterThanOrEqual(3);
      for (const word of p.bonus) expect(p.gridWords.has(word)).toBe(false);
    }
  });
});
